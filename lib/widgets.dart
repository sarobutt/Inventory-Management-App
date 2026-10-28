import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';

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

/// Asks for a whole number (used to set an exact stock count).
Future<int?> askCount(BuildContext context, {required String title, required int initial}) {
  final controller = TextEditingController(text: '$initial');
  return showDialog<int>(
    context: context,
    builder: (ctx) {
      void submit() {
        final v = int.tryParse(controller.text.trim());
        if (v != null && v >= 0) Navigator.pop(ctx, v);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Quantity'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: const Text('Save')),
        ],
      );
    },
  );
}

/// Runs [Db.refresh]-style work for pull-to-refresh and reports problems.
Future<void> pullRefresh(BuildContext context, Future<void> Function() fetch, VoidCallback resubscribe) async {
  try {
    await fetch();
  } catch (_) {
    if (context.mounted) showMessage(context, 'Could not refresh. Check your internet connection.');
  }
  resubscribe();
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

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
}

/// Small heading used above lists, e.g. "STORES (3)".
class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 0.8)),
      );
}

/// A row of summary figures, e.g. Products 12 | Units 340 | Value £1,200.00
class StatsRow extends StatelessWidget {
  final List<(String label, String value)> stats;
  const StatsRow(this.stats, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (final s in stats)
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.$1, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(s.$2, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// £1,234.50
String money(double value) {
  final fixed = value.toStringAsFixed(2);
  final parts = fixed.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '£$whole.${parts[1]}';
}

String formatPrice(double? price) => price == null ? '' : money(price);

/// 12,345
String count(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

// ---------------- Low stock ----------------

class StockColors {
  StockColors._();
  static const Color lowBg = Color(0xFFFFF4D6);
  static const Color lowBorder = Color(0xFFF0B429);
  static const Color lowText = Color(0xFF8A5A00);
}

/// "Needs ordering" (amber) or "Out of stock" (red) label for a product.
class StockStatusChip extends StatelessWidget {
  final Product product;
  const StockStatusChip({super.key, required this.product});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final out = product.isOutOfStock;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: out ? scheme.error : StockColors.lowBorder,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(out ? Icons.remove_shopping_cart_outlined : Icons.warning_amber_rounded,
              size: 14, color: out ? scheme.onError : Colors.black87),
          const SizedBox(width: 4),
          Text(
            out ? 'Out of stock: order now' : 'Needs ordering (≤ ${product.effectiveReorderLevel})',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: out ? scheme.onError : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

/// Amber banner: "N products need ordering". Tap to filter.
class NeedsOrderingBanner extends StatelessWidget {
  final int count;
  final bool active;
  final VoidCallback onTap;
  final String? actionLabel;

  const NeedsOrderingBanner({
    super.key,
    required this.count,
    required this.active,
    required this.onTap,
    this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: StockColors.lowBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StockColors.lowBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: StockColors.lowText),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$count product${count == 1 ? '' : 's'} need${count == 1 ? 's' : ''} ordering',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: StockColors.lowText),
                ),
              ),
              Text(
                actionLabel ?? (active ? 'Show all' : 'Show only these'),
                style: const TextStyle(color: StockColors.lowText, decoration: TextDecoration.underline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
