import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/schedule.dart';
import '../../widgets/common.dart';
import 'admin.dart';

/// All house numbers of one street. Tap a house to edit it; long-press (or the
/// checklist icon) to select many houses and give/remove a paper in one go.
class StreetScreen extends ConsumerStatefulWidget {
  const StreetScreen({super.key, required this.streetId});

  final int streetId;

  @override
  ConsumerState<StreetScreen> createState() => _StreetScreenState();
}

class _StreetScreenState extends ConsumerState<StreetScreen> {
  bool _selecting = false;
  final Set<int> _selected = {};

  void _exitSelection() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _addHouses(Street street) async {
    final products = ref.read(configProvider).config?.products ?? const <Product>[];
    final result = await showDialog<_BulkResult>(
      context: context,
      builder: (_) => _BulkAddDialog(products: products),
    );
    if (result == null || !mounted) return;
    if (result.end == null) {
      await runAdmin(
        context,
        ref,
        (api) => api.adminCreateAddress(street.id, {
          'number': result.start,
          'suffix': result.suffix,
          'products': result.products.map((p) => p.toJson()).toList(),
        }),
        success: 'Number ${result.start}${result.suffix} added.',
      );
    } else {
      await runAdmin(
        context,
        ref,
        (api) async {
          final r = await api.adminBulkAddresses(
            street.id,
            start: result.start,
            end: result.end!,
            parity: result.parity,
            products: result.products,
          );
          if (mounted) showSnack(context, '${r.created} added${r.skipped > 0 ? ', ${r.skipped} already existed' : ''}.');
        },
      );
    }
  }

