import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/run_state.dart';
import '../../core/schedule.dart';
import '../../widgets/changes_card.dart';
import '../../widgets/common.dart';
import '../delivery/run_screen.dart';
import '../delivery/sticker_screen.dart';
import '../parent/parent_gate.dart';
import '../settings/connection_screen.dart';
import '../stats/stats_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _dayOffset = 0;
  Timer? _ticker;

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime get _date => _today.add(Duration(days: _dayOffset));

  @override
  void initState() {
    super.initState();
    // Keeps the "run in progress" banner's clock moving.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (ref.read(activeRunProvider) != null && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _start(Kid? kid, int? routeId, DayPlan plan) async {
    final config = ref.read(configProvider).config;
    if (config != null && config.kids.length > 1 && kid == null) {
      showSnack(context, 'Who is delivering today? Pick a name first.');
      return;
    }
    var practice = false;
    if (_dayOffset != 0) {
      // Another day than today: useful for testing or a late delivery, but make
      // sure a real run is a deliberate choice because it counts in the stats.
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("Start ${plan.weekdayName}'s route?"),
          content: Text(
            'You are looking at ${friendlyDate(_date)}, not today. A practice run is not saved anywhere; '
            'a real run counts as a ${plan.weekdayName} run in the stats.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, 'real'), child: const Text('Real run')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => Navigator.pop(context, 'practice'),
              child: const Text('Practice run'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      practice = choice == 'practice';
    }
    await ref.read(activeRunProvider.notifier).start(kid: kid, routeId: routeId, date: _date, practice: practice);
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RunScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configState = ref.watch(configProvider);
    final config = configState.config;
    final kid = ref.watch(currentKidProvider);
    final activeRun = ref.watch(activeRunProvider);
    final sync = ref.watch(runSyncProvider);
    final routeId = config == null ? null : pickRouteId(config, kid);
    final skipped = ref.watch(skippedAddressIdsProvider);
    final plan = config == null ? null : buildDayPlan(config, routeId, _date, skip: skipped);
    final importProblem = config?.importStatus?.problem(DateTime.now()) ?? ImportProblem.none;

    return Scaffold(
      appBar: AppBar(
        title: Text(config?.familyName.isNotEmpty == true ? config!.familyName : 'Wijkloper'),
        actions: [
          IconButton(
            tooltip: 'Connection',
            icon: Icon(
              configState.offline
                  ? Icons.cloud_off
                  : configState.loading
                      ? Icons.cloud_sync
                      : Icons.cloud_done,
              color: configState.offline ? theme.colorScheme.error : null,
            ),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionScreen())),
          ),
          if (kid != null)
            IconButton(
              tooltip: 'Stats',
              icon: const Icon(Icons.emoji_events_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StatsScreen(kidId: kid.id))),
            ),
          IconButton(
            tooltip: 'Parent mode',
            icon: const Icon(Icons.lock_outline),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ParentGate())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(configProvider.notifier).refresh();
          await ref.read(runSyncProvider.notifier).sync();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (configState.offline && config != null) _OfflineBanner(lastSync: configState.lastSync),
            if (configState.unpaired) const _UnpairedBanner(),
            if (importProblem != ImportProblem.none)
              _ImportBanner(status: config!.importStatus!, problem: importProblem),
            if (config == null) _NoConfigCard(state: configState),
            if (config != null) ...[
              if (config.kids.isEmpty) const _SetupHintCard(),
              if (config.kids.length > 1) _KidPicker(kids: config.kids, selected: kid),
              if (config.hasChanges) ...[
                const SizedBox(height: 12),
                ChangesCard(config: config, compact: true),
              ],
              if (activeRun != null) ...[
                const SizedBox(height: 12),
                _ActiveRunBanner(run: activeRun),
              ],
              const SizedBox(height: 12),
              _DayCard(
                date: _date,
                isToday: _dayOffset == 0,
                plan: plan!,
                onPrev: () => setState(() => _dayOffset--),
                onNext: () => setState(() => _dayOffset++),
                onToday: () => setState(() => _dayOffset = 0),
              ),
              const SizedBox(height: 12),
              if (plan.isDeliveryDay && activeRun == null)
                FilledButton.icon(
                  onPressed: () => _start(kid, routeId, plan),
                  icon: const Icon(Icons.play_arrow_rounded, size: 28),
                  label: Text(_dayOffset == 0 ? 'Start route' : "Start ${plan.weekdayName}'s route"),
                ),
              if (skipped.isNotEmpty) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StickerScreen()),
                  ),
                  icon: Icon(Icons.do_not_disturb_on_outlined, color: theme.colorScheme.error, size: 18),
                  label: Text(
                    '${skipped.length} ${skipped.length == 1 ? 'house' : 'houses'} skipped (Nee/Nee sticker)',
                  ),
                ),
              ],
              if (kid != null) ...[
                const SizedBox(height: 12),
                _QuickStats(kid: kid, weekday: _date.weekday),
              ],
              if (sync.pending.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.upload_outlined, size: 18, color: theme.colorScheme.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${sync.pending.length} finished ${sync.pending.length == 1 ? 'run is' : 'runs are'} waiting to upload. '
                        'They are sent automatically as soon as the phone is online.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.lastSync});

  final DateTime? lastSync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline — using the saved route (last synced ${timeAgo(lastSync)}).',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// The nightly subscriber-list import missed a night or failed: the route on
/// the phone may be out of date. Tapping opens the connection screen.
class _ImportBanner extends StatelessWidget {
  const _ImportBanner({required this.status, required this.problem});

  final ImportStatus status;
  final ImportProblem problem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch (problem) {
      ImportProblem.failed =>
        'The last update from the portal (${timeAgo(status.lastAttempt!.ranAt)}) failed. '
            'The route may be out of date.',
      _ => status.lastApplied == null
          ? 'The subscriber list has never been imported. The route may be out of date.'
          : 'Subscriber list not updated since ${timeAgo(status.lastApplied!.ranAt)}. '
              'The route may be out of date.',
    };
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionScreen())),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnpairedBanner extends ConsumerWidget {
  const _UnpairedBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.link_off, color: theme.colorScheme.onErrorContainer),
        title: const Text('This phone is no longer paired'),
        subtitle: const Text('A parent removed it from the server. Pair again to sync.'),
        trailing: TextButton(
          onPressed: () => ref.read(connectionProvider.notifier).disconnect(),
          child: const Text('Pair again'),
        ),
      ),
    );
  }
}

