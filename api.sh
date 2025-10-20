#!/bin/bash
# ZI One-Time Key API — installer/repair/uninstaller
# Endpoints: /api/health, /api/generate, /api/consume   +  /admin (simple UI)
# Usage:
#   sudo bash api.sh --install --secret="changeme" --port=8088
#   sudo bash api.sh --status | --logs | --restart | --uninstall
set -euo pipefail

# ---------- Defaults ----------
SECRET="changeme"
PORT="8088"
DB="/var/lib/zi-keyapi/keys.db"
BIND="0.0.0.0"
APPDIR="/opt/zi-keyapi"
ENVF="/etc/default/zi-keyapi"
UNIT="/etc/systemd/system/zi-keyapi.service"

# ---------- Parse args ----------
ACTION=""
for a in "$@"; do
  case "$a" in
    --install) ACTION="install" ;;
    --uninstall) ACTION="uninstall" ;;
    --restart) ACTION="restart" ;;
    --status) ACTION="status" ;;
    --logs) ACTION="logs" ;;
    --secret=*) SECRET="${a#*=}" ;;
    --port=*)   PORT="${a#*=}" ;;
    --db=*)     DB="${a#*=}" ;;
    --bind=*)   BIND="${a#*=}" ;;
    *) ;;
  esac
done
[ -z "${ACTION}" ] && ACTION="install"

# ---------- Helpers ----------
die(){ echo -e "\e[1;31m$*\e[0m" >&2; exit 1; }
ok(){ echo -e "\e[1;32m$*\e[0m"; }
info(){ echo -e "\e[1;36m$*\e[0m"; }

write_app_py() {
  mkdir -p "$APPDIR" "$(dirname "$DB")"
  cat >"$APPDIR/app.py" <<'PY'
import os, sqlite3, uuid, datetime
from flask import Flask, request, jsonify, g

ADMIN_SECRET = os.environ.get("ADMIN_SECRET","changeme")
DB_PATH = os.environ.get("DB_PATH","/var/lib/zi-keyapi/keys.db")
BIND = os.environ.get("BIND","0.0.0.0")
PORT = int(os.environ.get("PORT","8088"))

app = Flask(__name__)

def get_db():
    if "db" not in g:
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        g.db = sqlite3.connect(DB_PATH, detect_types=sqlite3.PARSE_DECLTYPES, check_same_thread=False)
        g.db.execute("""CREATE TABLE IF NOT EXISTS keys(
            id TEXT PRIMARY KEY,
            created_at TIMESTAMP NOT NULL,
            expires_at TIMESTAMP,
            used_at TIMESTAMP,
            used_ip TEXT,
            note TEXT
        )""")
        g.db.commit()
    return g.db

@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None: db.close()

@app.get("/api/health")
def health():
    return jsonify({"ok": True})

def is_admin(req): 
    return req.headers.get("X-Admin-Secret","") == ADMIN_SECRET

@app.post("/api/generate")
def generate():
    if not is_admin(request):
        return jsonify({"ok":False, "error":"unauthorized"}), 401
    data = request.get_json(silent=True) or {}
    hours = data.get("expires_in_hours", 24)
    note  = data.get("note")
    key_id = uuid.uuid4().hex
    now = datetime.datetime.utcnow()
    exp = now + datetime.timedelta(hours=int(hours)) if hours else None
    db = get_db()
    db.execute("INSERT INTO keys(id,created_at,expires_at,used_at,used_ip,note) VALUES(?,?,?,?,?,?)",
               (key_id, now, exp, None, None, note))
    db.commit()
    return jsonify({"ok": True, "key": key_id, "expires_at": exp.isoformat() if exp else None, "note": note})

@app.post("/api/consume")
def consume():
    data = request.get_json(silent=True) or {}
    key_id = data.get("key")
    if not key_id:
        return jsonify({"ok":False, "error":"missing_key"}), 400
    db=get_db()
    row = db.execute("SELECT id, expires_at, used_at FROM keys WHERE id=?", (key_id,)).fetchone()
    if not row:
        return jsonify({"ok":False, "error":"invalid"}), 400
    _, expires_at, used_at = row
    now = datetime.datetime.utcnow()
    if used_at is not None:
        return jsonify({"ok":False, "error":"already_used"}), 409
    if expires_at is not None:
        if isinstance(expires_at, str):
            expires_at = datetime.datetime.fromisoformat(expires_at)
        if now > expires_at:
            return jsonify({"ok":False, "error":"expired"}), 410
    db.execute("UPDATE keys SET used_at=?, used_ip=? WHERE id=? AND used_at IS NULL",
               (now, request.remote_addr, key_id))
    db.commit()
    return jsonify({"ok":True,"msg":"consumed"})

# very small admin UI
@app.get("/admin")
def admin_page():
    return """
<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>
<title>One-Time Key Admin</title>
<style>body{font-family:system-ui,Segoe UI,Roboto;max-width:760px;margin:40px auto;padding:0 16px}
input,button{font-size:16px;padding:8px;margin:6px 0}pre{background:#f6f8fa;padding:12px;border-radius:8px}</style>
<h2>Generate One-Time Key</h2>
<input id=sec type=password placeholder="Admin Secret (X-Admin-Secret)">
<input id=hrs type=number min=0 step=1 placeholder="Expires in hours (0=no expiry)">
<input id=note type=text placeholder="Note (optional)">
<button onclick="gen()">Generate</button>
<pre id=out>Ready.</pre>
<script>
async function gen(){
  const sec=document.getElementById('sec').value;
  const hrs=parseInt(document.getElementById('hrs').value||'');
  const note=document.getElementById('note').value||null;
  const body={}; if(!isNaN(hrs)) body.expires_in_hours=hrs; if(note) body.note=note;
  const r=await fetch('/api/generate',{method:'POST',headers:{'Content-Type':'application/json','X-Admin-Secret':sec},body:JSON.stringify(body)});
  document.getElementById('out').textContent=await r.text();
}
</script>"""

if __name__ == "__main__":
    app.run(host=BIND, port=PORT)
PY
  chmod 644 "$APPDIR/app.py"
}