  Future<void> _assignSelected(bool give) async {
    final config = ref.read(configProvider).config;
    if (config == null || _selected.isEmpty) return;
    final choice = await showModalBottomSheet<_AssignChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AssignSheet(products: config.products, give: give, count: _selected.length),
    );
    if (choice == null || !mounted) return;
    final houses = _selected.toList();
    final bool ok;
    if (choice.dates != null) {
      final n = choice.dates!.length;
      ok = await runAdmin(
        context,
        ref,
        (api) => api.adminCreateExtras(
          productId: choice.product.id,
          dates: choice.dates!,
          addressIds: houses,
          note: choice.note,
        ),
        success: 'Extra delivery: ${choice.product.name} to ${houses.length} houses on $n ${n == 1 ? 'date' : 'dates'}.',
      );
    } else {
      ok = await runAdmin(
        context,
        ref,
        (api) => api.adminAssign(
          addressIds: houses,
          productId: choice.product.id,
          assigned: give,
          days: choice.days,
        ),
        success: give
            ? '${choice.product.name} given to ${houses.length} houses.'
            : '${choice.product.name} removed from ${houses.length} houses.',
      );
    }
    if (ok) _exitSelection();
  }

  Future<void> _streetMenu(String value, Street street, List<Address> ordered) async {
    switch (value) {
      case 'rename':
        final name = await promptText(context, title: 'Rename street', initial: street.name, label: 'Name');
        if (name == null || name.isEmpty || !mounted) return;
        await runAdmin(context, ref, (api) => api.adminUpdateStreet(street.id, name: name));
      case 'order':
        final order = await showDialog<NumberOrder>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Walking order of the numbers'),
            children: [
              RadioGroup<NumberOrder>(
                groupValue: street.numberOrder,
                onChanged: (v) => Navigator.pop(context, v),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final o in NumberOrder.values)
                      RadioListTile<NumberOrder>(
                        value: o,
                        enabled: o != NumberOrder.custom,
                        title: Text(o.label),
                        subtitle: o == NumberOrder.custom ? const Text('Set with "Reorder by hand"') : null,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        if (order == null || !mounted) return;
        await runAdmin(context, ref, (api) => api.adminUpdateStreet(street.id, order: order));
      case 'reorder':
        final ids = await Navigator.of(context).push<List<int>>(
          MaterialPageRoute(builder: (_) => _ManualOrderScreen(street: street, addresses: ordered)),
        );
        if (ids == null || !mounted) return;
        await runAdmin(context, ref, (api) => api.adminOrderAddresses(street.id, ids), success: 'Order saved.');
      case 'delete':
        final ok = await confirm(
          context,
          title: 'Delete ${street.name}?',
          message: 'All ${ordered.length} house numbers in it are deleted too.',
        );
        if (!ok || !mounted) return;
        final done = await runAdmin(context, ref, (api) => api.adminDeleteStreet(street.id), success: 'Street deleted.');
        if (done && mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = ref.watch(configProvider).config;
    final street = config?.streetById(widget.streetId);
    if (config == null || street == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.add_road, title: 'Street not found'));
    }
    final ordered = orderAddresses(config.addressesForStreet(street.id), street.numberOrder);

    return Scaffold(
      appBar: AppBar(
        title: Text(street.name),
        leading: _selecting ? IconButton(icon: const Icon(Icons.close), onPressed: _exitSelection) : null,
        actions: [
          IconButton(
            tooltip: _selecting ? 'Select all' : 'Select houses',
            icon: Icon(_selecting ? Icons.select_all : Icons.checklist),
            onPressed: () => setState(() {
              if (_selecting) {
                _selected.length == ordered.length
                    ? _selected.clear()
                    : _selected.addAll(ordered.map((a) => a.id));
              } else {
                _selecting = true;
              }
            }),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _streetMenu(v, street, ordered),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename street')),
              PopupMenuItem(value: 'order', child: Text('Walking order of numbers…')),
              PopupMenuItem(value: 'reorder', child: Text('Reorder by hand…')),
              PopupMenuItem(value: 'delete', child: Text('Delete street')),
            ],
          ),
        ],
      ),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addHouses(street),
              icon: const Icon(Icons.add_home_outlined),
              label: const Text('Add houses'),
            ),
      bottomNavigationBar: _selecting
          ? BottomAppBar(
              child: Row(
                children: [
                  Text('${_selected.length} selected', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: _selected.isEmpty ? null : () => _assignSelected(false),
                    icon: const Icon(Icons.remove_circle_outline),
                    label: const Text('Remove…'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: _selected.isEmpty ? null : () => _assignSelected(true),
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('Give…'),
                  ),
                ],
              ),
            )
          : null,
      body: ordered.isEmpty
          ? EmptyState(
              icon: Icons.add_home_outlined,
              title: 'No house numbers yet',
              message: 'Add a range like 1–60 (all, odd or even) and pick which papers they get.',
              action: FilledButton.icon(
                onPressed: () => _addHouses(street),
                icon: const Icon(Icons.add),
                label: const Text('Add houses'),
              ),
            )
          : Column(
              children: [
                _Legend(products: config.products, order: street.numberOrder, selecting: _selecting),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 96,
                      mainAxisExtent: 76,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: ordered.length,
                    itemBuilder: (context, index) {
                      final address = ordered[index];
                      return _HouseTile(
                        address: address,
                        config: config,
                        selected: _selected.contains(address.id),
                        selecting: _selecting,
                        onTap: () {
                          if (_selecting) {
                            setState(() {
                              _selected.contains(address.id) ? _selected.remove(address.id) : _selected.add(address.id);
                            });
                          } else {
                            showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              showDragHandle: true,
                              builder: (_) => _AddressEditor(address: address),
                            );
                          }
                        },
                        onLongPress: () => setState(() {
                          _selecting = true;
                          _selected.add(address.id);
                        }),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.products, required this.order, required this.selecting});

  final List<Product> products;
  final NumberOrder order;
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final p in products)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Dot(color: p.color, custom: false),
                    const SizedBox(width: 4),
                    Text(p.name, style: theme.textTheme.labelMedium),
                  ],
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Dot(color: theme.colorScheme.onSurface, custom: true),
                  const SizedBox(width: 4),
                  Text('= other days than usual', style: theme.textTheme.labelMedium),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            selecting
                ? 'Tap houses to select them, then choose Give… or Remove… below.'
                : 'Shown in walking order: ${order.label.toLowerCase()}. Tap a house to edit, hold to select many.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.custom});

  final Color color;
  final bool custom;

  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: custom ? Colors.transparent : color,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2.5),
        ),
      );
}

