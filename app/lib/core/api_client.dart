import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.isNetwork = false});

  final String message;
  final int? statusCode;

  /// True when the server could not be reached at all (offline, wrong Wi-Fi).
  final bool isNetwork;

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;

  @override
  String toString() => message;
}

class ServerInfo {
  const ServerInfo({required this.url, required this.familyName, required this.version});

  final String url;
  final String familyName;
  final String version;
}

class PairResult {
  const PairResult({required this.deviceId, required this.deviceToken, required this.familyName});

  final int deviceId;
  final String deviceToken;
  final String familyName;
}

class ParentSession {
  const ParentSession({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;

  bool get isValid => DateTime.now().isBefore(expiresAt.subtract(const Duration(minutes: 1)));

  Map<String, dynamic> toJson() => {'token': token, 'expires_at': expiresAt.toIso8601String()};

  static ParentSession? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final expires = DateTime.tryParse((j['expires_at'] as String?) ?? '');
    final token = j['token'] as String?;
    if (expires == null || token == null) return null;
    return ParentSession(token: token, expiresAt: expires);
  }
}

class RunUploadResult {
  const RunUploadResult({required this.serverId, required this.duplicate, required this.stats});

  final int serverId;
  final bool duplicate;
  final Stats stats;
}

class DeviceInfo {
  const DeviceInfo({required this.id, required this.name, this.createdAt, this.lastSeenAt});

  final int id;
  final String name;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: j['id'] as int,
        name: (j['name'] as String?) ?? '',
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? ''),
        lastSeenAt: DateTime.tryParse((j['last_seen_at'] as String?) ?? ''),
      );
}

final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

/// Private/LAN style hosts get plain http on port 8000 by default; everything
/// else is assumed to be a public HTTPS server.
bool _looksLocal(String host) =>
    _ipv4.hasMatch(host) || host.endsWith('.local') || host == 'localhost';

/// Normalises what a parent typed into a base URL such as
/// `https://wijkloper.example.org` or `http://192.168.1.5:8000`.
String normalizeServerUrl(String input) {
  var url = input.trim();
  if (url.isEmpty) return url;
  if (!url.contains('://')) {
    final host = url.split('/').first.split(':').first;
    url = '${_looksLocal(host) ? 'http' : 'https'}://$url';
  }
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  int? port = uri.hasPort ? uri.port : null;
  if (port == null && uri.scheme == 'http' && _looksLocal(uri.host)) port = 8000;
  return Uri(scheme: uri.scheme, host: uri.host, port: port).toString();
}

