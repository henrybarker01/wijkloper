import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/run_state.dart';
import '../../core/schedule.dart';
import '../../widgets/common.dart';
import 'finish_screen.dart';

/// The live route: timer, "next up", and every house as a colour-coded tile
/// grouped by street. Fill = the newspaper, thick border = an insert (folders),
/// star = one-off extra delivery. Tap a tile to tick it off, hold it for details.
class RunScreen extends ConsumerStatefulWidget {
  const RunScreen({super.key});

  @override
  ConsumerState<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends ConsumerState<RunScreen> {
  Timer? _ticker;
  final Set<int> _expandedDoneStreets = {};
  bool _finishing = false;

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

  Future<void> _toggle(int addressId) async {
    if (ref.read(settingsStoreProvider).haptics) {
      HapticFeedback.mediumImpact();
    }
    await ref.read(activeRunProvider.notifier).toggle(addressId);
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
            ],
          ),
        );
      },
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
    final plan = buildDayPlan(config, run.routeId, date);
    final kid = config.kidById(run.kidId);
    final done = run.doneAddressIds;
    final doneCount = plan.deliveries.where((d) => done.contains(d.address.id)).length;
    final total = plan.totalStops;
    final allDone = total > 0 && doneCount >= total;
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
            onSelected: (value) {
              if (value == 'cancel') _cancel();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'cancel', child: Text('Cancel run (discard)')),
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
                    collapsed: sp.deliveries.every((d) => done.contains(d.address.id)) &&
                        !_expandedDoneStreets.contains(sp.street.id),
                    onToggleCollapse: () => setState(() {
                      _expandedDoneStreets.contains(sp.street.id)
                          ? _expandedDoneStreets.remove(sp.street.id)
                          : _expandedDoneStreets.add(sp.street.id);
                    }),
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
                _Swatch(fill: p.color),
                const SizedBox(width: 5),
                Text(p.name, style: theme.textTheme.labelLarge),
              ],
            ),
          for (final i in inserts)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Swatch(fill: theme.colorScheme.surface, border: i.color),
                const SizedBox(width: 5),
                Text('${i.name} = border', style: theme.textTheme.labelLarge),
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
  const _Swatch({required this.fill, this.border});

  final Color fill;
  final Color? border;

  @override
  Widget build(BuildContext context) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(5),
          border: border == null ? null : Border.all(color: border!, width: 3.5),
        ),
      );
}

class _StreetSection extends StatelessWidget {
  const _StreetSection({
    required this.plan,
    required this.done,
    required this.collapsed,
    required this.onToggleCollapse,
    required this.onTapAddress,
    required this.onLongPressAddress,
  });

  final StreetPlan plan;
  final Set<int> done;
  final bool collapsed;
  final VoidCallback onToggleCollapse;
  final ValueChanged<int> onTapAddress;
  final ValueChanged<Delivery> onLongPressAddress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doneHere = plan.deliveries.where((d) => done.contains(d.address.id)).length;
    final allDone = doneHere == plan.deliveries.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: allDone ? onToggleCollapse : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
            child: Row(
              children: [
                if (allDone) Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 20),
                if (allDone) const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    plan.street.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: allDone ? theme.colorScheme.outline : null,
                    ),
                  ),
                ),
                Text('$doneHere / ${plan.deliveries.length}', style: theme.textTheme.labelLarge),
                if (allDone) Icon(collapsed ? Icons.expand_more : Icons.expand_less, size: 20),
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
                onTap: () => onTapAddress(delivery.address.id),
                onLongPress: () => onLongPressAddress(delivery),
              );
            },
          ),
      ],
    );
  }
}

/// One house as a coloured block: fill = newspaper(s), thick border = insert.
class _RunTile extends StatelessWidget {
  const _RunTile({
    required this.delivery,
    required this.done,
    required this.onTap,
    required this.onLongPress,
  });

  final Delivery delivery;
  final bool done;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = delivery.address;
    final papers = delivery.products.where((p) => p.kind == ProductKind.paper).toList();
    final inserts = delivery.products.where((p) => p.kind == ProductKind.insert).toList();
    final alpha = done ? 0.3 : 1.0;

    final Color fill = papers.isNotEmpty ? papers.first.color : theme.colorScheme.surfaceContainerHighest;
    final Color? secondFill = papers.length > 1 ? papers[1].color : null;
    final Color fg = done
        ? theme.colorScheme.onSurface.withValues(alpha: 0.55)
        : papers.isNotEmpty
            ? onColor(fill)
            : theme.colorScheme.onSurface;

    final decoration = BoxDecoration(
      color: secondFill == null ? fill.withValues(alpha: alpha) : null,
      gradient: secondFill == null
          ? null
          : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: const [0, 0.5, 0.5, 1],
              colors: [
                fill.withValues(alpha: alpha),
                fill.withValues(alpha: alpha),
                secondFill.withValues(alpha: alpha),
                secondFill.withValues(alpha: alpha),
              ],
            ),
      borderRadius: BorderRadius.circular(14),
      border: inserts.isEmpty ? null : Border.all(color: inserts.first.color.withValues(alpha: alpha), width: 5),
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
                      color: fg,
                      decoration: done ? TextDecoration.lineThrough : null,
                      decorationColor: fg,
                    ),
                  ),
                ),
              ),
              if (done)
                Positioned(top: 5, right: 5, child: Icon(Icons.check_circle, size: 18, color: theme.colorScheme.primary))
              else if (address.note.isNotEmpty)
                Positioned(top: 5, right: 5, child: Icon(Icons.sticky_note_2_outlined, size: 15, color: fg)),
              if (delivery.hasExtra)
                Positioned(
                  top: 4,
                  left: 5,
                  child: Icon(Icons.star_rounded, size: 17, color: Colors.amber.withValues(alpha: done ? 0.5 : 1)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
