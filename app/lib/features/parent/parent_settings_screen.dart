import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../../widgets/common.dart';
import 'admin.dart';

class ParentSettingsScreen extends ConsumerStatefulWidget {
  const ParentSettingsScreen({super.key});

  @override
  ConsumerState<ParentSettingsScreen> createState() => _ParentSettingsScreenState();
}

class _ParentSettingsScreenState extends ConsumerState<ParentSettingsScreen> {
  String? _familyName;
  String? _pairingCode;
  bool _showCode = false;
  List<DeviceInfo> _devices = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    if (api == null) return;
    try {
      final settings = await api.adminSettings();
      final devices = await api.adminDevices();
      if (!mounted) return;
      setState(() {
        _familyName = settings['family_name'] as String?;
        _pairingCode = settings['pairing_code'] as String?;
        _devices = devices;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _changePin() async {
    final first = await promptText(context, title: 'New parent PIN', label: 'At least 4 digits', obscure: true, keyboardType: TextInputType.number, confirmLabel: 'Next');
    if (first == null || !mounted) return;
    if (first.length < 4) {
      showSnack(context, 'Use at least 4 digits.', error: true);
      return;
    }
    final second = await promptText(context, title: 'Repeat the new PIN', obscure: true, keyboardType: TextInputType.number);
    if (second == null || !mounted) return;
    if (first != second) {
      showSnack(context, 'The PINs do not match.', error: true);
      return;
    }
    await runAdmin(context, ref, (api) => api.adminUpdateSettings(newPin: first), success: 'PIN changed.', refresh: false);
  }

  Future<void> _setCode(String code) async {
    final ok = await runAdmin(context, ref, (api) => api.adminUpdateSettings(pairingCode: code), success: 'Pairing code changed.', refresh: false);
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: ListTile(leading: const Icon(Icons.error_outline), title: Text(_error!)),
              ),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.family_restroom),
                    title: const Text('Family name'),
                    subtitle: Text(_familyName ?? '…'),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () async {
                      final name = await promptText(context, title: 'Family name', initial: _familyName, label: 'Shown on every phone');
                      if (name == null || name.isEmpty || !context.mounted) return;
                      final ok = await runAdmin(context, ref, (api) => api.adminUpdateSettings(familyName: name), success: 'Saved.');
                      if (ok) _load();
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.pin_outlined),
                    title: const Text('Parent PIN'),
                    subtitle: const Text('Needed to enter Parent mode on any phone'),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: _changePin,
                  ),
                ],
              ),
            ),
            const SectionHeader('Pairing code'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('New phones enter this code once to join the family server.', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _pairingCode == null ? '……' : (_showCode ? _pairingCode! : '••••••'),
                            style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 6),
                          ),
                        ),
                        IconButton(
                          icon: Icon(_showCode ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _showCode = !_showCode),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final code = await promptText(context, title: 'New pairing code', label: '4–20 characters', initial: _pairingCode, keyboardType: TextInputType.number);
                              if (code == null || code.length < 4 || !context.mounted) return;
                              await _setCode(code);
                            },
                            child: const Text('Choose code'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _setCode('${Random.secure().nextInt(900000) + 100000}'),
                            child: const Text('Random code'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SectionHeader('Paired phones'),
            Card(
              child: Column(
                children: [
                  if (_devices.isEmpty) const ListTile(title: Text('No phones paired yet')),
                  for (final d in _devices)
                    ListTile(
                      leading: const Icon(Icons.smartphone),
                      title: Text(d.name),
                      subtitle: Text('Last seen ${timeAgo(d.lastSeenAt)}'),
                      trailing: IconButton(
                        tooltip: 'Remove phone',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final ok = await confirm(
                            context,
                            title: 'Remove ${d.name}?',
                            message: 'That phone must pair again with the code before it can sync.',
                            confirmLabel: 'Remove',
                          );
                          if (!ok || !context.mounted) return;
                          final done = await runAdmin(context, ref, (api) => api.adminDeleteDevice(d.id), refresh: false);
                          if (done) _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
            const SectionHeader('Server'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(connection?.serverUrl ?? '—'),
                subtitle: const Text('The family server this phone talks to.'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
