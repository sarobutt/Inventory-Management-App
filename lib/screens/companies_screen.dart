import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';
import 'company_detail_screen.dart';
import 'company_form_screen.dart';

class CompaniesScreen extends StatefulWidget {
  const CompaniesScreen({super.key});

  @override
  State<CompaniesScreen> createState() => _CompaniesScreenState();
}

class _CompaniesScreenState extends State<CompaniesScreen> {
  final _companies = Db.watchCompanies();
  final _products = Db.watchProducts();
  String _search = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Companies')),
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
          if (!companySnap.hasData) return const Center(child: CircularProgressIndicator());

          return StreamBuilder<List<Product>>(
            stream: _products,
            builder: (context, productSnap) {
              final counts = <String, int>{};
              for (final p in productSnap.data ?? const <Product>[]) {
                counts[p.companyId] = (counts[p.companyId] ?? 0) + 1;
              }

              final q = _search.trim().toLowerCase();
              final companies =
                  companySnap.data!.where((c) => q.isEmpty || c.name.toLowerCase().contains(q)).toList();

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                children: [
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
                        subtitle: Text('${counts[c.id] ?? 0} product${(counts[c.id] ?? 0) == 1 ? '' : 's'}'),
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
          );
        },
      ),
    );
  }
}
