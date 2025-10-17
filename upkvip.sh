#!/usr/bin/env bash
# ============================================================
# ZIVPN UDP Server + Web Panel (Users/Expires/Online-Offline)
# Repacked & localized by U Phœ Kaunt (မြန်မာ UI မက်ဆေ့ချ်များ)
# Tested on Ubuntu 20.04/22.04 x86_64
# ============================================================

set -euo pipefail

# ---------- Helper ----------
log() { echo -e "$1"; }

# ---------- Header ----------
echo ""
echo "✨ ZIVPN UDP Server ကို သင့်ဆာဗာမှာ အပြည့်အဝတပ်သွားပေးမယ် ✨"
echo " • Packages တင် | ZIVPN binary | config.json | users.json"
echo " • systemd service | Web Panel (8080) | Users/Expires/Status"
echo "------------------------------------------------------------"

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
  echo "❗ ဒီ script ကို root အဖြစ် run ပေးပါ: sudo ./upkvip.sh"
  exit 1
fi

# ---------- Paths ----------
BIN=/usr/local/bin/zivpn
ETC=/etc/zivpn
CONF=$ETC/config.json
USERS=$ETC/users.json
CRT=$ETC/zivpn.crt
KEY=$ETC/zivpn.key
WEB=$ETC/web.py
WEB_SVC=/etc/systemd/system/zivpn-web.service
ZIVPN_SVC=/etc/systemd/system/zivpn.service
WEB_PORT=8080
ZIVPN_PORT=5667

# ---------- Apt deps ----------
echo "🧰 Packages တွေ အပ်ဒိတ်/တင်ဆက်နေပါတယ်... (အချိန်လိုနိုင်)"; echo
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl wget ufw python3 python3-flask ca-certificates >/dev/null

# ---------- Fetch ZIVPN binary ----------
echo "🧩 ZIVPN binary ကို ထည့်နေပါတယ်..."
curl -fsSL https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -o "$BIN"
chmod +x "$BIN"

# ---------- Config dir ----------
mkdir -p "$ETC"

# ---------- Certificates ----------
if [[ ! -s "$CRT" || ! -s "$KEY" ]]; then
  echo "🔐 စာရင်းသွင်းကတ်များ (cert/key) ထုတ်နေပါသည်..."
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=ZIVPN/OU=Ops/CN=zivpn" \
    -keyout "$KEY" -out "$CRT" >/dev/null 2>&1
fi

# ---------- Ask passwords for server auth ----------
echo ""
echo "🔑 \"Password List\" ကိုထည့်ပါ (ကော်မာဖြင့် ခွဲ): ဥပမာ -> upkvip,alice,pass1"
read -rp "Passwords (မထည့်ချင်ရင် Enter ထည့်— default 'zi' သာ အသုံးပြုမည်): " PW_INPUT
if [[ -z "${PW_INPUT// }" ]]; then
  PW_LIST=("zi")
else
  IFS=',' read -ra PW_LIST <<<"$PW_INPUT"
fi

# ---------- Write config.json ----------
echo "🧾 config.json ကို အသစ်ရေးနေသည်..."
cat >"$CONF" <<JSON
{
  "listen": ":$ZIVPN_PORT",
  "cert": "$CRT",
  "key": "$KEY",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": [
$(printf '      "%s",\n' "${PW_LIST[@]}" | sed '$ s/,$//')
    ]
  },
  "config": [
    "alice"
  ]
}
JSON

# ---------- users.json skeleton ----------
if [[ ! -f "$USERS" ]]; then
  echo "👥 users.json ကို ဖန်တီးနေသည်... (စာရင်းဗလာ)"
  echo "[]" > "$USERS"
fi

# ---------- systemd service (core ZIVPN) ----------
echo "🧷 ZIVPN service ဖိုင် တင်နေသည်..."
cat >"$ZIVPN_SVC" <<'UNIT'
[Unit]
Description=ZIVPN UDP Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Environment=ZIVPN_LOG_LEVEL=info
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

# ---------- Web panel (Flask) ----------
echo "🌐 Web Panel (Flask) ကို တပ်ဆင်/ရေးနေသည်..."
cat >"$WEB" <<'PY'
from flask import Flask, jsonify, render_template_string
import json, subprocess, re, os, time

USERS_FILE = "/etc/zivpn/users.json"
HTML = """<!doctype html>
<html>
<head><meta charset="utf-8"><title>ZIVPN User Panel</title>
<meta http-equiv="refresh" content="10">
<style>
body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:24px}
table{border-collapse:collapse;width:100%;max-width:820px}
th,td{border:1px solid #ddd;padding:8px;text-align:left}
th{background:#f5f5f5}
.ok{color:#0a0} .bad{color:#a00} .muted{color:#666}
small{color:#666}
</style></head>
<body>
<h2>ZIVPN User Panel</h2>
<table>
<tr><th>User</th><th>Expires</th><th>Status</th></tr>
{% for u in users %}
<tr>
  <td>{{u.user}}</td>
  <td>{{u.expires}}</td>
  <td>
    {% if u.status == "Online" %}<span class="ok">Online</span>
    {% elif u.status == "Offline" %}<span class="bad">Offline</span>
    {% else %}<span class="muted">Unknown</span>
    {% endif %}
  </td>
</tr>
{% endfor %}
</table>
<p><small>Tip: /etc/zivpn/users.json ထဲမှာ user တစ်ယောက်ချင်းစီအတွက် "port": 6001 လိုသတ်မှတ်ထားလျှင်
UDP ပေါ်တင် Scan လုပ်ပြီး Online/Offline ကို ပြသပေးပါမည် (best-effort).</small></p>
</body>
</html>"""

