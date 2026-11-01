import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../auth.dart';
import '../data.dart';
import '../widgets.dart';

/// Admin: link app stores to Odoo shops and control the Odoo stock sync.
/// The sync itself runs on GitHub Actions every ~5 minutes (sync/odoo_sync.py).
class OdooSyncScreen extends StatefulWidget {
  const OdooSyncScreen({super.key});

  @override
  State<OdooSyncScreen> createState() => _OdooSyncScreenState();
}

class _OdooSyncScreenState extends State<OdooSyncScreen> {
  static final _fs = FirebaseFirestore.instance;
  DocumentReference<Map<String, dynamic>> get _config => _fs.collection('odooSync').doc('config');
  DocumentReference<Map<String, dynamic>> get _catalog => _fs.collection('odooSync').doc('catalog');
  DocumentReference<Map<String, dynamic>> get _state => _fs.collection('odooSync').doc('state');

  Map<String, dynamic>? _cfg;
  Map<String, dynamic> _cat = const {};
  Map<String, dynamic> _st = const {};
  List<Store> _stores = const [];
  Map<String, String> _companyNames = const {};
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _pending = const [];
  Object? _error;
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    void onError(Object e) {
      if (mounted) setState(() => _error = e);
    }

    _subs.add(_config.snapshots().listen((d) => setState(() => _cfg = d.data() ?? {}), onError: onError));
    _subs.add(_catalog.snapshots().listen((d) => setState(() => _cat = d.data() ?? {}), onError: onError));
    _subs.add(_state.snapshots().listen((d) => setState(() => _st = d.data() ?? {}), onError: onError));
    _subs.add(Db.watchStores().listen((v) => setState(() => _stores = v), onError: onError));
    _subs.add(Db.watchCompanies().listen((v) => setState(() => _companyNames = {for (final c in v) c.id: c.name}),
        onError: onError));
    _subs.add(_fs.collection('odooPending').snapshots().listen((s) => setState(() => _pending = s.docs), onError: onError));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> get _shops =>
      [for (final s in (_cat['shops'] as List?) ?? const []) if (s is Map) s.cast<String, dynamic>()];

  /// {odooShopId (as String): companyId | "all"}; a shop is synced if it has a value.
  Map<String, dynamic> get _shopMap => ((_cfg?['shops'] as Map?) ?? const {}).cast<String, dynamic>();

  /// Same rule as the sync program: the store name contains "display".
  static bool _isDisplayStore(String name) => name.toLowerCase().contains('display');

