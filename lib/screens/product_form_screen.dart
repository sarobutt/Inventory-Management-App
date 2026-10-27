import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../barcode.dart';
import '../data.dart';
import '../widgets.dart';
import 'scanner_screen.dart';

/// Create a product in a store (product == null) or edit/delete an existing one.
class ProductFormScreen extends StatefulWidget {
  final String companyId;
  final String storeId;
  final Product? product;
  const ProductFormScreen({super.key, required this.companyId, required this.storeId, this.product});

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.product?.name ?? '');
  late final _sku = TextEditingController(text: widget.product?.sku ?? '');
  late final _price = TextEditingController(
    text: widget.product?.price == null ? '' : widget.product!.price!.toStringAsFixed(2),
  );
  late final _quantity = TextEditingController(text: '${widget.product?.quantity ?? 0}');
  late final _description = TextEditingController(text: widget.product?.description ?? '');
  bool _saving = false;

  // Barcode lookup state
  bool _lookingUp = false;
  String? _lookupNote;
  bool _lookupFound = false;
  String? _suggestedName; // found name when the name field was already filled

  bool get _isEdit => widget.product != null;

  /// Opens the camera, puts the barcode into SKU and fills in the product details.
  Future<void> _scan() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (code == null || !mounted) return;

    setState(() {
      _sku.text = code;
      _lookingUp = true;
      _lookupNote = null;
      _suggestedName = null;
    });

    final info = await lookupBarcode(code, preferStoreId: widget.storeId);
    if (!mounted) return;
    setState(() => _lookingUp = false);

    // Already in this store? Offer to open it instead of creating a duplicate.
    final existing = info.existing;
    if (existing != null && existing.storeId == widget.storeId && existing.id != widget.product?.id) {
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Already in this store'),
          content: Text('“${existing.name}” (quantity ${existing.quantity}) already uses this barcode in this store. '
              'Open it instead?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay here')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open product')),
          ],
        ),
      );
      if (open == true && mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ProductFormScreen(companyId: widget.companyId, storeId: widget.storeId, product: existing),
            fullscreenDialog: true,
          ),
        );
        return;
      }
      if (!mounted) return;
    }

    setState(() {
      _lookupFound = info.found;
      if (!info.found) {
        _lookupNote = 'Barcode $code not found in any database. Please type the product name.';
        return;
      }
      if (_name.text.trim().isEmpty) {
        _name.text = info.name!;
      } else if (_name.text.trim() != info.name) {
        _suggestedName = info.name;
      }
      if (_price.text.trim().isEmpty && info.price != null) _price.text = info.price!.toStringAsFixed(2);
      if (_description.text.trim().isEmpty && info.description != null) _description.text = info.description!;
      _lookupNote = 'Found in ${info.source}: ${info.name}';
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _sku.dispose();
    _price.dispose();
    _quantity.dispose();
    _description.dispose();
    super.dispose();
  }

  double? _parsePrice(String text) {
    final t = text.trim().replaceAll(',', '.').replaceAll('£', '');
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  void _step(int delta) {
    final current = int.tryParse(_quantity.text.trim()) ?? 0;
    final next = current + delta < 0 ? 0 : current + delta;
    setState(() => _quantity.text = '$next');
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final name = _name.text.trim();
      final sku = _sku.text.trim();
      final price = _parsePrice(_price.text);
      final quantity = int.tryParse(_quantity.text.trim()) ?? 0;
      final description = _description.text.trim();
      if (_isEdit) {
        await Db.updateProduct(
          widget.product!.id,
          name: name,
          sku: sku,
          price: price,
          quantity: quantity,
          description: description,
        );
      } else {
        await Db.createProduct(
          companyId: widget.companyId,
          storeId: widget.storeId,
          name: name,
          sku: sku,
          price: price,
          quantity: quantity,
          description: description,
        );
      }
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, _isEdit ? 'Product updated' : 'Product added');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDelete(
      context,
      title: 'Delete product?',
      message: '“${widget.product!.name}” will be permanently deleted.',
    );
    if (!ok) return;
    try {
      await Db.deleteProduct(widget.product!.id);
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, 'Product deleted');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit product' : 'New product'),
        actions: [
          if (_isEdit)
            IconButton(tooltip: 'Delete product', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton.tonalIcon(
              onPressed: _lookingUp || _saving ? null : _scan,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan barcode'),
            ),
            if (_lookingUp)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('Looking up product…'),
                  ],
                ),
              )
            else if (_lookupNote != null)
              _LookupNote(
                text: _lookupNote!,
                found: _lookupFound,
                suggestedName: _suggestedName,
                onUseName: () => setState(() {
                  _name.text = _suggestedName!;
                  _suggestedName = null;
                }),
              ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              autofocus: !_isEdit,
              maxLength: 200,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Product name *', hintText: 'e.g. Widget Pro'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Product name is required' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _sku,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'SKU / barcode',
                hintText: 'Optional',
                suffixIcon: IconButton(
                  tooltip: 'Scan barcode',
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: _lookingUp || _saving ? null : _scan,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Price', hintText: 'Optional', prefixText: '£ '),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return null;
                      final p = _parsePrice(v);
                      if (p == null || p < 0) return 'Invalid price';
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _quantity,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      labelText: 'Quantity',
                      prefixIcon: IconButton(icon: const Icon(Icons.remove), onPressed: () => _step(-1)),
                      suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: () => _step(1)),
                    ),
                    validator: (v) => int.tryParse((v ?? '').trim()) == null ? 'Enter a number' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _description,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration:
                  const InputDecoration(labelText: 'Description', hintText: 'Optional', alignLabelWithHint: true),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _saving
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_isEdit ? 'Save changes' : 'Add product'),
            ),
            if (_isEdit) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _delete,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete product'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LookupNote extends StatelessWidget {
  final String text;
  final bool found;
  final String? suggestedName;
  final VoidCallback onUseName;

  const _LookupNote({required this.text, required this.found, required this.suggestedName, required this.onUseName});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: found ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(found ? Icons.check_circle_outline : Icons.info_outline, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(text)),
            ],
          ),
          if (suggestedName != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onUseName, child: const Text('Use this name')),
            ),
        ],
      ),
    );
  }
}
