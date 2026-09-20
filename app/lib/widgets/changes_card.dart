import 'package:flutter/material.dart';

import '../core/models.dart';
import 'common.dart';

/// "What's changed on the round" — the thing a kid who knows the route by heart
/// actually needs. Added houses they would skip, stopped houses they would
/// deliver to anyway.
class ChangesCard extends StatelessWidget {
  const ChangesCard({super.key, required this.config, this.compact = false});

  final AppConfig config;

  /// A single summary line instead of the full list (used on the home screen).
  final bool compact;

  static const _added = Color(0xFF2E9E6B);
  static const _stopped = Color(0xFFD25049);
  static const _days = Color(0xFF3B5BD9);

  static Color _colourFor(ChangeKind kind) => switch (kind) {
        ChangeKind.added => _added,
        ChangeKind.stopped => _stopped,
        ChangeKind.days => _days,
        ChangeKind.street => _added,
      };

  static IconData _iconFor(ChangeKind kind) => switch (kind) {
        ChangeKind.added => Icons.add_circle,
        ChangeKind.stopped => Icons.cancel,
        ChangeKind.days => Icons.event_repeat,
        ChangeKind.street => Icons.add_road,
      };

  static String _describe(RouteChange change) => switch (change.kind) {
        ChangeKind.added => 'now gets the ${change.productName}',
        ChangeKind.stopped => 'stopped, do not deliver',
        ChangeKind.days => change.days == null
            ? 'back to the usual days'
            : 'only on ${daysLabel(change.days!.split(',').map(int.parse).toSet())}',
        ChangeKind.street => 'new street, ${change.detail}',
      };

  /// "2 new, 1 stopped"
  static String summarise(AppConfig config) {
    final counts = <ChangeKind, int>{};
    for (final c in config.changes) {
      counts[c.kind] = (counts[c.kind] ?? 0) + 1;
    }
    final parts = <String>[];
    if ((counts[ChangeKind.street] ?? 0) > 0) {
      parts.add('${counts[ChangeKind.street]} new ${counts[ChangeKind.street] == 1 ? 'street' : 'streets'}');
    }
    if ((counts[ChangeKind.added] ?? 0) > 0) parts.add('${counts[ChangeKind.added]} new');
    if ((counts[ChangeKind.stopped] ?? 0) > 0) parts.add('${counts[ChangeKind.stopped]} stopped');
    if ((counts[ChangeKind.days] ?? 0) > 0) parts.add('${counts[ChangeKind.days]} changed days');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!config.hasChanges) return const SizedBox.shrink();
    final scheme = theme.colorScheme;

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: tintedSurface(_added, scheme, light: 0.14, dark: 0.30),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tintedEdge(_added, scheme)),
        ),
        child: Row(
          children: [
            Icon(Icons.campaign_rounded, size: 20, color: tintedInk(_added, scheme)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Changed on the round: ${summarise(config)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: tintedInk(_added, scheme),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Stopped first: it is the one a kid walking from memory gets wrong.
    final ordered = [
      ...config.changes.where((c) => c.kind == ChangeKind.stopped),
      ...config.changes.where((c) => c.kind != ChangeKind.stopped),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tintedEdge(_added, scheme)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.campaign_rounded, color: tintedInk(_added, scheme)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Watch out, this changed',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              Text(summarise(config), style: theme.textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 10),
          for (final change in ordered.take(12))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_iconFor(change.kind), size: 20, color: _colourFor(change.kind)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
                        children: [
                          TextSpan(
                            text: config.whereOf(change),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          TextSpan(text: '  ${_describe(change)}'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (ordered.length > 12)
            Text('and ${ordered.length - 12} more', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
