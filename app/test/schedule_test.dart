import 'package:flutter_test/flutter_test.dart';
import 'package:wijkloper/core/models.dart';
import 'package:wijkloper/core/run_state.dart';
import 'package:wijkloper/core/schedule.dart';

AppConfig _config({NumberOrder order = NumberOrder.asc, List<Extra> extras = const []}) {
  const barnevelder = 1;
  const folders = 2;
  const deWeek = 3;
  return AppConfig(
    version: 1,
    familyName: 'Test',
    extras: extras,
    kids: [const Kid(id: 1, name: 'Sam', emoji: '', colorHex: '#000000')],
    routes: [const RouteInfo(id: 10, name: 'Route')],
    products: const [
      Product(id: barnevelder, name: 'Barnevelder', shortCode: 'B', colorHex: '#1D4ED8', days: {1, 2, 3, 4, 5, 6}),
      Product(id: folders, name: 'Folders', shortCode: 'F', colorHex: '#F59E0B', days: {4}, kind: ProductKind.insert, sortOrder: 1),
      Product(id: deWeek, name: 'De Week', shortCode: 'W', colorHex: '#16A34A', days: {4}, sortOrder: 2),
    ],
    streets: [Street(id: 100, routeId: 10, name: 'Kerkstraat', numberOrder: order)],
    addresses: const [
      // 1: Barnevelder every day + folders on Thursday
      Address(id: 1, streetId: 100, number: 1, products: [AddressProduct(productId: barnevelder), AddressProduct(productId: folders)]),
      // 2: De Week only (Thursday)
      Address(id: 2, streetId: 100, number: 2, products: [AddressProduct(productId: deWeek)]),
      // 3: Barnevelder without folders
      Address(id: 3, streetId: 100, number: 3, products: [AddressProduct(productId: barnevelder)]),
      // 4: Barnevelder only on Saturday (override), De Week on Thursday
      Address(id: 4, streetId: 100, number: 4, products: [AddressProduct(productId: barnevelder, days: {6}), AddressProduct(productId: deWeek)]),
      // 5: nothing ever
      Address(id: 5, streetId: 100, number: 5, suffix: 'a'),
      Address(id: 6, streetId: 100, number: 6, products: [AddressProduct(productId: barnevelder)]),
    ],
  );
}

final monday = DateTime(2026, 9, 14);
final thursday = DateTime(2026, 9, 17);
final saturday = DateTime(2026, 9, 19);
final sunday = DateTime(2026, 9, 20);

