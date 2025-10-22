#!/bin/bash
# ZI One-Time Key API (Login UI) — error-free installer
# - Prompts for admin user/pass if not supplied
# - Auto-detects VPS public IP for final link
# - Installs Flask app + systemd service
# - Uses safe heredocs and no fragile f-strings

set -euo pipefail

# ===== Defaults =====
SECRET="changeme"
PORT="8088"
DB="/var/lib/upkapi/keys.db"
BIND="0.0.0.0"
APPDIR="/opt/zi-keyapi"
ENVF="/etc/default/zi-keyapi"
UNIT="/etc/systemd/system/zi-keyapi.service"
LOGO_URL="https://raw.githubusercontent.com/Upk123/upkvip-ziscript/main/20251018_231111.png"
FORCE_IP=""
CLI_USER=""
CLI_PASS=""
ACTION=""

log(){ printf "\033[1;32m[+] \033[0m%s\n" "$*"; }
warn(){ printf "\033[1;33m[!] \033[0m%s\n" "$*"; }
die(){ printf "\033[1;31m[x] \033[0m%s\n" "$*"; exit 1; }
need_root(){ [[ $(id -u) -eq 0 ]] || die "Run as root (sudo)."; }

# ===== Parse args =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) ACTION="install";;
    --status) ACTION="status";;
    --logs) ACTION="logs";;
    --restart) ACTION="restart";;
    --uninstall) ACTION="uninstall";;
    --secret=*) SECRET="${1#*=}";;
    --port=*) PORT="${1#*=}";;
    --user=*) CLI_USER="${1#*=}";;
    --pass=*) CLI_PASS="${1#*=}";;
    --logo=*) LOGO_URL="${1#*=}";;
    --db=*) DB="${1#*=}";;
    --bind=*) BIND="${1#*=}";;
    --ip=*) FORCE_IP="${1#*=}";;
    *) die "Unknown argument: $1";;
  esac
  shift
done

ensure_deps(){
  log "Installing dependencies…"
  apt-get update -y >/dev/null
  apt-get install -y python3 python3-venv python3-pip curl jq >/dev/null
}

