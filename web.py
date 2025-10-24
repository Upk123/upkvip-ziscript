#!/usr/bin/env python3
# ZIVPN Web Panel — Android-friendly UI, accurate Online/Offline, Edit card,
# One-device bind (bind_ip), counters, and "Scan Online" refresh.
# Author: DEV-U PHOE KAUNT

from flask import Flask, render_template_string, request, redirect, url_for, session, jsonify
import os, json, re, tempfile, subprocess, hmac
from datetime import datetime, timedelta

USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LOGO_URL = "https://raw.githubusercontent.com/Upk123/upkvip-ziscript/main/20251018_231111.png"
LISTEN_FALLBACK = "5667"

app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET","dev-secret-change-me")
ADMIN_USER = os.environ.get("WEB_ADMIN_USER","").strip()
ADMIN_PASS = os.environ.get("WEB_ADMIN_PASSWORD","").strip()

# ---------- utils ----------
def sh(cmd): return subprocess.run(cmd, shell=True, capture_output=True, text=True)
def read_json(path, default): 
    try:
        with open(path) as f: return json.load(f)
    except Exception: return default
def write_json_atomic(path, data):
    d=json.dumps(data, ensure_ascii=False, indent=2)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    with os.fdopen(fd,"w") as f: f.write(d)
    os.replace(tmp, path)

def load_users():
    v=read_json(USERS_FILE,[])
    out=[]
    for u in v:
        out.append({
            "user":u.get("user",""), "password":u.get("password",""),
            "expires":u.get("expires",""), "port":str(u.get("port","")) if str(u.get("port",""))!="" else "",
            "bind_ip":u.get("bind_ip","")
        })
    return out
def save_users(users): write_json_atomic(USERS_FILE, users)

def get_listen_port_from_config():
    cfg=read_json(CONFIG_FILE,{})
    m=re.search(r":(\d+)$", str(cfg.get("listen","")))
    return (m.group(1) if m else LISTEN_FALLBACK)

def get_udp_listen_ports():
    out=sh("ss -uHln").stdout
    return set(re.findall(r":(\d+)\s", out))

def pick_free_port():
    used={str(u.get("port","")) for u in load_users() if str(u.get("port",""))}
    used |= get_udp_listen_ports()
    for p in range(6000,20000):
        if str(p) not in used: return str(p)
    return "6000"

# ---------- online/offline detection ----------
def conntrack_has(port):
    if not port: return False
    # fast path: /proc (new kernels)
    p = sh(f"grep -E '\\bdport={port}\\b|\\bsport={port}\\b' /proc/net/nf_conntrack 2>/dev/null | head -n1 || true").stdout
    if p.strip(): return True
    # fallback: conntrack binary
    q = sh(f"conntrack -L -p udp 2>/dev/null | grep -E '\\bdport={port}\\b|\\bsport={port}\\b' | head -n1 || true").stdout
    return bool(q.strip())

def first_src_ip(port):
    if not port: return ""
    out = sh(
      "conntrack -L -p udp 2>/dev/null | "
      f"awk \"/dport={port}\\b/ {{for(i=1;i<=NF;i++) if($i~/src=/){{split($i,a,'='); print a[2]; exit}}}}\""
    ).stdout.strip()
    return out if re.fullmatch(r'(?:\d{1,3}\.){3}\d{1,3}', out) else ""

def user_status(u, active_ports, listen_port):
    p = str(u.get("port","")) or listen_port
    if conntrack_has(p): return "Online"
    if p in active_ports: return "Offline"
    return "Unknown"

# ---------- one-device iptables ----------
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
        line = ipt(f"iptables -S INPUT | grep -E \"-p udp .* --dport {port}\\b .* (-j DROP|-j ACCEPT)\" | head -n1 || true").stdout.strip()
        if not line: break
        ipt(f"iptables -D INPUT {line.replace('-A ', '')}")
def apply_limits(users):
    for u in users:
        p=str(u.get("port","") or "")
        ip=(u.get("bind_ip","") or "").strip()
        if p and ip: ensure_limit(p, ip)
        elif p: remove_limit(p)

