import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'local_store.dart';
import 'models.dart';
import 'run_state.dart';
import 'schedule.dart';
import 'settings_store.dart';

// --- infrastructure, overridden in main() ---------------------------------------

final settingsStoreProvider = Provider<SettingsStore>((ref) => throw UnimplementedError('overridden in main'));
final localStoreProvider = Provider<LocalStore>((ref) => throw UnimplementedError('overridden in main'));

/// Cached config read from disk before the first frame, so the app never starts blank.
final initialConfigProvider = Provider<AppConfig?>((ref) => null);

/// Run that was in progress when the app was last closed.
final initialActiveRunProvider = Provider<ActiveRunState?>((ref) => null);

// --- connection -------------------------------------------------------------------

class ConnectionNotifier extends Notifier<ConnectionSettings?> {
  @override
  ConnectionSettings? build() => ref.read(settingsStoreProvider).connection;

  Future<void> save(ConnectionSettings connection) async {
    await ref.read(settingsStoreProvider).saveConnection(connection);
    state = connection;
  }

  Future<void> disconnect() async {
    await ref.read(settingsStoreProvider).clearConnection();
    state = null;
  }
}

final connectionProvider = NotifierProvider<ConnectionNotifier, ConnectionSettings?>(ConnectionNotifier.new);

// --- parent session -----------------------------------------------------------------

class ParentSessionNotifier extends Notifier<ParentSession?> {
  @override
  ParentSession? build() {
    final saved = ref.read(settingsStoreProvider).parentSession;
    return saved != null && saved.isValid ? saved : null;
  }

  Future<void> login(String pin) async {
    // Uses the device-only client: apiClientProvider depends on this notifier,
    // so reading it from here would be a circular dependency.
    final api = ref.read(deviceApiProvider);
    if (api == null) throw const ApiException('This phone is not connected to a server.');
    final session = await api.parentLogin(pin);
    await ref.read(settingsStoreProvider).setParentSession(session);
    state = session;
  }

  Future<void> logout() async {
    final connection = ref.read(connectionProvider);
    final token = state?.token;
    if (connection != null && token != null) {
      await ApiClient(
        baseUrl: connection.serverUrl,
        deviceToken: connection.deviceToken,
        parentToken: token,
      ).parentLogout();
    }
    await expire();
  }

  /// Forget the session locally (e.g. after the server said it expired).
  Future<void> expire() async {
    await ref.read(settingsStoreProvider).setParentSession(null);
    state = null;
  }
}

final parentSessionProvider = NotifierProvider<ParentSessionNotifier, ParentSession?>(ParentSessionNotifier.new);

// --- API clients ------------------------------------------------------------------------

/// Client with the device token only (no parent rights). Depends on nothing but
/// the connection, so notifiers that the parent-aware client watches may use it.
final deviceApiProvider = Provider<ApiClient?>((ref) {
  final connection = ref.watch(connectionProvider);
  if (connection == null) return null;
  return ApiClient(baseUrl: connection.serverUrl, deviceToken: connection.deviceToken);
});

/// Client that also carries the parent token while a parent is logged in.
final apiClientProvider = Provider<ApiClient?>((ref) {
  final connection = ref.watch(connectionProvider);
  if (connection == null) return null;
  final parent = ref.watch(parentSessionProvider);
  return ApiClient(
    baseUrl: connection.serverUrl,
    deviceToken: connection.deviceToken,
    parentToken: parent?.token,
  );
});

// --- route configuration ------------------------------------------------------------

class ConfigState {
  const ConfigState({
    this.config,
    this.loading = false,
    this.offline = false,
    this.unpaired = false,
    this.lastSync,
    this.error,
  });

  final AppConfig? config;
  final bool loading;

  /// Last refresh failed because the server was unreachable.
  final bool offline;

  /// Server no longer knows this device (token revoked).
  final bool unpaired;
  final DateTime? lastSync;
  final String? error;

  ConfigState copyWith({
    AppConfig? config,
    bool? loading,
    bool? offline,
    bool? unpaired,
    DateTime? lastSync,
    String? error,
    bool clearError = false,
  }) =>
      ConfigState(
        config: config ?? this.config,
        loading: loading ?? this.loading,
        offline: offline ?? this.offline,
        unpaired: unpaired ?? this.unpaired,
        lastSync: lastSync ?? this.lastSync,
        error: clearError ? null : (error ?? this.error),
      );
}

class ConfigNotifier extends Notifier<ConfigState> {
  @override
  ConfigState build() {
    ref.listen(connectionProvider, (previous, next) {
      if (next != null) refresh();
    });
    if (ref.read(connectionProvider) != null) {
      Future.microtask(refresh);
    }
    return ConfigState(config: ref.read(initialConfigProvider));
  }

  /// Fetches the config if the server has a newer version. Returns true on success.
  Future<bool> refresh() async {
    final api = ref.read(apiClientProvider);
    if (api == null) return false;
    if (!ref.mounted) return false;
    state = state.copyWith(loading: true);
    try {
      final fresh = await api.fetchConfig(knownVersion: state.config?.version);
      if (fresh != null) {
        await ref.read(localStoreProvider).writeConfig(fresh);
      }
      if (!ref.mounted) return true;
      state = state.copyWith(
        config: fresh,
        loading: false,
        offline: false,
        unpaired: false,
        lastSync: DateTime.now(),
        clearError: true,
      );
      return true;
    } on ApiException catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(
        loading: false,
        offline: e.isNetwork,
        unpaired: e.isUnauthorized,
        error: e.message,
      );
      return false;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(loading: false, error: 'Unexpected error: $e');
      return false;
    }
  }
}

