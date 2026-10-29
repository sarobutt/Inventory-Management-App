import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'audit.dart';
import 'auth.dart';

// Data structure
//   companies/{id}      name, description
//   stores/{id}         companyId, name, address
//   products/{id}       companyId, storeId, name, sku, retailPrice, quantity, reorderLevel, description
//                       (everyone signed in can READ retailPrice; only admins can change it)
//   productPrices/{id}  wholesale, perItem, companyId, storeId   (ADMIN ONLY; same id as the
//                       product, so staff can never read wholesale or per-item prices)

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
/// Retail: visible to everyone. Wholesale and per item: admins only. Only admins can change prices.
class Prices {
  final double? retail;
  final double? wholesale;
  final double? perItem;

  const Prices({this.retail, this.wholesale, this.perItem});

  static const none = Prices();

  bool get isEmpty => retail == null && wholesale == null && perItem == null;

  /// Reads the admin-only price record (wholesale + per item).
  factory Prices.fromAdminDoc(Map<String, dynamic>? d) {
    if (d == null) return none;
    double? n(Object? v) => (v as num?)?.toDouble();
    return Prices(wholesale: n(d['wholesale']), perItem: n(d['perItem']));
  }

  /// Keeps this retail price and takes wholesale/per item from [admin].
  Prices withAdmin(Prices admin) => Prices(retail: retail, wholesale: admin.wholesale, perItem: admin.perItem);

  Prices get retailOnly => Prices(retail: retail);

  /// Keeps this price where [other] has none (used by imports and barcode fills).
  Prices mergedWith(Prices other) => Prices(
        retail: other.retail ?? retail,
        wholesale: other.wholesale ?? wholesale,
        perItem: other.perItem ?? perItem,
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

  /// Retail for everyone; wholesale and per item are filled in for admins only.
  final Prices prices;
  final int quantity;

  /// Low-stock alert level for this product (null = use [defaultReorderLevel]).
  final int? reorderLevel;
  final String description;

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
  });

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
    );
  }
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

  /// Admin: the wholesale and per-item prices of one product.
  static Future<Prices> getAdminPrices(String productId) async =>
      Prices.fromAdminDoc((await _prices.doc(productId).get()).data());

  static Map<String, dynamic> _priceDoc(Prices prices, String companyId, String storeId) => {
        'wholesale': prices.wholesale,
        'perItem': prices.perItem,
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

  /// The product in [storeId] with this exact SKU/barcode, if any (used to prevent duplicates).
  static Future<Product?> findInStoreBySku(String storeId, String sku) async {
    final clean = sku.trim();
    if (clean.isEmpty) return null;
    final snap = await _products.where('storeId', isEqualTo: storeId).where('sku', isEqualTo: clean).limit(1).get();
    return snap.docs.isEmpty ? null : Product.fromDoc(snap.docs.first);
  }

  /// Products (in any store) whose SKU/barcode exactly matches [sku].
  static Future<List<Product>> findBySku(String sku) async {
    final snap = await _products.where('sku', isEqualTo: sku).limit(20).get();
    return snap.docs.map(Product.fromDoc).toList();
  }
}
