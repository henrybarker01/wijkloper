import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../widgets/common.dart';
import 'kids_screen.dart';
import 'parent_settings_screen.dart';
import 'products_screen.dart';
import 'streets_screen.dart';

class ParentHome extends ConsumerWidget {
  const ParentHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final configState = ref.watch(configProvider);
    final config = configState.config;
    final streetCount = config?.streets.length ?? 0;
    final houseCount = config?.addresses.length ?? 0;

    void open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Parent mode'),
        actions: [
          IconButton(
            tooltip: 'Lock parent mode',
            icon: const Icon(Icons.lock_open),
            onPressed: () async {
              await ref.read(parentSessionProvider.notifier).logout();
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (configState.offline)
            Card(
              color: theme.colorScheme.errorContainer,
              child: const ListTile(
                leading: Icon(Icons.cloud_off),
                title: Text('Server not reachable'),
                subtitle: Text('Changes need the server. Check the internet connection.'),
              ),
            ),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.child_care),
                  title: const Text('Kids'),
                  subtitle: Text(config == null || config.kids.isEmpty
                      ? 'Add the children who deliver'
                      : config.kids.map((k) => k.name).join(', ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(const KidsScreen()),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.newspaper),
                  title: const Text('Papers & folders'),
                  subtitle: Text(config == null || config.products.isEmpty
                      ? 'What gets delivered on which days'
                      : config.products.map((p) => '${p.name} (${daysLabel(p.days)})').join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(const ProductsScreen()),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.route),
                  title: const Text('Route, streets & house numbers'),
                  subtitle: Text('$streetCount ${streetCount == 1 ? 'street' : 'streets'} · $houseCount houses'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (config != null && config.routes.length == 1) {
                      open(StreetsScreen(routeId: config.routes.first.id));
                    } else {
                      open(const RoutesScreen());
                    }
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.settings),
                  title: const Text('Settings'),
                  subtitle: const Text('Family name, PIN, pairing code, phones'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(const ParentSettingsScreen()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'How it fits together: every house is linked to the papers it gets. '
            'Papers have their own weekdays (Barnevelder Mon–Sat, Folders and De Week on Thursday). '
            'A house can deviate, e.g. only on Saturday. The app works out the rest per day.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
