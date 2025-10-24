from flask import Flask, jsonify, render_template_string, request, redirect, url_for, session, make_response
import json, subprocess, os, tempfile, hmac, re
from datetime import datetime, timedelta

# ===== Files / Const =====
USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LISTEN_FALLBACK = "5667"
RECENT_SECONDS = 180
LOGO_URL = "https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png"

# ===== App / Admin =====
app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET","dev-secret-change-me")
ADMIN_USER = os.environ.get("WEB_ADMIN_USER","").strip()
ADMIN_PASS = os.environ.get("WEB_ADMIN_PASSWORD","").strip()

# ===== Utils =====
def read_json(path, default):
    try:
        with open(path,"r") as f: return json.load(f)
    except Exception:
        return default

def write_json_atomic(path, data):
    d=json.dumps(data, ensure_ascii=False, indent=2)
    dirn=os.path.dirname(path); os.makedirs(dirn, exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=".tmp-", dir=dirn)
    try:
        with os.fdopen(fd,"w") as f: f.write(d)
        os.replace(tmp,path)
    finally:
        try: os.remove(tmp)
        except: pass

def shell(cmd):  # returns CompletedProcess
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def get_listen_port_from_config():
    cfg=read_json(CONFIG_FILE,{})
    listen=str(cfg.get("listen","")).strip()
    m=re.search(r":(\d+)$", listen) if listen else None
    return (m.group(1) if m else LISTEN_FALLBACK)

def get_udp_listen_ports():
    out=shell("ss -uHln").stdout
    return set(re.findall(r":(\d+)\s", out))

def load_users():
    v=read_json(USERS_FILE,[])
    out=[]
    for u in v:
        out.append({
            "user":u.get("user",""),
            "password":u.get("password",""),
            "expires":u.get("expires",""),
            "port":str(u.get("port","")) if u.get("port","")!="" else "",
            "bind_ip":u.get("bind_ip","")
        })
    return out

def save_users(users): write_json_atomic(USERS_FILE, users)

def pick_free_port():
    used={str(u.get("port","")) for u in load_users() if str(u.get("port",""))}
    used |= get_udp_listen_ports()
    for p in range(6000,20000):
        if str(p) not in used: return str(p)
    return ""

def _ct_recent_line_for_port(port):
    # Narrow first by dport then accept both directions, take first recent
    cmd = f"conntrack -L -p udp 2>/dev/null | grep -w 'dport={port}' | head -n1 || true"
    return shell(cmd).stdout.strip()

def has_recent_udp_activity_for_port(port):
    return bool(_ct_recent_line_for_port(port))

def first_recent_src_ip(port):
    if not port: return ""
    out=_ct_recent_line_for_port(port)
    if not out: return ""
    m=re.search(r"\bsrc=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\b", out)
    ip=m.group(1) if m else ""
    return ip if re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}", ip or "") else ""

def status_for_user(u, active_ports, listen_port):
    port=str(u.get("port",""))
    check_port=port if port else listen_port
    if has_recent_udp_activity_for_port(check_port): return "Online"
    if check_port in active_ports: return "Offline"
    return "Unknown"

# ---- iptables device limit (bind_ip) ----
def _ipt(cmd): return shell(cmd)
def ensure_limit_rules(port, ip):
    if not (port and ip): return
    _ipt(f"iptables -C INPUT -p udp --dport {port} -s {ip} -j ACCEPT 2>/dev/null") or _ipt(f"iptables -I INPUT -p udp --dport {port} -s {ip} -j ACCEPT")
    _ipt(f"iptables -C INPUT -p udp --dport {port} ! -s {ip} -j DROP 2>/dev/null") or _ipt(f"iptables -I INPUT -p udp --dport {port} ! -s {ip} -j DROP")

def remove_limit_rules(port):
    if not port: return
    # remove both ACCEPT/DROP rules for this dport
    while True:
        chk=_ipt(f"iptables -S INPUT | grep -E \"-p udp .* --dport {port}\\b .* (-j DROP|-j ACCEPT)\" | head -n1 || true").stdout.strip()
        if not chk: break
        rule=chk.replace("-A","").strip()
        _ipt(f"iptables -D INPUT {rule}")

def apply_device_limits(users):
    for u in users:
        port=str(u.get("port","") or "")
        ip=(u.get("bind_ip","") or "").strip()
        if port and ip:
            ensure_limit_rules(port, ip)
        elif port and not ip:
            remove_limit_rules(port)

