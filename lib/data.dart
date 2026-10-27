import 'package:cloud_firestore/cloud_firestore.dart';

// Data structure
//   companies/{id}  name, description
//   stores/{id}     companyId, name, address
//   products/{id}   companyId, storeId, name, sku, price, quantity, description

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

class Product {
  final String id;
  final String companyId;
  final String storeId;
  final String name;
  final String sku;
  final double? price;
  final int quantity;
  final String description;

  const Product({
    required this.id,
    required this.companyId,
    required this.storeId,
    required this.name,
    required this.sku,
    required this.price,
    required this.quantity,
    required this.description,
  });

  /// Stock value = price x quantity (0 when no price).
  double get value => (price ?? 0) * quantity;

  factory Product.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return Product(
      id: doc.id,
      companyId: (d['companyId'] as String?) ?? '',
      storeId: (d['storeId'] as String?) ?? '',
      name: (d['name'] as String?) ?? '',
      sku: (d['sku'] as String?) ?? '',
      price: (d['price'] as num?)?.toDouble(),
      quantity: (d['quantity'] as num?)?.toInt() ?? 0,
      description: (d['description'] as String?) ?? '',
    );
  }
}

int _byName(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

// ---------------- Firestore CRUD ----------------

class Db {
  Db._();

  static final FirebaseFirestore _fs = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _companies => _fs.collection('companies');
  static CollectionReference<Map<String, dynamic>> get _stores => _fs.collection('stores');
  static CollectionReference<Map<String, dynamic>> get _products => _fs.collection('products');

  /// Pulls the latest data from the server (used by pull-to-refresh).
  /// Throws if the device is offline.
  static Future<void> refresh() async {
    const server = GetOptions(source: Source.server);
    await Future.wait([_companies.get(server), _stores.get(server), _products.get(server)]);
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

  /// Deletes the company together with all of its stores and products.
  static Future<void> deleteCompany(String id) async {
    final products = await _products.where('companyId', isEqualTo: id).get();
    final stores = await _stores.where('companyId', isEqualTo: id).get();
    await _deleteAll([
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

  /// Deletes the store together with all of its products.
  static Future<void> deleteStore(String id) async {
    final products = await _products.where('storeId', isEqualTo: id).get();
    await _deleteAll([...products.docs.map((d) => d.reference), _stores.doc(id)]);
  }

  // ----- Products -----

  /// Live list of products, optionally only for one company or one store.
  static Stream<List<Product>> watchProducts({String? companyId, String? storeId}) {
    Query<Map<String, dynamic>> q = _products;
    if (storeId != null) {
      q = q.where('storeId', isEqualTo: storeId);
    } else if (companyId != null) {
      q = q.where('companyId', isEqualTo: companyId);
    }
    return q.snapshots().map((s) {
      final list = s.docs.map(Product.fromDoc).toList();
      list.sort((a, b) => _byName(a.name, b.name));
      return list;
    });
  }

  static Future<void> createProduct({
    required String companyId,
    required String storeId,
    required String name,
    required String sku,
    required double? price,
    required int quantity,
    required String description,
  }) =>
      _products.add({
        'companyId': companyId,
        'storeId': storeId,
        'name': name,
        'sku': sku,
        'price': price,
        'quantity': quantity,
        'description': description,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  static Future<void> updateProduct(
    String id, {
    required String name,
    required String sku,
    required double? price,
    required int quantity,
    required String description,
  }) =>
      _products.doc(id).update({
        'name': name,
        'sku': sku,
        'price': price,
        'quantity': quantity,
        'description': description,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// Stock counting: add or subtract units. Never goes below zero.
  static Future<void> adjustQuantity(String productId, int delta) {
    final ref = _products.doc(productId);
    return _fs.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final current = (snap.data()?['quantity'] as num?)?.toInt() ?? 0;
      final next = current + delta < 0 ? 0 : current + delta;
      tx.update(ref, {'quantity': next, 'updatedAt': FieldValue.serverTimestamp()});
    });
  }

  static Future<void> deleteProduct(String id) => _products.doc(id).delete();
}
