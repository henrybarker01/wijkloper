import 'package:flutter/material.dart';

/// Parses "#RRGGBB" into a [Color]; falls back to indigo on bad input.
Color colorFromHex(String hex) {
  final clean = hex.replaceFirst('#', '');
  final value = int.tryParse(clean, radix: 16);
  if (value == null || clean.length != 6) return const Color(0xFF4F46E5);
  return Color(0xFF000000 | value);
}

String colorToHex(Color color) {
  final r = (color.r * 255).round().toRadixString(16).padLeft(2, '0');
  final g = (color.g * 255).round().toRadixString(16).padLeft(2, '0');
  final b = (color.b * 255).round().toRadixString(16).padLeft(2, '0');
  return '#$r$g$b'.toUpperCase();
}

List<int> _intList(dynamic value) =>
    value is List ? value.map((e) => (e as num).toInt()).toList() : <int>[];

class Kid {
  const Kid({
    required this.id,
    required this.name,
    required this.emoji,
    required this.colorHex,
    this.defaultRouteId,
    this.sortOrder = 0,
  });

  final int id;
  final String name;
  final String emoji;
  final String colorHex;
  final int? defaultRouteId;
  final int sortOrder;

  Color get color => colorFromHex(colorHex);
  String get displayEmoji => emoji.isEmpty ? '🚴' : emoji;

  factory Kid.fromJson(Map<String, dynamic> j) => Kid(
        id: j['id'] as int,
        name: j['name'] as String,
        emoji: (j['emoji'] as String?) ?? '',
        colorHex: (j['color'] as String?) ?? '#4F46E5',
        defaultRouteId: j['default_route_id'] as int?,
        sortOrder: (j['sort_order'] as int?) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'color': colorHex,
        'default_route_id': defaultRouteId,
        'sort_order': sortOrder,
      };
}

class RouteInfo {
  const RouteInfo({required this.id, required this.name, this.sortOrder = 0});

  final int id;
  final String name;
  final int sortOrder;

  factory RouteInfo.fromJson(Map<String, dynamic> j) => RouteInfo(
        id: j['id'] as int,
        name: j['name'] as String,
        sortOrder: (j['sort_order'] as int?) ?? 0,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'sort_order': sortOrder};
}

enum ProductKind {
  paper,
  insert;

  static ProductKind parse(String? value) =>
      value == 'insert' ? ProductKind.insert : ProductKind.paper;

  String get apiValue => name;
}

/// Something that gets delivered: a newspaper or an insert (folders).
class Product {
  const Product({
    required this.id,
    required this.name,
    required this.shortCode,
    required this.colorHex,
    required this.days,
    this.kind = ProductKind.paper,
    this.sortOrder = 0,
  });

  final int id;
  final String name;
  final String shortCode;
  final String colorHex;

  /// ISO weekdays (1 = Monday .. 7 = Sunday) on which this product is delivered.
  final Set<int> days;
  final ProductKind kind;
  final int sortOrder;

  Color get color => colorFromHex(colorHex);

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as int,
        name: j['name'] as String,
        shortCode: (j['short_code'] as String?) ?? '',
        colorHex: (j['color'] as String?) ?? '#4F46E5',
        days: _intList(j['days']).toSet(),
        kind: ProductKind.parse(j['kind'] as String?),
        sortOrder: (j['sort_order'] as int?) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'short_code': shortCode,
        'color': colorHex,
        'days': (days.toList()..sort()),
        'kind': kind.apiValue,
        'sort_order': sortOrder,
      };
}

/// How house numbers within a street are walked.
enum NumberOrder {
  asc('asc', 'Ascending (1, 2, 3 …)'),
  desc('desc', 'Descending (… 3, 2, 1)'),
  oddUpEvenBack('odd_up_even_back', 'Odd side up, even side back (1, 3, 5 … 6, 4, 2)'),
  evenUpOddBack('even_up_odd_back', 'Even side up, odd side back (2, 4, 6 … 5, 3, 1)'),
  oddThenEven('odd_then_even', 'Odd side, then even side (1, 3, 5 … 2, 4, 6)'),
  evenThenOdd('even_then_odd', 'Even side, then odd side (2, 4, 6 … 1, 3, 5)'),
  custom('custom', 'Manual order');

