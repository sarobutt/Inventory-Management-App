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


class AppCache:
    """In-memory copy of what the sync needs from Firestore, to stay far below the free
    plan's daily read limit (50,000). Loaded fully once (and every few hours); after that,
    each pass only reads documents whose updatedAt changed."""

    REFRESH_HOURS = 6

    def __init__(self, db):
        self.db = db
        self.stores: dict = {}      # storeId -> {name, companyId}
        self.companies: dict = {}   # companyId -> name
        self.products: dict = {}    # productId -> data (only products in display stores)
        self.costs: dict = {}       # productId -> cost
        self.loaded_at: dt.datetime | None = None
        self.retry_keys: set = set()  # barcodes to push again next pass
        self.checked_at: dt.datetime | None = None

    @property
    def display(self) -> dict:
        return {sid: st.get("companyId", "") for sid, st in self.stores.items() if is_display_store(st.get("name"))}

    def needs_full(self, now: dt.datetime) -> bool:
        return self.loaded_at is None or now - self.loaded_at > dt.timedelta(hours=self.REFRESH_HOURS)

    def full_load(self, now: dt.datetime) -> None:
        from google.cloud.firestore_v1.base_query import FieldFilter

        self.stores = {s.id: s.to_dict() or {} for s in self.db.collection("stores").stream()}
        self.companies = {c.id: (c.to_dict() or {}).get("name", "") for c in self.db.collection("companies").stream()}
        products = {}
        for store_id in self.display:
            for snap in self.db.collection("products").where(filter=FieldFilter("storeId", "==", store_id)).stream():
                products[snap.id] = snap.to_dict() or {}
        self.products = products
        refs = [self.db.collection("productPrices").document(pid) for pid in products]
        costs = {}
        for i in range(0, len(refs), 300):
            for snap in self.db.get_all(refs[i:i + 300]):
                c = (snap.to_dict() or {}).get("cost") if snap.exists else None
                if c is not None:
                    costs[snap.id] = c
        self.costs = costs
        self.loaded_at = self.checked_at = now
        print(f"cache: loaded {len(self.stores)} stores, {len(self.display)} display stores, {len(products)} display products", flush=True)

    def incremental(self, now: dt.datetime) -> set:
        """Reads only documents changed since the last check. Returns changed product barcodes (code keys)."""
        from google.cloud.firestore_v1.base_query import FieldFilter

        since = (self.checked_at or now) - dt.timedelta(minutes=3)
        changed_keys: set = set()

        def changed(col):
            return self.db.collection(col).where(filter=FieldFilter("updatedAt", ">=", since)).stream()

        display_before = set(self.display)
        for s in changed("stores"):
            self.stores[s.id] = s.to_dict() or {}
        for c in changed("companies"):
            self.companies[c.id] = (c.to_dict() or {}).get("name", "")
        new_display = set(self.display) - display_before
        if new_display or (display_before - set(self.display)):
            # A store became (or stopped being) a display store: reload everything once.
            self.full_load(now)
            return {code_key(p.get("sku")) for p in self.products.values() if code_key(p.get("sku"))}

        display = self.display
        for snap in changed("products"):
            d = snap.to_dict() or {}
            old = self.products.get(snap.id)
            if old:
                changed_keys.add(code_key(old.get("sku")))
            if d.get("storeId") in display:
                self.products[snap.id] = d
                changed_keys.add(code_key(d.get("sku")))
            elif old is not None:
                del self.products[snap.id]  # moved out of a display store
        for pr in changed("productPrices"):
            if pr.id in self.products:
                c = (pr.to_dict() or {}).get("cost")
                if c is not None:
                    self.costs[pr.id] = c
                changed_keys.add(code_key(self.products[pr.id].get("sku")))
        self.checked_at = now
        changed_keys.discard("")
        return changed_keys

    def forget(self, product_id: str) -> None:
        self.products.pop(product_id, None)


