import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';

/// Bottom sheet listing every company and its stores. Returns the chosen store,
/// or null. [excludeStoreId] is shown greyed out (the current store).
Future<Store?> pickDestinationStore(BuildContext context, {String? excludeStoreId}) {
  return showModalBottomSheet<Store>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _DestinationPicker(excludeStoreId: excludeStoreId),
  );
}

class _DestinationPicker extends StatefulWidget {
  final String? excludeStoreId;
  const _DestinationPicker({this.excludeStoreId});

  @override
  State<_DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends State<_DestinationPicker> {
  late final Future<(List<Company>, List<Store>)> _data = () async {
    final companies = await Db.watchCompanies().first;
    final stores = await Db.watchStores().first;
    return (companies, stores);
  }();
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Move to which store?', style: Theme.of(context).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                decoration: const InputDecoration(hintText: 'Search company or store', prefixIcon: Icon(Icons.search)),
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
              ),
            ),
            Expanded(
              child: FutureBuilder<(List<Company>, List<Store>)>(
                future: _data,
                builder: (context, snap) {
                  if (snap.hasError) return ErrorState(snap.error!);
                  if (!snap.hasData) return const Loading();
                  final (companies, stores) = snap.data!;
                  final groups = <Widget>[];
                  for (final c in companies) {
                    final cs = stores
                        .where((s) => s.companyId == c.id)
                        .where((s) =>
                            _q.isEmpty || s.name.toLowerCase().contains(_q) || c.name.toLowerCase().contains(_q))
                        .toList();
                    if (cs.isEmpty) continue;
                    groups.add(Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                      child: Text(c.name.toUpperCase(),
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 0.8)),
                    ));
                    for (final s in cs) {
                      final current = s.id == widget.excludeStoreId;
                      groups.add(ListTile(
                        leading: const Icon(Icons.storefront_outlined),
                        title: Text(s.name),
                        subtitle: Text(current ? 'Current store' : (s.address.isEmpty ? c.name : s.address)),
                        enabled: !current,
                        trailing: current ? null : Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                        onTap: current ? null : () => Navigator.pop(context, s),
                      ));
                    }
                  }
                  if (groups.isEmpty) {
                    return const EmptyState(icon: Icons.search_off, title: 'No stores found');
                  }
                  return ListView(children: groups);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks how to handle products whose barcode already exists in the target store.
/// Returns true = merge, false = skip, null = cancel.
Future<bool?> askDuplicateHandling(BuildContext context, List<(Product, Product)> conflicts, Store target) {
  final names = conflicts.take(5).map((c) => '• ${c.$1.name} (SKU ${c.$1.sku})').join('\n');
  final more = conflicts.length > 5 ? '\n…and ${conflicts.length - 5} more' : '';
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: Text('${conflicts.length} already in ${target.name}'),
      content: Text(
        'These barcodes already exist in ${target.name}:\n\n$names$more\n\n'
        'Merge: add their stock to the existing product there and remove the copy here.\n'
        'Skip: leave them where they are.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip these')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Merge stock')),
      ],
    ),
  );
}

/// Full move flow for a list of products: choose destination, resolve duplicates, confirm, move.
/// Returns the result, or null if cancelled.
Future<MoveResult?> runMoveFlow(BuildContext context, List<Product> products, {required String fromStoreId}) async {
  if (products.isEmpty) return null;
  final target = await pickDestinationStore(context, excludeStoreId: fromStoreId);
  if (target == null || !context.mounted) return null;

  // Find barcode clashes in the destination.
  final conflicts = <(Product, Product)>[];
  for (final p in products) {
    final dup = await Db.findInStoreBySku(target.id, p.sku);
    if (dup != null) conflicts.add((p, dup));
  }
  if (!context.mounted) return null;

  var merge = false;
  if (conflicts.isNotEmpty) {
    final choice = await askDuplicateHandling(context, conflicts, target);
    if (choice == null || !context.mounted) return null;
    merge = choice;
  } else {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move ${products.length} product${products.length == 1 ? '' : 's'}?'),
        content: Text(
          'To ${target.name}. Stock, prices, reorder levels and pending requests move with '
          '${products.length == 1 ? 'it' : 'them'}. The move is recorded in the stock audit.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Move')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return null;
  }

  return Db.moveProducts(products, target, mergeDuplicates: merge);
}

/// Admin: choose several products in a store and move them to another store.
class MoveProductsScreen extends StatefulWidget {
  final Store store;
  const MoveProductsScreen({super.key, required this.store});

  @override
  State<MoveProductsScreen> createState() => _MoveProductsScreenState();
}

class _MoveProductsScreenState extends State<MoveProductsScreen> {
  late final Stream<List<Product>> _products = Db.watchProducts(storeId: widget.store.id);
  final Set<String> _selected = {};
  String _q = '';
  bool _moving = false;

  Future<void> _move(List<Product> all) async {
    final chosen = all.where((p) => _selected.contains(p.id)).toList();
    setState(() => _moving = true);
    try {
      final result = await runMoveFlow(context, chosen, fromStoreId: widget.store.id);
      if (!mounted) return;
      if (result == null) {
        setState(() => _moving = false);
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text('Done: ${result.summary}')));
    } catch (e) {
      if (mounted) {
        setState(() => _moving = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Product>>(
      stream: _products,
      builder: (context, snap) {
        final all = snap.data ?? const <Product>[];
        final shown = all
            .where((p) => _q.isEmpty || p.name.toLowerCase().contains(_q) || p.sku.toLowerCase().contains(_q))
            .toList();
        final allShownSelected = shown.isNotEmpty && shown.every((p) => _selected.contains(p.id));

        return Scaffold(
          appBar: AppBar(
            title: Text(_selected.isEmpty ? 'Move products' : '${_selected.length} selected'),
            actions: [
              TextButton(
                onPressed: shown.isEmpty
                    ? null
                    : () => setState(() {
                          if (allShownSelected) {
                            _selected.removeAll(shown.map((p) => p.id));
                          } else {
                            _selected.addAll(shown.map((p) => p.id));
                          }
                        }),
                child: Text(allShownSelected ? 'Select none' : 'Select all'),
              ),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: _selected.isEmpty || _moving ? null : () => _move(all),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: _moving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.drive_file_move_outline),
                label: Text(_selected.isEmpty ? 'Select products to move' : 'Move ${_selected.length} to another store…'),
              ),
            ),
          ),
          body: snap.hasError
              ? ErrorState(snap.error!)
              : !snap.hasData
                  ? const Loading()
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      children: [
                        Text('From ${widget.store.name}',
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 8),
                        TextField(
                          decoration:
                              const InputDecoration(hintText: 'Search name or SKU', prefixIcon: Icon(Icons.search)),
                          onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                        ),
                        const SizedBox(height: 8),
                        if (shown.isEmpty) const EmptyState(icon: Icons.inventory_2_outlined, title: 'No products'),
                        for (final p in shown)
                          CheckboxListTile(
                            value: _selected.contains(p.id),
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(p.id);
                              } else {
                                _selected.remove(p.id);
                              }
                            }),
                            title: Text(p.name),
                            subtitle: Text([if (p.sku.isNotEmpty) 'SKU ${p.sku}', 'Stock ${p.quantity}'].join(' · ')),
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                      ],
                    ),
        );
      },
    );
  }
}