# ---------- sync to zivpn config ----------
def sync_config_passwords():
    cfg=read_json(CONFIG_FILE,{})
    pw=sorted({str(u["password"]) for u in load_users() if u.get("password")})
    cfg["auth"]={"mode":"passwords","config":pw}
    cfg["listen"]=cfg.get("listen") or ":5667"
    cfg["cert"]=cfg.get("cert") or "/etc/zivpn/zivpn.crt"
    cfg["key"]=cfg.get("key") or "/etc/zivpn/zivpn.key"
    cfg["obfs"]=cfg.get("obfs") or "zivpn"
    write_json_atomic(CONFIG_FILE,cfg)
    sh("systemctl restart zivpn.service")

# ---------- auth helpers ----------
def login_enabled(): return bool(ADMIN_USER and ADMIN_PASS)
def authed(): return session.get("auth") is True

# ---------- UI (Android-friendly) ----------
HTML = """<!doctype html><html lang="my"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>ZIVPN Panel</title>
<style>
:root{--bg:#0b0f14;--fg:#e7eef7;--muted:#9aa7b3;--card:#101724;--bd:#1f2a37;--ok:#22c55e;--bad:#ef4444;--unk:#9ca3af;--pri:#0f172a}
html,body{background:var(--bg);color:var(--fg)}
body{font-family:system-ui,Segoe UI,Roboto,'Noto Sans Myanmar',sans-serif;margin:0;padding:14px}
.wrap{max-width:980px;margin:0 auto}
header{display:flex;gap:12px;align-items:center}
h1{margin:0;font-weight:800;font-size:20px}
.sub{color:var(--muted);font-size:12px}
.btn{padding:10px 14px;border-radius:12px;border:1px solid var(--bd);background:#0f1522;color:var(--fg);text-decoration:none;cursor:pointer}
.btn-green{background:#16a34a;border-color:#15803d;color:#06140a;font-weight:800}
.btn-chip{background:var(--pri);border:1px solid var(--bd);border-radius:999px;padding:8px 12px;font-size:13px}
.card{margin:12px 0;padding:12px;border:1px solid var(--bd);border-radius:14px;background:var(--card)}
.input{width:100%;padding:12px;border:1px solid var(--bd);border-radius:12px;background:#0b1220;color:var(--fg)}
.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
@media(max-width:560px){.grid{grid-template-columns:1fr}}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid var(--bd);padding:10px;text-align:left}
th{background:#0c1420;font-size:12.5px}
td{font-size:14px}
.pill{display:inline-block;padding:4px 10px;border-radius:999px}
.ok{background:var(--ok);color:#06140a}.bad{background:var(--bad);color:#1b0606}.unk{background:var(--unk);color:#111}
.counter{display:flex;gap:8px;flex-wrap:wrap;margin-top:8px}
</style></head><body>
<div class="wrap">
<header>
  <img src="{{logo}}" style="height:42px;border-radius:10px">
  <div style="flex:1">
    <h1>DEV-U PHOE KAUNT • ZIVPN Panel</h1>
    <div class="sub">Android UI • One-device lock • Edit</div>
  </div>
  {% if authed %}<a class="btn" href="/logout">Logout</a>{% endif %}
</header>

<div class="counter">
  <span class="btn-chip">Total <b>{{count.total}}</b></span>
  <span class="btn-chip">Online <b>{{count.online}}</b></span>
  <span class="btn-chip">Offline <b>{{count.offline}}</b></span>
  <span class="btn-chip">Expired <b>{{count.expired}}</b></span>
  {% if authed %}<a class="btn" href="/scan">🔎 Scan Online</a>{% endif %}
</div>

{% if not authed %}
  <div class="card" style="max-width:440px;margin:36px auto">
    {% if err %}<div style="color:var(--bad);margin-bottom:8px">{{err}}</div>{% endif %}
    <form method="post" action="/login">
      <input class="input" name="u" placeholder="Username" autofocus required style="margin-bottom:8px">
      <input class="input" name="p" type="password" placeholder="Password" required style="margin-bottom:12px">
      <button class="btn btn-green" type="submit" style="width:100%">Login</button>
    </form>
  </div>
{% else %}

<div class="card">
  <h3 style="margin:6px 0 10px">➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
  {% if msg %}<div style="color:var(--ok);margin:6px 0">{{msg}}</div>{% endif %}
  {% if err %}<div style="color:var(--bad);margin:6px 0">{{err}}</div>{% endif %}
  <form method="post" action="/add">
    <div class="grid">
      <input class="input" name="user" placeholder="👤 User" required>
      <input class="input" name="password" placeholder="🔑 Password" required>
      <input class="input" name="expires" placeholder="⏰ YYYY-MM-DD or days">
      <input class="input" name="port" placeholder="🔌 UDP Port (auto)">
      <input class="input" name="bind_ip" placeholder="📱 Bind IP (auto when online)">
    </div>
    <button class="btn btn-green" type="submit" style="width:100%;margin-top:10px">Save + Sync</button>
  </form>
</div>

{% if edit %}
<div class="card" id="editcard">
  <h3 style="margin:6px 0 10px">✏️ Edit: {{edit.user}}</h3>
  <form method="post" action="/edit">
    <input type="hidden" name="orig" value="{{edit.user}}">
    <div class="grid">
      <input class="input" name="user" value="{{edit.user}}" required>
      <input class="input" name="password" value="{{edit.password}}" required>
      <input class="input" name="expires" value="{{edit.expires}}" placeholder="YYYY-MM-DD or days">
      <input class="input" name="port" value="{{edit.port}}">
      <input class="input" name="bind_ip" value="{{edit.bind_ip}}">
    </div>
    <button class="btn btn-green" type="submit" style="width:100%;margin-top:10px">Update</button>
    <a class="btn" href="/" style="width:100%;margin-top:6px;display:inline-block;text-align:center">Cancel</a>
  </form>
</div>
{% endif %}

<table>
  <tr>
    <th>User</th><th>Password</th><th>Expires</th><th>Port</th><th>Bind IP</th><th>Status</th><th>Edit</th><th>Delete</th>
  </tr>
  {% for u in users %}
  <tr>
    <td>{{u.user}}</td>
    <td>{{u.password}}</td>
    <td>{{u.expires or "—"}}</td>
    <td>{{u.port or "—"}}</td>
    <td>{{u.bind_ip or "—"}}</td>
    <td>{% if u.status=="Online" %}<span class="pill ok">Online</span>{% elif u.status=="Offline" %}<span class="pill bad">Offline</span>{% else %}<span class="pill unk">Unknown</span>{% endif %}</td>
    <td>
      <form method="get" action="/edit" style="display:inline">
        <input type="hidden" name="user" value="{{u.user}}">
        <button class="btn" type="submit">✏️</button>
      </form>
    </td>
    <td>
      <form method="post" action="/delete" onsubmit="return confirm('ဖျက်မလား?')" style="display:inline">
        <input type="hidden" name="user" value="{{u.user}}">
        <button class="btn" type="submit">🗑️</button>
      </form>
    </td>
  </tr>
  {% endfor %}
</table>
{% endif %}
</div></body></html>
"""

