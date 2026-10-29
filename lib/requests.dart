import 'package:cloud_firestore/cloud_firestore.dart';

import 'audit.dart';
import 'auth.dart';
import 'data.dart';

// =====================================================================
//  Stock change requests
//
//  Staff don't change stock directly; they create a request that an admin
//  approves (which applies the change) or rejects.
//
//  stockRequests/{id}
//    productId, productName, storeId, storeName, companyId,
//    delta (int, + adds stock, - removes stock), note,
//    status: pending | approved | rejected | cancelled,
//    requestedBy, requestedByName, createdAt,
//    decidedBy, decidedByName, decidedAt, decisionNote,
//    quantityBefore, quantityAfter        (set when approved)
// =====================================================================

enum RequestStatus { pending, approved, rejected, cancelled }

RequestStatus _statusFrom(String? s) {
  switch (s) {
    case 'approved':
      return RequestStatus.approved;
    case 'rejected':
      return RequestStatus.rejected;
    case 'cancelled':
      return RequestStatus.cancelled;
    default:
      return RequestStatus.pending;
  }
}

class StockRequest {
  final String id;
  final String productId;
  final String productName;
  final String storeId;
  final String storeName;
  final String companyId;
  final int delta;
  final String note;
  final RequestStatus status;
  final String requestedBy;
  final String requestedByName;
  final DateTime? createdAt;
  final String decidedByName;
  final DateTime? decidedAt;
  final String decisionNote;
  final int? quantityBefore;
  final int? quantityAfter;

  const StockRequest({
    required this.id,
    required this.productId,
    required this.productName,
    required this.storeId,
    required this.storeName,
    required this.companyId,
    required this.delta,
    required this.note,
    required this.status,
    required this.requestedBy,
    required this.requestedByName,
    required this.createdAt,
    required this.decidedByName,
    required this.decidedAt,
    required this.decisionNote,
    required this.quantityBefore,
    required this.quantityAfter,
  });

  bool get isPending => status == RequestStatus.pending;
  String get deltaLabel => delta > 0 ? '+$delta' : '$delta';

  factory StockRequest.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    DateTime? ts(Object? v) => v is Timestamp ? v.toDate() : null;
    return StockRequest(
      id: doc.id,
      productId: (d['productId'] as String?) ?? '',
      productName: (d['productName'] as String?) ?? '',
      storeId: (d['storeId'] as String?) ?? '',
      storeName: (d['storeName'] as String?) ?? '',
      companyId: (d['companyId'] as String?) ?? '',
      delta: (d['delta'] as num?)?.toInt() ?? 0,
      note: (d['note'] as String?) ?? '',
      status: _statusFrom(d['status'] as String?),
      requestedBy: (d['requestedBy'] as String?) ?? '',
      requestedByName: (d['requestedByName'] as String?) ?? '',
      createdAt: ts(d['createdAt']),
      decidedByName: (d['decidedByName'] as String?) ?? '',
      decidedAt: ts(d['decidedAt']),
      decisionNote: (d['decisionNote'] as String?) ?? '',
      quantityBefore: (d['quantityBefore'] as num?)?.toInt(),
      quantityAfter: (d['quantityAfter'] as num?)?.toInt(),
    );
  }
}

class StockRequests {
  StockRequests._();

  static FirebaseFirestore get _fs => FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _col => _fs.collection('stockRequests');

  static List<StockRequest> _sorted(QuerySnapshot<Map<String, dynamic>> s) {
    final list = s.docs.map(StockRequest.fromDoc).toList();
    // Newest first; requests still being saved (no timestamp yet) go on top.
    list.sort((a, b) {
      final at = a.createdAt, bt = b.createdAt;
      if (at == null && bt == null) return 0;
      if (at == null) return -1;
      if (bt == null) return 1;
      return bt.compareTo(at);
    });
    return list;
  }

