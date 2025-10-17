# ===== ZIVPN Web Panel (Users + Online/Offline) =====

# deps
if ! command -v flask >/dev/null 2>&1; then
  apt-get update 2>/dev/null || true
  apt-get install -y python3-flask curl || true
fi

# web app
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
.ok{color:#0a0}
.bad{color:#a00}
.muted{color:#666}
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

# small static index for sanity check
cat >/etc/zivpn/index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>ZIVPN</title>
<p>OK - ZIVPN web is installed. Go to <a href="/">/</a>.</p>
HTML

# systemd service
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

# firewall + enable
ufw allow 8080/tcp >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now zivpn-web
echo "✅ Web panel is running on http://<YOUR_IP>:8080"
echo "   Note: Put a 'port' for each user in /etc/zivpn/users.json to see Online/Offline."
# ===== end web panel block =====
