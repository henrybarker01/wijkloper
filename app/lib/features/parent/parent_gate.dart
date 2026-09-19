import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/providers.dart';
import 'parent_home.dart';

/// Shows the parent area when a parent session exists, otherwise asks for the PIN.
class ParentGate extends ConsumerStatefulWidget {
  const ParentGate({super.key});

  @override
  ConsumerState<ParentGate> createState() => _ParentGateState();
}

class _ParentGateState extends ConsumerState<ParentGate> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_pin.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(parentSessionProvider.notifier).login(_pin.text.trim());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? 'Wrong PIN.' : e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(parentSessionProvider);
    if (session != null && session.isValid) return const ParentHome();

    final theme = Theme.of(context);
    final offline = ref.watch(configProvider).offline;
    return Scaffold(
      appBar: AppBar(title: const Text('Parent mode')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(Icons.lock_outline, size: 56),
          const SizedBox(height: 16),
          Text('Enter the parent PIN', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'Changing the route needs a connection to the family server.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (offline)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The server is not reachable right now.',
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 24),
          TextField(
            controller: _pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, letterSpacing: 10),
            decoration: const InputDecoration(labelText: 'PIN'),
            onSubmitted: (_) => _unlock(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error), textAlign: TextAlign.center),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _unlock, child: Text(_busy ? 'Checking…' : 'Unlock')),
          const SizedBox(height: 16),
          Text(
            'The PIN is 1234 until a parent changes it in Parent mode › Settings.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