class _HouseTile extends StatelessWidget {
  const _HouseTile({
    required this.address,
    required this.config,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final Address address;
  final AppConfig config;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assignments = [
      for (final p in config.products)
        if (address.assignmentFor(p.id) != null) (product: p, custom: address.assignmentFor(p.id)!.days != null),
    ];
    return Material(
      color: selected ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    address.label,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: address.hasNeeNee ? theme.colorScheme.outline : null,
                      decoration: address.hasNeeNee ? TextDecoration.lineThrough : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (address.hasNeeNee) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.do_not_disturb_on, size: 14, color: theme.colorScheme.error),
                  ] else if (address.note.isNotEmpty) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.sticky_note_2_outlined, size: 14, color: theme.colorScheme.outline),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              if (assignments.isEmpty)
                Text('—', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline))
              else
                Wrap(
                  spacing: 4,
                  children: [for (final a in assignments) _Dot(color: a.product.color, custom: a.custom)],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- add houses ----------------------------------------------------------------------

class _BulkResult {
  const _BulkResult({required this.start, this.end, this.suffix = '', this.parity = 'all', this.products = const []});

  final int start;
  final int? end;
  final String suffix;
  final String parity;
  final List<AddressProduct> products;
}

class _BulkAddDialog extends StatefulWidget {
  const _BulkAddDialog({required this.products});

  final List<Product> products;

  @override
  State<_BulkAddDialog> createState() => _BulkAddDialogState();
}

class _BulkAddDialogState extends State<_BulkAddDialog> {
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _suffix = TextEditingController();
  String _parity = 'all';
  final Set<int> _products = {};

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _suffix.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final single = _end.text.trim().isEmpty;
    return AlertDialog(
      title: const Text('Add houses'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _start,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'From'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _end,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'To', hintText: 'optional'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (single)
              TextField(
                controller: _suffix,
                decoration: const InputDecoration(labelText: 'Suffix (optional)', hintText: 'a, -2, bis'),
              )
            else
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'all', label: Text('All')),
                  ButtonSegment(value: 'odd', label: Text('Odd')),
                  ButtonSegment(value: 'even', label: Text('Even')),
                ],
                selected: {_parity},
                onSelectionChanged: (s) => setState(() => _parity = s.first),
              ),
            const SizedBox(height: 12),
            Text('They get:', style: Theme.of(context).textTheme.labelLarge),
            for (final p in widget.products)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _products.contains(p.id),
                title: Row(children: [ProductChip(p, compact: true), const SizedBox(width: 8), Text(p.name)]),
                subtitle: Text(daysLabel(p.days)),
                onChanged: (v) => setState(() => v == true ? _products.add(p.id) : _products.remove(p.id)),
              ),
            Text('You can fine-tune per house afterwards.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: () {
            final start = int.tryParse(_start.text.trim());
            if (start == null) return;
            final end = int.tryParse(_end.text.trim());
            Navigator.pop(
              context,
              _BulkResult(
                start: start,
                end: end,
                suffix: single ? _suffix.text.trim() : '',
                parity: _parity,
                products: [for (final id in _products) AddressProduct(productId: id)],
              ),
            );
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

// --- give / remove for a selection -----------------------------------------------------

enum _When { usual, weekdays, dates }

class _AssignChoice {
  const _AssignChoice({required this.product, this.days, this.dates, this.note = ''});

  final Product product;

  /// Weekday override for a normal link (null = the product's usual days).
  final Set<int>? days;

  /// When set, this is a one-off extra delivery on these dates instead of a link.
  final List<String>? dates;
  final String note;
}

class _AssignSheet extends StatefulWidget {
  const _AssignSheet({required this.products, required this.give, required this.count});

  final List<Product> products;
  final bool give;
  final int count;

  @override
  State<_AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends State<_AssignSheet> {
  Product? _product;
  _When _when = _When.usual;
  Set<int> _days = {};
  List<String> _dates = [];
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (_product == null) return false;
    if (!widget.give) return true;
    switch (_when) {
      case _When.usual:
        return true;
      case _When.weekdays:
        return _days.isNotEmpty;
      case _When.dates:
        return _dates.isNotEmpty;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(
            widget.give ? 'Give ${widget.count} houses…' : 'Remove from ${widget.count} houses…',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          RadioGroup<Product>(
            groupValue: _product,
            onChanged: (v) => setState(() {
              _product = v;
              _days = Set<int>.of(v?.days ?? {});
            }),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final p in widget.products)
                  RadioListTile<Product>(
                    value: p,
                    title: Row(children: [ProductChip(p, compact: true), const SizedBox(width: 8), Text(p.name)]),
                    subtitle: Text('normally ${daysLabel(p.days)}'),
                  ),
              ],
            ),
          ),
          if (widget.give && _product != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<_When>(
                segments: const [
                  ButtonSegment(value: _When.usual, label: Text('Usual')),
                  ButtonSegment(value: _When.weekdays, label: Text('Weekdays')),
                  ButtonSegment(value: _When.dates, label: Text('Dates')),
                ],
                selected: {_when},
                onSelectionChanged: (s) => setState(() => _when = s.first),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              switch (_when) {
                _When.usual => 'These houses get ${_product!.name} on its usual days (${daysLabel(_product!.days)}).',
                _When.weekdays => 'These houses get ${_product!.name} only on the weekdays you pick, every week.',
                _When.dates => 'One-off extra delivery on specific dates. The houses keep their normal papers; on those dates ${_product!.name} is added.',
              },
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_when == _When.weekdays)
              DayToggleChips(value: _days, onChanged: (v) => setState(() => _days = v)),
            if (_when == _When.dates) ...[
              DateChips(dates: _dates, onChanged: (v) => setState(() => _dates = v)),
              const SizedBox(height: 8),
              TextField(
                controller: _note,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'Special edition'),
              ),
            ],
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: !_canSubmit
                ? null
                : () => Navigator.pop(
                      context,
                      _AssignChoice(
                        product: _product!,
                        days: widget.give && _when == _When.weekdays ? _days : null,
                        dates: widget.give && _when == _When.dates ? _dates : null,
                        note: _note.text.trim(),
                      ),
                    ),
            child: Text(widget.give ? (_when == _When.dates ? 'Add extra delivery' : 'Give') : 'Remove'),
          ),
        ],
      ),
    );
  }
}