class _NoConfigCard extends ConsumerWidget {
  const _NoConfigCard({required this.state});

  final ConfigState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (state.loading) const CircularProgressIndicator() else const Icon(Icons.route, size: 48),
            const SizedBox(height: 12),
            Text(
              state.loading ? 'Loading the route…' : (state.error ?? 'No route on this phone yet.'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: state.loading ? null : () => ref.read(configProvider.notifier).refresh(),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupHintCard extends StatelessWidget {
  const _SetupHintCard();

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: const Icon(Icons.tips_and_updates_outlined),
          title: const Text('Set up the route'),
          subtitle: const Text(
            'Parents: tap the lock at the top right, enter the PIN (1234 until you change it) '
            'and add the kids, streets and house numbers.',
          ),
        ),
      );
}

class _KidPicker extends ConsumerWidget {
  const _KidPicker({required this.kids, required this.selected});

  final List<Kid> kids;
  final Kid? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 4),
          child: Text("Who's delivering?", style: theme.textTheme.titleMedium),
        ),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: kids.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final kid = kids[index];
              final isSelected = kid.id == selected?.id;
              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => ref.read(selectedKidProvider.notifier).select(kid.id),
                child: Container(
                  width: 96,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: isSelected ? kid.color.withValues(alpha: 0.18) : theme.colorScheme.surfaceContainerLow,
                    border: Border.all(color: isSelected ? kid.color : Colors.transparent, width: 2),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      KidAvatar(kid, radius: 22),
                      const SizedBox(height: 6),
                      Text(
                        kid.name,
                        style: theme.textTheme.labelLarge?.copyWith(fontWeight: isSelected ? FontWeight.w800 : null),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ActiveRunBanner extends ConsumerWidget {
  const _ActiveRunBanner({required this.run});

  final ActiveRunState run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final elapsed = formatDuration(run.elapsedSeconds());
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: ListTile(
        leading: Icon(Icons.timer, color: theme.colorScheme.onPrimaryContainer),
        title: Text(
          '${run.practice ? 'Practice run' : 'Run'} in progress · $elapsed',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text('${run.doneAddressIds.length} delivered so far'),
        trailing: FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RunScreen())),
          child: const Text('Continue'),
        ),
      ),
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.date,
    required this.isToday,
    required this.plan,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
  });

  final DateTime date;
  final bool isToday;
  final DayPlan plan;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
                Expanded(
                  child: InkWell(
                    onTap: isToday ? null : onToday,
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      children: [
                        Text(
                          isToday ? 'Today' : (date.difference(DateTime.now()).inDays >= 0 ? 'Preview' : 'Earlier'),
                          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
                        ),
                        Text(
                          friendlyDate(date),
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                          textAlign: TextAlign.center,
                        ),
                        if (!isToday)
                          Text('tap to go back to today', style: theme.textTheme.labelSmall),
                      ],
                    ),
                  ),
                ),
                IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
              ],
            ),
            const SizedBox(height: 8),
            if (!plan.isDeliveryDay)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  children: [
                    const Text('🎉', style: TextStyle(fontSize: 40)),
                    const SizedBox(height: 8),
                    Text('No papers ${isToday ? 'today' : 'on this day'}!', style: theme.textTheme.titleLarge),
                    Text(
                      plan.route == null ? 'No route has been set up yet.' : 'Enjoy the day off.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${plan.totalStops} houses in ${plan.streets.length} ${plan.streets.length == 1 ? 'street' : 'streets'}',
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 12),
                    Text('Take with you', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    for (final line in plan.packing) _PackingRow(line: line),
                    if (plan.extraStops > 0) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.star_rounded, color: Colors.amber),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _extrasText(plan),
                                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (plan.hasMixedProducts) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onSecondaryContainer),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Mixed day: not every house gets the same. Check the coloured labels on each number.',
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Extra today: 12× Barnevelder to houses that don't normally get it — Special edition"
String _extrasText(DayPlan plan) {
  final parts = <String>[];
  for (final entry in plan.extraCountByProduct.entries) {
    final product = plan.allProducts.where((p) => p.id == entry.key).firstOrNull;
    parts.add('${entry.value}× ${product?.name ?? 'paper'}');
  }
  final notes = plan.extras.where((e) => e.note.isNotEmpty).map((e) => e.note).toSet();
  final base = 'Extra ${plan.date.day == DateTime.now().day && plan.date.month == DateTime.now().month ? 'today' : 'this day'}: '
      '${parts.join(', ')} to houses that don\'t normally get it (marked with a star).';
  return notes.isEmpty ? base : '$base ${notes.join('; ')}';
}