prompt_creds_if_needed(){
  if [[ -z "$CLI_USER" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Choose admin username (default: admin): " tmpu || true
      CLI_USER="${tmpu:-admin}"
    else
      CLI_USER="admin"
    fi
  fi
  if [[ -z "$CLI_PASS" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "Choose admin password (default: pass): " tmpp || true
      echo
      CLI_PASS="${tmpp:-pass}"
    else
      CLI_PASS="pass"
    fi
  fi
}

write_env(){
  log "Writing env: $ENVF"
  mkdir -p "$(dirname "$ENVF")" /var/lib/upkapi
  local APP_SECRET
  if [[ -f "$ENVF" ]] && grep -q '^APP_SECRET_KEY=' "$ENVF"; then
    APP_SECRET=$(sed -n 's/^APP_SECRET_KEY=//p' "$ENVF")
  else
    APP_SECRET=$(python3 - <<'__PY__'
import secrets; print(secrets.token_hex(32))
__PY__
)
  fi
  cat >"$ENVF" <<__EOF__
# Managed by api.sh
ADMIN_SECRET=${SECRET}
PORT=${PORT}
DB_PATH=${DB}
BIND=${BIND}
LOGO_URL=${LOGO_URL}
APP_SECRET_KEY=${APP_SECRET}
ADMIN_USER=${CLI_USER}
ADMIN_PASS=${CLI_PASS}
# Backward compatibility
LOGIN_USER=${CLI_USER}
LOGIN_PASS=${CLI_PASS}
__EOF__
  chmod 640 "$ENVF" || true
}

write_app(){
  log "Writing app → $APPDIR"
  install -d "$APPDIR"
  cat >"$APPDIR/app.py" <<'__PY__'
#!/usr/bin/env python3
import os
from flask import Flask, request, redirect, session

PORT = int(os.environ.get("PORT", "8088"))
BIND = os.environ.get("BIND", "0.0.0.0")
LOGO_URL = os.environ.get("LOGO_URL", "")
ADMIN_SECRET = os.environ.get("ADMIN_SECRET", "changeme")

LOGIN_USER = os.environ.get("ADMIN_USER") or os.environ.get("LOGIN_USER", "admin")
LOGIN_PASS = os.environ.get("ADMIN_PASS") or os.environ.get("LOGIN_PASS", "pass")

app = Flask(__name__)
app.secret_key = os.environ.get("APP_SECRET_KEY", "dev-secret-override-me")

HTML_HEAD = """<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Admin Login</title>
<style>
:root{--bg:#0b1220;--card:#0f172a;--bd:#26324b;--fg:#e5edf7;--muted:#9fb4d1;--brand:#4f46e5;--brand2:#0ea5e9}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font-family:ui-sans-serif,system-ui,Segoe UI,Roboto,Arial}
.card{width:min(92vw,380px);background:var(--card);border:1px solid var(--bd);border-radius:20px;padding:22px;box-shadow:0 12px 40px rgba(0,0,0,.35);text-align:center;margin:8vh auto}
.logo{width:110px;height:110px;border-radius:22px;object-fit:cover;display:block;margin:6px auto 12px;box-shadow:0 8px 26px rgba(0,0,0,.35)}
h2{margin:0 0 16px;font-size:1.35rem}
input{width:100%;height:46px;border:1px solid var(--bd);border-radius:12px;padding:10px;margin:8px 0;background:transparent;color:inherit;font-size:1rem}
button{width:100%;height:48px;border:0;border-radius:12px;background:linear-gradient(108deg,var(--brand),var(--brand2));color:#fff;font-weight:800;margin-top:6px}
.err{color:#f87171;margin-bottom:8px}.footer{opacity:.6;font-size:.85rem;margin-top:14px}
</style></head><body>
"""
HTML_FOOT = """<div class="footer">© ZI Key API</div></body></html>"""

def render_login(err=None):
    parts = ['<div class="card">']
    if LOGO_URL:
        parts.append(f'<img class="logo" src="{LOGO_URL}" alt="logo">')
    parts.append("<h2>Admin Login</h2>")
    if err:
        parts.append(f'<div class="err">{err}</div>')
    parts.append('<form method="post">')
    parts.append('<input name="username" placeholder="Username" required>')
    parts.append('<input name="password" type="password" placeholder="Password" required>')
    parts.append('<button type="submit">Login</button>')
    parts.append('</form></div>')
    return HTML_HEAD + "".join(parts) + HTML_FOOT

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

def authed():
    return session.get("auth") is True

@app.route("/")
def home():
    if not authed():
        return redirect("/login")
    logo = f'<img class="logo" src="{LOGO_URL}" alt="logo">' if LOGO_URL else ""
    body = f"""
    <div class="card">
      {logo}
      <h2>Dashboard</h2>
      <p>Welcome, <b>{LOGIN_USER}</b> ✅</p>
      <p><a href="/logout">Logout</a></p>
    </div>
    """
    return HTML_HEAD + body + HTML_FOOT

@app.route("/api/health")
def health():
    return {"ok": True}

@app.route("/api/generate", methods=["POST"])
def generate():
    if request.headers.get("X-Admin-Secret") != ADMIN_SECRET:
        return {"error": "forbidden"}, 403
    return {"status": "ok", "note": "stub"}

if __name__ == "__main__":
    app.run(host=BIND, port=PORT)
__PY__
  chmod +x "$APPDIR/app.py"

  if [[ ! -d "$APPDIR/venv" ]]; then
    log "Creating venv…"
    python3 -m venv "$APPDIR/venv"
  fi
  log "Installing Flask…"
  "$APPDIR/venv/bin/pip" install --upgrade pip >/dev/null
  "$APPDIR/venv/bin/pip" install flask >/dev/null
}

write_unit(){
  log "Writing unit → $UNIT"
  cat >"$UNIT" <<'__UNIT__'
[Unit]
Description=ZI One-Time Key API (Login UI)
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=/etc/default/zi-keyapi
WorkingDirectory=/opt/zi-keyapi
ExecStart=/opt/zi-keyapi/venv/bin/python /opt/zi-keyapi/app.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
__UNIT__
  systemctl daemon-reload
}

detect_ip(){
  [[ -n "$FORCE_IP" ]] && { echo "$FORCE_IP"; return; }
  for svc in "https://api.ipify.org" "https://ifconfig.co/ip" "https://checkip.amazonaws.com"; do
    ip="$(curl -fsS --max-time 5 "$svc" || true)"
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
  echo "127.0.0.1"
}

do_install(){
  need_root
  ensure_deps
  prompt_creds_if_needed
  write_env
  write_app
  write_unit
  log "Enable & start service…"
  systemctl enable zi-keyapi.service >/dev/null
  systemctl restart zi-keyapi.service || true
  sleep 1
  systemctl --no-pager --full status zi-keyapi.service | sed -n '1,12p' || true

  log "Health check:"
  curl -fsS "http://127.0.0.1:${PORT}/api/health" || echo '{"ok": false}'

  MYIP="$(detect_ip)"
  echo
  log "Done. Open: http://${MYIP}:${PORT}/login"
  log "Env:  $ENVF"
  log "App:  $APPDIR"
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
  warn "Removed service. Leave dirs/files in place:"
  echo " - $APPDIR"
  echo " - $ENVF"
}

case "${ACTION:-}" in
  install) do_install;;
  status) do_status;;
  logs) do_logs;;
  restart) do_restart;;
  uninstall) do_uninstall;;
  *) cat <<'__HELP__'
