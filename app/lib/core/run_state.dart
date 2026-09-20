import 'models.dart';
import 'schedule.dart';

/// A delivery run that is happening right now. Persisted after every tap so a
/// killed app (or a dead battery swap) resumes exactly where it was.
class ActiveRunState {
  const ActiveRunState({
    required this.clientRunId,
    required this.kidId,
    required this.routeId,
    required this.startedAt,
    required this.date,
    required this.weekday,
    this.doneAddressIds = const {},
    this.events = const [],
    this.practice = false,
  });

  final String clientRunId;
  final int? kidId;
  final int? routeId;
  final DateTime startedAt;
  final String date;
  final int weekday;
  final Set<int> doneAddressIds;
  final List<RunEvent> events;

  /// A test run (e.g. for another day): never saved or uploaded.
  final bool practice;

  int elapsedSeconds([DateTime? now]) => (now ?? DateTime.now()).difference(startedAt).inSeconds;

  ActiveRunState copyWith({Set<int>? doneAddressIds, List<RunEvent>? events}) => ActiveRunState(
        clientRunId: clientRunId,
        kidId: kidId,
        routeId: routeId,
        startedAt: startedAt,
        date: date,
        weekday: weekday,
        doneAddressIds: doneAddressIds ?? this.doneAddressIds,
        events: events ?? this.events,
        practice: practice,
      );

  /// Marks [addressId] delivered (or undoes it when already done).
  ActiveRunState toggle(int addressId, {DateTime? now}) {
    final done = Set<int>.from(doneAddressIds);
    final events = List<RunEvent>.from(this.events);
    if (done.contains(addressId)) {
      done.remove(addressId);
      events.removeWhere((e) => e.addressId == addressId);
    } else {
      done.add(addressId);
      events.add(RunEvent(addressId: addressId, t: elapsedSeconds(now)));
    }
    return copyWith(doneAddressIds: done, events: events);
  }

  /// Turns the run into an uploadable record based on today's [plan].
  RunRecord finish(DayPlan plan, {required bool markAllDone, DateTime? now}) {
    final finishedAt = now ?? DateTime.now();
    final doneIds = markAllDone ? plan.deliveries.map((d) => d.address.id).toSet() : doneAddressIds;
    final papers = <int, PaperCount>{};
    for (final delivery in plan.deliveries) {
      if (!doneIds.contains(delivery.address.id)) continue;
      for (final product in delivery.products) {
        final current = papers[product.id];
        papers[product.id] = PaperCount(name: product.name, count: (current?.count ?? 0) + 1);
      }
    }
    return RunRecord(
      clientRunId: clientRunId,
      kidId: kidId,
      routeId: routeId,
      date: date,
      weekday: weekday,
      startedAt: startedAt,
      finishedAt: finishedAt,
      durationSeconds: finishedAt.difference(startedAt).inSeconds,
      stopsTotal: plan.totalStops,
      stopsDone: plan.deliveries.where((d) => doneIds.contains(d.address.id)).length,
      papers: papers,
      events: events,
    );
  }

  factory ActiveRunState.fromJson(Map<String, dynamic> j) => ActiveRunState(
        clientRunId: j['client_run_id'] as String,
        kidId: j['kid_id'] as int?,
        routeId: j['route_id'] as int?,
        startedAt: DateTime.parse(j['started_at'] as String),
        date: j['date'] as String,
        weekday: (j['weekday'] as num).toInt(),
        doneAddressIds: ((j['done'] as List?) ?? const []).map((e) => (e as num).toInt()).toSet(),
        events: ((j['events'] as List?) ?? const [])
            .map((e) => RunEvent.fromJson(e as Map<String, dynamic>))
            .toList(),
        practice: (j['practice'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'client_run_id': clientRunId,
        'kid_id': kidId,
        'route_id': routeId,
        'started_at': startedAt.toIso8601String(),
        'date': date,
        'weekday': weekday,
        'done': doneAddressIds.toList(),
        'events': events.map((e) => e.toJson()).toList(),
        'practice': practice,
      };
}
