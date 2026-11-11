import 'package:flutter/material.dart';

import '../auth.dart';
import '../data.dart';
import '../requests.dart';
import '../widgets.dart';
import 'audit_screen.dart';
import 'import_screen.dart';
import 'move_products_screen.dart';
import 'product_form_screen.dart';
import 'requests_screen.dart';
import 'scanner_screen.dart';
import 'store_form_screen.dart';
import 'tables_screen.dart';

/// One store and its products.
///  - Admin: full editing, direct stock counting (− / +), import.
///  - Staff: view (no prices) and *request* stock changes for approval.
class StoreDetailScreen extends StatefulWidget {
  final String storeId;
  const StoreDetailScreen({super.key, required this.storeId});

  @override
  State<StoreDetailScreen> createState() => _StoreDetailScreenState();
}

class _StoreDetailScreenState extends State<StoreDetailScreen> {
  late Stream<Store?> _store = Db.watchStore(widget.storeId);
  late Stream<List<Product>> _products = Db.watchProducts(storeId: widget.storeId);
  late Stream<List<StockRequest>> _pending = StockRequests.watchPending(storeId: widget.storeId);
  List<Product> _latest = const [];
  String _search = '';
  bool _onlyNeedsOrdering = false;
  bool _deleting = false;

  Future<void> _refresh() => pullRefresh(context, Db.refresh, () {
        if (!mounted) return;
        setState(() {
          _store = Db.watchStore(widget.storeId);
          _products = Db.watchProducts(storeId: widget.storeId);
          _pending = StockRequests.watchPending(storeId: widget.storeId);
        });
      });

