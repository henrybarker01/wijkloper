import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/models.dart';
import '../core/schedule.dart';

const kidEmojis = ['🚴', '🏃', '⚡', '🦊', '🐯', '🚀', '🌟', '🎯', '🐉', '🦄', '🐸', '🛹', '🦁', '🐼', '🔥', '🎸'];

/// A curated, harmonious set of jewel tones for kids and papers. Kept at a
/// consistent depth/saturation so any pick looks at home next to the others.
const colorPalette = [
  '#3B5BD9', // indigo blue
  '#2E74C4', // blue
  '#1088B0', // sky
  '#0E8F86', // teal
  '#2E9E6B', // emerald
  '#6C9A2E', // olive green
  '#C98A26', // amber
  '#DE7A34', // orange
  '#D25049', // red
  '#CB4B84', // rose
  '#8A54C6', // purple
  '#6355CE', // violet
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

// --- Tonal colour helpers -----------------------------------------------------
// A vivid product/kid colour is rendered as a calm trio: a soft tinted surface,
// a deep readable ink for text/icons, and a translucent edge. Shared by the
// paper chips and the run tiles so the whole app reads as one palette.

/// Soft tinted background derived from a vivid [color].
Color tintedSurface(Color color, ColorScheme scheme, {double light = 0.14, double dark = 0.32}) =>
    Color.alphaBlend(color.withValues(alpha: scheme.brightness == Brightness.dark ? dark : light), scheme.surface);

/// A deep, readable shade of [color] for text and icons on a tinted surface.
Color tintedInk(Color color, ColorScheme scheme) => scheme.brightness == Brightness.dark
    ? Color.lerp(color, Colors.white, 0.55)!
    : Color.lerp(color, Colors.black, 0.38)!;

/// A translucent hairline edge of [color].
Color tintedEdge(Color color, ColorScheme scheme) =>
    color.withValues(alpha: scheme.brightness == Brightness.dark ? 0.5 : 0.35);

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

/// Soft tonal pill with a product's name (or short code when [compact]): a
/// tinted background in the product's colour, deep-tone text and a hairline
/// edge. Reads calmly on white and on the coloured "Next up" card alike.
class ProductChip extends StatelessWidget {
  const ProductChip(this.product, {super.key, this.compact = false, this.large = false});

  final Product product;
  final bool compact;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = tintedSurface(product.color, scheme, light: 0.16, dark: 0.38);
    final fg = tintedInk(product.color, scheme);
    final fontSize = large ? 18.0 : (compact ? 13.0 : 14.0);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 14 : (compact ? 9 : 11), vertical: large ? 7 : (compact ? 3 : 5)),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tintedEdge(product.color, scheme), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: large ? 11 : 9,
            height: large ? 11 : 9,
            decoration: BoxDecoration(color: product.color, shape: BoxShape.circle),
          ),
          SizedBox(width: large ? 7 : 5),
          Text(
            compact ? product.shortCode : product.name,
            style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: fontSize),
          ),
        ],
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

/// Chosen dates (yyyy-MM-dd) as removable chips plus an "Add date" chip.
class DateChips extends StatelessWidget {
  const DateChips({super.key, required this.dates, required this.onChanged, this.single = false});

  final List<String> dates;
  final ValueChanged<List<String>> onChanged;

  /// Only one date allowed; adding replaces it.
  final bool single;

  Future<void> _add(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 400)),
    );
    if (picked == null) return;
    final key = dateKey(picked);
    if (single) {
      onChanged([key]);
    } else if (!dates.contains(key)) {
      onChanged([...dates, key]..sort());
    }
  }

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final d in dates)
            InputChip(
              label: Text(longDate(d)),
              onDeleted: () => onChanged(dates.where((x) => x != d).toList()),
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 18),
            label: Text(single && dates.isNotEmpty ? 'Change date' : 'Add date'),
            onPressed: () => _add(context),
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
    final scheme = theme.colorScheme;
    final base = color ?? scheme.primary;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: BoxDecoration(
          color: tintedSurface(base, scheme, light: 0.12, dark: 0.30),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            if (icon != null) Icon(icon, color: tintedInk(base, scheme), size: 22),
            const SizedBox(height: 5),
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: tintedInk(base, scheme)),
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
