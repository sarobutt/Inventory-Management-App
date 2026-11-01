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

  Map<String, dynamic> get _storeMap => ((_cfg?['storeMap'] as Map?) ?? const {}).cast<String, dynamic>();

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
            'From now on, every paid sale at a linked Odoo shop will reduce stock in the matching app store, '
            'and refunds will add it back. Sales made before now are not counted.',
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
            'Odoo stock in each linked shop will be set to match the app (inventory adjustments in Odoo). '
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
                              Text('Last run: ${stats['lines_applied'] ?? 0} POS lines applied, '
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
                      title: const Text('Sync POS sales into the app'),
                      subtitle: const Text('Sales reduce stock, refunds add it back (logged in the stock audit)'),
                      value: enabled,
                      onChanged: _setEnabled,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Send app stock to Odoo'),
                      subtitle: const Text('Keeps Odoo stock equal to the app for linked stores'),
                      value: push,
                      onChanged: enabled ? _setPush : null,
                    ),
                    if (cfg['startFrom'] is Timestamp)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('Counting POS sales from ${_when(cfg['startFrom'])}',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),

                    // ---- Store links ----
                    SectionTitle('Link stores to Odoo shops (${_storeMap.values.where((v) => v != null).length} linked)'),
                    if (_shops.isEmpty)
                      Text('No Odoo shops found yet. They appear here after the first successful sync run.',
                          style: TextStyle(color: scheme.onSurfaceVariant))
                    else
                      for (final s in _stores)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: '${s.name} · ${_companyNames[s.companyId] ?? ''}',
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int?>(
                                isExpanded: true,
                                value: _shops.any((sh) => sh['id'] == _storeMap[s.id]) ? _storeMap[s.id] as int? : null,
                                items: [
                                  const DropdownMenuItem<int?>(value: null, child: Text('Not linked')),
                                  for (final sh in _shops)
                                    DropdownMenuItem<int?>(
                                      value: sh['id'] as int?,
                                      child: Text(
                                        '${sh['name']}${(sh['locationName'] ?? '') != '' ? '  (${sh['locationName']})' : ''}',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: (v) => _update({'storeMap': {..._storeMap, s.id: v}}),
                              ),
                            ),
                          ),
                        ),

                    // ---- Unmatched sales ----
                    SectionTitle('Unmatched POS sales (${_pending.length})'),
                    if (_pending.isEmpty)
                      Text('None. Every POS sale matched a product in the app.',
                          style: TextStyle(color: scheme.onSurfaceVariant))
                    else ...[
                      Text(
                        'These Odoo sales have a barcode that isn’t in the linked app store. Give the app product the '
                        'same barcode/SKU (or add it) and they’ll be applied automatically on the next run.',
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
                              ' · ${_stores.where((s) => s.id == p.data()['storeId']).firstOrNull?.name ?? ''}'
                              ' · ${p.data()['order'] ?? ''}',
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
