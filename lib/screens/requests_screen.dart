import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth.dart';
import '../data.dart';
import '../requests.dart';
import '../widgets.dart';
import 'audit_screen.dart';

String _when(DateTime? d) {
  if (d == null) return 'just now';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Admin: Pending approvals + History.  Staff: their own requests.
class RequestsScreen extends StatelessWidget {
  const RequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = Session.of(context);
    if (me == null) return const Scaffold(body: Loading());

    if (!me.isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('My stock requests')),
        body: _RequestList(stream: StockRequests.watchMine(me.uid), admin: false, emptyText: 'You haven’t made any requests yet.'),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Stock requests'),
          actions: [
            IconButton(
              tooltip: 'Approvals audit',
              icon: const Icon(Icons.fact_check_outlined),
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ApprovalAuditScreen())),
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Pending'), Tab(text: 'History')]),
        ),
        body: TabBarView(
          children: [
            _RequestList(
              stream: StockRequests.watchPending(),
              admin: true,
              emptyText: 'No requests waiting for approval.',
              showApproveAll: true,
            ),
            _RequestList(stream: StockRequests.watchRecent(), admin: true, emptyText: 'No requests yet.'),
          ],
        ),
      ),
    );
  }
}

class _RequestList extends StatelessWidget {
  final Stream<List<StockRequest>> stream;
  final bool admin;
  final String emptyText;
  final bool showApproveAll;

  const _RequestList({required this.stream, required this.admin, required this.emptyText, this.showApproveAll = false});

  Future<void> _approveAll(BuildContext context, List<StockRequest> pending) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve all?'),
        content: Text('Apply all ${pending.length} pending stock changes?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Approve all')),
        ],
      ),
    );
    if (ok != true) return;
    var done = 0, failed = 0;
    for (final r in pending) {
      try {
        await StockRequests.approve(r);
        done++;
      } catch (_) {
        failed++;
      }
    }
    if (context.mounted) {
      showMessage(context, failed == 0 ? 'Approved $done request(s)' : 'Approved $done, $failed could not be approved');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<StockRequest>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) return ErrorState(snap.error!);
        if (!snap.hasData) return const Loading();
        final list = snap.data!;
        if (list.isEmpty) return EmptyState(icon: Icons.inbox_outlined, title: emptyText);
        final pending = list.where((r) => r.isPending).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
          children: [
            if (showApproveAll && pending.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.tonalIcon(
                  onPressed: () => _approveAll(context, pending),
                  icon: const Icon(Icons.done_all),
                  label: Text('Approve all ${pending.length}'),
                ),
              ),
            for (final r in list) _RequestCard(request: r, admin: admin),
          ],
        );
      },
    );
  }
}

class _RequestCard extends StatefulWidget {
  final StockRequest request;
  final bool admin;
  const _RequestCard({required this.request, required this.admin});

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, e is StateError ? e.message : 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject request?'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Reason (optional)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Reject')),
        ],
      ),
    );
    if (reason == null) return;
    await _run(() => StockRequests.reject(widget.request, reason: reason), 'Request rejected');
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final scheme = Theme.of(context).colorScheme;
    final adding = r.delta > 0;

    final (Color chipBg, Color chipFg, String statusText) = switch (r.status) {
      RequestStatus.pending => (scheme.tertiaryContainer, scheme.onTertiaryContainer, 'Pending'),
      RequestStatus.approved => (scheme.primaryContainer, scheme.onPrimaryContainer, 'Approved'),
      RequestStatus.rejected => (scheme.errorContainer, scheme.onErrorContainer, 'Rejected'),
      RequestStatus.cancelled => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, 'Cancelled'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: adding ? Colors.green.withValues(alpha: 0.15) : scheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    r.deltaLabel,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: adding ? Colors.green.shade800 : scheme.onErrorContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.productName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      Text(r.storeName, style: TextStyle(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(20)),
                  child: Text(statusText, style: TextStyle(color: chipFg, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('Requested by ${r.requestedByName} · ${_when(r.createdAt)}',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            if (r.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('“${r.note}”')),
            if (!r.isPending && r.decidedByName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '$statusText by ${r.decidedByName} · ${_when(r.decidedAt)}'
                  '${r.quantityBefore != null ? ' · Stock ${r.quantityBefore} → ${r.quantityAfter}' : ''}'
                  '${r.decisionNote.isNotEmpty ? '\nReason: ${r.decisionNote}' : ''}',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                ),
              ),
            if (r.isPending) ...[
              const SizedBox(height: 10),
              if (_busy)
                const LinearProgressIndicator()
              else if (widget.admin)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _reject,
                        style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                        icon: const Icon(Icons.close),
                        label: const Text('Reject'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _run(() => StockRequests.approve(r), 'Approved: stock updated'),
                        icon: const Icon(Icons.check),
                        label: const Text('Approve'),
                      ),
                    ),
                  ],
                )
              else
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _run(() => StockRequests.cancel(r), 'Request cancelled'),
                    icon: const Icon(Icons.undo),
                    label: const Text('Cancel request'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Staff: bottom sheet to request adding or removing stock for one product.
Future<void> showStockRequestSheet(BuildContext context, {required Product product, required String storeName}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _StockRequestSheet(product: product, storeName: storeName),
    ),
  );
}

class _StockRequestSheet extends StatefulWidget {
  final Product product;
  final String storeName;
  const _StockRequestSheet({required this.product, required this.storeName});

  @override
  State<_StockRequestSheet> createState() => _StockRequestSheetState();
}

class _StockRequestSheetState extends State<_StockRequestSheet> {
  bool _adding = true;
  final _qty = TextEditingController(text: '1');
  final _note = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  void _step(int d) {
    final v = (int.tryParse(_qty.text) ?? 0) + d;
    setState(() => _qty.text = '${v < 1 ? 1 : v}');
  }

  Future<void> _send() async {
    final n = int.tryParse(_qty.text.trim()) ?? 0;
    if (n < 1) {
      setState(() => _error = 'Enter a quantity of 1 or more');
      return;
    }
    if (!_adding && n > widget.product.quantity) {
      setState(() => _error = 'Only ${widget.product.quantity} in stock');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await StockRequests.create(
        product: widget.product,
        storeName: widget.storeName,
        delta: _adding ? n : -n,
        note: _note.text,
      );
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        messenger.showSnackBar(const SnackBar(content: Text('Request sent to admin for approval')));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = 'Could not send: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: Theme.of(context).textTheme.titleLarge),
            Text('In stock now: ${p.quantity}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Add stock'), icon: Icon(Icons.add)),
                ButtonSegment(value: false, label: Text('Remove stock'), icon: Icon(Icons.remove)),
              ],
              selected: {_adding},
              onSelectionChanged: (s) => setState(() => _adding = s.first),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                IconButton.filledTonal(onPressed: () => _step(-1), icon: const Icon(Icons.remove)),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _qty,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    decoration: const InputDecoration(labelText: 'Quantity'),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(onPressed: () => _step(1), icon: const Icon(Icons.add)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. delivery received, damaged'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _sending
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: const Text('Send for approval'),
            ),
          ],
        ),
      ),
    );
  }
}