  Future<void> _update(Map<String, dynamic> data) async {
    try {
      await _config.set({...data, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _setEnabled(bool v) async {
    if (v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Start syncing POS sales?'),
          content: const Text(
            'From now on, every paid sale at a synced Odoo shop will reduce stock in the “Display Store” '
            'of the product’s company, and refunds will add it back. Other stores are never changed. '
            'Sales made before now are not counted.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
          ],
        ),
      );
      if (ok != true) return;
      // Only count sales from this moment on (unless sync was already started before).
      await _update({'enabled': true, if (_cfg?['startFrom'] == null) 'startFrom': FieldValue.serverTimestamp()});
    } else {
      await _update({'enabled': false});
    }
  }

  Future<void> _setPush(bool v) async {
    if (v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Send app stock to Odoo?'),
          content: const Text(
            'Odoo stock in each synced shop will be set to match the app’s Display Store stock '
            '(inventory adjustments in Odoo). '
            'The app is the master: if the two differ, Odoo is corrected.\n\n'
            'Tip: run the sync with this OFF for a day first, and check the stock audit shows POS sales correctly.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Turn on')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _update({'pushEnabled': v});
  }

  String _when(Object? v) {
    if (v is! Timestamp) return 'never';
    final d = v.toDate();
    final ago = DateTime.now().difference(d);
    String two(int n) => n.toString().padLeft(2, '0');
    final rel = ago.inMinutes < 1
        ? 'just now'
        : ago.inMinutes < 60
            ? '${ago.inMinutes} min ago'
            : ago.inHours < 24
                ? '${ago.inHours} h ago'
                : '${ago.inDays} days ago';
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)} ($rel)';
  }

  @override
  Widget build(BuildContext context) {
    if (!Session.isAdmin(context)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Odoo sync')),
        body: const EmptyState(icon: Icons.lock_outline, title: 'Only admins can manage the Odoo sync'),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final cfg = _cfg;
    final enabled = cfg?['enabled'] == true;
    final push = cfg?['pushEnabled'] == true;
    final lastError = (_st['lastError'] as String?) ?? '';
    final stats = ((_st['lastStats'] as Map?) ?? const {}).cast<String, dynamic>();
    final lastRun = _st['lastRunAt'];
    final stale = lastRun is Timestamp && DateTime.now().difference(lastRun.toDate()).inMinutes > 30;

    return Scaffold(
      appBar: AppBar(title: const Text('Odoo sync')),
      body: _error != null
          ? ErrorState(_error!)
          : cfg == null
              ? const Loading()
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // ---- Status ----
                    Card(
                      color: lastError.isNotEmpty
                          ? scheme.errorContainer
                          : (lastRun == null || stale ? StockColors.lowBg : Colors.green.withValues(alpha: 0.12)),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(lastError.isNotEmpty
                                  ? Icons.error_outline
                                  : (lastRun == null ? Icons.hourglass_empty : Icons.sync)),
                              const SizedBox(width: 8),
                              Text(
                                lastRun == null
                                    ? 'Waiting for the first sync run'
                                    : lastError.isNotEmpty
                                        ? 'Last sync failed'
                                        : 'Sync is running',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                              ),
                            ]),
                            const SizedBox(height: 8),
                            Text('Last run: ${_when(lastRun)}'),
                            Text('Last successful: ${_when(_st['lastOkAt'])}'),
                            if (stats.isNotEmpty)
                              Text('Last run: ${(stats['odoo_products_created'] ?? 0)} products added to Odoo, '
                                  '${(stats['odoo_products_updated'] ?? 0)} updated, '
                                  '${stats['lines_applied'] ?? 0} POS lines applied, '
                                  '${stats['odoo_updates'] ?? 0} Odoo stock updates'
                                  '${(stats['unmatched'] ?? 0) > 0 ? ', ${stats['unmatched']} unmatched' : ''}'),
                            if (lastError.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(lastError, style: TextStyle(color: scheme.onErrorContainer)),
                              ),
                            if (lastRun == null)
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: Text('Finish the GitHub setup (see README → Odoo sync). '
                                    'Once it runs, your Odoo shops appear below.'),
                              ),
                            if (stale && lastError.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: Text('No run for over 30 minutes. Check GitHub → Actions → “Odoo stock sync”.'),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ---- Switches ----
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Sync with the Odoo till'),
                      subtitle: const Text('Display Store products are added to Odoo automatically. Sales reduce '
                          'Display Store stock, refunds add it back (stock audit).'),
                      value: enabled,
                      onChanged: _setEnabled,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Send app stock to Odoo'),
                      subtitle: const Text('Keeps Odoo stock equal to the Display Store stock'),
                      value: push,
                      onChanged: enabled ? _setPush : null,
                    ),
                    if (cfg['startFrom'] is Timestamp)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('Counting POS sales from ${_when(cfg['startFrom'])}',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),

                    // ---- Display Stores ----
                    const SectionTitle('Display Stores'),
                    Text(
                      'Only the store with “Display” in its name (e.g. “Display Store”) in each company is linked to Odoo.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    for (final entry in _companyNames.entries)
                      Builder(builder: (context) {
                        final has = _stores.any((st) => st.companyId == entry.key && _isDisplayStore(st.name));
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(has ? Icons.check_circle : Icons.error_outline,
                              color: has ? Colors.green.shade700 : scheme.error),
                          title: Text(entry.value),
                          subtitle: Text(has
                              ? 'Display store: ${_stores.where((st) => st.companyId == entry.key && _isDisplayStore(st.name)).map((st) => st.name).join(', ')}'
                              : 'No store with “Display” in its name: its products won’t go to Odoo'),
                        );
                      }),

                    // ---- Odoo shops ----
                    SectionTitle('Odoo shops to sync (${_shopMap.values.where((v) => v != null).length})'),
                    if (_shops.isEmpty)
                      Text('No Odoo shops found yet. They appear here after the first successful sync run.',
                          style: TextStyle(color: scheme.onSurfaceVariant))
                    else
                      for (final sh in _shops)
                        Builder(builder: (context) {
                          final key = '${sh['id']}';
                          final value = _shopMap[key] as String?;
                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text('${sh['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                                    subtitle: Text((sh['locationName'] ?? '') == ''
                                        ? 'Odoo shop'
                                        : 'Stock location: ${sh['locationName']}'),
                                    value: value != null,
                                    onChanged: (on) => _update({'shops': {..._shopMap, key: on ? 'all' : null}}),
                                  ),
                                  if (value != null)
                                    InputDecorator(
                                      decoration: const InputDecoration(
                                        labelText: 'Sells products of',
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          isExpanded: true,
                                          value: value == 'all' || _companyNames.containsKey(value) ? value : 'all',
                                          items: [
                                            const DropdownMenuItem(
                                              value: 'all',
                                              child: Text('All companies (matched by barcode)'),
                                            ),
                                            for (final c in _companyNames.entries)
                                              DropdownMenuItem(value: c.key, child: Text('Only ${c.value}')),
                                          ],
                                          onChanged: (v) => _update({'shops': {..._shopMap, key: v ?? 'all'}}),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        }),

                    // ---- Unmatched sales ----
                    SectionTitle('Unmatched POS sales (${_pending.length})'),
                    if (_pending.isEmpty)
                      Text('None. Every POS sale matched a product in the app.',
                          style: TextStyle(color: scheme.onSurfaceVariant))
                    else ...[
                      Text(
                        'These Odoo sales couldn’t be matched to a Display Store product. Fix the reason shown (e.g. give '
                        'the Display Store product the same barcode/SKU) and they’re applied automatically on the next run.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 8),
                      for (final p in _pending)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text((p.data()['name'] as String?)?.isNotEmpty == true ? p.data()['name'] : 'Unknown product'),
                            subtitle: Text(
                              'Barcode ${(p.data()['barcode'] as String?)?.isNotEmpty == true ? p.data()['barcode'] : (p.data()['code'] ?? '—')}'
                              ' · ${(p.data()['qty'] ?? 0) > 0 ? 'sold' : 'refunded'} ${((p.data()['qty'] ?? 0) as num).abs()}'
                              ' · ${p.data()['order'] ?? ''}'
                              '${(p.data()['reason'] as String?)?.isNotEmpty == true ? '\n${p.data()['reason']}' : ''}',
                            ),
                            trailing: IconButton(
                              tooltip: 'Ignore this sale',
                              icon: const Icon(Icons.close),
                              onPressed: () async {
                                final ok = await confirmDelete(
                                  context,
                                  title: 'Ignore this sale?',
                                  message: 'Its stock will not be taken from the app.',
                                );
                                if (ok) await p.reference.delete();
                              },
                            ),
                          ),
                        ),
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
    );
  }
}
