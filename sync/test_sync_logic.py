"""Offline checks for the sync logic (no Odoo or Firebase needed): python sync/test_sync_logic.py"""
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import odoo_sync as s

# ---- pure helpers ----
lines = [
    {"order_id": [1, "Shop/0001"], "product_id": [10, "Cream"], "qty": 2},
    {"order_id": [1, "Shop/0001"], "product_id": [10, "Cream"], "qty": 1},
    {"order_id": [1, "Shop/0001"], "product_id": [11, "Mascara"], "qty": 1},
    {"order_id": [2, "Shop/0002"], "product_id": [10, "Cream"], "qty": -1},  # refund
]
g = s.group_lines(lines)
assert g == {(1, 10): 3, (1, 11): 1, (2, 10): -1}, g
assert s.stock_after_sale(10, 3) == (7, False)
assert s.stock_after_sale(2, 5) == (0, True)
assert s.stock_after_sale(4, -1) == (5, False)  # refund adds back
assert s.plan_push({1: 5, 2: 3, 3: 0}, {1: 5.0, 2: 4.0}) == {2: 3}  # 3 has no quant but 0 == 0
assert s.plan_push({4: 7}, {}) == {4: 7}
assert s.m2o_id(False) is None and s.m2o_id([5, "x"]) == 5
assert s.is_display_store(" Display Store ") and s.is_display_store("display store") and not s.is_display_store("Warehouse")
A = {"ref": "a", "companyId": "acme"}
B = {"ref": "b", "companyId": "nivea"}
assert s.choose_target([A], "all") == (A, "")
assert s.choose_target([A], None) == (A, "")
assert s.choose_target([A, B], "nivea") == (B, "")
assert s.choose_target([A, B], "all")[0] is None and "several" in s.choose_target([A, B], "all")[1]
assert s.choose_target([], "all") == (None, "not found in any Display Store")
assert s.choose_target([A], "nivea")[0] is None
assert {"0123456789012", "123456789012"} <= s.code_variants("123456789012")
assert "123456789012" in s.code_variants("0123456789012")
assert s.code_key("0123456789012") == s.code_key("123456789012")
assert s.code_variants("AC-001") == {"AC-001"}
assert s.code_variants("") == set()
print("helpers OK")

# ---- JSON-RPC client against a fake Odoo ----
calls = []
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        p = body["params"]; calls.append(p)
        if p["service"] == "common":
            result = 7 if p["args"][2] == "good-key" else False
        elif p["args"][3] == "fail.model":
            out = {"jsonrpc": "2.0", "id": body["id"], "error": {"message": "Odoo Server Error", "data": {"message": "Access denied"}}}
            return self._send(out)
        else:
            result = [{"id": 1, "name": "Main shop"}]
        self._send({"jsonrpc": "2.0", "id": body["id"], "result": result})
    def _send(self, out):
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(data)

srv = HTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{srv.server_port}"
try:
    s.Odoo(url, "db", "me@x.com", "bad-key"); raise SystemExit("bad key should fail")
except s.OdooError as e:
    assert "login failed" in str(e)
o = s.Odoo(url, "db", "me@x.com", "good-key")
assert o.uid == 7
assert o.search_read("pos.config", [], ["id", "name"]) == [{"id": 1, "name": "Main shop"}]
last = calls[-1]
assert last["service"] == "object" and last["method"] == "execute_kw"
assert last["args"][:6] == ["db", 7, "good-key", "pos.config", "search_read", [[]]] and last["args"][6] == {"fields": ["id", "name"]}
try:
    o.kw("fail.model", "read", [[1]]); raise SystemExit("should raise")
except s.OdooError as e:
    assert str(e) == "Access denied"
srv.shutdown()
print("JSON-RPC client OK")
