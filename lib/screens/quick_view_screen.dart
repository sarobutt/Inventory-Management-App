import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../data.dart';
import '../widgets.dart';
import 'scanner_screen.dart';
import 'store_detail_screen.dart';

/// Opens the scanner straight away, then shows where the scanned product is.
Future<void> openQuickView(BuildContext context) async {
  final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScannerScreen()));
  if (code == null || !context.mounted) return;
  await Navigator.push(context, MaterialPageRoute(builder: (_) => QuickViewScreen(initialQuery: code)));
}

/// Quick view: find a product by barcode (or name) and see every store that holds it.
class QuickViewScreen extends StatefulWidget {
  final String initialQuery;
  const QuickViewScreen({super.key, this.initialQuery = ''});

  @override
  State<QuickViewScreen> createState() => _QuickViewScreenState();
}

class _QuickViewScreenState extends State<QuickViewScreen> {
  late final _search = TextEditingController(text: widget.initialQuery);
  late String _q = widget.initialQuery.trim().toLowerCase();
  List<Product>? _products;
  Map<String, Store> _stores = const {};
  Map<String, String> _companyNames = const {};
  Object? _error;
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    void onError(Object e) {
      if (mounted) setState(() => _error = e);
    }

    _subs.add(Db.watchProducts().listen((v) => setState(() => _products = v), onError: onError));
    _subs.add(Db.watchStores().listen((v) => setState(() => _stores = {for (final s in v) s.id: s}), onError: onError));
    _subs.add(Db.watchCompanies().listen((v) => setState(() => _companyNames = {for (final c in v) c.id: c.name}),
        onError: onError));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _search.dispose();
    super.dispose();
  }

  Future<void> _scanAgain() async {
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (code == null || !mounted) return;
    setState(() {
      _search.text = code;
      _q = code.trim().toLowerCase();
    });
  }

  static String _key(Product p) =>
      p.sku.trim().isNotEmpty ? 'sku:${p.sku.trim().toLowerCase()}' : 'name:${p.name.trim().toLowerCase()}';

  @override
  Widget build(BuildContext context) {
    final isAdmin = Session.isAdmin(context);
    final scheme = Theme.of(context).colorScheme;
    final products = _products;

    // Exact barcode matches first; otherwise products whose name or SKU contains the text.
    var matches = <Product>[];
    var exact = false;
    if (products != null && _q.isNotEmpty) {
      matches = products.where((p) => p.sku.trim().toLowerCase() == _q).toList();
      exact = matches.isNotEmpty;
      if (!exact) {
        matches = products
            .where((p) => p.name.toLowerCase().contains(_q) || p.sku.toLowerCase().contains(_q))
            .toList();
      }
    }
    final groups = <String, List<Product>>{};
    for (final p in matches) {
      groups.putIfAbsent(_key(p), () => []).add(p);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Quick view')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanAgain,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: 'Barcode, SKU or product name',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() {
                        _search.clear();
                        _q = '';
                      }),
                    ),
            ),
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            ErrorState(_error!)
          else if (products == null)
            const Loading()
          else if (_q.isEmpty)
            const EmptyState(
              icon: Icons.qr_code_scanner,
              title: 'Scan a product',
              hint: 'Tap Scan, or type a barcode or name, to see which stores have it.',
            )
          else if (groups.isEmpty)
            EmptyState(
              icon: Icons.search_off,
              title: 'Not found in any store',
              hint: '“${_search.text.trim()}” isn’t in the system yet.',
            )
          else
            for (final g in groups.values) _ProductLocations(
              products: g,
              stores: _stores,
              companyNames: _companyNames,
              isAdmin: isAdmin,
              scheme: scheme,
            ),
          if (!exact && groups.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${groups.length} products match “${_search.text.trim()}”.',
                  textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}

class _ProductLocations extends StatelessWidget {
  final List<Product> products;
  final Map<String, Store> stores;
  final Map<String, String> companyNames;
  final bool isAdmin;
  final ColorScheme scheme;

  const _ProductLocations({
    required this.products,
    required this.stores,
    required this.companyNames,
    required this.isAdmin,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final first = products.first;
    final total = products.fold<int>(0, (a, p) => a + p.quantity);
    final sorted = [...products]..sort((a, b) => b.quantity.compareTo(a.quantity));
    final prices = first.prices;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(first.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              [
                if (first.sku.isNotEmpty) 'SKU ${first.sku}',
                if (prices.retail != null) 'Retail ${formatPrice(prices.retail)}',
                if (isAdmin && prices.wholesale != null) 'Wholesale ${formatPrice(prices.wholesale)}',
                if (isAdmin && prices.cost != null) 'Cost ${formatPrice(prices.cost)}',
              ].join(' · '),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Text(
              'In ${products.length} store${products.length == 1 ? '' : 's'} · $total in stock in total',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const Divider(height: 20),
            for (final p in sorted)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.storefront_outlined,
                  color: p.isOutOfStock ? scheme.error : (p.needsOrdering ? StockColors.lowText : null),
                ),
                title: Text(stores[p.storeId]?.name ?? 'Unknown store',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text([
                      companyNames[p.companyId] ?? '',
                      if ((stores[p.storeId]?.address ?? '').isNotEmpty) stores[p.storeId]!.address,
                    ].where((s) => s.isNotEmpty).join(' · ')),
                    if (p.needsOrdering)
                      Padding(padding: const EdgeInsets.only(top: 4), child: StockStatusChip(product: p)),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      count(p.quantity),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: p.isOutOfStock ? scheme.error : (p.needsOrdering ? StockColors.lowText : null),
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => StoreDetailScreen(storeId: p.storeId)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
