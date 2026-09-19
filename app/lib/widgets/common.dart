import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/models.dart';
import '../core/schedule.dart';

const kidEmojis = ['🚴', '🏃', '⚡', '🦊', '🐯', '🚀', '🌟', '🎯', '🐉', '🦄', '🐸', '🛹', '🦁', '🐼', '🔥', '🎸'];

const colorPalette = [
  '#2563EB',
  '#DB2777',
  '#16A34A',
  '#F59E0B',
  '#7C3AED',
  '#DC2626',
  '#0891B2',
  '#EA580C',
  '#4F46E5',
  '#65A30D',
  '#0F766E',
  '#9333EA',
];

String friendlyDate(DateTime date) => DateFormat('EEEE d MMMM').format(date);

String shortDate(String yyyyMMdd) {
  final date = DateTime.tryParse(yyyyMMdd);
  return date == null ? yyyyMMdd : DateFormat('EEE d MMM').format(date);
}

/// "Friday 18 September" from a yyyy-MM-dd string.
String longDate(String yyyyMMdd) {
  final date = DateTime.tryParse(yyyyMMdd);
  return date == null ? yyyyMMdd : friendlyDate(date);
}

String timeAgo(DateTime? when) {
  if (when == null) return 'never';
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return DateFormat('d MMM HH:mm').format(when);
}

Color onColor(Color background) => background.computeLuminance() > 0.45 ? Colors.black : Colors.white;

void showSnack(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? scheme.errorContainer : null,
        showCloseIcon: true,
      ),
    );
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  minimumSize: const Size(0, 40),
                )
              : FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Coloured pill with a product's name (or short code when [compact]).
class ProductChip extends StatelessWidget {
  const ProductChip(this.product, {super.key, this.compact = false, this.large = false});

  final Product product;
  final bool compact;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final fg = onColor(product.color);
    final fontSize = large ? 18.0 : (compact ? 13.0 : 14.0);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 14 : (compact ? 8 : 10), vertical: large ? 8 : (compact ? 3 : 5)),
      decoration: BoxDecoration(color: product.color, borderRadius: BorderRadius.circular(999)),
      child: Text(
        compact ? product.shortCode : product.name,
        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: fontSize),
      ),
    );
  }
}

class ProductBadges extends StatelessWidget {
  const ProductBadges(this.products, {super.key, this.compact = true, this.large = false});

  final List<Product> products;
  final bool compact;
  final bool large;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [for (final p in products) ProductChip(p, compact: compact, large: large)],
      );
}

class KidAvatar extends StatelessWidget {
  const KidAvatar(this.kid, {super.key, this.radius = 22});

  final Kid kid;
  final double radius;

  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: radius,
        backgroundColor: kid.color.withValues(alpha: 0.18),
        child: Text(kid.displayEmoji, style: TextStyle(fontSize: radius * 1.1)),
      );
}

/// Mon..Sun toggle chips.
class DayToggleChips extends StatelessWidget {
  const DayToggleChips({super.key, required this.value, required this.onChanged, this.enabled = true});

  final Set<int> value;
  final ValueChanged<Set<int>> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var d = 1; d <= 7; d++)
            FilterChip(
              label: Text(weekdayShort[d]!),
              selected: value.contains(d),
              showCheckmark: false,
              onSelected: enabled
                  ? (selected) {
                      final next = Set<int>.of(value);
                      selected ? next.add(d) : next.remove(d);
                      onChanged(next);
                    }
                  : null,
            ),
        ],
      );
}

/// Compact "Mon Tue …" text for a set of days.
String daysLabel(Set<int> days) {
  if (days.isEmpty) return 'never';
  if (days.length == 7) return 'every day';
  if (days.containsAll({1, 2, 3, 4, 5, 6}) && days.length == 6) return 'Mon–Sat';
  if (days.containsAll({1, 2, 3, 4, 5}) && days.length == 5) return 'Mon–Fri';
  final sorted = days.toList()..sort();
  return sorted.map((d) => weekdayShort[d]!).join(' ');
}

class ColorPalettePicker extends StatelessWidget {
  const ColorPalettePicker({super.key, required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final hex in colorPalette)
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => onChanged(hex),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colorFromHex(hex),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: hex.toUpperCase() == value.toUpperCase()
                        ? Theme.of(context).colorScheme.onSurface
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: hex.toUpperCase() == value.toUpperCase()
                    ? Icon(Icons.check, color: onColor(colorFromHex(hex)), size: 20)
                    : null,
              ),
            ),
        ],
      );
}

class EmojiPicker extends StatelessWidget {
  const EmojiPicker({super.key, required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final emoji in kidEmojis)
            ChoiceChip(
              label: Text(emoji, style: const TextStyle(fontSize: 20)),
              selected: emoji == value,
              showCheckmark: false,
              onSelected: (_) => onChanged(emoji),
            ),
        ],
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.icon, this.color});

  final String label;
  final String value;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: (color ?? theme.colorScheme.primary).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            if (icon != null) Icon(icon, color: color ?? theme.colorScheme.primary),
            const SizedBox(height: 4),
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(label, style: theme.textTheme.labelMedium, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            ?trailing,
          ],
        ),
      );
}