# ---- auth helpers ----
def login_enabled(): return bool(ADMIN_USER and ADMIN_PASS)
def is_authed(): return session.get("auth") == True
def require_login():
    if login_enabled() and not is_authed(): return False
    return True

# ---- sync passwords to config.json ----
def sync_config_passwords(mode="mirror"):
    cfg=read_json(CONFIG_FILE,{})
    users=load_users()
    users_pw=sorted({str(u["password"]) for u in users if u.get("password")})
    if mode=="merge":
        old=[]
        if isinstance(cfg.get("auth",{}).get("config",None), list):
            old=list(map(str, cfg["auth"]["config"]))
        new_pw=sorted(set(old)|set(users_pw))
    else:
        new_pw=users_pw
    if not isinstance(cfg.get("auth"),dict): cfg["auth"]={}
    cfg["auth"]["mode"]="passwords"
    cfg["auth"]["config"]=new_pw
    cfg["listen"]=cfg.get("listen") or ":5667"
    cfg["cert"]=cfg.get("cert") or "/etc/zivpn/zivpn.crt"
    cfg["key"]=cfg.get("key") or "/etc/zivpn/zivpn.key"
    cfg["obfs"]=cfg.get("obfs") or "zivpn"
    write_json_atomic(CONFIG_FILE,cfg)
    shell("systemctl restart zivpn.service")

