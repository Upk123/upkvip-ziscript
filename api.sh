#!/usr/bin/env bash
# api.sh — One-Time Key API (Flask+Gunicorn+systemd)
# All-in-one installer/manager with optional HTTPS (nginx) + UFW rules
# Usage examples:
#   sudo bash api.sh --install --secret="SuperSecret" --port=8088
#   sudo bash api.sh --status
#   sudo bash api.sh --logs
#   sudo bash api.sh --generate=24
#   sudo bash api.sh --enable-https --domain=keys.example.com  # needs DNS A record -> this VPS
#   sudo bash api.sh --enable-ufw
#   sudo bash api.sh --uninstall

set -euo pipefail

SERVICE_NAME="zi-keyapi"
APP_DIR="/opt/keyapi"
APP_FILE="${APP_DIR}/keyapi.py"
VENV_DIR="${APP_DIR}/venv"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="/etc/default/${SERVICE_NAME}"

SECRET="changeme"
PORT="8088"
DB_PATH="/var/lib/keyapi/keys.db"
DEFAULT_EXP_HOURS="24"
BIND="0.0.0.0"     # change to 127.0.0.1 if putting behind nginx
DOMAIN=""
ACTION="install"
GEN_HOURS=""
ENABLE_HTTPS=0
ENABLE_UFW=0

# ---------- arg parse ----------
for arg in "$@"; do
  case "$arg" in
    --install) ACTION="install" ;;
    --status) ACTION="status" ;;
    --logs) ACTION="logs" ;;
    --uninstall) ACTION="uninstall" ;;
    --generate) ACTION="generate" ;;
    --generate=*) ACTION="generate"; GEN_HOURS="${arg#*=}" ;;
    --secret=*) SECRET="${arg#*=}" ;;
    --port=*) PORT="${arg#*=}" ;;
    --db-path=*) DB_PATH="${arg#*=}" ;;
    --default-exp=*) DEFAULT_EXP_HOURS="${arg#*=}" ;;
    --bind=*) BIND="${arg#*=}" ;;
    --domain=*) DOMAIN="${arg#*=}" ;;
    --enable-https) ENABLE_HTTPS=1 ;;
    --enable-ufw) ENABLE_UFW=1 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root: sudo bash api.sh ..." >&2; exit 1
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y python3-venv python3-pip sqlite3 curl jq ca-certificates
}

write_env() {
  mkdir -p "$(dirname "$ENV_FILE")" "$(dirname "$DB_PATH")"
  cat > "$ENV_FILE" <<EOF
# ${SERVICE_NAME} environment
ADMIN_SECRET="${SECRET}"
DB_PATH="${DB_PATH}"
PORT="${PORT}"
DEFAULT_EXP_HOURS="${DEFAULT_EXP_HOURS}"
BIND="${BIND}"
EOF
  chmod 640 "$ENV_FILE"
  touch "$DB_PATH" || true
}

