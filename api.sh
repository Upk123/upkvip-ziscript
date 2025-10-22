#!/bin/bash
# ZI One-Time Key API (Login UI) — rewritten single-file installer
# Author: UPK helper
# Usage:
#   sudo bash api.sh --install [--port=8088 --user=admin --pass=pass --secret=changeme --logo=URL]
#   sudo bash api.sh --status | --logs | --restart | --uninstall

set -euo pipefail

# ===== Defaults =====
SECRET="changeme"
PORT="8088"
DB="/var/lib/upkapi/keys.db"
BIND="0.0.0.0"
APPDIR="/opt/zi-keyapi"
ENVF="/etc/default/zi-keyapi"
UNIT="/etc/systemd/system/zi-keyapi.service"
LOGO_URL="https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png"

CLI_USER=""
CLI_PASS=""
ACTION=""

log(){ printf "\033[1;32m[+] \033[0m%s\n" "$*"; }
warn(){ printf "\033[1;33m[!] \033[0m%s\n" "$*"; }
die(){ printf "\033[1;31m[x] \033[0m%s\n" "$*"; exit 1; }

# ===== Parse args =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) ACTION="install"; shift;;
    --status) ACTION="status"; shift;;
    --logs) ACTION="logs"; shift;;
    --restart) ACTION="restart"; shift;;
    --uninstall) ACTION="uninstall"; shift;;
    --secret=*) SECRET="${1#*=}"; shift;;
    --port=*) PORT="${1#*=}"; shift;;
    --user=*) CLI_USER="${1#*=}"; shift;;
    --pass=*) CLI_PASS="${1#*=}"; shift;;
    --logo=*) LOGO_URL="${1#*=}"; shift;;
    --db=*) DB="${1#*=}"; shift;;
    --bind=*) BIND="${1#*=}"; shift;;
    *) die "Unknown argument: $1";;
  esac
done

need_root(){ [[ $(id -u) -eq 0 ]] || die "Run as root (sudo)."; }

ensure_deps(){
  log "Installing dependencies..."
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip curl jq
}

write_env(){
  log "Writing environment file: $ENVF"
  mkdir -p "$(dirname "$ENVF")" /var/lib/upkapi
  # Keep existing APP_SECRET_KEY if present, else generate
  local APP_SECRET
  if [[ -f "$ENVF" ]] && grep -q '^APP_SECRET_KEY=' "$ENVF"; then
    APP_SECRET=$(grep '^APP_SECRET_KEY=' "$ENVF" | sed 's/APP_SECRET_KEY=//')
  else
    APP_SECRET=$(python3 - <<'PY'
import secrets; print(secrets.token_hex(32))
PY
)
  fi

  # If ENV already has ADMIN_/LOGIN_ creds and user didn't pass CLI creds, preserve them
  local EXIST_USER="" EXIST_PASS=""
  if [[ -f "$ENVF" ]]; then
    EXIST_USER=$( (grep -E '^(ADMIN_USER|LOGIN_USER)=' "$ENVF" || true) | tail -n1 | cut -d= -f2- )
    EXIST_PASS=$( (grep -E '^(ADMIN_PASS|LOGIN_PASS)=' "$ENVF" || true) | tail -n1 | cut -d= -f2- )
  fi

  local FINAL_USER="${CLI_USER:-${EXIST_USER:-admin}}"
  local FINAL_PASS="${CLI_PASS:-${EXIST_PASS:-pass}}"

  cat > "$ENVF" <<EOF
# Managed by api.sh
ADMIN_SECRET=${SECRET}
PORT=${PORT}
DB_PATH=${DB}
BIND=${BIND}
LOGO_URL=${LOGO_URL}
APP_SECRET_KEY=${APP_SECRET}
# Prefer ADMIN_* and keep LOGIN_* for backward compatibility
ADMIN_USER=${FINAL_USER}
ADMIN_PASS=${FINAL_PASS}
LOGIN_USER=${FINAL_USER}
LOGIN_PASS=${FINAL_PASS}
EOF
}

