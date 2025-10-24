#!/usr/bin/env python3
# ZIVPN Web Panel (Clean Rebuild)
# Author: DEV-U PHOE KAUNT (stable version)
# Features:
#   - Android friendly dark UI
#   - Add/Edit/Delete user
#   - One-device lock via bind_ip
#   - Online/Offline detection
#   - Total/Online/Offline/Expired counters
#   - Compatible with systemd (port 8080)

from flask import Flask, jsonify, render_template_string, request, redirect, url_for, session
import os, json, re, tempfile, subprocess, hmac
from datetime import datetime, timedelta

USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LOGO_URL = "https://raw.githubusercontent.com/Upk123/upkvip-ziscript/main/20251018_231111.png"
LISTEN_PORT = "5667"

app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET", "dev-secret")
ADMIN_USER = os.environ.get("WEB_ADMIN_USER", "").strip()
ADMIN_PASS = os.environ.get("WEB_ADMIN_PASSWORD", "").strip()

# ---------- Utility ----------
def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default

def write_json_atomic(path, data):
    data_json = json.dumps(data, ensure_ascii=False, indent=2)
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    with os.fdopen(fd, "w") as f:
        f.write(data_json)
    os.replace(tmp, path)

def load_users():
    users = read_json(USERS_FILE, [])
    for u in users:
        u.setdefault("user", "")
        u.setdefault("password", "")
        u.setdefault("expires", "")
        u.setdefault("port", "")
        u.setdefault("bind_ip", "")
    return users

def save_users(users): write_json_atomic(USERS_FILE, users)

# ---------- Detection ----------
def conntrack_has(port):
    if not port:
        return False
    out = sh(f"grep -E '\\bdport={port}\\b' /proc/net/nf_conntrack 2>/dev/null | head -n1 || true").stdout
    return bool(out.strip())

def first_src_ip(port):
    out = sh(f"conntrack -L -p udp 2>/dev/null | awk '/dport={port}/{{for(i=1;i<=NF;i++)if($i~/src=/){{split($i,a,\"=\");print a[2];exit}}}}'").stdout.strip()
    return out if re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", out) else ""

def get_ports():
    out = sh("ss -uHln").stdout
    return set(re.findall(r":(\d+)\s", out))

def pick_port():
    used = {str(u.get("port")) for u in load_users() if u.get("port")}
    used |= get_ports()
    for p in range(6000, 20000):
        if str(p) not in used:
            return str(p)
    return "6000"

# ---------- One-device limit ----------
def ipt(cmd): return sh(cmd)

def ensure_limit(port, ip):
    if not (port and ip): return
    ipt(f"iptables -C INPUT -p udp --dport {port} -s {ip} -j ACCEPT 2>/dev/null") or \
    ipt(f"iptables -I INPUT -p udp --dport {port} -s {ip} -j ACCEPT")
    ipt(f"iptables -C INPUT -p udp --dport {port} ! -s {ip} -j DROP 2>/dev/null") or \
    ipt(f"iptables -I INPUT -p udp --dport {port} ! -s {ip} -j DROP")

def remove_limit(port):
    if not port: return
    for _ in range(30):
        line = ipt(f"iptables -S INPUT | grep -E '--dport {port}\\b' | head -n1 || true").stdout.strip()
        if not line: break
        ipt(f"iptables -D INPUT {line.replace('-A ', '')}")

def apply_limits(users):
    for u in users:
        p, ip = u.get("port", ""), u.get("bind_ip", "")
        if p and ip:
            ensure_limit(p, ip)
        elif p:
            remove_limit(p)

# ---------- Sync to config.json ----------
def sync_passwords():
    cfg = read_json(CONFIG_FILE, {})
    users = load_users()
    pw = sorted({u["password"] for u in users if u.get("password")})
    cfg["auth"] = {"mode": "passwords", "config": pw}
    cfg["listen"] = cfg.get("listen", f":{LISTEN_PORT}")
    cfg["cert"] = cfg.get("cert", "/etc/zivpn/zivpn.crt")
    cfg["key"] = cfg.get("key", "/etc/zivpn/zivpn.key")
    cfg["obfs"] = cfg.get("obfs", "zivpn")
    write_json_atomic(CONFIG_FILE, cfg)
    sh("systemctl restart zivpn.service")