final configProvider = NotifierProvider<ConfigNotifier, ConfigState>(ConfigNotifier.new);

// --- kid selection ---------------------------------------------------------------------

class SelectedKidNotifier extends Notifier<int?> {
  @override
  int? build() => ref.read(settingsStoreProvider).selectedKidId;

  Future<void> select(int? kidId) async {
    await ref.read(settingsStoreProvider).setSelectedKidId(kidId);
    state = kidId;
  }
}

final selectedKidProvider = NotifierProvider<SelectedKidNotifier, int?>(SelectedKidNotifier.new);

/// The kid using the phone right now; auto-picks when there is only one.
final currentKidProvider = Provider<Kid?>((ref) {
  final config = ref.watch(configProvider).config;
  if (config == null) return null;
  final selected = ref.watch(selectedKidProvider);
  return config.kidById(selected) ?? (config.kids.length == 1 ? config.kids.first : null);
});

// --- active run --------------------------------------------------------------------------

class ActiveRunNotifier extends Notifier<ActiveRunState?> {
  @override
  ActiveRunState? build() => ref.read(initialActiveRunProvider);

  Future<ActiveRunState> start({required Kid? kid, required int? routeId, required DateTime date}) async {
    final run = ActiveRunState(
      clientRunId: const Uuid().v4(),
      kidId: kid?.id,
      routeId: routeId,
      startedAt: DateTime.now(),
      date: dateKey(date),
      weekday: date.weekday,
    );
    state = run;
    await ref.read(localStoreProvider).writeActiveRun(run);
    return run;
  }

  Future<void> toggle(int addressId) async {
    final current = state;
    if (current == null) return;
    final next = current.toggle(addressId);
    state = next;
    await ref.read(localStoreProvider).writeActiveRun(next);
  }

  /// Ends the run, queues it for upload and returns the record (plus upload result if online).
  Future<({RunRecord record, RunUploadResult? upload})?> finish(DayPlan plan, {required bool markAllDone}) async {
    final current = state;
    if (current == null) return null;
    final record = current.finish(plan, markAllDone: markAllDone);
    state = null;
    await ref.read(localStoreProvider).writeActiveRun(null);
    final upload = await ref.read(runSyncProvider.notifier).enqueue(record);
    return (record: record, upload: upload);
  }

  Future<void> cancel() async {
    state = null;
    await ref.read(localStoreProvider).writeActiveRun(null);
  }
}

final activeRunProvider = NotifierProvider<ActiveRunNotifier, ActiveRunState?>(ActiveRunNotifier.new);

// --- upload queue --------------------------------------------------------------------------

class RunSyncState {
  const RunSyncState({this.pending = const [], this.uploading = false, this.lastError});

  final List<RunRecord> pending;
  final bool uploading;
  final String? lastError;

  RunSyncState copyWith({List<RunRecord>? pending, bool? uploading, String? lastError, bool clearError = false}) =>
      RunSyncState(
        pending: pending ?? this.pending,
        uploading: uploading ?? this.uploading,
        lastError: clearError ? null : (lastError ?? this.lastError),
      );
}

class RunSyncNotifier extends Notifier<RunSyncState> {
  @override
  RunSyncState build() {
    Future.microtask(_load);
    return const RunSyncState();
  }

  Future<void> _load() async {
    final pending = await ref.read(localStoreProvider).readPendingRuns();
    if (!ref.mounted) return;
    state = state.copyWith(pending: pending);
    if (pending.isNotEmpty) await sync();
  }

  Future<RunUploadResult?> enqueue(RunRecord run) async {
    final pending = [...state.pending, run];
    state = state.copyWith(pending: pending);
    await ref.read(localStoreProvider).writePendingRuns(pending);
    return sync(target: run.clientRunId);
  }

  /// Uploads everything that is waiting. Stops at the first network error.
  Future<RunUploadResult?> sync({String? target}) async {
    final api = ref.read(apiClientProvider);
    if (api == null || state.uploading || state.pending.isEmpty) return null;
    state = state.copyWith(uploading: true, clearError: true);
    final local = ref.read(localStoreProvider);
    final pending = List<RunRecord>.of(state.pending);
    RunUploadResult? targetResult;
    String? error;
    for (final run in List<RunRecord>.of(pending)) {
      try {
        final result = await api.uploadRun(run);
        pending.remove(run);
        if (run.clientRunId == target) targetResult = result;
        if (run.kidId != null) await local.writeStats(run.kidId!, result.stats);
      } on ApiException catch (e) {
        error = e.message;
        if (e.isNetwork || e.isUnauthorized) break;
        // The server rejected this run for good (bad data); drop it so the rest can go.
        pending.remove(run);
      }
    }
    await local.writePendingRuns(pending);
    if (!ref.mounted) return targetResult;
    state = RunSyncState(pending: pending, uploading: false, lastError: error);
    ref.invalidate(statsProvider);
    return targetResult;
  }
}

final runSyncProvider = NotifierProvider<RunSyncNotifier, RunSyncState>(RunSyncNotifier.new);

// --- stats ------------------------------------------------------------------------------------

/// Stats for one kid: fresh from the server when reachable, otherwise the last cached copy.
final statsProvider = FutureProvider.family<Stats?, int>((ref, kidId) async {
  final api = ref.watch(apiClientProvider);
  final local = ref.read(localStoreProvider);
  if (api == null) return local.readStats(kidId);
  try {
    final stats = await api.fetchStats(kidId);
    await local.writeStats(kidId, stats);
    return stats;
  } on ApiException {
    return local.readStats(kidId);
  }
});
