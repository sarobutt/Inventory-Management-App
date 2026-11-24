import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'audit.dart';
import 'auth.dart';

// ---------------- Barcodes ----------------
//
// The same product barcode can be written in different ways:
//   * leading zeros: a scanner may read 0123456789012 where a spreadsheet saved 123456789012
//     (UPC-A vs EAN-13, or Excel dropping the leading 0)
//   * spreadsheet number formats: "8801234567890.0" or "8.80123456789E+12"
// These helpers treat all of those as the same barcode.

/// Tidies a barcode as typed, scanned or imported (spaces removed, Excel number formats undone).
String cleanBarcode(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'\s+'), '');
  final decimal = RegExp(r'^(\d+)\.0+$').firstMatch(s);
  if (decimal != null) return decimal.group(1)!;
  final sci = RegExp(r'^(\d)(?:\.(\d+))?[eE]\+?(\d+)$').firstMatch(s);
  if (sci != null) {
    final digits = sci.group(1)! + (sci.group(2) ?? '');
    final exp = int.parse(sci.group(3)!);
    final decimals = (sci.group(2) ?? '').length;
    // Only when no digits were lost (e.g. 8.801234567890E+12); a rounded value stays as it is.
    if (exp == decimals) s = digits;
  }
  return s;
}

/// Comparison key: numeric barcodes without leading zeros, other codes lower-case.
String barcodeKey(String raw) {
  final s = cleanBarcode(raw).toLowerCase();
  if (RegExp(r'^\d+$').hasMatch(s)) {
    final t = s.replaceFirst(RegExp(r'^0+'), '');
    return t.isEmpty ? '0' : t;
  }
  return s;
}

/// True when two barcodes mean the same product.
bool sameBarcode(String a, String b) {
  final ka = barcodeKey(a);
  return ka.isNotEmpty && ka == barcodeKey(b);
}

/// The spellings a barcode may be stored under (for database lookups; at most 10).
List<String> barcodeVariants(String raw) {
  final clean = cleanBarcode(raw);
  if (clean.isEmpty) return const [];
  final out = <String>{raw.trim(), clean, clean.toUpperCase(), clean.toLowerCase()};
  final key = barcodeKey(clean);
  if (RegExp(r'^\d+$').hasMatch(key)) {
    out.add(key);
    for (final len in [8, 12, 13, 14]) {
      if (key.length < len) out.add(key.padLeft(len, '0'));
    }
  }
  out.removeWhere((s) => s.isEmpty);
  return out.take(10).toList();
}

/// Search box match: name or SKU contains the text, or the text is the same barcode.
bool productMatches(String name, String sku, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return name.toLowerCase().contains(q) || sku.toLowerCase().contains(q) || sameBarcode(sku, q);
}

// Data structure
//   companies/{id}      name, description
//   stores/{id}         companyId, name, address
//   products/{id}       companyId, storeId, name, sku, retailPrice, quantity, reorderLevel, description
//                       (everyone signed in can READ retailPrice; only admins can change it)
//   productPrices/{id}  cost, wholesale, companyId, storeId   (ADMIN ONLY; same id as the
//                       product, so staff can never read cost or wholesale prices)

// ---------------- Models ----------------

class Company {
  final String id;
  final String name;
  final String description;

  const Company({required this.id, required this.name, required this.description});

  factory Company.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return Company(
      id: doc.id,
      name: (d['name'] as String?) ?? '',
      description: (d['description'] as String?) ?? '',
    );
  }
}

class Store {
  final String id;
  final String companyId;
  final String name;
  final String address;

  const Store({required this.id, required this.companyId, required this.name, required this.address});

  factory Store.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return Store(
      id: doc.id,
      companyId: (d['companyId'] as String?) ?? '',
      name: (d['name'] as String?) ?? '',
      address: (d['address'] as String?) ?? '',
    );
  }
}

/// The three selling prices of a product.
/// Cost and Wholesale: admins only. Retail: visible to everyone. Only admins can change prices.
class Prices {
  final double? cost;
  final double? wholesale;
  final double? retail;

  const Prices({this.cost, this.wholesale, this.retail});

