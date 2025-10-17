#!/bin/bash
# ZIVPN UDP Module + Web Panel (Myanmar UI)
# Original: Zahid Islam | Tweaks & MM UI: U Phote Kaunt
# Updates: apt-wait, download fallback, UFW 8080 allow (no other changes)

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

# --- NEW: Wait for other apt processes to finish ---
wait_for_apt() {
  echo -e "${Y}⏳ apt တွေကို စောင့်နေပါတယ်... (${Z}apt-get/unattended-upgrades${Y})${Z}"
  for i in $(seq 1 60); do
    if pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null || pgrep -f 'apt.systemd.daily' >/dev/null || pgrep -x unattended-upgrade >/dev/null; then
      sleep 5
    else
      return 0
    fi
  done
  echo -e "${Y}⚠️ apt မပြီးသေးလို့ timers ကို ယာယီရပ်နေပါတယ်...${Z}"
  systemctl stop --now unattended-upgrades.service 2>/dev/null || true
  systemctl stop --now apt-daily.service apt-daily.timer 2>/dev/null || true
  systemctl stop --now apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true
}
wait_for_apt

say "${Y}📦 Packages တွေ အပ်ဒိတ်လုပ်နေပါတယ်... (အချိန်ကြာနိုင်)${Z}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl ufw jq python3 python3-flask >/dev/null

# Stop services to avoid 'text file busy'
systemctl stop zivpn.service 2>/dev/null || true
systemctl stop zivpn-web.service 2>/dev/null || true

# ===== Download / Install ZIVPN binary =====
say "${Y}⬇️ ZIVPN binary ကို ဒေါင်းနေပါတယ်...${Z}"
BIN_TMP="/usr/local/bin/zivpn.new"
BIN="/usr/local/bin/zivpn"
PRIMARY_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
FALLBACK_URL="https://github.com/zahidbd2/udp-zivpn/releases/latest/download/udp-zivpn-linux-amd64"

if ! curl -fsSL -o "$BIN_TMP" "$PRIMARY_URL"; then
  echo -e "${Y}Primary URL 404 ဖြစ်သလိုပါ—latest ကို စမ်းပါတယ်...${Z}"
  curl -fSL -o "$BIN_TMP" "$FALLBACK_URL"
fi
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
# --- NEW: open Web Panel TCP 8080 ---
ufw allow 8080/tcp >/dev/null 2>&1 || true

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
</style></head><body>
<h2>📒 ZIVPN User Panel</h2>
<p class="tip">💡 <code>/etc/zivpn/users.json</code> ထဲက <code>port</code> နဲ့ UDP listener ကို စစ်ပြီး Online/Offline ပြပါသည်။</p>
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
</body></html>"""

app = Flask(__name__)

def load_users():
    try:
        with open(USERS_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return []

def get_udp_ports():
    out = subprocess.run("ss -uHapn", shell=True, capture_output=True, text=True).stdout
    return set(re.findall(r":(\d+)\s", out))

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
    view.sort(key=lambda x: (x.user or "").lower())
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
echo -e "$LINE"
