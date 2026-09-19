import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../widgets/common.dart';
import 'admin.dart';
import 'street_screen.dart';

/// Only shown when the family has more than one route (or wants to add one).
class RoutesScreen extends ConsumerWidget {
  const RoutesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider).config;
    final routes = config?.routes ?? const <RouteInfo>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Routes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final name = await promptText(context, title: 'New route', label: 'Name', confirmLabel: 'Add');
          if (name == null || name.isEmpty || !context.mounted) return;
          await runAdmin(context, ref, (api) => api.adminCreateRoute(name), success: 'Route added.');
        },
        icon: const Icon(Icons.add),
        label: const Text('Add route'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
        children: [
          for (final route in routes)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: const Icon(Icons.route),
                title: Text(route.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                  '${config!.streetsForRoute(route.id).length} streets · ${config.addressCountForRoute(route.id)} houses',
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'rename') {
                      final name = await promptText(context, title: 'Rename route', initial: route.name, label: 'Name');
                      if (name == null || name.isEmpty || !context.mounted) return;
                      await runAdmin(context, ref, (api) => api.adminUpdateRoute(route.id, name));
                    } else if (value == 'delete') {
                      final ok = await confirm(
                        context,
                        title: 'Delete ${route.name}?',
                        message: 'All its streets and house numbers are deleted too.',
                      );
                      if (!ok || !context.mounted) return;
                      await runAdmin(context, ref, (api) => api.adminDeleteRoute(route.id), success: 'Route deleted.');
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => StreetsScreen(routeId: route.id)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class StreetsScreen extends ConsumerWidget {
  const StreetsScreen({super.key, required this.routeId});

  final int routeId;

  Future<void> _addStreet(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<({String name, NumberOrder order})>(
      context: context,
      builder: (_) => const _StreetDialog(),
    );
    if (result == null || !context.mounted) return;
    final id = <int>[];
    final ok = await runAdmin(
      context,
      ref,
      (api) async => id.add(await api.adminCreateStreet(routeId, result.name, result.order)),
      success: '${result.name} added. Now add its house numbers.',
    );
    if (ok && id.isNotEmpty && context.mounted) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => StreetScreen(streetId: id.first)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = ref.watch(configProvider).config;
    final route = config?.routeById(routeId);
    final streets = config?.streetsForRoute(routeId) ?? const <Street>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(route?.name ?? 'Route'),
        actions: [
          if (config != null && config.routes.length <= 1)
            IconButton(
              tooltip: 'Manage routes',
              icon: const Icon(Icons.alt_route),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RoutesScreen())),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addStreet(context, ref),
        icon: const Icon(Icons.add_road),
        label: const Text('Add street'),
      ),
      body: streets.isEmpty
          ? EmptyState(
              icon: Icons.add_road,
              title: 'No streets yet',
              message: 'Add the streets in the order they are walked. Then add house numbers per street.',
              action: FilledButton.icon(
                onPressed: () => _addStreet(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Add the first street'),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text('Drag to change the walking order. Tap a street for its house numbers.',
                      style: theme.textTheme.bodySmall),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
                    itemCount: streets.length,
                    onReorderItem: (oldIndex, newIndex) {
                      final ids = streets.map((s) => s.id).toList();
                      final moved = ids.removeAt(oldIndex);
                      ids.insert(newIndex, moved);
                      runAdmin(context, ref, (api) => api.adminOrderStreets(routeId, ids));
                    },
                    itemBuilder: (context, index) {
                      final street = streets[index];
                      final houses = config!.addressesForStreet(street.id).length;
                      return Card(
                        key: ValueKey(street.id),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: CircleAvatar(child: Text('${index + 1}')),
                          title: Text(street.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('$houses houses · ${street.numberOrder.label}'),
                          trailing: const Icon(Icons.drag_handle),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => StreetScreen(streetId: street.id)),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _StreetDialog extends StatefulWidget {
  const _StreetDialog();

  @override
  State<_StreetDialog> createState() => _StreetDialogState();
}

class _StreetDialogState extends State<_StreetDialog> {
  final _name = TextEditingController();
  NumberOrder _order = NumberOrder.asc;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New street'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Street name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<NumberOrder>(
              initialValue: _order,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Walking order of the numbers'),
              items: [
                for (final o in NumberOrder.values)
                  if (o != NumberOrder.custom)
                    DropdownMenuItem(value: o, child: Text(o.label, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _order = v ?? NumberOrder.asc),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () {
              final name = _name.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(context, (name: name, order: _order));
            },
            child: const Text('Add'),
          ),
        ],
      );
}
