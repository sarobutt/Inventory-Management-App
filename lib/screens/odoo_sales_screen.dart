import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../widgets.dart';

/// Admin: every Odoo till sale/refund the sync has applied to the app's stock,
/// newest first, plus sales it could not match to a product and the sync's health.
///
/// Reads odooProcessed (one doc per till line applied), odooPending (unmatched lines)
/// and odooSync/state, all written by sync/odoo_sync.py.
class OdooSalesScreen extends StatefulWidget {
  const OdooSalesScreen({super.key});

  @override
  State<OdooSalesScreen> createState() => _OdooSalesScreenState();
}

class _OdooSalesScreenState extends State<OdooSalesScreen> {
  static final _fs = FirebaseFirestore.instance;
  static const _pageSize = 100;

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _sales = const [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _pending = const [];
  Map<String, dynamic> _st = const {};
  bool _loaded = false;
  int _limit = _pageSize;
  Object? _error;
  final _subs = <StreamSubscription<dynamic>>[];
  StreamSubscription<dynamic>? _salesSub;

  @override
  void initState() {
    super.initState();
    _listenSales();
    _subs.add(_fs.collection('odooPending').snapshots().listen(
        (s) => setState(() => _pending = s.docs), onError: _onError));
    _subs.add(_fs.collection('odooSync').doc('state').snapshots().listen(
        (d) => setState(() => _st = d.data() ?? const {}), onError: _onError));
  }

  void _onError(Object e) {
    if (mounted) setState(() => _error = e);
  }

  void _listenSales() {
    _salesSub?.cancel();
    _salesSub = _fs
        .collection('odooProcessed')
        .orderBy('at', descending: true)
        .limit(_limit)
        .snapshots()
        .listen((s) => setState(() {
              _sales = s.docs;
              _loaded = true;
            }), onError: _onError);
  }

  @override
  void dispose() {
    _salesSub?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
  static String _day(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${_two(d.day)}/${_two(d.month)}/${d.year}';
  }

  String _ago(Object? v) {
    if (v is! Timestamp) return 'never';
    final d = v.toDate();
    final m = DateTime.now().difference(d).inMinutes;
    if (m < 1) return 'just now';
    if (m < 60) return '$m min ago';
    return '${_day(d)} ${_time(d)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Today's totals.
    final now = DateTime.now();
    var soldToday = 0;
    var refundedToday = 0;
    final ordersToday = <String>{};
    for (final doc in _sales) {
      final d = doc.data();
      final at = d['at'];
      if (at is! Timestamp) continue;
      final t = at.toDate();
      if (t.year != now.year || t.month != now.month || t.day != now.day) continue;
      final q = (d['qty'] as num?)?.toInt() ?? 0;
      if (q > 0) soldToday += q;
      if (q < 0) refundedToday += -q;
      ordersToday.add((d['order'] as String?) ?? '');
    }

    final lastOk = _st['lastOkAt'];
    final lastError = (_st['lastError'] as String?) ?? '';
    final stale = lastOk is! Timestamp || now.difference(lastOk.toDate()).inMinutes > 15;
    final check = (_st['ordersCheck'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};

    final children = <Widget>[
      // ---- sync health ----
      Card(
        color: lastError.isNotEmpty || stale ? scheme.errorContainer : scheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(lastError.isNotEmpty || stale ? Icons.warning_amber_rounded : Icons.check_circle_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  lastError.isNotEmpty
                      ? 'Sync has a problem'
                      : stale
                          ? 'Sync has not checked Odoo recently'
                          : 'Sync is checking Odoo every 2 minutes',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text('Last check: ${_ago(lastOk)}'),
            if (check.isNotEmpty) ...[
              Text('Till orders in Odoo (last 2 days): ${check['recentOrders'] ?? 0}'),
              if ((check['tillsTicked'] as num? ?? 0) == 0)
                Text('No till is ticked in Profile → Odoo sync, so sales are ignored.',
                    style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
            ],
            if (lastError.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text(lastError)),
            if (stale && lastError.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Check GitHub → Actions → Odoo sync is running.'),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      StatsRow([
        ('Orders today', '${ordersToday.length}'),
        ('Items sold', '$soldToday'),
        ('Refunded', '$refundedToday'),
      ]),

      // ---- unmatched ----
      if (_pending.isNotEmpty) ...[
        SectionTitle('Not taken off stock (${_pending.length})'),
        for (final p in _pending)
          Card(
            color: scheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.help_outline),
              title: Text(((p.data()['name'] as String?) ?? '').isEmpty ? 'Unknown product' : p.data()['name'] as String),
              subtitle: Text([
                'Order ${p.data()['order'] ?? ''} · qty ${p.data()['qty'] ?? ''}',
                if (((p.data()['barcode'] as String?) ?? '').isNotEmpty) 'Barcode ${p.data()['barcode']}',
                (p.data()['reason'] as String?) ?? '',
              ].where((s) => s.isNotEmpty).join('\n')),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'These sales did not match a product in a Display Store. Fix the barcode or move the product '
            'into its Display Store — the sync retries every 2 minutes.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      ],

      // ---- applied sales, grouped by day ----
      SectionTitle('Stock taken off by Odoo sales'),
    ];

    if (!_loaded) {
      children.add(const Loading());
    } else if (_sales.isEmpty) {
      children.add(const EmptyState(
        icon: Icons.point_of_sale,
        title: 'No Odoo sales yet',
        hint: 'After a sale is paid on the till, it shows here within about 2–5 minutes.',
      ));
    } else {
      String? lastDay;
      for (final doc in _sales) {
        final d = doc.data();
        final at = d['at'];
        final t = at is Timestamp ? at.toDate() : null;
        final day = t == null ? 'Just now' : _day(t);
        if (day != lastDay) {
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text(day, style: Theme.of(context).textTheme.titleSmall),
          ));
          lastDay = day;
        }
        children.add(_SaleTile(data: d, time: t == null ? '' : _time(t)));
      }
      if (_sales.length >= _limit) {
        children.add(Center(
          child: TextButton(
            onPressed: () {
              setState(() => _limit += _pageSize);
              _listenSales();
            },
            child: const Text('Show older'),
          ),
        ));
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Odoo sales')),
      body: _error != null
          ? ErrorState(_error!)
          : ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 32), children: children),
    );
  }
}

const _refundColor = Color(0xFF2E7D32);

class _SaleTile extends StatelessWidget {
  final Map<String, dynamic> data;
  final String time;
  const _SaleTile({required this.data, required this.time});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final qty = (data['qty'] as num?)?.toInt() ?? 0;
    final refund = qty < 0;
    final name = (data['productName'] as String?) ?? '';
    final store = (data['storeName'] as String?) ?? '';
    final company = (data['companyName'] as String?) ?? '';
    final before = data['before'] as num?;
    final after = data['after'] as num?;
    final short = data['short'] == true;
    final order = (data['order'] as String?) ?? '';

    final place = [company, store].where((s) => s.isNotEmpty).join(' · ');
    final lines = <String>[
      if (place.isNotEmpty) place,
      [if (order.isNotEmpty) 'Order $order', if (time.isNotEmpty) time].join(' · '),
      if (before != null && after != null) 'Stock $before → $after',
      if (short) 'Till sold more than the app had in stock',
    ].where((s) => s.isNotEmpty).toList();

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: refund ? _refundColor.withValues(alpha: 0.15) : scheme.primaryContainer,
          child: Icon(refund ? Icons.undo : Icons.shopping_bag_outlined,
              color: refund ? _refundColor : scheme.onPrimaryContainer),
        ),
        title: Text(name.isEmpty ? 'Product' : name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(lines.join('\n'),
            style: short ? TextStyle(color: scheme.error) : null),
        isThreeLine: lines.length > 1,
        trailing: Text(
          refund ? '+${-qty}' : '−$qty',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: refund ? _refundColor : scheme.error,
              ),
        ),
      ),
    );
  }
}