/// Thin JSON client for the Wijkloper API.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    this.deviceToken,
    this.parentToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String? deviceToken;
  final String? parentToken;
  final Duration timeout;
  final http.Client _client;

  // --- plumbing ---------------------------------------------------------------

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Map<String, String> _headers({bool parent = false}) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (deviceToken != null) 'Authorization': 'Bearer $deviceToken',
        if (parent && parentToken != null) 'X-Parent-Token': parentToken!,
      };

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool parent = false,
  }) async {
    final request = http.Request(method, _uri(path, query))..headers.addAll(_headers(parent: parent));
    if (body != null) request.body = jsonEncode(body);
    http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on SocketException {
      throw const ApiException('Cannot reach the server. Check your internet connection.', isNetwork: true);
    } on TimeoutException {
      throw const ApiException('The server did not answer in time.', isNetwork: true);
    } on http.ClientException {
      throw const ApiException('Cannot reach the server. Check your internet connection.', isNetwork: true);
    } on HandshakeException {
      throw const ApiException('Secure connection to the server failed (certificate problem).', isNetwork: true);
    }
    return _decode(response);
  }

  static Map<String, dynamic> _decode(http.Response response) {
    dynamic decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        decoded = null;
      }
    }
    if (response.statusCode >= 400) {
      var message = 'Server error ${response.statusCode}';
      if (decoded is Map && decoded['detail'] is String) {
        message = decoded['detail'] as String;
      } else if (decoded is Map && decoded['detail'] is List) {
        final first = (decoded['detail'] as List).firstOrNull;
        if (first is Map && first['msg'] is String) message = first['msg'] as String;
      }
      throw ApiException(message, statusCode: response.statusCode);
    }
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return {'result': decoded};
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query, bool parent = false}) =>
      _send('GET', path, query: query, parent: parent);
  Future<Map<String, dynamic>> post(String path, Object? body, {bool parent = false}) =>
      _send('POST', path, body: body, parent: parent);
  Future<Map<String, dynamic>> put(String path, Object? body, {bool parent = false}) =>
      _send('PUT', path, body: body, parent: parent);
  Future<Map<String, dynamic>> delete(String path, {bool parent = false}) =>
      _send('DELETE', path, parent: parent);

  // --- public -------------------------------------------------------------------

  /// Checks whether a Wijkloper server answers at [baseUrl]. Never throws.
  static Future<ServerInfo?> probe(
    String baseUrl, {
    Duration timeout = const Duration(seconds: 3),
    http.Client? client,
  }) async {
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final response = await c.get(Uri.parse('$baseUrl/api/health')).timeout(timeout);
      if (response.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is! Map || json['app'] != 'wijkloper') return null;
      return ServerInfo(
        url: baseUrl,
        familyName: (json['family_name'] as String?) ?? '',
        version: (json['version'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    } finally {
      if (own) c.close();
    }
  }

  Future<PairResult> pair({required String pairingCode, required String deviceName}) async {
    final json = await post('/api/pair', {'pairing_code': pairingCode, 'device_name': deviceName});
    return PairResult(
      deviceId: json['device_id'] as int,
      deviceToken: json['device_token'] as String,
      familyName: (json['family_name'] as String?) ?? '',
    );
  }

  // --- device -------------------------------------------------------------------

  /// Returns the config, or null when the server says our [knownVersion] is current.
  Future<AppConfig?> fetchConfig({int? knownVersion}) async {
    final json = await get(
      '/api/config',
      query: knownVersion == null ? null : {'known_version': '$knownVersion'},
    );
    if (json['unchanged'] == true) return null;
    return AppConfig.fromJson(json);
  }

  Future<RunUploadResult> uploadRun(RunRecord run) async {
    final json = await post('/api/runs', run.toJson());
    return RunUploadResult(
      serverId: json['id'] as int,
      duplicate: (json['duplicate'] as bool?) ?? false,
      stats: Stats.fromJson(json['stats'] as Map<String, dynamic>, fetchedAt: DateTime.now()),
    );
  }

  /// Sets or clears the door sticker on a house. Returns false when the server
  /// already had that value.
  Future<bool> setSticker(int addressId, String sticker) async {
    final json = await put('/api/addresses/$addressId/sticker', {'sticker': sticker});
    return (json['unchanged'] as bool?) != true;
  }

  Future<Stats> fetchStats(int? kidId) async {
    final json = await get('/api/stats', query: kidId == null ? null : {'kid_id': '$kidId'});
    return Stats.fromJson(json, fetchedAt: DateTime.now());
  }

  Future<List<RunRecord>> fetchRuns({int? kidId, int limit = 50}) async {
    final json = await get('/api/runs', query: {
      'kid_id': ?kidId?.toString(),
      'limit': '$limit',
    });
    return ((json['runs'] as List?) ?? const [])
        .map((e) => RunRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ParentSession> parentLogin(String pin) async {
    final json = await post('/api/parent/login', {'pin': pin});
    return ParentSession(
      token: json['parent_token'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
  }

  Future<void> parentLogout() async {
    try {
      await post('/api/parent/logout', null, parent: true);
    } on ApiException {
      // Best effort; the session expires on its own anyway.
    }
  }

  // --- admin --------------------------------------------------------------------

  Future<Map<String, dynamic>> adminSettings() => get('/api/admin/settings', parent: true);

  Future<void> adminUpdateSettings({String? familyName, String? newPin, String? pairingCode}) =>
      put('/api/admin/settings', {
        'family_name': ?familyName,
        'new_pin': ?newPin,
        'pairing_code': ?pairingCode,
      }, parent: true);

  Future<List<DeviceInfo>> adminDevices() async {
    final json = await get('/api/admin/devices', parent: true);
    return ((json['devices'] as List?) ?? const [])
        .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> adminDeleteDevice(int id) => delete('/api/admin/devices/$id', parent: true);

  Future<int> adminCreateKid(Map<String, dynamic> kid) async =>
      (await post('/api/admin/kids', kid, parent: true))['id'] as int;
  Future<void> adminUpdateKid(int id, Map<String, dynamic> kid) => put('/api/admin/kids/$id', kid, parent: true);
  Future<void> adminDeleteKid(int id) => delete('/api/admin/kids/$id', parent: true);
  Future<void> adminOrderKids(List<int> ids) => put('/api/admin/kids/order', {'ids': ids}, parent: true);

  Future<int> adminCreateProduct(Map<String, dynamic> product) async =>
      (await post('/api/admin/products', product, parent: true))['id'] as int;
  Future<void> adminUpdateProduct(int id, Map<String, dynamic> product) =>
      put('/api/admin/products/$id', product, parent: true);
  Future<void> adminDeleteProduct(int id) => delete('/api/admin/products/$id', parent: true);
  Future<void> adminOrderProducts(List<int> ids) => put('/api/admin/products/order', {'ids': ids}, parent: true);

  Future<int> adminCreateRoute(String name) async =>
      (await post('/api/admin/routes', {'name': name}, parent: true))['id'] as int;
  Future<void> adminUpdateRoute(int id, String name) => put('/api/admin/routes/$id', {'name': name}, parent: true);
  Future<void> adminDeleteRoute(int id) => delete('/api/admin/routes/$id', parent: true);

  Future<int> adminCreateStreet(int routeId, String name, NumberOrder order) async =>
      (await post('/api/admin/routes/$routeId/streets', {'name': name, 'number_order': order.apiValue}, parent: true))['id'] as int;
  Future<void> adminUpdateStreet(int id, {String? name, NumberOrder? order}) => put(
        '/api/admin/streets/$id',
        {'name': ?name, 'number_order': ?order?.apiValue},
        parent: true,
      );
  Future<void> adminDeleteStreet(int id) => delete('/api/admin/streets/$id', parent: true);
  Future<void> adminOrderStreets(int routeId, List<int> ids) =>
      put('/api/admin/routes/$routeId/streets/order', {'ids': ids}, parent: true);

  Future<int> adminCreateAddress(int streetId, Map<String, dynamic> address) async =>
      (await post('/api/admin/streets/$streetId/addresses', address, parent: true))['id'] as int;

  Future<({int created, int skipped})> adminBulkAddresses(
    int streetId, {
    required int start,
    required int end,
    required String parity,
    List<AddressProduct> products = const [],
  }) async {
    final json = await post(
      '/api/admin/streets/$streetId/addresses/bulk',
      {
        'start': start,
        'end': end,
        'parity': parity,
        'products': products.map((p) => p.toJson()).toList(),
      },
      parent: true,
    );
    return (created: (json['created'] as int?) ?? 0, skipped: (json['skipped'] as int?) ?? 0);
  }

  Future<void> adminUpdateAddress(int id, Map<String, dynamic> fields) =>
      put('/api/admin/addresses/$id', fields, parent: true);
  Future<void> adminDeleteAddress(int id) => delete('/api/admin/addresses/$id', parent: true);
  Future<void> adminOrderAddresses(int streetId, List<int> ids) =>
      put('/api/admin/streets/$streetId/addresses/order', {'ids': ids}, parent: true);

  Future<void> adminAssign({
    required List<int> addressIds,
    required int productId,
    required bool assigned,
    Set<int>? days,
  }) =>
      put(
        '/api/admin/assignments',
        {
          'address_ids': addressIds,
          'product_id': productId,
          'assigned': assigned,
          'days': days == null ? null : (days.toList()..sort()),
        },
        parent: true,
      );

  Future<void> adminDeleteRun(int id) => delete('/api/admin/runs/$id', parent: true);

  Future<List<Extra>> adminExtras() async {
    final json = await get('/api/admin/extras', parent: true);
    return ((json['extras'] as List?) ?? const [])
        .map((e) => Extra.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Creates one extra per date; returns their ids.
  Future<List<int>> adminCreateExtras({
    required int productId,
    required List<String> dates,
    required List<int> addressIds,
    String note = '',
  }) async {
    final json = await post(
      '/api/admin/extras',
      {'product_id': productId, 'dates': dates, 'address_ids': addressIds, 'note': note},
      parent: true,
    );
    return ((json['ids'] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
  }

  Future<void> adminUpdateExtra(int id, {String? date, List<int>? addressIds, String? note}) =>
      put('/api/admin/extras/$id', {'date': ?date, 'address_ids': ?addressIds, 'note': ?note}, parent: true);

  Future<void> adminDeleteExtra(int id) => delete('/api/admin/extras/$id', parent: true);

  void close() => _client.close();
}
