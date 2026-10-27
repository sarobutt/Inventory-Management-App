import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';

/// Create a product for [companyId] (product == null) or edit/delete an existing one.
class ProductFormScreen extends StatefulWidget {
  final String companyId;
  final Product? product;
  const ProductFormScreen({super.key, required this.companyId, this.product});

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.product?.name ?? '');
  late final _price = TextEditingController(
    text: widget.product?.price == null ? '' : widget.product!.price!.toStringAsFixed(2),
  );
  late final _description = TextEditingController(text: widget.product?.description ?? '');
  bool _saving = false;

  bool get _isEdit => widget.product != null;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _description.dispose();
    super.dispose();
  }

  double? _parsePrice(String text) {
    final t = text.trim().replaceAll(',', '.').replaceAll('£', '');
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final name = _name.text.trim();
      final price = _parsePrice(_price.text);
      final description = _description.text.trim();
      if (_isEdit) {
        await Db.updateProduct(widget.product!.id, name: name, price: price, description: description);
      } else {
        await Db.createProduct(widget.companyId, name: name, price: price, description: description);
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
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Price (£)', hintText: 'Optional', prefixText: '£ '),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                final p = _parsePrice(v);
                if (p == null || p < 0) return 'Enter a valid price, e.g. 9.99';
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _description,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Description', hintText: 'Optional', alignLabelWithHint: true),
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
