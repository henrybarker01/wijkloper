import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../widgets/common.dart';

/// The nightly import from the distributor's portal: when it last ran, when it
/// last changed anything on the route, and the log of recent attempts.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  ImportStatus? _status;
  List<ImportRun> _runs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    if (api == null) return;
    try {
      final log = await api.adminImports();
      if (!mounted) return;
      setState(() {
        _status = log.status;
        _runs = log.runs;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Until the log arrives, show what the route config already carries.
    final status = _status ?? ref.watch(configProvider).config?.importStatus ?? const ImportStatus();
    final problem = status.problem(DateTime.now());
    final applied = status.lastApplied;
    final attempt = status.lastAttempt;

    final String headline;
    final String detail;
    if (status.isEmpty) {
      headline = 'No automatic import yet';
      detail = 'Set up the nightly job on the server (see the README).';
    } else {
      switch (problem) {
        case ImportProblem.failed:
          headline = 'Last run failed ${timeAgo(attempt!.ranAt)}';
          detail = attempt.message +
              (applied == null ? '' : '\nLast successful check ${timeAgo(applied.ranAt)}.');
        case ImportProblem.stale:
          headline = applied == null ? 'Never imported successfully' : 'No check since ${timeAgo(applied.ranAt)}';
          detail = 'Expected every morning by ${status.expectedBy}. '
              'Check the server: is the cron job running, is the portal password still right?';
        case ImportProblem.none:
          headline = 'Checked ${timeAgo(applied!.ranAt)}';
          detail = '${applied.summary} · from ${applied.source}';
      }
    }
    final fine = problem == ImportProblem.none;

    return Scaffold(
      appBar: AppBar(title: const Text('Portal import')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: ListTile(leading: const Icon(Icons.cloud_off), title: Text(_error!)),
              ),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      fine ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                      color: fine ? theme.colorScheme.primary : theme.colorScheme.error,
                    ),
                    title: Text(headline),
                    subtitle: Text(detail),
                    isThreeLine: detail.contains('\n'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.edit_calendar_outlined),
                    title: Text(
                      status.lastChanged == null
                          ? 'No changes to the route yet'
                          : 'Last change ${timeAgo(status.lastChanged!.ranAt)}',
                    ),
                    subtitle: Text(
                      status.lastChanged?.summary ?? 'Most mornings the list is the same as the day before.',
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.schedule),
                    title: Text('Runs every morning, expected by ${status.expectedBy}'),
                    subtitle: const Text('Set on the server (crontab and WIJKLOPER_IMPORT_TIME).'),
                  ),
                ],
              ),
            ),
            const SectionHeader('Recent runs'),
            if (_loading)
              const Center(
                child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
              )
            else if (_runs.isEmpty)
              const Card(child: ListTile(title: Text('No runs yet')))
            else
              Card(
                child: Column(
                  children: [
                    for (final run in _runs) ...[
                      ListTile(
                        dense: true,
                        leading: Icon(
                          !run.ok
                              ? Icons.error_outline
                              : run.applied
                                  ? Icons.check_circle_outline
                                  : Icons.remove_circle_outline,
                          color: run.ok ? theme.colorScheme.primary : theme.colorScheme.error,
                        ),
                        title: Text(DateFormat('EEE d MMM HH:mm').format(run.ranAt)),
                        subtitle: Text(run.summary),
                      ),
                      if (run != _runs.last) const Divider(height: 1),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