  Future<void> _deleteStore(Store store, int productCount) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete store?',
      message: '“${store.name}” and its $productCount product(s) will be permanently deleted.',
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    try {
      await Db.deleteStore(store.id);
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, 'Store deleted');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _deleting = false);
        showError(context, e);
      }
    }
  }

  Future<void> _adjust(Product p, int delta) async {
    try {
      await Db.adjustQuantity(p, delta);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _setCount(Product p) async {
    final value = await askCount(context, title: 'Count “${p.name}”', initial: p.quantity);
    if (value == null || value == p.quantity) return;
    await _adjust(p, value - p.quantity);
  }

  Future<void> _removeProduct(Product p) async {
    final ok = await confirmDelete(context, title: 'Remove product?', message: '“${p.name}” will be removed.');
    if (!ok) return;
    try {
      await Db.deleteProduct(p);
      if (mounted) showMessage(context, 'Product removed');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _openProduct(Store store, Product p, {required bool isAdmin}) {
    if (isAdmin) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProductFormScreen(companyId: store.companyId, storeId: store.id, product: p),
          fullscreenDialog: true,
        ),
      );
    } else {
      showStockRequestSheet(context, product: p, storeName: store.name);
    }
  }

  /// Scan a barcode to jump to that product in this store.
  Future<void> _scanToFind(Store store, {required bool isAdmin}) async {
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (code == null || !mounted) return;
    final key = code.trim().toLowerCase();
    Product? match;
    for (final p in _latest) {
      if (sameBarcode(p.sku, key)) {
        match = p;
        break;
      }
    }
    if (match != null) {
      showMessage(context, 'Product already exists: ${match.name} (stock ${match.quantity})');
      _openProduct(store, match, isAdmin: isAdmin);
      return;
    }
    if (!isAdmin) {
      showMessage(context, 'No product with barcode $code in this store. Ask an admin to add it.');
      return;
    }
    final noBarcode = _latest.where((p) => p.sku.trim().isEmpty).length;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Not in this store'),
        content: Text('No product with barcode $code here yet.\n\n'
            'If the product is already in the list without a barcode (e.g. imported from a supplier list), '
            'link this barcode to it. Otherwise add it as a new product.'
            '${noBarcode > 0 ? '\n\nProducts here without a barcode: $noBarcode.' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          OutlinedButton(onPressed: () => Navigator.pop(ctx, 'link'), child: const Text('Link to existing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'add'), child: const Text('Add new')),
        ],
      ),
    );
    if (choice == 'link' && mounted) {
      await _linkBarcode(code);
      return;
    }
    if (choice == 'add' && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProductFormScreen(companyId: store.companyId, storeId: store.id, initialSku: code),
          fullscreenDialog: true,
        ),
      );
    }
  }

  /// Pick a product in this store (products without a barcode first) and save [code] as its barcode.
  Future<void> _linkBarcode(String code) async {
    final picked = await showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _LinkBarcodeSheet(code: code, products: _latest),
    );
    if (picked == null || !mounted) return;
    try {
      await Db.setSku(picked.id, code);
      if (mounted) showMessage(context, 'Barcode $code saved for ${picked.name}. Scan the next box.');
    } catch (e) {
      if (mounted) showMessage(context, 'Could not save the barcode: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = Session.isAdmin(context);

    return StreamBuilder<Store?>(
      stream: _store,
      builder: (context, storeSnap) {
        if (storeSnap.hasError) return Scaffold(appBar: AppBar(), body: ErrorState(storeSnap.error!));
        if (!storeSnap.hasData && storeSnap.connectionState == ConnectionState.waiting) {
          return Scaffold(appBar: AppBar(), body: const Loading());
        }
        final store = storeSnap.data;
        if (store == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(icon: Icons.delete_outline, title: 'This store no longer exists'),
          );
        }

        return StreamBuilder<List<StockRequest>>(
          stream: _pending,
          builder: (context, pendingSnap) => StreamBuilder<List<Product>>(
            stream: _products,
            builder: (context, productSnap) {
              final all = productSnap.data;
              _latest = all ?? const [];
              final q = _search.trim().toLowerCase();
              final products = (all ?? const <Product>[])
                  .where((p) => productMatches(p.name, p.sku, q))
                  .where((p) => !_onlyNeedsOrdering || p.needsOrdering)
                  .toList();
              final needOrdering = (all ?? const <Product>[]).where((p) => p.needsOrdering).length;
              final totalUnits = (all ?? const <Product>[]).fold<int>(0, (sum, p) => sum + p.quantity);
              final totalValue = (all ?? const <Product>[]).fold<double>(0, (sum, p) => sum + p.value);

              // Pending request changes per product, e.g. {productId: [+5, -2]}
              final pendingByProduct = <String, List<int>>{};
              for (final r in pendingSnap.data ?? const <StockRequest>[]) {
                pendingByProduct.putIfAbsent(r.productId, () => []).add(r.delta);
              }

              return Scaffold(
                appBar: AppBar(
                  title: Text(store.name),
                  actions: [
                    IconButton(
                      tooltip: 'Scan to find a product',
                      icon: const Icon(Icons.qr_code_scanner),
                      onPressed: () => _scanToFind(store, isAdmin: isAdmin),
                    ),
                    IconButton(
                      tooltip: 'View & print table',
                      icon: const Icon(Icons.print_outlined),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TablesScreen(
                            companyId: store.companyId,
                            storeId: store.id,
                            initialTab: TableKind.products,
                          ),
                        ),
                      ),
                    ),
                    if (isAdmin)
                      _deleting
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : PopupMenuButton<String>(
                              tooltip: 'More',
                              onSelected: (v) {
                                switch (v) {
                                  case 'import':
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ImportScreen(
                                          companyId: store.companyId,
                                          storeId: store.id,
                                          storeName: store.name,
                                        ),
                                        fullscreenDialog: true,
                                      ),
                                    );
                                    break;
                                  case 'edit':
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => StoreFormScreen(companyId: store.companyId, store: store),
                                        fullscreenDialog: true,
                                      ),
                                    );
                                    break;
                                  case 'delete':
                                    _deleteStore(store, all?.length ?? 0);
                                    break;
                                  case 'move':
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => MoveProductsScreen(store: store),
                                        fullscreenDialog: true,
                                      ),
                                    );
                                    break;
                                  case 'history':
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => AuditScreen(companyId: store.companyId, storeId: store.id),
                                      ),
                                    );
                                    break;
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'history',
                                  child: ListTile(leading: Icon(Icons.history), title: Text('Stock history')),
                                ),
                                PopupMenuItem(
                                  value: 'move',
                                  child: ListTile(
                                    leading: Icon(Icons.drive_file_move_outline),
                                    title: Text('Move products…'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'import',
                                  child: ListTile(leading: Icon(Icons.upload_file), title: Text('Import from Excel')),
                                ),
                                PopupMenuItem(
                                  value: 'edit',
                                  child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit store')),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete store')),
                                ),
                              ],
                            ),
                  ],
                ),
                floatingActionButton: !isAdmin
                    ? null
                    : FloatingActionButton.extended(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProductFormScreen(companyId: store.companyId, storeId: store.id),
                            fullscreenDialog: true,
                          ),
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('Product'),
                      ),
                body: RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    children: [
                      if (store.address.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            children: [
                              const Icon(Icons.place_outlined, size: 18),
                              const SizedBox(width: 6),
                              Expanded(child: Text(store.address)),
                            ],
                          ),
                        ),
                      StatsRow([
                        ('Products', count(all?.length ?? 0)),
                        ('Units', count(totalUnits)),
                        if (isAdmin) ('Stock value', money(totalValue)),
                        if (!isAdmin) ('Pending', count(pendingSnap.data?.length ?? 0)),
                      ]),
                      if (!isAdmin)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            'Tap a product (or scan it) to request adding or removing stock. '
                            'An admin approves each request.',
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                      if (needOrdering > 0) ...[
                        const SizedBox(height: 12),
                        NeedsOrderingBanner(
                          count: needOrdering,
                          active: _onlyNeedsOrdering,
                          onTap: () => setState(() => _onlyNeedsOrdering = !_onlyNeedsOrdering),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextField(
                        decoration:
                            const InputDecoration(hintText: 'Search name or SKU', prefixIcon: Icon(Icons.search)),
                        onChanged: (v) => setState(() => _search = v),
                      ),
                      SectionTitle('Products (${products.length})'),
                      if (productSnap.hasError)
                        ErrorState(productSnap.error!)
                      else if (all == null)
                        const Loading()
                      else if (products.isEmpty)
                        q.isEmpty && !_onlyNeedsOrdering
                            ? EmptyState(
                                icon: Icons.inventory_2_outlined,
                                title: 'No products yet',
                                hint: isAdmin ? 'Tap “+ Product” to add one to this store.' : null,
                              )
                            : const EmptyState(icon: Icons.search_off, title: 'No matches')
                      else
                        for (final p in products)
                          _ProductCard(
                            product: p,
                            isAdmin: isAdmin,
                            pending: pendingByProduct[p.id] ?? const [],
                            onTap: () => _openProduct(store, p, isAdmin: isAdmin),
                            onMinus: p.quantity > 0 ? () => _adjust(p, -1) : null,
                            onPlus: () => _adjust(p, 1),
                            onCount: () => _setCount(p),
                            onDelete: () => _removeProduct(p),
                            onRequest: () => showStockRequestSheet(context, product: p, storeName: store.name),
                          ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _ProductCard extends StatelessWidget {
  final Product product;
  final bool isAdmin;
  final List<int> pending;
  final VoidCallback onTap;
  final VoidCallback? onMinus;
  final VoidCallback onPlus;
  final VoidCallback onCount;
  final VoidCallback onDelete;
  final VoidCallback onRequest;

  const _ProductCard({
    required this.product,
    required this.isAdmin,
    required this.pending,
    required this.onTap,
    required this.onMinus,
    required this.onPlus,
    required this.onCount,
    required this.onDelete,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = product;
    final details = [
      if (p.sku.isNotEmpty) 'SKU ${p.sku}',
      if (isAdmin && p.prices.cost != null) 'Cost ${formatPrice(p.prices.cost)}',
      if (isAdmin && p.prices.wholesale != null) 'Wholesale ${formatPrice(p.prices.wholesale)}',
      if (p.prices.retail != null) 'Retail ${formatPrice(p.prices.retail)}',
    ].join(' · ');
    final pendingText = pending.map((d) => d > 0 ? '+$d' : '$d').join(', ');

    final qtyText = Text(
      count(p.quantity),
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: p.isOutOfStock ? scheme.error : (p.needsOrdering ? StockColors.lowText : null),
      ),
    );

    // Highlight low / out-of-stock products.
    final Color? cardColor =
        p.isOutOfStock ? scheme.errorContainer.withValues(alpha: 0.55) : (p.needsOrdering ? StockColors.lowBg : null);
    final BorderSide? border = p.isOutOfStock
        ? BorderSide(color: scheme.error, width: 1.5)
        : (p.needsOrdering ? const BorderSide(color: StockColors.lowBorder, width: 1.5) : null);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: cardColor,
      shape: border == null ? null : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: border),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: isAdmin ? onDelete : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    if (details.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(details, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                      ),
                    if (p.needsOrdering)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: StockStatusChip(product: p),
                      ),
                    if (pending.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'Pending approval: $pendingText',
                            style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (isAdmin) ...[
                // Stock counter:  [-]  12  [+]
                IconButton.filledTonal(
                  tooltip: 'Remove one',
                  visualDensity: VisualDensity.compact,
                  onPressed: onMinus,
                  icon: const Icon(Icons.remove),
                ),
                InkWell(
                  onTap: onCount,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 48),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    alignment: Alignment.center,
                    child: qtyText,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Add one',
                  visualDensity: VisualDensity.compact,
                  onPressed: onPlus,
                  icon: const Icon(Icons.add),
                ),
              ] else ...[
                Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: qtyText),
                FilledButton.tonalIcon(
                  onPressed: onRequest,
                  icon: const Icon(Icons.swap_vert, size: 18),
                  label: const Text('Request'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}


/// List of this store's products to attach a scanned barcode to.
class _LinkBarcodeSheet extends StatefulWidget {
  final String code;
  final List<Product> products;
  const _LinkBarcodeSheet({required this.code, required this.products});

  @override
  State<_LinkBarcodeSheet> createState() => _LinkBarcodeSheetState();
}

class _LinkBarcodeSheetState extends State<_LinkBarcodeSheet> {
  String _q = '';
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final list = widget.products
        .where((p) => _showAll || p.sku.trim().isEmpty)
        .where((p) => _q.isEmpty || p.name.toLowerCase().contains(_q))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Which product is barcode ${widget.code}?', style: Theme.of(context).textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Type part of the name'),
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          ),
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Also show products that already have a barcode'),
          value: _showAll,
          onChanged: (v) => setState(() => _showAll = v),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('No matching products'))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final p = list[i];
                    return ListTile(
                      title: Text(p.name),
                      subtitle: Text(p.sku.trim().isEmpty ? 'No barcode · stock ${p.quantity}' : 'Barcode ${p.sku} · stock ${p.quantity}'),
                      onTap: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Save barcode?'),
                            content: Text(p.sku.trim().isEmpty
                                ? 'Save barcode ${widget.code} for "${p.name}"?'
                                : '"${p.name}" already has barcode ${p.sku}. Replace it with ${widget.code}?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
                            ],
                          ),
                        );
                        if (ok == true && context.mounted) Navigator.pop(context, p);
                      },
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