write_app(){
  log "Writing application to $APPDIR"
  install -d "$APPDIR"

  # Python app
  cat > "$APPDIR/app.py" <<'PY'
#!/usr/bin/env python3
import os
from flask import Flask, request, redirect, session, make_response

# --- Config from env ---
PORT = int(os.environ.get("PORT", "8088"))
BIND = os.environ.get("BIND", "0.0.0.0")
LOGO_URL = os.environ.get("LOGO_URL", "")
ADMIN_SECRET = os.environ.get("ADMIN_SECRET", "changeme")

# Back/forward compatible env names for credentials
LOGIN_USER = os.environ.get("ADMIN_USER") or os.environ.get("LOGIN_USER", "admin")
LOGIN_PASS = os.environ.get("ADMIN_PASS") or os.environ.get("LOGIN_PASS", "pass")

app = Flask(__name__)
app.secret_key = os.environ.get("APP_SECRET_KEY", "dev-secret-override-me")

HTML_HEAD = """<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Admin Login</title>
<style>
:root{--bg:#0b1220;--card:#0f172a;--bd:#26324b;--fg:#e5edf7;--muted:#9fb4d1;
--brand:#4f46e5;--brand2:#0ea5e9}
*{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--fg);font-family:ui-sans-serif,system-ui,Segoe UI,Roboto,Arial}
.card{width:min(92vw,380px);background:var(--card);border:1px solid var(--bd);border-radius:20px;
padding:22px;box-shadow:0 12px 40px rgba(0,0,0,.35);text-align:center;margin:8vh auto}
.logo{width:110px;height:110px;border-radius:22px;object-fit:cover;display:block;margin:6px auto 12px;box-shadow:0 8px 26px rgba(0,0,0,.35)}
h2{margin: 0 0 16px;font-size:1.35rem}
input{width:100%;height:46px;border:1px solid var(--bd);border-radius:12px;padding:10px;margin:8px 0;background:transparent;color:inherit;font-size:1rem}
button{width:100%;height:48px;border:0;border-radius:12px;background:linear-gradient(108deg,var(--brand),var(--brand2));color:#fff;font-weight:800;margin-top:6px}
.err{color:#f87171;margin-bottom:8px}
a, a:visited{color:#9ecbff;text-decoration:none}
.footer{opacity:.6;font-size:.85rem;margin-top:14px}
</style></head><body>
"""

HTML_FOOT = """<div class="footer">© ZI Key API</div></body></html>"""

def render_login(err=None):
    body = ['<div class="card">']
    if LOGO_URL:
        body.append(f'<img class="logo" src="{LOGO_URL}" alt="logo">')
    body.append("<h2>Admin Login</h2>")
    if err:
        body.append(f'<div class="err">{err}</div>')
    body.append('<form method="post">')
    body.append('<input name="username" placeholder="Username" required>')
    body.append('<input name="password" type="password" placeholder="Password" required>')
    body.append('<button type="submit">Login</button>')
    body.append('</form></div>')
    return HTML_HEAD + "".join(body) + HTML_FOOT

@app.route("/login", methods=["GET","POST"])
def login():
    if request.method == "GET":
        return render_login()
    u = request.form.get("username","")
    p = request.form.get("password","")
    if u == LOGIN_USER and p == LOGIN_PASS:
        session["auth"] = True
        return redirect("/")
    return render_login("Invalid credentials")

@app.route("/logout")
def logout():
    session.clear()
    return redirect("/login")

def require_auth():
    return session.get("auth") is True

@app.route("/")
def home():
    if not require_auth():
        return redirect("/login")
    html = HTML_HEAD + f"""
    <div class="card">
      {'<img class="logo" src=\"'+LOGO_URL+'\" alt=\"logo\">' if LOGO_URL else ''}
      <h2>Dashboard</h2>
      <p>Welcome, <b>{LOGIN_USER}</b> ✅</p>
      <p><a href="/logout">Logout</a></p>
    </div>
    """ + HTML_FOOT
    return html

@app.route("/api/health")
def health():
    return {"ok": True}

# Example protected API (needs ADMIN_SECRET in header)
@app.route("/api/generate", methods=["POST"])
def generate():
    if request.headers.get("X-Admin-Secret") != ADMIN_SECRET:
        return {"error":"forbidden"}, 403
    # TODO: generate key into DB if you add that later
    return {"status":"ok","note":"stub"}

if __name__ == "__main__":
    app.run(host=BIND, port=PORT)
PY
  chmod +x "$APPDIR/app.py"

  # Python venv + deps
  if [[ ! -d "$APPDIR/venv" ]]; then
    log "Creating virtualenv..."
    python3 -m venv "$APPDIR/venv"
  fi
  log "Installing Flask..."
  "$APPDIR/venv/bin/pip" install --upgrade pip >/dev/null
  "$APPDIR/venv/bin/pip" install flask >/dev/null
}

write_unit(){
  log "Writing systemd unit: $UNIT"
  cat > "$UNIT" <<EOF
[Unit]
Description=ZI One-Time Key API (Login UI)
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=$ENVF
WorkingDirectory=$APPDIR
ExecStart=$APPDIR/venv/bin/python $APPDIR/app.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

do_install(){
  need_root
  ensure_deps
  write_env
  write_app
  write_unit
  log "Enabling & starting service..."
  systemctl enable zi-keyapi.service
  systemctl restart zi-keyapi.service
  sleep 1
  systemctl --no-pager --full status zi-keyapi.service || true
  log "Health check:"
  set +e
  curl -sS "http://127.0.0.1:${PORT}/api/health" || true
  echo
  set -e
  log "Done. Open: http://<YOUR_SERVER_IP>:${PORT}/login"
}

do_status(){ systemctl --no-pager --full status zi-keyapi.service; }
do_logs(){ journalctl -u zi-keyapi.service -n 200 --no-pager; }
do_restart(){ systemctl restart zi-keyapi.service && log "Restarted."; }
do_uninstall(){
  need_root
  systemctl stop zi-keyapi.service || true
  systemctl disable zi-keyapi.service || true
  rm -f "$UNIT"
  systemctl daemon-reload
  warn "Service removed. App dir & env left in place:"
  echo " - $APPDIR"
  echo " - $ENVF"
  echo "Remove them manually if you want."
}

case "${ACTION:-}" in
  install) do_install;;
  status) do_status;;
  logs) do_logs;;
  restart) do_restart;;
  uninstall) do_uninstall;;
  *) cat <<USAGE
Usage:
  sudo bash api.sh --install [--port=8088 --user=admin --pass=pass --secret=changeme --logo=URL]
  sudo bash api.sh --status | --logs | --restart | --uninstall
USAGE
     ;;
esac
