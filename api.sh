#!/usr/bin/env bash
# ZI One-Time Key API — installer
# Author: UPK (for DEV-U PHOE KAUNT) — single-file bootstrap
set -euo pipefail

# ---------- args ----------
ADMIN_SECRET="${ADMIN_SECRET:-}"
PORT="${PORT:-8088}"
while [ $# -gt 0 ]; do
  case "$1" in
    --secret=*) ADMIN_SECRET="${1#*=}";;
    --port=*)   PORT="${1#*=}";;
    *) echo "Unknown arg: $1"; exit 2;;
  esac; shift
done
[ -n "${ADMIN_SECRET:-}" ] || ADMIN_SECRET="myapi123"

APP_DIR="/opt/zi-keyapi"
APP_FILE="$APP_DIR/app.py"
ENV_FILE="/etc/default/zi-keyapi"
SERVICE_FILE="/etc/systemd/system/zi-keyapi.service"

echo "🔧 Installing ZI Key API (port: $PORT, secret set)…"

# ---------- packages ----------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -o APT::Update::Post-Invoke-Success::=
apt-get install -y python3 python3-flask ufw curl

# ---------- layout ----------
mkdir -p "$APP_DIR"
touch "$APP_DIR/keys.txt"

# ---------- write app.py ----------
cat >"$APP_FILE" <<'PY'
from flask import Flask, request, jsonify
import os
from datetime import datetime

app = Flask(__name__)

ADMIN_SECRET = os.environ.get("ADMIN_SECRET", "changeme")
KEYS_FILE = "/opt/zi-keyapi/keys.txt"

def read_keys():
    if not os.path.exists(KEYS_FILE):
        return set()
    with open(KEYS_FILE) as f:
        return set(k.strip() for k in f if k.strip())

def write_keys(keys):
    with open(KEYS_FILE, "w") as f:
        for k in keys:
            f.write(k + "\n")

@app.route("/healthz", methods=["GET"])
def healthz():
    return jsonify({"status": "ok", "time": datetime.utcnow().isoformat()})

# admin: create a one-time key
@app.route("/api/key", methods=["POST"])
def create_key():
    auth = request.headers.get("X-Admin-Secret", "")
    if auth != ADMIN_SECRET:
        return jsonify({"ok": False, "error": "unauthorized"}), 401
    key = os.urandom(16).hex()
    keys = read_keys()
    keys.add(key)
    write_keys(keys)
    return jsonify({"ok": True, "key": key})

# user/installer: validate & consume key
@app.route("/api/validate", methods=["POST"])
def validate():
    data = request.get_json(silent=True) or {}
    key = (data.get("key") or "").strip()
    keys = read_keys()
    if not key or key not in keys:
        return jsonify({"ok": False, "error": "invalid key"}), 400
    keys.remove(key)            # consume once
    write_keys(keys)
    return jsonify({"ok": True, "msg": "valid"})

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8088"))
    app.run(host="0.0.0.0", port=port)
PY

# ---------- env ----------
cat >"$ENV_FILE" <<EOF
ADMIN_SECRET="$ADMIN_SECRET"
PORT="$PORT"
EOF

# ---------- service ----------
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=ZI One-Time Key API
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/python3 $APP_FILE
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# ---------- firewall ----------
ufw allow "${PORT}/tcp" || true
ufw reload || true

# ---------- enable ----------
systemctl daemon-reload
systemctl enable --now zi-keyapi.service

# ---------- health ----------
IP="$(hostname -I | awk '{print $1}')"
echo "⏱  Probing health…"
sleep 1
set +e
curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null
RC=$?
set -e

echo "✅ Done."
echo "   Admin Secret : ${ADMIN_SECRET}"
echo "   API Base     : http://${IP}:${PORT}"
echo "   Health       : http://${IP}:${PORT}/healthz"
echo "   Create Key   : POST /api/key  (header: X-Admin-Secret: ${ADMIN_SECRET})"
echo "   Validate     : POST /api/validate  (json: {\"key\":\"...\"})"
echo
echo "💡 UI ကိုသုံးချင်ရင် (https://api.upkvpn.site) ထဲမှာ:"
echo "    API URL  =>  http://${IP}:${PORT}"
echo "    Admin Secret => ${ADMIN_SECRET}"