# ---------- view ----------
def build_view(msg="", err="", edit=None):
    if login_enabled() and not authed():
        return render_template_string(HTML, authed=False, logo=LOGO_URL, err=session.pop("login_err", None),
                                      users=[], count={"total":0,"online":0,"offline":0,"expired":0}, edit=None)
    users=load_users()
    # auto-bind first IP when online & no bind_ip
    changed=False
    for u in users:
        if u.get("port") and not u.get("bind_ip"):
            ip=first_src_ip(str(u["port"]))
            if ip: u["bind_ip"]=ip; changed=True
    if changed: save_users(users)

    apply_limits(users)

    active=get_udp_listen_ports()
    listen_port=get_listen_port_from_config()

    today=datetime.now().strftime("%Y-%m-%d")
    total=online=offline=expired=0
    view=[]
    for u in users:
        st=user_status(u, active, listen_port)
        total+=1
        online+= (1 if st=="Online" else 0)
        offline+= (1 if st=="Offline" else 0)
        if u.get("expires") and str(u["expires"]) < today: expired+=1
        view.append(type("U",(),{
            "user":u.get("user",""), "password":u.get("password",""),
            "expires":u.get("expires",""), "port":u.get("port",""),
            "bind_ip":u.get("bind_ip",""), "status":st
        }))
    view.sort(key=lambda x:(x.user or "").lower())
    return render_template_string(HTML, authed=True, logo=LOGO_URL, users=view,
                                  count={"total":total,"online":online,"offline":offline,"expired":expired},
                                  msg=msg, err=err, edit=edit)

