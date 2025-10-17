bash -c "$(curl -fsSL https://gist.githubusercontent.com/anonymous/0/raw/zivpn-allinone.sh)" || cat <<'SH' > /root/zivpn-allinone.sh
#!/usr/bin/env bash
set -euo pipefail

# ---------- sanity ----------
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

echo "[1/8] Install deps"
apt-get update -y
apt-get install -y curl ca-certificates python3 python3-flask ufw

# ---------- paths ----------
ZDIR=/etc/zivpn
BIN=/usr/local/bin/zivpn
CONF=$ZDIR/config.json
CRT=$ZDIR/zivpn.crt
KEY=$ZDIR/zivpn.key
UJSON=$ZDIR/users.json
WEB=$ZDIR/web.py
WEBUNIT=/etc/systemd/system/zivpn-web.service
SVUNIT=/etc/systemd/system/zivpn.service

mkdir -p "$ZDIR"

echo "[2/8] Install ZIVPN binary"
curl -fsSL https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -o "$BIN"
chmod +x "$BIN"

echo "[3/8] Make/keep config.json"
if [[ ! -f "$CONF" ]]; then
  cat > "$CONF" <<JSON
{
  "listen": ":5667",
  "cert": "$CRT",
  "key": "$KEY",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": [ "zi" ]
  }
}
JSON
fi

echo "[4/8] Generate TLS cert if missing"
if [[ ! -f "$CRT" || ! -f "$KEY" ]]; then
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
   -subj "/C=US/ST=CA/L=LA/O=ZIVPN/OU=IT/CN=zivpn" \
   -keyout "$KEY" -out "$CRT"
fi

echo "[5/8] Prompt & update passwords in config.json"
read -rp "Enter passwords (comma-separated) [default: zi]: " INPUT || true
INPUT="${INPUT:-zi}"
python3 - <<PY
import json,sys
p="$CONF"
cfg=json.load(open(p))
cfg.setdefault("auth",{}).setdefault("config",[])
cfg["auth"]["mode"]="passwords"
cfg["auth"]["config"]=[s.strip() for s in "$INPUT".split(",") if s.strip()]
open(p,"w").write(json.dumps(cfg,indent=2))
print("Saved passwords:", cfg["auth"]["config"])
PY

echo "[6/8] Systemd service for ZIVPN"
cat > "$SVUNIT" <<'UNIT'
[Unit]
Description=ZIVPN UDP Server
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT

echo "[7/8] Web panel"
# pick web port
WEBPORT=8080
if ss -ltn '( sport = :8080 )' | grep -q LISTEN; then WEBPORT=8081; fi

cat > "$WEB" <<'PY'
from flask import Flask, jsonify, render_template_string
import json, re, subprocess, os

USERS_FILE = "/etc/zivpn/users.json"

HTML = """<!doctype html><meta charset="utf-8">
<title>ZIVPN User Panel</title>
<meta http-equiv="refresh" content="10">
<style>
body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:24px}
table{border-collapse:collapse;width:100%;max-width:820px}
th,td{border:1px solid #ddd;padding:8px;text-align:left}
th{background:#f5f5f5}
.ok{color:#0a0}.bad{color:#a00}.muted{color:#666}
</style>
<h2>ZIVPN User Panel</h2>
<table>
<tr><th>User</th><th>Expires</th><th>Status</th></tr>
{% if not users %}<tr><td colspan=3 class="muted">
No users in /etc/zivpn/users.json
</td></tr>{% endif %}
{% for u in users %}
<tr>
  <td>{{u.user}}</td>
  <td>{{u.expires}}</td>
  <td>
    {% if u.status == "Online" %}<span class="ok">Online</span>
    {% elif u.status == "Offline" %}<span class="bad">Offline</span>
    {% else %}<span class="muted">Unknown</span>{% endif %}
  </td>
</tr>
{% endfor %}
</table>
<p class="muted">Tip: If you set a dedicated UDP client port for a user,
add it as <code>"port": 6001</code> in users.json to enable best-effort status.</p>
"""

app = Flask(__name__)

def load_users():
    try:
        with open(USERS_FILE,"r") as f:
            return json.load(f)
    except Exception:
        return []

def get_udp_ports():
    out = subprocess.run("ss -uHapn", shell=True, capture_output=True, text=True).stdout
    return set(re.findall(r":(\\d+)\\s", out))

@app.route("/")
def index():
    users = load_users()
    active = get_udp_ports()
    view = []
    for u in users:
        port = str(u.get("port",""))
        status = "Unknown"
        if port:
            status = "Online" if port in active else "Offline"
        view.append(type("U", (), {
            "user": u.get("user",""),
            "expires": u.get("expires",""),
            "status": status
        }))
    view.sort(key=lambda x: x.user.lower())
    from flask import render_template_string
    return render_template_string(HTML, users=view)

@app.route("/api/users")
def api_users():
    users = load_users()
    active = get_udp_ports()
    for u in users:
        p = str(u.get("port",""))
        u["status"] = ("Online" if p in active else ("Offline" if p else "Unknown"))
    return jsonify(users)

if __name__ == "__main__":
    import os
    port = int(os.environ.get("PORT","8080"))
    app.run(host="0.0.0.0", port=port)
PY

cat > "$WEBUNIT" <<UNIT
[Unit]
Description=ZIVPN Web Monitor
After=network.target
[Service]
Type=simple
User=root
Environment=PORT=$WEBPORT
ExecStart=/usr/bin/python3 $WEB
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT

# users.json bootstrap
if [[ ! -f "$UJSON" ]]; then
  echo "[]" > "$UJSON"
fi

echo "[8/8] Firewall & start services"
# UDP service
ufw allow 5667/udp >/dev/null 2>&1 || true
# Optional DNAT fan-in ports
IFACE=$(ip -4 route show default | awk '/default/ {print $5; exit}')
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
ufw allow 6000:19999/udp >/dev/null 2>&1 || true

# Web port
ufw allow ${WEBPORT}/tcp >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl enable --now zivpn.service
sleep 1
systemctl enable --now zivpn-web.service

IP=$(curl -fsSL https://ifconfig.me || hostname -I | awk '{print $1}')
echo
echo "✅ DONE."
echo "   - ZIVPN UDP  : udp://${IP}:5667"
echo "   - Web panel  : http://${IP}:${WEBPORT}/"
echo
echo "Users file: $UJSON  (example entry)"
cat <<'EX'
[
  {
    "user": "demo",
    "pass": "demo123",
    "expires": "2025-12-31T23:59:59+07:00",
    "port": 6001
  }
]
EX
SH
bash /root/zivpn-allinone.sh
