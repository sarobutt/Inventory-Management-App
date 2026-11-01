"""
Beauty Souq <-> Odoo stock sync.

Runs every few minutes (GitHub Actions). The app (Firestore) is the MASTER stock.

  1. Odoo POS -> app:   paid POS orders (sales and refunds) change stock in the linked store
                        and are written to the stock audit. Every order line is applied exactly
                        once. Lines whose barcode isn't found are kept as "pending" and retried.
  2. App -> Odoo:       each linked store's stock is copied to its Odoo stock location
                        (inventory adjustment) whenever the numbers differ.

Configuration lives in Firestore (set from the app: Profile -> Odoo sync):
  odooSync/config   { enabled, pushEnabled, startFrom, storeMap: { appStoreId: odooPosConfigId } }
  odooSync/catalog  written here: Odoo shops (POS configs) with their stock locations
  odooSync/state    written here: last run, counts, last error
  odooPending/{id}  POS lines that couldn't be matched yet (retried every run)
  odooProcessed/{id} marker per applied POS line (prevents double counting)

Secrets (GitHub -> Settings -> Secrets and variables -> Actions):
  FIREBASE_SERVICE_ACCOUNT  JSON key from Firebase Console -> Project settings -> Service accounts
  ODOO_URL                  e.g. https://beautysouq.odoo.com
  ODOO_DB                   database name (usually the part before .odoo.com)
  ODOO_LOGIN                login (email) of the Odoo user that owns the API key
  ODOO_API_KEY              Odoo -> Preferences -> Account Security -> New API Key

Logs are kept to counts only (no product names or prices), because logs of a public
GitHub repository can be read by anyone.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import traceback
from collections import defaultdict

import requests

# ----------------------------------------------------------------------------- Odoo


class OdooError(Exception):
    pass


class Odoo:
    """Minimal Odoo external API client (JSON-RPC, works on Odoo 16-19)."""

    def __init__(self, url: str, db: str, login: str, key: str):
        self.url = url.rstrip("/")
        self.db = db
        self.key = key
        self._id = 0
        self.uid = self._call("common", "authenticate", db, login, key, {})
        if not self.uid:
            raise OdooError("Odoo login failed: check ODOO_DB, ODOO_LOGIN and ODOO_API_KEY.")

    def _call(self, service: str, method: str, *args):
        self._id += 1
        resp = requests.post(
            f"{self.url}/jsonrpc",
            json={"jsonrpc": "2.0", "method": "call", "params": {"service": service, "method": method, "args": args}, "id": self._id},
            timeout=90,
        )
        resp.raise_for_status()
        data = resp.json()
        if data.get("error"):
            err = data["error"]
            msg = (err.get("data") or {}).get("message") or err.get("message") or str(err)
            raise OdooError(msg)
        return data.get("result")

    def kw(self, model: str, method: str, args: list, kwargs: dict | None = None):
        return self._call("object", "execute_kw", self.db, self.uid, self.key, model, method, args, kwargs or {})

    def search_read(self, model: str, domain: list, fields: list, **kw):
        return self.kw(model, "search_read", [domain], {"fields": fields, **kw})


# ----------------------------------------------------------------------------- helpers


def odoo_time(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def norm(code: str | None) -> str:
    return (code or "").strip().lower()


def m2o_id(v):
    """Odoo many2one values come as [id, name] or False."""
    return v[0] if isinstance(v, (list, tuple)) and v else None


def m2o_name(v):
    return v[1] if isinstance(v, (list, tuple)) and len(v) > 1 else ""


def group_lines(lines: list[dict]) -> dict:
    """Sum quantities per (order, product). Refund lines have negative qty."""
    out: dict = defaultdict(float)
    for l in lines:
        out[(m2o_id(l["order_id"]), m2o_id(l["product_id"]))] += float(l.get("qty") or 0)
    return dict(out)


def stock_after_sale(current: int, sold: int) -> tuple[int, bool]:
    """New stock after selling `sold` units (negative = refund). Never below zero.
    Returns (new_qty, was_short)."""
    new = current - sold
    if new < 0:
        return 0, True
    return new, False


def plan_push(app_qty: dict, odoo_qty: dict) -> dict:
    """Which Odoo products need their stock set, and to what. app_qty / odoo_qty: {odoo_product_id: qty}."""
    return {pid: q for pid, q in app_qty.items() if round(float(odoo_qty.get(pid, 0))) != q}


# ----------------------------------------------------------------------------- sync


class Sync:
    def __init__(self, db, odoo: Odoo, firestore_mod):
        self.db = db
        self.odoo = odoo
        self.fs = firestore_mod
        self.now = dt.datetime.now(dt.timezone.utc)
        self.stats = defaultdict(int)
        self._place_cache: dict = {}

    # ---- catalog of Odoo shops (shown in the app for linking) ----
    def write_catalog(self) -> dict:
        configs = self.odoo.search_read("pos.config", [], ["id", "name", "picking_type_id"])
        type_ids = [m2o_id(c["picking_type_id"]) for c in configs if m2o_id(c["picking_type_id"])]
        types = {t["id"]: t for t in self.odoo.kw("stock.picking.type", "read", [type_ids], {"fields": ["default_location_src_id"]})} if type_ids else {}
        shops = []
        for c in configs:
            t = types.get(m2o_id(c["picking_type_id"]), {})
            loc = t.get("default_location_src_id")
            shops.append({"id": c["id"], "name": c["name"], "locationId": m2o_id(loc), "locationName": m2o_name(loc)})
        self.db.collection("odooSync").document("catalog").set({"shops": shops, "updatedAt": self.fs.SERVER_TIMESTAMP})
        return {s["id"]: s for s in shops}

    def place(self, store_id: str, company_id: str):
        key = (store_id, company_id)
        if key not in self._place_cache:
            s = self.db.collection("stores").document(store_id).get()
            c = self.db.collection("companies").document(company_id).get() if company_id else None
            self._place_cache[key] = (
                (s.to_dict() or {}).get("name", "") if s.exists else "",
                (c.to_dict() or {}).get("name", "") if c is not None and c.exists else "",
            )
        return self._place_cache[key]

    def find_product(self, store_id: str, barcodes: list[str]):
        """App product in this store whose SKU equals one of the Odoo codes."""
        from google.cloud.firestore_v1.base_query import FieldFilter

        for code in barcodes:
            if not code:
                continue
            for variant in {code, code.strip(), code.strip().upper()}:
                q = (
                    self.db.collection("products")
                    .where(filter=FieldFilter("storeId", "==", store_id))
                    .where(filter=FieldFilter("sku", "==", variant))
                    .limit(1)
                    .get()
                )
                if q:
                    return q[0].reference
        return None

    # ---- 1. Odoo POS -> app ----
    def apply_line(self, line_key: str, prod_ref, sold: int, order_name: str, product_name: str) -> bool:
        """Apply one POS line in a transaction. False if it was already applied."""
        fs = self.fs
        marker = self.db.collection("odooProcessed").document(line_key)
        audit_ref = self.db.collection("auditLog").document()
        pending_ref = self.db.collection("odooPending").document(line_key)
        sync = self

        @fs.transactional
        def run(tx):
            if marker.get(transaction=tx).exists:
                return False
            snap = prod_ref.get(transaction=tx)
            if not snap.exists:
                raise LookupError("product vanished")
            d = snap.to_dict() or {}
            before = int(d.get("quantity") or 0)
            after, short = stock_after_sale(before, sold)
            store_name, company_name = sync.place(d.get("storeId", ""), d.get("companyId", ""))
            tx.update(prod_ref, {"quantity": after, "updatedAt": fs.SERVER_TIMESTAMP})
            note = f"Odoo POS {'refund' if sold < 0 else 'sale'} {order_name}"
            if short:
                note += f" (sold {sold}, only {before} in stock in the app)"
            tx.set(audit_ref, {
                "type": "pos",
                "productId": prod_ref.id,
                "productName": d.get("name", product_name),
                "sku": d.get("sku", ""),
                "storeId": d.get("storeId", ""),
                "storeName": store_name,
                "companyId": d.get("companyId", ""),
                "companyName": company_name,
                "delta": after - before,
                "quantityBefore": before,
                "quantityAfter": after,
                "userId": "",
                "userName": "Odoo POS",
                "approvedById": "",
                "approvedByName": "",
                "note": note,
                "createdAt": fs.SERVER_TIMESTAMP,
            })
            tx.set(marker, {"at": fs.SERVER_TIMESTAMP, "order": order_name, "qty": sold})
            tx.delete(pending_ref)
            return True

        return run(self.db.transaction())

    def pull_sales(self, config: dict, shops: dict):
        store_by_shop = {}
        for store_id, shop_id in (config.get("storeMap") or {}).items():
            if shop_id:
                store_by_shop[int(shop_id)] = store_id
        if not store_by_shop:
            return

        state = self.db.collection("odooSync").document("state").get().to_dict() or {}
        start = config.get("startFrom")
        start = start if isinstance(start, dt.datetime) else self.now
        last = state.get("lastPullAt")
        since = max(start, (last - dt.timedelta(minutes=30)) if isinstance(last, dt.datetime) else start)

        orders = self.odoo.search_read(
            "pos.order",
            [("state", "in", ["paid", "done", "invoiced"]), ("write_date", ">=", odoo_time(since)),
             ("config_id", "in", list(store_by_shop.keys()))],
            ["id", "name", "config_id"],
            order="id asc",
        )
        self.stats["orders_seen"] = len(orders)
        order_info = {o["id"]: o for o in orders}
        lines = self.odoo.search_read("pos.order.line", [("order_id", "in", list(order_info))], ["id", "order_id", "product_id", "qty"]) if orders else []

        product_ids = list({m2o_id(l["product_id"]) for l in lines if m2o_id(l["product_id"])})
        products = {p["id"]: p for p in self.odoo.kw("product.product", "read", [product_ids], {"fields": ["barcode", "default_code", "display_name"]})} if product_ids else {}

        work = []  # (line_key, store_id, odoo_product_id, qty, order_name)
        for (order_id, pid), qty in group_lines(lines).items():
            o = order_info.get(order_id)
            if not o or not pid or round(qty) == 0:
                continue
            store_id = store_by_shop.get(m2o_id(o["config_id"]))
            if store_id:
                work.append((f"{order_id}_{pid}", store_id, pid, int(round(qty)), o["name"]))

        # Earlier unmatched lines are retried every run.
        for p in self.db.collection("odooPending").stream():
            d = p.to_dict() or {}
            if not any(w[0] == p.id for w in work):
                work.append((p.id, d.get("storeId"), d.get("odooProductId"), int(d.get("qty") or 0), d.get("order", "")))
                pid = d.get("odooProductId")
                if pid and pid not in products:
                    products[pid] = {"barcode": d.get("barcode"), "default_code": d.get("code"), "display_name": d.get("name", "")}

        for line_key, store_id, pid, qty, order_name in work:
            if not store_id or not qty:
                continue
            prod = products.get(pid, {})
            ref = self.find_product(store_id, [prod.get("barcode") or "", prod.get("default_code") or ""])
            if ref is None:
                self.db.collection("odooPending").document(line_key).set({
                    "storeId": store_id, "odooProductId": pid, "qty": qty, "order": order_name,
                    "barcode": prod.get("barcode") or "", "code": prod.get("default_code") or "",
                    "name": prod.get("display_name", ""), "updatedAt": self.fs.SERVER_TIMESTAMP,
                }, merge=True)
                self.stats["unmatched"] += 1
                continue
            if self.apply_line(line_key, ref, qty, order_name, prod.get("display_name", "")):
                self.stats["lines_applied"] += 1

        self.db.collection("odooSync").document("state").set({"lastPullAt": self.now}, merge=True)

    # ---- 2. app -> Odoo ----
    def push_stock(self, config: dict, shops: dict):
        from google.cloud.firestore_v1.base_query import FieldFilter

        for store_id, shop_id in (config.get("storeMap") or {}).items():
            shop = shops.get(int(shop_id)) if shop_id else None
            loc = shop and shop.get("locationId")
            if not loc:
                continue
            app_products = [
                p.to_dict() for p in self.db.collection("products").where(filter=FieldFilter("storeId", "==", store_id)).stream()
            ]
            by_code = {norm(p.get("sku")): int(p.get("quantity") or 0) for p in app_products if norm(p.get("sku"))}
            if not by_code:
                continue

            codes = list(by_code)
            odoo_products = []
            for i in range(0, len(codes), 200):
                chunk = codes[i:i + 200]
                variants = list({c for c in chunk} | {c.upper() for c in chunk})
                odoo_products += self.odoo.search_read(
                    "product.product",
                    ["|", ("barcode", "in", variants), ("default_code", "in", variants)],
                    ["id", "barcode", "default_code"],
                )
            app_qty = {}
            for op in odoo_products:
                code = norm(op.get("barcode")) if norm(op.get("barcode")) in by_code else norm(op.get("default_code"))
                if code in by_code:
                    app_qty[op["id"]] = by_code[code]
            if not app_qty:
                continue

            quants = self.odoo.search_read(
                "stock.quant", [("location_id", "=", loc), ("product_id", "in", list(app_qty))], ["id", "product_id", "quantity"]
            )
            odoo_qty = defaultdict(float)
            quant_id = {}
            for q in quants:
                pid = m2o_id(q["product_id"])
                odoo_qty[pid] += float(q.get("quantity") or 0)
                quant_id.setdefault(pid, q["id"])

            ctx = {"context": {"inventory_mode": True}}
            for pid, target in plan_push(app_qty, odoo_qty).items():
                try:
                    if pid in quant_id:
                        qid = quant_id[pid]
                        self.odoo.kw("stock.quant", "write", [[qid], {"inventory_quantity": target}], ctx)
                    else:
                        qid = self.odoo.kw("stock.quant", "create", [{"product_id": pid, "location_id": loc, "inventory_quantity": target}], ctx)
                        qid = qid[0] if isinstance(qid, list) else qid
                    self.odoo.kw("stock.quant", "action_apply_inventory", [[qid]])
                    self.stats["odoo_updates"] += 1
                except OdooError:
                    # e.g. product is not tracked as stock in Odoo
                    self.stats["odoo_update_errors"] += 1


def main() -> int:
    import firebase_admin
    from firebase_admin import credentials, firestore

    sa = json.loads(os.environ["FIREBASE_SERVICE_ACCOUNT"])
    firebase_admin.initialize_app(credentials.Certificate(sa))
    db = firestore.client()
    state_ref = db.collection("odooSync").document("state")

    try:
        config = db.collection("odooSync").document("config").get().to_dict() or {}
        odoo = Odoo(os.environ["ODOO_URL"], os.environ["ODOO_DB"], os.environ["ODOO_LOGIN"], os.environ["ODOO_API_KEY"])
        sync = Sync(db, odoo, firestore)
        shops = sync.write_catalog()

        if config.get("enabled"):
            sync.pull_sales(config, shops)
            if config.get("pushEnabled"):
                sync.push_stock(config, shops)

        state_ref.set({
            "lastRunAt": firestore.SERVER_TIMESTAMP,
            "lastOkAt": firestore.SERVER_TIMESTAMP,
            "lastError": "",
            "lastStats": dict(sync.stats),
        }, merge=True)
        print("OK", dict(sync.stats))
        return 0
    except Exception as e:  # noqa: BLE001 - report any failure to the app
        state_ref.set({"lastRunAt": firestore.SERVER_TIMESTAMP, "lastError": f"{type(e).__name__}: {e}"[:500]}, merge=True)
        print("FAILED:", type(e).__name__)
        traceback.print_exc(limit=3)
        return 1


if __name__ == "__main__":
    sys.exit(main())
