import 'package:flutter/material.dart';

import '../auth.dart';
import '../brand.dart';
import '../data.dart';
import '../export.dart';
import '../report.dart';
import '../requests.dart';
import '../widgets.dart';
import 'audit_screen.dart';
import 'company_detail_screen.dart';
import 'company_form_screen.dart';
import 'orders_screen.dart';
import 'quick_view_screen.dart';
import 'profile_screen.dart';
import 'requests_screen.dart';
import 'tables_screen.dart';

/// Home screen: all companies.
class CompaniesScreen extends StatefulWidget {
  const CompaniesScreen({super.key});

  @override
  State<CompaniesScreen> createState() => _CompaniesScreenState();
}

class _CompaniesScreenState extends State<CompaniesScreen> {
  Stream<List<Company>> _companies = Db.watchCompanies();
  Stream<List<Store>> _stores = Db.watchStores();
  Stream<List<Product>> _products = Db.watchProducts();
  String _search = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _exportAll(List<Product> products, List<Company> companies, List<Store> stores,
      {required bool isAdmin}) async {
    final d = DateTime.now();
    final stamp = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    await showExportSheet(
      context,
      title: 'All products',
      fileBaseName: 'products_$stamp',
      pdf: () => buildPdf(productsTable(products, companies, stores, showPrices: isAdmin)),
      xlsx: () async => allProductsXlsx(products, companies, stores, showPrices: isAdmin),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = Session.of(context);
    final isAdmin = me?.isAdmin ?? false;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandBadge(size: 34),
            SizedBox(width: 10),
            Flexible(child: BrandWordmark(fontSize: 20)),
          ],
        ),
        actions: [
          _RequestsButton(isAdmin: isAdmin),
          if (isAdmin)
            IconButton(
              tooltip: 'Stock audit',
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AuditScreen())),
            ),
          IconButton(
            tooltip: 'View & print tables',
            icon: const Icon(Icons.table_chart_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TablesScreen())),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              tooltip: 'My profile',
              icon: CircleAvatar(radius: 15, child: Text(me?.initials ?? '?', style: const TextStyle(fontSize: 12))),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
            ),
          ),
        ],
      ),
      floatingActionButton: !isAdmin
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CompanyFormScreen(), fullscreenDialog: true),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Company'),
            ),
      body: StreamBuilder<List<Company>>(
        stream: _companies,
        builder: (context, companySnap) {
          if (companySnap.hasError) return ErrorState(companySnap.error!);
          if (!companySnap.hasData) return const Loading();

          return StreamBuilder<List<Store>>(
            stream: _stores,
            builder: (context, storeSnap) => StreamBuilder<List<Product>>(
              stream: _products,
              builder: (context, productSnap) {
                final stores = storeSnap.data ?? const <Store>[];
                final products = productSnap.data ?? const <Product>[];

                final storeCount = <String, int>{};
                for (final s in stores) {
                  storeCount[s.companyId] = (storeCount[s.companyId] ?? 0) + 1;
                }
                final unitCount = <String, int>{};
                for (final p in products) {
                  unitCount[p.companyId] = (unitCount[p.companyId] ?? 0) + p.quantity;
                }

                final q = _search.trim().toLowerCase();
                final companies =
                    companySnap.data!.where((c) => q.isEmpty || c.name.toLowerCase().contains(q)).toList();
                final companyName = {for (final c in companySnap.data!) c.id: c.name};
                final storeName = {for (final s in stores) s.id: s.name};
                // Product search: exact barcode first, otherwise name / SKU contains the text.
                var productHits = <Product>[];
                if (q.isNotEmpty) {
                  productHits = products.where((p) => sameBarcode(p.sku, q)).toList();
                  if (productHits.isEmpty) productHits = products.where((p) => productMatches(p.name, p.sku, q)).toList();
                }

                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                  children: [
                    if (me != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Hello, ${me.displayName.isEmpty ? me.username : me.displayName.split(' ').first} (${me.roleLabel})',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: _searchCtrl,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search products (name or barcode) or companies',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _search.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear',
                                  icon: const Icon(Icons.clear),
                                  onPressed: () => setState(() {
                                    _searchCtrl.clear();
                                    _search = '';
                                  }),
                                ),
                        ),
                        onChanged: (v) => setState(() => _search = v),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => openQuickView(context),
                              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                              icon: const Icon(Icons.qr_code_scanner),
                              label: const Text('Quick view'),
                            ),
                          ),
                          if (isAdmin) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.tonalIcon(
                                onPressed: () =>
                                    Navigator.push(context, MaterialPageRoute(builder: (_) => const OrdersScreen())),
                                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                                icon: const Icon(Icons.receipt_long_outlined),
                                label: const Text('Orders'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    StatsRow([
                      ('Companies', count(companySnap.data!.length)),
                      ('Stores', count(stores.length)),
                      ('Units in stock', count(products.fold<int>(0, (sum, p) => sum + p.quantity))),
                    ]),
                    if (products.any((p) => p.needsOrdering)) ...[
                      const SizedBox(height: 12),
                      NeedsOrderingBanner(
                        count: products.where((p) => p.needsOrdering).length,
                        active: false,
                        actionLabel: 'View list',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const TablesScreen(initialTab: TableKind.products, needsOrderingOnly: true),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: products.isEmpty
                            ? null
                            : () => _exportAll(products, companySnap.data!, stores, isAdmin: isAdmin),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('Export all products (Excel, PDF, PNG)'),
                      ),
                    ),
                    if (q.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SectionTitle('Products (${productHits.length})'),
                      if (productHits.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text('No products match.'),
                        ),
                      for (final p in productHits.take(30))
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const Icon(Icons.inventory_2_outlined),
                            title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text([
                              '${companyName[p.companyId] ?? ''} · ${storeName[p.storeId] ?? ''}',
                              [
                                if (p.sku.isNotEmpty) p.sku,
                                if (p.prices.retail != null) 'Retail ${money(p.prices.retail!)}',
                                if (p.expiryDate != null) 'Exp ${formatDate(p.expiryDate)}',
                              ].join(' · '),
                            ].where((t) => t.trim().isNotEmpty).join('\n')),
                            trailing: Text('${p.quantity}',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: p.isOutOfStock ? Theme.of(context).colorScheme.error : null,
                                )),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => QuickViewScreen(initialQuery: p.sku.isNotEmpty ? p.sku : p.name),
                              ),
                            ),
                          ),
                        ),
                      if (productHits.length > 30)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('Showing 30 of ${productHits.length} – type more to narrow it down.'),
                        ),
                      SectionTitle('Companies (${companies.length})'),
                    ] else
                      const SizedBox(height: 8),
                    if (companies.isEmpty)
                      q.isEmpty
                          ? EmptyState(
                              icon: Icons.business_outlined,
                              title: 'No companies yet',
                              hint: isAdmin ? 'Tap “+ Company” to add your first one.' : 'Nothing has been set up yet.',
                            )
                          : const EmptyState(icon: Icons.search_off, title: 'No matches'),
                    for (final c in companies)
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: CircleAvatar(child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase())),
                          title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            '${storeCount[c.id] ?? 0} store${(storeCount[c.id] ?? 0) == 1 ? '' : 's'}'
                            ' · ${count(unitCount[c.id] ?? 0)} units',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => CompanyDetailScreen(companyId: c.id)),
                          ),
                        ),
                      ),
                  ],
                ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// App-bar button to the requests screen. For admins it shows how many are pending.
class _RequestsButton extends StatefulWidget {
  final bool isAdmin;
  const _RequestsButton({required this.isAdmin});

  @override
  State<_RequestsButton> createState() => _RequestsButtonState();
}

class _RequestsButtonState extends State<_RequestsButton> {
  // Created once, so rebuilding the home screen doesn't restart the listener.
  final Stream<List<StockRequest>> _pending = StockRequests.watchPending();

  void _open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const RequestsScreen()));

  @override
  Widget build(BuildContext context) {
    if (!widget.isAdmin) {
      return IconButton(
        tooltip: 'My stock requests',
        icon: const Icon(Icons.pending_actions_outlined),
        onPressed: () => _open(context),
      );
    }
    return StreamBuilder<List<StockRequest>>(
      stream: _pending,
      builder: (context, snap) {
        final n = snap.data?.length ?? 0;
        return IconButton(
          tooltip: 'Stock requests',
          icon: Badge(
            isLabelVisible: n > 0,
            label: Text('$n'),
            child: const Icon(Icons.pending_actions_outlined),
          ),
          onPressed: () => _open(context),
        );
      },
    );
  }
}
