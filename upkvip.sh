#!/bin/bash
# ZIVPN UDP + Web Panel (Myanmar UI) — One-file Installer with Auto-Block on Expiry
# Original: Zahid Islam | MM UI: U Phote Kaunt | Hardened + Auto-Block: ChatGPT
set -Eeuo pipefail
trap 'echo -e "\e[1;31m✖ Error on line $LINENO\e[0m"' ERR

# ===== Tunables =====
ZIVPN_VERSION="udp-zivpn_1.4.9"
BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/${ZIVPN_VERSION}/udp-zivpn-linux-amd64"
SHA256_URL="${BIN_URL}.sha256"           # If not available upstream, checksum step will skip silently
LISTEN_PORT=5667
FORWARD_START=6000
FORWARD_END=6010                         # keep tight; enlarge if needed
ENABLE_UFW="yes"                         # "no" to skip UFW changes
PANEL_BIND="127.0.0.1"                   # 0.0.0.0 to expose publicly (recommend 127.0.0.1)
PANEL_PORT=8080
PANEL_REFRESH_SEC=10
PANEL_USER=""                            # optional Basic Auth user
PANEL_PASS=""                            # optional Basic Auth pass
OBFS_TAG="zivpn"

# ===== UI Helpers =====
B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; M="\e[1;35m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"
say(){ echo -e "$1"; }

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP Server (Hardened + Auto-Block) ကို တပ်ဆင်နေပါတယ်...${Z}\n$LINE"
if [ "$(id -u)" -ne 0 ]; then echo -e "${R}sudo -i နဲ့ run လုပ်ပါ${Z}"; exit 1; fi

# ===== Packages =====
say "${Y}📦 Packages အပ်ဒိတ်/တပ်ဆင်နေပါတယ်...${Z}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl ufw jq python3 python3-flask libcap2-bin iptables-persistent ca-certificates >/dev/null
command -v ss >/dev/null || apt-get install -y iproute2 >/dev/null

# Stop previous services if any
systemctl stop zivpn.service 2>/dev/null || true
systemctl stop zivpn-web.service 2>/dev/null || true
systemctl stop zivpn-enforce.timer 2>/dev/null || true
systemctl stop zivpn-enforce.service 2>/dev/null || true

# ===== Service user =====
id -u zivpn >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin zivpn

# ===== Download / Verify binary =====
say "${Y}⬇️ ZIVPN binary ကို ဒေါင်းပြီး စစ်ဆေးနေပါတယ်...${Z}"
BIN_DIR="/usr/local/bin"
BIN_TMP="${BIN_DIR}/zivpn.new"
BIN="${BIN_DIR}/zivpn"
curl -fsSL -o "$BIN_TMP" "$BIN_URL"
chmod +x "$BIN_TMP"
if curl -fsSL -o /tmp/zivpn.sha256 "$SHA256_URL"; then
  ( cd "$BIN_DIR" && sha256sum -c /tmp/zivpn.sha256 >/dev/null )
fi
mv -f "$BIN_TMP" "$BIN"
chown root:root "$BIN"
setcap 'cap_net_bind_service,cap_net_raw=+ep' "$BIN" || true

# ===== Config dir =====
mkdir -p /etc/zivpn
chown -R zivpn:zivpn /etc/zivpn
chmod 750 /etc/zivpn

# ===== Base config.json =====
CFG="/etc/zivpn/config.json"
if [ ! -f "$CFG" ]; then
  say "${Y}🧩 မူရင်း config.json ကို ဖန်တီးနေပါတယ်...${Z}"
  curl -fsSL -o "$CFG" "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json"
fi

# ===== TLS (self-signed) =====
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  say "${Y}🔐 Self-signed TLS စိတျဖိုင်တွေ ဖန်တီးနေပါတယ်...${Z}"
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=UPK/OU=Net/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
  chown zivpn:zivpn /etc/zivpn/zivpn.key /etc/zivpn/zivpn.crt
  chmod 640 /etc/zivpn/zivpn.key
fi

# ===== Ask for initial users (optional) =====
say "${G}🔏 တစ်ခါတည်း users.json ထဲ ထည့်မယ့် user/password/expiry (ကော်မာခွဲ): eg 'alice,alice123,2025-12-31'${Z}"
say "${G}   မထည့်ချင်ရင် Enter ကို နှိပ်ပါ (ပြီးမှ /etc/zivpn/users.json ကို ကိုယ်တိုင်ပြင်နိုင်)${Z}"
read -r -p "User triple (သို့မဟုတ် blank): " triple || true

