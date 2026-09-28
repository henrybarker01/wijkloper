import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/run_state.dart';
import '../../core/schedule.dart';
import '../../widgets/changes_card.dart';
import '../../widgets/common.dart';
import 'finish_screen.dart';
import 'sticker_screen.dart';

/// The live route: timer, "next up", and every house as a colour-coded tile
/// grouped by street. Tint = the newspaper, ring = an insert (folders), star =
/// one-off extra. Tap a tile to tick it off, hold it for details, or tick a
/// whole street at once with its "All done" button.
class RunScreen extends ConsumerStatefulWidget {
  const RunScreen({super.key});

  @override
  ConsumerState<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends ConsumerState<RunScreen> {
  Timer? _ticker;

  /// Explicit collapse choices per street. A street that is not in here
  /// follows the default: open while there is still something to deliver,
  /// closed once it is finished.
  final Map<int, bool> _collapsed = {};

  /// Header of each street, so collapsing from the bottom can bring the
  /// header back into view instead of dumping you further down the list.
  final Map<int, GlobalKey> _headerKeys = {};
  bool _finishing = false;

  GlobalKey _headerKey(int streetId) => _headerKeys.putIfAbsent(streetId, () => GlobalKey());

  bool _isCollapsed(StreetPlan street, Set<int> done) =>
      _collapsed[street.street.id] ??
      street.deliveries.every((d) => done.contains(d.address.id));

  void _setCollapsed(int streetId, bool value, {bool revealHeader = false}) {
    setState(() => _collapsed[streetId] = value);
    if (!revealHeader) return;
    // After the list shrinks, scroll the street's header back to the top.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _headerKeys[streetId]?.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(context, alignment: 0, duration: const Duration(milliseconds: 250));
      }
    });
  }

  void _setAllCollapsed(DayPlan plan, bool value) {
    setState(() {
      for (final street in plan.streets) {
        _collapsed[street.street.id] = value;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    if (ref.read(settingsStoreProvider).keepScreenOn) {
      WakelockPlus.enable();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  void _haptic() {
    if (ref.read(settingsStoreProvider).haptics) HapticFeedback.mediumImpact();
  }

  Future<void> _toggle(int addressId) async {
    _haptic();
    await ref.read(activeRunProvider.notifier).toggle(addressId);
  }

  Future<void> _markStreet(StreetPlan street, {required bool done}) async {
    _haptic();
    await ref.read(activeRunProvider.notifier).markAll(street.deliveries.map((d) => d.address.id), done: done);
  }

  void _showDetails(Delivery delivery, Street street, DayPlan plan, bool done) {
    final extraNotes = plan.extras
        .where((e) => delivery.isExtra(e.productId) && e.addressIds.contains(delivery.address.id) && e.note.isNotEmpty)
        .map((e) => e.note)
        .toSet()
        .toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(street.name, style: theme.textTheme.titleMedium),
              Text(
                delivery.address.label,
                style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w900, height: 1.05),
              ),
              const SizedBox(height: 8),
              ProductBadges(delivery.products, compact: false, large: true),
              if (delivery.hasExtra) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.star_rounded, color: Colors.amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Extra delivery today${extraNotes.isEmpty ? '' : ': ${extraNotes.join('; ')}'}',
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
              if (delivery.address.note.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.info_outline, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Expanded(child: Text(delivery.address.note, style: theme.textTheme.bodyLarge)),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _toggle(delivery.address.id);
                },
                icon: Icon(done ? Icons.undo : Icons.check),
                label: Text(done ? 'Undo, not delivered yet' : 'Delivered'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _markNeeNee(delivery, street);
                },
                icon: const Icon(Icons.do_not_disturb_on_outlined),
                label: const Text('Nee/Nee sticker: skip this house'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The kid saw a Nee/Nee sticker: the house leaves the round right away
  /// (also offline) and can be brought back from the Nee/Nee list.
  Future<void> _markNeeNee(Delivery delivery, Street street) async {
    _haptic();
    final id = delivery.address.id;
    await ref.read(stickerProvider.notifier).set(id, kStickerNeeNee);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${street.name} ${delivery.address.label} skipped (Nee/Nee).'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => ref.read(stickerProvider.notifier).set(id, ''),
          ),
        ),
      );
  }

  Future<void> _finish(DayPlan plan, ActiveRunState run, Kid? kid) async {
    if (_finishing) return;
    final remaining = plan.totalStops - plan.deliveries.where((d) => run.doneAddressIds.contains(d.address.id)).length;
    bool markAll = false;
    if (remaining > 0) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('$remaining ${remaining == 1 ? 'house is' : 'houses are'} not ticked'),
          content: const Text('Did you deliver everything? Ticking them all keeps your time eligible for a personal best.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, 'keep'), child: const Text('Keep going')),
            TextButton(onPressed: () => Navigator.pop(context, 'partial'), child: const Text('Finish as is')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => Navigator.pop(context, 'all'),
              child: const Text('All delivered, finish'),
            ),
          ],
        ),
      );
      if (choice == null || choice == 'keep') return;
      markAll = choice == 'all';
    }
    setState(() => _finishing = true);
    final result = await ref.read(activeRunProvider.notifier).finish(plan, markAllDone: markAll);
    if (!mounted) return;
    setState(() => _finishing = false);
    if (result == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => FinishScreen(
          record: result.record,
          upload: result.upload,
          plan: plan,
          kid: kid,
          practice: result.practice,
        ),
      ),
    );
  }

  Future<void> _cancel() async {
    final ok = await confirm(
      context,
      title: 'Cancel this run?',
      message: 'The time and ticks of this run are thrown away. Nothing is uploaded.',
      confirmLabel: 'Cancel run',
    );
    if (!ok || !mounted) return;
    await ref.read(activeRunProvider.notifier).cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final run = ref.watch(activeRunProvider);
    final config = ref.watch(configProvider).config;
    if (run == null || config == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(icon: Icons.check_circle_outline, title: 'No run in progress'),
      );
    }
    final date = DateTime.tryParse(run.date) ?? DateTime.now();
    final skipped = ref.watch(skippedAddressIdsProvider);
    final plan = buildDayPlan(config, run.routeId, date, skip: skipped);
    final kid = config.kidById(run.kidId);
    final done = run.doneAddressIds;
    final doneCount = plan.deliveries.where((d) => done.contains(d.address.id)).length;
    final total = plan.totalStops;
    final allDone = total > 0 && doneCount >= total;
    // Houses that recently started, or moved days; marked so they stand out to
    // a kid who walks the round from memory.
    final changedIds = {
      for (final d in plan.deliveries)
        if (config.isNewlyChanged(d.address.id)) d.address.id,
    };
    Delivery? next;
    Street? nextStreet;
    for (final sp in plan.streets) {
      for (final d in sp.deliveries) {
        if (!done.contains(d.address.id)) {
          next = d;
          nextStreet = sp.street;
          break;
        }
      }
      if (next != null) break;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${kid?.displayEmoji ?? '🗞️'} ${plan.weekdayName}${run.practice ? ' · practice' : ''}'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) => switch (value) {
              'collapse' => _setAllCollapsed(plan, true),
              'expand' => _setAllCollapsed(plan, false),
              'stickers' => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const StickerScreen()),
                ),
              'cancel' => _cancel(),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'collapse', child: Text('Collapse all streets')),
              const PopupMenuItem(value: 'expand', child: Text('Expand all streets')),
              PopupMenuItem(
                value: 'stickers',
                child: Text(skipped.isEmpty ? 'Nee/Nee stickers' : 'Nee/Nee stickers (${skipped.length})'),
              ),
              const PopupMenuItem(value: 'cancel', child: Text('Cancel run (discard)')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _Header(elapsed: run.elapsedSeconds(), done: doneCount, total: total),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                if (config.hasChanges) ...[
                  ChangesCard(config: config),
                  const SizedBox(height: 12),
                ],
                if (next != null && nextStreet != null)
                  _NextUpCard(
                    street: nextStreet,
                    delivery: next,
                    onTap: () => _toggle(next!.address.id),
                    onLongPress: () => _showDetails(next!, nextStreet!, plan, false),
                  )
                else if (allDone)
                  Card(
                    color: theme.colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          const Text('🎉', style: TextStyle(fontSize: 40)),
                          Text('All delivered!', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                          const Text('Hit Finish to stop the clock.'),
                        ],
                      ),
                    ),
                  ),
                _Legend(plan: plan),
                for (final sp in plan.streets)
                  _StreetSection(
                    plan: sp,
                    done: done,
                    changed: changedIds,
                    headerKey: _headerKey(sp.street.id),
                    collapsed: _isCollapsed(sp, done),
                    onToggleCollapse: () =>
                        _setCollapsed(sp.street.id, !_isCollapsed(sp, done)),
                    onCollapseFromBottom: () =>
                        _setCollapsed(sp.street.id, true, revealHeader: true),
                    onMarkAll: (value) => _markStreet(sp, done: value),
                    onTapAddress: _toggle,
                    onLongPressAddress: (delivery) =>
                        _showDetails(delivery, sp.street, plan, done.contains(delivery.address.id)),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            style: allDone
                ? null
                : FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    foregroundColor: theme.colorScheme.onSecondaryContainer,
                  ),
            onPressed: _finishing ? null : () => _finish(plan, run, kid),
            icon: const Icon(Icons.flag_rounded),
            label: Text(_finishing ? 'Saving…' : (allDone ? 'Finish!' : 'Finish')),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.elapsed, required this.done, required this.total});

  final int elapsed;
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatDuration(elapsed),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              Text(
                '$done / $total',
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: total == 0 ? 0 : done / total, minHeight: 10),
          ),
        ],
      ),
    );
  }
}

