import 'package:cloud_firestore/cloud_firestore.dart';

// ---------------- Models ----------------

class Company {
  final String id;
  final String name;
  final String description;

  const Company({required this.id, required this.name, required this.description});

  factory Company.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Company(
      id: doc.id,
      name: (d['name'] as String?) ?? '',
      description: (d['description'] as String?) ?? '',
    );
  }
}

class Product {
  final String id;
  final String companyId;
  final String name;
  final double? price;
  final String description;

  const Product({
    required this.id,
    required this.companyId,
    required this.name,
    required this.price,
    required this.description,
  });

  factory Product.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Product(
      id: doc.id,
      companyId: (d['companyId'] as String?) ?? '',
      name: (d['name'] as String?) ?? '',
      price: (d['price'] as num?)?.toDouble(),
      description: (d['description'] as String?) ?? '',
    );
  }
}

// ---------------- Firestore CRUD ----------------

class Db {
  Db._();

  static final _fs = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _companies => _fs.collection('companies');
  static CollectionReference<Map<String, dynamic>> get _products => _fs.collection('products');

  // ----- Companies -----

  /// Live list of companies, sorted by name.
  static Stream<List<Company>> watchCompanies() => _companies
      .orderBy('name')
      .snapshots()
      .map((s) => s.docs.map(Company.fromDoc).toList());

  /// Live single company; null if it has been deleted.
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

  /// Deletes a company and all of its products in one batch.
  static Future<void> deleteCompany(String id) async {
    final products = await _products.where('companyId', isEqualTo: id).get();
    final batch = _fs.batch();
    for (final p in products.docs) {
      batch.delete(p.reference);
    }
    batch.delete(_companies.doc(id));
    await batch.commit();
  }

  // ----- Products -----

  /// Live list of products (optionally for one company), sorted by name.
  static Stream<List<Product>> watchProducts({String? companyId}) {
    Query<Map<String, dynamic>> q = _products;
    if (companyId != null) q = q.where('companyId', isEqualTo: companyId);
    return q.snapshots().map((s) {
      final list = s.docs.map(Product.fromDoc).toList();
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    });
  }

  static Future<void> createProduct(
    String companyId, {
    required String name,
    required double? price,
    required String description,
  }) =>
      _products.add({
        'companyId': companyId,
        'name': name,
        'price': price,
        'description': description,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  static Future<void> updateProduct(
    String id, {
    required String name,
    required double? price,
    required String description,
  }) =>
      _products.doc(id).update({
        'name': name,
        'price': price,
        'description': description,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  static Future<void> deleteProduct(String id) => _products.doc(id).delete();
}
