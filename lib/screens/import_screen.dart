import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data.dart';
import '../importer.dart';
import '../widgets.dart';

/// Import products into one store from an Excel (.xlsx) or CSV file.
class ImportScreen extends StatefulWidget {
  final String companyId;
  final String storeId;
  final String storeName;

  const ImportScreen({super.key, required this.companyId, required this.storeId, required this.storeName});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  String? _fileName;
  List<ImportRow>? _rows;
  List<Product> _products = const [];
  ImportPlan? _plan;
  QuantityMode _mode = QuantityMode.replace;
  bool _loading = false;
  double? _progress; // non-null while importing
  String? _error;

  Future<void> _pickFile() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      final file = result?.files.single;
      if (file == null) {
        setState(() => _loading = false);
        return;
      }
      final bytes = file.bytes;
      if (bytes == null) throw ImportException('Could not read the file. Please try again.');

      final rows = rowsFromGrid(readGrid(bytes, file.name));

      // Load the store's current products so existing ones are updated, not duplicated.
      final products = await Db.watchProducts(storeId: widget.storeId).first;

      setState(() {
        _fileName = file.name;
        _rows = rows;
        _products = products;
        _loading = false;
        _replan();
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e is ImportException ? e.message : 'Could not read the file: $e';
        _rows = null;
        _plan = null;
      });
    }
  }

  void _replan() {
    final rows = _rows;
    if (rows == null) return;
    _plan = buildPlan(
      rows: rows,
      companyId: widget.companyId,
      storeId: widget.storeId,
      storeProducts: _products,
      mode: _mode,
    );
  }

  Future<void> _import() async {
    final plan = _plan;
    if (plan == null || !plan.hasWork) return;
    setState(() => _progress = 0);
    try {
      await runImport(plan, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      final summary = [
        if (plan.newProducts > 0) '${plan.newProducts} added',
        if (plan.updatedProducts > 0) '${plan.updatedProducts} updated',
      ].join(', ');
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text('Import complete: $summary')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _progress = null);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final importing = _progress != null;

    return PopScope(
      canPop: !importing,
      child: Scaffold(
        appBar: AppBar(title: Text('Import into ${widget.storeName}')),
        bottomNavigationBar: plan == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: importing
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LinearProgressIndicator(value: _progress),
                            const SizedBox(height: 8),
                            Text('Importing… ${((_progress ?? 0) * 100).round()}%'),
                          ],
                        )
                      : FilledButton.icon(
                          onPressed: plan.hasWork ? _import : null,
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                          icon: const Icon(Icons.cloud_upload_outlined),
                          label: Text(plan.hasWork
                              ? 'Import ${plan.newProducts + plan.updatedProducts} product(s)'
                              : 'Nothing to import'),
                        ),
                ),
              ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (plan == null) _instructions(context),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _loading || importing ? null : _pickFile,
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.upload_file),
              label: Text(_fileName == null ? 'Choose Excel or CSV file' : 'Choose a different file'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ],
            if (plan != null) ..._preview(context, plan, importing),
          ],
        ),
      ),
    );
  }

  Widget _instructions(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    const columns = [
      ('Product', 'Required'),
      ('SKU', 'Optional, used to match existing products'),
      ('Price', 'Optional, e.g. 4.99'),
      ('Quantity', 'Optional, stock count'),
      ('Description', 'Optional'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your file’s first row should contain these headings:',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            for (final c in columns)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 120, child: Text(c.$1, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Expanded(child: Text(c.$2, style: TextStyle(color: muted))),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Text(
              'Products are added to ${widget.storeName}. Products already in this store are matched by SKU '
              '(or by name) and updated instead of duplicated. You’ll see a preview before anything is saved.',
              style: TextStyle(color: muted),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _preview(BuildContext context, ImportPlan plan, bool importing) {
    final scheme = Theme.of(context).colorScheme;
    return [
      const SizedBox(height: 16),
      Text(_fileName ?? '', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip(context, '${plan.newProducts} new products', Icons.add_circle_outline),
          _chip(context, '${plan.updatedProducts} updates', Icons.sync),
          if (plan.errors > 0) _chip(context, '${plan.errors} rows skipped', Icons.error_outline, error: true),
        ],
      ),
      const SizedBox(height: 16),
      Text('Quantity in the file should…', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      SegmentedButton<QuantityMode>(
        segments: const [
          ButtonSegment(value: QuantityMode.replace, label: Text('Replace stock'), icon: Icon(Icons.fact_check_outlined)),
          ButtonSegment(value: QuantityMode.add, label: Text('Add to stock'), icon: Icon(Icons.add)),
        ],
        selected: {_mode},
        onSelectionChanged: importing
            ? null
            : (s) => setState(() {
                  _mode = s.first;
                  _replan();
                }),
      ),
      const SizedBox(height: 4),
      Text(
        _mode == QuantityMode.replace
            ? 'Use after a stock take: the file’s quantity becomes the new count.'
            : 'Use for a delivery: the file’s quantity is added to the current count.',
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      ),
      const SectionTitle('Preview'),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStatePropertyAll(scheme.primaryContainer),
          columnSpacing: 18,
          columns: const [
            DataColumn(label: Text('Row'), numeric: true),
            DataColumn(label: Text('Status')),
            DataColumn(label: Text('Product')),
            DataColumn(label: Text('SKU')),
            DataColumn(label: Text('Price'), numeric: true),
            DataColumn(label: Text('Qty'), numeric: true),
          ],
          rows: [
            for (final r in plan.results.take(300))
              DataRow(
                color: r.status == RowStatus.error ? WidgetStatePropertyAll(scheme.errorContainer) : null,
                cells: [
                  DataCell(Text('${r.row.line}')),
                  DataCell(Text(
                    r.status == RowStatus.error
                        ? r.note
                        : r.status == RowStatus.update
                            ? 'Update · ${r.note}'
                            : r.note,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: r.status == RowStatus.error
                          ? scheme.onErrorContainer
                          : r.status == RowStatus.update
                              ? scheme.tertiary
                              : scheme.primary,
                    ),
                  )),
                  DataCell(Text(r.row.product)),
                  DataCell(Text(r.row.sku)),
                  DataCell(Text(formatPrice(r.row.price))),
                  DataCell(Text(r.row.quantity == null ? '' : count(r.row.quantity!))),
                ],
              ),
          ],
        ),
      ),
      if (plan.results.length > 300)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Showing the first 300 of ${plan.results.length} rows. All rows will be imported.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      const SizedBox(height: 24),
    ];
  }

  Widget _chip(BuildContext context, String text, IconData icon, {bool error = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icon, size: 18, color: error ? scheme.error : scheme.primary),
      label: Text(text),
      backgroundColor: error ? scheme.errorContainer : null,
    );
  }
}