class _NextUpCard extends StatelessWidget {
  const _NextUpCard({
    required this.street,
    required this.delivery,
    required this.onTap,
    required this.onLongPress,
  });

  final Street street;
  final Delivery delivery;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = delivery.address;
    return Card(
      color: theme.colorScheme.primaryContainer,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('NEXT UP', style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.5)),
                    Text(street.name, style: theme.textTheme.titleMedium),
                    Text(
                      address.label,
                      style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w900, height: 1.05),
                    ),
                    const SizedBox(height: 6),
                    ProductBadges(delivery.products, compact: false, large: true),
                    if (delivery.hasExtra) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.star_rounded, size: 18, color: Colors.amber),
                          const SizedBox(width: 4),
                          Text('Extra delivery today', style: theme.textTheme.labelLarge),
                        ],
                      ),
                    ],
                    if (address.note.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onPrimaryContainer),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              address.note,
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                children: [
                  Icon(Icons.check_circle_outline, size: 56, color: theme.colorScheme.primary),
                  Text('Tap = done', style: theme.textTheme.labelSmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the colours mean today.
class _Legend extends StatelessWidget {
  const _Legend({required this.plan});

  final DayPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final papers = plan.productsToday.where((p) => p.kind == ProductKind.paper).toList();
    final inserts = plan.productsToday.where((p) => p.kind == ProductKind.insert).toList();
    if (papers.isEmpty && inserts.isEmpty) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 2),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final p in papers)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Swatch(fill: tintedSurface(p.color, scheme), border: tintedEdge(p.color, scheme), borderWidth: 1.5),
                const SizedBox(width: 5),
                Text(p.name, style: theme.textTheme.labelLarge?.copyWith(color: tintedInk(p.color, scheme))),
              ],
            ),
          for (final i in inserts)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Swatch(fill: scheme.surface, border: i.color.withValues(alpha: 0.9), borderWidth: 3),
                const SizedBox(width: 5),
                Text('ring = ${i.name}', style: theme.textTheme.labelLarge),
              ],
            ),
          if (plan.extraStops > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.star_rounded, size: 18, color: Colors.amber),
                const SizedBox(width: 3),
                Text('extra today', style: theme.textTheme.labelLarge),
              ],
            ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.fill, required this.border, required this.borderWidth});

  final Color fill;
  final Color border;
  final double borderWidth;

  @override
  Widget build(BuildContext context) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: border, width: borderWidth),
        ),
      );
}

