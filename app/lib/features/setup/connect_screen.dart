import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/defaults.dart';
import '../../core/discovery.dart';
import '../../core/providers.dart';
import '../../core/settings_store.dart';

/// First-run flow. By default the phone talks to the family server on the
/// internet, so all a kid has to do is type the family code. Parents can point
/// the app at another server (e.g. a Raspberry Pi on the home Wi-Fi) under
/// "Use a different server".
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _urlController = TextEditingController();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController(text: 'My phone');

  ServerInfo? _server;
  bool _probingDefault = true;
  bool _showAdvanced = false;
  bool _scanning = false;
  double _progress = 0;
  final List<ServerInfo> _found = [];
  bool _checking = false;
  bool _pairing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _probeDefault();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  String get _targetUrl => _server?.url ?? defaultServerUrl;
  String get _targetHost => Uri.tryParse(_targetUrl)?.host ?? _targetUrl;
  bool get _usingDefault => _targetUrl == defaultServerUrl;

  Future<void> _probeDefault() async {
    setState(() {
      _probingDefault = true;
      _error = null;
    });
    final info = await ApiClient.probe(defaultServerUrl, timeout: const Duration(seconds: 6));
    if (!mounted) return;
    setState(() {
      _probingDefault = false;
      if (info != null && (_server == null || _usingDefault)) _server = info;
    });
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _progress = 0;
      _found.clear();
      _error = null;
    });
    final results = await LanDiscovery().scan(
      onProgress: (done, total) {
        if (mounted) setState(() => _progress = done / total);
      },
      onFound: (server) {
        if (mounted) setState(() => _found.add(server));
      },
    );
    if (!mounted) return;
    setState(() {
      _scanning = false;
      if (results.length == 1) _select(results.first);
      if (results.isEmpty) _error = 'No server found on this Wi-Fi. You can type its address below.';
    });
  }

  void _select(ServerInfo server) {
    _server = server;
    _urlController.text = server.url;
    _error = null;
  }

  Future<void> _checkTyped() async {
    final url = normalizeServerUrl(_urlController.text);
    if (url.isEmpty) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final info = await ApiClient.probe(url, timeout: const Duration(seconds: 6));
    if (!mounted) return;
    setState(() {
      _checking = false;
      if (info == null) {
        _error = 'No Wijkloper server answered at $url.';
      } else {
        _select(info);
      }
    });
  }

  Future<void> _pair() async {
    final server = _server;
    if (server == null) return;
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the family code.');
      return;
    }
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      final api = ApiClient(baseUrl: server.url);
      final result = await api.pair(pairingCode: code, deviceName: _nameController.text.trim());
      final deviceName = _nameController.text.trim().isEmpty ? 'Phone' : _nameController.text.trim();
      await ref.read(connectionProvider.notifier).save(
            ConnectionSettings(
              serverUrl: server.url,
              deviceToken: result.deviceToken,
              deviceName: deviceName,
              familyName: result.familyName,
            ),
          );
      // The root widget switches to the home screen when the connection appears.
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final serverOk = _server != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect this phone')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Wijkloper keeps the paper route on the family server. Enter the family code once and this phone is set.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: _probingDefault && _usingDefault
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Icon(
                      serverOk ? Icons.cloud_done : Icons.cloud_off,
                      color: serverOk ? theme.colorScheme.primary : theme.colorScheme.error,
                    ),
              title: Text(_targetHost, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                serverOk
                    ? (_server!.familyName.isEmpty ? 'Wijkloper server' : _server!.familyName)
                    : _probingDefault
                        ? 'Checking…'
                        : 'Not reachable. Check the internet connection.',
              ),
              trailing: !serverOk && !_probingDefault && _usingDefault
                  ? TextButton(onPressed: _probeDefault, child: const Text('Retry'))
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Pair this phone', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(fontSize: 24, letterSpacing: 6, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      labelText: 'Family code',
                      helperText: 'Ask a parent for the code',
                    ),
                    onSubmitted: (_) => _pair(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nameController,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(labelText: 'Name of this phone', hintText: "Sam's phone"),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _pairing || !serverOk ? null : _pair,
                    icon: const Icon(Icons.link),
                    label: Text(_pairing ? 'Pairing…' : 'Pair this phone'),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
            icon: Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more),
            label: Text(_showAdvanced ? 'Hide server options' : 'Use a different server'),
          ),
          if (_showAdvanced)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Server on the home Wi-Fi', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: _scanning ? null : _scan,
                      icon: const Icon(Icons.wifi_find),
                      label: Text(_scanning ? 'Searching…' : 'Search on this Wi-Fi'),
                    ),
                    if (_scanning) ...[
                      const SizedBox(height: 10),
                      LinearProgressIndicator(value: _progress),
                    ],
                    for (final server in _found)
                      ListTile(
                        leading: Icon(
                          _server?.url == server.url ? Icons.radio_button_checked : Icons.radio_button_off,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(server.familyName.isEmpty ? 'Wijkloper server' : server.familyName),
                        subtitle: Text(server.url),
                        onTap: () => setState(() => _select(server)),
                      ),
                    const SizedBox(height: 16),
                    Text('Or type an address', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _urlController,
                            keyboardType: TextInputType.url,
                            decoration: const InputDecoration(hintText: 'example.org or 192.168.1.50'),
                            onSubmitted: (_) => _checkTyped(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                          onPressed: _checking ? null : _checkTyped,
                          child: Text(_checking ? '…' : 'Check'),
                        ),
                      ],
                    ),
                    if (!_usingDefault) ...[
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => setState(() {
                          _server = null;
                          _urlController.clear();
                          _probeDefault();
                        }),
                        child: Text('Back to ${Uri.parse(defaultServerUrl).host}'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
