#!/bin/bash
# ZI One-Time Key API (Login + Modern UI Version)
# Author: GPT DevLab
# Install: sudo bash api.sh --install --secret="changeme" --port=8088
# Manage:  --status | --logs | --restart | --uninstall

set -euo pipefail

SECRET="changeme"
PORT="8088"
DB="/var/lib/upkapi/keys.db"
BIND="0.0.0.0"
APPDIR="/opt/zi-keyapi"
ENVF="/etc/default/zi-keyapi"
UNIT="/etc/systemd/system/zi-keyapi.service"

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

die(){ echo -e "\e[1;31m$*\e[0m" >&2; exit 1; }
ok(){ echo -e "\e[1;32m$*\e[0m"; }
info(){ echo -e "\e[1;36m$*\e[0m"; }

ask_credentials() {
  echo -e "\n\e[1;33m🔐 Admin Login သတ်မှတ်ပါ:\e[0m"
  read -rp "Admin Username: " ADMIN_USER
  read -rsp "Admin Password: " ADMIN_PASS
  echo
}

write_app_py() {
  mkdir -p "$APPDIR" "$(dirname "$DB")"
  cat >"$APPDIR/app.py" <<'PY'
import os, sqlite3, uuid, datetime
from flask import Flask, request, jsonify, g, session, redirect, url_for, render_template_string

ADMIN_SECRET = os.environ.get("ADMIN_SECRET","changeme")
DB_PATH = os.environ.get("DB_PATH","/var/lib/upkapi/keys.db")
BIND = os.environ.get("BIND","0.0.0.0")
PORT = int(os.environ.get("PORT","8088"))
LOGIN_USER = os.environ.get("ADMIN_USER","admin")
LOGIN_PASS = os.environ.get("ADMIN_PASS","pass")
APP_KEY = os.environ.get("APP_SECRET_KEY","supersecret")

app = Flask(__name__)
app.secret_key = APP_KEY

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

# ---------- Login ----------
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        u = request.form.get("username")
        p = request.form.get("password")
        if u == LOGIN_USER and p == LOGIN_PASS:
            session["auth"] = True
            return redirect("/admin")
        return render_template_string(LOGIN_HTML, error="Invalid credentials")
    return render_template_string(LOGIN_HTML)

@app.before_request
def require_login():
    if request.path.startswith("/admin") and session.get("auth") != True:
        return redirect("/login")

LOGIN_HTML = """
<!doctype html>
<html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>🔐 Login</title>
<style>
body{margin:0;background:#0b1020;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh}
.card{background:rgba(255,255,255,.08);padding:28px;border-radius:20px;max-width:360px;width:90%;box-shadow:0 10px 30px rgba(0,0,0,.4);text-align:center}
.logo{width:100px;height:100px;border-radius:20px;margin-bottom:14px;object-fit:cover}
h2{margin:0 0 18px;font-size:1.4rem}
input{width:100%;padding:12px;margin:8px 0;border-radius:12px;border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.08);color:#fff;font-size:1rem}
button{width:100%;padding:12px;border-radius:12px;border:0;background:linear-gradient(180deg,#3b82f6,#1e40af);color:#fff;font-weight:bold;font-size:1rem;margin-top:10px}
.err{color:#f87171;margin-bottom:10px}
</style></head>
<body>
  <div class="card">
    <img class="logo" src="https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png">
    <h2>Admin Login</h2>
    {% if error %}<div class="err">{{error}}</div>{% endif %}
    <form method="post">
      <input name="username" placeholder="Username" required>
      <input name="password" type="password" placeholder="Password" required>
      <button type="submit">Login</button>
    </form>
  </div>
</body></html>
"""

@app.get("/admin")
def admin_page():
    return "<h1 style='font-family:system-ui'>🔑 Logged in! Use the API to manage keys.</h1>"

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
ADMIN_USER=$ADMIN_USER
ADMIN_PASS=$ADMIN_PASS
APP_SECRET_KEY=$(uuidgen)
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

case "$ACTION" in
  install)
    ask_credentials
    info "📦 Installing ZI One-Time Key API…"
    install_pkgs
    write_app_py
    write_env
    write_unit
    start_service
    sleep 1
    ok "✅ Installation complete!"
    echo "Admin Login: http://<SERVER_IP>:$PORT/login"
    ;;
  restart)
    systemctl restart zi-keyapi.service
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
    ok "✅ Removed service. App dir kept at $APPDIR"
    ;;
esac
