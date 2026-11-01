"""
Beauty Souq <-> Odoo stock sync.

Runs every few minutes (GitHub Actions). The app (Firestore) is the MASTER stock.

  0. App -> Odoo products: every product in a company's "Display Store" is created (or its
                        name/price updated) in Odoo, so the till can scan it. Nothing has to be
                        registered in Odoo by hand.
  1. Odoo POS -> app:   paid POS orders (sales and refunds) change stock in the linked store
                        and are written to the stock audit. Every order line is applied exactly
                        once. Lines whose barcode isn't found are kept as "pending" and retried.
  2. App -> Odoo:       each linked store's stock is copied to its Odoo stock location
                        (inventory adjustment) whenever the numbers differ.

Only stores whose name contains "Display" (e.g. "Display Store") in each company is ever changed by Odoo sales,
and only Display Store stock is sent to Odoo. A sale line's barcode decides the company.

Configuration lives in Firestore (set from the app: Profile -> Odoo sync):
  odooSync/config   { enabled, pushEnabled, startFrom,
                      shops: { odooPosConfigId: companyId | "all" } }   # which Odoo tills are synced
  odooSync/catalog  written here: Odoo shops (POS configs) with their stock locations
  odooSync/state    written here: last run, counts, last error
  odooPending/{id}  POS lines that couldn't be matched yet (retried every run)
  odooProcessed/{id} marker per applied POS line (prevents double counting)

Secrets (GitHub -> Settings -> Secrets and variables -> Actions):
  FIREBASE_SERVICE_ACCOUNT  JSON key from Firebase Console -> Project settings -> Service accounts
  ODOO_URL                  e.g. https://beautysouq.odoo.com
  ODOO_DB                   optional: database name. If empty it is taken from the address,
                            e.g. https://beautysouq.odoo.com -> beautysouq
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
            raise OdooError(f"Odoo login failed for database '{db}': check ODOO_LOGIN and ODOO_API_KEY "
                            "(and ODOO_DB if your database name differs from your web address).")

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


def db_from_url(url: str) -> str:
    """Odoo Online database name = the part before .odoo.com (e.g. beautysouq)."""
    from urllib.parse import urlparse

    host = urlparse(url if "://" in url else f"https://{url}").hostname or ""
    return host.split(".")[0] if host else ""


def odoo_time(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def norm(code: str | None) -> str:
    return (code or "").strip().lower()


def code_variants(code: str | None) -> set[str]:
    """Spellings of the same barcode. UPC-A (12 digits) is often read as EAN-13 with a
    leading 0, so for numeric codes we also try with/without leading zeros."""
    c = (code or "").strip()
    if not c:
        return set()
    out = {c, c.upper()}
    if c.isdigit():
        bare = c.lstrip("0") or "0"
        out |= {bare}
        for length in (8, 12, 13, 14):
            if len(bare) <= length:
                out.add(bare.zfill(length))
    return out


def code_key(code: str | None) -> str:
    """One comparable key per barcode (numeric codes without leading zeros)."""
    c = norm(code)
    return (c.lstrip("0") or "0") if c.isdigit() else c


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


def is_display_store(name: str | None) -> bool:
    """Any store whose name contains "display" (Display Store, Display Storage, Display – Doha...)."""
    return "display" in norm(name)


def choose_target(candidates: list[dict], company: str | None):
    """Pick the Display Store product a POS line should come from.
    candidates: [{"ref":..., "companyId":...}] (products with that barcode in Display Stores).
    company: the company linked to the Odoo shop, or None/"all".
    Returns (candidate or None, reason)."""
    if company and company != "all":
        candidates = [c for c in candidates if c["companyId"] == company]
    if len(candidates) == 1:
        return candidates[0], ""
    if not candidates:
        return None, "not found in any Display Store"
    return None, "barcode is in several companies' Display Stores – link this Odoo shop to one company"


def product_payload(name: str, barcode: str, retail, cost) -> dict:
    """Odoo product fields we manage from the app."""
    vals = {"name": name or barcode, "barcode": barcode, "available_in_pos": True, "sale_ok": True}
    if retail is not None:
        vals["list_price"] = float(retail)
    if cost is not None:
        vals["standard_price"] = float(cost)
    return vals


def product_changes(current: dict, wanted: dict) -> dict:
    """Only the fields that differ (prices compared to the cent)."""
    out = {}
    for k, v in wanted.items():
        cur = current.get(k)
        if isinstance(v, float):
            if cur is None or cur is False or abs(float(cur) - v) >= 0.005:
                out[k] = v
        elif cur != v:
            out[k] = v
    return out


def category_change(field_is_many: bool, current, wanted_id: int):
    """Odoo write value to put a product in POS category wanted_id, or None if already there."""
    if field_is_many:
        ids = list(current or [])
        return None if wanted_id in ids else [(4, wanted_id)]
    return None if m2o_id(current) == wanted_id else wanted_id


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
        import time

        # Leave room under the GitHub job limit; unfinished work continues on the next run.
        self.deadline = time.monotonic() + float(os.environ.get("SYNC_TIME_BUDGET_SECONDS", "720"))
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

    def display_stores(self) -> dict:
        """{storeId: companyId} for every store named "Display Store"."""
        out = {}
        for st in self.db.collection("stores").stream():
            d = st.to_dict() or {}
            if is_display_store(d.get("name")):
                out[st.id] = d.get("companyId", "")
        return out

    def find_candidates(self, codes: list[str], display: dict) -> list[dict]:
        """Products whose SKU equals one of the Odoo codes, in Display Stores only."""
        from google.cloud.firestore_v1.base_query import FieldFilter

        found = {}
        for code in codes:
            if not code:
                continue
            for variant in code_variants(code):
                for snap in self.db.collection("products").where(filter=FieldFilter("sku", "==", variant)).limit(50).get():
                    d = snap.to_dict() or {}
                    if d.get("storeId") in display:
                        found[snap.id] = {"ref": snap.reference, "companyId": d.get("companyId", "")}
        return list(found.values())

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

    def pull_sales(self, config: dict, shops: dict, display: dict):
        shop_company = {int(k): v for k, v in (config.get("shops") or {}).items() if v}
        if not shop_company or not display:
            return

        state = self.db.collection("odooSync").document("state").get().to_dict() or {}
        start = config.get("startFrom")
        start = start if isinstance(start, dt.datetime) else self.now
        last = state.get("lastPullAt")
        since = max(start, (last - dt.timedelta(minutes=30)) if isinstance(last, dt.datetime) else start)

        orders = self.odoo.search_read(
            "pos.order",
            [("state", "in", ["paid", "done", "invoiced"]), ("write_date", ">=", odoo_time(since)),
             ("config_id", "in", list(shop_company.keys()))],
            ["id", "name", "config_id"],
            order="id asc",
        )
        self.stats["orders_seen"] = len(orders)
        order_info = {o["id"]: o for o in orders}
        lines = self.odoo.search_read("pos.order.line", [("order_id", "in", list(order_info))], ["id", "order_id", "product_id", "qty"]) if orders else []

        product_ids = list({m2o_id(l["product_id"]) for l in lines if m2o_id(l["product_id"])})
        products = {p["id"]: p for p in self.odoo.kw("product.product", "read", [product_ids], {"fields": ["barcode", "default_code", "display_name"]})} if product_ids else {}

        work = []  # (line_key, shopId, odoo_product_id, qty, order_name)
        for (order_id, pid), qty in group_lines(lines).items():
            o = order_info.get(order_id)
            if not o or not pid or round(qty) == 0:
                continue
            work.append((f"{order_id}_{pid}", m2o_id(o["config_id"]), pid, int(round(qty)), o["name"]))

        # Earlier unmatched lines are retried every run.
        keys = {w[0] for w in work}
        for p in self.db.collection("odooPending").stream():
            d = p.to_dict() or {}
            if p.id in keys:
                continue
            pid = d.get("odooProductId")
            work.append((p.id, d.get("shopId"), pid, int(d.get("qty") or 0), d.get("order", "")))
            if pid and pid not in products:
                products[pid] = {"barcode": d.get("barcode"), "default_code": d.get("code"), "display_name": d.get("name", "")}

        for line_key, shop_id, pid, qty, order_name in work:
            if not qty:
                continue
            prod = products.get(pid, {})
            candidates = self.find_candidates([prod.get("barcode") or "", prod.get("default_code") or ""], display)
            target, reason = choose_target(candidates, shop_company.get(shop_id))
            if target is None:
                self.db.collection("odooPending").document(line_key).set({
                    "shopId": shop_id, "odooProductId": pid, "qty": qty, "order": order_name,
                    "barcode": prod.get("barcode") or "", "code": prod.get("default_code") or "",
                    "name": prod.get("display_name", ""), "reason": reason,
                    "updatedAt": self.fs.SERVER_TIMESTAMP,
                }, merge=True)
                self.stats["unmatched"] += 1
                continue
            if self.apply_line(line_key, target["ref"], qty, order_name, prod.get("display_name", "")):
                self.stats["lines_applied"] += 1

        self.db.collection("odooSync").document("state").set({"lastPullAt": self.now}, merge=True)

    # ---- 2. app -> Odoo ----
    def ensure_categories(self, company_ids: set) -> dict:
        """Make sure POS category "Display Store" exists with a child per company. {companyId: categId}"""
        cats = self.odoo.search_read("pos.category", [], ["id", "name", "parent_id"])
        parent = next((c for c in cats if norm(c["name"]) == "display store" and not c.get("parent_id")), None)
        parent_id = parent["id"] if parent else self.odoo.kw("pos.category", "create", [{"name": "Display Store"}])
        if isinstance(parent_id, list):
            parent_id = parent_id[0]
        children = {norm(c["name"]): c["id"] for c in cats if m2o_id(c.get("parent_id")) == parent_id}
        out = {}
        for cid in company_ids:
            snap = self.db.collection("companies").document(cid).get()
            name = ((snap.to_dict() or {}).get("name") if snap.exists else "") or "Other"
            if norm(name) not in children:
                new_id = self.odoo.kw("pos.category", "create", [{"name": name, "parent_id": parent_id}])
                children[norm(name)] = new_id[0] if isinstance(new_id, list) else new_id
                self.stats["pos_categories_created"] += 1
            out[cid] = children[norm(name)]
        return out

    # ---- 0. app products -> Odoo products ----
    def push_products(self, display: dict):
        """Create/update an Odoo product for every Display Store product (one per barcode).
        Creates in batches and stops before the time budget; the rest continues next run."""
        import time

        from google.cloud.firestore_v1.base_query import FieldFilter

        # Cost prices, read once (admin-only collection).
        costs = {}
        for pr in self.db.collection("productPrices").stream():
            c = (pr.to_dict() or {}).get("cost")
            if c is not None:
                costs[pr.id] = c

        # One app product per barcode (first Display Store wins for name/price).
        wanted: dict = {}
        company_of: dict = {}
        for store_id, company_id in display.items():
            for snap in self.db.collection("products").where(filter=FieldFilter("storeId", "==", store_id)).stream():
                d = snap.to_dict() or {}
                sku = (d.get("sku") or "").strip()
                key = code_key(sku)
                if key and key not in wanted:
                    wanted[key] = product_payload(d.get("name", ""), sku, d.get("retailPrice"), costs.get(snap.id))
                    company_of[key] = company_id
        self.stats["app_products"] = len(wanted)
        if not wanted:
            return

        # Odoo 18+ marks stock-tracked products with is_storable; older versions use type "product".
        tmpl_fields = self.odoo.kw("product.template", "fields_get", [], {"attributes": ["type", "selection"]})
        if "is_storable" in tmpl_fields:
            storable = {"type": "consu", "is_storable": True}
        elif any(v == "product" for v, _ in (tmpl_fields.get("type", {}).get("selection") or [])):
            storable = {"type": "product"}
        else:
            storable = {}

        # POS categories: "Display Store" with one sub-category per company (brand).
        categ_field, categ_many = None, False
        if "pos_categ_ids" in tmpl_fields:
            categ_field, categ_many = "pos_categ_ids", True
        elif "pos_categ_id" in tmpl_fields:
            categ_field = "pos_categ_id"
        categ_for_company: dict = {}
        if categ_field:
            try:
                categ_for_company = self.ensure_categories({c for c in company_of.values() if c})
            except OdooError:
                categ_field = None
                self.stats["category_errors"] += 1

        def with_category(key: str, vals: dict) -> dict:
            cid = categ_for_company.get(company_of.get(key))
            if not categ_field or not cid:
                return vals
            return {**vals, categ_field: [(6, 0, [cid])] if categ_many else cid}

        keys = list(wanted)
        existing: dict = {}
        for i in range(0, len(keys), 200):
            variants = list({v for k in keys[i:i + 200] for v in code_variants(k)})
            for op in self.odoo.search_read(
                "product.product",
                [("barcode", "in", variants)],
                ["id", "barcode", "name", "list_price", "standard_price", "available_in_pos", "sale_ok"]
                + ([categ_field] if categ_field else []),
                context={"active_test": False},
            ):
                existing[code_key(op.get("barcode"))] = op
        self.stats["odoo_products_existing"] = len(existing)

        # ---- create missing products, 100 per call ----
        to_create = [with_category(key, {**vals, **storable}) for key, vals in wanted.items() if key not in existing]
        print(f"products: {len(wanted)} in Display Stores, {len(existing)} already in Odoo, {len(to_create)} to create")
        for i in range(0, len(to_create), 100):
            if time.monotonic() > self.deadline:
                self.stats["odoo_products_left_for_next_run"] = len(to_create) - i
                print(f"products: time budget reached, {len(to_create) - i} will be created next run")
                return
            batch = to_create[i:i + 100]
            try:
                self.odoo.kw("product.template", "create", [batch])
                self.stats["odoo_products_created"] += len(batch)
            except OdooError:
                # One bad product (e.g. duplicate barcode) fails the batch; retry one by one.
                for vals in batch:
                    try:
                        self.odoo.kw("product.template", "create", [vals])
                        self.stats["odoo_products_created"] += 1
                    except OdooError:
                        self.stats["odoo_product_errors"] += 1
            print(f"products: created {self.stats['odoo_products_created']}/{len(to_create)}")

        # ---- update changed names/prices ----
        for key, vals in wanted.items():
            op = existing.get(key)
            if op is None:
                continue
            if time.monotonic() > self.deadline:
                print("products: time budget reached during updates, continuing next run")
                return
            changes = product_changes(op, {**vals, "barcode": op.get("barcode")})
            cid = categ_for_company.get(company_of.get(key))
            if categ_field and cid:
                cat = category_change(categ_many, op.get(categ_field), cid)
                if cat is not None:
                    changes[categ_field] = cat
            if changes:
                try:
                    self.odoo.kw("product.product", "write", [[op["id"]], changes])
                    self.stats["odoo_products_updated"] += 1
                except OdooError:
                    self.stats["odoo_product_errors"] += 1

    def push_stock(self, config: dict, shops: dict, display: dict):
        """Set each synced Odoo shop's stock to the Display Store stock of its company
        (or of all companies, summed per barcode, if the shop is linked to "all")."""
        from google.cloud.firestore_v1.base_query import FieldFilter

        # Display Store stock per company: {companyId: {code: qty}}
        per_company: dict = defaultdict(lambda: defaultdict(int))
        for store_id, company_id in display.items():
            for snap in self.db.collection("products").where(filter=FieldFilter("storeId", "==", store_id)).stream():
                d = snap.to_dict() or {}
                code = code_key(d.get("sku"))
                if code:
                    per_company[company_id][code] += int(d.get("quantity") or 0)

        for shop_key, company in (config.get("shops") or {}).items():
            if not company:
                continue
            shop = shops.get(int(shop_key))
            loc = shop and shop.get("locationId")
            if not loc:
                continue
            by_code: dict = defaultdict(int)
            for cid, codes in per_company.items():
                if company == "all" or cid == company:
                    for code, q in codes.items():
                        by_code[code] += q
            if not by_code:
                continue

            codes = list(by_code)
            odoo_products = []
            for i in range(0, len(codes), 100):
                chunk = codes[i:i + 100]
                variants = list({v for c in chunk for v in code_variants(c)})
                odoo_products += self.odoo.search_read(
                    "product.product",
                    ["|", ("barcode", "in", variants), ("default_code", "in", variants)],
                    ["id", "barcode", "default_code"],
                )
            app_qty = {}
            for op in odoo_products:
                code = code_key(op.get("barcode")) if code_key(op.get("barcode")) in by_code else code_key(op.get("default_code"))
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
            import time

            for pid, target in plan_push(app_qty, odoo_qty).items():
                if time.monotonic() > self.deadline:
                    print("stock: time budget reached, continuing next run")
                    return
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
        url = os.environ["ODOO_URL"].strip()
        if "://" not in url:
            url = f"https://{url}"
        odoo_db = (os.environ.get("ODOO_DB") or "").strip() or db_from_url(url)
        odoo = Odoo(url, odoo_db, os.environ["ODOO_LOGIN"].strip(), os.environ["ODOO_API_KEY"].strip())
        sync = Sync(db, odoo, firestore)
        shops = sync.write_catalog()

        if config.get("enabled"):
            display = sync.display_stores()
            sync.stats["display_stores"] = len(display)
            if config.get("syncProducts", True):
                sync.push_products(display)
            sync.pull_sales(config, shops, display)
            if config.get("pushEnabled"):
                sync.push_stock(config, shops, display)

        state_ref.set({
            "lastRunAt": firestore.SERVER_TIMESTAMP,
            "lastOkAt": firestore.SERVER_TIMESTAMP,
            "lastError": "",
            "lastStats": dict(sync.stats),
        }, merge=True)
        summary = ", ".join(f"{k}={v}" for k, v in sorted(sync.stats.items())) or "nothing to do"
        print(f"OK: sync {'ON' if config.get('enabled') else 'OFF (turn it on in the app: Profile > Odoo sync)'}; {summary}")
        return 0
    except Exception as e:  # noqa: BLE001 - report any failure to the app
        state_ref.set({"lastRunAt": firestore.SERVER_TIMESTAMP, "lastError": f"{type(e).__name__}: {e}"[:500]}, merge=True)
        print("FAILED:", type(e).__name__)
        traceback.print_exc(limit=3)
        return 1


if __name__ == "__main__":
    sys.exit(main())