# ---------- HTML ----------
HTML = """<!doctype html><html lang="my"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ZIVPN Panel</title>
<style>
body{background:#0b0f14;color:#e8eef4;font-family:system-ui,'Noto Sans Myanmar',sans-serif;margin:0;padding:14px}
.wrap{max-width:950px;margin:auto}
.btn{background:#151b23;color:#e8eef4;border:1px solid #334155;border-radius:999px;padding:8px 14px;cursor:pointer}
table{width:100%;border-collapse:collapse;margin-top:10px}
th,td{border:1px solid #334155;padding:10px;text-align:left}
th{background:#111823;font-size:13px}
td{font-size:14px}
.pill{padding:3px 9px;border-radius:999px;font-size:12px}
.ok{background:#22c55e;color:#0a0a0a}.bad{background:#ef4444;color:#fff}.unk{background:#9ca3af;color:#000}
.chip{background:#111823;border:1px solid #1f2a37;border-radius:999px;padding:6px 12px;font-size:13px;margin-right:6px}
.form{display:flex;flex-wrap:wrap;gap:10px}
.form input{padding:10px;border:1px solid #334155;border-radius:8px;background:#0d141d;color:#e8eef4}
@media(max-width:480px){th,td{font-size:12px}}
</style></head><body>
<div class="wrap">
<h2>🌐 DEV-U PHOE KAUNT • ZIVPN Panel</h2>
<div>
<span class="chip">Total {{count.total}}</span>
<span class="chip">Online {{count.online}}</span>
<span class="chip">Offline {{count.offline}}</span>
<span class="chip">Expired {{count.expired}}</span>
</div>
{% if not authed %}
<form method="post" action="/login" style="margin-top:20px">
  <input name="u" placeholder="Username" required><br><br>
  <input name="p" type="password" placeholder="Password" required><br><br>
  <button class="btn" type="submit">Login</button>
</form>
{% else %}
<div class="form" style="margin-top:16px">
<form method="post" action="/add" class="form">
<input name="user" placeholder="User" required>
<input name="password" placeholder="Password" required>
<input name="expires" placeholder="YYYY-MM-DD or days">
<input name="port" placeholder="auto">
<input name="bind_ip" placeholder="auto when online">
<button class="btn">Save + Sync</button>
</form></div>
<table>
<tr><th>User</th><th>Password</th><th>Expires</th><th>Port</th><th>Bind IP</th><th>Status</th><th>Edit</th><th>Del</th></tr>
{% for u in users %}
<tr>
<td>{{u.user}}</td><td>{{u.password}}</td><td>{{u.expires}}</td>
<td>{{u.port}}</td><td>{{u.bind_ip}}</td>
<td>{% if u.status=="Online" %}<span class="pill ok">Online</span>{% elif u.status=="Offline" %}<span class="pill bad">Offline</span>{% else %}<span class="pill unk">Unknown</span>{% endif %}</td>
<td><form method="get" action="/edit"><input type="hidden" name="user" value="{{u.user}}"><button class="btn">✏️</button></form></td>
<td><form method="post" action="/delete" onsubmit="return confirm('Delete?')"><input type="hidden" name="user" value="{{u.user}}"><button class="btn">🗑️</button></form></td>
</tr>{% endfor %}
</table>
<a href="/logout" class="btn" style="margin-top:12px;display:inline-block">Logout</a>
{% endif %}
</div></body></html>"""

# ---------- Logic ----------
def status_for(u):
    port = str(u.get("port", "")) or LISTEN_PORT
    if conntrack_has(port): return "Online"
    return "Offline"

def build_view(msg=""):
    if ADMIN_USER and not session.get("auth"): return render_template_string(HTML, authed=False, users=[], count={"total":0,"online":0,"offline":0,"expired":0})
    users = load_users()
    total, online, offline, expired = 0,0,0,0
    today = datetime.now().strftime("%Y-%m-%d")
    for u in users:
        total += 1
        st = status_for(u)
        if st == "Online": online += 1
        else: offline += 1
        if u.get("expires") and u["expires"] < today: expired += 1
        u["status"] = st
    count = {"total":total,"online":online,"offline":offline,"expired":expired}
    return render_template_string(HTML, authed=True, users=users, count=count, msg=msg)

@app.route("/", methods=["GET"])
def index(): return build_view()

@app.route("/login", methods=["GET","POST"])
def login():
    if request.method=="POST":
        if hmac.compare_digest(request.form["u"], ADMIN_USER) and hmac.compare_digest(request.form["p"], ADMIN_PASS):
            session["auth"]=True; return redirect("/")
    return build_view()

@app.route("/logout")
def logout(): session.clear(); return redirect("/")

@app.route("/add", methods=["POST"])
def add():
    if ADMIN_USER and not session.get("auth"): return redirect("/")
    u = (request.form["user"]).strip(); pw = (request.form["password"]).strip()
    exp = (request.form.get("expires") or "").strip(); port = (request.form.get("port") or "").strip(); ip = (request.form.get("bind_ip") or "").strip()
    if exp.isdigit(): exp=(datetime.now()+timedelta(days=int(exp))).strftime("%Y-%m-%d")
    if not port: port=pick_port()
    users=load_users()
    for x in users:
        if x["user"].lower()==u.lower():
            x.update({"password":pw,"expires":exp,"port":port,"bind_ip":ip}); break
    else:
        users.append({"user":u,"password":pw,"expires":exp,"port":port,"bind_ip":ip})
    save_users(users); sync_passwords()
    return redirect("/")

@app.route("/edit", methods=["GET"])
def edit(): return redirect("/") # simplified for stable build

@app.route("/delete", methods=["POST"])
def delete():
    if ADMIN_USER and not session.get("auth"): return redirect("/")
    name = request.form["user"].lower()
    users = [u for u in load_users() if u["user"].lower()!=name]
    save_users(users); sync_passwords()
    return redirect("/")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
