import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:xml/xml.dart';

import 'audit.dart';
import 'data.dart';
import 'widgets.dart';

// =====================================================================
//  Import products into ONE store from Excel (.xlsx) or CSV.
//
//  Expected columns (header row, any order, case-insensitive):
//    Product | SKU | Cost Price | Wholesale Price | Retail Price | Quantity | Reorder Level | Description
//  Only "Product" is required. Companies and stores are never created here.
// =====================================================================

class ImportException implements Exception {
  final String message;
  ImportException(this.message);
  @override
  String toString() => message;
}

/// One data row from the file, after reading the columns.
class ImportRow {
  final int line; // row number in the spreadsheet (1-based, incl. header)
  final String product;
  final String sku;
  final Prices prices;
  final int? quantity;
  final int? reorderLevel;
  final String description;
  final String? error;

  const ImportRow({
    required this.line,
    required this.product,
    required this.sku,
    required this.prices,
    required this.quantity,
    this.reorderLevel,
    required this.description,
    this.error,
  });
}

// ---------------------------------------------------------------------
//  Reading files
// ---------------------------------------------------------------------

/// Reads an .xlsx or .csv file into a grid of strings (first sheet only for Excel).
List<List<String>> readGrid(Uint8List bytes, String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.csv') || lower.endsWith('.txt')) return _readCsv(bytes);
  if (lower.endsWith('.xlsx')) return _readXlsx(bytes);
  if (lower.endsWith('.xls')) {
    throw ImportException('Old .xls files are not supported. In Excel use File → Save As → Excel Workbook (.xlsx).');
  }
  throw ImportException('Please choose an Excel (.xlsx) or CSV (.csv) file.');
}

List<List<String>> _readCsv(Uint8List bytes) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1); // Excel's UTF-8 BOM

  // Excel in some regions saves CSV with semicolons.
  final firstLine = text.split('\n').first;
  final sep = ';'.allMatches(firstLine).length > ','.allMatches(firstLine).length ? ';' : ',';

  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == sep) {
      row.add(field.toString());
      field.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

String _zipText(Archive zip, String path) {
  final f = zip.findFile(path);
  if (f == null) return '';
  return utf8.decode(f.content as List<int>, allowMalformed: true);
}

/// Path of the first worksheet, read from the workbook (falls back to sheet1.xml).
String _firstSheetPath(Archive zip) {
  try {
    final workbook = XmlDocument.parse(_zipText(zip, 'xl/workbook.xml'));
    final sheet = workbook.findAllElements('sheet').first;
    final relId = sheet.attributes
        .firstWhere((a) => a.name.local == 'id' && (a.name.prefix ?? '').isNotEmpty)
        .value;
    final rels = XmlDocument.parse(_zipText(zip, 'xl/_rels/workbook.xml.rels'));
    final rel = rels.findAllElements('Relationship').firstWhere((r) => r.getAttribute('Id') == relId);
    var target = rel.getAttribute('Target') ?? 'worksheets/sheet1.xml';
    if (target.startsWith('/')) return target.substring(1);
    return 'xl/$target';
  } catch (_) {
    return 'xl/worksheets/sheet1.xml';
  }
}

int _columnIndex(String cellRef) {
  var col = 0;
  for (final code in cellRef.codeUnits) {
    if (code >= 65 && code <= 90) {
      col = col * 26 + (code - 64);
    } else if (code >= 97 && code <= 122) {
      col = col * 26 + (code - 96);
    } else {
      break;
    }
  }
  return col - 1;
}

String _allText(XmlElement e) => e.findAllElements('t').map((t) => t.innerText).join();

List<List<String>> _readXlsx(Uint8List bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw ImportException('This file could not be opened as an Excel (.xlsx) workbook.');
  }

  final shared = <String>[];
  final sharedXml = _zipText(zip, 'xl/sharedStrings.xml');
  if (sharedXml.isNotEmpty) {
    for (final si in XmlDocument.parse(sharedXml).findAllElements('si')) {
      shared.add(_allText(si));
    }
  }

  final sheetXml = _zipText(zip, _firstSheetPath(zip));
  if (sheetXml.isEmpty) throw ImportException('The workbook has no worksheet.');

  final rows = <List<String>>[];
  for (final r in XmlDocument.parse(sheetXml).findAllElements('row')) {
    final cells = <int, String>{};
    var nextCol = 0;
    for (final c in r.findElements('c')) {
      final ref = c.getAttribute('r');
      final col = ref == null ? nextCol : _columnIndex(ref);
      nextCol = col + 1;
      final type = c.getAttribute('t');
      final v = c.getElement('v')?.innerText ?? '';
      String value;
      switch (type) {
        case 's':
          final i = int.tryParse(v);
          value = (i != null && i >= 0 && i < shared.length) ? shared[i] : '';
          break;
        case 'inlineStr':
          final isEl = c.getElement('is');
          value = isEl == null ? '' : _allText(isEl);
          break;
        case 'b':
          value = v == '1' ? 'TRUE' : 'FALSE';
          break;
        default:
          value = v; // numbers and formula results
      }
      cells[col] = value;
    }
    if (cells.isEmpty) {
      rows.add(const <String>[]);
      continue;
    }
    final maxCol = cells.keys.reduce((a, b) => a > b ? a : b);
    rows.add([for (var i = 0; i <= maxCol; i++) cells[i] ?? '']);
  }
  return rows;
}

