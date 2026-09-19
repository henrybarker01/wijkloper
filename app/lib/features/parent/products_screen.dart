import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../widgets/common.dart';
import 'admin.dart';

class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  void _edit(BuildContext context, Product? product) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ProductEditor(product: product),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = ref.watch(configProvider).config;
    final products = config?.products ?? const <Product>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Papers & folders')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Each paper or insert has the weekdays it normally appears. Houses are linked to '
              'the papers they get; a house can deviate from these days.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
              itemCount: products.length,
              onReorderItem: (oldIndex, newIndex) {
                final ids = products.map((p) => p.id).toList();
                final moved = ids.removeAt(oldIndex);
                ids.insert(newIndex, moved);
                runAdmin(context, ref, (api) => api.adminOrderProducts(ids));
              },
              itemBuilder: (context, index) {
                final product = products[index];
                final used = config?.addresses.where((a) => a.assignmentFor(product.id) != null).length ?? 0;
                return Card(
                  key: ValueKey(product.id),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: ProductChip(product, compact: true),
                    title: Text(product.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      '${product.kind == ProductKind.insert ? 'Insert' : 'Paper'} · ${daysLabel(product.days)} · $used houses',
                    ),
                    trailing: const Icon(Icons.drag_handle),
                    onTap: () => _edit(context, product),
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

class _ProductEditor extends ConsumerStatefulWidget {
  const _ProductEditor({required this.product});

  final Product? product;

  @override
  ConsumerState<_ProductEditor> createState() => _ProductEditorState();
}

class _ProductEditorState extends ConsumerState<_ProductEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.product?.name ?? '');
  late final TextEditingController _code = TextEditingController(text: widget.product?.shortCode ?? '');
  late ProductKind _kind = widget.product?.kind ?? ProductKind.paper;
  late Set<int> _days = Set<int>.of(widget.product?.days ?? {1, 2, 3, 4, 5, 6});
  late String _color = widget.product?.colorHex ?? colorPalette[2];
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    var code = _code.text.trim().toUpperCase();
    if (name.isEmpty) {
      showSnack(context, 'Give it a name.', error: true);
      return;
    }
    if (code.isEmpty) code = name.substring(0, 1).toUpperCase();
    if (_days.isEmpty) {
      showSnack(context, 'Pick at least one weekday.', error: true);
      return;
    }
    setState(() => _busy = true);
    final body = {
      'name': name,
      'short_code': code,
      'color': _color,
      'days': (_days.toList()..sort()),
      'kind': _kind.apiValue,
    };
    final ok = await runAdmin(
      context,
      ref,
      (api) => widget.product == null ? api.adminCreateProduct(body) : api.adminUpdateProduct(widget.product!.id, body),
      success: 'Saved.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final product = widget.product!;
    final ok = await confirm(
      context,
      title: 'Delete ${product.name}?',
      message: 'It is removed from every house. Past runs keep their counts.',
    );
    if (!ok || !mounted) return;
    final done = await runAdmin(context, ref, (api) => api.adminDeleteProduct(product.id), success: '${product.name} deleted.');
    if (done && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(widget.product == null ? 'New paper or insert' : 'Edit ${widget.product!.name}', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _name,
                  autofocus: widget.product == null,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'Barnevelder'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _code,
                  maxLength: 3,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Code', hintText: 'B', counterText: ''),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SegmentedButton<ProductKind>(
            segments: const [
              ButtonSegment(value: ProductKind.paper, label: Text('Newspaper'), icon: Icon(Icons.newspaper)),
              ButtonSegment(value: ProductKind.insert, label: Text('Insert / folders'), icon: Icon(Icons.description_outlined)),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 16),
          Text('Delivered on', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          DayToggleChips(value: _days, onChanged: (v) => setState(() => _days = v)),
          const SizedBox(height: 16),
          Text('Colour', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          ColorPalettePicker(value: _color, onChanged: (v) => setState(() => _color = v)),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
          if (widget.product != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
          ],
        ],
      ),
    );
  }
}