  const NumberOrder(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static NumberOrder parse(String? value) => NumberOrder.values.firstWhere(
        (o) => o.apiValue == value,
        orElse: () => NumberOrder.asc,
      );
}

class Street {
  const Street({
    required this.id,
    required this.routeId,
    required this.name,
    this.numberOrder = NumberOrder.asc,
    this.sortOrder = 0,
  });

  final int id;
  final int routeId;
  final String name;
  final NumberOrder numberOrder;
  final int sortOrder;

  factory Street.fromJson(Map<String, dynamic> j) => Street(
        id: j['id'] as int,
        routeId: j['route_id'] as int,
        name: j['name'] as String,
        numberOrder: NumberOrder.parse(j['number_order'] as String?),
        sortOrder: (j['sort_order'] as int?) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'route_id': routeId,
        'name': name,
        'number_order': numberOrder.apiValue,
        'sort_order': sortOrder,
      };
}

/// Link between an address and a product, optionally on different days than
/// the product's default (e.g. Barnevelder only on Saturday).
class AddressProduct {
  const AddressProduct({required this.productId, this.days});

  final int productId;
  final Set<int>? days;

  factory AddressProduct.fromJson(Map<String, dynamic> j) => AddressProduct(
        productId: j['product_id'] as int,
        days: j['days'] == null ? null : _intList(j['days']).toSet(),
      );

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'days': days == null ? null : (days!.toList()..sort()),
      };
}

class Address {
  const Address({
    required this.id,
    required this.streetId,
    required this.number,
    this.suffix = '',
    this.note = '',
    this.sortOrder = 0,
    this.products = const [],
  });

  final int id;
  final int streetId;
  final int number;
  final String suffix;
  final String note;
  final int sortOrder;
  final List<AddressProduct> products;

  String get label => '$number$suffix';
  bool get isOdd => number.isOdd;

  AddressProduct? assignmentFor(int productId) {
    for (final p in products) {
      if (p.productId == productId) return p;
    }
    return null;
  }

  factory Address.fromJson(Map<String, dynamic> j) => Address(
        id: j['id'] as int,
        streetId: j['street_id'] as int,
        number: j['number'] as int,
        suffix: (j['suffix'] as String?) ?? '',
        note: (j['note'] as String?) ?? '',
        sortOrder: (j['sort_order'] as int?) ?? 0,
        products: ((j['products'] as List?) ?? const [])
            .map((e) => AddressProduct.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'street_id': streetId,
        'number': number,
        'suffix': suffix,
        'note': note,
        'sort_order': sortOrder,
        'products': products.map((p) => p.toJson()).toList(),
      };
}

/// A one-off delivery: [productId] also goes to [addressIds] on [date]
/// (yyyy-MM-dd), regardless of the weekday rules.
class Extra {
  const Extra({
    required this.id,
    required this.productId,
    required this.date,
    this.note = '',
    this.addressIds = const {},
  });

  final int id;
  final int productId;
  final String date;
  final String note;
  final Set<int> addressIds;