  static const none = Prices();

  bool get isEmpty => retail == null && wholesale == null && cost == null;

  /// Reads the admin-only price record (cost + wholesale).
  factory Prices.fromAdminDoc(Map<String, dynamic>? d) {
    if (d == null) return none;
    double? n(Object? v) => (v as num?)?.toDouble();
    return Prices(cost: n(d['cost']), wholesale: n(d['wholesale']));
  }

  /// Keeps this retail price and takes cost/wholesale from [admin].
  Prices withAdmin(Prices admin) => Prices(cost: admin.cost, wholesale: admin.wholesale, retail: retail);

  Prices get retailOnly => Prices(retail: retail);

  /// Keeps this price where [other] has none (used by imports and barcode fills).
  Prices mergedWith(Prices other) => Prices(
        retail: other.retail ?? retail,
        wholesale: other.wholesale ?? wholesale,
        cost: other.cost ?? cost,
      );
}

/// Stock at or below this level counts as "needs ordering" when a product has no own level.
const int defaultReorderLevel = 5;

class Product {
  final String id;
  final String companyId;
  final String storeId;
  final String name;
  final String sku;

  /// Retail for everyone; cost and wholesale are filled in for admins only.
  final Prices prices;
  final int quantity;

  /// Low-stock alert level for this product (null = use [defaultReorderLevel]).
  final int? reorderLevel;
  final String description;

  /// Batch / lot code printed on the product (letters and numbers), '' if none.
  final String batchCode;

  /// Expiry date of this stock (date only), null if none.
  final DateTime? expiryDate;

  const Product({
    required this.id,
    required this.companyId,
    required this.storeId,
    required this.name,
    required this.sku,
    this.prices = Prices.none,
    required this.quantity,
    this.reorderLevel,
    required this.description,
    this.batchCode = '',
    this.expiryDate,
  });

  /// Expired already (expiry date before today).
  bool get isExpired {
    final e = expiryDate;
    if (e == null) return false;
    final now = DateTime.now();
    return e.isBefore(DateTime(now.year, now.month, now.day));
  }

  int get effectiveReorderLevel => reorderLevel ?? defaultReorderLevel;

  /// No stock left.
  bool get isOutOfStock => quantity <= 0;

  /// Stock is at or below the reorder level (includes out of stock).
  bool get needsOrdering => quantity <= effectiveReorderLevel;

  /// Short status for tables: "Out of stock", "Needs ordering" or "".
  String get stockStatus => isOutOfStock ? 'Out of stock' : (needsOrdering ? 'Needs ordering' : '');

  /// Stock value at retail price = retail x quantity (0 when no retail price).
  double get value => (prices.retail ?? 0) * quantity;

  Product withPrices(Prices p) => Product(
        id: id,
        companyId: companyId,
        storeId: storeId,
        name: name,
        sku: sku,
        prices: p,
        quantity: quantity,
        reorderLevel: reorderLevel,
        description: description,
        batchCode: batchCode,
        expiryDate: expiryDate,
      );

  factory Product.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    // Older versions stored a single 'price'; it becomes the retail price.
    final retail = ((d['retailPrice'] ?? d['price']) as num?)?.toDouble();
    return Product(
      id: doc.id,
      companyId: (d['companyId'] as String?) ?? '',
      storeId: (d['storeId'] as String?) ?? '',
      name: (d['name'] as String?) ?? '',
      sku: (d['sku'] as String?) ?? '',
      prices: retail == null ? Prices.none : Prices(retail: retail),
      quantity: (d['quantity'] as num?)?.toInt() ?? 0,
      reorderLevel: (d['reorderLevel'] as num?)?.toInt(),
      description: (d['description'] as String?) ?? '',
      batchCode: (d['batchCode'] as String?) ?? '',
      expiryDate: d['expiryDate'] is Timestamp ? (d['expiryDate'] as Timestamp).toDate().toLocal() : null,
    );
  }
}

/// Date as dd/mm/yyyy ('' for null).
String formatDate(DateTime? d) => d == null
    ? ''
    : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Batch codes: letters and numbers (a dash, slash or dot inside is allowed too).