Usage:
  sudo bash api.sh --install [--port=8088] [--secret=changeme] [--logo=URL] [--ip=1.2.3.4]
  sudo bash api.sh --install --user=upk123 --pass=123123
  sudo bash api.sh --status | --logs | --restart | --uninstall
__HELP__
  ;;
esac
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
    logo_html = f'<img class="logo" src="{LOGO_URL}" alt="logo">' if LOGO_URL else ""
    html = HTML_HEAD + f"""
    <div class="card">
      {logo_html}
      <h2>Dashboard</h2>
      <p>Welcome, <b>{LOGIN_USER}</b> ✅</p>
      <p><a href="/logout">Logout</a></p>
    </div>
    """ + HTML_FOOT
    return html

@app.route("/api/health")
def health():
    return {"ok": True}

@app.route("/api/generate", methods=["POST"])
def generate():
    if request.headers.get("X-Admin-Secret") != ADMIN_SECRET:
        return {"error":"forbidden"}, 403
    return {"status":"ok","note":"stub"}

if __name__ == "__main__":
    app.run(host=BIND, port=PORT)
PY

  chmod +x "$APPDIR/app.py"

  # venv + deps
  if [[ ! -d "$APPDIR/venv" ]]; then
    log "Creating virtualenv..."
    python3 -m venv "$APPDIR/venv"
  fi
  log "Installing Flask in venv..."
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

detect_ip(){
  if [[ -n "$FORCE_IP" ]]; then
    echo "$FORCE_IP"
    return
  fi
  # try multiple sources
  for svc in "https://api.ipify.org" "https://ifconfig.co/ip" "https://checkip.amazonaws.com"; do
    ip=$(curl -s --max-time 5 "$svc" || true)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return
    fi
  done
  echo "127.0.0.1"
}

do_install(){
  need_root
  ensure_deps
  prompt_creds_if_needed
  write_env
  write_app
  write_unit
  log "Enabling & starting service..."
  systemctl enable zi-keyapi.service
  systemctl restart zi-keyapi.service || true
  sleep 1
  systemctl --no-pager --full status zi-keyapi.service || true

  log "Health check:"
  set +e
  curl -sS "http://127.0.0.1:${PORT}/api/health" || true
  set -e

  IPV="$(detect_ip)"
  log "Done. Open: http://${IPV}:${PORT}/login"
  echo
  log "Saved env: $ENVF"
  log "App dir: $APPDIR"
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
  sudo bash api.sh --install [--port=8088 --secret=changeme --logo=URL --ip=1.2.3.4]
  sudo bash api.sh --install --user=upk --pass=123   # skip interactive prompts
  sudo bash api.sh --status | --logs | --restart | --uninstall
USAGE
;;
esac    body.append('<input name="username" placeholder="Username" required>')
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
