import 'package:flutter/material.dart';

import '../auth.dart';
import '../orders.dart';
import '../report.dart';
import '../widgets.dart';
import 'order_form_screen.dart';

/// Admin: list of purchase orders with filters and totals.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  Stream<List<PurchaseOrder>> _orders = Orders.watchAll();
  OrderStatus? _status;
  PaymentStatus? _payment;
  String _q = '';

  Future<void> _refresh() async {
    setState(() => _orders = Orders.watchAll());
  }

  List<PurchaseOrder> _filter(List<PurchaseOrder> all) => all.where((o) {
        if (_status != null && o.status != _status) return false;
        if (_payment != null && o.payment != _payment) return false;
        if (_q.isNotEmpty &&
            !o.number.toLowerCase().contains(_q) &&
            !o.customerName.toLowerCase().contains(_q) &&
            !o.customerRef.toLowerCase().contains(_q)) {
          return false;
        }
        return true;
      }).toList();

  Future<void> _export(List<PurchaseOrder> list, {required bool print}) async {
    final rows = <List<String>>[];
    var total = 0.0, unpaid = 0.0;
    for (final o in list) {
      if (o.status != OrderStatus.cancelled) {
        total += o.effectiveAmount;
        if (o.payment != PaymentStatus.paid) unpaid += o.effectiveAmount;
      }
      rows.add([
        o.number,
        fmtOrderDate(o.completedAt ?? o.createdAt),
        o.customerName,
        o.customerRef,
        count(o.units),
        money(o.effectiveAmount),
        orderStatusLabel(o.status),
        paymentStatusLabel(o.payment),
        o.invoice == null ? '' : 'Yes',
      ]);
    }
    final t = TableData(
      title: 'Purchase orders',
      headers: const ['Order', 'Date', 'Customer', 'Their ref', 'Units', 'Amount', 'Status', 'Payment', 'Invoice'],
      rows: rows,
      numericColumns: const {4, 5},
      totals: ['TOTAL', '${list.length} orders', '', '', '', money(total), '', 'Unpaid ${money(unpaid)}', ''],
    );
    final filters = [
      if (_status != null) 'Status: ${orderStatusLabel(_status!)}',
      if (_payment != null) 'Payment: ${paymentStatusLabel(_payment!)}',
      if (_q.isNotEmpty) 'Search: $_q',
    ].join('   ');
    try {
      if (print) {
        await printTable(t, filterText: filters);
      } else {
        await shareTable(t, filterText: filters);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Session.isAdmin(context)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Purchase orders')),
        body: const EmptyState(icon: Icons.lock_outline, title: 'Only admins can view purchase orders'),
      );
    }

    return StreamBuilder<List<PurchaseOrder>>(
      stream: _orders,
      builder: (context, snap) {
        final all = snap.data ?? const <PurchaseOrder>[];
        final list = _filter(all);
        final live = list.where((o) => o.status != OrderStatus.cancelled);
        final total = live.fold<double>(0, (a, o) => a + o.effectiveAmount);
        final unpaid = live.where((o) => o.payment != PaymentStatus.paid).fold<double>(0, (a, o) => a + o.effectiveAmount);
        final drafts = all.where((o) => o.status == OrderStatus.draft).length;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Purchase orders'),
            actions: [
              IconButton(
                tooltip: 'Share list as PDF',
                icon: const Icon(Icons.share_outlined),
                onPressed: list.isEmpty ? null : () => _export(list, print: false),
              ),
              IconButton(
                tooltip: 'Print list',
                icon: const Icon(Icons.print_outlined),
                onPressed: list.isEmpty ? null : () => _export(list, print: true),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const OrderFormScreen(), fullscreenDialog: true),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Order'),
          ),
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
              children: [
                StatsRow([
                  ('Orders', count(list.length)),
                  ('Total', money(total)),
                  ('Unpaid', money(unpaid)),
                ]),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search order no., customer or reference',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(label: const Text('All'), selected: _status == null, onSelected: (_) => setState(() => _status = null)),
                    ChoiceChip(
                      label: Text('Drafts${drafts > 0 ? ' ($drafts)' : ''}'),
                      selected: _status == OrderStatus.draft,
                      onSelected: (_) => setState(() => _status = OrderStatus.draft),
                    ),
                    ChoiceChip(
                      label: const Text('Completed'),
                      selected: _status == OrderStatus.completed,
                      onSelected: (_) => setState(() => _status = OrderStatus.completed),
                    ),
                    ChoiceChip(
                      label: const Text('Cancelled'),
                      selected: _status == OrderStatus.cancelled,
                      onSelected: (_) => setState(() => _status = OrderStatus.cancelled),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final p in [null, ...PaymentStatus.values])
                      FilterChip(
                        label: Text(p == null ? 'Any payment' : paymentStatusLabel(p)),
                        selected: _payment == p,
                        onSelected: (_) => setState(() => _payment = p),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (snap.hasError)
                  ErrorState(snap.error!)
                else if (!snap.hasData)
                  const Loading()
                else if (list.isEmpty)
                  EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: all.isEmpty ? 'No purchase orders yet' : 'No orders match',
                    hint: all.isEmpty ? 'Tap “+ Order” when a customer wants to buy products.' : null,
                  )
                else
                  for (final o in list) _OrderTile(order: o),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OrderTile extends StatelessWidget {
  final PurchaseOrder order;
  const _OrderTile({required this.order});

  @override
  Widget build(BuildContext context) {
    final o = order;
    final scheme = Theme.of(context).colorScheme;
    final (Color sBg, Color sFg) = switch (o.status) {
      OrderStatus.draft => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      OrderStatus.completed => (Colors.green.withValues(alpha: 0.15), Colors.green.shade800),
      OrderStatus.cancelled => (scheme.errorContainer, scheme.onErrorContainer),
    };
    final (Color pBg, Color pFg) = switch (o.payment) {
      PaymentStatus.paid => (Colors.green.withValues(alpha: 0.15), Colors.green.shade800),
      PaymentStatus.pending => (StockColors.lowBg, StockColors.lowText),
      PaymentStatus.notPaid => (scheme.errorContainer, scheme.onErrorContainer),
    };
    Widget chip(String text, Color bg, Color fg) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
        );

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => OrderFormScreen(order: o), fullscreenDialog: true),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(o.customerName.isEmpty ? '(no customer)' : o.customerName,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  Text(money(o.effectiveAmount), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${o.number} · ${fmtOrderDate(o.completedAt ?? o.createdAt)} · '
                '${o.lines.length} product${o.lines.length == 1 ? '' : 's'}, ${o.units} units',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  chip(orderStatusLabel(o.status), sBg, sFg),
                  chip(paymentStatusLabel(o.payment), pBg, pFg),
                  if (o.invoice != null)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.attach_file, size: 16, color: scheme.onSurfaceVariant),
                      Text('Invoice', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ]),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
