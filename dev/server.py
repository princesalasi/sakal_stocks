"""Local test stand-in for Supabase (no internet needed).

Serves the app from the repo folder and answers POST /rest/v1/rpc/<fn> by calling the
same SQL functions in a local Postgres as role "anon" - exactly like Supabase does.
/config.js is replaced so the page talks to this server instead of the real database.

Usage (from the repo root):
  dev/reset_db.sh            # fresh local database from setup.sql (first admin: Prince / 1234)
  python3 dev/server.py 8780 # then open http://localhost:8780/
"""
import http.server, json, os, re, subprocess, sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8780
DB = os.environ.get("PGDATABASE", "sakal_test")
PSQL = ["psql", "-h", os.environ.get("PGHOST", "/tmp/pg"), "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-d", DB]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def lit(v):
    if v is None: return "NULL"
    if isinstance(v, bool): return "true" if v else "false"
    return "'" + str(v).replace("'", "''") + "'"

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(s, *a, **k): super().__init__(*a, directory=ROOT, **k)
    def log_message(s, *a): pass
    def do_GET(s):
        if s.path.split("?")[0] == "/config.js":
            body = ('window.SAKAL_CONFIG = { url: "http://localhost:%d", key: "sb_publishable_local_test" };\n' % PORT).encode()
            s.send_response(200); s.send_header("Content-Type", "text/javascript"); s.end_headers(); s.wfile.write(body); return
        super().do_GET()
    def do_POST(s):
        m = re.match(r"^/rest/v1/rpc/([a-z_]+)$", s.path)
        body = json.loads(s.rfile.read(int(s.headers.get("Content-Length", 0))) or b"{}")
        if not m or not s.headers.get("apikey"):
            s.send_response(401); s.end_headers(); return
        args = ", ".join(f"{k} => {lit(v)}" for k, v in body.items() if re.match(r"^p_[a-z_0-9]+$", k))
        r = subprocess.run(PSQL + ["-At", "-v", "ON_ERROR_STOP=1", "-c", f"set role anon; select public.{m.group(1)}({args})::text;"], capture_output=True, text=True)
        if r.returncode:
            msg = re.search(r"ERROR:\s+(.*)", r.stderr); out, code = json.dumps({"message": msg.group(1) if msg else r.stderr}), 400
        else:
            lines = r.stdout.strip().splitlines()
            if lines and lines[0] == "SET": lines = lines[1:]
            out, code = "\n".join(lines), 200
        s.send_response(code); s.send_header("Content-Type", "application/json"); s.end_headers(); s.wfile.write(out.encode())

print("Serving on http://localhost:%d (database %s)" % (PORT, DB))
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