  factory Extra.fromJson(Map<String, dynamic> j) => Extra(
        id: (j['id'] as num).toInt(),
        productId: (j['product_id'] as num).toInt(),
        date: j['date'] as String,
        note: (j['note'] as String?) ?? '',
        addressIds: ((j['address_ids'] as List?) ?? const []).map((e) => (e as num).toInt()).toSet(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'product_id': productId,
        'date': date,
        'note': note,
        'address_ids': (addressIds.toList()..sort()),
      };
}

/// The complete route configuration as served by `GET /api/config`.
class AppConfig {
  AppConfig({
    required this.version,
    required this.familyName,
    required List<Kid> kids,
    required List<RouteInfo> routes,
    required List<Product> products,
    required List<Street> streets,
    required List<Address> addresses,
    List<Extra> extras = const [],
  })  : kids = List.unmodifiable(List<Kid>.of(kids)..sort(_bySortOrder)),
        routes = List.unmodifiable(List<RouteInfo>.of(routes)..sort(_bySortOrder)),
        products = List.unmodifiable(List<Product>.of(products)..sort(_bySortOrder)),
        streets = List.unmodifiable(List<Street>.of(streets)..sort(_bySortOrder)),
        addresses = List.unmodifiable(List<Address>.of(addresses)),
        extras = List.unmodifiable(List<Extra>.of(extras)..sort(_byDate)) {
    for (final p in this.products) {
      _productById[p.id] = p;
    }
    for (final s in this.streets) {
      _streetById[s.id] = s;
      _streetsByRoute.putIfAbsent(s.routeId, () => []).add(s);
    }
    for (final a in this.addresses) {
      _addressById[a.id] = a;
      _addressesByStreet.putIfAbsent(a.streetId, () => []).add(a);
    }
    for (final e in this.extras) {
      _extrasByDate.putIfAbsent(e.date, () => []).add(e);
    }
  }

  static int _byDate(Extra a, Extra b) {
    final byDate = a.date.compareTo(b.date);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  }

  static int _bySortOrder(dynamic a, dynamic b) {
    final byOrder = (a.sortOrder as int).compareTo(b.sortOrder as int);
    return byOrder != 0 ? byOrder : (a.id as int).compareTo(b.id as int);
  }

  final int version;
  final String familyName;
  final List<Kid> kids;
  final List<RouteInfo> routes;
  final List<Product> products;
  final List<Street> streets;
  final List<Address> addresses;
  final List<Extra> extras;

  final Map<int, Product> _productById = {};
  final Map<int, Street> _streetById = {};
  final Map<int, Address> _addressById = {};
  final Map<int, List<Street>> _streetsByRoute = {};
  final Map<int, List<Address>> _addressesByStreet = {};
  final Map<String, List<Extra>> _extrasByDate = {};

  /// Extra deliveries on a yyyy-MM-dd date.
  List<Extra> extrasOn(String date) => _extrasByDate[date] ?? const [];

  Product? productById(int id) => _productById[id];
  Street? streetById(int id) => _streetById[id];
  Address? addressById(int id) => _addressById[id];
  Kid? kidById(int? id) {
    for (final k in kids) {
      if (k.id == id) return k;
    }
    return null;
  }

  RouteInfo? routeById(int? id) {
    for (final r in routes) {
      if (r.id == id) return r;
    }
    return null;
  }

  List<Street> streetsForRoute(int routeId) => _streetsByRoute[routeId] ?? const [];
  List<Address> addressesForStreet(int streetId) => _addressesByStreet[streetId] ?? const [];

  int addressCountForRoute(int routeId) =>
      streetsForRoute(routeId).fold(0, (sum, s) => sum + addressesForStreet(s.id).length);

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        version: (j['version'] as num).toInt(),
        familyName: (j['family_name'] as String?) ?? '',
        kids: ((j['kids'] as List?) ?? const [])
            .map((e) => Kid.fromJson(e as Map<String, dynamic>))
            .toList(),
        routes: ((j['routes'] as List?) ?? const [])
            .map((e) => RouteInfo.fromJson(e as Map<String, dynamic>))
            .toList(),
        products: ((j['products'] as List?) ?? const [])
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList(),
        streets: ((j['streets'] as List?) ?? const [])
            .map((e) => Street.fromJson(e as Map<String, dynamic>))
            .toList(),
        addresses: ((j['addresses'] as List?) ?? const [])
            .map((e) => Address.fromJson(e as Map<String, dynamic>))
            .toList(),
        extras: ((j['extras'] as List?) ?? const [])
            .map((e) => Extra.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'family_name': familyName,
        'kids': kids.map((k) => k.toJson()).toList(),
        'routes': routes.map((r) => r.toJson()).toList(),
        'products': products.map((p) => p.toJson()).toList(),
        'streets': streets.map((s) => s.toJson()).toList(),
        'addresses': addresses.map((a) => a.toJson()).toList(),
        'extras': extras.map((e) => e.toJson()).toList(),
      };
}

// --- runs & stats -----------------------------------------------------------

class PaperCount {
  const PaperCount({required this.name, required this.count});