write_app() {
  mkdir -p "$APP_DIR"
  python3 -m venv "$VENV_DIR"
  "${VENV_DIR}/bin/pip" install --upgrade pip >/dev/null
  "${VENV_DIR}/bin/pip" install flask gunicorn >/dev/null

  # Flask app (API + /admin)
  cat > "$APP_FILE" <<'PYEOF'
import os, sqlite3, uuid, datetime
from flask import Flask, request, jsonify, g, abort

ADMIN_SECRET = os.environ.get("ADMIN_SECRET", "changeme")
DB_PATH = os.environ.get("DB_PATH", "/var/lib/keyapi/keys.db")
DEFAULT_EXP_HOURS = int(os.environ.get("DEFAULT_EXP_HOURS", "24"))

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
        g.db.execute("""CREATE TABLE IF NOT EXISTS logs(
            at TIMESTAMP NOT NULL,
            action TEXT NOT NULL,
            key_id TEXT,
            ip TEXT
        )""")
        g.db.commit()
    return g.db

@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()

def is_admin(req):
    return req.headers.get("X-Admin-Secret", "") == ADMIN_SECRET

def log(action, key_id=None):
    try:
        get_db().execute("INSERT INTO logs VALUES(?,?,?,?)",
            (datetime.datetime.utcnow(), action, key_id, request.remote_addr))
        get_db().commit()
    except Exception:
        pass

@app.post("/api/generate")
def generate_key():
    if not is_admin(request):
        log("unauth_gen_attempt")
        return jsonify({"ok": False, "error": "unauthorized"}), 401
    hours = DEFAULT_EXP_HOURS
    note = None
    if request.is_json:
        hours = request.json.get("expires_in_hours", DEFAULT_EXP_HOURS)
        note = request.json.get("note")
    key_id = uuid.uuid4().hex
    now = datetime.datetime.utcnow()
    exp = now + datetime.timedelta(hours=int(hours)) if hours else None

    db = get_db()
    db.execute("INSERT INTO keys(id,created_at,expires_at,used_at,used_ip,note) VALUES(?,?,?,?,?,?)",
               (key_id, now, exp, None, None, note))
    db.commit()
    log("generate", key_id)
    return jsonify({"ok": True, "key": key_id, "expires_at": exp.isoformat() if exp else None, "note": note})

@app.post("/api/consume")
def consume_key():
    if not request.is_json or "key" not in request.json:
        return jsonify({"ok": False, "error": "missing_key"}), 400
    key_id = request.json["key"]
    db = get_db()
    cur = db.execute("SELECT id, expires_at, used_at FROM keys WHERE id = ?", (key_id,))
    row = cur.fetchone()
    if not row:
        log("consume_invalid", key_id)
        return jsonify({"ok": False, "error": "invalid"}), 400
    _, expires_at, used_at = row
    now = datetime.datetime.utcnow()
    if used_at is not None:
        log("consume_used", key_id)
        return jsonify({"ok": False, "error": "already_used"}), 409
    if expires_at is not None:
        if isinstance(expires_at, str):
            try:
                expires_at = datetime.datetime.fromisoformat(expires_at)
            except Exception:
                pass
        if now > expires_at:
            log("consume_expired", key_id)
            return jsonify({"ok": False, "error": "expired"}), 410

    db.execute("UPDATE keys SET used_at=?, used_ip=? WHERE id=? AND used_at IS NULL",
               (now, request.remote_addr, key_id))
    if db.total_changes == 0:
        log("consume_race", key_id)
        return jsonify({"ok": False, "error": "race_conflict"}), 409
    db.commit()
    log("consume_ok", key_id)
    return jsonify({"ok": True, "msg": "consumed"})

@app.get("/api/health")
def health():
    return jsonify({"ok": True})

@app.get("/admin")
def admin_page():
    return """
<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>
<title>One-Time Key Admin</title>
<style>
 body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu;max-width:780px;margin:40px auto;padding:0 16px}
 input,button{font-size:16px;padding:8px;margin:6px 0} pre{background:#f6f8fa;padding:12px;border-radius:8px}
 .row{display:flex;gap:8px;align-items:center}.row input{flex:1}
</style>
<h2>Generate One-Time Key</h2>
<div class=row>
  <input id=sec type=password placeholder="Admin Secret (X-Admin-Secret)">
  <input id=hrs type=number min=0 step=1 placeholder="Expires in hours (0 = no expiry)">
  <input id=note type=text placeholder="Note (optional)">
  <button onclick="gen()">Generate</button>
</div>
<pre id=out>Ready.</pre>
<script>
async function gen(){
  const sec=document.getElementById('sec').value;
  const hrs=parseInt(document.getElementById('hrs').value||'');
  const note=document.getElementById('note').value||null;
  const body={};
  if(!isNaN(hrs)) body.expires_in_hours=hrs;
  if(note) body.note=note;
  const res=await fetch('/api/generate',{method:'POST',headers:{'Content-Type':'application/json','X-Admin-Secret':sec},body:JSON.stringify(body)});
  document.getElementById('out').textContent=await res.text();
}
</script>
"""
PYEOF

  chmod 755 "$APP_DIR" || true
  chmod 644 "$APP_FILE"
}

write_unit() {
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=One-Time Key API (Flask via Gunicorn)
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=-${ENV_FILE}
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_DIR}/bin/gunicorn -w 2 --timeout 30 -b \${BIND:-127.0.0.1}:\${PORT:-8088} keyapi:app
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_service() {
  systemctl enable "${SERVICE_NAME}.service" >/dev/null
  systemctl restart "${SERVICE_NAME}.service"
  sleep 1
}

