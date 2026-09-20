import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/schedule.dart';
import '../../widgets/common.dart';

class FinishScreen extends ConsumerWidget {
  const FinishScreen({
    super.key,
    required this.record,
    required this.upload,
    required this.plan,
    required this.kid,
    this.practice = false,
  });

  final RunRecord record;
  final RunUploadResult? upload;
  final DayPlan plan;
  final Kid? kid;

  /// Test run for another day: nothing was saved or uploaded.
  final bool practice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final weekday = weekdayNames[record.weekday] ?? '';

    // Compare with the best time we know about: fresh from the server if the
    // upload went through, otherwise the last cached stats.
    final Stats? stats =
        practice ? null : upload?.stats ?? (kid == null ? null : ref.watch(statsProvider(kid!.id)).value);
    final best = stats?.mine.bestByWeekday[record.weekday];
    String headline;
    String detail;
    if (practice) {
      headline = 'Practice run finished';
      detail = 'Nothing was saved or uploaded, so try as often as you like.';
    } else if (!record.completed) {
      headline = 'Route finished';
      detail = 'Not every house was ticked, so this time does not count for a personal best.';
    } else if (upload != null && best != null && best.runId == upload!.serverId) {
      headline = 'New personal best! 🏆';
      detail = 'Fastest $weekday ever.';
    } else if (upload == null && (best == null || record.durationSeconds < best.durationSeconds)) {
      headline = best == null ? 'First $weekday done! ⭐' : 'Looks like a new best! 🏆';
      detail = 'It counts as soon as the run has been uploaded.';
    } else if (best != null) {
      final diff = record.durationSeconds - best.durationSeconds;
      headline = diff <= 0 ? 'Personal best! 🏆' : 'Nice run!';
      detail = diff <= 0 ? 'Fastest $weekday ever.' : '${formatDuration(diff)} behind your best $weekday (${formatDuration(best.durationSeconds)}).';
    } else {
      headline = 'Route done! ⭐';
      detail = 'Your first $weekday time is on the board.';
    }
    final streak = stats?.mine.streakDays;

    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, title: const Text('Finished')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            kid == null ? 'Great job!' : 'Great job, ${kid!.name}! ${kid!.displayEmoji}',
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Text(
            formatDuration(record.durationSeconds),
            textAlign: TextAlign.center,
            style: theme.textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          Text(longDate(record.date), textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 20),
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(headline, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800), textAlign: TextAlign.center),
                  const SizedBox(height: 4),
                  Text(detail, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              StatTile(label: 'Houses', value: '${record.stopsDone} / ${record.stopsTotal}', icon: Icons.home_outlined),
              const SizedBox(width: 8),
              StatTile(label: 'Papers', value: '${record.paperCount}', icon: Icons.newspaper_outlined, color: Colors.teal),
              if (streak != null) ...[
                const SizedBox(width: 8),
                StatTile(label: 'Streak', value: '$streak ${streak == 1 ? 'day' : 'days'}', icon: Icons.local_fire_department_outlined, color: Colors.deepOrange),
              ],
            ],
          ),
          const SizedBox(height: 16),
          if (record.papers.isNotEmpty) ...[
            Text('Delivered', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final entry in record.papers.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Text('${entry.value.count}×', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(width: 8),
                    Builder(builder: (context) {
                      final product = plan.allProducts.where((p) => p.id == entry.key).firstOrNull;
                      return product == null ? Text(entry.value.name) : ProductChip(product);
                    }),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                practice
                    ? Icons.science_outlined
                    : upload == null
                        ? Icons.cloud_upload_outlined
                        : Icons.cloud_done,
                size: 18,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  practice
                      ? 'Practice run: not saved.'
                      : upload == null
                          ? 'Saved on this phone. It uploads automatically as soon as the phone is online.'
                          : 'Uploaded to the family server.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