  final String name;
  final int count;

  factory PaperCount.fromJson(Map<String, dynamic> j) => PaperCount(
        name: (j['name'] as String?) ?? '',
        count: ((j['count'] as num?) ?? 0).toInt(),
      );

  Map<String, dynamic> toJson() => {'name': name, 'count': count};
}

class RunEvent {
  const RunEvent({required this.addressId, required this.t});

  final int addressId;

  /// Seconds since the run started.
  final int t;

  factory RunEvent.fromJson(Map<String, dynamic> j) => RunEvent(
        addressId: (j['address_id'] as num).toInt(),
        t: ((j['t'] as num?) ?? 0).toInt(),
      );

  Map<String, dynamic> toJson() => {'address_id': addressId, 't': t};
}

/// A finished delivery run, either waiting to be uploaded or as returned by the server.
class RunRecord {
  const RunRecord({
    required this.clientRunId,
    required this.kidId,
    required this.routeId,
    required this.date,
    required this.weekday,
    required this.startedAt,
    required this.finishedAt,
    required this.durationSeconds,
    required this.stopsTotal,
    required this.stopsDone,
    required this.papers,
    this.events = const [],
    this.serverId,
  });

  final String clientRunId;
  final int? kidId;
  final int? routeId;

  /// Local date as yyyy-MM-dd.
  final String date;
  final int weekday;
  final DateTime startedAt;
  final DateTime finishedAt;
  final int durationSeconds;
  final int stopsTotal;
  final int stopsDone;
  final Map<int, PaperCount> papers;
  final List<RunEvent> events;
  final int? serverId;

  bool get completed => stopsTotal > 0 && stopsDone >= stopsTotal;
  int get paperCount => papers.values.fold(0, (sum, p) => sum + p.count);

