import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';

/// Create a store for [companyId] (store == null) or edit an existing one.
class StoreFormScreen extends StatefulWidget {
  final String companyId;
  final Store? store;
  const StoreFormScreen({super.key, required this.companyId, this.store});

  @override
  State<StoreFormScreen> createState() => _StoreFormScreenState();
}

class _StoreFormScreenState extends State<StoreFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.store?.name ?? '');
  late final _address = TextEditingController(text: widget.store?.address ?? '');
  bool _saving = false;

  bool get _isEdit => widget.store != null;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final name = _name.text.trim();
      final address = _address.text.trim();
      if (_isEdit) {
        await Db.updateStore(widget.store!.id, name: name, address: address);
      } else {
        await Db.createStore(widget.companyId, name: name, address: address);
      }
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, _isEdit ? 'Store updated' : 'Store added');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit store' : 'New store')),
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
              decoration: const InputDecoration(labelText: 'Store name *', hintText: 'e.g. Hull City Centre'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Store name is required' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _address,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Address', hintText: 'Optional', alignLabelWithHint: true),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _saving
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_isEdit ? 'Save changes' : 'Add store'),
            ),
          ],
        ),
      ),
    );
  }
}
