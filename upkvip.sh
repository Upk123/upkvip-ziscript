#!/bin/bash
# ZIVPN UDP Module + Web Panel (Myanmar UI)
# Original: Zahid Islam | Tweaks & MM UI: U Phote Kaunt

set -e

# ===== Color Helpers =====
B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; M="\e[1;35m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"

say() { echo -e "$1"; }

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP Server ကို တပ်ဆင်နေပါတယ်...${Z}\n$LINE"

# ===== Pre-flight =====
say "${C}🔑 Root အခွင့်အရေး 필요${Z}"
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}ဤ script ကို root အဖြစ် chạy ရပါမယ် (sudo -i)${Z}"; exit 1
fi

say "${Y}📦 Packages တွေ အပ်ဒိတ်လုပ်နေပါတယ်... (အချိန်ကြာနိုင်)${Z}"
apt-get update -y >/dev/null
apt-get install -y curl ufw jq python3 python3-flask >/dev/null

# Stop services to avoid 'text file busy'
systemctl stop zivpn.service 2>/dev/null || true
systemctl stop zivpn-web.service 2>/dev/null || true

# ===== Download / Install ZIVPN binary =====
say "${Y}⬇️ ZIVPN binary ကို ဒေါင်းနေပါတယ်...${Z}"
BIN_TMP="/usr/local/bin/zivpn.new"
BIN="/usr/local/bin/zivpn"
curl -fsSL -o "$BIN_TMP" "https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
chmod +x "$BIN_TMP"
mv -f "$BIN_TMP" "$BIN"

# ===== Config folder =====
mkdir -p /etc/zivpn

# ===== Base config.json =====
CFG="/etc/zivpn/config.json"
if [ ! -f "$CFG" ]; then
  say "${Y}🧩 မူရင်း config.json ကို ဖန်တီးနေပါတယ်...${Z}"
  curl -fsSL -o "$CFG" "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json"
fi

# ===== Generate certs (once) =====
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  say "${Y}🔐 SSL စိတျဖိုင်တွေ ဖန်တီးနေပါတယ်...${Z}"
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=UPK/OU=Net/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# ===== Ask passwords for config.json =====
say "${G}🔏 \"Password List\" ထည့်ပါ (ကော်မာဖြင့်ခွဲ) eg: upkvip,alice,pass1 ${Z}"
read -r -p "Passwords (Enter ကို နှိပ်ရင် 'zi' သာ သုံးမယ်): " input_pw
if [ -z "$input_pw" ]; then
  PW_LIST='["zi"]'
else
  # normalize to JSON array
  PW_LIST=$(echo "$input_pw" | awk -F',' '{
    printf("["); for(i=1;i<=NF;i++){gsub(/^ *| *$/,"",$i); printf("%s\"%s\"", (i>1?",":""), $i)}; printf("]")
  }')
fi