// ---------------------------------------------------------------------
//  Turning the grid into rows
// ---------------------------------------------------------------------

enum _Col { product, sku, cost, wholesale, retail, quantity, reorder, description }

const Map<_Col, List<String>> _aliases = {
  _Col.product: ['product', 'productname', 'name', 'item', 'itemname'],
  _Col.sku: ['sku', 'code', 'productcode', 'itemcode', 'barcode', 'ref', 'reference'],
  _Col.retail: ['retailprice', 'retail', 'price', 'rrp', 'sellingprice', 'saleprice'],
  _Col.wholesale: ['wholesaleprice', 'wholesale', 'trade', 'tradeprice'],
  _Col.cost: ['costprice', 'cost', 'unitcost', 'purchaseprice', 'buyprice', 'buyingprice', 'costperunit'],
  _Col.quantity: ['quantity', 'qty', 'stock', 'count', 'units', 'stockcount', 'onhand', 'qtyinstock'],
  _Col.reorder: [
    'reorderlevel', 'reorder', 'reorderat', 'reorderpoint', 'minstock', 'minimumstock', 'minimum', 'min',
    'lowstock', 'lowstocklevel', 'alertat',
  ],
  _Col.description: ['description', 'notes', 'details', 'comment', 'comments'],
};

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

double? parsePrice(String raw) => parseMoney(raw);

int? parseQuantity(String raw) {
  final t = raw.trim().replaceAll(RegExp(r'[\s,]'), '');
  if (t.isEmpty) return null;
  final d = double.tryParse(t);
  return d?.round();
}

