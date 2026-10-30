import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'audit.dart';
import 'auth.dart';

// =====================================================================
//  Purchase orders: an external customer buys products from us.
//
//  purchaseOrders/{id}
//    number, customerName, customerPhone, customerEmail, customerRef, notes
//    lines: [{productId, productName, sku, storeId, storeName, companyId, quantity, unitPrice}]
//    linesTotal, units, amount (invoice amount, may differ from linesTotal)
//    payment: notPaid | pending | paid
//    status:  draft | completed | cancelled
//    invoice: {name, mime, size, chunks}       (file itself is in orderFiles)
//    createdAt/By/ByName, completedAt/By/ByName, cancelledAt/By/ByName
//
//  orderFiles/{orderId}              invoice metadata
//  orderFiles/{orderId}/chunks/{i}   invoice bytes in ~900 KB pieces
//  (kept in Firestore so no paid Cloud Storage plan is needed)
// =====================================================================

enum OrderStatus { draft, completed, cancelled }

enum PaymentStatus { notPaid, pending, paid }

String orderStatusLabel(OrderStatus s) => switch (s) {
      OrderStatus.draft => 'Draft',
      OrderStatus.completed => 'Completed',
      OrderStatus.cancelled => 'Cancelled',
    };

String paymentStatusLabel(PaymentStatus s) => switch (s) {
      PaymentStatus.notPaid => 'Not paid',
      PaymentStatus.pending => 'Pending',
      PaymentStatus.paid => 'Paid',
    };

T _enumFrom<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.firstWhere((v) => v.name == name, orElse: () => fallback);

class OrderLine {
  final String productId;
  final String productName;
  final String sku;
  final String storeId;
  final String storeName;
  final String companyId;
  final int quantity;
  final double unitPrice;

  const OrderLine({
    required this.productId,
    required this.productName,
    required this.sku,
    required this.storeId,
    required this.storeName,
    required this.companyId,
    required this.quantity,
    required this.unitPrice,
  });

  double get total => unitPrice * quantity;

  OrderLine copyWith({int? quantity, double? unitPrice}) => OrderLine(
        productId: productId,
        productName: productName,
        sku: sku,
        storeId: storeId,
        storeName: storeName,
        companyId: companyId,
        quantity: quantity ?? this.quantity,
        unitPrice: unitPrice ?? this.unitPrice,
      );

  Map<String, dynamic> toMap() => {
        'productId': productId,
        'productName': productName,
        'sku': sku,
        'storeId': storeId,
        'storeName': storeName,
        'companyId': companyId,
        'quantity': quantity,
        'unitPrice': unitPrice,
      };

  factory OrderLine.fromMap(Map<String, dynamic> d) => OrderLine(
        productId: (d['productId'] as String?) ?? '',
        productName: (d['productName'] as String?) ?? '',
        sku: (d['sku'] as String?) ?? '',
        storeId: (d['storeId'] as String?) ?? '',
        storeName: (d['storeName'] as String?) ?? '',
        companyId: (d['companyId'] as String?) ?? '',
        quantity: (d['quantity'] as num?)?.toInt() ?? 0,
        unitPrice: (d['unitPrice'] as num?)?.toDouble() ?? 0,
      );
}

class InvoiceInfo {
  final String name;
  final String mime;
  final int size;
  final int chunks;

  const InvoiceInfo({required this.name, required this.mime, required this.size, required this.chunks});

  bool get isPdf => mime == 'application/pdf';

  String get sizeLabel => size >= 1024 * 1024
      ? '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(size / 1024).ceil()} KB';

  Map<String, dynamic> toMap() => {'name': name, 'mime': mime, 'size': size, 'chunks': chunks};

  static InvoiceInfo? fromMap(Object? v) {
    if (v is! Map) return null;
    final d = v.cast<String, dynamic>();
    return InvoiceInfo(
      name: (d['name'] as String?) ?? 'invoice',
      mime: (d['mime'] as String?) ?? 'application/octet-stream',
      size: (d['size'] as num?)?.toInt() ?? 0,
      chunks: (d['chunks'] as num?)?.toInt() ?? 0,
    );
  }
}

class PurchaseOrder {
  final String id;
  final String number;
  final String customerName;
  final String customerPhone;
  final String customerEmail;
  final String customerRef;
  final String notes;
  final List<OrderLine> lines;

