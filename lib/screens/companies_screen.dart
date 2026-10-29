import 'package:flutter/material.dart';

import '../auth.dart';
import '../brand.dart';
import '../data.dart';
import '../requests.dart';
import '../widgets.dart';
import 'audit_screen.dart';
import 'company_detail_screen.dart';
import 'company_form_screen.dart';
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

  Future<void> _refresh() => pullRefresh(context, Db.refresh, () {
        if (!mounted) return;
        setState(() {
          _companies = Db.watchCompanies();
          _stores = Db.watchStores();
          _products = Db.watchProducts();
        });
      });

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
