import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:xml/xml.dart';

import 'data.dart';

// =====================================================================
//  Bulk import from Excel (.xlsx) or CSV.
//
//  Expected columns (header row, any order, case-insensitive):
//    Company | Store | Store Address | Product | SKU | Price | Quantity | Description
//  Only "Product" is always required. Company and Store are required
//  unless you import from inside a store (then that store is used).
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
  final String company;
  final String store;
  final String address;
  final String product;
  final String sku;
  final double? price;
  final int? quantity;
  final String description;
  final String? error;

  const ImportRow({
    required this.line,
    required this.company,
    required this.store,
    required this.address,
    required this.product,
    required this.sku,
    required this.price,
    required this.quantity,
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

enum _Col { company, store, address, product, sku, price, quantity, description }

const Map<_Col, List<String>> _aliases = {
  _Col.company: ['company', 'companyname', 'business'],
  _Col.store: ['store', 'storename', 'shop', 'branch', 'location'],
  _Col.address: ['storeaddress', 'address', 'shopaddress', 'branchaddress'],
  _Col.product: ['product', 'productname', 'name', 'item', 'itemname', 'productdescription'],
  _Col.sku: ['sku', 'code', 'productcode', 'itemcode', 'barcode', 'ref', 'reference'],
  _Col.price: ['price', 'unitprice', 'cost', 'rrp', 'priceeach', 'sellingprice'],
  _Col.quantity: ['quantity', 'qty', 'stock', 'count', 'units', 'stockcount', 'onhand', 'qtyinstock'],
  _Col.description: ['description', 'notes', 'details', 'comment', 'comments'],
};

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

double? parsePrice(String raw) {
  final t = raw.trim().replaceAll(RegExp(r'[£$€\s,]'), '');
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

int? parseQuantity(String raw) {
  final t = raw.trim().replaceAll(RegExp(r'[\s,]'), '');
  if (t.isEmpty) return null;
  final d = double.tryParse(t);
  return d?.round();
}

/// Finds the header row and converts the rest into [ImportRow]s.
List<ImportRow> rowsFromGrid(List<List<String>> grid) {
  // Header = first row that has at least one non-empty cell.
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
      'Expected headers: Company, Store, Store Address, Product, SKU, Price, Quantity, Description.',
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

    final priceText = cell(r, _Col.price);
    final qtyText = cell(r, _Col.quantity);
    final price = parsePrice(priceText);
    final qty = parseQuantity(qtyText);
    final product = cell(r, _Col.product);

    String? error;
    if (product.isEmpty) {
      error = 'Product name is empty';
    } else if (product.length > 200) {
      error = 'Product name is too long';
    } else if (priceText.isNotEmpty && (price == null || price < 0)) {
      error = 'Invalid price "$priceText"';
    } else if (qtyText.isNotEmpty && (qty == null || qty < 0)) {
      error = 'Invalid quantity "$qtyText"';
    }

    out.add(ImportRow(
      line: i + 1,
      company: cell(r, _Col.company),
      store: cell(r, _Col.store),
      address: cell(r, _Col.address),
      product: product,
      sku: cell(r, _Col.sku),
      price: price,
      quantity: qty,
      description: cell(r, _Col.description),
      error: error,
    ));
  }
  if (out.isEmpty) throw ImportException('No product rows found under the header row.');
  return out;
}

// ---------------------------------------------------------------------
//  Planning: match rows to existing companies / stores / products
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

class _NewCompany {
  final String name;
  _NewCompany(this.name);
}

class _NewStore {
  final String companyKey;
  final String name;
  String address;
  _NewStore(this.companyKey, this.name, this.address);
}

class _ProductWrite {
  final String? existingId; // null = new product
  final String companyKey;
  final String storeKey;
  String name;
  String sku;
  double? price;
  int quantity;
  String description;

  _ProductWrite({
    required this.existingId,
    required this.companyKey,
    required this.storeKey,
    required this.name,
    required this.sku,
    required this.price,
    required this.quantity,
    required this.description,
  });
}

class ImportPlan {
  final List<RowResult> results;
  final Map<String, _NewCompany> _newCompanies;
  final Map<String, _NewStore> _newStores;
  final Map<String, _ProductWrite> _products;

  /// companyKey -> existing company id; storeKey -> existing store id.
  final Map<String, String> _companyIds;
  final Map<String, String> _storeIds;

  ImportPlan._(this.results, this._newCompanies, this._newStores, this._products, this._companyIds, this._storeIds);

  int get newCompanies => _newCompanies.length;
  int get newStores => _newStores.length;
  int get newProducts => _products.values.where((p) => p.existingId == null).length;
  int get updatedProducts => _products.values.where((p) => p.existingId != null).length;
  int get errors => results.where((r) => r.status == RowStatus.error).length;
  bool get hasWork => _products.isNotEmpty;
}

String _key(String s) => s.trim().toLowerCase();

/// Works out what the import will do without writing anything.
/// [contextCompanyId]/[contextStoreId] are used for rows that leave Company/Store blank.
ImportPlan buildPlan({
  required List<ImportRow> rows,
  required List<Company> companies,
  required List<Store> stores,
  required List<Product> products,
  required QuantityMode mode,
  String? contextCompanyId,
  String? contextStoreId,
}) {
  final companyIds = <String, String>{}; // companyKey -> id
  final companyKeyById = <String, String>{};
  for (final c in companies) {
    final k = 'c:${_key(c.name)}';
    companyIds.putIfAbsent(k, () => c.id);
    companyKeyById[c.id] = k;
  }

  final storeIds = <String, String>{}; // storeKey -> id
  final storeKeyById = <String, String>{};
  for (final s in stores) {
    final ck = companyKeyById[s.companyId];
    if (ck == null) continue;
    final k = '$ck|s:${_key(s.name)}';
    storeIds.putIfAbsent(k, () => s.id);
    storeKeyById[s.id] = k;
  }

  final existingBySku = <String, Product>{};
  final existingByName = <String, Product>{};
  for (final p in products) {
    final sk = storeKeyById[p.storeId];
    if (sk == null) continue;
    if (p.sku.isNotEmpty) existingBySku.putIfAbsent('$sk|${_key(p.sku)}', () => p);
    existingByName.putIfAbsent('$sk|${_key(p.name)}', () => p);
  }

  final contextCompanyKey = contextCompanyId == null ? null : companyKeyById[contextCompanyId];
  final contextStoreKey = contextStoreId == null ? null : storeKeyById[contextStoreId];

  final newCompanies = <String, _NewCompany>{};
  final newStores = <String, _NewStore>{};
  final writes = <String, _ProductWrite>{};
  final results = <RowResult>[];

  for (final row in rows) {
    if (row.error != null) {
      results.add(RowResult(row, RowStatus.error, row.error!));
      continue;
    }

    // --- company ---
    String companyKey;
    if (row.company.isNotEmpty) {
      companyKey = 'c:${_key(row.company)}';
      if (!companyIds.containsKey(companyKey)) {
        newCompanies.putIfAbsent(companyKey, () => _NewCompany(row.company));
      }
    } else if (contextCompanyKey != null) {
      companyKey = contextCompanyKey;
    } else {
      results.add(RowResult(row, RowStatus.error, 'Company is empty'));
      continue;
    }

    // --- store ---
    String storeKey;
    if (row.store.isNotEmpty) {
      storeKey = '$companyKey|s:${_key(row.store)}';
      if (!storeIds.containsKey(storeKey)) {
        final ns = newStores.putIfAbsent(storeKey, () => _NewStore(companyKey, row.store, row.address));
        if (ns.address.isEmpty && row.address.isNotEmpty) ns.address = row.address;
      }
    } else if (contextStoreKey != null && companyKey == contextCompanyKey) {
      storeKey = contextStoreKey;
    } else {
      results.add(RowResult(row, RowStatus.error, 'Store is empty'));
      continue;
    }

    // --- product: match by SKU first, then by name, within the store ---
    final skuKey = row.sku.isEmpty ? null : '$storeKey|${_key(row.sku)}';
    final nameKey = '$storeKey|${_key(row.product)}';
    final writeKey = skuKey != null ? 'sku:$skuKey' : 'name:$nameKey';

    final pending = writes[writeKey];
    final existing = pending == null ? (skuKey != null ? existingBySku[skuKey] : null) ?? existingByName[nameKey] : null;

    if (pending != null) {
      // Same product appears again in the file.
      final qty = row.quantity ?? 0;
      pending.quantity = mode == QuantityMode.add ? pending.quantity + qty : (row.quantity ?? pending.quantity);
      if (row.price != null) pending.price = row.price;
      if (row.description.isNotEmpty) pending.description = row.description;
      pending.name = row.product;
      results.add(RowResult(
        row,
        pending.existingId == null ? RowStatus.newProduct : RowStatus.update,
        'Merged with an earlier row',
      ));
    } else if (existing != null) {
      final qty = mode == QuantityMode.add
          ? existing.quantity + (row.quantity ?? 0)
          : (row.quantity ?? existing.quantity);
      writes[writeKey] = _ProductWrite(
        existingId: existing.id,
        companyKey: companyKey,
        storeKey: storeKey,
        name: row.product,
        sku: row.sku.isNotEmpty ? row.sku : existing.sku,
        price: row.price ?? existing.price,
        quantity: qty,
        description: row.description.isNotEmpty ? row.description : existing.description,
      );
      results.add(RowResult(row, RowStatus.update, 'Qty ${existing.quantity} → $qty'));
    } else {
      writes[writeKey] = _ProductWrite(
        existingId: null,
        companyKey: companyKey,
        storeKey: storeKey,
        name: row.product,
        sku: row.sku,
        price: row.price,
        quantity: row.quantity ?? 0,
        description: row.description,
      );
      results.add(RowResult(row, RowStatus.newProduct, 'New'));
    }
  }

  return ImportPlan._(results, newCompanies, newStores, writes, companyIds, storeIds);
}

// ---------------------------------------------------------------------
//  Writing to Firestore
// ---------------------------------------------------------------------

/// Applies the plan in three phases (companies, then stores, then products),
/// so each record's parent already exists when it is saved.
Future<void> runImport(ImportPlan plan, {void Function(double progress)? onProgress}) async {
  final fs = FirebaseFirestore.instance;
  final companyIds = Map<String, String>.from(plan._companyIds);
  final storeIds = Map<String, String>.from(plan._storeIds);

  final total = plan._newCompanies.length + plan._newStores.length + plan._products.length;
  var done = 0;
  void tick(int n) {
    done += n;
    if (onProgress != null && total > 0) onProgress(done / total);
  }

  Future<void> commitInChunks(List<void Function(WriteBatch b)> ops) async {
    for (var i = 0; i < ops.length; i += 400) {
      final batch = fs.batch();
      final chunk = ops.skip(i).take(400).toList();
      for (final op in chunk) {
        op(batch);
      }
      await batch.commit();
      tick(chunk.length);
    }
  }

  // 1. Companies
  final companyOps = <void Function(WriteBatch b)>[];
  plan._newCompanies.forEach((key, c) {
    final ref = fs.collection('companies').doc();
    companyIds[key] = ref.id;
    companyOps.add((b) => b.set(ref, {
          'name': c.name,
          'description': '',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }));
  });
  await commitInChunks(companyOps);

  // 2. Stores
  final storeOps = <void Function(WriteBatch b)>[];
  plan._newStores.forEach((key, s) {
    final ref = fs.collection('stores').doc();
    storeIds[key] = ref.id;
    final companyId = companyIds[s.companyKey]!;
    storeOps.add((b) => b.set(ref, {
          'companyId': companyId,
          'name': s.name,
          'address': s.address,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }));
  });
  await commitInChunks(storeOps);

  // 3. Products
  final productOps = <void Function(WriteBatch b)>[];
  for (final p in plan._products.values) {
    final data = <String, dynamic>{
      'companyId': companyIds[p.companyKey]!,
      'storeId': storeIds[p.storeKey]!,
      'name': p.name,
      'sku': p.sku,
      'price': p.price,
      'quantity': p.quantity,
      'description': p.description,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (p.existingId != null) {
      final ref = fs.collection('products').doc(p.existingId);
      productOps.add((b) => b.update(ref, data));
    } else {
      final ref = fs.collection('products').doc();
      data['createdAt'] = FieldValue.serverTimestamp();
      productOps.add((b) => b.set(ref, data));
    }
  }
  await commitInChunks(productOps);
}