class _StreetSection extends StatelessWidget {
  const _StreetSection({
    required this.plan,
    required this.done,
    required this.changed,
    required this.headerKey,
    required this.collapsed,
    required this.onToggleCollapse,
    required this.onCollapseFromBottom,
    required this.onMarkAll,
    required this.onTapAddress,
    required this.onLongPressAddress,
  });

  final StreetPlan plan;
  final Set<int> done;
  final Set<int> changed;
  final Key headerKey;
  final bool collapsed;
  final VoidCallback onToggleCollapse;
  final VoidCallback onCollapseFromBottom;
  final ValueChanged<bool> onMarkAll;
  final ValueChanged<int> onTapAddress;
  final ValueChanged<Delivery> onLongPressAddress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doneHere = plan.deliveries.where((d) => done.contains(d.address.id)).length;
    final allDone = doneHere == plan.deliveries.length;
    final compact = FilledButton.styleFrom(
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: headerKey,
          onTap: onToggleCollapse,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
            child: Row(
              children: [
                Icon(
                  collapsed ? Icons.expand_more : Icons.expand_less,
                  size: 22,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                if (allDone) Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 20),
                if (allDone) const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    plan.street.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: allDone ? theme.colorScheme.outline : null,
                    ),
                  ),
                ),
                Text('$doneHere / ${plan.deliveries.length}', style: theme.textTheme.labelLarge),
                const SizedBox(width: 8),
                if (allDone)
                  TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 10)),
                    onPressed: () => onMarkAll(false),
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('Undo'),
                  )
                else
                  FilledButton.tonalIcon(
                    style: compact,
                    onPressed: () => onMarkAll(true),
                    icon: const Icon(Icons.done_all, size: 18),
                    label: const Text('All done'),
                  ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 92,
              mainAxisExtent: 72,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: plan.deliveries.length,
            itemBuilder: (context, index) {
              final delivery = plan.deliveries[index];
              return _RunTile(
                delivery: delivery,
                done: done.contains(delivery.address.id),
                isNew: changed.contains(delivery.address.id),
                onTap: () => onTapAddress(delivery.address.id),
                onLongPress: () => onLongPressAddress(delivery),
              );
            },
          ),
        // Same control at the bottom, so you can close a street you have just
        // finished without scrolling back up to its header.
        if (!collapsed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Material(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onCollapseFromBottom,
                child: SizedBox(
                  height: 38,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.expand_less, size: 18, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Close ${plan.street.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One house as a tinted block: wash = newspaper(s), ring = insert.
class _RunTile extends StatelessWidget {
  const _RunTile({
    required this.delivery,
    required this.done,
    required this.isNew,
    required this.onTap,
    required this.onLongPress,
  });

  final Delivery delivery;
  final bool done;

  /// Recently added to the round, or moved to different days.
  final bool isNew;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final address = delivery.address;
    final papers = delivery.products.where((p) => p.kind == ProductKind.paper).toList();
    final inserts = delivery.products.where((p) => p.kind == ProductKind.insert).toList();

    final Color? paperColor = papers.isNotEmpty ? papers.first.color : null;
    final Color? secondColor = papers.length > 1 ? papers[1].color : null;

    final Color background = done
        ? scheme.surfaceContainerLow
        : paperColor != null
            ? tintedSurface(paperColor, scheme)
            : scheme.surfaceContainerHigh;
    final Color? secondBackground = done || secondColor == null ? null : tintedSurface(secondColor, scheme);
    final Color ink = done
        ? scheme.outline
        : paperColor != null
            ? tintedInk(paperColor, scheme)
            : scheme.onSurface;

    final BoxBorder border;
    if (inserts.isNotEmpty) {
      border = Border.all(color: inserts.first.color.withValues(alpha: done ? 0.25 : 0.9), width: 3.5);
    } else if (done) {
      border = Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5), width: 1);
    } else {
      border = Border.all(color: paperColor != null ? tintedEdge(paperColor, scheme) : scheme.outlineVariant, width: 1.5);
    }

    final decoration = BoxDecoration(
      color: secondBackground == null ? background : null,
      gradient: secondBackground == null
          ? null
          : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: const [0, 0.5, 0.5, 1],
              colors: [background, background, secondBackground, secondBackground],
            ),
      borderRadius: BorderRadius.circular(14),
      border: border,
    );

    return Material(
      type: MaterialType.transparency,
      child: Ink(
        decoration: decoration,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    address.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: ink,
                      decoration: done ? TextDecoration.lineThrough : null,
                      decorationColor: ink,
                    ),
                  ),
                ),
              ),
              if (done)
                Positioned(top: 5, right: 5, child: Icon(Icons.check_circle, size: 18, color: scheme.primary))
              else if (address.note.isNotEmpty)
                Positioned(
                  top: 5,
                  right: 5,
                  child: Icon(Icons.sticky_note_2_outlined, size: 15, color: ink.withValues(alpha: 0.8)),
                ),
              if (delivery.hasExtra)
                Positioned(
                  top: 4,
                  left: 5,
                  child: Icon(Icons.star_rounded, size: 17, color: Colors.amber.withValues(alpha: done ? 0.45 : 1)),
                ),
              if (isNew)
                Positioned(
                  bottom: 3,
                  left: 4,
                  child: Icon(
                    Icons.fiber_new_rounded,
                    size: 20,
                    color: const Color(0xFF2E9E6B).withValues(alpha: done ? 0.4 : 1),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
