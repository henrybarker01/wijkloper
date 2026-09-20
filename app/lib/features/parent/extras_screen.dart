import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/schedule.dart';
import '../../widgets/common.dart';
import 'admin.dart';

/// Extra delivery days: on specific dates a paper also goes to houses that
/// don't normally get it (a special edition, a promotion, …).
class ExtrasScreen extends ConsumerStatefulWidget {
  const ExtrasScreen({super.key});

  @override
  ConsumerState<ExtrasScreen> createState() => _ExtrasScreenState();
}

class _ExtrasScreenState extends ConsumerState<ExtrasScreen> {
  List<Extra>? _extras;
  bool _showPast = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<Extra>? loaded;
    await runAdmin(context, ref, (api) async => loaded = await api.adminExtras(), refresh: false);
    if (mounted && loaded != null) setState(() => _extras = loaded);
  }

  Future<void> _openEditor(Extra? extra) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ExtraEditorScreen(extra: extra)),
    );
    if (changed == true) _load();
  }

  Future<void> _delete(Extra extra, Product? product) async {
    final ok = await confirm(
      context,
      title: 'Remove this extra delivery?',
      message: '${product?.name ?? 'The paper'} will no longer go to the ${extra.addressIds.length} extra houses on ${longDate(extra.date)}.',
      confirmLabel: 'Remove',
    );
    if (!ok || !mounted) return;
    final done = await runAdmin(context, ref, (api) => api.adminDeleteExtra(extra.id), success: 'Removed.');
    if (done) _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = ref.watch(configProvider).config;
    final today = dateKey(DateTime.now());
    final all = _extras ?? config?.extras ?? const <Extra>[];
    final upcoming = all.where((e) => e.date.compareTo(today) >= 0).toList();
    final past = all.where((e) => e.date.compareTo(today) < 0).toList()..sort((a, b) => b.date.compareTo(a.date));

    Widget tile(Extra extra, {bool dim = false}) {
      final product = config?.productById(extra.productId);
      return Opacity(
        opacity: dim ? 0.55 : 1,
        child: Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.star_rounded, color: Colors.amber),
            title: Text(longDate(extra.date), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (product != null) ProductChip(product, compact: true),
                  Text('${extra.addressIds.length} extra ${extra.addressIds.length == 1 ? 'house' : 'houses'}'),
                  if (extra.note.isNotEmpty) Text(extra.note, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(extra, product)),
            onTap: () => _openEditor(extra),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Extra delivery days')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(null),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                'On these dates a paper also goes to houses that do not normally get it. '
                'The kids see those houses with a star, and the packing count includes them.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (upcoming.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: EmptyState(
                  icon: Icons.star_outline,
                  title: 'No extra delivery days planned',
                  message: 'Tap Add to pick a paper, one or more dates and the extra houses.',
                ),
              ),
            for (final extra in upcoming) tile(extra),
            if (past.isNotEmpty) ...[
              TextButton.icon(
                onPressed: () => setState(() => _showPast = !_showPast),
                icon: Icon(_showPast ? Icons.expand_less : Icons.expand_more),
                label: Text('${past.length} past'),
              ),
              if (_showPast) for (final extra in past) tile(extra, dim: true),
            ],
          ],
        ),
      ),
    );
  }
}

class ExtraEditorScreen extends ConsumerStatefulWidget {
  const ExtraEditorScreen({super.key, this.extra, this.initialAddressIds = const {}, this.initialProductId});

  final Extra? extra;
  final Set<int> initialAddressIds;
  final int? initialProductId;

  @override
  ConsumerState<ExtraEditorScreen> createState() => _ExtraEditorScreenState();
}

class _ExtraEditorScreenState extends ConsumerState<ExtraEditorScreen> {
  int? _productId;
  List<String> _dates = [];
  late Set<int> _selected = Set<int>.of(widget.extra?.addressIds ?? widget.initialAddressIds);
  late final TextEditingController _note = TextEditingController(text: widget.extra?.note ?? '');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _productId = widget.extra?.productId ?? widget.initialProductId;
    if (widget.extra != null) _dates = [widget.extra!.date];
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// True when [address] gets the product on every chosen date anyway.
  bool _alreadyGetsIt(AppConfig config, Address address) {
    if (_productId == null || _dates.isEmpty) return false;
    for (final d in _dates) {
      final date = DateTime.tryParse(d);
      if (date == null) return false;
      final today = productsFor(config, address, date);
      final normal = today.products.any((p) => p.id == _productId) && !today.extraIds.contains(_productId);
      if (!normal) return false;
    }
    return true;
  }

