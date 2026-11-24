import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'widgets.dart';

// =====================================================================
//  Saving documents as PDF, PNG or Excel (.xlsx), plus print / share.
//  No extra packages: Excel files are written by hand (they are zipped XML).
// =====================================================================

/// One spreadsheet cell value: String, int, double or null.
typedef XlsxRow = List<Object?>;

/// Builds a one-sheet .xlsx file. The first [headerRows] rows are bold.
/// Columns in [textColumns] are stored as text (keeps barcodes like 0123… exactly),
/// doubles are shown with 2 decimals, and [widths] sets column widths (characters).
Uint8List buildXlsx(
  List<XlsxRow> rows, {
  String sheetName = 'Sheet1',
  int headerRows = 1,
  Set<int> textColumns = const {},
  List<double>? widths,
}) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  String colName(int i) {
    var n = i + 1;
    var s = '';
    while (n > 0) {
      final m = (n - 1) % 26;
      s = String.fromCharCode(65 + m) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  // Styles (cellXfs): 0 normal, 1 bold, 2 money 0.00, 3 text, 4 whole number.
  final sheet = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
  if (rows.isNotEmpty && headerRows > 0) {
    sheet.write('<sheetViews><sheetView workbookViewId="0">'
        '<pane ySplit="$headerRows" topLeftCell="A${headerRows + 1}" activePane="bottomLeft" state="frozen"/>'
        '</sheetView></sheetViews>');
  }
  if (widths != null && widths.isNotEmpty) {
    sheet.write('<cols>');
    for (var i = 0; i < widths.length; i++) {
      sheet.write('<col min="${i + 1}" max="${i + 1}" width="${widths[i]}" customWidth="1"/>');
    }
    sheet.write('</cols>');
  }
  sheet.write('<sheetData>');
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    final header = r < headerRows;
    sheet.write('<row r="${r + 1}">');
    for (var c = 0; c < row.length; c++) {
      final v = row[c];
      if (v == null) continue;
      final ref = '${colName(c)}${r + 1}';
      if (!header && v is num && !textColumns.contains(c)) {
        final style = v is int ? 4 : 2;
        sheet.write('<c r="$ref" s="$style"><v>$v</v></c>');
      } else {
        final style = header ? 1 : (textColumns.contains(c) ? 3 : 0);
        sheet.write('<c r="$ref" t="inlineStr" s="$style"><is><t xml:space="preserve">${esc('$v')}</t></is></c>');
      }
    }
    sheet.write('</row>');
  }
  sheet.write('</sheetData>');
  if (rows.isNotEmpty && headerRows > 0) {
    final lastCol = colName(rows.fold<int>(1, (m, r) => r.length > m ? r.length : m) - 1);
    sheet.write('<autoFilter ref="A$headerRows:$lastCol${rows.length}"/>');
  }
  sheet.write('</worksheet>');

  final safeSheet = esc(sheetName.replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ')).trim();
  final files = <String, String>{
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="${safeSheet.isEmpty ? 'Sheet1' : (safeSheet.length > 31 ? safeSheet.substring(0, 31) : safeSheet)}" sheetId="1" r:id="rId1"/></sheets>'
        '</workbook>',
    'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
    'xl/styles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="5">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
        '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        '<xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        '<xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        '</cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        '</styleSheet>',
    'xl/worksheets/sheet1.xml': sheet.toString(),
  };

  final archive = Archive();
  files.forEach((name, text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final List<int>? zipped = ZipEncoder().encode(archive);
  return Uint8List.fromList(zipped ?? const <int>[]);
}

/// Each PDF page as a PNG image (150 dpi).
Future<List<Uint8List>> pdfToPngs(Uint8List pdf, {double dpi = 150}) async {
  final out = <Uint8List>[];
  await for (final page in Printing.raster(pdf, dpi: dpi)) {
    out.add(await page.toPng());
  }
  return out;
}

/// A file-name-safe version of [name] (keeps letters, numbers, spaces, - and _).
String safeFileName(String name) {
  final s = name.replaceAll(RegExp(r'[^A-Za-z0-9 _\-]'), '').trim().replaceAll(RegExp(r'\s+'), '_');
  return s.isEmpty ? 'export' : s;
}

/// Asks where to save [bytes] as [fileName]. Returns true when saved.
Future<bool> saveBytes(BuildContext context, Uint8List bytes, String fileName) async {
  final saved = await FilePicker.saveFile(dialogTitle: 'Save $fileName', fileName: fileName, bytes: bytes);
  if (saved == null) return false;
  if (context.mounted) showMessage(context, 'Saved $fileName');
  return true;
}

enum ExportAction { print, sharePdf, savePdf, savePng, saveExcel }

/// Bottom sheet with Print / Share / Save as PDF, PNG or Excel, then does it.
/// [pdf] builds the PDF; [xlsx] builds the Excel file (omit to hide that option).
Future<void> showExportSheet(
  BuildContext context, {
  required String title,
  required String fileBaseName,
  required Future<Uint8List> Function() pdf,
  Future<Uint8List> Function()? xlsx,
}) async {
  final action = await showModalBottomSheet<ExportAction>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        ListTile(
          leading: const Icon(Icons.print_outlined),
          title: const Text('Print'),
          onTap: () => Navigator.pop(ctx, ExportAction.print),
        ),
        ListTile(
          leading: const Icon(Icons.share_outlined),
          title: const Text('Share as PDF'),
          subtitle: const Text('WhatsApp, email, Drive…'),
          onTap: () => Navigator.pop(ctx, ExportAction.sharePdf),
        ),
        ListTile(
          leading: const Icon(Icons.picture_as_pdf_outlined),
          title: const Text('Save as PDF'),
          onTap: () => Navigator.pop(ctx, ExportAction.savePdf),
        ),
        ListTile(
          leading: const Icon(Icons.image_outlined),
          title: const Text('Save as picture (PNG)'),
          onTap: () => Navigator.pop(ctx, ExportAction.savePng),
        ),
        if (xlsx != null)
          ListTile(
            leading: const Icon(Icons.table_chart_outlined),
            title: const Text('Save as Excel (.xlsx)'),
            onTap: () => Navigator.pop(ctx, ExportAction.saveExcel),
          ),
      ]),
    ),
  );
  if (action == null || !context.mounted) return;

  final base = safeFileName(fileBaseName);
  try {
    switch (action) {
      case ExportAction.print:
        final printBytes = await pdf();
        await Printing.layoutPdf(name: title, onLayout: (_) async => printBytes);
      case ExportAction.sharePdf:
        await Printing.sharePdf(bytes: await pdf(), filename: '$base.pdf');
      case ExportAction.savePdf:
        final pdfBytes = await pdf();
        if (context.mounted) await saveBytes(context, pdfBytes, '$base.pdf');
      case ExportAction.savePng:
        final pages = await pdfToPngs(await pdf());
        for (var i = 0; i < pages.length; i++) {
          if (!context.mounted) return;
          final name = pages.length == 1 ? '$base.png' : '${base}_page${i + 1}.png';
          final ok = await saveBytes(context, pages[i], name);
          if (!ok) break; // cancelled
        }
      case ExportAction.saveExcel:
        final xlsxBytes = await xlsx!();
        if (context.mounted) await saveBytes(context, xlsxBytes, '$base.xlsx');
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
