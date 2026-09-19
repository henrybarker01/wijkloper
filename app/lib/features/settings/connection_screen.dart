import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../widgets/common.dart';

/// Kid-accessible connection status and phone settings.
class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  bool _syncing = false;

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    final ok = await ref.read(configProvider.notifier).refresh();
    await ref.read(runSyncProvider.notifier).sync();
    if (!mounted) return;
    setState(() => _syncing = false);
    showSnack(context, ok ? 'Up to date.' : (ref.read(configProvider).error ?? 'Could not reach the server.'), error: !ok);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionProvider);
    final configState = ref.watch(configProvider);
    final sync = ref.watch(runSyncProvider);
    final settings = ref.watch(settingsStoreProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Connection & phone')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    configState.offline ? Icons.cloud_off : Icons.cloud_done,
                    color: configState.offline ? theme.colorScheme.error : theme.colorScheme.primary,
                  ),
                  title: Text(configState.offline ? 'Server not reachable' : 'Connected'),
                  subtitle: Text(connection?.serverUrl ?? '—'),
                ),
                ListTile(
                  leading: const Icon(Icons.family_restroom),
                  title: Text(connection?.familyName.isNotEmpty == true ? connection!.familyName : 'Family server'),
                  subtitle: Text('This phone: ${connection?.deviceName ?? '—'}'),
                ),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text('Route last synced ${timeAgo(configState.lastSync)}'),
                  subtitle: Text(
                    configState.config == null
                        ? 'No route on this phone yet'
                        : 'Route version ${configState.config!.version} · ${configState.config!.addresses.length} houses',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.upload_outlined),
                  title: Text(
                    sync.pending.isEmpty
                        ? 'All runs uploaded'
                        : '${sync.pending.length} ${sync.pending.length == 1 ? 'run' : 'runs'} waiting to upload',
                  ),
                  subtitle: sync.lastError == null ? null : Text(sync.lastError!),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: FilledButton.tonalIcon(
                    onPressed: _syncing ? null : _syncNow,
                    icon: const Icon(Icons.sync),
                    label: Text(_syncing ? 'Syncing…' : 'Sync now'),
                  ),
                ),
              ],
            ),
          ),
          const SectionHeader('During the route'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Keep the screen on'),
                  subtitle: const Text('While a run is in progress'),
                  value: settings.keepScreenOn,
                  onChanged: (v) async {
                    await settings.setKeepScreenOn(v);
                    setState(() {});
                  },
                ),
                SwitchListTile(
                  title: const Text('Vibrate when ticking a house'),
                  value: settings.haptics,
                  onChanged: (v) async {
                    await settings.setHaptics(v);
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SectionHeader('Danger zone'),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: () async {
              final ok = await confirm(
                context,
                title: 'Disconnect this phone?',
                message: 'You will need the family pairing code to connect again. '
                    'Runs that are still waiting to upload stay on the phone.',
                confirmLabel: 'Disconnect',
              );
              if (!ok || !context.mounted) return;
              await ref.read(parentSessionProvider.notifier).expire();
              await ref.read(connectionProvider.notifier).disconnect();
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            },
            icon: const Icon(Icons.link_off),
            label: const Text('Disconnect from the server'),
          ),
        ],
      ),
    );
  }
}
