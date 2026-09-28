import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/schedule.dart';
import '../../widgets/common.dart';
import 'extras_screen.dart';
import 'import_screen.dart';
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
    final today = dateKey(DateTime.now());
    final upcomingExtras = config?.extras.where((e) => e.date.compareTo(today) >= 0).length ?? 0;
    final importStatus = config?.importStatus;
    final String importSummary;
    if (importStatus == null || importStatus.isEmpty) {
      importSummary = 'Nightly check of the subscriber list';
    } else {
      importSummary = switch (importStatus.problem(DateTime.now())) {
        ImportProblem.failed =>
          'Failed ${timeAgo(importStatus.lastAttempt!.ranAt)}: ${importStatus.lastAttempt!.message}',
        ImportProblem.stale => importStatus.lastApplied == null
            ? 'Never imported successfully'
            : 'No check since ${timeAgo(importStatus.lastApplied!.ranAt)}',
        ImportProblem.none => 'Checked ${timeAgo(importStatus.lastApplied!.ranAt)} · '
            '${importStatus.lastChanged == null ? 'no changes yet' : 'last change ${timeAgo(importStatus.lastChanged!.ranAt)}'}',
      };
    }

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
                  leading: const Icon(Icons.star_outline),
                  title: const Text('Extra delivery days'),
                  subtitle: Text(upcomingExtras == 0
                      ? 'A paper to extra houses on specific dates'
                      : '$upcomingExtras upcoming'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(const ExtrasScreen()),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.cloud_download_outlined,
                    color: importStatus != null && importStatus.problem(DateTime.now()) != ImportProblem.none
                        ? theme.colorScheme.error
                        : null,
                  ),
                  title: const Text('Portal import'),
                  subtitle: Text(importSummary),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(const ImportScreen()),
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
            'A house can deviate, e.g. only on Saturday, and extra delivery days add houses on specific dates. '
            'The app works out the rest per day.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
