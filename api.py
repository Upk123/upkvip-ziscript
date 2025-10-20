#!/bin/bash
# ZI One-Time Key API – full auto installer
# - Creates /opt/zi-keyapi with app.py + keys.txt
# - Installs python/pip + Flask, Flask-CORS
# - Sets ADMIN_SECRET (random if not provided)
# - Opens port 8088/tcp and enables a systemd service
# Usage (optional custom secret):
#   sudo ADMIN_SECRET="MyStrongSecret123" bash zi-keyapi-install.sh

set -euo pipefail

B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; Z="\e[0m"
say(){ echo -e "$1"; }

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}Please run as root (sudo -i)${Z}"; exit 1
fi

APP_DIR="/opt/zi-keyapi"
APP_FILE="${APP_DIR}/app.py"
KEY_FILE="${APP_DIR}/keys.txt"
ENV_FILE="/etc/zi-keyapi.env"
SERVICE="/etc/systemd/system/zi-keyapi.service"
PORT="${PORT:-8088}"

# ---- Fix apt "command-not-found" bug if present (Ubuntu 20.04) ----
CNF_CONF="/etc/apt/apt.conf.d/50command-not-found"
if [ -f "$CNF_CONF" ]; then
  mv "$CNF_CONF" "${CNF_CONF}.disabled" || true
fi

say "${Y}Installing Python & pip...${Z}"
apt-get update -y >/dev/null || true
apt-get install -y python3 python3-pip ufw ca-certificates >/dev/null

# restore file if we moved it
if [ -f "${CNF_CONF}.disabled" ]; then
  mv "${CNF_CONF}.disabled" "$CNF_CONF" || true
fi

say "${Y}Installing Python packages (Flask, CORS)...${Z}"
pip3 install --quiet --upgrade pip
pip3 install --quiet flask flask-cors

say "${Y}Creating app directory & files...${Z}"
mkdir -p "$APP_DIR"
touch "$KEY_FILE"

# ---- Create app.py ----
cat >"$APP_FILE" <<'PY'
from flask import Flask, request, jsonify
from flask_cors import CORS
import os
from datetime import datetime, timedelta
from secrets import token_hex
from pathlib import Path

APP_DIR = Path("/opt/zi-keyapi")
KEY_FILE = APP_DIR / "keys.txt"
APP_DIR.mkdir(parents=True, exist_ok=True)
KEY_FILE.touch(exist_ok=True)

app = Flask(__name__)
CORS(app)

ADMIN_SECRET = os.environ.get("ADMIN_SECRET", "changeme")
PORT = int(os.environ.get("PORT", "8088"))

def load_keys():
    if not KEY_FILE.exists(): return []
    with KEY_FILE.open() as f:
        return [line.strip() for line in f if line.strip()]

def save_keys(keys):
    with KEY_FILE.open("w") as f:
        f.write("\n".join(keys) + ("\n" if keys else ""))

@app.get("/healthz")
def healthz():
    return jsonify({"message":"ZI Key API is running", "status":"ok", "time": datetime.utcnow().isoformat()})

@app.post("/api/key")
def create_key():
    if request.headers.get("X-Admin-Secret") != ADMIN_SECRET:
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    body = request.get_json(silent=True) or {}
    ttl = int(body.get("ttl", 60))
    note = str(body.get("note", ""))

    token = token_hex(16)
    exp = (datetime.utcnow() + timedelta(minutes=ttl)).isoformat()

    keys = load_keys()
    keys.append(f"{token}|{exp}|{note}")
    save_keys(keys)

    return jsonify({"ok": True, "key": token, "expires": exp, "note": note})

@app.post("/api/validate")
def validate():
    body = request.get_json(silent=True) or {}
    key = str(body.get("key","")).strip()
    if not key:
        return jsonify({"ok": False, "error": "key required"}), 400

    now = datetime.utcnow()
    keys = load_keys()
    found = None
    remain = []
    for line in keys:
        parts = line.split("|",2)
        tok = parts[0]
        exp = parts[1] if len(parts) > 1 else ""
        if tok == key:
            found = (tok, exp)
            continue
        remain.append(line)

    if not found:
        return jsonify({"ok": False, "error": "invalid"}), 400

    try:
        if now > datetime.fromisoformat(found[1]):
            save_keys(remain)  # consume expired too
            return jsonify({"ok": False, "error": "expired"}), 400
    except Exception:
        pass

    save_keys(remain)  # consume on success (one-time)
    return jsonify({"ok": True, "msg": "valid"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
PY

chmod 644 "$APP_FILE" "$KEY_FILE"

# ---- Secret & env file ----
if [ -z "${ADMIN_SECRET:-}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    ADMIN_SECRET="$(openssl rand -hex 16)"
  else
    ADMIN_SECRET="$(python3 - <<'P'\nimport secrets;print(secrets.token_hex(16))\nP\n)"
  fi
  GEN_NOTE="(generated)"
else
  GEN_NOTE="(from env)"
fi

cat >"$ENV_FILE" <<EOF
# Environment for zi-keyapi
ADMIN_SECRET=${ADMIN_SECRET}
PORT=${PORT}
EOF
chmod 600 "$ENV_FILE"

# ---- systemd service ----
cat >"$SERVICE" <<'EOF'
[Unit]
Description=ZI One-Time Key API
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/zi-keyapi.env
WorkingDirectory=/opt/zi-keyapi
ExecStart=/usr/bin/python3 /opt/zi-keyapi/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ---- Firewall & start ----
ufw allow ${PORT}/tcp >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl enable --now zi-keyapi

IP=$(hostname -I | awk '{print $1}')
say "${G}✅ Install complete${Z}"
echo -e "${B}API URL   :${Z} http://${IP}:${PORT}"
echo -e "${B}Health    :${Z} curl http://${IP}:${PORT}/healthz"
echo -e "${B}Admin Key :${Z} ${ADMIN_SECRET} ${Y}${GEN_NOTE}${Z}"
echo -e "${B}Service   :${Z} systemctl status zi-keyapi  |  journalctl -u zi-keyapi -f"
echo -e "${B}Config    :${Z} ${ENV_FILE}  (edit & 'systemctl restart zi-keyapi')"
