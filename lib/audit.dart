import 'package:cloud_firestore/cloud_firestore.dart';

import 'auth.dart';

// =====================================================================
//  Stock audit trail
//
//  auditLog/{id}  — one entry per stock change, never edited or deleted.
//    type            adjust | request | create | edit | import | delete | move
//    productId, productName, sku
//    storeId, storeName, companyId, companyName      (names as they were at the time)
//    delta           + added / − removed
//    quantityBefore, quantityAfter
//    userId, userName              who made (or requested) the change
//    approvedById, approvedByName  admin who approved a staff request
//    note
//    createdAt       server time
// =====================================================================

enum AuditType { adjust, request, create, edit, import, delete, move }

AuditType _typeFrom(String? s) =>
    AuditType.values.firstWhere((t) => t.name == s, orElse: () => AuditType.adjust);

String auditTypeLabel(AuditType t) => switch (t) {
      AuditType.adjust => 'Stock count',
      AuditType.request => 'Staff request',
      AuditType.create => 'New product',
      AuditType.edit => 'Product edited',
      AuditType.import => 'Excel import',
      AuditType.delete => 'Product deleted',
      AuditType.move => 'Moved between stores',
    };

class AuditEntry {
  final String id;
  final AuditType type;
  final String productId;
  final String productName;
  final String sku;
  final String storeId;
  final String storeName;
  final String companyId;
  final String companyName;
  final int delta;
  final int quantityBefore;
  final int quantityAfter;
  final String userId;
  final String userName;
  final String approvedById;
  final String approvedByName;
  final String note;
  final DateTime? createdAt;

  const AuditEntry({
    required this.id,
    required this.type,
    required this.productId,
    required this.productName,
    required this.sku,
    required this.storeId,
    required this.storeName,
    required this.companyId,
    required this.companyName,
    required this.delta,
    required this.quantityBefore,
    required this.quantityAfter,
    required this.userId,
    required this.userName,
    required this.approvedById,
    required this.approvedByName,
    required this.note,
    required this.createdAt,
  });

  bool get isAdded => delta > 0;
  String get deltaLabel => delta > 0 ? '+$delta' : '$delta';

  factory AuditEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    String str(String k) => (d[k] as String?) ?? '';
    int n(String k) => (d[k] as num?)?.toInt() ?? 0;
    final ts = d['createdAt'];
    return AuditEntry(
      id: doc.id,
      type: _typeFrom(d['type'] as String?),
      productId: str('productId'),
      productName: str('productName'),
      sku: str('sku'),
      storeId: str('storeId'),
      storeName: str('storeName'),
      companyId: str('companyId'),
      companyName: str('companyName'),
      delta: n('delta'),
      quantityBefore: n('quantityBefore'),
      quantityAfter: n('quantityAfter'),
      userId: str('userId'),
      userName: str('userName'),
      approvedById: str('approvedById'),
      approvedByName: str('approvedByName'),
      note: str('note'),
      createdAt: ts is Timestamp ? ts.toDate() : null,
    );
  }
}

/// Store and company names, looked up once and cached for the session.
class PlaceNames {
  final String storeName;
  final String companyName;
  const PlaceNames(this.storeName, this.companyName);
}

class Audit {
  Audit._();

  static FirebaseFirestore get _fs => FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get col => _fs.collection('auditLog');

  static final Map<String, String> _storeNames = {};
  static final Map<String, String> _companyNames = {};

  static Future<PlaceNames> names(String storeId, String companyId) async {
    try {
      if (!_storeNames.containsKey(storeId) && storeId.isNotEmpty) {
        final s = await _fs.collection('stores').doc(storeId).get();
        _storeNames[storeId] = (s.data()?['name'] as String?) ?? '';
      }
      if (!_companyNames.containsKey(companyId) && companyId.isNotEmpty) {
        final c = await _fs.collection('companies').doc(companyId).get();
        _companyNames[companyId] = (c.data()?['name'] as String?) ?? '';
      }
    } catch (_) {
      // Names are only for display; the ids are always stored.
    }
    return PlaceNames(_storeNames[storeId] ?? '', _companyNames[companyId] ?? '');
  }

  /// Builds one audit record. [userId]/[userName] default to the signed-in user.
  static Map<String, dynamic> entry({
    required AuditType type,
    required String productId,
    required String productName,
    required String sku,
    required String storeId,
    required String companyId,
    required PlaceNames place,
    required int before,
    required int after,
    String note = '',
    String? userId,
    String? userName,
    String? approvedById,
    String? approvedByName,
  }) {
    final me = currentUser.value;
    return {
      'type': type.name,
      'productId': productId,
      'productName': productName,
      'sku': sku,
      'storeId': storeId,
      'storeName': place.storeName,
      'companyId': companyId,
      'companyName': place.companyName,
      'delta': after - before,
      'quantityBefore': before,
      'quantityAfter': after,
      'userId': userId ?? me?.uid ?? '',
      'userName': userName ?? (me == null ? '' : (me.displayName.isEmpty ? me.username : me.displayName)),
      'approvedById': approvedById ?? '',
      'approvedByName': approvedByName ?? '',
      'note': note,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  /// Entries between [from] and [to] (inclusive), newest first.
  static Stream<List<AuditEntry>> watch({required DateTime from, required DateTime to, int limit = 5000}) {
    return col
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .where('createdAt', isLessThanOrEqualTo: Timestamp.fromDate(to))
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(AuditEntry.fromDoc).toList());
  }
}
