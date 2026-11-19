"""Export every product from Firestore to an Excel file on your computer.

Columns: SKU / barcode, product name, company, store, quantity, cost, wholesale and retail price.

How to run (on your Mac, in VS Code's terminal):
    pip3 install firebase-admin openpyxl
    python3 tools/export_products.py ~/Downloads/service-account.json

The file is saved as  products_export_<date>.xlsx  next to where you ran it.
The service-account key gives full access to your database: keep it on your computer,
never put it in this project folder or on GitHub.

Reads used: about 2 per product (well inside the free 50,000 a day).
"""
import datetime as dt
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: python3 tools/export_products.py <path to service-account .json>")
        return 1
    key = Path(sys.argv[1]).expanduser()
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
        rows.append([
            str(d.get("sku") or ""),
            d.get("name", ""),
            companies.get(d.get("companyId", ""), ""),
            stores.get(d.get("storeId", ""), ""),
            int(d.get("quantity") or 0),
            num(pr.get("cost")),
            num(pr.get("wholesale")),
            num(d.get("retailPrice", d.get("price"))),
        ])
    rows.sort(key=lambda r: (r[2].lower(), r[3].lower(), r[1].lower()))

    wb = Workbook()
    ws = wb.active
    ws.title = "Products"
    headers = ["SKU / Barcode", "Product", "Company", "Store", "Quantity",
               "Cost price (QAR)", "Wholesale price (QAR)", "Retail price (QAR)"]
    ws.append(headers)
    for c in ws[1]:
        c.font = Font(bold=True)
    for r in rows:
        ws.append(r)
    for row in ws.iter_rows(min_row=2):
        row[0].number_format = "@"  # keep barcodes as text (no 8.8E+12, no lost leading 0)
        for c in row[5:8]:
            c.number_format = "#,##0.00"
    for i, w in enumerate([18, 45, 20, 18, 10, 16, 20, 18], start=1):
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = ws.dimensions

    out = Path(f"products_export_{dt.date.today():%Y-%m-%d}.xlsx").resolve()
    wb.save(out)
    print(f"Done: {len(rows)} products saved to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