# Update config.json: auth.config (password list)
if jq . >/dev/null 2>&1 <<<'{}'; then
  TMP=$(mktemp)
  jq --argjson pw "$PW_LIST" '
    .auth.mode = "passwords" |
    .auth.config = $pw |
    .listen = (."listen" // ":5667") |
    .cert = "/etc/zivpn/zivpn.crt" |
    .key  = "/etc/zivpn/zivpn.key" |
    .obfs = "zivpn"
  ' "$CFG" > "$TMP" && mv "$TMP" "$CFG"
else
  # jq မရှိသော်လည်း အရင်က sed fallback (already installed jq above)
  :
fi
say "${G}✅ Password List ကို config.json ထဲသို့ ထည့်ပြီးပါပြီ${Z}"

# ===== users.json (for Web Panel) =====
USERS="/etc/zivpn/users.json"
if [ ! -f "$USERS" ]; then
  echo "[]" > "$USERS"
  say "${C}📒 users.json ကို ဖန်တီးထားပြီးပါပြီ: $USERS ${Z}"
fi

# ===== systemd service for ZIVPN =====
say "${Y}🧰 systemd service (zivpn.service) ကို ထည့်နေပါတယ်...${Z}"
cat >/etc/systemd/system/zivpn.service <<'EOF'
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
EOF

systemctl daemon-reload
systemctl enable --now zivpn.service
sleep 1

# ===== Port forward & firewall =====
IFACE=$(ip -4 route ls | awk '/default/ {print $5; exit}')
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667

ufw allow 6000:19999/udp >/dev/null 2>&1 || true
ufw allow 5667/udp >/dev/null 2>&1 || true

# ===== Web Panel (Flask) =====
say "${Y}🖥️ Web Panel (Flask) ကိုတပ်နေပါတယ်...${Z}"
cat >/etc/zivpn/web.py <<'PY'
from flask import Flask, jsonify, render_template_string, request
import json, re, subprocess, os

USERS_FILE = "/etc/zivpn/users.json"

HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<title>ZIVPN User Panel</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="10">
<style>
 body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:24px}
 h2{margin:0 0 12px}
 .tip{color:#666;margin:6px 0 18px}
 table{border-collapse:collapse;width:100%;max-width:860px}
 th,td{border:1px solid #ddd;padding:8px;text-align:left}
 th{background:#f5f5f5}
 .ok{color:#0a0}.bad{color:#a00}.muted{color:#666}
 .pill{display:inline-block;background:#eef;padding:3px 8px;border-radius:999px}
 .btn{display:inline-block;padding:6px 10px;border:1px solid #ccc;border-radius:8px;text-decoration:none}
 .btn:hover{background:#f8f8f8}
</style></head><body>
<h2>📒 ZIVPN User Panel</h2>
<p class="tip">💡 အွန်လိုင်း/အော့ဖ်လိုင်းပြရန် <code>/etc/zivpn/users.json</code> ထဲမှာ user တစ်ယောက်စီအတွက် <code>port</code> ထည့်ပါ (UDP ဆာဗာသို့ scan လုပ်ပြီးစစ်တာ)။</p>
<table>
  <tr><th>👤 အသုံးပြုသူ</th><th>⏰ ကုန်ဆုံးရက်</th><th>🔌 အနေအထား</th></tr>
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
<p class="tip">➕ အသုံးပြုသူအသစ်ထည့်ရန်: <span class="pill">/etc/zivpn/users.json</span> ကို တိုက်ရိုက်ပြင်ပြီး <span class="pill">systemctl restart zivpn-web</span> မလိုပါ—ဒီစာမျက်နှာက auto refresh ဖြစ်နေပါတယ်။</p>
</body></html>"""

app = Flask(__name__)

def load_users():
    try:
        with open(USERS_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return []

def get_udp_ports():
    # collect active/listening UDP ports (requires root)
    out = subprocess.run("ss -uHapn", shell=True, capture_output=True, text=True).stdout
    return set(re.findall(r":(\\d+)\\s", out))

@app.route("/")
def index():
    users = load_users()
    active = get_udp_ports()
    view = []
    for u in users:
        port = str(u.get("port",""))
        if port:
            status = "Online" if port in active else "Offline"
        else:
            status = "Unknown"
        view.append(type("U", (), {"user":u.get("user",""), "expires":u.get("expires",""), "status":status}))
    view.sort(key=lambda x: x.user.lower())
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
    app.run(host="0.0.0.0", port=8080)
PY

# systemd for web
cat >/etc/systemd/system/zivpn-web.service <<'EOF'
[Unit]
Description=ZIVPN Web Panel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /etc/zivpn/web.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now zivpn-web.service

# ===== Done =====
IP=$(hostname -I | awk '{print $1}')
echo -e "\n$LINE\n${G}✅ အားလုံးပြီးပါပြီ!${Z}"
echo -e "${C}• UDP Server   : ${M}running${Z}"
echo -e "${C}• Web Panel    : ${Y}http://$IP:8080${Z}"
echo -e "${C}• config.json  : ${Y}/etc/zivpn/config.json${Z}"
echo -e "${C}• users.json   : ${Y}/etc/zivpn/users.json${Z}"
echo -e "${C}• Service cmds : ${Y}systemctl status|restart zivpn (or) zivpn-web${Z}"
echo -e "$LINE"  .ok{color:#0a0;font-weight:600}
  .bad{color:#c00;font-weight:600}
  .muted{color:#777}
  .brand{font-weight:700;background:linear-gradient(90deg,#0ea5e9,#22c55e);-webkit-background-clip:text;color:transparent}
</style>
</head><body>
  <h2 class="brand">ZIVPN User Panel</h2>
  <div class="tip">💡 အွန်လိုင်း/အော့ဖ်လိုင်း ကို UDP port scan နဲ့ခနခန (10s) ပြန်စစ်ပေးတယ်။ <span class="muted">user တစ်ယောက်ချင်း "port" ထည့်ထားမလားမသိ — မထည့်ရင် Unknown ရနိုင်</span></div>
  <table>
   <tr><th>👤 User</th><th>⏳ Expires</th><th>📶 Status</th></tr>
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
</body></html>"""

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
    view=[]
    for u in users:
        port = str(u.get("port","")) if isinstance(u, dict) else ""
        if port:
            status = "Online" if port in active else "Offline"
        else:
            status = "Unknown"
        view.append(type("U",(),{"user":u.get("user",""),"expires":u.get("expires",""),"status":status}))
    view.sort(key=lambda x: x.user.lower())
    return render_template_string(HTML, users=view)

@app.route("/api/users")
def api_users():
    users = load_users()
    active = get_udp_ports()
    for u in users:
        p = str(u.get("port",""))
        u["status"] = ("Online" if p in active else ("Offline" if p else "Unknown"))
    return jsonify(users)

if __name__=="__main__":
    app.run(host="0.0.0.0", port=8080)
PY

cat >/etc/systemd/system/zivpn-web.service <<'UNIT'
[Unit]
Description=ZIVPN Web Panel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /etc/zivpn/web.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now zivpn-web.service || true
ufw allow 8080/tcp >/dev/null 2>&1 || true

# -------- 9) Helper commands (add/del/list user)
install -d /usr/local/sbin

# Add user: zivpn-add-user <user> <pass> <ISO8601-exp> [port]
cat >/usr/local/sbin/zivpn-add-user <<'PY'
#!/usr/bin/env python3
import json,sys,os
p="/etc/zivpn/users.json"
if len(sys.argv)<4:
  print("အသုံးပြုမှု: zivpn-add-user <user> <pass> <expires-ISO8601> [port]")
  sys.exit(1)
user, pw, exp = sys.argv[1], sys.argv[2], sys.argv[3]
port = sys.argv[4] if len(sys.argv)>4 else ""
try:
  data=json.load(open(p))
except:
  data=[]
# replace if exists
data=[u for u in data if u.get("user")!=user]
obj={"user":user,"pass":pw,"expires":exp}
if port: obj["port"]=port
data.append(obj)
with open(p,"w") as f: json.dump(data,f,indent=2)
print("✔ ထည့်ပြီး: ",user)
PY
chmod +x /usr/local/sbin/zivpn-add-user

# Del user
cat >/usr/local/sbin/zivpn-del-user <<'PY'
#!/usr/bin/env python3
import json,sys
p="/etc/zivpn/users.json"
if len(sys.argv)<2:
  print("အသုံးပြုမှု: zivpn-del-user <user>")
  sys.exit(1)
user=sys.argv[1]
try:
  data=json.load(open(p))
except:
  data=[]
before=len(data)
data=[u for u in data if u.get("user")!=user]
with open(p,"w") as f: json.dump(data,f,indent=2)
print("✔ ဖယ်ရှားပြီး: ",user," (",before,"→",len(data),")")
PY
chmod +x /usr/local/sbin/zivpn-del-user

# List users
cat >/usr/local/sbin/zivpn-list-users <<'PY'
#!/usr/bin/env python3
import json
p="/etc/zivpn/users.json"
try:
  data=json.load(open(p))
except:
  data=[]
for u in sorted(data, key=lambda x: x.get("user","")):
  print(f"{u.get('user','?'):15s}  exp={u.get('expires','?')}  port={u.get('port','-')}")
PY
chmod +x /usr/local/sbin/zivpn-list-users

# -------- 10) Status
sleep 1
green "✅ ZIVPN UDP အင်စတောလုပ်ငန်း စည်ဆန်စွာပြီးဆုံး!"
echo
yellow "📍 Web Panel:   http://$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}') :8080/"
yellow "🧩 Service:     systemctl status zivpn.service   |   systemctl status zivpn-web.service"
yellow "👥 Users JSON:   /etc/zivpn/users.json   (user, pass, expires, [port])"
echo
green "အသုံးပြုရန် (မြန်မာ Command Helper)"
echo "  • အသစ်ထည့်:  zivpn-add-user alice alice \"$(date -d '+30 days' -Iseconds 2>/dev/null || date -v+30d -Iseconds)\" 5667"
echo "  • ဖျက်ရန်:      zivpn-del-user alice"
echo "  • စာရင်းကြည့်:  zivpn-list-users"
echo
green "အောင်မြင်ပါစေ ✨"        st   = ("Online" if (p and p in active) else ("Offline" if p else "Unknown"))
        lines.append(f"👤 {name} | ⏳ {exp} | 📶 {st}")
    txt = "\n".join(lines) + "\n"
    return Response(txt, mimetype="text/plain; charset=utf-8")

if __name__ == "__main__":
    port = int(os.environ.get("PORT","8080"))
    app.run(host="0.0.0.0", port=port)
PY

# 3) restart web service
sudo systemctl daemon-reload
sudo systemctl restart zivpn-web
sudo systemctl status zivpn-web --no-pager -n 10