class _PackingRow extends StatelessWidget {
  const _PackingRow({required this.line});

  final PackingLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[];
    for (final entry in line.inserts.entries) {
      parts.add('${entry.value} with ${entry.key.name}, ${line.count - entry.value} without');
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${line.count}×',
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, height: 1.1),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(alignment: Alignment.centerLeft, child: ProductChip(line.product)),
                if (parts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(parts.join(' · '), style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickStats extends ConsumerWidget {
  const _QuickStats({required this.kid, required this.weekday});

  final Kid kid;
  final int weekday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider(kid.id)).value;
    final mine = stats?.mine ?? KidSummary.empty;
    final best = mine.bestByWeekday[weekday];
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StatsScreen(kidId: kid.id))),
      child: Row(
        children: [
          StatTile(
            label: 'Best ${weekdayName(weekday)}',
            value: best == null ? '—' : formatDuration(best.durationSeconds),
            icon: Icons.timer_outlined,
            color: kid.color,
          ),
          const SizedBox(width: 8),
          StatTile(
            label: 'Streak',
            value: '${mine.streakDays} ${mine.streakDays == 1 ? 'day' : 'days'}',
            icon: Icons.local_fire_department_outlined,
            color: Colors.deepOrange,
          ),
          const SizedBox(width: 8),
          StatTile(
            label: 'Papers delivered',
            value: '${mine.papers}',
            icon: Icons.newspaper_outlined,
            color: Colors.teal,
          ),
        ],
      ),
    );
  }

  static String weekdayName(int weekday) => weekdayNames[weekday] ?? '';
}