write_unit() {
  cat >"$UNIT" <<EOF
[Unit]
Description=ZI One-Time Key API
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=-$ENVF
WorkingDirectory=$APPDIR
ExecStart=/usr/bin/python3 $APPDIR/app.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

write_env() {
  mkdir -p "$(dirname "$ENVF")" "$(dirname "$DB")"
  cat >"$ENVF" <<EOF
ADMIN_SECRET=$SECRET
PORT=$PORT
DB_PATH=$DB
BIND=$BIND
EOF
  chmod 600 "$ENVF"
}

install_pkgs() {
  apt-get update -y >/dev/null
  apt-get install -y python3 python3-flask sqlite3 curl ca-certificates >/dev/null
}

start_service() {
  systemctl daemon-reload
  systemctl enable --now zi-keyapi.service
}

# ---------- Actions ----------
case "$ACTION" in
  install)
    info "Installing/repairing ZI One-Time Key API…"
    install_pkgs
    write_app_py
    write_env
    write_unit
    start_service
    sleep 1
    systemctl --no-pager -l status zi-keyapi.service || true
    echo
    ok "=== zi-keyapi Installed/Updated ==="
    echo "Admin Secret : $SECRET"
    echo "Port        : $PORT (bind $BIND)"
    echo "DB          : $DB"
    echo "Admin UI    : http://<SERVER_IP>:$PORT/admin"
    echo
    echo "Quick test:"
    echo "  curl -s http://127.0.0.1:$PORT/api/health"
    echo "  curl -s -X POST http://127.0.0.1:$PORT/api/generate -H 'Content-Type: application/json' -H 'X-Admin-Secret: $SECRET'"
    ;;
  restart)
    systemctl restart zi-keyapi.service
    systemctl --no-pager -l status zi-keyapi.service
    ;;
  status)
    systemctl --no-pager -l status zi-keyapi.service
    ;;
  logs)
    journalctl -u zi-keyapi.service -n 200 --no-pager
    ;;
  uninstall)
    systemctl disable --now zi-keyapi.service 2>/dev/null || true
    rm -f "$UNIT" "$ENVF"
    systemctl daemon-reload
    ok "Removed service. App dir kept at $APPDIR (delete manually if you wish)."
    ;;
esac