class Sync:
    def __init__(self, db, odoo: Odoo, firestore_mod, cache: AppCache | None = None):
        self.db = db
        self.odoo = odoo
        self.fs = firestore_mod
        self.now = dt.datetime.now(dt.timezone.utc)
        self.stats = defaultdict(int)
        import time

        # Leave room under the GitHub job limit; unfinished work continues on the next run.
        self.deadline = time.monotonic() + float(os.environ.get("SYNC_TIME_BUDGET_SECONDS", "720"))
        self._place_cache: dict = {}
        self.cache = cache

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
        if self.cache and store_id in self.cache.stores:
            return self.cache.stores[store_id].get("name", ""), self.cache.companies.get(company_id, "")
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
        """{storeId: companyId} for every display store."""
        if self.cache:
            return self.cache.display
        out = {}
        for st in self.db.collection("stores").stream():
            d = st.to_dict() or {}
            if is_display_store(d.get("name")):
                out[st.id] = d.get("companyId", "")
        return out

    def find_candidates(self, codes: list[str], display: dict) -> list[dict]:
        """Products whose SKU equals one of the Odoo codes, in Display Stores only."""
        from google.cloud.firestore_v1.base_query import FieldFilter

        if self.cache:
            keys = {code_key(c) for c in codes if c}
            return [
                {"ref": self.db.collection("products").document(pid), "companyId": d.get("companyId", "")}
                for pid, d in self.cache.products.items()
                if code_key(d.get("sku")) in keys and d.get("storeId") in display
            ]

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
            if sync.cache and prod_ref.id in sync.cache.products:
                sync.cache.products[prod_ref.id]["quantity"] = after  # keep the cache current
                sync.cache.retry_keys.add(code_key(d.get("sku")))
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
            # Shown in the app under Profile > Odoo sales.
            tx.set(marker, {
                "at": fs.SERVER_TIMESTAMP, "order": order_name, "qty": sold,
                "productId": prod_ref.id, "productName": d.get("name", product_name), "sku": d.get("sku", ""),
                "storeName": store_name, "companyName": company_name,
                "before": before, "after": after, "short": short,
            })
            tx.delete(pending_ref)
            return True

        return run(self.db.transaction())

    def pull_sales(self, config: dict, shops: dict, display: dict, last_pull: dt.datetime | None = None):
        shop_company = {int(k): v for k, v in (config.get("shops") or {}).items() if v}
        if not shop_company or not display:
            return

        start = config.get("startFrom")
        start = start if isinstance(start, dt.datetime) else self.now
        since = max(start, (last_pull - dt.timedelta(minutes=30)) if isinstance(last_pull, dt.datetime) else start)

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
            try:
                if self.apply_line(line_key, target["ref"], qty, order_name, prod.get("display_name", "")):
                    self.stats["lines_applied"] += 1
            except LookupError:
                # Product was deleted in the app since the cache was loaded: retry next pass.
                if self.cache:
                    self.cache.forget(target["ref"].id)
                self.stats["retry_next_pass"] += 1

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
            if self.cache and cid in self.cache.companies:
                name = self.cache.companies[cid] or "Other"
            else:
                snap = self.db.collection("companies").document(cid).get()
                name = ((snap.to_dict() or {}).get("name") if snap.exists else "") or "Other"
            if norm(name) not in children:
                new_id = self.odoo.kw("pos.category", "create", [{"name": name, "parent_id": parent_id}])
                children[norm(name)] = new_id[0] if isinstance(new_id, list) else new_id
                self.stats["pos_categories_created"] += 1
            out[cid] = children[norm(name)]
        return out

    def diagnose_orders(self, config: dict, shops: dict, last_pull):
        """Counts only: recent till orders by till and state, and which tills the sync reads."""
        try:
            since = self.now - dt.timedelta(days=2)
            recent = self.odoo.search_read("pos.order", [("create_date", ">=", odoo_time(since))], ["state", "config_id"], limit=500)
            by = defaultdict(int)
            for o in recent:
                by[f"till {m2o_id(o.get('config_id'))} {o.get('state')}"] += 1
            linked = {k: ("all brands" if v == "all" else "one brand") for k, v in (config.get("shops") or {}).items() if v}
            start = config.get("startFrom")
            self.db.collection("odooSync").document("state").set({"ordersCheck": {
                "at": self.fs.SERVER_TIMESTAMP, "recentOrders": len(recent),
                "tillsTicked": len(linked), "pushEnabled": config.get("pushEnabled", True) is not False,
            }}, merge=True)
            print(f"orders check: last 2 days {dict(by) or 'no till orders at all'}; tills in Odoo {sorted(shops)}; "
                  f"tills ticked in the app {linked or 'NONE - tick your till in Profile > Odoo sync'}; "
                  f"counting sales from {odoo_time(start) if isinstance(start, dt.datetime) else 'not set'}; "
                  f"last checked {odoo_time(last_pull) if isinstance(last_pull, dt.datetime) else 'never'}; "
                  f"send stock to Odoo {'ON' if config.get('pushEnabled', True) else 'OFF'}", flush=True)
        except OdooError as e:
            print(f"orders check failed: {e}", flush=True)

    def diagnose_till(self):
        """Print why products might not show in the till (counts and settings only)."""
        try:
            sellable = self.odoo.search_read("product.product", [("available_in_pos", "=", True)], ["company_id", "pos_categ_ids"] if "pos_categ_ids" in self.odoo.kw("product.product", "fields_get", [], {"attributes": ["type"]}) else ["company_id"])
            by_company = defaultdict(int)
            for p in sellable:
                by_company[m2o_name(p.get("company_id")) or "shared (all companies)"] += 1
            print(f"check: {len(sellable)} products are 'Available in POS'; by Odoo company: {dict(by_company)}")
            cfg_fields = self.odoo.kw("pos.config", "fields_get", [], {"attributes": ["type"]})
            want = [f for f in ["name", "company_id", "limit_categories", "iface_available_categ_ids", "current_session_state",
                                "limited_products_loading", "active"] if f in cfg_fields]
            for c in self.odoo.search_read("pos.config", [], want):
                info = {k: (m2o_name(v) if isinstance(v, list) and k == "company_id" else (len(v) if isinstance(v, list) else v))
                        for k, v in c.items() if k != "id"}
                print(f"check: till {info}")
            companies = self.odoo.search_read("res.company", [], ["name"])
            print(f"check: Odoo companies: {[c['name'] for c in companies]}")
        except OdooError as e:
            print(f"check: could not read till settings: {e}")

    # ---- 0. app products -> Odoo products ----
    def push_products(self, display: dict, only_keys: set | None = None):
        """Create/update an Odoo product for every Display Store product (one per barcode),
        from the in-memory cache. only_keys limits it to changed barcodes (no hiding then)."""
        import time

        # One app product per barcode (first Display Store wins for name/price).
        wanted: dict = {}
        company_of: dict = {}
        for pid, d in sorted(self.cache.products.items()):
            if d.get("storeId") not in display:
                continue
            sku = (d.get("sku") or "").strip()
            key = code_key(sku)
            if key and key not in wanted:
                wanted[key] = product_payload(d.get("name", ""), sku, d.get("retailPrice"), self.cache.costs.get(pid))
                company_of[key] = display[d.get("storeId")]
        # Products with no Display Store stock left are taken off the till until restocked.
        stock_of: dict = defaultdict(int)
        for d in self.cache.products.values():
            if d.get("storeId") in display:
                stock_of[code_key(d.get("sku"))] += int(d.get("quantity") or 0)
        for key, vals in wanted.items():
            vals["available_in_pos"] = stock_of.get(key, 0) > 0
        self.stats["out_of_stock_hidden"] = sum(1 for v in wanted.values() if not v["available_in_pos"])
        all_keys = set(wanted)
        if only_keys is not None:
            wanted = {k: v for k, v in wanted.items() if k in only_keys}
        self.stats["app_products"] = len(all_keys)
        if not wanted:
            return  # never hide everything because of an empty/failed read

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
        if only_keys is None or to_create:
            print(f"products: {len(wanted)} checked, {len(existing)} already in Odoo, {len(to_create)} to create", flush=True)
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
            print(f"products: created {self.stats['odoo_products_created']}/{len(to_create)}", flush=True)

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
                    # Odoo may refuse to take a product off the till while a session is open:
                    # save the other changes now and try the till visibility again next pass.
                    rest = {k: v for k, v in changes.items() if k != "available_in_pos"}
                    try:
                        if rest:
                            self.odoo.kw("product.product", "write", [[op["id"]], rest])
                        self.stats["till_visibility_retry"] += 1
                        if self.cache:
                            self.cache.retry_keys.add(key)
                    except OdooError:
                        self.stats["odoo_product_errors"] += 1

        # Everything else in Odoo is hidden from the till (full passes only).
        if only_keys is None and time.monotonic() <= self.deadline:
            try:
                self.hide_non_display_products(all_keys)
            except OdooError:
                self.stats["hide_errors"] += 1

    def hide_non_display_products(self, display_keys: set):
        """Only Display Unit products may be sold: any other product in the till is hidden
        (available_in_pos = False). Nothing is deleted."""
        sellable = self.odoo.search_read("product.product", [("available_in_pos", "=", True)], ["id", "barcode"])
        hide = [p["id"] for p in sellable if code_key(p.get("barcode")) not in display_keys]
        hidden = refused = 0
        for i in range(0, len(hide), 200):
            batch = hide[i:i + 200]
            try:
                self.odoo.kw("product.product", "write", [batch, {"available_in_pos": False}])
                hidden += len(batch)
            except OdooError:
                # Odoo refuses some (e.g. product in an open till session): do them one by one.
                for pid in batch:
                    try:
                        self.odoo.kw("product.product", "write", [[pid], {"available_in_pos": False}])
                        hidden += 1
                    except OdooError:
                        refused += 1
        if hidden:
            self.stats["hidden_from_till"] = hidden
        if refused:
            self.stats["could_not_hide_yet"] = refused
        if hide:
            print(f"till: {len(hide)} products are not in a Display Unit; hidden {hidden}, refused by Odoo {refused}")

    def push_stock(self, config: dict, shops: dict, display: dict, only_keys: set | None = None):
        """Set each synced Odoo shop's stock to the Display Store stock of its company
        (or of all companies, summed per barcode, if the shop is linked to "all").
        Uses the in-memory cache; only_keys limits it to changed barcodes."""
        # Display Store stock per company: {companyId: {code: qty}}
        per_company: dict = defaultdict(lambda: defaultdict(int))
        for d in self.cache.products.values():
            company_id = display.get(d.get("storeId"))
            code = code_key(d.get("sku"))
            if company_id is not None and code and (only_keys is None or code in only_keys):
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