void main() {
  test('normal weekday: only Barnevelder addresses, no mixed products', () {
    final plan = buildDayPlan(_config(), 10, monday);
    expect(plan.isDeliveryDay, isTrue);
    expect(plan.streets.single.deliveries.map((d) => d.address.number), [1, 3, 6]);
    expect(plan.hasMixedProducts, isFalse);
    expect(plan.countByProduct, {1: 3});
    expect(plan.packing.single.count, 3);
    expect(plan.packing.single.inserts, isEmpty);
  });

  test('thursday: folders, de week and both papers together', () {
    final plan = buildDayPlan(_config(), 10, thursday);
    final labels = {for (final d in plan.deliveries) d.address.number: d.shortLabel};
    expect(labels, {1: 'B+F', 2: 'W', 3: 'B', 4: 'W', 6: 'B'});
    expect(plan.hasMixedProducts, isTrue);
    expect(plan.countByProduct, {1: 3, 2: 1, 3: 2});
    final packing = plan.packing;
    expect(packing.map((l) => l.product.name), ['Barnevelder', 'De Week']);
    expect(packing.first.count, 3);
    expect(packing.first.inserts.values.single, 1); // one Barnevelder gets folders
  });

  test('saturday: per-address day override adds the extra house', () {
    final plan = buildDayPlan(_config(), 10, saturday);
    expect(plan.deliveries.map((d) => d.address.number), [1, 3, 4, 6]);
  });

  test('sunday: nothing to deliver', () {
    final plan = buildDayPlan(_config(), 10, sunday);
    expect(plan.isDeliveryDay, isFalse);
    expect(plan.streets, isEmpty);
  });

  test('extra delivery day adds houses on that date only and marks them', () {
    final config = _config(extras: [
      const Extra(id: 1, productId: 1, date: '2026-09-14', note: 'Special edition', addressIds: {2, 3, 5}),
    ]);
    final plan = buildDayPlan(config, 10, monday);
    // 2 and 5 get nothing on a normal Monday; 3 already gets the Barnevelder.
    expect(plan.deliveries.map((d) => d.address.number), [1, 2, 3, 5, 6]);
    expect(plan.deliveryFor(2)!.isExtra(1), isTrue);
    expect(plan.deliveryFor(5)!.shortLabel, 'B');
    expect(plan.deliveryFor(3)!.isExtra(1), isFalse);
    expect(plan.deliveryFor(3)!.products.length, 1); // no duplicate
    expect(plan.extraStops, 2);
    expect(plan.extraCountByProduct, {1: 2});
    expect(plan.countByProduct, {1: 5});
    expect(plan.packing.single.count, 5);
    expect(plan.extras.single.note, 'Special edition');
    // The day after, everything is back to normal.
    final tuesday = buildDayPlan(config, 10, DateTime(2026, 9, 15));
    expect(tuesday.deliveries.map((d) => d.address.number), [1, 3, 6]);
    expect(tuesday.extras, isEmpty);
  });

  test('unknown route yields an empty plan', () {
    expect(buildDayPlan(_config(), 999, monday).totalStops, 0);
    expect(buildDayPlan(_config(), null, monday).totalStops, 0);
  });

  group('number ordering', () {
    Address a(int n, {int order = 0, String suffix = ''}) =>
        Address(id: n, streetId: 1, number: n, sortOrder: order, suffix: suffix);
    final houses = [a(2), a(5), a(1), a(4), a(3), a(6)];
    List<int> numbers(NumberOrder o) => orderAddresses(houses, o).map((x) => x.number).toList();

    test('asc / desc', () {
      expect(numbers(NumberOrder.asc), [1, 2, 3, 4, 5, 6]);
      expect(numbers(NumberOrder.desc), [6, 5, 4, 3, 2, 1]);
    });
    test('odd up, even back', () => expect(numbers(NumberOrder.oddUpEvenBack), [1, 3, 5, 6, 4, 2]));
    test('even up, odd back', () => expect(numbers(NumberOrder.evenUpOddBack), [2, 4, 6, 5, 3, 1]));
    test('odd then even', () => expect(numbers(NumberOrder.oddThenEven), [1, 3, 5, 2, 4, 6]));
    test('even then odd', () => expect(numbers(NumberOrder.evenThenOdd), [2, 4, 6, 1, 3, 5]));
    test('custom uses sort order', () {
      final custom = [a(1, order: 2), a(2, order: 0), a(3, order: 1)];
      expect(orderAddresses(custom, NumberOrder.custom).map((x) => x.number), [2, 3, 1]);
    });
    test('suffix sorts after the bare number', () {
      final withSuffix = [a(7, suffix: 'a'), a(7), a(8)];
      expect(orderAddresses(withSuffix, NumberOrder.asc).map((x) => x.label), ['7', '7a', '8']);
    });
  });

  test('formatDuration', () {
    expect(formatDuration(0), '0:00');
    expect(formatDuration(65), '1:05');
    expect(formatDuration(1530), '25:30');
    expect(formatDuration(3725), '1:02:05');
    expect(formatDuration(-12), '-0:12');
  });

  test('config JSON round trip keeps assignments, day overrides and extras', () {
    final config = _config(
      order: NumberOrder.oddUpEvenBack,
      extras: [const Extra(id: 7, productId: 1, date: '2026-10-03', note: 'x', addressIds: {1, 2})],
    );
    final copy = AppConfig.fromJson(config.toJson());
    expect(copy.extrasOn('2026-10-03').single.addressIds, {1, 2});
    expect(copy.extrasOn('2026-10-04'), isEmpty);
    expect(copy.streets.single.numberOrder, NumberOrder.oddUpEvenBack);
    expect(copy.addressById(4)!.assignmentFor(1)!.days, {6});
    expect(copy.addressById(1)!.assignmentFor(1)!.days, isNull);
    expect(copy.productById(2)!.kind, ProductKind.insert);
    expect(copy.addressById(5)!.label, '5a');
  });

  test('marking a whole street done and undoing it', () {
    final run = ActiveRunState(
      clientRunId: 'run-1',
      kidId: 1,
      routeId: 10,
      startedAt: DateTime(2026, 9, 14, 16),
      date: '2026-09-14',
      weekday: 1,
    ).toggle(1, now: DateTime(2026, 9, 14, 16, 0, 30));
    final street = run.markAll([1, 3, 6], done: true, now: DateTime(2026, 9, 14, 16, 5));
    expect(street.doneAddressIds, {1, 3, 6});
    expect(street.events.length, 3); // house 1 keeps its original event
    expect(street.events.first.t, 30);
    expect(street.events.last.t, 300);
    final undone = street.markAll([1, 3, 6], done: false);
    expect(undone.doneAddressIds, isEmpty);
    expect(undone.events, isEmpty);
    expect(street.practice, isFalse);
  });

  test('run record JSON round trip', () {
    final run = RunRecord(
      clientRunId: 'abc-123-def-456',
      kidId: 1,
      routeId: 10,
      date: '2026-09-17',
      weekday: 4,
      startedAt: DateTime(2026, 9, 17, 16),
      finishedAt: DateTime(2026, 9, 17, 16, 25, 30),
      durationSeconds: 1530,
      stopsTotal: 5,
      stopsDone: 5,
      papers: const {1: PaperCount(name: 'Barnevelder', count: 3), 3: PaperCount(name: 'De Week', count: 2)},
      events: const [RunEvent(addressId: 1, t: 40)],
    );
    final copy = RunRecord.fromJson(run.toJson());
    expect(copy.completed, isTrue);
    expect(copy.paperCount, 5);
    expect(copy.papers[3]!.name, 'De Week');
    expect(copy.events.single.t, 40);
    expect(dateKey(copy.startedAt), '2026-09-17');
  });
}
