"""Offline test of the in-memory cache: checks that passes after the first one read
almost nothing from Firestore. Run:  cd sync && python3 test_cache.py"""
import datetime as dt

from odoo_sync import AppCache, Sync, code_key

T0 = dt.datetime(2026, 11, 1, 8, 0, tzinfo=dt.timezone.utc)
OLD = T0 - dt.timedelta(days=1)


class Snap:
    def __init__(self, id, data):
        self.id, self._d = id, data
        self.exists = data is not None

    def to_dict(self):
        return dict(self._d) if self._d is not None else None


class Query:
    def __init__(self, db, col, filters=()):
        self.db, self.col, self.filters = db, col, list(filters)

    def where(self, filter):
        return Query(self.db, self.col, self.filters + [filter])

    def stream(self):
        out = []
        for id, d in self.db.data.get(self.col, {}).items():
            ok = True
            for f in self.filters:
                v = d.get(f.field_path)
                if f.op_string == "==":
                    ok &= v == f.value
                elif f.op_string == ">=":
                    ok &= v is not None and v >= f.value
            if ok:
                out.append(Snap(id, d))
        self.db.reads += max(1, len(out))  # Firestore bills at least 1 read per query
        return iter(out)

    def document(self, id):
        return Doc(self.db, self.col, id)


class Doc:
    def __init__(self, db, col, id):
        self.db, self.col, self.id = db, col, id

    def get(self):
        self.db.reads += 1
        return Snap(self.id, self.db.data.get(self.col, {}).get(self.id))


class FakeDb:
    def __init__(self, data):
        self.data, self.reads = data, 0

    def collection(self, col):
        return Query(self, col)

    def get_all(self, refs):
        for r in refs:
            self.reads += 1
            yield Snap(r.id, self.data.get(r.col, {}).get(r.id))


def make_data(n=400):
    data = {
        "companies": {"c1": {"name": "Abib", "updatedAt": OLD}, "c2": {"name": "Cosrx", "updatedAt": OLD}},
        "stores": {
            "s1": {"name": "Display Store", "companyId": "c1", "updatedAt": OLD},
            "s2": {"name": "Storage Unit A", "companyId": "c1", "updatedAt": OLD},
            "s3": {"name": "Display Unit", "companyId": "c2", "updatedAt": OLD},
        },
        "products": {},
        "productPrices": {},
    }
    for i in range(n):
        store = ["s1", "s2", "s3"][i % 3]
        cid = data["stores"][store]["companyId"]
        data["products"][f"p{i}"] = {"name": f"P{i}", "sku": f"0{880000000000 + i}", "storeId": store,
                                     "companyId": cid, "quantity": 5, "retailPrice": 10, "updatedAt": OLD}
        data["productPrices"][f"p{i}"] = {"cost": 4, "updatedAt": OLD}
    return data


def main():
    db = FakeDb(make_data())
    cache = AppCache(db)
    cache.full_load(T0)
    display_products = sum(1 for p in db.data["products"].values() if p["storeId"] in ("s1", "s3"))
    assert len(cache.products) == display_products, (len(cache.products), display_products)
    assert set(cache.display) == {"s1", "s3"}
    full_reads = db.reads
    assert full_reads < 2 * display_products + 20, full_reads

    # A quiet pass: only the 4 "what changed" queries.
    db.reads = 0
    assert cache.incremental(T0 + dt.timedelta(minutes=10)) == set()
    assert db.reads <= 4, db.reads

    # A sale/edit in the app: only that product is re-read and reported as changed.
    db.data["products"]["p0"].update(quantity=3, updatedAt=T0 + dt.timedelta(minutes=11))
    db.reads = 0
    changed = cache.incremental(T0 + dt.timedelta(minutes=12))
    assert changed == {code_key("0880000000000")}, changed
    assert cache.products["p0"]["quantity"] == 3
    assert db.reads <= 5, db.reads

    # Moving a product out of the Display Store removes it from the cache.
    db.data["products"]["p3"].update(storeId="s2", updatedAt=T0 + dt.timedelta(minutes=13))
    cache.incremental(T0 + dt.timedelta(minutes=14))
    assert "p3" not in cache.products

    # Renaming a store to "Display ..." makes the cache reload everything.
    db.data["stores"]["s2"].update(name="Display Shelf", updatedAt=T0 + dt.timedelta(minutes=15))
    cache.incremental(T0 + dt.timedelta(minutes=16))
    assert "s2" in cache.display and "p3" in cache.products

    # Till sale lookup comes from the cache (no Firestore query).
    sync = Sync(db, odoo=None, firestore_mod=None, cache=cache)
    db.reads = 0
    found = sync.find_candidates(["880000000000"], cache.display)  # leading zero dropped by the till
    assert [f["ref"].id for f in found] == ["p0"], found
    assert db.reads == 0
    assert cache.needs_full(T0 + dt.timedelta(hours=7)) and not cache.needs_full(T0 + dt.timedelta(hours=1))

    passes_per_day = 24 * 30  # every 2 minutes
    print(f"cache OK (full load {full_reads} reads; quiet pass <=4 reads -> ~{passes_per_day * 5} reads/day + ~5 full loads)")


if __name__ == "__main__":
    main()
