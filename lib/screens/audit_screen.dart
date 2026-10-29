import 'dart:async';

import 'package:flutter/material.dart';

import '../audit.dart';
import '../auth.dart';
import '../data.dart';
import '../report.dart';
import '../widgets.dart';

enum _Direction { all, added, removed }

enum _Range { today, week, month, thisMonth, custom }

/// Admin: full stock audit with filters (date, user, company, store, product, added/removed),
/// totals, and print / share as PDF.
class AuditScreen extends StatefulWidget {
  final String? companyId;
  final String? storeId;
  final String? productId;
  final String? productName;

  const AuditScreen({super.key, this.companyId, this.storeId, this.productId, this.productName});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  // Date range (inclusive). Defaults to the last 30 days.
  _Range _range = _Range.month;
  late DateTimeRange _dates = _rangeFor(_Range.month);

  late String? _companyId = widget.companyId;
  late String? _storeId = widget.storeId;
  late String? _productId = widget.productId;
  late String? _productLabel = widget.productName;
  String? _userId;
  _Direction _direction = _Direction.all;

  List<AuditEntry>? _entries;
  Object? _error;
  StreamSubscription<List<AuditEntry>>? _sub;

  List<Company> _companies = const [];
  List<Store> _stores = const [];
  List<AppUser> _users = const [];
  final _subs = <StreamSubscription<dynamic>>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _listen();
    _subs.add(Db.watchCompanies().listen((v) => setState(() => _companies = v), onError: (_) {}));
    _subs.add(Db.watchStores().listen((v) => setState(() => _stores = v), onError: (_) {}));
    _subs.add(Auth.watchUsers().listen((v) => setState(() => _users = v), onError: (_) {}));
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  static DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
  static DateTime _endOfDay(DateTime d) => DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

  static DateTimeRange _rangeFor(_Range r) {
    final now = DateTime.now();
    final today = _startOfDay(now);
    switch (r) {
      case _Range.today:
        return DateTimeRange(start: today, end: _endOfDay(now));
      case _Range.week:
        return DateTimeRange(start: today.subtract(const Duration(days: 6)), end: _endOfDay(now));
      case _Range.month:
        return DateTimeRange(start: today.subtract(const Duration(days: 29)), end: _endOfDay(now));
      case _Range.thisMonth:
        return DateTimeRange(start: DateTime(now.year, now.month, 1), end: _endOfDay(now));
      case _Range.custom:
        return DateTimeRange(start: today, end: _endOfDay(now));
    }
  }

  void _listen() {
    _sub?.cancel();
    setState(() {
      _entries = null;
      _error = null;
    });
    _sub = Audit.watch(from: _dates.start, to: _dates.end).listen(
      (v) => setState(() => _entries = v),
      onError: (Object e) => setState(() => _error = e),
    );
  }