final RegExp batchCodePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9\-/.]*$');

/// Firestore value for an expiry date (date only, midday UTC so time zones never shift the day).
Object? expiryValue(DateTime? d) => d == null ? null : Timestamp.fromDate(DateTime.utc(d.year, d.month, d.day, 12));

/// Outcome of [Db.moveProducts].
class MoveResult {
  final int moved;
  final int merged;
  final int skipped;
  const MoveResult({required this.moved, required this.merged, required this.skipped});

  String get summary => [
        if (moved > 0) '$moved moved',
        if (merged > 0) '$merged merged into existing products',
        if (skipped > 0) '$skipped skipped',
      ].join(', ');
}

/// Combines the latest values of two streams (like rxdart's combineLatest2).
Stream<R> combineLatest2<A, B, R>(Stream<A> a, Stream<B> b, R Function(A a, B b) combine) {
  late final StreamController<R> controller;
  StreamSubscription<A>? subA;
  StreamSubscription<B>? subB;
  A? lastA;
  B? lastB;
  var hasA = false, hasB = false;

  void emit() {
    if (hasA && hasB) controller.add(combine(lastA as A, lastB as B));
  }

  controller = StreamController<R>(
    onListen: () {
      subA = a.listen((v) {
        lastA = v;
        hasA = true;
        emit();
      }, onError: controller.addError);
      subB = b.listen((v) {
        lastB = v;
        hasB = true;
        emit();
      }, onError: controller.addError);
    },
    onCancel: () async {
      await subA?.cancel();
      await subB?.cancel();
    },
  );
  return controller.stream;
}