  /// All pending requests (admin approvals list), optionally for one store.
  static Stream<List<StockRequest>> watchPending({String? storeId}) {
    Query<Map<String, dynamic>> q = _col.where('status', isEqualTo: 'pending');
    if (storeId != null) q = q.where('storeId', isEqualTo: storeId);
    return q.snapshots().map(_sorted);
  }

  /// Recent requests of any status (admin history).
  static Stream<List<StockRequest>> watchRecent({int limit = 200}) =>
      _col.orderBy('createdAt', descending: true).limit(limit).snapshots().map(_sorted);

  /// Requests made by one person (staff "My requests").
  static Stream<List<StockRequest>> watchMine(String uid) =>
      _col.where('requestedBy', isEqualTo: uid).snapshots().map(_sorted);

  /// Staff: ask for stock to be added (delta > 0) or removed (delta < 0).
  static Future<void> create({
    required Product product,
    required String storeName,
    required int delta,
    required String note,
  }) {
    final me = currentUser.value;
    if (me == null) throw StateError('Not signed in');
    return _col.add({
      'productId': product.id,
      'productName': product.name,
      'storeId': product.storeId,
      'storeName': storeName,
      'companyId': product.companyId,
      'delta': delta,
      'note': note.trim(),
      'status': 'pending',
      'requestedBy': me.uid,
      'requestedByName': me.displayName.isEmpty ? me.username : me.displayName,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Staff: withdraw your own pending request.
  static Future<void> cancel(StockRequest r) => _col.doc(r.id).update({
        'status': 'cancelled',
        'decidedAt': FieldValue.serverTimestamp(),
      });

  /// Admin: apply the change to the product's stock and mark the request approved.
  /// Stock never goes below zero.
  static Future<void> approve(StockRequest r) async {
    final me = currentUser.value!;
    final reqRef = _col.doc(r.id);
    final productRef = _fs.collection('products').doc(r.productId);
    final place = await Audit.names(r.storeId, r.companyId);
    final meName = me.displayName.isEmpty ? me.username : me.displayName;
    await _fs.runTransaction((tx) async {
      final reqSnap = await tx.get(reqRef);
      if (reqSnap.data()?['status'] != 'pending') {
        throw StateError('This request has already been handled.');
      }
      final productSnap = await tx.get(productRef);
      if (!productSnap.exists) {
        throw StateError('The product no longer exists. Reject this request instead.');
      }
      final before = (productSnap.data()?['quantity'] as num?)?.toInt() ?? 0;
      final after = before + r.delta < 0 ? 0 : before + r.delta;
      tx.update(productRef, {'quantity': after, 'updatedAt': FieldValue.serverTimestamp()});
      tx.set(
        Audit.col.doc(),
        Audit.entry(
          type: AuditType.request,
          productId: r.productId,
          productName: (productSnap.data()?['name'] as String?) ?? r.productName,
          sku: (productSnap.data()?['sku'] as String?) ?? '',
          storeId: r.storeId,
          companyId: r.companyId,
          place: place,
          before: before,
          after: after,
          note: r.note,
          userId: r.requestedBy,
          userName: r.requestedByName,
          approvedById: me.uid,
          approvedByName: meName,
        ),
      );
      tx.update(reqRef, {
        'status': 'approved',
        'decidedBy': me.uid,
        'decidedByName': meName,
        'decidedAt': FieldValue.serverTimestamp(),
        'quantityBefore': before,
        'quantityAfter': after,
      });
    });
  }

  /// Admin: turn the request down (stock is unchanged).
  static Future<void> reject(StockRequest r, {String reason = ''}) {
    final me = currentUser.value!;
    return _col.doc(r.id).update({
      'status': 'rejected',
      'decidedBy': me.uid,
      'decidedByName': me.displayName.isEmpty ? me.username : me.displayName,
      'decidedAt': FieldValue.serverTimestamp(),
      'decisionNote': reason.trim(),
    });
  }
}
