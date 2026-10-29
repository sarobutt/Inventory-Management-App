import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'data.dart';

/// What we found for a scanned barcode.
class BarcodeInfo {
  final String code;
  final String? name;
  final Prices? prices; // only known from your own products (cost/wholesale for admins only)
  final String? description;
  final String source; // shown to the user, e.g. "Open Beauty Facts"

  /// Set when the barcode already exists as a product in your database.
  final Product? existing;

  const BarcodeInfo({
    required this.code,
    this.name,
    this.prices,
    this.description,
    required this.source,
    this.existing,
  });

  bool get found => name != null && name!.isNotEmpty;
}

/// Looks up a barcode, cheapest and most reliable first:
///   1. your own products (any store)   — unlimited, includes prices (admins)
///   2. Open Beauty Facts               — free, unlimited, cosmetics & personal care
///   3. UPCitemdb (trial)                — free ~100 lookups/day, general retail
/// Returns a result with name == null if nobody knows the barcode.
Future<BarcodeInfo> lookupBarcode(String code, {String? preferStoreId}) async {
  final clean = code.trim();

  // 1. Your own database.
  try {
    final matches = await Db.findBySku(clean);
    if (matches.isNotEmpty) {
      // Prefer a match from the current store, otherwise any store.
      final inStore = matches.where((p) => p.storeId == preferStoreId);
      final p = inStore.isNotEmpty ? inStore.first : matches.first;
      var prices = p.prices.retailOnly;
      if (currentUser.value?.isAdmin ?? false) {
        try {
          prices = prices.withAdmin(await Db.getAdminPrices(p.id));
        } catch (_) {}
      }
      return BarcodeInfo(
        code: clean,
        name: p.name,
        prices: prices,
        description: p.description.isEmpty ? null : p.description,
        source: 'your products',
        existing: p,
      );
    }
  } catch (_) {
    // Offline or permission problem: fall through to the public databases.
  }

  // Public databases only understand numeric product barcodes (EAN/UPC).
  if (!RegExp(r'^\d{8,14}$').hasMatch(clean)) {
    return BarcodeInfo(code: clean, source: 'none');
  }

  // 2. Open Beauty Facts.
  final obf = await _openFacts('https://world.openbeautyfacts.org', clean);
  if (obf != null) return BarcodeInfo(code: clean, name: obf, source: 'Open Beauty Facts');

  // 3. UPCitemdb (free trial endpoint).
  final upc = await _upcItemDb(clean);
  if (upc != null) return BarcodeInfo(code: clean, name: upc, source: 'UPCitemdb');

  return BarcodeInfo(code: clean, source: 'none');
}

const _headers = {'User-Agent': 'InventoryManagementApp/1.0 (Flutter)', 'Accept': 'application/json'};
const _timeout = Duration(seconds: 7);

/// Open Beauty Facts / Open Food Facts share the same API.
Future<String?> _openFacts(String base, String code) async {
  try {
    final uri = Uri.parse('$base/api/v2/product/$code.json?fields=product_name,brands,quantity');
    final res = await http.get(uri, headers: _headers).timeout(_timeout);
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (json['status'] != 1) return null;
    final p = (json['product'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final name = (p['product_name'] as String?)?.trim() ?? '';
    if (name.isEmpty) return null;
    final brand = ((p['brands'] as String?) ?? '').split(',').first.trim();
    final qty = ((p['quantity'] as String?) ?? '').trim();
    return _compose(brand, name, qty);
  } catch (_) {
    return null;
  }
}

Future<String?> _upcItemDb(String code) async {
  try {
    final uri = Uri.parse('https://api.upcitemdb.com/prod/trial/lookup?upc=$code');
    final res = await http.get(uri, headers: _headers).timeout(_timeout);
    if (res.statusCode != 200) return null; // 429 = daily limit reached
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final items = (json['items'] as List?) ?? const [];
    if (items.isEmpty) return null;
    final item = (items.first as Map).cast<String, dynamic>();
    final title = ((item['title'] as String?) ?? '').trim();
    if (title.isEmpty) return null;
    final brand = ((item['brand'] as String?) ?? '').trim();
    return _compose(brand, title, '');
  } catch (_) {
    return null;
  }
}

/// "Brand Product Name 50ml" without repeating the brand if it's already in the name.
String _compose(String brand, String name, String qty) {
  final parts = <String>[];
  if (brand.isNotEmpty && !name.toLowerCase().contains(brand.toLowerCase())) parts.add(brand);
  parts.add(name);
  if (qty.isNotEmpty && !name.toLowerCase().contains(qty.toLowerCase())) parts.add(qty);
  final s = parts.join(' ');
  return s.length > 200 ? s.substring(0, 200) : s;
}