# ===== users.json schema (password + expires + port) =====
USERS="/etc/zivpn/users.json"
if [ ! -f "$USERS" ]; then echo "[]" > "$USERS"; fi

if [ -n "${triple:-}" ]; then
  u=$(echo "$triple" | awk -F',' '{gsub(/^ *| *$/,"",$1);print $1}')
  p=$(echo "$triple" | awk -F',' '{gsub(/^ *| *$/,"",$2);print $2}')
  e=$(echo "$triple" | awk -F',' '{gsub(/^ *| *$/,"",$3);print $3}')
  jq --arg u "$u" --arg p "$p" --arg e "$e" '. += [{user:$u,password:$p,expires:$e,port:6001}]' "$USERS" > "$USERS.tmp" && mv "$USERS.tmp" "$USERS"
fi
chown zivpn:zivpn "$USERS"; chmod 640 "$USERS"

# ===== OPTIONAL: static passwords (always-allowed) =====
STATIC="/etc/zivpn/static_passwords.json"
if [ ! -f "$STATIC" ]; then
  echo '["zi"]' > "$STATIC"   # default keep
  chown zivpn:zivpn "$STATIC"; chmod 640 "$STATIC"
fi

# ===== Write initial config values (listen/obfs/certs) =====
TMP=$(mktemp)
jq --arg crt "/etc/zivpn/zivpn.crt" --arg key "/etc/zivpn/zivpn.key" --arg obfs "$OBFS_TAG" --arg listen ":${LISTEN_PORT}" '
  .auth.mode = "passwords" |
  .listen = (."listen" // $listen) |
  .cert = $crt |
  .key  = $key |
  .obfs = $obfs
' "$CFG" > "$TMP" && mv "$TMP" "$CFG"
chown zivpn:zivpn "$CFG"; chmod 640 "$CFG"

# ===== Auto-Enforcer (expires -> block) =====
say "${Y}🧮 Auth auto-enforcer ထည့်နေပါတယ်...${Z}"
cat >/etc/zivpn/enforce-auth.sh <<'BASH'
#!/bin/bash
set -Eeuo pipefail
CFG="/etc/zivpn/config.json"
USERS="/etc/zivpn/users.json"
STATIC="/etc/zivpn/static_passwords.json"
TMP=$(mktemp)
TODAY=$(date +%F)

# Load lists
STATIC_JSON=$( [ -f "$STATIC" ] && cat "$STATIC" || echo "[]")
ACTIVE_JSON=$( [ -f "$USERS" ] && jq --arg today "$TODAY" '
  map({user:(.user//""), password:(.password//""), expires:(.expires//"")})
  | [ .[] | select( (.expires=="" or .expires >= $today) and (.password!="") ) .password ]
' "$USERS" || echo "[]" )

MERGED=$(jq -n --argjson a "$ACTIVE_JSON" --argjson s "$STATIC_JSON" '($s+$a)|unique')

[ -f "$CFG" ] || { echo "config.json missing"; exit 1; }
jq --argjson pw "$MERGED" '
  .auth.mode = "passwords" |
  .auth.config = $pw
' "$CFG" > "$TMP" && mv "$TMP" "$CFG"
chown zivpn:zivpn "$CFG"; chmod 640 "$CFG"

# Apply changes
systemctl restart zivpn.service
BASH
chmod 750 /etc/zivpn/enforce-auth.sh
chown root:root /etc/zivpn/enforce-auth.sh

# Initial enforce now
/etc/zivpn/enforce-auth.sh

# ===== systemd: ZIVPN =====
say "${Y}🧰 systemd service (zivpn.service) ကို ထည့်နေပါတယ်...${Z}"
cat >/etc/systemd/system/zivpn.service <<EOF
[Unit]
Description=ZIVPN UDP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=zivpn
Group=zivpn
WorkingDirectory=/etc/zivpn
ExecStart=$BIN server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadWritePaths=/etc/zivpn
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now zivpn.service

# ===== NAT + Firewall =====
say "${Y}🌐 UDP ${FORWARD_START}-${FORWARD_END} ➜ ${LISTEN_PORT} REDIRECT rule ထည့်နေပါတယ်...${Z}"
IFACE=$(ip -4 route ls | awk '/default/ {print $5; exit}')
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport ${FORWARD_START}:${FORWARD_END} -j REDIRECT --to-ports ${LISTEN_PORT} 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport ${FORWARD_START}:${FORWARD_END} -j REDIRECT --to-ports ${LISTEN_PORT}
netfilter-persistent save >/dev/null || true

if [ "$ENABLE_UFW" = "yes" ]; then
  ufw allow ${LISTEN_PORT}/udp >/dev/null 2>&1 || true
  ufw allow ${FORWARD_START}:${FORWARD_END}/udp >/dev/null 2>&1 || true
  ufw status | grep -q inactive && ufw --force enable
fi

# ===== Web Panel (Flask) with expiry highlight =====
say "${Y}🖥️ Web Panel (Flask) ကို တပ်ဆင်နေပါတယ်...${Z}"
cat >/etc/zivpn/web.py <<'PY'
from flask import Flask, jsonify, render_template_string, request, Response
import json, re, subprocess, os, base64, datetime

USERS_FILE = "/etc/zivpn/users.json"
REFRESH = int(os.getenv("ZIVPNPANEL_REFRESH", "10"))

HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<title>ZIVPN User Panel</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="{{refresh}}">
<style>
 body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:24px}
 h2{margin:0 0 12px}
 .tip{color:#666;margin:6px 0 18px}
 table{border-collapse:collapse;width:100%;max-width:900px}
 th,td{border:1px solid #ddd;padding:8px;text-align:left}
 th{background:#f5f5f5}
 .ok{color:#0a0}.bad{color:#a00}.muted{color:#666}.warn{color:#b57f00}
 .pill{display:inline-block;background:#eef;padding:3px 8px;border-radius:999px}
 .exp{font-weight:bold}
</style></head><body>
<h2>📒 ZIVPN User Panel</h2>
<p class="tip">💡 <code>/etc/zivpn/users.json</code> ထဲက <code>password</code>/<code>expires</code> အရ auth ကို auto-sync လုပ်ထားပြီး သက်တမ်းကုန်ရင် auto-block ဖြစ်မယ်။</p>
<table>
  <tr><th>👤 အသုံးပြုသူ</th><th>🔑 စကားဝှက်</th><th>⏰ ကုန်ဆုံးရက်</th><th>📶 Listener Port</th><th>🔌 အနေအထား</th></tr>
  {% for u in users %}
  <tr>
    <td>{{u.user}}</td>
    <td>{{u.password_disp}}</td>
    <td class="exp">
      {% if u.expired %}<span class="bad">{{u.expires or "—"}}</span>
      {% elif u.expiring %}<span class="warn">{{u.expires}}</span>
      {% else %}{{u.expires or "—"}}
      {% endif %}
    </td>
    <td>{{u.port or ""}}</td>
    <td>
      {% if u.status == "Online" %}<span class="ok">Online</span>
      {% elif u.status == "Offline" %}<span class="bad">Offline</span>
      {% else %}<span class="muted">Unknown</span>
      {% endif %}
    </td>
  </tr>
  {% endfor %}
</table>
<p class="tip">✏️ အသုံးပြုသူထည့်/ပြင်ရန် <span class="pill">/etc/zivpn/users.json</span> ကို တိုက်ရိုက်ပြင်ပါ — panel က auto-refresh ဖြစ်နေပါတယ်။</p>
</body></html>"""

app = Flask(__name__)

def basic_auth():
    u = os.getenv("ZIVPNPANEL_USER", "")
    p = os.getenv("ZIVPNPANEL_PASS", "")
    if not u or not p:
        return True
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Basic "):
        return Response(status=401, headers={"WWW-Authenticate": 'Basic realm="ZIVPN"'})
    try:
        dec = base64.b64decode(auth.split(" ",1)[1]).decode("utf-8")
    except Exception:
        return Response(status=401, headers={"WWW-Authenticate": 'Basic realm="ZIVPN"'})
    return dec == f"{u}:{p}"

def load_users():
    try:
        with open(USERS_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return []

def get_udp_ports():
    out = subprocess.run("ss -uHpn", shell=True, capture_output=True, text=True).stdout
    return set(re.findall(r":(\d+)\s", out))

def parse_date(s):
    try:
        return datetime.date.fromisoformat(s)
    except Exception:
        return None

@app.before_request
def guard():
    if not basic_auth():
        return Response(status=401, headers={"WWW-Authenticate": 'Basic realm="ZIVPN"'})

@app.route("/")
def index():
    users = load_users()
    active = get_udp_ports()
    today = datetime.date.today()
    view = []
    for u in users:
        port = str(u.get("port","")) if u.get("port") else ""
        exp_s = u.get("expires","")
        exp_d = parse_date(exp_s) if exp_s else None
        expired = (exp_d is not None and exp_d < today)
        expiring = (exp_d is not None and (0 <= (exp_d - today).days <= 7))
        pwd = u.get("password","")
        pw_disp = "••••••" if pwd else ""
        status = "Unknown"
        if port:
            status = "Online" if port in active else "Offline"
        view.append(type("U", (), {
            "user":u.get("user",""), "password_disp":pw_disp,
            "expires":exp_s, "expired":expired, "expiring":expiring,
            "port":port, "status":status
        }))
    view.sort(key=lambda x: (x.user or "").lower())
    return render_template_string(HTML, users=view, refresh=REFRESH)

@app.route("/api/users")
def api_users():
    users = load_users()
    active = get_udp_ports()
    today = datetime.date.today()
    for u in users:
        p = str(u.get("port","")) if u.get("port") else ""
        exp_s = u.get("expires","")
        exp_d = parse_date(exp_s) if exp_s else None
        u["expired"] = bool(exp_d and exp_d < today)
        u["status"] = ("Online" if p and p in active else ("Offline" if p else "Unknown"))
        if "password" in u:
            u["password"] = "****" if u["password"] else ""
    return jsonify(users)

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.getenv("ZIVPNPANEL_HOST","127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.getenv("ZIVPNPANEL_PORT","8080")))
    args = ap.parse_args()
    app.run(host=args.host, port=args.port)
PY

# systemd for web
cat >/etc/systemd/system/zivpn-web.service <<EOF
[Unit]
Description=ZIVPN Web Panel
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
Environment=ZIVPNPANEL_HOST="${PANEL_BIND}"
Environment=ZIVPNPANEL_PORT="${PANEL_PORT}"
Environment=ZIVPNPANEL_REFRESH="${PANEL_REFRESH_SEC}"
Environment=ZIVPNPANEL_USER="${PANEL_USER}"
Environment=ZIVPNPANEL_PASS="${PANEL_PASS}"
ExecStart=/usr/bin/python3 /etc/zivpn/web.py --host "\$ZIVPNPANEL_HOST" --port "\$ZIVPNPANEL_PORT"
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/etc/zivpn
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now zivpn-web.service

# ===== systemd timer for auto-enforce =====
cat >/etc/systemd/system/zivpn-enforce.service <<'UNIT'
[Unit]
Description=ZIVPN auth enforcement (expires -> block)
[Service]
Type=oneshot
ExecStart=/etc/zivpn/enforce-auth.sh
User=root
Group=root
UNIT

cat >/etc/systemd/system/zivpn-enforce.timer <<'UNIT'
[Unit]
Description=Run ZIVPN auth enforcement every 10 minutes
[Timer]
OnBootSec=30s
OnUnitActiveSec=10min
AccuracySec=1min
Unit=zivpn-enforce.service
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now zivpn-enforce.timer

# ===== Final info =====
IP_IF=$(ip -4 addr show "${IFACE:-$(ip -4 route ls | awk '/default/ {print $5; exit}')}" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
echo -e "\n$LINE\n${G}✅ အားလုံးပြီးပါပြီ!${Z}"
echo -e "${C}• UDP Server   : ${M}running${Z}"
echo -e "${C}• Web Panel    : ${Y}http://${PANEL_BIND}:$PANEL_PORT${Z}  (server IP: ${IP_IF:-<auto>})"
echo -e "${C}• users.json   : ${Y}/etc/zivpn/users.json  ${Z}(format: user/password/expires/port)"
echo -e "${C}• Static pws   : ${Y}/etc/zivpn/static_passwords.json${Z}"
echo -e "${C}• Services     : ${Y}systemctl status|restart zivpn (or) zivpn-web${Z}"
echo -e "${C}• Enforcer     : ${Y}systemctl list-timers | grep zivpn-enforce${Z}"
echo -e "$LINE"  <td>
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