/// Finds the header row and converts the rest into [ImportRow]s.
List<ImportRow> rowsFromGrid(List<List<String>> grid) {
  final headerIndex = grid.indexWhere((r) => r.any((c) => c.trim().isNotEmpty));
  if (headerIndex < 0) throw ImportException('The file is empty.');

  final header = grid[headerIndex];
  final colOf = <_Col, int>{};
  for (var i = 0; i < header.length; i++) {
    final h = _norm(header[i]);
    if (h.isEmpty) continue;
    for (final entry in _aliases.entries) {
      if (!colOf.containsKey(entry.key) && entry.value.contains(h)) {
        colOf[entry.key] = i;
        break;
      }
    }
  }
  if (!colOf.containsKey(_Col.product)) {
    throw ImportException(
      'Could not find a "Product" column in the first row.\n'
      'Expected headings: Product, SKU, Cost Price, Wholesale Price, Retail Price, Quantity, Reorder Level, Description.',
    );
  }

  String cell(List<String> r, _Col c) {
    final i = colOf[c];
    if (i == null || i >= r.length) return '';
    return r[i].trim();
  }

  final out = <ImportRow>[];
  for (var i = headerIndex + 1; i < grid.length; i++) {
    final r = grid[i];
    if (r.every((c) => c.trim().isEmpty)) continue;

    final qtyText = cell(r, _Col.quantity);
    final qty = parseQuantity(qtyText);
    final reorderText = cell(r, _Col.reorder);
    final reorder = parseQuantity(reorderText);
    final product = cell(r, _Col.product);

    // Three prices; remember the first one that can't be read.
    String? priceError;
    double? readPrice(_Col c, String label) {
      final text = cell(r, c);
      if (text.isEmpty) return null;
      final v = parsePrice(text);
      if (v == null || v < 0) priceError ??= 'Invalid $label price "$text"';
      return v;
    }

    final prices = Prices(
      retail: readPrice(_Col.retail, 'retail'),
      wholesale: readPrice(_Col.wholesale, 'wholesale'),
      cost: readPrice(_Col.cost, 'cost'),
    );

    String? error;
    if (product.isEmpty) {
      error = 'Product name is empty';
    } else if (product.length > 200) {
      error = 'Product name is too long';
    } else if (priceError != null) {
      error = priceError;
    } else if (reorderText.isNotEmpty && (reorder == null || reorder < 0)) {
      error = 'Invalid reorder level "$reorderText"';
    } else if (qtyText.isNotEmpty && (qty == null || qty < 0)) {
      error = 'Invalid quantity "$qtyText"';
    }

    out.add(ImportRow(
      line: i + 1,
      product: product,
      sku: cell(r, _Col.sku),
      prices: prices,
      quantity: qty,
      reorderLevel: reorder,
      description: cell(r, _Col.description),
      error: error,
    ));
  }
  if (out.isEmpty) throw ImportException('No product rows found under the header row.');
  return out;
}

// ---------------------------------------------------------------------
//  Planning: match rows to the store's existing products
// ---------------------------------------------------------------------

enum QuantityMode {
  /// The file's quantity becomes the stock count (e.g. after a stock take).
  replace,

  /// The file's quantity is added to the current stock (e.g. a delivery).
  add,
}

enum RowStatus { newProduct, update, error }

class RowResult {
  final ImportRow row;
  final RowStatus status;
  final String note;
  const RowResult(this.row, this.status, this.note);
}

class _ProductWrite {
  final String? existingId; // null = new product
  String name;
  String sku;
  Prices prices;
  int quantity;
  final int previousQuantity; // 0 for new products
  int? reorderLevel;
  String description;

  _ProductWrite({
    required this.existingId,
    this.previousQuantity = 0,
    required this.name,
    required this.sku,
    required this.prices,
    required this.quantity,
    required this.reorderLevel,
    required this.description,
  });
}

class ImportPlan {
  final String companyId;
  final String storeId;
  final List<RowResult> results;
  final Map<String, _ProductWrite> _writes;

  ImportPlan._(this.companyId, this.storeId, this.results, this._writes);

  int get newProducts => _writes.values.where((p) => p.existingId == null).length;
  int get updatedProducts => _writes.values.where((p) => p.existingId != null).length;
  int get errors => results.where((r) => r.status == RowStatus.error).length;
  bool get hasWork => _writes.isNotEmpty;
}

String _key(String s) => s.trim().toLowerCase();

