import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/local_store.dart';
import 'core/providers.dart';
import 'core/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final local = await LocalStore.open();
  final cachedConfig = await local.readConfig();
  final activeRun = await local.readActiveRun();

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(SettingsStore(prefs)),
        localStoreProvider.overrideWithValue(local),
        initialConfigProvider.overrideWithValue(cachedConfig),
        initialActiveRunProvider.overrideWithValue(activeRun),
      ],
      // Network failures are handled inside the providers; no automatic retries.
      retry: (retryCount, error) => null,
      child: const WijkloperApp(),
    ),
  );
}