  factory RunRecord.fromJson(Map<String, dynamic> j) {
    final papersJson = (j['papers'] as Map?) ?? const {};
    return RunRecord(
      clientRunId: j['client_run_id'] as String,
      kidId: j['kid_id'] as int?,
      routeId: j['route_id'] as int?,
      date: j['date'] as String,
      weekday: (j['weekday'] as num).toInt(),
      startedAt: DateTime.parse(j['started_at'] as String),
      finishedAt: DateTime.parse(j['finished_at'] as String),
      durationSeconds: (j['duration_seconds'] as num).toInt(),
      stopsTotal: (j['stops_total'] as num).toInt(),
      stopsDone: (j['stops_done'] as num).toInt(),
      papers: {
        for (final e in papersJson.entries)
          int.parse(e.key as String): PaperCount.fromJson(e.value as Map<String, dynamic>),
      },
      events: ((j['events'] as List?) ?? const [])
          .map((e) => RunEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
      serverId: j['id'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'client_run_id': clientRunId,
        'kid_id': kidId,
        'route_id': routeId,
        'date': date,
        'weekday': weekday,
        'started_at': startedAt.toIso8601String(),
        'finished_at': finishedAt.toIso8601String(),
        'duration_seconds': durationSeconds,
        'stops_total': stopsTotal,
        'stops_done': stopsDone,
        'papers': {for (final e in papers.entries) '${e.key}': e.value.toJson()},
        'events': events.map((e) => e.toJson()).toList(),
        if (serverId != null) 'id': serverId,
      };
}

class BestTime {
  const BestTime({
    required this.durationSeconds,
    required this.date,
    this.runId,
    this.stopsTotal = 0,
  });

  final int durationSeconds;
  final String date;
  final int? runId;
  final int stopsTotal;

  factory BestTime.fromJson(Map<String, dynamic> j) => BestTime(
        durationSeconds: (j['duration_seconds'] as num).toInt(),
        date: (j['date'] as String?) ?? '',
        runId: j['run_id'] as int?,
        stopsTotal: ((j['stops_total'] as num?) ?? 0).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'duration_seconds': durationSeconds,
        'date': date,
        'run_id': runId,
        'stops_total': stopsTotal,
      };
}

/// Per-kid summary; also used for leaderboard rows.
class KidSummary {
  const KidSummary({
    required this.runs,
    required this.completedRuns,
    required this.papers,
    required this.seconds,
    required this.streakDays,
    required this.bestByWeekday,
    required this.todayDone,
  });

  final int runs;
  final int completedRuns;
  final int papers;
  final int seconds;
  final int streakDays;
  final Map<int, BestTime> bestByWeekday;
  final bool todayDone;

  static const empty = KidSummary(
    runs: 0,
    completedRuns: 0,
    papers: 0,
    seconds: 0,
    streakDays: 0,
    bestByWeekday: {},
    todayDone: false,
  );

  factory KidSummary.fromJson(Map<String, dynamic> j) {
    final totals = (j['totals'] as Map?) ?? const {};
    final best = (j['best_by_weekday'] as Map?) ?? const {};
    return KidSummary(
      runs: ((totals['runs'] as num?) ?? 0).toInt(),
      completedRuns: ((totals['completed_runs'] as num?) ?? 0).toInt(),
      papers: ((totals['papers'] as num?) ?? 0).toInt(),
      seconds: ((totals['seconds'] as num?) ?? 0).toInt(),
      streakDays: ((j['streak_days'] as num?) ?? 0).toInt(),
      bestByWeekday: {
        for (final e in best.entries)
          int.parse(e.key as String): BestTime.fromJson(e.value as Map<String, dynamic>),
      },
      todayDone: (j['today_done'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'totals': {
          'runs': runs,
          'completed_runs': completedRuns,
          'papers': papers,
          'seconds': seconds,
        },
        'streak_days': streakDays,
        'best_by_weekday': {for (final e in bestByWeekday.entries) '${e.key}': e.value.toJson()},
        'today_done': todayDone,
      };
}

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.kidId,
    required this.name,
    required this.emoji,
    required this.colorHex,
    required this.summary,
  });

  final int kidId;
  final String name;
  final String emoji;
  final String colorHex;
  final KidSummary summary;

  Color get color => colorFromHex(colorHex);
  String get displayEmoji => emoji.isEmpty ? '🚴' : emoji;

  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) => LeaderboardEntry(
        kidId: (j['kid_id'] as num).toInt(),
        name: (j['name'] as String?) ?? '',
        emoji: (j['emoji'] as String?) ?? '',
        colorHex: (j['color'] as String?) ?? '#4F46E5',
        summary: KidSummary.fromJson(j),
      );

  Map<String, dynamic> toJson() => {
        'kid_id': kidId,
        'name': name,
        'emoji': emoji,
        'color': colorHex,
        ...summary.toJson(),
      };
}

/// Response of `GET /api/stats`.
class Stats {
  const Stats({
    required this.kidId,
    required this.today,
    required this.mine,
    required this.recent,
    required this.leaderboard,
    this.fetchedAt,
  });

  final int? kidId;
  final String today;
  final KidSummary mine;
  final List<RunRecord> recent;
  final List<LeaderboardEntry> leaderboard;
  final DateTime? fetchedAt;

  factory Stats.fromJson(Map<String, dynamic> j, {DateTime? fetchedAt}) => Stats(
        kidId: j['kid_id'] as int?,
        today: (j['today'] as String?) ?? '',
        mine: j['totals'] == null ? KidSummary.empty : KidSummary.fromJson(j),
        recent: ((j['recent'] as List?) ?? const [])
            .map((e) => RunRecord.fromJson(e as Map<String, dynamic>))
            .toList(),
        leaderboard: ((j['leaderboard'] as List?) ?? const [])
            .map((e) => LeaderboardEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        fetchedAt: fetchedAt ??
            (j['_fetched_at'] == null ? null : DateTime.tryParse(j['_fetched_at'] as String)),
      );

  Map<String, dynamic> toJson() => {
        'kid_id': kidId,
        'today': today,
        ...mine.toJson(),
        'recent': recent.map((r) => r.toJson()).toList(),
        'leaderboard': leaderboard.map((l) => l.toJson()).toList(),
        if (fetchedAt != null) '_fetched_at': fetchedAt!.toIso8601String(),
      };
}
