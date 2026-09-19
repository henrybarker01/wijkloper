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

/// The live route: timer, "next up", and every house grouped by street.
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
        builder: (_) => FinishScreen(record: result.record, upload: result.upload, plan: plan, kid: kid),
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
      // Run finished/cancelled elsewhere; nothing to show.
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
        title: Text('${kid?.displayEmoji ?? '🗞️'} ${plan.weekdayName}'),
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
                    showBadges: plan.hasMixedProducts,
                    onTap: () => _toggle(next!.address.id),
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
                const SizedBox(height: 12),
                for (final sp in plan.streets)
                  _StreetSection(
                    plan: sp,
                    done: done,
                    showBadges: plan.hasMixedProducts,
                    collapsed: sp.deliveries.every((d) => done.contains(d.address.id)) &&
                        !_expandedDoneStreets.contains(sp.street.id),
                    onToggleCollapse: () => setState(() {
                      _expandedDoneStreets.contains(sp.street.id)
                          ? _expandedDoneStreets.remove(sp.street.id)
                          : _expandedDoneStreets.add(sp.street.id);
                    }),
                    onTapAddress: _toggle,
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
  const _NextUpCard({required this.street, required this.delivery, required this.showBadges, required this.onTap});

  final Street street;
  final Delivery delivery;
  final bool showBadges;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = delivery.address;
    return Card(
      color: theme.colorScheme.primaryContainer,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
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
                    if (showBadges) ...[
                      const SizedBox(height: 6),
                      ProductBadges(delivery.products, compact: false, large: true),
                    ],
                    if (address.note.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onPrimaryContainer),
                          const SizedBox(width: 4),
                          Expanded(child: Text(address.note, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
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

class _StreetSection extends StatelessWidget {
  const _StreetSection({
    required this.plan,
    required this.done,
    required this.showBadges,
    required this.collapsed,
    required this.onToggleCollapse,
    required this.onTapAddress,
  });

  final StreetPlan plan;
  final Set<int> done;
  final bool showBadges;
  final bool collapsed;
  final VoidCallback onToggleCollapse;
  final ValueChanged<int> onTapAddress;

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
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
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
          for (final delivery in plan.deliveries)
            _AddressRow(
              delivery: delivery,
              done: done.contains(delivery.address.id),
              showBadges: showBadges,
              onTap: () => onTapAddress(delivery.address.id),
            ),
      ],
    );
  }
}

class _AddressRow extends StatelessWidget {
  const _AddressRow({required this.delivery, required this.done, required this.showBadges, required this.onTap});

  final Delivery delivery;
  final bool done;
  final bool showBadges;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = delivery.address;
    final accent = delivery.products.isEmpty ? theme.colorScheme.primary : delivery.products.first.color;
    return Opacity(
      opacity: done ? 0.45 : 1,
      child: Card(
        margin: const EdgeInsets.only(bottom: 6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              Container(width: 6, height: 64, color: showBadges ? accent : theme.colorScheme.primary),
              const SizedBox(width: 12),
              SizedBox(
                width: 72,
                child: Text(
                  address.label,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    decoration: done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (showBadges) ProductBadges(delivery.products, compact: false),
                    if (address.note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          address.note,
                          style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: done ? theme.colorScheme.primary : theme.colorScheme.outline,
                  size: 30,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