// --- single address editor -----------------------------------------------------------------

class _AddressEditor extends ConsumerStatefulWidget {
  const _AddressEditor({required this.address});

  final Address address;

  @override
  ConsumerState<_AddressEditor> createState() => _AddressEditorState();
}

class _AddressEditorState extends ConsumerState<_AddressEditor> {
  late final TextEditingController _number = TextEditingController(text: '${widget.address.number}');
  late final TextEditingController _suffix = TextEditingController(text: widget.address.suffix);
  late final TextEditingController _note = TextEditingController(text: widget.address.note);

  /// product id -> days override (null = product default). Absent = not assigned.
  late final Map<int, Set<int>?> _assigned = {
    for (final ap in widget.address.products) ap.productId: ap.days == null ? null : Set<int>.of(ap.days!),
  };
  late bool _neeNee = widget.address.hasNeeNee;
  bool _busy = false;

  @override
  void dispose() {
    _number.dispose();
    _suffix.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final number = int.tryParse(_number.text.trim());
    if (number == null) {
      showSnack(context, 'Enter a house number.', error: true);
      return;
    }
    setState(() => _busy = true);
    final ok = await runAdmin(
      context,
      ref,
      (api) => api.adminUpdateAddress(widget.address.id, {
        'number': number,
        'suffix': _suffix.text.trim(),
        'note': _note.text.trim(),
        'sticker': _neeNee ? kStickerNeeNee : '',
        'products': [
          for (final e in _assigned.entries)
            {'product_id': e.key, 'days': e.value == null ? null : (e.value!.toList()..sort())},
        ],
      }),
      success: 'Saved.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Delete number ${widget.address.label}?',
      message: 'It disappears from the route.',
    );
    if (!ok || !mounted) return;
    final done = await runAdmin(context, ref, (api) => api.adminDeleteAddress(widget.address.id), success: 'Deleted.');
    if (done && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final products = ref.watch(configProvider).config?.products ?? const <Product>[];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text('House ${widget.address.label}', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _number,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Number'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(controller: _suffix, decoration: const InputDecoration(labelText: 'Suffix')),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Note for the kid', hintText: 'Big dog! / letterbox at the side'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Nee/Nee sticker on the door'),
            subtitle: const Text('The house is skipped on every round while this is on'),
            value: _neeNee,
            onChanged: (v) => setState(() => _neeNee = v),
          ),
          const SizedBox(height: 4),
          Text('Gets', style: theme.textTheme.labelLarge),
          for (final p in products) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Row(children: [ProductChip(p, compact: true), const SizedBox(width: 8), Text(p.name)]),
              subtitle: Text(
                !_assigned.containsKey(p.id)
                    ? 'no'
                    : _assigned[p.id] == null
                        ? 'on the usual days (${daysLabel(p.days)})'
                        : 'only ${daysLabel(_assigned[p.id]!)}',
              ),
              value: _assigned.containsKey(p.id),
              onChanged: (v) => setState(() => v ? _assigned[p.id] = null : _assigned.remove(p.id)),
            ),
            if (_assigned.containsKey(p.id))
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _assigned[p.id] = _assigned[p.id] == null ? Set<int>.of(p.days) : null;
                      }),
                      child: Text(_assigned[p.id] == null ? 'Other days…' : 'Use usual days'),
                    ),
                    if (_assigned[p.id] != null)
                      Expanded(
                        child: DayToggleChips(
                          value: _assigned[p.id]!,
                          onChanged: (v) => setState(() => _assigned[p.id] = v),
                        ),
                      ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
          const SizedBox(height: 8),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete this house'),
          ),
        ],
      ),
    );
  }
}

// --- manual order -----------------------------------------------------------------------------

class _ManualOrderScreen extends StatefulWidget {
  const _ManualOrderScreen({required this.street, required this.addresses});

  final Street street;
  final List<Address> addresses;

  @override
  State<_ManualOrderScreen> createState() => _ManualOrderScreenState();
}

class _ManualOrderScreenState extends State<_ManualOrderScreen> {
  late final List<Address> _items = List<Address>.of(widget.addresses);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('Order in ${widget.street.name}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _items.map((a) => a.id).toList()),
              child: const Text('Save'),
            ),
          ],
        ),
        body: ReorderableListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: _items.length,
          onReorderItem: (oldIndex, newIndex) => setState(() {
            _items.insert(newIndex, _items.removeAt(oldIndex));
          }),
          itemBuilder: (context, index) => ListTile(
            key: ValueKey(_items[index].id),
            leading: Text('${index + 1}.'),
            title: Text(_items[index].label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
            trailing: const Icon(Icons.drag_handle),
          ),
        ),
      );
}
