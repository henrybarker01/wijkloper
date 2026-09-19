import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../widgets/common.dart';
import 'admin.dart';

class KidsScreen extends ConsumerWidget {
  const KidsScreen({super.key});

  void _edit(BuildContext context, Kid? kid) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _KidEditor(kid: kid),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider).config;
    final kids = config?.kids ?? const <Kid>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Kids')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Add kid'),
      ),
      body: kids.isEmpty
          ? const EmptyState(
              icon: Icons.child_care,
              title: 'No kids yet',
              message: 'Add each child who delivers. Times and personal bests are kept per kid.',
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
              itemCount: kids.length,
              onReorderItem: (oldIndex, newIndex) {
                final ids = kids.map((k) => k.id).toList();
                final moved = ids.removeAt(oldIndex);
                ids.insert(newIndex, moved);
                runAdmin(context, ref, (api) => api.adminOrderKids(ids));
              },
              itemBuilder: (context, index) {
                final kid = kids[index];
                final route = config?.routeById(kid.defaultRouteId);
                return Card(
                  key: ValueKey(kid.id),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: KidAvatar(kid),
                    title: Text(kid.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(route == null ? 'Walks the first route' : 'Walks ${route.name}'),
                    trailing: const Icon(Icons.drag_handle),
                    onTap: () => _edit(context, kid),
                  ),
                );
              },
            ),
    );
  }
}

class _KidEditor extends ConsumerStatefulWidget {
  const _KidEditor({required this.kid});

  final Kid? kid;

  @override
  ConsumerState<_KidEditor> createState() => _KidEditorState();
}

class _KidEditorState extends ConsumerState<_KidEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.kid?.name ?? '');
  late String _emoji = widget.kid?.displayEmoji ?? kidEmojis.first;
  late String _color = widget.kid?.colorHex ?? colorPalette.first;
  late int? _routeId = widget.kid?.defaultRouteId;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showSnack(context, 'Give the kid a name.', error: true);
      return;
    }
    setState(() => _busy = true);
    final body = {'name': name, 'emoji': _emoji, 'color': _color, 'default_route_id': _routeId};
    final ok = await runAdmin(
      context,
      ref,
      (api) => widget.kid == null ? api.adminCreateKid(body) : api.adminUpdateKid(widget.kid!.id, body),
      success: widget.kid == null ? '$name added.' : 'Saved.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final kid = widget.kid!;
    final ok = await confirm(
      context,
      title: 'Remove ${kid.name}?',
      message: 'Past runs are kept for the leaderboard, but ${kid.name} disappears from the app.',
      confirmLabel: 'Remove',
    );
    if (!ok || !mounted) return;
    final done = await runAdmin(context, ref, (api) => api.adminDeleteKid(kid.id), success: '${kid.name} removed.');
    if (done && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final routes = ref.watch(configProvider).config?.routes ?? const <RouteInfo>[];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(widget.kid == null ? 'New kid' : 'Edit ${widget.kid!.name}', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: widget.kid == null,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 16),
          Text('Avatar', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          EmojiPicker(value: _emoji, onChanged: (v) => setState(() => _emoji = v)),
          const SizedBox(height: 16),
          Text('Colour', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          ColorPalettePicker(value: _color, onChanged: (v) => setState(() => _color = v)),
          if (routes.length > 1) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<int?>(
              initialValue: routes.any((r) => r.id == _routeId) ? _routeId : null,
              decoration: const InputDecoration(labelText: 'Route'),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('First route')),
                for (final r in routes) DropdownMenuItem<int?>(value: r.id, child: Text(r.name)),
              ],
              onChanged: (v) => setState(() => _routeId = v),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
          if (widget.kid != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove kid'),
            ),
          ],
        ],
      ),
    );
  }
}
