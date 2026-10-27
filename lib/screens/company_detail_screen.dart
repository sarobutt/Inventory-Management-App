import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';
import 'company_form_screen.dart';
import 'store_detail_screen.dart';
import 'store_form_screen.dart';
import 'tables_screen.dart';

/// One company and its stores.
class CompanyDetailScreen extends StatefulWidget {
  final String companyId;
  const CompanyDetailScreen({super.key, required this.companyId});

  @override
  State<CompanyDetailScreen> createState() => _CompanyDetailScreenState();
}

class _CompanyDetailScreenState extends State<CompanyDetailScreen> {
  late final Stream<Company?> _company = Db.watchCompany(widget.companyId);
  late final Stream<List<Store>> _stores = Db.watchStores(companyId: widget.companyId);
  late final Stream<List<Product>> _products = Db.watchProducts(companyId: widget.companyId);
  bool _deleting = false;

  Future<void> _deleteCompany(Company company, int stores, int products) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete company?',
      message: '“${company.name}”, its $stores store(s) and $products product(s) will be permanently deleted.',
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    try {
      await Db.deleteCompany(company.id);
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, 'Company deleted');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _deleting = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Company?>(
      stream: _company,
      builder: (context, companySnap) {
        if (companySnap.hasError) return Scaffold(appBar: AppBar(), body: ErrorState(companySnap.error!));
        if (!companySnap.hasData && companySnap.connectionState == ConnectionState.waiting) {
          return Scaffold(appBar: AppBar(), body: const Loading());
        }
        final company = companySnap.data;
        if (company == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(icon: Icons.delete_outline, title: 'This company no longer exists'),
          );
        }

        return StreamBuilder<List<Store>>(
          stream: _stores,
          builder: (context, storeSnap) => StreamBuilder<List<Product>>(
            stream: _products,
            builder: (context, productSnap) {
              final stores = storeSnap.data;
              final products = productSnap.data ?? const <Product>[];

              final productsPerStore = <String, int>{};
              final unitsPerStore = <String, int>{};
              for (final p in products) {
                productsPerStore[p.storeId] = (productsPerStore[p.storeId] ?? 0) + 1;
                unitsPerStore[p.storeId] = (unitsPerStore[p.storeId] ?? 0) + p.quantity;
              }
              final totalUnits = products.fold<int>(0, (sum, p) => sum + p.quantity);
              final totalValue = products.fold<double>(0, (sum, p) => sum + p.value);

              return Scaffold(
                appBar: AppBar(
                  title: Text(company.name),
                  actions: [
                    IconButton(
                      tooltip: 'View & print tables',
                      icon: const Icon(Icons.table_chart_outlined),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TablesScreen(companyId: company.id, initialTab: TableKind.stores),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit company',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CompanyFormScreen(company: company),
                          fullscreenDialog: true,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Delete company',
                      icon: _deleting
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.delete_outline),
                      onPressed: _deleting
                          ? null
                          : () => _deleteCompany(company, stores?.length ?? 0, products.length),
                    ),
                  ],
                ),
                floatingActionButton: FloatingActionButton.extended(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => StoreFormScreen(companyId: company.id),
                      fullscreenDialog: true,
                    ),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Store'),
                ),
                body: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                  children: [
                    if (company.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(company.description, style: Theme.of(context).textTheme.bodyLarge),
                      ),
                    StatsRow([
                      ('Stores', count(stores?.length ?? 0)),
                      ('Units', count(totalUnits)),
                      ('Stock value', money(totalValue)),
                    ]),
                    SectionTitle('Stores (${stores?.length ?? 0})'),
                    if (storeSnap.hasError)
                      ErrorState(storeSnap.error!)
                    else if (stores == null)
                      const Loading()
                    else if (stores.isEmpty)
                      const EmptyState(
                        icon: Icons.storefront_outlined,
                        title: 'No stores yet',
                        hint: 'Tap “+ Store” to add a store to this company.',
                      )
                    else
                      for (final s in stores)
                        Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            leading: const CircleAvatar(child: Icon(Icons.storefront_outlined)),
                            title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              [
                                if (s.address.isNotEmpty) s.address,
                                '${productsPerStore[s.id] ?? 0} products · ${count(unitsPerStore[s.id] ?? 0)} units',
                              ].join('\n'),
                            ),
                            isThreeLine: s.address.isNotEmpty,
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => StoreDetailScreen(storeId: s.id)),
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
    );
  }
}
