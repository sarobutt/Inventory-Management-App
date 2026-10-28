import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../data.dart';
import '../report.dart';
import '../widgets.dart';

enum TableKind { companies, stores, products }

/// View mode: read-only tables of companies, stores and products,
/// with filters, totals, printing and PDF sharing.
class TablesScreen extends StatefulWidget {
  final String? companyId;
  final String? storeId;
  final TableKind initialTab;

  /// Start with the Products table showing only items that need ordering.
  final bool needsOrderingOnly;

  const TablesScreen({
    super.key,
    this.companyId,
    this.storeId,
    this.initialTab = TableKind.companies,
    this.needsOrderingOnly = false,
  });

  @override
  State<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends State<TablesScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: TableKind.values.length, vsync: this, initialIndex: widget.initialTab.index);

  List<Company>? _companies;
  List<Store>? _stores;
  List<Product>? _products;
  Object? _error;
  final _subs = <StreamSubscription<dynamic>>[];

  late String? _companyId = widget.companyId;
  late String? _storeId = widget.storeId;
  late bool _needsOrderingOnly = widget.needsOrderingOnly;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
    _tabs.addListener(() => setState(() {}));
  }

  void _subscribe() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    void onError(Object e) {
      if (mounted) setState(() => _error = e);
    }

    _subs.add(Db.watchCompanies().listen((v) => setState(() => _companies = v), onError: onError));
    _subs.add(Db.watchStores().listen((v) => setState(() => _stores = v), onError: onError));
    _subs.add(Db.watchProducts().listen((v) => setState(() => _products = v), onError: onError));
  }

  Future<void> _refresh() => pullRefresh(context, Db.refresh, () {
        if (!mounted) return;
        setState(() => _error = null);
        _subscribe();
      });

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _tabs.dispose();
    super.dispose();
  }

  bool get _loaded => _companies != null && _stores != null && _products != null;

  String get _filterText {
    final parts = <String>[];
    if (_companyId != null) {
      final c = _companies?.where((x) => x.id == _companyId).firstOrNull;
      if (c != null) parts.add('Company: ${c.name}');
    }
    if (_storeId != null) {
      final s = _stores?.where((x) => x.id == _storeId).firstOrNull;
      if (s != null) parts.add('Store: ${s.name}');
    }
    return parts.isEmpty ? 'All companies' : parts.join('   ');
  }

  TableData _table(TableKind kind) {
    final companies = _companies!.where((c) => _companyId == null || c.id == _companyId).toList();
    final stores = _stores!
        .where((s) => (_companyId == null || s.companyId == _companyId) && (_storeId == null || s.id == _storeId))
        .toList();
    final products = _products!
        .where((p) => (_companyId == null || p.companyId == _companyId) && (_storeId == null || p.storeId == _storeId))
        .toList();

    final showPrices = Session.isAdmin(context);
    switch (kind) {
      case TableKind.companies:
        return companiesTable(companies, stores, products, showPrices: showPrices);
      case TableKind.stores:
        return storesTable(stores, _companies!, products, showPrices: showPrices);
      case TableKind.products:
        return productsTable(products, _companies!, _stores!,
            showPrices: showPrices, needsOrderingOnly: _needsOrderingOnly);
    }
  }

  Future<void> _run(Future<void> Function(TableData t, {String filterText}) action) async {
    if (!_loaded || _busy) return;
    setState(() => _busy = true);
    try {
      await action(_table(TableKind.values[_tabs.index]), filterText: _filterText);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tables'),
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
              onPressed: _loaded ? () => _run(shareTable) : null,
            ),
            IconButton(
              tooltip: 'Print',
              icon: const Icon(Icons.print_outlined),
              onPressed: _loaded ? () => _run(printTable) : null,
            ),
          ],
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Companies'), Tab(text: 'Stores'), Tab(text: 'Products')],
        ),
      ),
      body: _error != null
          ? ErrorState(_error!)
          : !_loaded
              ? const Loading()
              : Column(
                  children: [
                    _filters(),
                    if (_tabs.index == TableKind.products.index)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FilterChip(
                            avatar: const Icon(Icons.warning_amber_rounded, size: 18),
                            label: const Text('Needs ordering only'),
                            selected: _needsOrderingOnly,
                            onSelected: (v) => setState(() => _needsOrderingOnly = v),
                          ),
                        ),
                      ),
                    Expanded(
                      child: TabBarView(
                        controller: _tabs,
                        children: [for (final k in TableKind.values) _TableView(data: _table(k), onRefresh: _refresh)],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _filters() {
    final storesForCompany = _stores!.where((s) => _companyId == null || s.companyId == _companyId).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: _Dropdown(
              label: 'Company',
              value: _companyId,
              allLabel: 'All companies',
              items: {for (final c in _companies!) c.id: c.name},
              onChanged: (v) => setState(() {
                _companyId = v;
                // Clear the store filter if it belongs to another company.
                if (_storeId != null && !_stores!.any((s) => s.id == _storeId && (v == null || s.companyId == v))) {
                  _storeId = null;
                }
              }),
            ),
          ),
          const SizedBox(width: 10),
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

/// Scrollable (both directions) read-only table with a bold totals row.
class _TableView extends StatelessWidget {
  final TableData data;
  final Future<void> Function() onRefresh;
  const _TableView({required this.data, required this.onRefresh});

  WidgetStateProperty<Color?>? _rowColor(BuildContext context, int row) {
    final level = (data.rowHighlights != null && row < data.rowHighlights!.length) ? data.rowHighlights![row] : 0;
    if (level == 2) return WidgetStatePropertyAll(Theme.of(context).colorScheme.errorContainer);
    if (level == 1) return const WidgetStatePropertyAll(StockColors.lowBg);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (data.rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            EmptyState(icon: Icons.table_rows_outlined, title: 'No records', hint: 'Try changing the filters.'),
          ],
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    const bold = TextStyle(fontWeight: FontWeight.w700);

    DataCell cell(String text, int col, {bool isTotal = false}) => DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(text, overflow: TextOverflow.ellipsis, style: isTotal ? bold : null),
          ),
        );

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: Scrollbar(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(scheme.primaryContainer),
            headingTextStyle: TextStyle(fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
            columnSpacing: 24,
            border: TableBorder.all(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(8)),
            columns: [
              for (var i = 0; i < data.headers.length; i++)
                DataColumn(label: Text(data.headers[i]), numeric: data.numericColumns.contains(i)),
            ],
            rows: [
              for (var ri = 0; ri < data.rows.length; ri++)
                DataRow(
                  color: _rowColor(context, ri),
                  cells: [for (var i = 0; i < data.rows[ri].length; i++) cell(data.rows[ri][i], i)],
                ),
              if (data.totals != null)
                DataRow(
                  color: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
                  cells: [for (var i = 0; i < data.totals!.length; i++) cell(data.totals![i], i, isTotal: true)],
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
