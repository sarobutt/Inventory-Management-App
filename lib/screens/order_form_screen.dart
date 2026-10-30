import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data.dart';
import '../orders.dart';
import '../report.dart';
import '../widgets.dart';
import 'scanner_screen.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String fmtOrderDate(DateTime? d) =>
    d == null ? '' : '${_two(d.day)}/${_two(d.month)}/${d.year} ${_two(d.hour)}:${_two(d.minute)}';

/// Create, edit and complete a purchase order (admin only).
class OrderFormScreen extends StatefulWidget {
  final PurchaseOrder? order;
  const OrderFormScreen({super.key, this.order});

  @override
  State<OrderFormScreen> createState() => _OrderFormScreenState();
}

class _OrderFormScreenState extends State<OrderFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final String _id = widget.order?.id ?? Orders.newId();
  late final String _number = widget.order?.number ?? Orders.newNumber();
  late final _customer = TextEditingController(text: widget.order?.customerName ?? '');
  late final _phone = TextEditingController(text: widget.order?.customerPhone ?? '');
  late final _email = TextEditingController(text: widget.order?.customerEmail ?? '');
  late final _ref = TextEditingController(text: widget.order?.customerRef ?? '');
  late final _notes = TextEditingController(text: widget.order?.notes ?? '');
  late final _amount = TextEditingController(
    text: (widget.order?.effectiveAmount ?? 0) == 0 ? '' : widget.order!.effectiveAmount.toStringAsFixed(2),
  );
  late List<OrderLine> _lines = [...?widget.order?.lines];
  late PaymentStatus _payment = widget.order?.payment ?? PaymentStatus.notPaid;
  late bool _amountEdited = widget.order?.amount != null;
  late InvoiceInfo? _invoice = widget.order?.invoice;
  (Uint8List, String)? _pendingFile;
  bool _removeInvoice = false;
  bool _busy = false;

  bool get _isNew => widget.order == null;
  OrderStatus get _status => widget.order?.status ?? OrderStatus.draft;
  bool get _isDraft => _status == OrderStatus.draft;

  double get _linesTotal => _lines.fold<double>(0, (a, l) => a + l.total);

  @override
  void dispose() {
    for (final c in [_customer, _phone, _email, _ref, _notes, _amount]) {
      c.dispose();
    }
    super.dispose();
  }

  void _linesChanged() {
    if (!_amountEdited) {
      _amount.text = _linesTotal == 0 ? '' : _linesTotal.toStringAsFixed(2);
    }
  }

  PurchaseOrder _current() {
    final typed = parseMoney(_amount.text);
    return PurchaseOrder(
      id: _id,
      number: _number,
      customerName: _customer.text.trim(),
      customerPhone: _phone.text.trim(),
      customerEmail: _email.text.trim(),
      customerRef: _ref.text.trim(),
      notes: _notes.text.trim(),
      lines: _lines,
      // Only store an amount if it differs from the lines total.
      amount: typed == null || (typed - _linesTotal).abs() < 0.005 ? null : typed,
      payment: _payment,
      status: _status,
      invoice: _invoice,
    );
  }

  // ---------------- Lines ----------------

  Future<void> _addProduct({String? query}) async {
    final line = await showModalBottomSheet<OrderLine>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SourcePicker(existing: _lines, initialQuery: query),
    );
    if (line == null) return;
    setState(() {
      final i = _lines.indexWhere((l) => l.productId == line.productId);
      if (i >= 0) {
        _lines[i] = _lines[i].copyWith(quantity: _lines[i].quantity + line.quantity, unitPrice: line.unitPrice);
      } else {
        _lines = [..._lines, line];
      }
      _linesChanged();
    });
  }

  Future<void> _scan() async {
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (code == null || !mounted) return;
    await _addProduct(query: code);
  }

  Future<void> _editLine(int i) async {
    final l = _lines[i];
    final result = await showLineDialog(context, title: l.productName, quantity: l.quantity, unitPrice: l.unitPrice);
    if (result == null) return;
    setState(() {
      _lines[i] = l.copyWith(quantity: result.$1, unitPrice: result.$2);
      _linesChanged();
    });
  }

  void _removeLine(int i) => setState(() {
        _lines = [..._lines]..removeAt(i);
        _linesChanged();
      });

  // ---------------- Invoice ----------------

  Future<void> _pickInvoice() async {
    try {
      final file = await FilePicker.pickFile();
      if (file == null) return;
      if (!Orders.isSupportedInvoice(file.name)) {
        if (mounted) showMessage(context, 'Please choose a PDF, JPG or PNG file.');
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > Orders.maxInvoiceBytes) {
        if (mounted) showMessage(context, 'That file is over 8 MB. Please choose a smaller file.');
        return;
      }
      setState(() {
        _pendingFile = (bytes, file.name);
        _removeInvoice = false;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _viewInvoice() async {
    final pending = _pendingFile;
    final name = pending?.$2 ?? _invoice?.name ?? 'invoice';
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InvoiceViewerScreen(
          title: name,
          load: () async => pending?.$1 ?? await Orders.downloadInvoice(_id),
          fileName: name,
        ),
      ),
    );
  }

  Future<void> _applyInvoiceChanges() async {
    if (_removeInvoice && _invoice != null) {
      await Orders.deleteInvoice(_id, unlinkOrder: true);
    }
    final f = _pendingFile;
    if (f != null) await Orders.uploadInvoice(_id, f.$1, f.$2);
  }

  // ---------------- Actions ----------------

  Future<void> _run(Future<void> Function() action, String done) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e is StateError) {
        showMessage(context, e.message);
      } else {
        showError(context, e);
      }
    }
  }

  Future<void> _save() => _run(() async {
        await Orders.save(_current(), isNew: _isNew);
        await _applyInvoiceChanges();
      }, _isDraft ? 'Order saved as draft' : 'Order updated');

  Future<void> _complete() async {
    if (!_formKey.currentState!.validate()) return;
    if (_lines.isEmpty) {
      showMessage(context, 'Add at least one product first.');
      return;
    }
    // Summary per store.
    final perStore = <String, (int, int)>{}; // storeName -> (lines, units)
    for (final l in _lines) {
      final v = perStore[l.storeName] ?? (0, 0);
      perStore[l.storeName] = (v.$1 + 1, v.$2 + l.quantity);
    }
    final summary = perStore.entries.map((e) => '• ${e.key}: ${e.value.$2} units (${e.value.$1} products)').join('\n');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Complete order?'),
        content: Text(
          'This will take the stock out of these stores now:\n\n$summary\n\n'
          'Amount: ${money(_current().effectiveAmount)} · ${paymentStatusLabel(_payment)}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Complete & subtract stock')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await Orders.complete(_current());
      await _applyInvoiceChanges();
    }, 'Order completed – stock updated');
  }

  Future<void> _cancelOrder() async {
    final completed = _status == OrderStatus.completed;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this order?'),
        content: Text(completed
            ? 'All ${widget.order!.units} units will be returned to the stores they came from. '
                'This is recorded in the stock audit.'
            : 'The draft will be marked as cancelled.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep order')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(completed ? 'Cancel & return stock' : 'Cancel order'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final missing = await Orders.cancel(widget.order!);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
        content: Text(missing.isEmpty
            ? 'Order cancelled${completed ? ' – stock returned' : ''}'
            : 'Order cancelled. Could not return stock for deleted products: ${missing.join(', ')}'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showMessage(context, e is StateError ? e.message : 'Could not cancel: $e');
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDelete(
      context,
      title: 'Delete order?',
      message: 'Order $_number will be permanently deleted, including its invoice file.',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await Orders.delete(widget.order!);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Order deleted')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showMessage(context, e is StateError ? e.message : 'Could not delete: $e');
    }
  }

  TableData _orderTable() {
    final o = _current();
    return TableData(
      title: 'Purchase order ${o.number}',
      headers: const ['Product', 'SKU', 'From store', 'Qty', 'Unit price', 'Total'],
      rows: [
        for (final l in o.lines)
          [l.productName, l.sku, l.storeName, count(l.quantity), money(l.unitPrice), money(l.total)],
      ],
      numericColumns: const {3, 4, 5},
      totals: ['TOTAL', '', '', count(o.units), '', money(o.linesTotal)],
    );
  }

  String _orderHeader() {
    final o = _current();
    return [
      'Customer: ${o.customerName}',
      if (o.customerRef.isNotEmpty) 'Their ref: ${o.customerRef}',
      if (o.customerPhone.isNotEmpty) o.customerPhone,
      'Status: ${orderStatusLabel(o.status)}',
      'Amount: ${money(o.effectiveAmount)} (${paymentStatusLabel(o.payment)})',
    ].join('   ');
  }

  Future<void> _shareOrder() async {
    try {
      await shareTable(_orderTable(), filterText: _orderHeader());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final o = widget.order;
    final hasInvoice = !_removeInvoice && (_pendingFile != null || _invoice != null);

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'New purchase order' : _number),
          actions: [
            IconButton(
              tooltip: 'Share order as PDF',
              icon: const Icon(Icons.share_outlined),
              onPressed: _lines.isEmpty ? null : _shareOrder,
            ),
            if (!_isNew)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'cancel') _cancelOrder();
                  if (v == 'delete') _delete();
                },
                itemBuilder: (_) => [
                  if (_status != OrderStatus.cancelled)
                    PopupMenuItem(
                      value: 'cancel',
                      child: ListTile(
                        leading: const Icon(Icons.undo),
                        title: Text(_status == OrderStatus.completed ? 'Cancel & return stock' : 'Cancel order'),
                      ),
                    ),
                  if (_status != OrderStatus.completed)
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete order')),
                    ),
                ],
              ),
          ],
        ),
        bottomNavigationBar: _status == OrderStatus.cancelled
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: _busy
                      ? const LinearProgressIndicator()
                      : _isDraft
                          ? Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _save,
                                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                                    child: const Text('Save draft'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 2,
                                  child: FilledButton.icon(
                                    onPressed: _complete,
                                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                                    icon: const Icon(Icons.check_circle_outline),
                                    label: const Text('Complete order'),
                                  ),
                                ),
                              ],
                            )
                          : FilledButton(
                              onPressed: _save,
                              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                              child: const Text('Save changes'),
                            ),
                ),
              ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ---- Status banner ----
              if (o != null && !_isDraft)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _status == OrderStatus.completed ? Colors.green.withValues(alpha: 0.12) : scheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _status == OrderStatus.completed
                        ? 'Completed by ${o.completedByName} · ${fmtOrderDate(o.completedAt)}\n'
                            'Stock has been taken from the stores. Products can no longer be changed; '
                            'customer, amount, payment and invoice can.'
                        : 'Cancelled by ${o.cancelledByName} · ${fmtOrderDate(o.cancelledAt)}',
                  ),
                ),
              if (o != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('Created by ${o.createdByName} · ${fmtOrderDate(o.createdAt)}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),

              // ---- Customer ----
              const SectionTitle('Customer'),
              TextFormField(
                controller: _customer,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Customer / company name *'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Customer name is required' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Phone'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _ref,
                      decoration: const InputDecoration(labelText: 'Their PO / reference'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),

              // ---- Products ----
              SectionTitle('Products (${_lines.length})'),
              if (_lines.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('Add the products the customer wants, and choose which store each one comes from.',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              for (var i = 0; i < _lines.length; i++)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(_lines[i].productName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      'From ${_lines[i].storeName}${_lines[i].sku.isNotEmpty ? ' · SKU ${_lines[i].sku}' : ''}\n'
                      '${_lines[i].quantity} × ${money(_lines[i].unitPrice)} = ${money(_lines[i].total)}',
                    ),
                    isThreeLine: true,
                    onTap: _isDraft ? () => _editLine(i) : null,
                    trailing: _isDraft
                        ? IconButton(
                            tooltip: 'Remove',
                            icon: Icon(Icons.remove_circle_outline, color: scheme.error),
                            onPressed: () => _removeLine(i),
                          )
                        : null,
                  ),
                ),
              if (_isDraft)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => _addProduct(),
                        icon: const Icon(Icons.add),
                        label: const Text('Add product'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.tonalIcon(
                      onPressed: _scan,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan'),
                    ),
                  ],
                ),
              if (_lines.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    'Products total: ${money(_linesTotal)} · ${_lines.fold<int>(0, (a, l) => a + l.quantity)} units',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),

              // ---- Amount & payment ----
              const SectionTitle('Amount & payment'),
              TextFormField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Invoice amount',
                  prefixText: '$currencyCode ',
                  helperText: _amountEdited ? 'Entered manually' : 'Calculated from the products',
                  suffixIcon: _amountEdited && _lines.isNotEmpty
                      ? TextButton(
                          onPressed: () => setState(() {
                            _amountEdited = false;
                            _linesChanged();
                          }),
                          child: const Text('Use total'),
                        )
                      : null,
                ),
                onChanged: (_) => setState(() => _amountEdited = true),
                validator: (v) {
                  if ((v ?? '').trim().isEmpty) return null;
                  final a = parseMoney(v!);
                  return a == null || a < 0 ? 'Enter a valid amount' : null;
                },
              ),
              const SizedBox(height: 12),
              SegmentedButton<PaymentStatus>(
                segments: const [
                  ButtonSegment(value: PaymentStatus.notPaid, label: Text('Not paid'), icon: Icon(Icons.close)),
                  ButtonSegment(value: PaymentStatus.pending, label: Text('Pending'), icon: Icon(Icons.schedule)),
                  ButtonSegment(value: PaymentStatus.paid, label: Text('Paid'), icon: Icon(Icons.check)),
                ],
                selected: {_payment},
                onSelectionChanged: (s) => setState(() => _payment = s.first),
              ),

              // ---- Invoice ----
              const SectionTitle('Invoice'),
              if (hasInvoice)
                Card(
                  child: ListTile(
                    leading: Icon(
                      (_pendingFile?.$2 ?? _invoice?.name ?? '').toLowerCase().endsWith('.pdf')
                          ? Icons.picture_as_pdf_outlined
                          : Icons.image_outlined,
                    ),
                    title: Text(_pendingFile?.$2 ?? _invoice!.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_pendingFile != null ? 'New file – uploads when you save' : _invoice!.sizeLabel),
                    onTap: _viewInvoice,
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'view') _viewInvoice();
                        if (v == 'replace') _pickInvoice();
                        if (v == 'remove') {
                          setState(() {
                            _pendingFile = null;
                            _removeInvoice = true;
                          });
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'view', child: Text('View / share')),
                        PopupMenuItem(value: 'replace', child: Text('Replace')),
                        PopupMenuItem(value: 'remove', child: Text('Remove')),
                      ],
                    ),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: _status == OrderStatus.cancelled ? null : _pickInvoice,
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload invoice (PDF, JPG or PNG)'),
                ),

              // ---- Notes ----
              const SectionTitle('Notes'),
              TextFormField(
                controller: _notes,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Delivery details, terms, etc.'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quantity + unit price dialog. [maxQuantity] limits the quantity (stock available).
Future<(int, double)?> showLineDialog(
  BuildContext context, {
  required String title,
  required int quantity,
  required double unitPrice,
  int? maxQuantity,
  String? subtitle,
}) {
  final qty = TextEditingController(text: '$quantity');
  final price = TextEditingController(text: unitPrice == 0 ? '' : unitPrice.toStringAsFixed(2));
  final key = GlobalKey<FormState>();
  return showDialog<(int, double)>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Form(
        key: key,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (subtitle != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(subtitle)),
            TextFormField(
              controller: qty,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Quantity',
                helperText: maxQuantity == null ? null : 'Up to $maxQuantity available',
              ),
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                if (n == null || n < 1) return 'Enter 1 or more';
                if (maxQuantity != null && n > maxQuantity) return 'Only $maxQuantity available';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Unit price', prefixText: '$currencyCode '),
              validator: (v) {
                if ((v ?? '').trim().isEmpty) return null;
                final p = parseMoney(v!);
                return p == null || p < 0 ? 'Enter a valid price' : null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!key.currentState!.validate()) return;
            Navigator.pop(ctx, (int.parse(qty.text.trim()), parseMoney(price.text) ?? 0.0));
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Bottom sheet: find a product, see which stores hold it, pick the store and quantity.
class _SourcePicker extends StatefulWidget {
  final List<OrderLine> existing;
  final String? initialQuery;
  const _SourcePicker({required this.existing, this.initialQuery});

  @override
  State<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends State<_SourcePicker> {
  late final Future<(List<Product>, List<Store>, List<Company>)> _data = () async {
    final results = await Future.wait([
      Db.watchProducts().first,
      Db.watchStores().first,
      Db.watchCompanies().first,
    ]);
    return (results[0] as List<Product>, results[1] as List<Store>, results[2] as List<Company>);
  }();
  late String _q = widget.initialQuery?.trim().toLowerCase() ?? '';
  late final _search = TextEditingController(text: widget.initialQuery ?? '');
  String? _storeFilter;
  String? _groupKey;
  bool _autoOpened = false;

  static String _key(Product p) => p.sku.trim().isNotEmpty ? 'sku:${p.sku.trim().toLowerCase()}' : 'name:${p.name.trim().toLowerCase()}';

  int _alreadyInOrder(String productId) =>
      widget.existing.where((l) => l.productId == productId).fold<int>(0, (a, l) => a + l.quantity);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _choose(Product p, String storeName) async {
    final available = p.quantity - _alreadyInOrder(p.id);
    final result = await showLineDialog(
      context,
      title: p.name,
      subtitle: 'From $storeName',
      quantity: 1,
      unitPrice: p.prices.wholesale ?? p.prices.retail ?? 0,
      maxQuantity: available,
    );
    if (result == null || !mounted) return;
    Navigator.pop(
      context,
      OrderLine(
        productId: p.id,
        productName: p.name,
        sku: p.sku,
        storeId: p.storeId,
        storeName: storeName,
        companyId: p.companyId,
        quantity: result.$1,
        unitPrice: result.$2,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: FutureBuilder<(List<Product>, List<Store>, List<Company>)>(
          future: _data,
          builder: (context, snap) {
            if (snap.hasError) return ErrorState(snap.error!);
            if (!snap.hasData) return const Loading();
            final (products, stores, companies) = snap.data!;
            final storeById = {for (final s in stores) s.id: s};
            final companyName = {for (final c in companies) c.id: c.name};
            String storeLabel(String id) {
              final s = storeById[id];
              if (s == null) return 'Unknown store';
              final c = companyName[s.companyId];
              return c == null ? s.name : '${s.name} ($c)';
            }

            // Group the same product across stores (by SKU, or by name if no SKU).
            final groups = <String, List<Product>>{};
            for (final p in products) {
              if (_storeFilter != null && p.storeId != _storeFilter) continue;
              if (_q.isNotEmpty && !p.name.toLowerCase().contains(_q) && !p.sku.toLowerCase().contains(_q)) continue;
              groups.putIfAbsent(_key(p), () => []).add(p);
            }

            // A scanned barcode that matches exactly one product opens it straight away.
            if (!_autoOpened && widget.initialQuery != null && groups.length == 1) {
              _autoOpened = true;
              _groupKey = groups.keys.first;
            }

            final selected = _groupKey == null ? null : groups[_groupKey];
            if (selected != null) {
              final first = selected.first;
              return ListView(
                children: [
                  ListTile(
                    leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _groupKey = null)),
                    title: Text(first.name, style: Theme.of(context).textTheme.titleMedium),
                    subtitle: Text(first.sku.isEmpty ? 'Choose the store to take it from' : 'SKU ${first.sku} · choose the store'),
                  ),
                  const Divider(height: 1),
                  for (final p in selected)
                    Builder(builder: (context) {
                      final inOrder = _alreadyInOrder(p.id);
                      final available = p.quantity - inOrder;
                      return ListTile(
                        leading: const Icon(Icons.storefront_outlined),
                        title: Text(storeLabel(p.storeId)),
                        subtitle: Text(
                          '${p.quantity} in stock'
                          '${inOrder > 0 ? ' · $inOrder already in this order' : ''}'
                          '${p.prices.wholesale != null ? ' · Wholesale ${money(p.prices.wholesale!)}' : ''}',
                        ),
                        enabled: available > 0,
                        trailing: available > 0
                            ? const Icon(Icons.chevron_right)
                            : Text('None left', style: TextStyle(color: scheme.error)),
                        onTap: available > 0 ? () => _choose(p, storeById[p.storeId]?.name ?? '') : null,
                      );
                    }),
                ],
              );
            }

            final keys = groups.keys.toList()
              ..sort((a, b) => groups[a]!.first.name.toLowerCase().compareTo(groups[b]!.first.name.toLowerCase()));
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _search,
                    autofocus: widget.initialQuery == null,
                    decoration: const InputDecoration(hintText: 'Search product name or SKU', prefixIcon: Icon(Icons.search)),
                    onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: DropdownButtonFormField<String?>(
                    value: _storeFilter,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Only from store', isDense: true),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('All stores')),
                      for (final s in stores) DropdownMenuItem<String?>(value: s.id, child: Text(storeLabel(s.id))),
                    ],
                    onChanged: (v) => setState(() => _storeFilter = v),
                  ),
                ),
                Expanded(
                  child: keys.isEmpty
                      ? EmptyState(
                          icon: Icons.search_off,
                          title: 'No products found',
                          hint: widget.initialQuery != null ? 'Barcode ${widget.initialQuery} is not in any store.' : null,
                        )
                      : ListView.builder(
                          itemCount: keys.length,
                          itemBuilder: (_, i) {
                            final g = groups[keys[i]]!;
                            final total = g.fold<int>(0, (a, p) => a + p.quantity);
                            return ListTile(
                              title: Text(g.first.name),
                              subtitle: Text(
                                '${g.first.sku.isNotEmpty ? 'SKU ${g.first.sku} · ' : ''}'
                                'In ${g.length} store${g.length == 1 ? '' : 's'} · $total in stock',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => setState(() => _groupKey = keys[i]),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Shows an invoice (PDF, or a photo converted to PDF) with share / print buttons.
class InvoiceViewerScreen extends StatelessWidget {
  final String title;
  final String fileName;
  final Future<Uint8List> Function() load;

  const InvoiceViewerScreen({super.key, required this.title, required this.fileName, required this.load});

  Future<Uint8List> _asPdf() async {
    final bytes = await load();
    if (fileName.toLowerCase().endsWith('.pdf')) return bytes;
    final doc = pw.Document();
    final image = pw.MemoryImage(bytes);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
    ));
    return doc.save();
  }

  @override
  Widget build(BuildContext context) {
    final pdfName = fileName.toLowerCase().endsWith('.pdf') ? fileName : '$fileName.pdf';
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: PdfPreview(
        build: (_) => _asPdf(),
        pdfFileName: pdfName,
        canChangeOrientation: false,
        canChangePageFormat: false,
        canDebug: false,
      ),
    );
  }
}