class Runner:
    """Keeps the Odoo login, the shop catalog and the Firestore cache between passes."""

    def __init__(self, db, firestore):
        self.db = db
        self.fs = firestore
        self.cache = AppCache(db)
        self.odoo: Odoo | None = None
        self.shops: dict | None = None
        self.last_pull: dt.datetime | None = None
        self.first = True
        self.passes = 0

    def login(self) -> Odoo:
        url = os.environ["ODOO_URL"].strip()
        if "://" not in url:
            url = f"https://{url}"
        odoo_db = (os.environ.get("ODOO_DB") or "").strip() or db_from_url(url)
        return Odoo(url, odoo_db, os.environ["ODOO_LOGIN"].strip(), os.environ["ODOO_API_KEY"].strip())

    def run_once(self) -> bool:
        db, firestore = self.db, self.fs
        state_ref = db.collection("odooSync").document("state")
        try:
            config = db.collection("odooSync").document("config").get().to_dict() or {}
            if self.last_pull is None:
                st = state_ref.get().to_dict() or {}
                self.last_pull = st.get("lastPullAt") if isinstance(st.get("lastPullAt"), dt.datetime) else None
            if self.odoo is None:
                self.odoo = self.login()
            sync = Sync(db, self.odoo, firestore, self.cache)
            now = sync.now

            full = self.cache.needs_full(now)
            if full or self.shops is None:
                self.shops = sync.write_catalog()
            if self.first:
                sync.diagnose_till()

            if self.first or self.passes % 30 == 0:  # about once an hour
                sync.diagnose_orders(config, self.shops, self.last_pull)
            self.passes += 1

            if config.get("enabled"):
                if full:
                    self.cache.full_load(now)
                    changed = None  # everything
                else:
                    changed = self.cache.incremental(now)
                display = self.cache.display
                sync.stats["display_stores"] = len(display)
                # 1. Till sales first, so the stock sent back to Odoo already includes them.
                sync.pull_sales(config, self.shops, display, self.last_pull)
                self.last_pull = now
                if changed is not None:
                    changed |= self.cache.retry_keys
                self.cache.retry_keys = set()
                # 2. Products (name, price, on/off the till when out of stock), 3. stock levels.
                if config.get("syncProducts", True) and (changed is None or changed):
                    sync.push_products(display, changed)
                if config.get("pushEnabled", True) and (changed is None or changed):
                    sync.push_stock(config, self.shops, display, changed)

            state_ref.set({
                "lastRunAt": firestore.SERVER_TIMESTAMP,
                "lastOkAt": firestore.SERVER_TIMESTAMP,
                "lastPullAt": self.last_pull,
                "lastError": "",
                "lastStats": dict(sync.stats),
            }, merge=True)
            self.first = False
            summary = ", ".join(f"{k}={v}" for k, v in sorted(sync.stats.items())) or "nothing new"
            stamp = dt.datetime.now(dt.timezone.utc).strftime("%H:%M:%S")
            print(f"{stamp} OK: sync {'ON' if config.get('enabled') else 'OFF (turn it on in the app: Profile > Odoo sync)'}; {summary}", flush=True)
            return True
        except Exception as e:  # noqa: BLE001 - report any failure to the app
            self.odoo = None  # log in again next pass
            quota = "ResourceExhausted" in type(e).__name__ or "Quota exceeded" in str(e)
            msg = ("Firebase free daily limit reached – the sync waits until it resets" if quota
                   else f"{type(e).__name__}: {e}")[:500]
            try:
                state_ref.set({"lastRunAt": firestore.SERVER_TIMESTAMP, "lastError": msg}, merge=True)
            except Exception:  # noqa: BLE001
                pass
            print("FAILED:", "Firebase daily quota exceeded" if quota else type(e).__name__, flush=True)
            if not quota:
                traceback.print_exc(limit=3)
            return False