  /// Invoice amount entered by the admin (null = use [linesTotal]).
  final double? amount;
  final PaymentStatus payment;
  final OrderStatus status;
  final InvoiceInfo? invoice;
  final String createdByName;
  final String completedByName;
  final String cancelledByName;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;

  const PurchaseOrder({
    required this.id,
    required this.number,
    required this.customerName,
    this.customerPhone = '',
    this.customerEmail = '',
    this.customerRef = '',
    this.notes = '',
    this.lines = const [],
    this.amount,
    this.payment = PaymentStatus.notPaid,
    this.status = OrderStatus.draft,
    this.invoice,
    this.createdByName = '',
    this.completedByName = '',
    this.cancelledByName = '',
    this.createdAt,
    this.completedAt,
    this.cancelledAt,
  });

  double get linesTotal => lines.fold<double>(0, (a, l) => a + l.total);
  double get effectiveAmount => amount ?? linesTotal;
  int get units => lines.fold<int>(0, (a, l) => a + l.quantity);

  factory PurchaseOrder.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    String str(String k) => (d[k] as String?) ?? '';
    DateTime? ts(String k) => d[k] is Timestamp ? (d[k] as Timestamp).toDate() : null;
    return PurchaseOrder(
      id: doc.id,
      number: str('number'),
      customerName: str('customerName'),
      customerPhone: str('customerPhone'),
      customerEmail: str('customerEmail'),
      customerRef: str('customerRef'),
      notes: str('notes'),
      lines: [
        for (final l in (d['lines'] as List?) ?? const [])
          if (l is Map) OrderLine.fromMap(l.cast<String, dynamic>()),
      ],
      amount: (d['amount'] as num?)?.toDouble(),
      payment: _enumFrom(PaymentStatus.values, d['payment'], PaymentStatus.notPaid),
      status: _enumFrom(OrderStatus.values, d['status'], OrderStatus.draft),
      invoice: InvoiceInfo.fromMap(d['invoice']),
      createdByName: str('createdByName'),
      completedByName: str('completedByName'),
      cancelledByName: str('cancelledByName'),
      createdAt: ts('createdAt'),
      completedAt: ts('completedAt'),
      cancelledAt: ts('cancelledAt'),
    );
  }
}

class Orders {
  Orders._();

  static FirebaseFirestore get _fs => FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _col => _fs.collection('purchaseOrders');
  static CollectionReference<Map<String, dynamic>> get _files => _fs.collection('orderFiles');
  static CollectionReference<Map<String, dynamic>> get _products => _fs.collection('products');

  static const int maxInvoiceBytes = 8 * 1024 * 1024;
  static const int _chunkBytes = 900 * 1024;

  static String newId() => _col.doc().id;

