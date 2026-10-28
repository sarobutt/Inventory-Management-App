import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'brand.dart';
import 'data.dart';
import 'widgets.dart';

/// A table ready to show on screen or print.
class TableData {
  final String title;
  final List<String> headers;
  final List<List<String>> rows;

  /// Column indexes that hold numbers (right-aligned).
  final Set<int> numericColumns;

  /// Optional totals row (same length as headers).
  final List<String>? totals;

  const TableData({
    required this.title,
    required this.headers,
    required this.rows,
    this.numericColumns = const {},
    this.totals,
  });
}

// ---------------- Building the three tables ----------------

/// Removes the given column indexes from headers, rows and totals (used to hide prices).
TableData _withoutColumns(TableData t, Set<int> drop) {
  if (drop.isEmpty) return t;
  List<String> keep(List<String> r) => [for (var i = 0; i < r.length; i++) if (!drop.contains(i)) r[i]];
  final numeric = <int>{};
  var newIndex = 0;
  for (var i = 0; i < t.headers.length; i++) {
    if (drop.contains(i)) continue;
    if (t.numericColumns.contains(i)) numeric.add(newIndex);
    newIndex++;
  }
  return TableData(
    title: t.title,
    headers: keep(t.headers),
    rows: [for (final r in t.rows) keep(r)],
    numericColumns: numeric,
    totals: t.totals == null ? null : keep(t.totals!),
  );
}

TableData companiesTable(List<Company> companies, List<Store> stores, List<Product> products, {bool showPrices = true}) {
  final rows = <List<String>>[];
  var tStores = 0, tProducts = 0, tUnits = 0;
  var tValue = 0.0;
  for (final c in companies) {
    final s = stores.where((x) => x.companyId == c.id).length;
    final ps = products.where((x) => x.companyId == c.id).toList();
    final units = ps.fold<int>(0, (sum, p) => sum + p.quantity);
    final value = ps.fold<double>(0, (sum, p) => sum + p.value);
    tStores += s;
    tProducts += ps.length;
    tUnits += units;
    tValue += value;
    rows.add([c.name, c.description, count(s), count(ps.length), count(units), money(value)]);
  }
  final t = TableData(
    title: 'Companies',
    headers: const ['Company', 'Description', 'Stores', 'Products', 'Units', 'Stock value (retail)'],
    rows: rows,
    numericColumns: const {2, 3, 4, 5},
    totals: ['TOTAL', '', count(tStores), count(tProducts), count(tUnits), money(tValue)],
  );
  return showPrices ? t : _withoutColumns(t, {5});
}

TableData storesTable(List<Store> stores, List<Company> companies, List<Product> products, {bool showPrices = true}) {
  final companyName = {for (final c in companies) c.id: c.name};
  final rows = <List<String>>[];
  var tProducts = 0, tUnits = 0;
  var tValue = 0.0;
  for (final s in stores) {
    final ps = products.where((x) => x.storeId == s.id).toList();
    final units = ps.fold<int>(0, (sum, p) => sum + p.quantity);
    final value = ps.fold<double>(0, (sum, p) => sum + p.value);
    tProducts += ps.length;
    tUnits += units;
    tValue += value;
    rows.add([s.name, companyName[s.companyId] ?? '', s.address, count(ps.length), count(units), money(value)]);
  }
  final t = TableData(
    title: 'Stores',
    headers: const ['Store', 'Company', 'Address', 'Products', 'Units', 'Stock value (retail)'],
    rows: rows,
    numericColumns: const {3, 4, 5},
    totals: ['TOTAL', '', '', count(tProducts), count(tUnits), money(tValue)],
  );
  return showPrices ? t : _withoutColumns(t, {5});
}

TableData productsTable(List<Product> products, List<Company> companies, List<Store> stores, {bool showPrices = true}) {
  final companyName = {for (final c in companies) c.id: c.name};
  final storeName = {for (final s in stores) s.id: s.name};
  var tUnits = 0;
  var tValue = 0.0;
  final rows = <List<String>>[];
  for (final p in products) {
    tUnits += p.quantity;
    tValue += p.value;
    rows.add([
      p.name,
      p.sku,
      companyName[p.companyId] ?? '',
      storeName[p.storeId] ?? '',
      formatPrice(p.prices.retail),
      formatPrice(p.prices.wholesale),
      formatPrice(p.prices.perItem),
      count(p.quantity),
      money(p.value),
    ]);
  }
  final t = TableData(
    title: 'Products',
    headers: const ['Product', 'SKU', 'Company', 'Store', 'Retail', 'Wholesale', 'Per item', 'Qty', 'Value (retail)'],
    rows: rows,
    numericColumns: const {4, 5, 6, 7, 8},
    totals: ['TOTAL', '', '', '', '', '', '', count(tUnits), money(tValue)],
  );
  // Staff keep Retail; wholesale, per item and value are hidden.
  return showPrices ? t : _withoutColumns(t, {5, 6, 8});
}

// ---------------- PDF / printing ----------------

String _two(int n) => n.toString().padLeft(2, '0');

String _timestamp() {
  final n = DateTime.now();
  return '${_two(n.day)}/${_two(n.month)}/${n.year} ${_two(n.hour)}:${_two(n.minute)}';
}

Future<Uint8List> buildPdf(TableData t, {String filterText = ''}) async {
  // Roboto supports more characters than the built-in font; fall back if offline.
  pw.ThemeData? theme;
  try {
    theme = pw.ThemeData.withFont(
      base: await PdfGoogleFonts.robotoRegular(),
      bold: await PdfGoogleFonts.robotoBold(),
    );
  } catch (_) {
    theme = null;
  }

  final align = <int, pw.Alignment>{for (final i in t.numericColumns) i: pw.Alignment.centerRight};
  final subtitle = [if (filterText.isNotEmpty) filterText, 'Generated ${_timestamp()}'].join('   |   ');

  final doc = pw.Document(title: t.title);
  doc.addPage(
    pw.MultiPage(
      theme: theme,
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(28),
      header: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(appName.toUpperCase(),
              style: pw.TextStyle(fontSize: 9, letterSpacing: 2, color: PdfColor.fromHex('#5B1F52'))),
          pw.Text(t.title, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 2),
          pw.Text(subtitle, style: pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          pw.SizedBox(height: 10),
        ],
      ),
      footer: (ctx) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      ),
      build: (ctx) => [
        if (t.rows.isEmpty)
          pw.Text('No records.')
        else
          pw.TableHelper.fromTextArray(
            headers: t.headers,
            data: [...t.rows, if (t.totals != null) t.totals!],
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white),
            headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#5B1F52')),
            cellStyle: pw.TextStyle(fontSize: 9),
            cellAlignments: align,
            headerAlignments: align,
            oddRowDecoration: pw.BoxDecoration(color: PdfColors.grey100),
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          ),
      ],
    ),
  );
  return doc.save();
}

/// Opens the system print dialog (Android / iOS), which also offers "Save as PDF".
Future<void> printTable(TableData t, {String filterText = ''}) async {
  final bytes = await buildPdf(t, filterText: filterText);
  await Printing.layoutPdf(name: t.title, onLayout: (_) async => bytes);
}

/// Shares the table as a PDF file (email, WhatsApp, Drive, etc.).
Future<void> shareTable(TableData t, {String filterText = ''}) async {
  final bytes = await buildPdf(t, filterText: filterText);
  await Printing.sharePdf(bytes: bytes, filename: '${t.title.toLowerCase()}.pdf');
}
