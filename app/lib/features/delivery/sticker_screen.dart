import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/schedule.dart';
import '../../widgets/common.dart';

/// Houses skipped because of a Nee/Nee sticker on the door. A kid marks a
/// house from the route (long-press); this is where it comes back when the
/// sticker is gone.
class StickerScreen extends ConsumerWidget {
  const StickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = ref.watch(configProvider).config;
    final pending = ref.watch(stickerProvider);
    final skipped = ref.watch(skippedAddressIdsProvider);

    final rows = <({Street street, Address address})>[];
    if (config != null) {
      for (final route in config.routes) {
        for (final street in config.streetsForRoute(route.id)) {
          for (final address in orderAddresses(config.addressesForStreet(street.id), street.numberOrder)) {
            if (skipped.contains(address.id)) rows.add((street: street, address: address));
          }
        }
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Nee/Nee stickers')),
      body: rows.isEmpty
          ? const EmptyState(
              icon: Icons.do_not_disturb_on_outlined,
              title: 'No skipped houses',
              message: 'Seen a Nee/Nee sticker on a door? Hold that house on the route and mark it. '
                  'It comes back here so you can undo it when the sticker is gone.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    'These houses are left out of the round. Remove the sticker here when it '
                    'disappears from the door and the house is delivered again.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (pending.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Row(
                      children: [
                        Icon(Icons.cloud_upload_outlined, size: 16, color: theme.colorScheme.outline),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${pending.length} ${pending.length == 1 ? 'change is' : 'changes are'} waiting to '
                            'reach the server; they already apply on this phone.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        TextButton(
                          onPressed: () => ref.read(stickerProvider.notifier).sync(),
                          child: const Text('Sync'),
                        ),
                      ],
                    ),
                  ),
                for (final row in rows)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: Icon(Icons.do_not_disturb_on, color: theme.colorScheme.error),
                      title: Text(
                        '${row.street.name} ${row.address.label}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        [
                          'Nee/Nee sticker',
                          if (row.address.note.isNotEmpty) row.address.note,
                          if (pending.containsKey(row.address.id)) 'not synced yet',
                        ].join(' · '),
                      ),
                      trailing: FilledButton.tonal(
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                        onPressed: () {
                          ref.read(stickerProvider.notifier).set(row.address.id, '');
                          showSnack(context, '${row.street.name} ${row.address.label} is delivered again.');
                        },
                        child: const Text('Deliver again'),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