# ===== HTML (modal + android-friendly) =====
HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta http-equiv="refresh" content="120">
<title>ZIVPN Panel</title>
<style>
 :root{
  --bg:#0b0f14; --fg:#e6edf3; --muted:#a0abb7; --card:#111823; --bd:#1f2a37;
  --ok:#22c55e; --bad:#ef4444; --unk:#9ca3af; --btn:#0d141d; --btnbd:#334155; --brand:#16a34a;
 }
 *{box-sizing:border-box}
 html,body{background:var(--bg);color:var(--fg)}
 body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:0;padding:16px}
 header{position:sticky;top:0;background:var(--bg);padding:10px 0 12px;z-index:10;border-bottom:1px solid var(--bd)}
 .wrap{max-width:1060px;margin:0 auto}
 .row{display:flex;gap:12px;align-items:center;flex-wrap:wrap}
 h1{margin:0;font-size:20px;font-weight:800}
 .sub{color:var(--muted);font-size:13px}
 .btn{padding:10px 14px;border-radius:10px;border:1px solid var(--btnbd);
      background:var(--btn);color:var(--fg);text-decoration:none;cursor:pointer}
 .btn-green{background:var(--brand);border-color:#0c762f}
 .chip{display:inline-block;padding:8px 12px;border:1px solid var(--bd);border-radius:999px;background:#0f1624;font-size:12px}
 table{border-collapse:collapse;width:100%}
 th,td{border:1px solid var(--bd);padding:10px;text-align:left}
 th{background:var(--card);font-size:13px}
 td{font-size:14px}
 .pill{display:inline-block;padding:4px 10px;border-radius:999px}
 .ok{color:var(--bg);background:var(--ok)}
 .bad{color:var(--bg);background:var(--bad)}
 .unk{color:var(--bg);background:var(--unk)}
 .muted{color:var(--muted)}
 .box{margin:14px 0;padding:12px;border:1px solid var(--bd);border-radius:14px;background:var(--card)}
 label{display:block;margin:6px 0 3px;font-size:13px;color:var(--muted)}
 input{width:100%;max-width:520px;padding:12px;border:1px solid var(--bd);border-radius:12px;background:#0a1220;color:var(--fg)}
 .form-inline{display:flex;gap:10px;flex-wrap:wrap}
 .form-inline > div{min-width:180px;flex:1}
 .footer-save{position:sticky;bottom:8px}
 /* modal */
 .modal{position:fixed;inset:0;display:none;background:rgba(0,0,0,.55);backdrop-filter:blur(2px);align-items:center;justify-content:center;z-index:20}
 .modal .card{width:min(92vw,520px);background:var(--card);border:1px solid var(--bd);border-radius:16px;padding:16px}
 .modal .head{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}
 .close{border:1px solid var(--bd);background:#1a2433;border-radius:10px;padding:6px 10px;cursor:pointer}
 @media (max-width:480px){ body{padding:12px} th,td{font-size:13px} .btn{padding:10px 12px} }
</style></head><body>
<header>
 <div class="wrap row">
   <img src="{{ logo }}" alt="DEV-U PHOE KAUNT" style="height:40px;width:auto;border-radius:10px">
   <div style="flex:1">
     <h1>DEV-U PHOE KAUNT • ZIVPN</h1>
     <div class="sub">
       <span class="chip">Total {{ totals.total }}</span>
       <span class="chip">Online {{ totals.online }}</span>
       <span class="chip">Offline {{ totals.offline }}</span>
       <span class="chip">Expired {{ totals.expired }}</span>
     </div>
   </div>
   <div class="row">
     <a class="btn" href="/scan">🔄 Scan Online</a>
     <a class="btn" href="https://m.me/upkvpnfastvpn" target="_blank" rel="noopener">💬 Messenger</a>
     {% if authed %}<a class="btn" href="/logout">Logout</a>{% endif %}
   </div>
 </div>
</header>

<div class="wrap">
{% if not authed %}
  <div class="box" style="max-width:440px;margin:40px auto">
    {% if err %}<div style="color:var(--bad);margin-bottom:8px">{{err}}</div>{% endif %}
    <form method="post" action="/login" style="margin-top:10px">
      <label>Username</label><input name="u" autofocus required>
      <label style="margin-top:8px">Password</label><input name="p" type="password" required>
      <div class="footer-save" style="margin-top:12px"><button class="btn btn-green" type="submit" style="width:100%;height:52px;font-size:16px">Login</button></div>
    </form>
  </div>
{% else %}

<div class="box">
  <h3 style="margin:4px 0 8px">➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
  {% if msg %}<div style="color:var(--ok);margin:6px 0">{{msg}}</div>{% endif %}
  {% if err %}<div style="color:var(--bad);margin:6px 0">{{err}}</div>{% endif %}
  <form method="post" action="/add" class="form-inline" id="addForm">
    <div><label>👤 User</label><input name="user" required></div>
    <div><label>🔑 Password</label><input name="password" required></div>
    <div><label>⏰ Expires</label><input name="expires" placeholder="2025-12-31 or 30"></div>
    <div><label>🔌 UDP Port</label><input name="port" placeholder="auto"></div>
    <div><label>📱 Bind IP (1 device)</label><input name="bind_ip" placeholder="auto when online…"></div>
    <div class="footer-save" style="flex-basis:100%">
      <button class="btn btn-green" type="submit" style="width:100%;height:52px;font-size:16px">Save + Sync</button>
    </div>
  </form>
</div>

<table>
  <tr>
    <th>👤 User</th><th>🔑 Password</th><th>⏰ Expires</th>
    <th>🔌 Port</th><th>📱 Bind IP</th><th>🔎 Status</th><th>✏️ Edit</th><th>🗑️ Del</th>
  </tr>
  {% for u in users %}
  <tr>
    <td>{{u.user}}</td>
    <td>{{u.password}}</td>
    <td>{% if u.expires %}{{u.expires}}{% else %}<span class="muted">—</span>{% endif %}</td>
    <td>{% if u.port %}{{u.port}}{% else %}<span class="muted">—</span>{% endif %}</td>
    <td>{% if u.bind_ip %}{{u.bind_ip}}{% else %}<span class="muted">—</span>{% endif %}</td>
    <td>
      {% if u.status == "Online" %}<span class="pill ok">Online</span>
      {% elif u.status == "Offline" %}<span class="pill bad">Offline</span>
      {% else %}<span class="pill unk">Unknown</span>
      {% endif %}
    </td>
    <td>
      <button type="button" class="btn" onclick="openEdit('{{u.user}}');return false;">✏️</button>
    </td>
    <td>
      <form method="post" action="/delete" onsubmit="return confirm('ဖျက်မလား?')" style="display:inline">
        <input type="hidden" name="user" value="{{u.user}}">
        <button type="submit" class="btn">🗑️</button>
      </form>
    </td>
  </tr>
  {% endfor %}
</table>

<!-- ===== Modal Edit ===== -->
<div class="modal" id="editModal">
  <div class="card">
    <div class="head">
      <h3 style="margin:0">✏️ Edit</h3>
      <button class="close" onclick="closeEdit()">×</button>
    </div>
    <form id="editForm" onsubmit="return saveEdit(event)">
      <input type="hidden" id="orig">
      <label>User</label><input id="e_user" required>
      <label style="margin-top:8px">Password</label><input id="e_password" required>
      <label style="margin-top:8px">Expires</label><input id="e_expires" placeholder="2025-12-31 or 30">
      <label style="margin-top:8px">UDP Port</label><input id="e_port" placeholder="auto">
      <label style="margin-top:8px">Bind IP (1 device)</label><input id="e_bind">
      <div class="footer-save" style="margin-top:12px">
        <button class="btn btn-green" type="submit" style="width:100%;height:52px;font-size:16px">Save</button>
      </div>
    </form>
  </div>
</div>

<script>
async function openEdit(user){
  try{
    const r = await fetch('/api/user.get?user='+encodeURIComponent(user));
    const j = await r.json();
    if(!j || !j.user){alert('Not found');return}
    document.getElementById('orig').value = j.user;
    document.getElementById('e_user').value = j.user||'';
    document.getElementById('e_password').value = j.password||'';
    document.getElementById('e_expires').value = j.expires||'';
    document.getElementById('e_port').value = j.port||'';
    document.getElementById('e_bind').value = j.bind_ip||'';
    document.getElementById('editModal').style.display='flex';
  }catch(e){ alert('Error'); }
}
function closeEdit(){ document.getElementById('editModal').style.display='none'; }
async function saveEdit(ev){
  ev.preventDefault();
  const body={
    orig: document.getElementById('orig').value,
    user: document.getElementById('e_user').value.trim(),
    password: document.getElementById('e_password').value.trim(),
    expires: document.getElementById('e_expires').value.trim(),
    port: document.getElementById('e_port').value.trim(),
    bind_ip: document.getElementById('e_bind').value.trim()
  };
  const r = await fetch('/api/user.save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const j = await r.json();
  if(j && j.ok){ closeEdit(); location.reload(); } else { alert(j.err||'Failed'); }
  return false;
}
</script>

{% endif %}
</div>
</body></html>
"""

# ===== View / Counters =====
def build_view(msg="", err=""):
    if not require_login():
        return render_template_string(HTML, authed=False, logo=LOGO_URL, err=session.pop("login_err", None))

    users=load_users()

    # auto-capture bind_ip if currently online but empty
    changed=False
    for u in users:
        if u.get("port") and not u.get("bind_ip"):
            ip=first_recent_src_ip(u["port"])
            if ip:
                u["bind_ip"]=ip; changed=True
    if changed: save_users(users)

    apply_device_limits(users)

    active=get_udp_listen_ports()
    listen_port=get_listen_port_from_config()

    view=[]
    online=offline=unknown=expired=0
    today=datetime.now().strftime("%Y-%m-%d")
    for u in users:
        st=status_for_user(u,active,listen_port)
        if st=="Online": online+=1
        elif st=="Offline": offline+=1
        else: unknown+=1
        if u.get("expires") and str(u["expires"])<=today:
            expired+=1
        view.append(type("U",(),{
            "user":u.get("user",""),
            "password":u.get("password",""),
            "expires":u.get("expires",""),
            "port":u.get("port",""),
            "bind_ip":u.get("bind_ip",""),
            "status":st
        }))
    view.sort(key=lambda x:(x.user or "").lower())
    totals={"total":len(view),"online":online,"offline":offline,"expired":expired}
    return render_template_string(HTML, authed=True, logo=LOGO_URL, users=view, msg=msg, err=err, totals=totals)

# ===== Routes =====
@app.route("/scan", methods=["GET"])
def scan():  # refresh device limits + quick redirect
    apply_device_limits(load_users())
    return redirect(url_for('index'))

@app.route("/login", methods=["GET","POST"])
def login():
    if not login_enabled(): return redirect(url_for('index'))
    if request.method=="POST":
        u=(request.form.get("u") or "").strip()
        p=(request.form.get("p") or "").strip()
        if hmac.compare_digest(u, ADMIN_USER) and hmac.compare_digest(p, ADMIN_PASS):
            session["auth"]=True; return redirect(url_for('index'))
        session["auth"]=False; session["login_err"]="မှန်ကန်မှုမရှိပါ (username/password)"; return redirect(url_for('login'))
    return render_template_string(HTML, authed=False, logo=LOGO_URL, err=session.pop("login_err", None))

@app.route("/logout", methods=["GET"])
def logout():
    session.pop("auth", None)
    return redirect(url_for('login') if login_enabled() else url_for('index'))

@app.route("/", methods=["GET"])
def index(): return build_view()

@app.route("/add", methods=["POST"])
def add_user():
    if not require_login(): return redirect(url_for('login'))
    user=(request.form.get("user") or "").strip()
    password=(request.form.get("password") or "").strip()
    expires=(request.form.get("expires") or "").strip()
    port=(request.form.get("port") or "").strip()
    bind_ip=(request.form.get("bind_ip") or "").strip()

    if expires.isdigit():
        expires=(datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")

    if not user or not password: return build_view(err="User နှင့် Password လိုအပ်သည်")
    if expires:
        try: datetime.strptime(expires,"%Y-%m-%d")
        except ValueError: return build_view(err="Expires format မမှန်ပါ (YYYY-MM-DD)")
    if port:
        if not re.fullmatch(r"\d{2,5}",port) or not (6000 <= int(port) <= 19999):
            return build_view(err="Port အကွာအဝေး 6000-19999")
    else:
        port=pick_free_port()

    users=load_users(); replaced=False
    for u in users:
        if u.get("user","").lower()==user.lower():
            u.update({"password":password,"expires":expires,"port":port,"bind_ip":bind_ip}); replaced=True; break
    if not replaced:
        users.append({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip})
    save_users(users); sync_config_passwords()
    return build_view(msg="Saved & Synced")

@app.route("/delete", methods=["POST"])
def delete_user_html():
    if not require_login(): return redirect(url_for('login'))
    user = (request.form.get("user") or "").strip()
    if not user: return build_view(err="User လိုအပ်သည်")
    remain=[]; removed=None
    for u in load_users():
        if u.get("user","").lower()==user.lower(): removed=u
        else: remain.append(u)
    if removed and removed.get("port"): remove_limit_rules(removed.get("port"))
    save_users(remain); sync_config_passwords(mode="mirror")
    return build_view(msg=f"Deleted: {user}")

# === API for modal edit ===
@app.route("/api/user.get", methods=["GET"])
def api_user_get():
    if not require_login(): return make_response(jsonify({"ok": False, "err":"login required"}), 401)
    q=(request.args.get("user") or "").strip().lower()
    users=load_users()
    for u in users:
        if u.get("user","").lower()==q:
            return jsonify({"user":u.get("user"),"password":u.get("password"),
                            "expires":u.get("expires"),"port":u.get("port"),"bind_ip":u.get("bind_ip")})
    return jsonify({"err":"not_found"}), 404

@app.route("/api/user.save", methods=["POST"])
def api_user_save():
    if not require_login(): return make_response(jsonify({"ok": False, "err":"login required"}), 401)
    data=request.get_json(silent=True) or {}
    orig=(data.get("orig") or "").strip().lower()
    user=(data.get("user") or "").strip()
    password=(data.get("password") or "").strip()
    expires=(data.get("expires") or "").strip()
    port=(data.get("port") or "").strip()
    bind_ip=(data.get("bind_ip") or "").strip()

    if expires.isdigit():
        expires=(datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")
    if not user or not password: return jsonify({"ok":False,"err":"user/password required"}),400
    if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)):
        return jsonify({"ok":False,"err":"invalid port"}),400
    users=load_users(); found=False
    for u in users:
        if u.get("user","").lower()==orig:
            if u.get("port") and (str(u.get("port"))!=str(port) or (u.get("bind_ip","")!=bind_ip)):
                remove_limit_rules(u.get("port"))
            u.update({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip})
            found=True; break
    if not found:
        return jsonify({"ok":False,"err":"not found"}),404
    save_users(users); sync_config_passwords(); apply_device_limits(users)
    return jsonify({"ok":True})

@app.route("/api/users", methods=["GET"])
def api_users():
    if not require_login(): return make_response(jsonify({"ok": False, "err":"login required"}), 401)
    users=load_users(); active=get_udp_listen_ports(); listen_port=get_listen_port_from_config()
    for u in users: u["status"]=status_for_user(u,active,listen_port)
    return jsonify(users)

@app.route("/favicon.ico", methods=["GET"])
def favicon(): return ("",204)

@app.errorhandler(405)
def handle_405(e): return redirect(url_for('index'))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
