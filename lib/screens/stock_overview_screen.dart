import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../data.dart';
import '../report.dart';
import '../widgets.dart';
import 'quick_view_screen.dart';

/// Admin: overview of stock across stores, focused on what needs ordering.
/// Choose All stores, one company, or one store.
class StockOverviewScreen extends StatefulWidget {
  final String? companyId;
  final String? storeId;
  const StockOverviewScreen({super.key, this.companyId, this.storeId});

  @override
  State<StockOverviewScreen> createState() => _StockOverviewScreenState();
}

class _StockOverviewScreenState extends State<StockOverviewScreen> {
  late String? _companyId = widget.companyId;
  late String? _storeId = widget.storeId;
  bool _onlyNeedsOrdering = true;
  String _q = '';

  List<Product>? _products;
  List<Store> _stores = const [];
  List<Company> _companies = const [];
  Object? _error;
  final _subs = <StreamSubscription<dynamic>>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    void onError(Object e) {
      if (mounted) setState(() => _error = e);
    }

    _subs.add(Db.watchProducts().listen((v) => setState(() => _products = v), onError: onError));
    _subs.add(Db.watchStores().listen((v) => setState(() => _stores = v), onError: onError));
    _subs.add(Db.watchCompanies().listen((v) => setState(() => _companies = v), onError: onError));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  String _storeName(String id) => _stores.where((s) => s.id == id).firstOrNull?.name ?? 'Unknown store';
  String _companyName(String id) => _companies.where((c) => c.id == id).firstOrNull?.name ?? '';

  static String _key(Product p) =>
      p.sku.trim().isNotEmpty ? 'sku:${p.sku.trim().toLowerCase()}' : 'name:${p.name.trim().toLowerCase()}';

  /// 0 = out of stock, 1 = needs ordering, 2 = ok (for sorting most urgent first).
  static int _urgency(Product p) => p.isOutOfStock ? 0 : (p.needsOrdering ? 1 : 2);

  /// Products in the chosen scope (company/store) matching the search.
  List<Product> get _inScope => (_products ?? const <Product>[]).where((p) {
        if (_companyId != null && p.companyId != _companyId) return false;
        if (_storeId != null && p.storeId != _storeId) return false;
        if (_q.isNotEmpty && !p.name.toLowerCase().contains(_q) && !p.sku.toLowerCase().contains(_q)) return false;
        return true;
      }).toList();

  /// Groups of the same product (by SKU/name) across the stores in scope, most urgent first.
  List<List<Product>> _groups(List<Product> scope) {
    final map = <String, List<Product>>{};
    for (final p in scope) {
      map.putIfAbsent(_key(p), () => []).add(p);
    }
    var groups = map.values.toList();
    if (_onlyNeedsOrdering) groups = groups.where((g) => g.any((p) => p.needsOrdering)).toList();
    for (final g in groups) {
      g.sort((a, b) {
        final u = _urgency(a).compareTo(_urgency(b));
        return u != 0 ? u : _storeName(a.storeId).compareTo(_storeName(b.storeId));
      });
    }
    groups.sort((a, b) {
      final u = _urgency(a.first).compareTo(_urgency(b.first));
      return u != 0 ? u : a.first.name.toLowerCase().compareTo(b.first.name.toLowerCase());
    });
    return groups;
  }

  String get _scopeLabel {
    if (_storeId != null) return 'Store: ${_storeName(_storeId!)}';
    if (_companyId != null) return 'Company: ${_companyName(_companyId!)} (all its stores)';
    return 'All stores';
  }

