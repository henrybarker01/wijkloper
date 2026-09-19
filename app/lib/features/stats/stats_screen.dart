import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/schedule.dart';
import '../../widgets/common.dart';

class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key, required this.kidId});

  final int kidId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = ref.watch(configProvider).config;
    final kid = config?.kidById(kidId);
    final statsAsync = ref.watch(statsProvider(kidId));
    final stats = statsAsync.value;

    return Scaffold(
      appBar: AppBar(title: Text(kid == null ? 'Stats' : '${kid.displayEmoji} ${kid.name}')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(statsProvider(kidId).future),
        child: stats == null
            ? ListView(
                children: [
                  const SizedBox(height: 120),
                  if (statsAsync.isLoading)
                    const Center(child: CircularProgressIndicator())
                  else
                    const EmptyState(
                      icon: Icons.cloud_off,
                      title: 'No stats yet',
                      message: 'Stats appear after the first run has been uploaded.',
                    ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Row(
                    children: [
                      StatTile(label: 'Runs', value: '${stats.mine.runs}', icon: Icons.directions_walk),
                      const SizedBox(width: 8),
                      StatTile(label: 'Papers', value: '${stats.mine.papers}', icon: Icons.newspaper_outlined, color: Colors.teal),
                      const SizedBox(width: 8),
                      StatTile(
                        label: 'Streak',
                        value: '${stats.mine.streakDays}',
                        icon: Icons.local_fire_department_outlined,
                        color: Colors.deepOrange,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Total time on the route: ${formatDuration(stats.mine.seconds)}',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SectionHeader('Best times'),
                  Card(
                    child: Column(
                      children: [
                        for (var d = 1; d <= 7; d++)
                          if (stats.mine.bestByWeekday[d] != null || d != 7)
                            _BestRow(weekday: d, best: stats.mine.bestByWeekday[d]),
                      ],
                    ),
                  ),
                  if (stats.leaderboard.length > 1) ...[
                    const SectionHeader('Family leaderboard'),
                    Card(
                      child: Column(
                        children: [
                          for (final entry in stats.leaderboard) _LeaderRow(entry: entry, highlight: entry.kidId == kidId),
                        ],
                      ),
                    ),
                  ],
                  const SectionHeader('Recent runs'),
                  if (stats.recent.isEmpty) const Text('No runs yet. Go deliver some papers!'),
                  for (final run in stats.recent) _RunRow(run: run),
                ],
              ),
      ),
    );
  }
}

class _BestRow extends StatelessWidget {
  const _BestRow({required this.weekday, required this.best});

  final int weekday;
  final BestTime? best;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 40,
        child: Text(weekdayShort[weekday]!, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ),
      title: Text(
        best == null ? '—' : formatDuration(best!.durationSeconds),
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      subtitle: best == null ? null : Text('${best!.stopsTotal} houses · ${shortDate(best!.date)}'),
      trailing: best == null ? null : const Icon(Icons.emoji_events, color: Colors.amber),
    );
  }
}

class _LeaderRow extends StatelessWidget {
  const _LeaderRow({required this.entry, required this.highlight});

  final LeaderboardEntry entry;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bestThu = entry.summary.bestByWeekday[4];
    return ListTile(
      selected: highlight,
      leading: CircleAvatar(
        backgroundColor: entry.color.withValues(alpha: 0.18),
        child: Text(entry.displayEmoji, style: const TextStyle(fontSize: 22)),
      ),
      title: Text(entry.name, style: TextStyle(fontWeight: highlight ? FontWeight.w800 : FontWeight.w600)),
      subtitle: Text(
        '${entry.summary.runs} runs · ${entry.summary.papers} papers · streak ${entry.summary.streakDays}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: bestThu == null
          ? null
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(formatDuration(bestThu.durationSeconds), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                Text('best Thursday', style: theme.textTheme.labelSmall),
              ],
            ),
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({required this.run});

  final RunRecord run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: Icon(
          run.completed ? Icons.check_circle : Icons.remove_circle_outline,
          color: run.completed ? theme.colorScheme.primary : theme.colorScheme.outline,
        ),
        title: Text(longDate(run.date)),
        subtitle: Text('${run.stopsDone}/${run.stopsTotal} houses · ${run.paperCount} papers'),
        trailing: Text(
          formatDuration(run.durationSeconds),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
