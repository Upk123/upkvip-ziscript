cat > /etc/zivpn/web.py << "PY"
#!/usr/bin/env python3
# ZIVPN Web Panel — Final Stable Build (UPK 2025-10-24)
# Android-Friendly Layout + Modal Edit + Correct Online Status

from flask import Flask, jsonify, render_template_string, request, redirect, url_for, session, make_response
import json, subprocess, os, tempfile, hmac, re
from datetime import datetime, timedelta

USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LISTEN_FALLBACK = "5667"
LOGO_URL = "https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png"

app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET", "dev-secret")
ADMIN_USER = os.environ.get("WEB_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("WEB_ADMIN_PASSWORD", "admin")

def read_json(path, default):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return default

def write_json_atomic(path, data):
    d = json.dumps(data, ensure_ascii=False, indent=2)
    dirn = os.path.dirname(path)
    os.makedirs(dirn, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=dirn)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(d)
        os.replace(tmp, path)
    finally:
        try:
            os.remove(tmp)
        except:
            pass

def shell(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def get_listen_port_from_config():
    cfg = read_json(CONFIG_FILE, {})
    listen = str(cfg.get("listen", "")).strip()
    m = re.search(r":(\d+)$", listen) if listen else None
    return (m.group(1) if m else LISTEN_FALLBACK)

def get_udp_listen_ports():
    out = shell("ss -uHln").stdout
    return set(re.findall(r":(\d+)\s", out))

def _ct_recent_line_for_port(port):
    cmd = f"conntrack -L -p udp 2>/dev/null | grep -w 'dport={port}' | head -n1 || true"
    return shell(cmd).stdout.strip()

def has_recent_udp_activity_for_port(port):
    return bool(_ct_recent_line_for_port(port))

def first_recent_src_ip(port):
    if not port: return ""
    out = _ct_recent_line_for_port(port)
    if not out: return ""
    m = re.search(r"\bsrc=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\b", out)
    ip = m.group(1) if m else ""
    return ip if re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}", ip or "") else ""

def status_for_user(u, active_ports, listen_port):
    port = str(u.get("port", ""))
    check_port = port if port else listen_port
    if has_recent_udp_activity_for_port(check_port):
        return "Online"
    if check_port in active_ports:
        return "Offline"
    return "Unknown"

def _ipt(cmd): return shell(cmd)

def ensure_limit_rules(port, ip):
    if not (port and ip): return
    _ipt(f"iptables -C INPUT -p udp --dport {port} -s {ip} -j ACCEPT 2>/dev/null") or \
    _ipt(f"iptables -I INPUT -p udp --dport {port} -s {ip} -j ACCEPT")
    _ipt(f"iptables -C INPUT -p udp --dport {port} ! -s {ip} -j DROP 2>/dev/null") or \
    _ipt(f"iptables -I INPUT -p udp --dport {port} ! -s {ip} -j DROP")

def remove_limit_rules(port):
    if not port: return
    while True:
        chk = _ipt(f"iptables -S INPUT | grep -E \"--dport {port}\\b\" | head -n1 || true").stdout.strip()
        if not chk: break
        rule = chk.replace("-A", "").strip()
        _ipt(f"iptables -D INPUT {rule}")

def apply_device_limits(users):
    for u in users:
        port = str(u.get("port", "") or "")
        ip = (u.get("bind_ip", "") or "").strip()
        if port and ip: ensure_limit_rules(port, ip)
        elif port and not ip: remove_limit_rules(port)

def load_users():
    v = read_json(USERS_FILE, [])
    return [{"user":u.get("user",""),"password":u.get("password",""),
             "expires":u.get("expires",""),"port":str(u.get("port","")),
             "bind_ip":u.get("bind_ip","")} for u in v]

def save_users(users): write_json_atomic(USERS_FILE, users)

def pick_free_port():
    used = {str(u.get("port","")) for u in load_users() if str(u.get("port",""))}
    used |= get_udp_listen_ports()
    for p in range(6000, 20000):
        if str(p) not in used: return str(p)
    return ""

def login_enabled(): return bool(ADMIN_USER and ADMIN_PASS)
def is_authed(): return session.get("auth") == True
def require_login(): return not login_enabled() or is_authed()

HTML = """<!doctype html>
<html lang="my">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ZIVPN Panel</title>
<style>
:root{
 --bg:#0b0f14;--fg:#e6edf3;--muted:#a0abb7;--card:#111823;--bd:#1f2a37;
 --ok:#22c55e;--bad:#ef4444;--unk:#9ca3af;--btn:#0d141d;--btnbd:#334155;
 --green:#16a34a;
}
body{background:var(--bg);color:var(--fg);font-family:system-ui,Segoe UI,Roboto,Arial;margin:0;padding:16px}
header{position:sticky;top:0;background:var(--bg);padding:10px 0;z-index:10;border-bottom:1px solid var(--bd)}
.wrap{max-width:1060px;margin:auto}
.btn{padding:10px 14px;border:1px solid var(--btnbd);border-radius:10px;background:var(--btn);color:var(--fg);text-decoration:none}
.btn-green{background:var(--green);border:none;color:#fff}
.box{background:var(--card);padding:14px;border-radius:12px;border:1px solid var(--bd);margin:10px 0}
input{width:100%;padding:12px;margin-top:4px;border-radius:10px;border:1px solid var(--bd);background:#0a1220;color:var(--fg)}
.footer-save{margin-top:12px;text-align:center}
table{width:100%;border-collapse:collapse;margin-top:10px}
th,td{border:1px solid var(--bd);padding:8px;text-align:left}
th{background:#101826}
.pill{padding:4px 10px;border-radius:10px}
.ok{background:var(--ok);color:var(--bg)}.bad{background:var(--bad);color:var(--bg)}.unk{background:var(--unk);color:var(--bg)}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.55);display:none;align-items:center;justify-content:center}
.modal .card{background:var(--card);padding:16px;border-radius:12px;width:min(90vw,420px)}
.close{background:#1a2433;border:none;border-radius:8px;padding:5px 10px;color:#fff}
</style></head><body>
<header>
 <div class="wrap">
  <h2>ZIVPN Web Panel</h2>
  <div class="sub">Total: {{ totals.total }} | Online: {{ totals.online }} | Offline: {{ totals.offline }}</div>
  {% if authed %}<a class="btn" href="/logout">Logout</a>{% endif %}
 </div>
</header>
<div class="wrap">
{% if not authed %}
  <div class="box" style="max-width:440px;margin:40px auto">
    <form method="post" action="/login">
      <label>Username</label><input name="u" required>
      <label>Password</label><input name="p" type="password" required>
      <div class="footer-save"><button class="btn-green" style="width:100%;height:48px">Login</button></div>
    </form>
  </div>
{% else %}
<div class="box">
  <h3>➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
  <form method="post" action="/add">
    <label>👤 User</label><input name="user" required>
    <label>🔑 Password</label><input name="password" required>
    <label>⏰ Expires</label><input name="expires" placeholder="2025-12-31 or 30">
    <label>🔌 Port</label><input name="port" placeholder="auto">
    <label>📱 Bind IP</label><input name="bind_ip" placeholder="auto">
    <div class="footer-save"><button class="btn-green" style="width:100%;height:48px">Save + Sync</button></div>
  </form>
</div>
<table>
<tr><th>User</th><th>Password</th><th>Expires</th><th>Port</th><th>Bind IP</th><th>Status</th><th>Edit</th><th>Del</th></tr>
{% for u in users %}
<tr>
 <td>{{u.user}}</td><td>{{u.password}}</td><td>{{u.expires}}</td><td>{{u.port}}</td><td>{{u.bind_ip}}</td>
 <td>{% if u.status=="Online" %}<span class="pill ok">Online{% elif u.status=="Offline" %}<span class="pill bad">Offline{% else %}<span class="pill unk">Unknown{% endif %}</span></td>
 <td><button onclick="editUser('{{u.user}}','{{u.password}}','{{u.expires}}','{{u.port}}','{{u.bind_ip}}')" class="btn">✏️</button></td>
 <td><form method="post" action="/delete"><input type="hidden" name="user" value="{{u.user}}"><button class="btn">🗑️</button></form></td>
</tr>{% endfor %}
</table>

<div id="modal" class="modal">
 <div class="card">
  <div style="display:flex;justify-content:space-between;align-items:center"><h3>Edit User</h3><button class="close" onclick="closeEdit()">×</button></div>
  <form id="editForm" onsubmit="return saveEdit(event)">
   <input type="hidden" id="orig">
   <label>User</label><input id="e_user" required>
   <label>Password</label><input id="e_pass" required>
   <label>Expires</label><input id="e_exp">
   <label>Port</label><input id="e_port">
   <label>Bind IP</label><input id="e_ip">
   <div class="footer-save"><button class="btn-green" style="width:100%;height:48px">Save</button></div>
  </form>
 </div>
</div>

<script>
function editUser(u,p,e,po,ip){
 document.getElementById("modal").style.display="flex";
 document.getElementById("orig").value=u;
 e_user.value=u; e_pass.value=p; e_exp.value=e; e_port.value=po; e_ip.value=ip;
}
function closeEdit(){document.getElementById("modal").style.display="none";}
async function saveEdit(ev){
 ev.preventDefault();
 const body={orig:orig.value,user:e_user.value,password:e_pass.value,expires:e_exp.value,port:e_port.value,bind_ip:e_ip.value};
 const r=await fetch("/api/user.save",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});
 const j=await r.json(); if(j.ok){location.reload();} else alert(j.err||"Error");
}
</script>
{% endif %}
</div></body></html>
"""

def build_view(msg="", err=""):
    if not require_login():
        return render_template_string(HTML, authed=False, logo=LOGO_URL, err=session.pop("login_err", None))
    users = load_users()
    changed = False
    for u in users:
        if u.get("port") and not u.get("bind_ip"):
            ip = first_recent_src_ip(u["port"])
            if ip: u["bind_ip"] = ip; changed = True
    if changed: save_users(users)
    apply_device_limits(users)
    active = get_udp_listen_ports()
    listen_port = get_listen_port_from_config()
    today = datetime.now().strftime("%Y-%m-%d")
    view = []
    online=offline=0
    for u in users:
        st = status_for_user(u, active, listen_port)
        if st=="Online": online+=1
        elif st=="Offline": offline+=1
        view.append(type("U",(),u|{"status":st}))
    totals={"total":len(view),"online":online,"offline":offline}
    return render_template_string(HTML, authed=True, logo=LOGO_URL, users=view, totals=totals, msg=msg, err=err)

@app.route("/", methods=["GET"]) 
def index(): return build_view()

@app.route("/login", methods=["GET","POST"])
def login():
    if not login_enabled(): return redirect(url_for("index"))
    if request.method=="POST":
        u=request.form.get("u","").strip(); p=request.form.get("p","").strip()
        if hmac.compare_digest(u,ADMIN_USER) and hmac.compare_digest(p,ADMIN_PASS):
            session["auth"]=True; return redirect(url_for("index"))
        session["auth"]=False; session["login_err"]="Invalid Login"; return redirect(url_for("login"))
    return render_template_string(HTML, authed=False, logo=LOGO_URL)

@app.route("/logout")
def logout(): session.pop("auth",None); return redirect(url_for("login"))

@app.route("/add", methods=["POST"])
def add_user():
    if not require_login(): return redirect(url_for("login"))
    user=request.form.get("user","").strip()
    pw=request.form.get("password","").strip()
    exp=request.form.get("expires","").strip()
    port=request.form.get("port","").strip()
    ip=request.form.get("bind_ip","").strip()
    if exp.isdigit(): exp=(datetime.now()+timedelta(days=int(exp))).strftime("%Y-%m-%d")
    users=load_users(); found=False
    for u in users:
        if u["user"].lower()==user.lower():
            u.update({"password":pw,"expires":exp,"port":port,"bind_ip":ip}); found=True
    if not found: users.append({"user":user,"password":pw,"expires":exp,"port":port or pick_free_port(),"bind_ip":ip})
    save_users(users)
    return redirect(url_for("index"))

@app.route("/delete", methods=["POST"])
def delete_user():
    if not require_login(): return redirect(url_for("login"))
    user=request.form.get("user","").strip().lower()
    remain=[u for u in load_users() if u.get("user","").lower()!=user]
    save_users(remain)
    return redirect(url_for("index"))

@app.route("/api/user.save", methods=["POST"])
def api_user_save():
    if not require_login(): return make_response(jsonify({"ok":False,"err":"login required"}),401)
    d=request.get_json(silent=True) or {}
    orig=d.get("orig","").lower(); users=load_users(); found=False
    for u in users:
        if u.get("user","").lower()==orig:
            u.update({"user":d.get("user"),"password":d.get("password"),"expires":d.get("expires"),
                      "port":d.get("port"),"bind_ip":d.get("bind_ip")}); found=True
    if not found: return jsonify({"ok":False,"err":"not found"}),404
    save_users(users)
    return jsonify({"ok":True})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
PY
