import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../../widgets/common.dart';

typedef AdminAction = Future<void> Function(ApiClient api);

/// Runs a parent-only server call, refreshes the route afterwards and turns
/// errors into snackbars. Returns true when the call succeeded.
Future<bool> runAdmin(
  BuildContext context,
  WidgetRef ref,
  AdminAction action, {
  String? success,
  bool refresh = true,
}) async {
  final api = ref.read(apiClientProvider);
  if (api == null) {
    showSnack(context, 'This phone is not connected to the server.', error: true);
    return false;
  }
  if (ref.read(parentSessionProvider) == null) {
    showSnack(context, 'Parent session expired. Enter your PIN again.', error: true);
    return false;
  }
  try {
    await action(api);
    if (refresh) await ref.read(configProvider.notifier).refresh();
    if (success != null && context.mounted) showSnack(context, success);
    return true;
  } on ApiException catch (e) {
    if (!context.mounted) return false;
    if (e.isForbidden) {
      await ref.read(parentSessionProvider.notifier).expire();
      if (context.mounted) {
        showSnack(context, 'Parent session expired. Enter your PIN again.', error: true);
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } else {
      showSnack(context, e.message, error: true);
    }
    return false;
  }
}

/// Simple one-field text prompt.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? initial,
  String? label,
  String confirmLabel = 'Save',
  TextInputType keyboardType = TextInputType.text,
  bool obscure = false,
}) {
  final controller = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: obscure,
        keyboardType: keyboardType,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}
