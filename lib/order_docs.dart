import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'brand.dart';
import 'data.dart';
import 'export.dart';
import 'orders.dart';

// =====================================================================
//  Printouts for an order:
//   * Purchase order – retail price only.
//   * Delivery note  – wholesale price as the unit price, batch code and
//                      expiry date; never shows which storage unit an item
//                      came from (the app itself still shows it).
//  Both have the Beauty Souq logo and name, and a barcode image per item.
// =====================================================================

enum OrderDocType { purchaseOrder, deliveryNote }

String orderDocTitle(OrderDocType t) => switch (t) {
      OrderDocType.purchaseOrder => 'Purchase Order',
      OrderDocType.deliveryNote => 'Delivery Note',
    };

/// What a printout shows for one order line.
class DocLine {
  final String name;
  final String barcode;
  final int quantity;
  final double? retail;
  final double? wholesale;
  final String batch;
  final DateTime? expiry;
  const DocLine(this.name, this.barcode, this.quantity, this.retail, this.wholesale, this.batch, this.expiry);
}

/// Line details for the printouts. Older orders did not save prices/batch/expiry with
/// their lines, so those are read from the products (and admin prices) once.
Future<List<DocLine>> docLines(PurchaseOrder o) async {
  final fs = FirebaseFirestore.instance;
  final need = {for (final l in o.lines) if (!l.hasProductDetails && l.productId.isNotEmpty) l.productId};
  final products = <String, Map<String, dynamic>>{};
  final prices = <String, Map<String, dynamic>>{};
  for (final id in need) {
    try {
      final p = await fs.collection('products').doc(id).get();
      if (p.exists) products[id] = p.data() ?? const {};
      final pr = await fs.collection('productPrices').doc(id).get();
      if (pr.exists) prices[id] = pr.data() ?? const {};
    } catch (_) {
      // Deleted product or no access: fall back to what the line has.
    }
  }
  double? n(Object? v) => (v as num?)?.toDouble();
  return [
    for (final l in o.lines)
      if (l.hasProductDetails || !products.containsKey(l.productId))
        DocLine(l.productName, l.sku, l.quantity, l.retailPrice, l.wholesalePrice ?? l.unitPrice, l.batchCode,
            l.expiryDate)
      else
        DocLine(
          l.productName,
          l.sku,
          l.quantity,
          n(products[l.productId]!['retailPrice'] ?? products[l.productId]!['price']),
          n(prices[l.productId]?['wholesale']) ?? l.unitPrice,
          (products[l.productId]!['batchCode'] as String?) ?? '',
          products[l.productId]!['expiryDate'] is Timestamp
              ? (products[l.productId]!['expiryDate'] as Timestamp).toDate().toLocal()
              : null,
        ),
  ];
}

double? _unitPrice(OrderDocType t, DocLine l) =>
    t == OrderDocType.purchaseOrder ? l.retail : l.wholesale;

String _num(double? v) => v == null ? '' : v.toStringAsFixed(2);

/// The barcode image for a code: EAN-13 / EAN-8 / UPC-A when valid, otherwise Code 128.
pw.Widget _barcode(String code) {
  final c = code.trim();
  if (c.isEmpty) return pw.Text('-', style: const pw.TextStyle(fontSize: 8));
  pw.Barcode type = pw.Barcode.code128();
  for (final candidate in [pw.Barcode.ean13(), pw.Barcode.ean8(), pw.Barcode.upcA()]) {
    if (candidate.isValid(c)) {
      type = candidate;
      break;
    }
  }
  if (!type.isValid(c)) return pw.Text(c, style: const pw.TextStyle(fontSize: 8));
  return pw.BarcodeWidget(
    barcode: type,
    data: c,
    width: 112,
    height: 36,
    drawText: true,
    textStyle: const pw.TextStyle(fontSize: 7),
  );
}

