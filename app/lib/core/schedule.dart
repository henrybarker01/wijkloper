import 'models.dart';

/// Pure logic: which products go to which address on a given day, in walking order.

const weekdayNames = <int, String>{
  1: 'Monday',
  2: 'Tuesday',
  3: 'Wednesday',
  4: 'Thursday',
  5: 'Friday',
  6: 'Saturday',
  7: 'Sunday',
};

const weekdayShort = <int, String>{
  1: 'Mon',
  2: 'Tue',
  3: 'Wed',
  4: 'Thu',
  5: 'Fri',
  6: 'Sat',
  7: 'Sun',
};

const weekdayLetter = <int, String>{
  1: 'M',
  2: 'T',
  3: 'W',
  4: 'T',
  5: 'F',
  6: 'S',
  7: 'S',
};

String formatDuration(int totalSeconds) {
  final seconds = totalSeconds.abs();
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  final body = h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  return totalSeconds < 0 ? '-$body' : body;
}

String dateKey(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// One stop: an address and everything it gets today.
class Delivery {
  const Delivery({required this.address, required this.products, this.extraProductIds = const {}});

  final Address address;
  final List<Product> products;

  /// Products this house only gets today because of a one-off extra delivery.
  final Set<int> extraProductIds;

  bool has(int productId) => products.any((p) => p.id == productId);
  bool isExtra(int productId) => extraProductIds.contains(productId);
  bool get hasExtra => extraProductIds.isNotEmpty;

  /// Short label such as "B+F" or "W".
  String get shortLabel => products.map((p) => p.shortCode).join('+');

  String get longLabel => products.map((p) => p.name).join(' + ');
}

class StreetPlan {
  const StreetPlan({required this.street, required this.deliveries});

  final Street street;
  final List<Delivery> deliveries;
}

/// A packing line: how many of a paper to take, and how many of them get inserts.
class PackingLine {
  const PackingLine({required this.product, required this.count, this.inserts = const {}});

  final Product product;
  final int count;

  /// insert product -> number of [product] copies that also get this insert.
  final Map<Product, int> inserts;
}

class DayPlan {
  DayPlan({
    required this.date,
    required this.route,
    required this.streets,
    required this.allProducts,
    this.extras = const [],
  });

  final DateTime date;
  final RouteInfo? route;
  final List<StreetPlan> streets;
  final List<Product> allProducts;

  /// One-off extra deliveries that apply to this date.
  final List<Extra> extras;

  /// Houses that get something today only because of an extra delivery.
  int get extraStops => deliveries.where((d) => d.hasExtra).length;

  /// productId -> number of copies that are one-off extras today.
  Map<int, int> get extraCountByProduct {
    final counts = <int, int>{};
    for (final d in deliveries) {
      for (final id in d.extraProductIds) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    return counts;
  }

  int get weekday => date.weekday;
  String get weekdayName => weekdayNames[weekday]!;

  Iterable<Delivery> get deliveries sync* {
    for (final s in streets) {
      yield* s.deliveries;
    }
  }

  int get totalStops => streets.fold(0, (sum, s) => sum + s.deliveries.length);
  bool get isDeliveryDay => totalStops > 0;

  /// productId -> number of copies delivered today.
  Map<int, int> get countByProduct {
    final counts = <int, int>{};
    for (final d in deliveries) {
      for (final p in d.products) {
        counts[p.id] = (counts[p.id] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Products that appear at least once today, in configured order.
  List<Product> get productsToday {
    final counts = countByProduct;
    return allProducts.where((p) => (counts[p.id] ?? 0) > 0).toList();
  }

  /// True when the kid has to pay attention to what goes where (Thursday!).
  bool get hasMixedProducts {
    final combos = <String>{};
    for (final d in deliveries) {
      combos.add(d.products.map((p) => p.id).join(','));
      if (combos.length > 1) return true;
    }
    return false;
  }

  /// What to pack before leaving.
  List<PackingLine> get packing {
    final counts = countByProduct;
    final papers = productsToday.where((p) => p.kind == ProductKind.paper).toList();
    final inserts = productsToday.where((p) => p.kind == ProductKind.insert).toList();
    final lines = <PackingLine>[];
    final insertsCovered = <int>{};
    for (final paper in papers) {
      final withInsert = <Product, int>{};
      for (final insert in inserts) {
        final n = deliveries.where((d) => d.has(paper.id) && d.has(insert.id)).length;
        if (n > 0) {
          withInsert[insert] = n;
          insertsCovered.add(insert.id);
        }
      }
      lines.add(PackingLine(product: paper, count: counts[paper.id] ?? 0, inserts: withInsert));
    }
    for (final insert in inserts) {
      if (!insertsCovered.contains(insert.id)) {
        lines.add(PackingLine(product: insert, count: counts[insert.id] ?? 0));
      }
    }
    return lines;
  }

  Delivery? deliveryFor(int addressId) {
    for (final d in deliveries) {
      if (d.address.id == addressId) return d;
    }
    return null;
  }
}

/// Which products [address] receives on [date]: the weekday rules of its
/// linked products, plus any one-off extras for that date.
({List<Product> products, Set<int> extraIds}) productsFor(AppConfig config, Address address, DateTime date) {
  final weekday = date.weekday;
  final result = <Product>[];
  for (final ap in address.products) {
    final product = config.productById(ap.productId);
    if (product == null) continue;
    final days = ap.days ?? product.days;
    if (days.contains(weekday)) result.add(product);
  }
  final extraIds = <int>{};
  for (final extra in config.extrasOn(dateKey(date))) {
    if (!extra.addressIds.contains(address.id)) continue;
    final product = config.productById(extra.productId);
    if (product == null || result.any((p) => p.id == product.id)) continue;
    result.add(product);
    extraIds.add(product.id);
  }
  result.sort((a, b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
  });
  return (products: result, extraIds: extraIds);
}

int _cmpNumberSuffix(Address a, Address b) {
  final byNumber = a.number.compareTo(b.number);
  return byNumber != 0 ? byNumber : a.suffix.compareTo(b.suffix);
}

/// Sorts addresses of one street into walking order.
List<Address> orderAddresses(List<Address> addresses, NumberOrder order) {
  final list = List<Address>.from(addresses);
  switch (order) {
    case NumberOrder.asc:
      list.sort(_cmpNumberSuffix);
    case NumberOrder.desc:
      list.sort((a, b) => _cmpNumberSuffix(b, a));
    case NumberOrder.oddUpEvenBack:
      list.sort((a, b) {
        if (a.isOdd != b.isOdd) return a.isOdd ? -1 : 1;
        return a.isOdd ? _cmpNumberSuffix(a, b) : _cmpNumberSuffix(b, a);
      });
    case NumberOrder.evenUpOddBack:
      list.sort((a, b) {
        if (a.isOdd != b.isOdd) return a.isOdd ? 1 : -1;
        return a.isOdd ? _cmpNumberSuffix(b, a) : _cmpNumberSuffix(a, b);
      });
    case NumberOrder.oddThenEven:
      list.sort((a, b) {
        if (a.isOdd != b.isOdd) return a.isOdd ? -1 : 1;
        return _cmpNumberSuffix(a, b);
      });
    case NumberOrder.evenThenOdd:
      list.sort((a, b) {
        if (a.isOdd != b.isOdd) return a.isOdd ? 1 : -1;
        return _cmpNumberSuffix(a, b);
      });
    case NumberOrder.custom:
      list.sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : _cmpNumberSuffix(a, b);
      });
  }
  return list;
}

/// Builds the plan for [routeId] on [date]. Streets without stops are omitted.
/// Houses in [skip] (a Nee/Nee sticker on the door) are left out entirely, so
/// they count in neither the stops nor the papers to pack.
DayPlan buildDayPlan(AppConfig config, int? routeId, DateTime date, {Set<int> skip = const {}}) {
  final route = config.routeById(routeId);
  final streetPlans = <StreetPlan>[];
  if (route != null) {
    for (final street in config.streetsForRoute(route.id)) {
      final ordered = orderAddresses(config.addressesForStreet(street.id), street.numberOrder);
      final deliveries = <Delivery>[];
      for (final address in ordered) {
        if (skip.contains(address.id)) continue;
        final today = productsFor(config, address, date);
        if (today.products.isNotEmpty) {
          deliveries.add(Delivery(address: address, products: today.products, extraProductIds: today.extraIds));
        }
      }
      if (deliveries.isNotEmpty) {
        streetPlans.add(StreetPlan(street: street, deliveries: deliveries));
      }
    }
  }
  return DayPlan(
    date: date,
    route: route,
    streets: streetPlans,
    allProducts: config.products,
    extras: config.extrasOn(dateKey(date)),
  );
}

/// Picks the route a kid should walk: their default, else the only/first route.
int? pickRouteId(AppConfig config, Kid? kid) {
  if (kid?.defaultRouteId != null && config.routeById(kid!.defaultRouteId) != null) {
    return kid.defaultRouteId;
  }
  return config.routes.isEmpty ? null : config.routes.first.id;
}
