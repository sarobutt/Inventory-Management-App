import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';
import 'company_detail_screen.dart';
import 'company_form_screen.dart';
import 'tables_screen.dart';

/// Home screen: all companies.
class CompaniesScreen extends StatefulWidget {
  const CompaniesScreen({super.key});

  @override
  State<CompaniesScreen> createState() => _CompaniesScreenState();
}

class _CompaniesScreenState extends State<CompaniesScreen> {
  final _companies = Db.watchCompanies();
  final _stores = Db.watchStores();
  final _products = Db.watchProducts();
  String _search = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory'),
        actions: [
          IconButton(
            tooltip: 'View & print tables',
            icon: const Icon(Icons.table_chart_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TablesScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
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

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                  children: [
                    StatsRow([
                      ('Companies', count(companySnap.data!.length)),
                      ('Stores', count(stores.length)),
                      ('Units in stock', count(products.fold<int>(0, (sum, p) => sum + p.quantity))),
                    ]),
                    const SizedBox(height: 16),
                    TextField(
                      decoration: const InputDecoration(
                        hintText: 'Search companies',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                    const SizedBox(height: 12),
                    if (companies.isEmpty)
                      q.isEmpty
                          ? const EmptyState(
                              icon: Icons.business_outlined,
                              title: 'No companies yet',
                              hint: 'Tap “+ Company” to add your first one.',
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
                );
              },
            ),
          );
        },
      ),
    );
  }
}
