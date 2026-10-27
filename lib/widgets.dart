import 'package:flutter/material.dart';

/// Shows a "Delete?" dialog. Returns true if the user confirmed.
Future<bool> confirmDelete(BuildContext context, {required String title, required String message}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Something went wrong: $error'),
      backgroundColor: Theme.of(context).colorScheme.error,
    ),
  );
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? hint;

  const EmptyState({super.key, required this.icon, required this.title, this.hint});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        children: [
          Icon(icon, size: 48, color: muted),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(hint!, style: TextStyle(color: muted), textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  final Object error;
  const ErrorState(this.error, {super.key});

  @override
  Widget build(BuildContext context) {
    final text = error.toString();
    final hint = text.contains('permission-denied')
        ? '\n\nTip: publish the rules from firestore.rules in Firebase Console → Firestore → Rules.'
        : '';
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text('Could not load data:\n$text$hint',
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }
}

String formatPrice(double? price) => price == null ? '' : '£${price.toStringAsFixed(2)}';