# ---------- routes ----------
@app.route("/")
def index(): return build_view()

@app.route("/scan")
def scan():  # manual refresh for online status
    return build_view(msg="Scanned.")

@app.route("/login", methods=["GET","POST"])
def login():
    if not login_enabled(): return redirect(url_for('index'))
    if request.method=="POST":
        u=(request.form.get("u") or "").strip()
        p=(request.form.get("p") or "").strip()
        if hmac.compare_digest(u, ADMIN_USER) and hmac.compare_digest(p, ADMIN_PASS):
            session["auth"]=True; return redirect(url_for('index'))
        session["login_err"]="မှန်ကန်မှုမရှိပါ (username/password)"
        return redirect(url_for('login'))
    return build_view()

@app.route("/logout")
def logout():
    session.pop("auth", None)
    return redirect(url_for('login') if login_enabled() else url_for('index'))

@app.route("/add", methods=["POST"])
def add_user():
    if login_enabled() and not authed(): return redirect(url_for('login'))
    user=(request.form.get("user") or "").strip()
    password=(request.form.get("password") or "").strip()
    expires=(request.form.get("expires") or "").strip()
    port=(request.form.get("port") or "").strip()
    bind_ip=(request.form.get("bind_ip") or "").strip()
    if expires.isdigit(): expires=(datetime.now()+timedelta(days=int(expires))).strftime("%Y-%m-%d")
    if not user or not password: return build_view(err="User/Password လိုအပ်")
    if port:
        if not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999):
            return build_view(err="Port 6000–19999")
    else:
        port=pick_free_port()
    users=load_users(); replaced=False
    for u in users:
        if u.get("user","").lower()==user.lower():
            u.update({"password":password,"expires":expires,"port":port,"bind_ip":bind_ip}); replaced=True; break
    if not replaced:
        users.append({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip})
    save_users(users); sync_config_passwords(); apply_limits(users)
    return redirect(url_for('index'))

@app.route("/edit", methods=["GET","POST"])
def edit_user():
    if login_enabled() and not authed(): return redirect(url_for('login'))
    if request.method=="GET":
        q=(request.args.get("user") or "").strip().lower()
        users=load_users()
        t=[u for u in users if u.get("user","").lower()==q]
        if not t: return build_view(err="မတွေ့ပါ")
        e=t[0]
        return build_view(edit=type("E",(),e))
    # POST save
    orig=(request.form.get("orig") or "").strip().lower()
    user=(request.form.get("user") or "").strip()
    password=(request.form.get("password") or "").strip()
    expires=(request.form.get("expires") or "").strip()
    port=(request.form.get("port") or "").strip()
    bind_ip=(request.form.get("bind_ip") or "").strip()
    if expires.isdigit(): expires=(datetime.now()+timedelta(days=int(expires))).strftime("%Y-%m-%d")
    if not user or not password: return build_view(err="User/Password လိုအပ်")
    if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)):
        return build_view(err="Port 6000–19999")
    users=load_users(); found=False
    for u in users:
        if u.get("user","").lower()==orig:
            oldp=u.get("port",""); oldip=u.get("bind_ip","")
            if oldp and (str(oldp)!=str(port) or oldip!=bind_ip): remove_limit(oldp)
            u.update({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip})
            found=True; break
    if not found: return build_view(err="မတွေ့ပါ")
    save_users(users); sync_config_passwords(); apply_limits(users)
    return redirect(url_for('index'))

@app.route("/delete", methods=["POST"])
def delete_user():
    if login_enabled() and not authed(): return redirect(url_for('login'))
    name=(request.form.get("user") or "").strip().lower()
    remain=[]; removed=None
    for u in load_users():
        if u.get("user","").lower()==name: removed=u
        else: remain.append(u)
    if removed and removed.get("port"): remove_limit(removed.get("port"))
    save_users(remain); sync_config_passwords()
    return redirect(url_for('index'))

# simple api to view statuses as JSON
@app.route("/api/users")
def api_users():
    users=load_users()
    active=get_udp_listen_ports()
    listen=get_listen_port_from_config()
    for u in users: u["status"]=user_status(u, active, listen)
    return jsonify(users)

@app.errorhandler(405)
def h405(e): return redirect(url_for('index'))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)<form method="post" action="/login" style="margin-top:20px">
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
