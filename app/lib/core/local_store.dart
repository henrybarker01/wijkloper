import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'run_state.dart';

/// JSON files in the app's private documents folder: the cached route, the run
/// in progress, finished runs waiting for upload and the last stats we saw.
class LocalStore {
  LocalStore(this.dir);

  final Directory dir;

  static const configFile = 'config.json';
  static const activeRunFile = 'active_run.json';
  static const pendingRunsFile = 'pending_runs.json';

  static Future<LocalStore> open() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}wijkloper');
    await dir.create(recursive: true);
    return LocalStore(dir);
  }

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  Future<dynamic> readJson(String name) async {
    final file = _file(name);
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> writeJson(String name, Object? json) async {
    final file = _file(name);
    if (json == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    final tmp = _file('$name.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(file.path);
  }

  Future<AppConfig?> readConfig() async {
    final json = await readJson(configFile);
    if (json is! Map<String, dynamic>) return null;
    try {
      return AppConfig.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeConfig(AppConfig config) => writeJson(configFile, config.toJson());

  Future<ActiveRunState?> readActiveRun() async {
    final json = await readJson(activeRunFile);
    if (json is! Map<String, dynamic>) return null;
    try {
      return ActiveRunState.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeActiveRun(ActiveRunState? run) => writeJson(activeRunFile, run?.toJson());

  Future<List<RunRecord>> readPendingRuns() async {
    final json = await readJson(pendingRunsFile);
    if (json is! List) return [];
    final runs = <RunRecord>[];
    for (final item in json) {
      try {
        runs.add(RunRecord.fromJson(item as Map<String, dynamic>));
      } catch (_) {
        // Skip corrupt entries rather than blocking every upload.
      }
    }
    return runs;
  }

  Future<void> writePendingRuns(List<RunRecord> runs) =>
      writeJson(pendingRunsFile, runs.map((r) => r.toJson()).toList());

  Future<Stats?> readStats(int kidId) async {
    final json = await readJson('stats_$kidId.json');
    if (json is! Map<String, dynamic>) return null;
    try {
      return Stats.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeStats(int kidId, Stats stats) => writeJson('stats_$kidId.json', stats.toJson());

  Future<void> wipe() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }
}
