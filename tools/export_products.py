"""Export every product from Firestore to an Excel file on your computer.

Columns: Product name, Barcode, Quantity, Cost price, Wholesale price, Retail price, Storage unit.

How to run (on your Mac, in VS Code's terminal):
    pip3 install firebase-admin openpyxl
    python3 tools/export_products.py        (finds the Firebase key in Downloads)
    python3 tools/export_products.py <path to key .json>

The file is saved as  products_export_<date>.xlsx  next to where you ran it.
The service-account key gives full access to your database: keep it on your computer,
never put it in this project folder or on GitHub.

Reads used: about 2 per product (well inside the free 50,000 a day).
"""
import datetime as dt
import sys
from pathlib import Path


def find_keys():
    """Any service-account key (.json with "type": "service_account") in Downloads, Desktop or Documents."""
    import json

    for folder in ("~/Downloads", "~/Desktop", "~/Documents"):
        for f in Path(folder).expanduser().glob("*.json"):
            try:
                if f.stat().st_size < 20000 and json.loads(f.read_text()).get("type") == "service_account":
                    yield f
            except Exception:  # noqa: BLE001 - not a key file
                continue


def main() -> int:
    if len(sys.argv) >= 2:
        key = Path(sys.argv[1]).expanduser()
    else:
        # No path given: use the newest Firebase key in Downloads.
        found = sorted(find_keys(), key=lambda f: f.stat().st_mtime, reverse=True)
        if not found:
            print("No Firebase key found in Downloads, Desktop or Documents.")
            print("Download it: Firebase console > gear icon > Project settings > Service accounts >")
            print("Generate new private key. Then run this command again.")
            return 1
        key = found[0]
        print(f"Using key: {key.name}")
    if not key.exists():
        print(f"Key file not found: {key}")
        return 1

    try:
        import firebase_admin
        from firebase_admin import credentials, firestore
        from openpyxl import Workbook
        from openpyxl.styles import Font
        from openpyxl.utils import get_column_letter
    except ImportError:
        print("Missing packages. Run:  pip3 install firebase-admin openpyxl")
        return 1

    firebase_admin.initialize_app(credentials.Certificate(str(key)))
    db = firestore.client()

    print("Reading companies and stores…")
    companies = {c.id: (c.to_dict() or {}).get("name", "") for c in db.collection("companies").stream()}
    stores = {s.id: (s.to_dict() or {}).get("name", "") for s in db.collection("stores").stream()}
    print("Reading products…")
    products = [(p.id, p.to_dict() or {}) for p in db.collection("products").stream()]
    print("Reading prices…")
    prices = {pr.id: pr.to_dict() or {} for pr in db.collection("productPrices").stream()}

    def num(v):
        return float(v) if isinstance(v, (int, float)) else None

    rows = []
    for pid, d in products:
        pr = prices.get(pid, {})
        company = companies.get(d.get("companyId", ""), "")
        rows.append((company.lower(), [
            d.get("name", ""),
            str(d.get("sku") or ""),
            int(d.get("quantity") or 0),
            num(pr.get("cost")),
            num(pr.get("wholesale")),
            num(d.get("retailPrice", d.get("price"))),
            stores.get(d.get("storeId", ""), ""),
        ]))
    # Grouped by company, then storage unit, then name.
    rows = [r for _, r in sorted(rows, key=lambda x: (x[0], x[1][6].lower(), x[1][0].lower()))]

    wb = Workbook()
    ws = wb.active
    ws.title = "Products"
    headers = ["Product name", "Barcode", "Quantity", "Cost price (QAR)",
               "Wholesale price (QAR)", "Retail price (QAR)", "Storage unit"]
    ws.append(headers)
    for c in ws[1]:
        c.font = Font(bold=True)
    for r in rows:
        ws.append(r)
    for row in ws.iter_rows(min_row=2):
        row[1].number_format = "@"  # keep barcodes as text (no 8.8E+12, no lost leading 0)
        for c in row[3:6]:
            c.number_format = "#,##0.00"
    for i, w in enumerate([45, 18, 10, 16, 20, 18, 20], start=1):
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = ws.dimensions

    out = Path(f"products_export_{dt.date.today():%Y-%m-%d}.xlsx").resolve()
    wb.save(out)
    print(f"Done: {len(rows)} products saved to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
