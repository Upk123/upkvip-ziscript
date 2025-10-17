#!/bin/bash
# Zivpn UDP Module installer
# Creator Zahid Islam  +  Web Panel add-on (minimal)

echo -e "Updating server"
sudo apt-get update && apt-get upgrade -y

systemctl stop zivpn.service 1> /dev/null 2> /dev/null

echo -e "Downloading UDP Service"
wget https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn 1> /dev/null 2> /dev/null
chmod +x /usr/local/bin/zivpn

# config dir
mkdir -p /etc/zivpn 1> /dev/null 2> /dev/null

# base config
wget https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json -O /etc/zivpn/config.json 1> /dev/null 2> /dev/null

# ---- certs ----
echo "Generating cert files:"
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
  -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn" \
  -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt"

# socket tuning
sysctl -w net.core.rmem_max=16777216 1> /dev/null 2> /dev/null
sysctl -w net.core.wmem_max=16777216 1> /dev/null 2> /dev/null

# ---- main VPN service ----
cat >/etc/systemd/system/zivpn.service <<'EOF'
[Unit]
Description=zivpn VPN Server
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

echo -e "ZIVPN UDP Passwords"
read -p "Enter passwords separated by commas, example: pass1,pass2 (Press enter for Default 'zi'): " input_config

if [ -n "$input_config" ]; then
  IFS=',' read -r -a config <<< "$input_config"
  if [ ${#config[@]} -eq 1 ]; then
    config+=(${config[0]})
  fi
else
  config=("zi")
fi

new_config_str="\"config\": [$(printf "\"%s\"," "${config[@]}" | sed 's/,$//')]"
sed -i -E "s/\"config\": ?\[[[:space:]]*\"zi\"[[:space:]]*\]/${new_config_str}/g" /etc/zivpn/config.json

systemctl enable zivpn.service
systemctl start zivpn.service

# DNAT for ports (unchanged)
iptables -t nat -A PREROUTING -i $(ip -4 route ls|grep default|grep -Po '(?<=dev )(\S+)'|head -1) -p udp --dport 6000:19999 -j DNAT --to-destination :5667
ufw allow 6000:19999/udp
ufw allow 5667/udp

# -------------------------
#          WEB PANEL
# -------------------------
# ensure users.json exists (will be edited later by you)
if [ ! -f /etc/zivpn/users.json ]; then
  echo "[]" > /etc/zivpn/users.json
fi

# deps for web
if ! command -v flask >/dev/null 2>&1; then
  apt-get update 2>/dev/null || true
  apt-get install -y python3-flask curl || true
fi

# web app file
cat >/etc/zivpn/web.py <<'PY'
from flask import Flask, jsonify, render_template_string
import json, re, subprocess

USERS_FILE = "/etc/zivpn/users.json"

HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<title>ZIVPN User Panel</title>
<meta http-equiv="refresh" content="10">
<style>
body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:24px}
table{border-collapse:collapse;width:100%;max-width:720px}
th,td{border:1px solid #ddd;padding:8px;text-align:left}
th{background:#f5f5f5}
.ok{color:#0a0}.bad{color:#a00}.muted{color:#666}
</style></head><body>
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
<p class="muted">Tip: add "port" per user in /etc/zivpn/users.json to enable Online/Offline (by UDP port scan).</p>
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

# tiny index page
cat >/etc/zivpn/index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>ZIVPN</title>
<p>OK - ZIVPN web is installed. Go to <a href="/">/</a>.</p>
HTML

# systemd unit for web
cat >/etc/systemd/system/zivpn-web.service <<'UNIT'
[Unit]
Description=ZIVPN Web Monitor
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

# open port & enable
ufw allow 8080/tcp >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now zivpn-web

echo
echo "ZIVPN UDP Installed"
echo "Web panel:  http://\$(hostname -I | awk '{print \$1}'):8080"
echo "Note: Add a \"port\" for each user in /etc/zivpn/users.json to see Online/Offline."
