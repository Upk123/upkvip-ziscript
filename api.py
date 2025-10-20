#!/bin/bash
# ZI One-Time Key API — full auto install
# Creates Flask API + JSON DB + CORS + systemd + UFW
set -euo pipefail

# ------- Config (can override by CLI flags) -------
PORT_DEFAULT=8088
SECRET_DEFAULT="CHANGE_ME_TO_STRONG_SECRET"
CORS_DEFAULT="*"

usage() {
  cat <<EOF
Usage: sudo bash $0 [--port=8088] [--secret=STRONG_SECRET] [--cors=https://yourname.github.io]
Defaults: port=${PORT_DEFAULT}, secret=${SECRET_DEFAULT}, cors=${CORS_DEFAULT}
EOF
}

PORT="${PORT_DEFAULT}"
ADMIN_SECRET="${SECRET_DEFAULT}"
CORS_ORIGIN="${CORS_DEFAULT}"

for arg in "$@"; do
  case "$arg" in
    --port=*) PORT="${arg#--port=}" ;;
    --secret=*) ADMIN_SECRET="${arg#--secret=}" ;;
    --cors=*) CORS_ORIGIN="${arg#--cors=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $arg"; usage; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0"; exit 1
fi

echo "==> Installing deps..."
apt-get update -y >/dev/null
apt-get install -y python3 python3-pip ufw >/dev/null
python3 -m pip install --break-system-packages flask >/dev/null

echo "==> Creating app files..."
mkdir -p /opt/zi-keyapi
cat >/opt/zi-keyapi/app.py <<'PY'
from flask import Flask, request, jsonify, make_response
import os, hmac, json, time, secrets
from datetime import datetime

APP = Flask(__name__)

DB_PATH = os.environ.get("DB_PATH", "/opt/zi-keyapi/keys.json")
ADMIN_SECRET = os.environ.get("ADMIN_SECRET", "CHANGE_ME_TO_STRONG_SECRET")
CORS_ORIGIN = os.environ.get("CORS_ORIGIN", "*")  # e.g. https://yourname.github.io

def load_db():
    try:
        with open(DB_PATH, "r") as f:
            return json.load(f)
    except Exception:
        return {}

def save_db(d):
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with open(DB_PATH, "w") as f:
        json.dump(d, f)

def is_admin(req):
    return hmac.compare_digest(req.headers.get("X-Admin-Secret",""), ADMIN_SECRET)

@APP.after_request
def add_cors(resp):
    # allow CORS for admin site
    resp.headers["Access-Control-Allow-Origin"] = CORS_ORIGIN
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type, X-Admin-Secret"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    resp.headers["Access-Control-Max-Age"] = "86400"
    return resp

@APP.route("/api/keys/create", methods=["POST","OPTIONS"])
def create_key():
    if request.method == "OPTIONS":
        return ("",204)
    if not is_admin(request):
        return jsonify({"ok":False,"err":"unauthorized"}), 401
    data = request.get_json(silent=True) or {}
    ttl_min = int(data.get("ttl_minutes", 60))
    note = (data.get("note",""))[:200]
    token = secrets.token_urlsafe(32)
    now = int(time.time())
    d = load_db()
    d[token] = {"note": note, "exp": now + ttl_min*60, "used": False, "created_at": now}
    save_db(d)
    return jsonify({"ok":True, "token":token, "expires_in_min":ttl_min, "note":note})

@APP.route("/api/keys/status", methods=["GET","OPTIONS"])
def status():
    if request.method == "OPTIONS":
        return ("",204)
    if not is_admin(request):
        return jsonify({"ok":False,"err":"unauthorized"}), 401
    d = load_db()
    items = []
    for t,info in d.items():
        items.append({
            "token": t,
            "note": info.get("note",""),
            "expires_at_utc": datetime.utcfromtimestamp(info.get("exp",0)).isoformat(),
            "used_at_utc": datetime.utcfromtimestamp(info["used"]) .isoformat() if isinstance(info.get("used"), int) else (info.get("used") or None),
            "used": bool(info.get("used") not in (False, None))
        })
    items.sort(key=lambda x: x["expires_at_utc"], reverse=True)
    return jsonify({"ok":True, "items":items})

@APP.route("/api/keys/revoke", methods=["POST","OPTIONS"])
def revoke():
    if request.method == "OPTIONS":
        return ("",204)
    if not is_admin(request):
        return jsonify({"ok":False,"err":"unauthorized"}), 401
    tok = (request.get_json(silent=True) or {}).get("token","").strip()
    d = load_db()
    if tok not in d:
        return jsonify({"ok":False,"err":"invalid"}), 404
    d[tok]["used"] = int(time.time())
    save_db(d)
    return jsonify({"ok":True})

@APP.route("/api/keys/consume", methods=["POST","OPTIONS"])
def consume():
    if request.method == "OPTIONS":
        return ("",204)
    data = request.get_json(silent=True) or {}
    tok = (data.get("token") or "").strip()
    if not tok:
        return jsonify({"ok":False,"err":"token required"}), 400
    d = load_db()
    info = d.get(tok)
    if not info:
        return jsonify({"ok":False,"err":"invalid"}), 404
    if info.get("used") not in (False, None):
        return jsonify({"ok":False,"err":"used"}), 409
    now = int(time.time())
    if now > int(info.get("exp",0)):
        return jsonify({"ok":False,"err":"expired"}), 410
    # mark used
    info["used"] = now
    d[tok] = info
    save_db(d)
    return jsonify({"ok":True})

@APP.route("/healthz")
def health():
    return "ok", 200

if __name__ == "__main__":
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    if not os.path.exists(DB_PATH):
        save_db({})
    port = int(os.environ.get("PORT","8088"))
    APP.run(host="0.0.0.0", port=port)
PY

echo "==> Creating systemd unit..."
cat >/etc/systemd/system/zi-keyapi.service <<UNIT
[Unit]
Description=ZI One-Time Key API (Flask)
After=network.target

[Service]
User=root
WorkingDirectory=/opt/zi-keyapi
Environment=ADMIN_SECRET=${ADMIN_SECRET}
Environment=PORT=${PORT}
Environment=CORS_ORIGIN=${CORS_ORIGIN}
Environment=DB_PATH=/opt/zi-keyapi/keys.json
ExecStart=/usr/bin/python3 /opt/zi-keyapi/app.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

echo "==> Opening firewall (ufw)..."
ufw allow ${PORT}/tcp >/dev/null 2>&1 || true

echo "==> Starting service..."
systemctl daemon-reload
systemctl enable --now zi-keyapi

IP=$(hostname -I | awk '{print $1}')
echo
echo "================ READY ================"
echo " KEY_API        : http://$IP:${PORT}"
echo " ADMIN_SECRET   : ${ADMIN_SECRET}"
echo " CORS_ORIGIN    : ${CORS_ORIGIN}"
echo " Health         : curl http://$IP:${PORT}/healthz"
echo " Create Key     : curl -X POST http://$IP:${PORT}/api/keys/create -H 'Content-Type: application/json' -H 'X-Admin-Secret: ${ADMIN_SECRET}' -d '{\"ttl_minutes\":60,\"note\":\"test\"}'"
echo " Status         : curl http://$IP:${PORT}/api/keys/status -H 'X-Admin-Secret: ${ADMIN_SECRET}'"
echo " Revoke         : curl -X POST http://$IP:${PORT}/api/keys/revoke -H 'Content-Type: application/json' -H 'X-Admin-Secret: ${ADMIN_SECRET}' -d '{\"token\":\"<TOKEN>\"}'"
echo "======================================="