int _byName(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

// ---------------- Firestore CRUD ----------------

class Db {
  Db._();

  static final FirebaseFirestore _fs = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _companies => _fs.collection('companies');
  static CollectionReference<Map<String, dynamic>> get _stores => _fs.collection('stores');
  static CollectionReference<Map<String, dynamic>> get _products => _fs.collection('products');
  static CollectionReference<Map<String, dynamic>> get _prices => _fs.collection('productPrices');

  static bool get _isAdmin => currentUser.value?.isAdmin ?? false;

  /// Pulls the latest data from the server (used by pull-to-refresh).
  /// Throws if the device is offline.
  static Future<void> refresh() async {
    const server = GetOptions(source: Source.server);
    await Future.wait([
      _companies.get(server),
      _stores.get(server),
      _products.get(server),
      if (_isAdmin) _prices.get(server),
    ]);
  }

  /// Deletes many documents safely (Firestore batches are limited to 500 writes).
  static Future<void> _deleteAll(List<DocumentReference<Map<String, dynamic>>> refs) async {
    for (var i = 0; i < refs.length; i += 450) {
      final batch = _fs.batch();
      for (final r in refs.skip(i).take(450)) {
        batch.delete(r);
      }
      await batch.commit();
    }
  }

  // ----- Companies -----

  static Stream<List<Company>> watchCompanies() => _companies.snapshots().map((s) {
        final list = s.docs.map(Company.fromDoc).toList();
        list.sort((a, b) => _byName(a.name, b.name));
        return list;
      });

  static Stream<Company?> watchCompany(String id) =>
      _companies.doc(id).snapshots().map((d) => d.exists ? Company.fromDoc(d) : null);

  static Future<void> createCompany({required String name, required String description}) =>
      _companies.add({
        'name': name,
        'description': description,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  static Future<void> updateCompany(String id, {required String name, required String description}) =>
      _companies.doc(id).update({
        'name': name,
        'description': description,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// Records a 'delete' audit entry for each product that still had stock.
  static Future<void> _auditDeletedProducts(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, String note) async {
    final entries = <Map<String, dynamic>>[];
    for (final d in docs) {
      final p = Product.fromDoc(d);
      if (p.quantity == 0) continue;
      final place = await Audit.names(p.storeId, p.companyId);
      entries.add(Audit.entry(
        type: AuditType.delete,
        productId: p.id,
        productName: p.name,
        sku: p.sku,
        storeId: p.storeId,
        companyId: p.companyId,
        place: place,
        before: p.quantity,
        after: 0,
        note: note,
      ));
    }
    for (var i = 0; i < entries.length; i += 450) {
      final batch = _fs.batch();
      for (final e in entries.skip(i).take(450)) {
        batch.set(Audit.col.doc(), e);
      }
      await batch.commit();
    }
  }

  /// Deletes the company together with all of its stores, products and prices.
  static Future<void> deleteCompany(String id) async {
    final products = await _products.where('companyId', isEqualTo: id).get();
    final stores = await _stores.where('companyId', isEqualTo: id).get();
    await _auditDeletedProducts(products.docs, 'Company deleted');
    await _deleteAll([
      ...products.docs.map((d) => _prices.doc(d.id)),
      ...products.docs.map((d) => d.reference),
      ...stores.docs.map((d) => d.reference),
      _companies.doc(id),
    ]);
  }

  // ----- Stores -----

  /// Live list of stores, optionally only for one company.
  static Stream<List<Store>> watchStores({String? companyId}) {
    Query<Map<String, dynamic>> q = _stores;
    if (companyId != null) q = q.where('companyId', isEqualTo: companyId);
    return q.snapshots().map((s) {
      final list = s.docs.map(Store.fromDoc).toList();
      list.sort((a, b) => _byName(a.name, b.name));
      return list;
    });
  }

  static Stream<Store?> watchStore(String id) =>
      _stores.doc(id).snapshots().map((d) => d.exists ? Store.fromDoc(d) : null);

  static Future<void> createStore(String companyId, {required String name, required String address}) =>
      _stores.add({
        'companyId': companyId,
        'name': name,
        'address': address,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  static Future<void> updateStore(String id, {required String name, required String address}) =>
      _stores.doc(id).update({
        'name': name,
        'address': address,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// Deletes the store together with all of its products and their prices.
  static Future<void> deleteStore(String id) async {
    final products = await _products.where('storeId', isEqualTo: id).get();
    await _auditDeletedProducts(products.docs, 'Store deleted');
    await _deleteAll([
      ...products.docs.map((d) => _prices.doc(d.id)),
      ...products.docs.map((d) => d.reference),
      _stores.doc(id),
    ]);
  }

  // ----- Products -----

  /// Live list of products, optionally only for one company or one store.
  /// For admins each product also carries its three prices.
  static Stream<List<Product>> watchProducts({String? companyId, String? storeId}) {
    Query<Map<String, dynamic>> q = _products;
    Query<Map<String, dynamic>> pq = _prices;
    if (storeId != null) {
      q = q.where('storeId', isEqualTo: storeId);
      pq = pq.where('storeId', isEqualTo: storeId);
    } else if (companyId != null) {
      q = q.where('companyId', isEqualTo: companyId);
      pq = pq.where('companyId', isEqualTo: companyId);
    }
    final products = q.snapshots().map((s) {
      final list = s.docs.map(Product.fromDoc).toList();
      list.sort((a, b) => _byName(a.name, b.name));
      return list;
    });
    if (!_isAdmin) {
      // Staff: retail price only.
      return products.map((list) => [for (final p in list) p.withPrices(p.prices.retailOnly)]);
    }
    final adminPrices = pq.snapshots().map((s) => {for (final d in s.docs) d.id: Prices.fromAdminDoc(d.data())});
    return combineLatest2<List<Product>, Map<String, Prices>, List<Product>>(
      products,
      adminPrices,
      (list, priceMap) => [for (final p in list) p.withPrices(p.prices.withAdmin(priceMap[p.id] ?? Prices.none))],
    );
  }

  /// Admin: the cost and wholesale prices of one product.
  static Future<Prices> getAdminPrices(String productId) async =>
      Prices.fromAdminDoc((await _prices.doc(productId).get()).data());

  static Map<String, dynamic> _priceDoc(Prices prices, String companyId, String storeId) => {
        'wholesale': prices.wholesale,
        'cost': prices.cost,
        'companyId': companyId,
        'storeId': storeId,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  static Future<void> createProduct({
    required String companyId,
    required String storeId,
    required String name,
    required String sku,
    required Prices prices,
    required int quantity,
    required int? reorderLevel,
    required String description,
    String batchCode = '',
    DateTime? expiryDate,
  }) async {
    final ref = _products.doc();
    final place = await Audit.names(storeId, companyId);
    final batch = _fs.batch();
    batch.set(ref, {
      'companyId': companyId,
      'storeId': storeId,
      'name': name,
      'sku': sku,
      'retailPrice': prices.retail,
      'quantity': quantity,
      'reorderLevel': reorderLevel,
      'description': description,
      'batchCode': batchCode.trim(),
      'expiryDate': expiryValue(expiryDate),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.set(_prices.doc(ref.id), _priceDoc(prices, companyId, storeId));
    batch.set(
      Audit.col.doc(),
      Audit.entry(
        type: AuditType.create,
        productId: ref.id,
        productName: name,
        sku: sku,
        storeId: storeId,
        companyId: companyId,
        place: place,
        before: 0,
        after: quantity,
      ),
    );
    return batch.commit();
  }

  static Future<void> updateProduct(
    String id, {
    required String companyId,
    required String storeId,
    required String name,
    required String sku,
    required Prices prices,
    required int quantity,
    required int previousQuantity,
    required int? reorderLevel,
    required String description,
    String batchCode = '',
    DateTime? expiryDate,
  }) async {
    final place = quantity != previousQuantity ? await Audit.names(storeId, companyId) : null;
    final batch = _fs.batch();
    batch.update(_products.doc(id), {
      'name': name,
      'sku': sku,
      'retailPrice': prices.retail,
      'price': FieldValue.delete(), // old single-price field, replaced by retailPrice
      'quantity': quantity,
      'reorderLevel': reorderLevel,
      'description': description,
      'batchCode': batchCode.trim(),
      'expiryDate': expiryValue(expiryDate),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.set(_prices.doc(id), _priceDoc(prices, companyId, storeId));
    if (place != null) {
      batch.set(
        Audit.col.doc(),
        Audit.entry(
          type: AuditType.edit,
          productId: id,
          productName: name,
          sku: sku,
          storeId: storeId,
          companyId: companyId,
          place: place,
          before: previousQuantity,
          after: quantity,
          note: 'Quantity changed in the product form',
        ),
      );
    }
    return batch.commit();
  }

  /// Admin, once per app start: renames the old single 'price' field to 'retailPrice'.
  static Future<int> migrateLegacyPrices() async {
    if (!_isAdmin) return 0;
    final snap = await _products.where('price', isGreaterThanOrEqualTo: 0).get();
    final docs = snap.docs.where((d) => d.data()['price'] is num).toList();
    for (var i = 0; i < docs.length; i += 400) {
      final batch = _fs.batch();
      for (final d in docs.skip(i).take(400)) {
        final data = d.data();
        batch.update(d.reference, {
          if (data['retailPrice'] == null) 'retailPrice': (data['price'] as num).toDouble(),
          'price': FieldValue.delete(),
        });
      }
      await batch.commit();
    }
    return docs.length;
  }

  /// Stock counting: add or subtract units. Never goes below zero.
  static Future<void> adjustQuantity(Product product, int delta) async {
    final ref = _products.doc(product.id);
    final place = await Audit.names(product.storeId, product.companyId);
    await _fs.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final current = (snap.data()?['quantity'] as num?)?.toInt() ?? 0;
      final next = current + delta < 0 ? 0 : current + delta;
      if (next == current) return;
      tx.update(ref, {'quantity': next, 'updatedAt': FieldValue.serverTimestamp()});
      tx.set(
        Audit.col.doc(),
        Audit.entry(
          type: AuditType.adjust,
          productId: product.id,
          productName: (snap.data()?['name'] as String?) ?? product.name,
          sku: (snap.data()?['sku'] as String?) ?? product.sku,
          storeId: product.storeId,
          companyId: product.companyId,
          place: place,
          before: current,
          after: next,
        ),
      );
    });
  }

  static Future<void> deleteProduct(Product product) async {
    final place = await Audit.names(product.storeId, product.companyId);
    final batch = _fs.batch();
    batch.delete(_prices.doc(product.id));
    batch.delete(_products.doc(product.id));
    batch.set(
      Audit.col.doc(),
      Audit.entry(
        type: AuditType.delete,
        productId: product.id,
        productName: product.name,
        sku: product.sku,
        storeId: product.storeId,
        companyId: product.companyId,
        place: place,
        before: product.quantity,
        after: 0,
      ),
    );
    return batch.commit();
  }

  /// Moves products to [target] (and its company). Prices, reorder level and pending
  /// staff requests move too, and the stock movement is recorded in the audit.
  ///
  /// [quantities] (product id → units) moves only part of a product's stock. The rest
  /// stays in the current store with its pending requests; the moved units join the same
  /// barcode in [target], or become a copy of the product there (same prices and details).
  /// Products not in the map, or with an amount at or above their stock, move completely.
  ///
  /// If the target store already has a product with the same SKU:
  ///  - [mergeDuplicates] true  → the stock is added to that product (and a full move removes this one);
  ///  - [mergeDuplicates] false → the product is skipped.
  static Future<MoveResult> moveProducts(
    List<Product> products,
    Store target, {
    required bool mergeDuplicates,
    Map<String, int>? quantities,
  }) async {
    var moved = 0, merged = 0, skipped = 0;
    final to = await Audit.names(target.id, target.companyId);

    for (final p in products) {
      final wanted = quantities?[p.id];
      if (p.storeId == target.id || (wanted != null && wanted <= 0)) {
        skipped++;
        continue;
      }
      final from = await Audit.names(p.storeId, p.companyId);
      final note = 'Moved from ${from.storeName} (${from.companyName}) to ${to.storeName} (${to.companyName})';
      final duplicate = await findInStoreBySku(target.id, p.sku);
      final pendingReqs = await _fs
          .collection('stockRequests')
          .where('productId', isEqualTo: p.id)
          .where('status', isEqualTo: 'pending')
          .get();

      if (duplicate != null && !mergeDuplicates) {
        skipped++;
        continue;
      }

      final done = await _fs.runTransaction<bool>((tx) async {
        // All reads first (Firestore transactions need reads before writes).
        final srcRef = _products.doc(p.id);
        final srcSnap = await tx.get(srcRef);
        if (!srcSnap.exists) return false;
        final src = srcSnap.data()!;
        final qty = (src['quantity'] as num?)?.toInt() ?? 0;
        final dstRef = duplicate == null ? null : _products.doc(duplicate.id);
        final dstSnap = dstRef == null ? null : await tx.get(dstRef);
        if (dstSnap != null && !dstSnap.exists) return false;
        final dstBefore = (dstSnap?.data()?['quantity'] as num?)?.toInt() ?? 0;

        // Part of the stock (checked against the live count, not the one on screen).
        final amount = wanted != null && wanted < qty ? wanted : qty;
        final partial = amount < qty;
        final priceSnap = partial && dstRef == null ? await tx.get(_prices.doc(p.id)) : null;

        if (partial) {
          // ---- move some units; the product and its requests stay here ----
          final left = qty - amount;
          final partNote = '$note ($amount of $qty units)';
          tx.update(srcRef, {'quantity': left, 'updatedAt': FieldValue.serverTimestamp()});
          tx.set(Audit.col.doc(), Audit.entry(
            type: AuditType.move, productId: p.id, productName: p.name, sku: p.sku,
            storeId: p.storeId, companyId: p.companyId, place: from,
            before: qty, after: left, note: partNote,
          ));
          if (dstRef != null) {
            tx.update(dstRef, {'quantity': dstBefore + amount, 'updatedAt': FieldValue.serverTimestamp()});
            tx.set(Audit.col.doc(), Audit.entry(
              type: AuditType.move, productId: duplicate!.id, productName: duplicate.name, sku: duplicate.sku,
              storeId: target.id, companyId: target.companyId, place: to,
              before: dstBefore, after: dstBefore + amount, note: '$partNote (merged)',
            ));
          } else {
            // Same product in the new store: copy its details and admin prices.
            final newRef = _products.doc();
            tx.set(newRef, {
              ...src,
              'storeId': target.id,
              'companyId': target.companyId,
              'quantity': amount,
              'createdAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            });
            tx.set(_prices.doc(newRef.id), {
              ...?priceSnap?.data(),
              'storeId': target.id,
              'companyId': target.companyId,
              'updatedAt': FieldValue.serverTimestamp(),
            });
            tx.set(Audit.col.doc(), Audit.entry(
              type: AuditType.move, productId: newRef.id, productName: p.name, sku: p.sku,
              storeId: target.id, companyId: target.companyId, place: to,
              before: 0, after: amount, note: partNote,
            ));
          }
        } else if (dstRef != null) {
          // ---- merge into the existing product in the target store ----
          tx.update(dstRef, {'quantity': dstBefore + qty, 'updatedAt': FieldValue.serverTimestamp()});
          tx.delete(_prices.doc(p.id));
          tx.delete(srcRef);
          for (final r in pendingReqs.docs) {
            tx.update(r.reference, {
              'productId': duplicate!.id,
              'productName': duplicate.name,
              'storeId': target.id,
              'storeName': to.storeName,
              'companyId': target.companyId,
            });
          }
          if (qty != 0) {
            tx.set(Audit.col.doc(), Audit.entry(
              type: AuditType.move, productId: p.id, productName: p.name, sku: p.sku,
              storeId: p.storeId, companyId: p.companyId, place: from,
              before: qty, after: 0, note: '$note (merged into existing product)',
            ));
            tx.set(Audit.col.doc(), Audit.entry(
              type: AuditType.move, productId: duplicate!.id, productName: duplicate.name, sku: duplicate.sku,
              storeId: target.id, companyId: target.companyId, place: to,
              before: dstBefore, after: dstBefore + qty, note: '$note (merged)',
            ));
          }
        } else {
          // ---- plain move of the whole product ----
          tx.update(srcRef, {
            'storeId': target.id,
            'companyId': target.companyId,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          tx.set(_prices.doc(p.id), {'storeId': target.id, 'companyId': target.companyId}, SetOptions(merge: true));
          for (final r in pendingReqs.docs) {
            tx.update(r.reference, {
              'storeId': target.id,
              'storeName': to.storeName,
              'companyId': target.companyId,
            });
          }
          if (qty != 0) {
            tx.set(Audit.col.doc(), Audit.entry(
              type: AuditType.move, productId: p.id, productName: p.name, sku: p.sku,
              storeId: p.storeId, companyId: p.companyId, place: from,
              before: qty, after: 0, note: note,
            ));
            tx.set(Audit.col.doc(), Audit.entry(
              type: AuditType.move, productId: p.id, productName: p.name, sku: p.sku,
              storeId: target.id, companyId: target.companyId, place: to,
              before: 0, after: qty, note: note,
            ));
          }
        }
        return true;
      });
      if (!done) {
        skipped++;
      } else if (duplicate != null) {
        merged++;
      } else {
        moved++;
      }
    }
    return MoveResult(moved: moved, merged: merged, skipped: skipped);
  }

  /// The product in [storeId] with this exact SKU/barcode, if any (used to prevent duplicates).
  static Future<Product?> findInStoreBySku(String storeId, String sku) async {
    final variants = barcodeVariants(sku);
    if (variants.isEmpty) return null;
    final snap = await _products.where('storeId', isEqualTo: storeId).where('sku', whereIn: variants).limit(1).get();
    return snap.docs.isEmpty ? null : Product.fromDoc(snap.docs.first);
  }

  /// Attaches a scanned barcode to an existing product (e.g. one imported without barcodes).
  static Future<void> setSku(String productId, String sku) =>
      _products.doc(productId).update({'sku': cleanBarcode(sku), 'updatedAt': FieldValue.serverTimestamp()});

  /// Products (in any store) with this SKU/barcode (leading zeros and spreadsheet formats ignored).
  static Future<List<Product>> findBySku(String sku) async {
    final variants = barcodeVariants(sku);
    if (variants.isEmpty) return const [];
    final snap = await _products.where('sku', whereIn: variants).limit(20).get();
    return snap.docs.map(Product.fromDoc).toList();
  }
}
