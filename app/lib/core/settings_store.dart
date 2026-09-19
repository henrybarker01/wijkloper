import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// How this phone talks to the family server.
class ConnectionSettings {
  const ConnectionSettings({
    required this.serverUrl,
    required this.deviceToken,
    required this.deviceName,
    this.familyName = '',
  });

  final String serverUrl;
  final String deviceToken;
  final String deviceName;
  final String familyName;

  ConnectionSettings copyWith({String? serverUrl, String? familyName}) => ConnectionSettings(
        serverUrl: serverUrl ?? this.serverUrl,
        deviceToken: deviceToken,
        deviceName: deviceName,
        familyName: familyName ?? this.familyName,
      );
}

/// Small key/value settings kept in SharedPreferences.
class SettingsStore {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _serverUrl = 'server_url';
  static const _deviceToken = 'device_token';
  static const _deviceName = 'device_name';
  static const _familyName = 'family_name';
  static const _selectedKid = 'selected_kid_id';
  static const _parentSession = 'parent_session';
  static const _keepScreenOn = 'keep_screen_on';
  static const _haptics = 'haptics';

  ConnectionSettings? get connection {
    final url = _prefs.getString(_serverUrl);
    final token = _prefs.getString(_deviceToken);
    if (url == null || token == null) return null;
    return ConnectionSettings(
      serverUrl: url,
      deviceToken: token,
      deviceName: _prefs.getString(_deviceName) ?? 'Phone',
      familyName: _prefs.getString(_familyName) ?? '',
    );
  }

  Future<void> saveConnection(ConnectionSettings c) async {
    await _prefs.setString(_serverUrl, c.serverUrl);
    await _prefs.setString(_deviceToken, c.deviceToken);
    await _prefs.setString(_deviceName, c.deviceName);
    await _prefs.setString(_familyName, c.familyName);
  }

  Future<void> clearConnection() async {
    await _prefs.remove(_serverUrl);
    await _prefs.remove(_deviceToken);
    await _prefs.remove(_familyName);
    await _prefs.remove(_parentSession);
  }

  int? get selectedKidId => _prefs.getInt(_selectedKid);
  Future<void> setSelectedKidId(int? id) async =>
      id == null ? _prefs.remove(_selectedKid) : _prefs.setInt(_selectedKid, id);

  ParentSession? get parentSession {
    final raw = _prefs.getString(_parentSession);
    if (raw == null) return null;
    try {
      return ParentSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> setParentSession(ParentSession? session) async => session == null
      ? _prefs.remove(_parentSession)
      : _prefs.setString(_parentSession, jsonEncode(session.toJson()));

  bool get keepScreenOn => _prefs.getBool(_keepScreenOn) ?? true;
  Future<void> setKeepScreenOn(bool value) => _prefs.setBool(_keepScreenOn, value);

  bool get haptics => _prefs.getBool(_haptics) ?? true;
  Future<void> setHaptics(bool value) => _prefs.setBool(_haptics, value);
}
