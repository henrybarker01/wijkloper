import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_client.dart';

/// Finds Wijkloper servers on the phone's Wi-Fi by probing every address in the
/// phone's own /24 subnet(s) on the server port. Takes a few seconds at most.
class LanDiscovery {
  LanDiscovery({this.port = 8000, this.concurrency = 40, this.probeTimeout = const Duration(milliseconds: 900)});

  final int port;
  final int concurrency;
  final Duration probeTimeout;

  /// "192.168.1" style prefixes for every non-loopback IPv4 interface.
  static Future<List<String>> localPrefixes() async {
    final prefixes = <String>{};
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final parts = addr.address.split('.');
          if (parts.length == 4) prefixes.add(parts.sublist(0, 3).join('.'));
        }
      }
    } catch (_) {
      // Some Android builds refuse interface listing; fall back to common home subnets.
    }
    if (prefixes.isEmpty) prefixes.addAll(['192.168.1', '192.168.0', '192.168.178']);
    return prefixes.toList();
  }

  Future<List<ServerInfo>> scan({
    void Function(int done, int total)? onProgress,
    void Function(ServerInfo server)? onFound,
  }) async {
    final prefixes = await localPrefixes();
    final candidates = <String>[
      for (final prefix in prefixes)
        for (var i = 1; i <= 254; i++) 'http://$prefix.$i:$port',
    ];
    final found = <ServerInfo>[];
    final client = http.Client();
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (next < candidates.length) {
        final url = candidates[next++];
        final info = await ApiClient.probe(url, timeout: probeTimeout, client: client);
        done++;
        if (info != null) {
          found.add(info);
          onFound?.call(info);
        }
        onProgress?.call(done, candidates.length);
      }
    }

    try {
      await Future.wait(List.generate(concurrency, (_) => worker()));
    } finally {
      client.close();
    }
    found.sort((a, b) => a.url.compareTo(b.url));
    return found;
  }
}