  Future<void> _save() async {
    final productId = _productId;
    if (productId == null) {
      showSnack(context, 'Pick a paper.', error: true);
      return;
    }
    if (_dates.isEmpty) {
      showSnack(context, 'Pick at least one date.', error: true);
      return;
    }
    if (_selected.isEmpty) {
      showSnack(context, 'Pick at least one house.', error: true);
      return;
    }
    setState(() => _busy = true);
    final ok = await runAdmin(
      context,
      ref,
      (api) => widget.extra == null
          ? api.adminCreateExtras(productId: productId, dates: _dates, addressIds: _selected.toList(), note: _note.text.trim())
          : api.adminUpdateExtra(widget.extra!.id, date: _dates.first, addressIds: _selected.toList(), note: _note.text.trim()),
      success: 'Saved.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = ref.watch(configProvider).config;
    if (config == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.cloud_off, title: 'Route not loaded'));
    }
    final product = _productId == null ? null : config.productById(_productId!);
    final editing = widget.extra != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit extra delivery' : 'New extra delivery'),
        actions: [
          TextButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text('Which paper?', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in config.products)
                ChoiceChip(
                  label: Text(p.name),
                  avatar: CircleAvatar(backgroundColor: p.color, radius: 8),
                  selected: p.id == _productId,
                  onSelected: editing ? null : (_) => setState(() => _productId = p.id),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(editing ? 'On which date?' : 'On which dates?', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          DateChips(dates: _dates, single: editing, onChanged: (v) => setState(() => _dates = v)),
          const SizedBox(height: 20),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'Special edition, extra thick paper, …'),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text('Which extra houses?', style: theme.textTheme.titleMedium)),
              Text('${_selected.length} selected', style: theme.textTheme.labelLarge),
            ],
          ),
          Text(
            product == null
                ? 'Pick a paper first to see which houses already get it.'
                : 'Greyed-out houses already get ${product.name} on the chosen date(s).',
            style: theme.textTheme.bodySmall,
          ),
          for (final route in config.routes) ...[
            if (config.routes.length > 1) SectionHeader(route.name),
            for (final street in config.streetsForRoute(route.id))
              _StreetPicker(
                street: street,
                addresses: orderAddresses(config.addressesForStreet(street.id), street.numberOrder),
                selected: _selected,
                isDisabled: (a) => _alreadyGetsIt(config, a),
                onChanged: (next) => setState(() => _selected = next),
              ),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
        ],
      ),
    );
  }
}

class _StreetPicker extends StatelessWidget {
  const _StreetPicker({
    required this.street,
    required this.addresses,
    required this.selected,
    required this.isDisabled,
    required this.onChanged,
  });

  final Street street;
  final List<Address> addresses;
  final Set<int> selected;
  final bool Function(Address) isDisabled;
  final ValueChanged<Set<int>> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectable = addresses.where((a) => !isDisabled(a)).toList();
    final selectedHere = selectable.where((a) => selected.contains(a.id)).length;
    final allSelected = selectable.isNotEmpty && selectedHere == selectable.length;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${street.name}  ·  $selectedHere/${selectable.length}',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: selectable.isEmpty
                    ? null
                    : () {
                        final next = Set<int>.of(selected);
                        if (allSelected) {
                          next.removeAll(selectable.map((a) => a.id));
                        } else {
                          next.addAll(selectable.map((a) => a.id));
                        }
                        onChanged(next);
                      },
                child: Text(allSelected ? 'None' : 'All'),
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in addresses)
                FilterChip(
                  label: Text(a.label),
                  selected: selected.contains(a.id),
                  showCheckmark: false,
                  onSelected: isDisabled(a)
                      ? null
                      : (v) {
                          final next = Set<int>.of(selected);
                          v ? next.add(a.id) : next.remove(a.id);
                          onChanged(next);
                        },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
