import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data.dart';
import '../widgets.dart';

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

  bool get _isEdit => widget.product != null;

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
              decoration: const InputDecoration(labelText: 'SKU / code', hintText: 'Optional'),
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