/// Works out what the import will do in [storeId] without writing anything.
/// [storeProducts] are the products currently in that store.
ImportPlan buildPlan({
  required List<ImportRow> rows,
  required String companyId,
  required String storeId,
  required List<Product> storeProducts,
  required QuantityMode mode,
}) {
  final bySku = <String, Product>{};
  final byName = <String, Product>{};
  for (final p in storeProducts) {
    if (p.sku.isNotEmpty) bySku.putIfAbsent(_key(p.sku), () => p);
    byName.putIfAbsent(_key(p.name), () => p);
  }

  final writes = <String, _ProductWrite>{};
  final results = <RowResult>[];

  for (final row in rows) {
    if (row.error != null) {
      results.add(RowResult(row, RowStatus.error, row.error!));
      continue;
    }

    // Match by SKU first, then by name.
    final writeKey = row.sku.isNotEmpty ? 'sku:${_key(row.sku)}' : 'name:${_key(row.product)}';
    final pending = writes[writeKey];
    final existing =
        pending == null ? (row.sku.isNotEmpty ? bySku[_key(row.sku)] : null) ?? byName[_key(row.product)] : null;

    if (pending != null) {
      // Same product appears again in the file.
      final qty = row.quantity ?? 0;
      pending.quantity = mode == QuantityMode.add ? pending.quantity + qty : (row.quantity ?? pending.quantity);
      pending.prices = pending.prices.mergedWith(row.prices);
      if (row.reorderLevel != null) pending.reorderLevel = row.reorderLevel;
      if (row.description.isNotEmpty) pending.description = row.description;
      pending.name = row.product;
      results.add(RowResult(
        row,
        pending.existingId == null ? RowStatus.newProduct : RowStatus.update,
        'Merged with an earlier row',
      ));
    } else if (existing != null) {
      final qty =
          mode == QuantityMode.add ? existing.quantity + (row.quantity ?? 0) : (row.quantity ?? existing.quantity);
      writes[writeKey] = _ProductWrite(
        existingId: existing.id,
        previousQuantity: existing.quantity,
        name: row.product,
        sku: row.sku.isNotEmpty ? row.sku : existing.sku,
        prices: existing.prices.mergedWith(row.prices), // empty cells keep the current price
        quantity: qty,
        reorderLevel: row.reorderLevel ?? existing.reorderLevel,
        description: row.description.isNotEmpty ? row.description : existing.description,
      );
      results.add(RowResult(row, RowStatus.update, 'Qty ${existing.quantity} → $qty'));
    } else {
      writes[writeKey] = _ProductWrite(
        existingId: null,
        name: row.product,
        sku: row.sku,
        prices: row.prices,
        quantity: row.quantity ?? 0,
        reorderLevel: row.reorderLevel,
        description: row.description,
      );
      results.add(RowResult(row, RowStatus.newProduct, 'New'));
    }
  }

  return ImportPlan._(companyId, storeId, results, writes);
}

// ---------------------------------------------------------------------
//  Writing to Firestore
// ---------------------------------------------------------------------

/// Saves the planned products. Each product is up to three writes (the product with its
/// retail price, the admin-only cost/wholesale prices, and an audit entry), so 150 per batch.
Future<void> runImport(ImportPlan plan, {void Function(double progress)? onProgress, String fileName = ''}) async {
  final fs = FirebaseFirestore.instance;
  final writes = plan._writes.values.toList();
  final place = await Audit.names(plan.storeId, plan.companyId);

  for (var i = 0; i < writes.length; i += 150) {
    final batch = fs.batch();
    final chunk = writes.skip(i).take(150);
    for (final p in chunk) {
      final data = <String, dynamic>{
        'companyId': plan.companyId,
        'storeId': plan.storeId,
        'name': p.name,
        'sku': p.sku,
        'retailPrice': p.prices.retail,
        'quantity': p.quantity,
        'reorderLevel': p.reorderLevel,
        'description': p.description,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      final DocumentReference<Map<String, dynamic>> ref;
      if (p.existingId != null) {
        ref = fs.collection('products').doc(p.existingId);
        data['price'] = FieldValue.delete(); // old single-price field
        batch.update(ref, data);
      } else {
        ref = fs.collection('products').doc();
        data['createdAt'] = FieldValue.serverTimestamp();
        batch.set(ref, data);
      }
      if (p.quantity != p.previousQuantity) {
        batch.set(
          Audit.col.doc(),
          Audit.entry(
            type: AuditType.import,
            productId: ref.id,
            productName: p.name,
            sku: p.sku,
            storeId: plan.storeId,
            companyId: plan.companyId,
            place: place,
            before: p.previousQuantity,
            after: p.quantity,
            note: fileName.isEmpty ? 'Excel import' : 'Imported from $fileName',
          ),
        );
      }
      batch.set(fs.collection('productPrices').doc(ref.id), {
        'wholesale': p.prices.wholesale,
        'cost': p.prices.cost,
        'companyId': plan.companyId,
        'storeId': plan.storeId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    if (onProgress != null) onProgress((i + 150).clamp(0, writes.length) / writes.length);
  }
}