def newer_code_pushed() -> bool:
    """True when a newer version of this program is on GitHub: the run then ends early and
    the workflow starts the next run, which uses the new code. Checked every ~10 minutes."""
    import subprocess
    import time

    global _last_code_check
    sha, repo = os.environ.get("GITHUB_SHA"), os.environ.get("GITHUB_REPOSITORY")
    branch = os.environ.get("GITHUB_REF_NAME", "main")
    if not sha or not repo or time.monotonic() - _last_code_check < 600:
        return False
    _last_code_check = time.monotonic()
    try:
        out = subprocess.run(["git", "ls-remote", f"https://github.com/{repo}.git", f"refs/heads/{branch}"],
                             capture_output=True, text=True, timeout=30).stdout.split()
        if out and out[0] != sha:
            print("newer sync code found on GitHub: restarting with it", flush=True)
            return True
    except Exception:  # noqa: BLE001
        pass
    return False


_last_code_check = __import__("time").monotonic()


def main() -> int:
    """Runs the sync repeatedly: every SYNC_INTERVAL_SECONDS for SYNC_LOOP_MINUTES. The GitHub
    workflow then starts the next run itself."""
    import time

    import firebase_admin
    from firebase_admin import credentials, firestore

    sa = json.loads(os.environ["FIREBASE_SERVICE_ACCOUNT"])
    firebase_admin.initialize_app(credentials.Certificate(sa))
    runner = Runner(firestore.client(), firestore)

    loop_seconds = float(os.environ.get("SYNC_LOOP_MINUTES", "0")) * 60
    interval = float(os.environ.get("SYNC_INTERVAL_SECONDS", "120"))
    end = time.monotonic() + loop_seconds
    ok_any = False
    failures = 0
    while True:
        started = time.monotonic()
        ok = runner.run_once()
        ok_any = ok or ok_any
        failures = 0 if ok else failures + 1
        if time.monotonic() + interval > end or newer_code_pushed():
            break
        # Back off after repeated failures (e.g. quota reached): up to 30 minutes.
        wait = interval if failures < 2 else min(1800.0, interval * (2 ** (failures - 1)))
        time.sleep(max(5.0, wait - (time.monotonic() - started)))
    return 0 if ok_any else 1


if __name__ == "__main__":
    sys.exit(main())
