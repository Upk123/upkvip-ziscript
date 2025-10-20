#!/usr/bin/env bash
# ZI One-Time Key API — Full Installer (UPK edition)
# - Flask API: /healthz, /api/key (admin), /api/validate (user)
# - One-time keys stored at /opt/zi-keyapi/keys.txt
# - systemd service + env file
# - UFW firewall open
# - Optional HTTPS reverse proxy via Caddy (Let's Encrypt)
# Usage:
#   sudo bash install-keyapi.sh --secret="upkapi" --port=8088 [--domain=upkapi.yourdomain.com]

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# -------- Parse args --------
ADMIN_SECRET=""
PORT="8088"
DOMAIN=""
for arg in "$@"; do
  case "$arg" in
    --secret=*) ADMIN_SECRET="${arg#*=}";;
    --port=*)   PORT="${arg#*=}";;
    --domain=*) DOMAIN="${arg#*=}";;
    *) echo "Unknown arg: $arg"; exit 2;;
  esac
done

if [[ -z "${ADMIN_SECRET}" ]]; then
  read -rp "Enter ADMIN_SECRET (e.g. upkapi): " ADMIN_SECRET
fi
if ! [[ "${PORT}" =~ ^[0-9]{2,5}$ ]]; then
  echo "Invalid --port value"; exit 2
fi

APP_DIR="/opt/zi-keyapi"
APP_FILE="${APP_DIR}/app.py"
KEYS_FILE="${APP_DIR}/keys.txt"
ENV_FILE="/etc/default/zi-keyapi"
SERVICE_FILE="/etc/systemd/system/zi-keyapi.service"

echo "==> Installing Key API (port: ${PORT}, secret: set, domain: ${DOMAIN:-none})"

# -------- Packages --------
apt-get update -y -o APT::Update::Post-Invoke-Success::= -o APT::Update::Post-Invoke::= >/dev/null
apt-get install -y python3 python3-flask ufw curl ca-certificates >/dev/null

# -------- Layout --------
mkdir -p "${APP_DIR}"
touch "${KEYS_FILE}"

# -------- app.py --------
cat > "${APP_FILE}" <<'PY'
from flask import Flask, request, jsonify
import os, secrets, time, pathlib

app = Flask(__name__)

ADMIN_SECRET = os.environ.get("ADMIN_SECRET","").strip()
KEYS_FILE = os.environ.get("KEYS_FILE","/opt/zi-keyapi/keys.txt")

p = pathlib.Path(KEYS_FILE)
p.parent.mkdir(parents=True, exist_ok=True)
if not p.exists(): p.write_text("", encoding="utf-8")

def read_keys():
    return set(k.strip() for k in p.read_text(encoding="utf-8").splitlines() if k.strip())

def add_key(k: str):
    with p.open("a", encoding="utf-8") as f:
        f.write(k + "\n")

def consume_key(k: str) -> bool:
    keys = list(read_keys())
    if k not in keys: return False
    keys.remove(k)
    p.write_text("\n".join(keys) + ("\n" if keys else ""), encoding="utf-8")
    return True

@app.get("/healthz")
def healthz():
    return jsonify(status="ok", time=time.strftime("%Y-%m-%dT%H:%M:%S"))

@app.post("/api/key")
def create_key():
    if not ADMIN_SECRET or request.headers.get("X-Admin-Secret","").strip() != ADMIN_SECRET:
        return jsonify(ok=False, error="unauthorized"), 401
    key = secrets.token_hex(16)
    add_key(key)
    return jsonify(ok=True, key=key)

@app.post("/api/validate")
def validate():
    data = request.get_json(silent=True) or {}
    key = str(data.get("key","")).strip()
    if not key:
        return jsonify(ok=False, error="key-required"), 400
    ok = consume_key(key)  # one-time use
    if not ok:
        return jsonify(ok=False, error="invalid-key"), 400
    return jsonify(ok=True, msg="valid")

if __name__ == "__main__":
    import os
    port = int(os.environ.get("PORT", "8088"))
    app.run(host="0.0.0.0", port=port)
PY

# -------- ENV for systemd --------
cat > "${ENV_FILE}" <<EOF
ADMIN_SECRET=${ADMIN_SECRET}
PORT=${PORT}
KEYS_FILE=${KEYS_FILE}
EOF
chmod 600 "${ENV_FILE}"

# -------- systemd Unit --------
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=ZI One-Time Key API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 ${APP_FILE}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# -------- Firewall --------
ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true

# -------- Start service --------
systemctl daemon-reload
systemctl enable --now zi-keyapi.service

# -------- Optional HTTPS via Caddy --------
if [[ -n "${DOMAIN}" ]]; then
  echo "==> Enabling HTTPS reverse proxy on ${DOMAIN} via Caddy…"
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https >/dev/null 2>&1 || true
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | tee /usr/share/keyrings/caddy-stable-archive-keyring.gpg >/dev/null >/dev/null
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -y >/dev/null
  apt-get install -y caddy >/dev/null
  cat > /etc/caddy/Caddyfile <<EOC
${DOMAIN} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:${PORT}
}
EOC
  systemctl enable --now caddy
  systemctl reload caddy || systemctl restart caddy
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi

# -------- Summary --------
IP=$(hostname -I | awk '{print $1}')
echo
echo "================= DONE ================="
echo " Admin Secret : ${ADMIN_SECRET}"
echo " API Base     : http://${IP}:${PORT}"
echo " Health       : http://${IP}:${PORT}/healthz"
echo " Create Key   : POST /api/key     (header: X-Admin-Secret: ${ADMIN_SECRET})"
echo " Validate     : POST /api/validate (json: {\"key\":\"...\"})"
if [[ -n "${DOMAIN}" ]]; then
  echo " HTTPS URL    : https://${DOMAIN}"
  echo " (UI မှာ API URL ကို https://${DOMAIN} နဲ့သွင်းပါ)"
else
  echo " (UI မှာ API URL ကို http://${IP}:${PORT} နဲ့သွင်းပါ)"
fi
echo " Keys file    : ${KEYS_FILE}"
echo " Service      : systemctl status zi-keyapi"
