import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';
import 'import_screen.dart';
import 'product_form_screen.dart';
import 'store_form_screen.dart';
import 'tables_screen.dart';

/// One store, its products, and stock counting.
class StoreDetailScreen extends StatefulWidget {
  final String storeId;
  const StoreDetailScreen({super.key, required this.storeId});

  @override
  State<StoreDetailScreen> createState() => _StoreDetailScreenState();
}

class _StoreDetailScreenState extends State<StoreDetailScreen> {
  late final Stream<Store?> _store = Db.watchStore(widget.storeId);
  late final Stream<List<Product>> _products = Db.watchProducts(storeId: widget.storeId);
  String _search = '';
  bool _deleting = false;

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
      await Db.adjustQuantity(p.id, delta);
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
      await Db.deleteProduct(p.id);
      if (mounted) showMessage(context, 'Product removed');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
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

        return StreamBuilder<List<Product>>(
          stream: _products,
          builder: (context, productSnap) {
            final all = productSnap.data;
            final q = _search.trim().toLowerCase();
            final products = (all ?? const <Product>[])
                .where((p) => q.isEmpty || p.name.toLowerCase().contains(q) || p.sku.toLowerCase().contains(q))
                .toList();
            final totalUnits = (all ?? const <Product>[]).fold<int>(0, (sum, p) => sum + p.quantity);
            final totalValue = (all ?? const <Product>[]).fold<double>(0, (sum, p) => sum + p.value);

            return Scaffold(
              appBar: AppBar(
                title: Text(store.name),
                actions: [
                  IconButton(
                    tooltip: 'Import products from Excel',
                    icon: const Icon(Icons.upload_file),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ImportScreen(
                          companyId: store.companyId,
                          storeId: store.id,
                          storeName: store.name,
                        ),
                        fullscreenDialog: true,
                      ),
                    ),
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
                  IconButton(
                    tooltip: 'Edit store',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StoreFormScreen(companyId: store.companyId, store: store),
                        fullscreenDialog: true,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete store',
                    icon: _deleting
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.delete_outline),
                    onPressed: _deleting ? null : () => _deleteStore(store, all?.length ?? 0),
                  ),
                ],
              ),
              floatingActionButton: FloatingActionButton.extended(
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
              body: ListView(
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
                    ('Stock value', money(totalValue)),
                  ]),
                  const SizedBox(height: 16),
                  TextField(
                    decoration: const InputDecoration(hintText: 'Search name or SKU', prefixIcon: Icon(Icons.search)),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                  SectionTitle('Products (${products.length})'),
                  if (productSnap.hasError)
                    ErrorState(productSnap.error!)
                  else if (all == null)
                    const Loading()
                  else if (products.isEmpty)
                    q.isEmpty
                        ? const EmptyState(
                            icon: Icons.inventory_2_outlined,
                            title: 'No products yet',
                            hint: 'Tap “+ Product” to add one to this store.',
                          )
                        : const EmptyState(icon: Icons.search_off, title: 'No matches')
                  else
                    for (final p in products) _ProductCard(
                      product: p,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ProductFormScreen(companyId: store.companyId, storeId: store.id, product: p),
                          fullscreenDialog: true,
                        ),
                      ),
                      onMinus: p.quantity > 0 ? () => _adjust(p, -1) : null,
                      onPlus: () => _adjust(p, 1),
                      onCount: () => _setCount(p),
                      onDelete: () => _removeProduct(p),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _ProductCard extends StatelessWidget {
  final Product product;
  final VoidCallback onTap;
  final VoidCallback? onMinus;
  final VoidCallback onPlus;
  final VoidCallback onCount;
  final VoidCallback onDelete;

  const _ProductCard({
    required this.product,
    required this.onTap,
    required this.onMinus,
    required this.onPlus,
    required this.onCount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = product;
    final details = [
      if (p.sku.isNotEmpty) 'SKU ${p.sku}',
      if (p.price != null) formatPrice(p.price),
      if (p.price != null) 'Value ${money(p.value)}',
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onDelete,
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
                  ],
                ),
              ),
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
                  child: Text(
                    count(p.quantity),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: p.quantity == 0 ? scheme.error : null,
                    ),
                  ),
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Add one',
                visualDensity: VisualDensity.compact,
                onPressed: onPlus,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