  Future<void> _export({required bool print}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final rows = <List<String>>[];
      final highlights = <int>[];
      for (final g in _groups(_inScope)) {
        for (final p in g) {
          if (_onlyNeedsOrdering && !p.needsOrdering) continue;
          final shortfall = p.effectiveReorderLevel - p.quantity;
          rows.add([
            p.name,
            p.sku,
            _storeName(p.storeId),
            _companyName(p.companyId),
            count(p.quantity),
            count(p.effectiveReorderLevel),
            shortfall > 0 ? count(shortfall) : '',
            p.stockStatus.isEmpty ? 'OK' : p.stockStatus,
          ]);
          highlights.add(p.isOutOfStock ? 2 : (p.needsOrdering ? 1 : 0));
        }
      }
      final t = TableData(
        title: _onlyNeedsOrdering ? 'Products to order' : 'Stock overview',
        headers: const ['Product', 'SKU', 'Store', 'Company', 'In stock', 'Reorder level', 'Below level by', 'Status'],
        rows: rows,
        numericColumns: const {4, 5, 6},
        rowHighlights: highlights,
      );
      if (print) {
        await printTable(t, filterText: _scopeLabel);
      } else {
        await shareTable(t, filterText: _scopeLabel);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Session.isAdmin(context)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Stock overview')),
        body: const EmptyState(icon: Icons.lock_outline, title: 'Only admins can view the stock overview'),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final scope = _inScope;
    final groups = _groups(scope);
    final out = scope.where((p) => p.isOutOfStock).length;
    final low = scope.where((p) => p.needsOrdering && !p.isOutOfStock).length;
    final storesForCompany = _stores.where((s) => _companyId == null || s.companyId == _companyId).toList();
    final singleStore = _storeId != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock overview'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            IconButton(
              tooltip: 'Share as PDF',
              icon: const Icon(Icons.share_outlined),
              onPressed: _products == null ? null : () => _export(print: false),
            ),
            IconButton(
              tooltip: 'Print',
              icon: const Icon(Icons.print_outlined),
              onPressed: _products == null ? null : () => _export(print: true),
            ),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          // ---- Which stores ----
          Row(
            children: [
              Expanded(
                child: _Dropdown(
                  label: 'Company',
                  value: _companyId,
                  allLabel: 'All companies',
                  items: {for (final c in _companies) c.id: c.name},
                  onChanged: (v) => setState(() {
                    _companyId = v;
                    if (_storeId != null && !_stores.any((s) => s.id == _storeId && (v == null || s.companyId == v))) {
                      _storeId = null;
                    }
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Dropdown(
                  label: 'Store',
                  value: _storeId,
                  allLabel: 'All stores',
                  items: {for (final s in storesForCompany) s.id: s.name},
                  onChanged: (v) => setState(() => _storeId = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(hintText: 'Search name or SKU', prefixIcon: Icon(Icons.search), isDense: true),
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                avatar: const Icon(Icons.warning_amber_rounded, size: 18),
                label: const Text('Needs ordering'),
                selected: _onlyNeedsOrdering,
                onSelected: (_) => setState(() => _onlyNeedsOrdering = true),
              ),
              ChoiceChip(
                label: const Text('All products'),
                selected: !_onlyNeedsOrdering,
                onSelected: (_) => setState(() => _onlyNeedsOrdering = false),
              ),
            ],
          ),
          const SizedBox(height: 12),
          StatsRow([
            ('Products', count(scope.length)),
            ('Needs ordering', count(low)),
            ('Out of stock', count(out)),
          ]),
          const SizedBox(height: 12),

          if (_error != null)
            ErrorState(_error!)
          else if (_products == null)
            const Loading()
          else if (groups.isEmpty)
            EmptyState(
              icon: _onlyNeedsOrdering ? Icons.check_circle_outline : Icons.inventory_2_outlined,
              title: _onlyNeedsOrdering ? 'Nothing needs ordering' : 'No products',
              hint: _onlyNeedsOrdering ? 'All products in $_scopeLabel are above their reorder level.' : null,
            )
          else
            for (final g in groups)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => QuickViewScreen(initialQuery: g.first.sku.isNotEmpty ? g.first.sku : g.first.name),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(g.first.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                                  if (g.first.sku.isNotEmpty)
                                    Text('SKU ${g.first.sku}', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                                ],
                              ),
                            ),
                            if (!singleStore && g.length > 1)
                              Text('Total ${count(g.fold<int>(0, (a, p) => a + p.quantity))}',
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final p in g)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  singleStore ? 'In stock' : '${_storeName(p.storeId)} · ${_companyName(p.companyId)}',
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                              ),
                              if (p.needsOrdering) ...[
                                StockStatusChip(product: p),
                                const SizedBox(width: 8),
                              ] else
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Text('OK (≥ ${p.effectiveReorderLevel + 1})',
                                      style: TextStyle(fontSize: 12, color: Colors.green.shade700)),
                                ),
                              SizedBox(
                                width: 44,
                                child: Text(
                                  count(p.quantity),
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: p.isOutOfStock
                                        ? scheme.error
                                        : (p.needsOrdering ? StockColors.lowText : null),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _Dropdown extends StatelessWidget {
  final String label;
  final String? value;
  final String allLabel;
  final Map<String, String> items;
  final ValueChanged<String?> onChanged;

  const _Dropdown({
    required this.label,
    required this.value,
    required this.allLabel,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final safeValue = value != null && items.containsKey(value) ? value : null;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: safeValue,
          isExpanded: true,
          items: [
            DropdownMenuItem<String?>(value: null, child: Text(allLabel)),
            for (final e in items.entries)
              DropdownMenuItem<String?>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