Future<Uint8List> buildOrderDocPdf(PurchaseOrder o, OrderDocType type, {DateTime? date}) async {
  final lines = await docLines(o);
  pw.ThemeData? theme;
  try {
    theme = pw.ThemeData.withFont(
      base: await PdfGoogleFonts.robotoRegular(),
      bold: await PdfGoogleFonts.robotoBold(),
    );
  } catch (_) {
    theme = null; // offline: built-in font
  }

  final plum = PdfColor.fromHex('#5B1F52');
  final title = orderDocTitle(type);
  final isDn = type == OrderDocType.deliveryNote;
  final logo = pw.MemoryImage(brandLogoPng);
  final when = date ?? o.createdAt ?? DateTime.now();

  final headers = [
    '#',
    'Product',
    'Barcode',
    if (isDn) 'Batch code',
    if (isDn) 'Expiry',
    'Qty',
    isDn ? 'Unit price (QAR)' : 'Retail price (QAR)',
    'Total (QAR)',
  ];
  final numericFrom = headers.length - 3; // Qty, unit price, total
  var units = 0;
  var total = 0.0;

  pw.Widget cell(String text, {bool bold = false, bool right = false, PdfColor? color}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        child: pw.Text(text,
            textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : null, color: color)),
      );

  final rows = <pw.TableRow>[
    pw.TableRow(
      decoration: pw.BoxDecoration(color: plum),
      children: [
        for (var i = 0; i < headers.length; i++)
          cell(headers[i], bold: true, right: i >= numericFrom, color: PdfColors.white),
      ],
    ),
  ];
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final price = _unitPrice(type, l);
    final lineTotal = price == null ? null : price * l.quantity;
    units += l.quantity;
    total += lineTotal ?? 0;
    rows.add(pw.TableRow(
      verticalAlignment: pw.TableCellVerticalAlignment.middle,
      decoration: i.isOdd ? const pw.BoxDecoration(color: PdfColors.grey100) : null,
      children: [
        cell('${i + 1}'),
        cell(l.name),
        pw.Padding(padding: const pw.EdgeInsets.all(4), child: _barcode(l.barcode)),
        if (isDn) cell(l.batch.isEmpty ? '-' : l.batch),
        if (isDn) cell(l.expiry == null ? '-' : formatDate(l.expiry)),
        cell('${l.quantity}', right: true),
        cell(_num(price), right: true),
        cell(_num(lineTotal), right: true),
      ],
    ));
  }
  rows.add(pw.TableRow(children: [
    for (var i = 0; i < headers.length; i++)
      if (i == 1)
        cell('TOTAL', bold: true)
      else if (i == numericFrom)
        cell('$units', bold: true, right: true)
      else if (i == headers.length - 1)
        cell(total.toStringAsFixed(2), bold: true, right: true)
      else
        cell(''),
  ]));

  final widths = <int, pw.TableColumnWidth>{
    0: const pw.FixedColumnWidth(18),
    1: const pw.FlexColumnWidth(3),
    2: const pw.FixedColumnWidth(122),
    if (isDn) 3: const pw.FlexColumnWidth(1.3),
    if (isDn) 4: const pw.FixedColumnWidth(54),
    numericFrom: const pw.FixedColumnWidth(30),
    numericFrom + 1: const pw.FixedColumnWidth(62),
    numericFrom + 2: const pw.FixedColumnWidth(56),
  };

  pw.Widget info(String label, String value) => value.isEmpty
      ? pw.SizedBox()
      : pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 2),
          child: pw.RichText(
            text: pw.TextSpan(children: [
              pw.TextSpan(text: '$label: ', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
              pw.TextSpan(text: value, style: const pw.TextStyle(fontSize: 9)),
            ]),
          ),
        );

  final doc = pw.Document(title: '$title ${o.number}');
  doc.addPage(pw.MultiPage(
    theme: theme,
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 36),
    header: (ctx) => pw.Column(children: [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
        pw.Image(logo, height: 54),
        pw.SizedBox(width: 10),
        pw.Expanded(
          child: pw.Text(appName, style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: plum)),
        ),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text(title.toUpperCase(),
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, letterSpacing: 1)),
          pw.Text('No. ${o.number}', style: const pw.TextStyle(fontSize: 10)),
          pw.Text('Date: ${formatDate(when)}', style: const pw.TextStyle(fontSize: 10)),
        ]),
      ]),
      pw.SizedBox(height: 6),
      pw.Divider(color: plum, thickness: 1.2),
      pw.SizedBox(height: 4),
    ]),
    footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text('$appName · $title ${o.number}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
    ]),
    build: (ctx) => [
      pw.Text(isDn ? 'Deliver to' : 'Customer',
          style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: plum)),
      pw.SizedBox(height: 3),
      pw.Text(o.customerName, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      info('Phone', o.customerPhone),
      info('Email', o.customerEmail),
      info('Customer ref', o.customerRef),
      pw.SizedBox(height: 12),
      if (lines.isEmpty)
        pw.Text('No items.')
      else
        pw.Table(
          columnWidths: widths,
          border: const pw.TableBorder(
            horizontalInside: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
            bottom: pw.BorderSide(color: PdfColors.grey500, width: 0.5),
          ),
          children: rows,
        ),
      if (o.notes.isNotEmpty) ...[
        pw.SizedBox(height: 12),
        info('Notes', o.notes),
      ],
      if (isDn) ...[
        pw.SizedBox(height: 40),
        pw.Row(children: [
          for (final label in ['Delivered by', 'Received by (name)', 'Signature & date']) ...[
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Container(height: 0.7, color: PdfColors.grey600),
                pw.SizedBox(height: 3),
                pw.Text(label, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
              ]),
            ),
            if (label != 'Signature & date') pw.SizedBox(width: 20),
          ],
        ]),
      ],
    ],
  ));
  return doc.save();
}

/// The same document as a spreadsheet.
Future<Uint8List> buildOrderDocXlsx(PurchaseOrder o, OrderDocType type, {DateTime? date}) async {
  final lines = await docLines(o);
  final isDn = type == OrderDocType.deliveryNote;
  final when = date ?? o.createdAt ?? DateTime.now();
  final head = [
    'Product',
    'Barcode',
    if (isDn) 'Batch code',
    if (isDn) 'Expiry date',
    'Quantity',
    isDn ? 'Unit price (QAR)' : 'Retail price (QAR)',
    'Total (QAR)',
  ];
  var units = 0;
  var total = 0.0;
  final rows = <XlsxRow>[
    ['$appName – ${orderDocTitle(type)} ${o.number}'],
    ['Date', formatDate(when)],
    ['Customer', o.customerName],
    if (o.customerRef.isNotEmpty) ['Customer ref', o.customerRef],
    [],
    head,
  ];
  for (final l in lines) {
    final price = _unitPrice(type, l);
    final lineTotal = price == null ? null : price * l.quantity;
    units += l.quantity;
    total += lineTotal ?? 0;
    rows.add([
      l.name,
      l.barcode,
      if (isDn) l.batch,
      if (isDn) formatDate(l.expiry),
      l.quantity,
      price,
      lineTotal,
    ]);
  }
  rows.add(['TOTAL', null, if (isDn) null, if (isDn) null, units, null, total]);
  return buildXlsx(
    rows,
    sheetName: orderDocTitle(type),
    headerRows: 0,
    textColumns: {1, if (isDn) 2},
    widths: [40, 18, if (isDn) 14, if (isDn) 12, 10, 16, 14],
  );
}