app = Flask(__name__)

def load_users():
    try:
        with open(USERS_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return []

def active_udp_ports():
    # ss -uHapn | regex ":<port> "
    try:
        out = subprocess.run("ss -uHapn", shell=True, capture_output=True, text=True, timeout=2).stdout
        return set(re.findall(r":(\\d+)\\s", out))
    except Exception:
        return set()

@app.route("/")
def index():
    users = load_users()
    active = active_udp_ports()
    view = []
    for u in users:
        p = str(u.get("port", "")) if u else ""
        status = "Unknown"
        if p:
            status = "Online" if p in active else "Offline"
        view.append(type("U", (), {
            "user": u.get("user",""),
            "expires": u.get("expires",""),
            "status": status
        }))
    view.sort(key=lambda x: x.user.lower() if x.user else "")
    return render_template_string(HTML, users=view)

@app.route("/api/users")
def api_users():
    users = load_users()
    active = active_udp_ports()
    for u in users:
        p = str(u.get("port",""))
        u["status"] = ("Online" if p in active else ("Offline" if p else "Unknown"))
    return jsonify(users)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
PY

# ---------- Web systemd ----------
cat >"$WEB_SVC" <<UNIT
[Unit]
Description=ZIVPN Web Panel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $WEB
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# ---------- Firewall ----------
echo "🧱 Firewall (UFW) rule များ ထည့်နေသည်..."
ufw allow ${WEB_PORT}/tcp >/dev/null 2>&1 || true
ufw allow ${ZIVPN_PORT}/udp >/dev/null 2>&1 || true
# (optional) client NAT range ကို သင့် setup အလိုက် ထည့်နိုင်သည်
# ufw allow 6000:19999/udp >/dev/null 2>&1 || true

# ---------- Enable services ----------
echo "🚀 Service များ ထည့်ပြီး စတင်နေသည်..."
systemctl daemon-reload
systemctl enable --now zivpn.service >/dev/null
systemctl enable --now zivpn-web.service >/dev/null || true

# ---------- CLI helpers (add/del user) ----------
cat >/usr/local/bin/zivpn-add-user <<'SH'
#!/usr/bin/env bash
# usage: zivpn-add-user USER PASS EXPIRES PORT(optional)
set -e
USERS=/etc/zivpn/users.json
python3 - "$@" <<'PY'
import json, sys
users_file="/etc/zivpn/users.json"
user=sys.argv[1]
pwd=sys.argv[2]
exp=sys.argv[3]
port=int(sys.argv[4]) if len(sys.argv)>4 else None
try:
    with open(users_file,"r") as f: data=json.load(f)
except: data=[]
# replace if exists
data=[u for u in data if u.get("user")!=user]
obj={"user":user,"pass":pwd,"expires":exp}
if port: obj["port"]=port
data.append(obj)
with open(users_file,"w") as f: json.dump(data,f,indent=2)
print("OK: user saved")
PY
SH
chmod +x /usr/local/bin/zivpn-add-user

cat >/usr/local/bin/zivpn-del-user <<'SH'
#!/usr/bin/env bash
# usage: zivpn-del-user USER
set -e
python3 - "$@" <<'PY'
import json, sys
users_file="/etc/zivpn/users.json"
u=sys.argv[1]
try:
    with open(users_file,"r") as f: data=json.load(f)
except: data=[]
data=[x for x in data if x.get("user")!=u]
with open(users_file,"w") as f: json.dump(data,f,indent=2)
print("OK: user removed")
PY
SH
chmod +x /usr/local/bin/zivpn-del-user

# ---------- Summary (Myanmar nice text) ----------
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "✅ အဆင်ပြေပါပြီ!"
echo " • UDP Server   : running (port $ZIVPN_PORT/udp)"
echo " • Web Panel    : http://$IP:$WEB_PORT"
echo " • config.json  : $CONF"
echo " • users.json   : $USERS"
echo " • Service cmds : systemctl status|restart zivpn (or) zivpn-web"
echo ""
echo "📝 အသုံးပြုနည်း:"
echo "  user အသစ်ထည့် ->  zivpn-add-user  upk123  pass123  2025-12-31T23:59:59+07:00  6001"
echo "  user ဖျက်    ->  zivpn-del-user   upk123"
echo ""
echo "📌 မှတ်ချက်: Online/Offline သို့မဟုတ် 'Unknown' ပြခြင်းသည်"
echo "    users.json ထဲမှ port နဲ့ ဆာဗာပေါ်ရှိ UDP ဆက်သွယ်မှုကို scan လုပ်ထားသော"
echo "    best-effort ခန့်မှန်းချက်သာ ဖြစ်ပါသည်။"
echo "------------------------------------------------------------"