  /// e.g. PO-261030-4821
  static String newNumber() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final rand = Random().nextInt(9000) + 1000;
    return 'PO-${two(n.year % 100)}${two(n.month)}${two(n.day)}-$rand';
  }

  static String _meName() {
    final me = currentUser.value;
    if (me == null) return '';
    return me.displayName.isEmpty ? me.username : me.displayName;
  }

  static Stream<List<PurchaseOrder>> watchAll() => _col.snapshots().map((s) {
        final list = s.docs.map(PurchaseOrder.fromDoc).toList();
        list.sort((a, b) {
          final at = a.createdAt, bt = b.createdAt;
          if (at == null && bt == null) return 0;
          if (at == null) return -1;
          if (bt == null) return 1;
          return bt.compareTo(at);
        });
        return list;
      });

  static Stream<PurchaseOrder?> watch(String id) =>
      _col.doc(id).snapshots().map((d) => d.exists ? PurchaseOrder.fromDoc(d) : null);

  static Map<String, dynamic> _header(PurchaseOrder o) => {
        'number': o.number,
        'customerName': o.customerName,
        'customerPhone': o.customerPhone,
        'customerEmail': o.customerEmail,
        'customerRef': o.customerRef,
        'notes': o.notes,
        'amount': o.amount,
        'payment': o.payment.name,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  static Map<String, dynamic> _linesData(PurchaseOrder o) => {
        'lines': [for (final l in o.lines) l.toMap()],
        'linesTotal': o.linesTotal,
        'units': o.units,
      };

  /// Saves a draft (everything), or for a completed/cancelled order only the
  /// customer, amount, payment and notes (its products can no longer change).
  static Future<void> save(PurchaseOrder o, {required bool isNew}) async {
    final data = <String, dynamic>{..._header(o)};
    if (o.status == OrderStatus.draft) data.addAll(_linesData(o));
    if (isNew) {
      final me = currentUser.value;
      await _col.doc(o.id).set({
        ...data,
        'status': OrderStatus.draft.name,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': me?.uid ?? '',
        'createdByName': _meName(),
      });
    } else {
      await _col.doc(o.id).update(data);
    }
  }

  /// Completes the order: checks every store has enough stock, subtracts it, records
  /// the movements in the stock audit and marks the order completed – all at once.
  static Future<void> complete(PurchaseOrder o) async {
    if (o.lines.isEmpty) throw StateError('Add at least one product to the order.');
    final me = currentUser.value!;
    final meName = _meName();

    final places = <String, PlaceNames>{};
    for (final l in o.lines) {
      places[l.storeId] ??= await Audit.names(l.storeId, l.companyId);
    }
    final need = <String, int>{};
    final lineFor = <String, OrderLine>{};
    for (final l in o.lines) {
      need[l.productId] = (need[l.productId] ?? 0) + l.quantity;
      lineFor[l.productId] = l;
    }

    final ref = _col.doc(o.id);
    await _fs.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists && snap.data()?['status'] != OrderStatus.draft.name) {
        throw StateError('This order has already been completed or cancelled.');
      }
      // ---- reads ----
      final before = <String, int>{};
      for (final id in need.keys) {
        final l = lineFor[id]!;
        final p = await tx.get(_products.doc(id));
        if (!p.exists) throw StateError('“${l.productName}” no longer exists. Remove it from the order.');
        if (p.data()?['storeId'] != l.storeId) {
          throw StateError('“${l.productName}” was moved to another store. Remove it and add it again.');
        }
        final q = (p.data()?['quantity'] as num?)?.toInt() ?? 0;
        if (q < need[id]!) {
          throw StateError('Not enough “${l.productName}” in ${l.storeName}: $q in stock, ${need[id]} ordered.');
        }
        before[id] = q;
      }
      // ---- writes ----
      for (final id in need.keys) {
        final l = lineFor[id]!;
        final after = before[id]! - need[id]!;
        tx.update(_products.doc(id), {'quantity': after, 'updatedAt': FieldValue.serverTimestamp()});
        tx.set(
          Audit.col.doc(),
          Audit.entry(
            type: AuditType.order,
            productId: id,
            productName: l.productName,
            sku: l.sku,
            storeId: l.storeId,
            companyId: l.companyId,
            place: places[l.storeId]!,
            before: before[id]!,
            after: after,
            note: 'Purchase order ${o.number} – ${o.customerName}',
          ),
        );
      }
      final data = <String, dynamic>{
        ..._header(o),
        ..._linesData(o),
        'status': OrderStatus.completed.name,
        'completedAt': FieldValue.serverTimestamp(),
        'completedBy': me.uid,
        'completedByName': meName,
      };
      if (snap.exists) {
        tx.update(ref, data);
      } else {
        tx.set(ref, {
          ...data,
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': me.uid,
          'createdByName': meName,
        });
      }
    });
  }

  /// Cancels an order. If it was completed, its stock is returned to the stores.
  /// Returns the names of products whose stock could not be returned (deleted since).
  static Future<List<String>> cancel(PurchaseOrder o) async {
    final me = currentUser.value!;
    final meName = _meName();
    final ref = _col.doc(o.id);
    final cancelData = {
      'status': OrderStatus.cancelled.name,
      'cancelledAt': FieldValue.serverTimestamp(),
      'cancelledBy': me.uid,
      'cancelledByName': meName,
    };

    if (o.status == OrderStatus.draft) {
      await ref.update(cancelData);
      return const [];
    }

    final places = <String, PlaceNames>{};
    for (final l in o.lines) {
      places[l.storeId] ??= await Audit.names(l.storeId, l.companyId);
    }
    final give = <String, int>{};
    final lineFor = <String, OrderLine>{};
    for (final l in o.lines) {
      give[l.productId] = (give[l.productId] ?? 0) + l.quantity;
      lineFor[l.productId] = l;
    }
    final missing = <String>[];

    await _fs.runTransaction((tx) async {
      missing.clear();
      final snap = await tx.get(ref);
      if (snap.data()?['status'] != OrderStatus.completed.name) {
        throw StateError('Only completed orders can be cancelled with stock returned.');
      }
      final current = <String, (int, String, String)>{}; // qty, storeId, companyId
      for (final id in give.keys) {
        final p = await tx.get(_products.doc(id));
        if (!p.exists) {
          missing.add(lineFor[id]!.productName);
          continue;
        }
        final d = p.data()!;
        current[id] = (
          (d['quantity'] as num?)?.toInt() ?? 0,
          (d['storeId'] as String?) ?? lineFor[id]!.storeId,
          (d['companyId'] as String?) ?? lineFor[id]!.companyId,
        );
      }
      for (final id in current.keys) {
        final l = lineFor[id]!;
        final (qty, storeId, companyId) = current[id]!;
        final after = qty + give[id]!;
        tx.update(_products.doc(id), {'quantity': after, 'updatedAt': FieldValue.serverTimestamp()});
        tx.set(
          Audit.col.doc(),
          Audit.entry(
            type: AuditType.order,
            productId: id,
            productName: l.productName,
            sku: l.sku,
            storeId: storeId,
            companyId: companyId,
            place: places[storeId] ?? places[l.storeId]!,
            before: qty,
            after: after,
            note: 'Purchase order ${o.number} cancelled – stock returned',
          ),
        );
      }
      tx.update(ref, cancelData);
    });
    return missing;
  }

  /// Deletes a draft or cancelled order (completed orders must be cancelled first).
  static Future<void> delete(PurchaseOrder o) async {
    if (o.status == OrderStatus.completed) {
      throw StateError('Cancel the order first (this returns its stock), then delete it.');
    }
    await deleteInvoice(o.id);
    await _col.doc(o.id).delete();
  }

  // ---------------- Invoice file ----------------

  static String mimeFor(String fileName) {
    final n = fileName.toLowerCase();
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  static bool isSupportedInvoice(String fileName) => mimeFor(fileName) != 'application/octet-stream';

  /// Stores the invoice for [orderId] (replacing any previous one) and links it to the order.
  static Future<InvoiceInfo> uploadInvoice(String orderId, Uint8List bytes, String fileName) async {
    if (bytes.length > maxInvoiceBytes) {
      throw StateError('The invoice file is too large (max 8 MB). Try a PDF or a smaller photo.');
    }
    await deleteInvoice(orderId);
    final chunks = (bytes.length / _chunkBytes).ceil();
    final meta = _files.doc(orderId);
    for (var i = 0; i < chunks; i++) {
      final part = bytes.sublist(i * _chunkBytes, min((i + 1) * _chunkBytes, bytes.length));
      await meta.collection('chunks').doc('$i').set({'i': i, 'data': Blob(part)});
    }
    final info = InvoiceInfo(name: fileName, mime: mimeFor(fileName), size: bytes.length, chunks: chunks);
    await meta.set({...info.toMap(), 'uploadedAt': FieldValue.serverTimestamp(), 'uploadedByName': _meName()});
    await _col.doc(orderId).set({'invoice': info.toMap()}, SetOptions(merge: true));
    return info;
  }

  static Future<Uint8List> downloadInvoice(String orderId) async {
    final snap = await _files.doc(orderId).collection('chunks').orderBy('i').get();
    if (snap.docs.isEmpty) throw StateError('The invoice file could not be found.');
    final out = BytesBuilder(copy: false);
    for (final d in snap.docs) {
      final data = d.data()['data'];
      if (data is Blob) out.add(data.bytes);
    }
    return out.takeBytes();
  }

  /// Removes the invoice file. With [unlinkOrder], also clears it from the order.
  static Future<void> deleteInvoice(String orderId, {bool unlinkOrder = false}) async {
    final chunks = await _files.doc(orderId).collection('chunks').get();
    for (final d in chunks.docs) {
      await d.reference.delete();
    }
    await _files.doc(orderId).delete();
    if (unlinkOrder) await _col.doc(orderId).update({'invoice': FieldValue.delete()});
  }
}