  Future<void> _pickRange(_Range r) async {
    if (r != _Range.custom) {
      setState(() {
        _range = r;
        _dates = _rangeFor(r);
      });
      _listen();
      return;
    }
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: DateTimeRange(start: _dates.start, end: _startOfDay(_dates.end)),
      helpText: 'Choose audit period',
    );
    if (picked == null) return;
    setState(() {
      _range = _Range.custom;
      _dates = DateTimeRange(start: _startOfDay(picked.start), end: _endOfDay(picked.end));
    });
    _listen();
  }

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}';
  }

  String _fmtDateTime(DateTime? d) {
    if (d == null) return 'just now';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${_fmtDate(d)} ${two(d.hour)}:${two(d.minute)}';
  }

  String _storeName(AuditEntry e) {
    for (final s in _stores) {
      if (s.id == e.storeId) return s.name;
    }
    return e.storeName.isEmpty ? '(deleted store)' : e.storeName;
  }

  String _companyName(AuditEntry e) {
    for (final c in _companies) {
      if (c.id == e.companyId) return c.name;
    }
    return e.companyName.isEmpty ? '(deleted company)' : e.companyName;
  }

  List<AuditEntry> get _filtered {
    final all = _entries ?? const <AuditEntry>[];
    return all.where((e) {
      if (_companyId != null && e.companyId != _companyId) return false;
      if (_storeId != null && e.storeId != _storeId) return false;
      if (_productId != null && e.productId != _productId) return false;
      if (_userId != null && e.userId != _userId && e.approvedById != _userId) return false;
      if (_direction == _Direction.added && e.delta <= 0) return false;
      if (_direction == _Direction.removed && e.delta >= 0) return false;
      return true;
    }).toList();
  }

  bool get _hasFilters =>
      _companyId != null || _storeId != null || _productId != null || _userId != null || _direction != _Direction.all;

  void _clearFilters() => setState(() {
        _companyId = null;
        _storeId = null;
        _productId = null;
        _productLabel = null;
        _userId = null;
        _direction = _Direction.all;
      });

  String get _filterText {
    final parts = <String>['${_fmtDate(_dates.start)} – ${_fmtDate(_dates.end)}'];
    if (_companyId != null) {
      final c = _companies.where((x) => x.id == _companyId).firstOrNull;
      if (c != null) parts.add('Company: ${c.name}');
    }
    if (_storeId != null) {
      final s = _stores.where((x) => x.id == _storeId).firstOrNull;
      if (s != null) parts.add('Store: ${s.name}');
    }
    if (_productId != null) parts.add('Product: ${_productLabel ?? ''}');
    if (_userId != null) {
      final u = _users.where((x) => x.uid == _userId).firstOrNull;
      if (u != null) parts.add('User: ${u.displayName.isEmpty ? u.username : u.displayName}');
    }
    if (_direction == _Direction.added) parts.add('Added only');
    if (_direction == _Direction.removed) parts.add('Removed only');
    return parts.join('   ');
  }

  TableData _table(List<AuditEntry> list) {
    var added = 0, removed = 0;
    final rows = <List<String>>[];
    for (final e in list) {
      if (e.delta > 0) added += e.delta;
      if (e.delta < 0) removed += -e.delta;
      rows.add([
        _fmtDateTime(e.createdAt),
        e.productName,
        e.sku,
        _storeName(e),
        _companyName(e),
        e.deltaLabel,
        '${e.quantityBefore}',
        '${e.quantityAfter}',
        auditTypeLabel(e.type),
        e.userName,
        e.approvedByName,
        e.note,
      ]);
    }
    return TableData(
      title: 'Stock audit',
      headers: const [
        'Date', 'Product', 'SKU', 'Store', 'Company', 'Change', 'Before', 'After', 'Type', 'By', 'Approved by', 'Note',
      ],
      rows: rows,
      numericColumns: const {5, 6, 7},
      totals: ['TOTAL', '${list.length} movements', '', '', '', 'Net ${added - removed >= 0 ? '+' : ''}${added - removed}',
        '', '', 'Added +$added', 'Removed -$removed', '', ''],
    );
  }

  Future<void> _export(Future<void> Function(TableData t, {String filterText}) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(_table(_filtered), filterText: _filterText);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickProduct() async {
    final entries = _entries ?? const <AuditEntry>[];
    // Products that appear in the loaded period (respecting company/store filters).
    final options = <String, String>{};
    for (final e in entries) {
      if (_companyId != null && e.companyId != _companyId) continue;
      if (_storeId != null && e.storeId != _storeId) continue;
      options.putIfAbsent(e.productId, () => e.sku.isEmpty ? e.productName : '${e.productName} (${e.sku})');
    }
    final picked = await showModalBottomSheet<MapEntry<String, String>?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ProductPicker(options: options),
    );
    if (picked == null) return;
    setState(() {
      _productId = picked.key.isEmpty ? null : picked.key;
      _productLabel = picked.key.isEmpty ? null : picked.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!Session.isAdmin(context)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Stock audit')),
        body: const EmptyState(icon: Icons.lock_outline, title: 'Only admins can view the audit'),
      );
    }

    final list = _filtered;
    var added = 0, removed = 0;
    for (final e in list) {
      if (e.delta > 0) added += e.delta;
      if (e.delta < 0) removed += -e.delta;
    }
    final storesForCompany = _stores.where((s) => _companyId == null || s.companyId == _companyId).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock audit'),
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
              onPressed: _entries == null ? null : () => _export(shareTable),
            ),
            IconButton(
              tooltip: 'Print',
              icon: const Icon(Icons.print_outlined),
              onPressed: _entries == null ? null : () => _export(printTable),
            ),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          // ---- Date range ----
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (r, label) in const [
                (_Range.today, 'Today'),
                (_Range.week, '7 days'),
                (_Range.month, '30 days'),
                (_Range.thisMonth, 'This month'),
              ])
                ChoiceChip(label: Text(label), selected: _range == r, onSelected: (_) => _pickRange(r)),
              ActionChip(
                avatar: const Icon(Icons.date_range, size: 18),
                label: Text(_range == _Range.custom
                    ? '${_fmtDate(_dates.start)} – ${_fmtDate(_dates.end)}'
                    : 'Custom dates'),
                onPressed: () => _pickRange(_Range.custom),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ---- Filters ----
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
          Row(
            children: [
              Expanded(
                child: _Dropdown(
                  label: 'User',
                  value: _userId,
                  allLabel: 'All users',
                  items: {for (final u in _users) u.uid: u.displayName.isEmpty ? u.username : u.displayName},
                  onChanged: (v) => setState(() => _userId = v),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: _pickProduct,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Product',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      suffixIcon: _productId == null
                          ? const Icon(Icons.search, size: 20)
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => setState(() {
                                _productId = null;
                                _productLabel = null;
                              }),
                            ),
                    ),
                    child: Text(
                      _productLabel ?? 'All products',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<_Direction>(
                  segments: const [
                    ButtonSegment(value: _Direction.all, label: Text('All')),
                    ButtonSegment(value: _Direction.added, label: Text('Added'), icon: Icon(Icons.add)),
                    ButtonSegment(value: _Direction.removed, label: Text('Removed'), icon: Icon(Icons.remove)),
                  ],
                  selected: {_direction},
                  onSelectionChanged: (s) => setState(() => _direction = s.first),
                ),
              ),
              if (_hasFilters)
                TextButton(onPressed: _clearFilters, child: const Text('Clear')),
            ],
          ),
          const SizedBox(height: 14),

          // ---- Totals ----
          StatsRow([
            ('Movements', count(list.length)),
            ('Added', '+${count(added)}'),
            ('Removed', '-${count(removed)}'),
          ]),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text(
              'Net change: ${added - removed >= 0 ? '+' : ''}${count(added - removed)} units',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),

          // ---- Entries ----
          if (_error != null)
            ErrorState(_error!)
          else if (_entries == null)
            const Loading()
          else if (list.isEmpty)
            const EmptyState(
              icon: Icons.history,
              title: 'No stock movements',
              hint: 'Try a longer date range or fewer filters.',
            )
          else
            for (final e in list.take(500))
              _AuditTile(
                entry: e,
                storeName: _storeName(e),
                companyName: _companyName(e),
                when: _fmtDateTime(e.createdAt),
              ),
          if (list.length > 500)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Showing the latest 500 of ${list.length}. Print or share to get every movement.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _AuditTile extends StatelessWidget {
  final AuditEntry entry;
  final String storeName;
  final String companyName;
  final String when;

  const _AuditTile({required this.entry, required this.storeName, required this.companyName, required this.when});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final scheme = Theme.of(context).colorScheme;
    final added = e.delta > 0;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 58,
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: added ? Colors.green.withValues(alpha: 0.15) : scheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                e.deltaLabel,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: added ? Colors.green.shade800 : scheme.onErrorContainer,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.productName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  Text('$storeName · $companyName', style: muted),
                  const SizedBox(height: 2),
                  Text(
                    '${auditTypeLabel(e.type)} · Stock ${e.quantityBefore} → ${e.quantityAfter}',
                    style: muted,
                  ),
                  Text(
                    'By ${e.userName.isEmpty ? 'unknown' : e.userName}'
                    '${e.approvedByName.isNotEmpty ? ' · approved by ${e.approvedByName}' : ''}'
                    ' · $when',
                    style: muted,
                  ),
                  if (e.note.isNotEmpty) Text('“${e.note}”', style: muted.copyWith(fontStyle: FontStyle.italic)),
                ],
              ),
            ),
          ],
        ),
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

/// Searchable list of products found in the audit period. Returns MapEntry('', '') for "All products".
class _ProductPicker extends StatefulWidget {
  final Map<String, String> options;
  const _ProductPicker({required this.options});

  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final entries = widget.options.entries
        .where((e) => _q.isEmpty || e.value.toLowerCase().contains(_q.toLowerCase()))
        .toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search product name or SKU', prefixIcon: Icon(Icons.search)),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.all_inclusive),
              title: const Text('All products'),
              onTap: () => Navigator.pop(context, const MapEntry('', '')),
            ),
            const Divider(height: 1),
            Expanded(
              child: entries.isEmpty
                  ? const EmptyState(icon: Icons.search_off, title: 'No products with movements in this period')
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (_, i) => ListTile(
                        title: Text(entries[i].value),
                        onTap: () => Navigator.pop(context, entries[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
