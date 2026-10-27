import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';
import 'company_form_screen.dart';
import 'product_form_screen.dart';

class CompanyDetailScreen extends StatefulWidget {
  final String companyId;
  const CompanyDetailScreen({super.key, required this.companyId});

  @override
  State<CompanyDetailScreen> createState() => _CompanyDetailScreenState();
}

class _CompanyDetailScreenState extends State<CompanyDetailScreen> {
  late final Stream<Company?> _company = Db.watchCompany(widget.companyId);
  late final Stream<List<Product>> _products = Db.watchProducts(companyId: widget.companyId);
  bool _deleting = false;

  String _details(Product p) {
    final parts = [formatPrice(p.price), p.description].where((x) => x.isNotEmpty);
    return parts.isEmpty ? 'No details' : parts.join(' · ');
  }

  Future<void> _deleteCompany(Company company, int productCount) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete company?',
      message: '“${company.name}” and its $productCount product(s) will be permanently deleted.',
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

  Future<void> _removeProduct(Company company, Product p) async {
    final ok = await confirmDelete(
      context,
      title: 'Remove product?',
      message: '“${p.name}” will be removed from ${company.name}.',
    );
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
    return StreamBuilder<Company?>(
      stream: _company,
      builder: (context, companySnap) {
        if (companySnap.hasError) return Scaffold(appBar: AppBar(), body: ErrorState(companySnap.error!));
        if (companySnap.connectionState == ConnectionState.waiting && !companySnap.hasData) {
          return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
        }
        final company = companySnap.data;
        if (company == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(icon: Icons.delete_outline, title: 'This company no longer exists'),
          );
        }

        return StreamBuilder<List<Product>>(
          stream: _products,
          builder: (context, productSnap) {
            final products = productSnap.data;
            return Scaffold(
              appBar: AppBar(
                title: Text(company.name),
                actions: [
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
                    onPressed: _deleting ? null : () => _deleteCompany(company, products?.length ?? 0),
                  ),
                ],
              ),
              floatingActionButton: FloatingActionButton.extended(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProductFormScreen(companyId: company.id),
                    fullscreenDialog: true,
                  ),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Product'),
              ),
              body: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(company.name, style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 6),
                          Text(
                            company.description.isEmpty ? 'No description' : company.description,
                            style: TextStyle(
                              color: company.description.isEmpty
                                  ? Theme.of(context).colorScheme.onSurfaceVariant
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
                    child: Text(
                      'PRODUCTS (${products?.length ?? 0})',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 0.8),
                    ),
                  ),
                  if (productSnap.hasError)
                    ErrorState(productSnap.error!)
                  else if (products == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (products.isEmpty)
                    const EmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: 'No products yet',
                      hint: 'Tap “+ Product” to add one to this company.',
                    )
                  else
                    for (final p in products)
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            _details(p),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove ${p.name}',
                            icon: Icon(Icons.remove_circle_outline, color: Theme.of(context).colorScheme.error),
                            onPressed: () => _removeProduct(company, p),
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ProductFormScreen(companyId: company.id, product: p),
                              fullscreenDialog: true,
                            ),
                          ),
                        ),
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
