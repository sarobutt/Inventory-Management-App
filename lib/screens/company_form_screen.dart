import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';

/// Create a company (company == null) or edit an existing one.
class CompanyFormScreen extends StatefulWidget {
  final Company? company;
  const CompanyFormScreen({super.key, this.company});

  @override
  State<CompanyFormScreen> createState() => _CompanyFormScreenState();
}

class _CompanyFormScreenState extends State<CompanyFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.company?.name ?? '');
  late final _description = TextEditingController(text: widget.company?.description ?? '');
  bool _saving = false;

  bool get _isEdit => widget.company != null;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final name = _name.text.trim();
      final description = _description.text.trim();
      if (_isEdit) {
        await Db.updateCompany(widget.company!.id, name: name, description: description);
      } else {
        await Db.createCompany(name: name, description: description);
      }
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, _isEdit ? 'Company updated' : 'Company added');
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
      appBar: AppBar(title: Text(_isEdit ? 'Edit company' : 'New company')),
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
              decoration: const InputDecoration(labelText: 'Company name *', hintText: 'e.g. Acme Ltd'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Company name is required' : null,
            ),
            const SizedBox(height: 8),
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
                  : Text(_isEdit ? 'Save changes' : 'Add company'),
            ),
          ],
        ),
      ),
    );
  }
}
