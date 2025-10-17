#!/bin/bash
# ZIVPN UDP Module + Web Panel + User Manager (Burmese Friendly)
# Base by: Zahid Islam | Refactor: U Phote Kaunt (မြန်မာ UI/messages ထည့်သွင်း)

set -euo pipefail

green(){ echo -e "\e[92m$*\e[0m"; }
yellow(){ echo -e "\e[93m$*\e[0m"; }
red(){ echo -e "\e[91m$*\e[0m"; }

green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
green "   ✨ ZIVPN UDP Server ကို သန့်သန့်ရှင်းရှင်း အပြီးအစီးသွင်းနေပါပြီ"
green "   • Web Panel (8080)   • Users/Expires  • Online/Offline"
green "   • မြန်မာ UI messages"
green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# -------- 0) Basic deps
yellow "🔧 Packages ရှာနေ/သွင်းနေ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y wget curl ufw openssl python3 python3-flask >/dev/null

# -------- 1) Install ZIVPN binary
yellow "⬇️ ZIVPN binary ထည့်နေ..."
install -d -m 755 /usr/local/bin
wget -q https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn

# -------- 2) Config folder + default config
install -d -m 755 /etc/zivpn
if [ ! -f /etc/zivpn/config.json ]; then
  yellow "📄 default config.json ဆွဲယူနေ..."
  if ! wget -q https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json -O /etc/zivpn/config.json; then
    # fallback very small config
    cat >/etc/zivpn/config.json <<'CFG'
{
  "listen": ":5667",
  "cert": "/etc/zivpn/zivpn.crt",
  "key":  "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "auth": { "mode": "passwords", "config": ["zi"] },
  "config": []
}
CFG
  fi
fi

# -------- 3) Certificates (self-signed)
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  yellow "🔐 ဆိုင်ဖာထုတ်စစ်လက်မှတ် files တည်ဆောက်နေ..."
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=UPhoteKaunt/OU=ZIVPN/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# -------- 4) Ask passwords -> write into config.json
echo
yellow "🔑 ZIVPN UDP စကားဝှက်များ ကိုမာများ (ဥပမာ: upkvip,alice,pass1)"
read -rp "    မထည့်ရင် 'zi' ကို default ယူပါမယ်: " input_config || true

if [ -n "${input_config:-}" ]; then
  IFS=',' read -r -a config <<< "$input_config"
else
  config=("zi")
fi
# build JSON list
pw_list=$(printf '"%s",' "${config[@]}" | sed 's/,$//')

# Replace/ensure passwords array
if grep -q '"auth"' /etc/zivpn/config.json; then
  # replace whatever inside "config": [ ... ]
  sed -i -E '0,/"auth"[^\}]*"config":[^\]]*\]/s//"auth": { "mode":"passwords", "config": ['"$pw_list"'] }/' /etc/zivpn/config.json
else
  # append auth block
  sed -i 's@^{@{ "auth": { "mode":"passwords","config": ['"$pw_list"'] }, @' /etc/zivpn/config.json
fi

# -------- 5) users.json (for panel) – create if missing, seed from passwords
if [ ! -f /etc/zivpn/users.json ]; then
  yellow "👥 users.json တည်ဆောက်နေ (expires 30 ရက်) ..."
  exp=$(date -d '+30 days' -Iseconds 2>/dev/null || date -v+30d -Iseconds)
  {
    echo "["
    n=${#config[@]}
    for i in "${!config[@]}"; do
      p="${config[$i]}"
      printf '  {"user":"%s","pass":"%s","expires":"%s"}' "$p" "$p" "$exp"
      if [ "$i" -lt $((n-1)) ]; then echo ","; else echo; fi
    done
    echo "]"
  } > /etc/zivpn/users.json
fi

# -------- 6) systemd service (zivpn)
yellow "🧩 systemd service တင်နေ..."
cat >/etc/systemd/system/zivpn.service <<'UNIT'
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

systemctl daemon-reload
systemctl enable --now zivpn.service || true

# -------- 7) NAT + firewall
yellow "🛡 firewall/NAT ပြင်နေ..."
IFACE=$(ip -4 route ls | awk '/default/ {print $5; exit}')
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
ufw allow 6000:19999/udp >/dev/null 2>&1 || true
ufw allow 5667/udp >/dev/null 2>&1 || true

# -------- 8) Web Panel (Flask)
yellow "🌐 Web Panel (8080) တပ်နေ..."
cat >/etc/zivpn/web.py <<'PY'
from flask import Flask, jsonify, render_template_string
import json, re, subprocess

USERS_FILE = "/etc/zivpn/users.json"

HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<title>ZIVPN User Panel</title>
<meta http-equiv="refresh" content="10">
<style>
  body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:24px;background:#fafafa}
  h2{margin:0 0 12px}
  .tip{color:#666;margin:6px 0 18px}
  table{border-collapse:collapse;width:100%;max-width:820px;background:#fff}
  th,td{border:1px solid #e5e5e5;padding:10px 12px;text-align:left}
  th{background:#f6f8fa}
  .ok{color:#0a0;font-weight:600}
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