show_status() { systemctl --no-pager -l status "${SERVICE_NAME}.service" || true; }
tail_logs() { journalctl -u "${SERVICE_NAME}.service" -f; }

enable_https() {
  if [[ -z "$DOMAIN" ]]; then
    echo "Set --domain=YOUR_DOMAIN with public DNS -> this VPS." >&2; exit 2
  fi
  apt-get install -y nginx certbot python3-certbot-nginx
  # bind app to localhost when proxying
  sed -i 's/^BIND=.*/BIND="127.0.0.1"/' "$ENV_FILE" || true
  systemctl restart "${SERVICE_NAME}.service"

  local site="/etc/nginx/sites-available/${SERVICE_NAME}"
  cat > "$site" <<NGX
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${PORT};
    }
    # Simple rate limit for brute-force
    limit_req_zone \$binary_remote_addr zone=one:10m rate=5r/s;
    location /api/consume { limit_req zone=one; proxy_pass http://127.0.0.1:${PORT}/api/consume; }
    location /api/generate { limit_req zone=one; proxy_pass http://127.0.0.1:${PORT}/api/generate; }
}
NGX
  ln -sf "$site" /etc/nginx/sites-enabled/${SERVICE_NAME}
  nginx -t
  systemctl restart nginx
  # Let's Encrypt
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN"
  echo "HTTPS enabled at https://${DOMAIN}"
}

enable_ufw() {
  apt-get install -y ufw
  ufw allow OpenSSH
  if [[ "$ENABLE_HTTPS" -eq 1 || -n "$DOMAIN" ]]; then
    ufw allow 443/tcp
    ufw allow 80/tcp
    # deny app port from public if proxying
    ufw deny "${PORT}"/tcp || true
  else
    # no https: open app port directly
    ufw allow "${PORT}"/tcp
  fi
  ufw --force enable
  ufw status verbose
}

uninstall_all() {
  systemctl stop "${SERVICE_NAME}.service" || true
  systemctl disable "${SERVICE_NAME}.service" || true
  rm -f "$UNIT_FILE"; systemctl daemon-reload
  rm -rf "$APP_DIR"
  echo "Service and app removed. Kept: ${ENV_FILE} and ${DB_PATH}"
}

install_flow() {
  if [[ "$SECRET" == "changeme" ]]; then
    echo "WARNING: Using default --secret=changeme. Set a strong secret with --secret=..." >&2
  fi
  apt_install
  write_env
  write_app
  write_unit
  start_service

  echo
  echo "=== ${SERVICE_NAME} Installed/Updated ==="
  echo "Admin Secret : $SECRET"
  echo "Port         : $PORT (bind ${BIND})"
  echo "DB           : $DB_PATH"
  echo "Default Exp  : ${DEFAULT_EXP_HOURS}h"
  echo "Admin UI     : http://SERVER_IP:${PORT}/admin"
  echo
  show_status

  if [[ "$ENABLE_HTTPS" -eq 1 ]]; then enable_https; fi
  if [[ "$ENABLE_UFW" -eq 1 ]]; then enable_ufw; fi

  echo
  echo "API quick test:"
  echo "curl -s -X GET http://127.0.0.1:${PORT}/api/health"
  echo "curl -s -X POST http://127.0.0.1:${PORT}/api/generate -H 'Content-Type: application/json' -H 'X-Admin-Secret: ${SECRET}'"
}

generate_via_local() {
  if [[ ! -f "$ENV_FILE" ]]; then echo "Env not found: $ENV_FILE (install first)"; exit 1; fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  local body="{}"
  if [[ -n "$GEN_HOURS" ]]; then body="{\"expires_in_hours\": ${GEN_HOURS}}"; fi
  curl -sS -X POST "http://127.0.0.1:${PORT}/api/generate" \
    -H "Content-Type: application/json" \
    -H "X-Admin-Secret: ${ADMIN_SECRET}" \
    -d "$body"
  echo
}

main() {
  require_root
  case "$ACTION" in
    install)   install_flow ;;
    status)    show_status ;;
    logs)      tail_logs ;;
    generate)  generate_via_local ;;
    uninstall) uninstall_all ;;
    *) echo "Unknown action"; exit 2 ;;
  esac
}
main "$@"
