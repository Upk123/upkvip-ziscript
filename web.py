from flask import Flask, jsonify, render_template_string, request, redirect, url_for, session, make_response
import json, subprocess, os, tempfile, hmac, re
from datetime import datetime, timedelta

# ===== Files =====
USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LISTEN_FALLBACK = "5667"
RECENT_SECONDS = 120

# ===== Branding =====
LOGO_URL = "https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png"
TITLE = "DEV-U PHOE KAUNT • ZIVPN"

# ===== Flask / Admin =====
app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET","dev-secret-change-me")
ADMIN_USER = os.environ.get("WEB_ADMIN_USER","").strip()
ADMIN_PASS = os.environ.get("WEB_ADMIN_PASSWORD","").strip()

# ===== Utils =====
def read_json(path, default):
    try:
        with open(path,"r") as f:
            return json.load(f)
    except Exception:
        return default

def write_json_atomic(path, data):
    d = json.dumps(data, ensure_ascii=False, indent=2)
    dirn = os.path.dirname(path)
    os.makedirs(dirn, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=dirn)
    try:
        with os.fdopen(fd,"w") as f:
            f.write(d)
        os.replace(tmp, path)
    finally:
        try: os.remove(tmp)
        except: pass

def shell(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def load_users():
    v = read_json(USERS_FILE, [])
    out = []
    for u in v:
        out.append({
            "user": u.get("user",""),
            "password": u.get("password",""),
            "expires": u.get("expires",""),
            "port": str(u.get("port","")) if str(u.get("port","")) else "",
            "bind_ip": u.get("bind_ip","")
        })
    return out

def save_users(users): write_json_atomic(USERS_FILE, users)

def get_listen_port_from_config():
    cfg = read_json(CONFIG_FILE,{})
    listen = str(cfg.get("listen","")).strip()
    m = re.search(r":(\d+)$", listen) if listen else None
    return (m.group(1) if m else LISTEN_FALLBACK)

def get_udp_listen_ports():
    out = shell("ss -uHln").stdout
    return set(re.findall(r":(\d+)\s", out))

def pick_free_port():
    used = {str(u.get("port","")) for u in load_users() if str(u.get("port",""))}
    used |= get_udp_listen_ports()
    for p in range(6000,20000):
        if str(p) not in used:
            return str(p)
    return ""

def has_recent_udp_activity_for_port(port):
    if not port: return False
    out = shell(f"conntrack -L -p udp 2>/dev/null | grep -w 'dport={port}' | head -n1 || true").stdout
    return bool(out.strip())

def first_recent_src_ip(port):
    if not port: return ""
    out = shell(
        "conntrack -L -p udp 2>/dev/null | "
        f"awk '/dport={port}\\b/ {{for(i=1;i<=NF;i++) if($i~/src=/){{split($i,a,\"=\"); print a[2]; exit}}}}'"
    ).stdout.strip()
    return out if re.fullmatch(r"(\\d{1,3}\\.){3}\\d{1,3}", out) else out

def status_for_user(u, active_ports, listen_port):
    port = str(u.get("port",""))
    check_port = port if port else listen_port
    if has_recent_udp_activity_for_port(check_port): return "Online"
    if check_port in active_ports: return "Offline"
    return "Unknown"

def _ipt(cmd): return shell(cmd)

def ensure_limit_rules(port, ip):
    if not (port and ip): return
    _ipt(f"iptables -C INPUT -p udp --dport {port} -s {ip} -j ACCEPT 2>/dev/null") \
        or _ipt(f"iptables -I INPUT -p udp --dport {port} -s {ip} -j ACCEPT")
    _ipt(f"iptables -C INPUT -p udp --dport {port} ! -s {ip} -j DROP 2>/dev/null") \
        or _ipt(f"iptables -I INPUT -p udp --dport {port} ! -s {ip} -j DROP")

def remove_limit_rules(port):
    if not port: return
    # remove any ACCEPT/DROP rules for this dport
    lines = shell("iptables -S INPUT").stdout.splitlines()
    for line in lines:
        if f"--dport {port}" in line and (" -j DROP" in line or " -j ACCEPT" in line):
            rule = line.replace("-A ","").strip()
            _ipt(f"iptables -D INPUT {rule}")

def apply_device_limits(users):
    for u in users:
        port = str(u.get("port","") or "")
        ip = (u.get("bind_ip","") or "").strip()
        if port and ip:
            ensure_limit_rules(port, ip)
        elif port and not ip:
            remove_limit_rules(port)

def login_enabled(): return bool(ADMIN_USER and ADMIN_PASS)
def is_authed(): return session.get("auth") is True
def require_login():
    if login_enabled() and not is_authed():
        return False
    return True

def sync_config_passwords(mode="mirror"):
    cfg = read_json(CONFIG_FILE,{})
    users = load_users()
    users_pw = sorted({str(u["password"]) for u in users if u.get("password")})
    if mode == "merge":
        old = []
        if isinstance(cfg.get("auth",{}).get("config",None), list):
            old = list(map(str, cfg["auth"]["config"]))
        new_pw = sorted(set(old)|set(users_pw))
    else:
        new_pw = users_pw
    if not isinstance(cfg.get("auth"),dict): cfg["auth"]={}
    cfg["auth"]["mode"]="passwords"
    cfg["auth"]["config"]=new_pw
    cfg["listen"]=cfg.get("listen") or ":5667"
    cfg["cert"]=cfg.get("cert") or "/etc/zivpn/zivpn.crt"
    cfg["key"]=cfg.get("key") or "/etc/zivpn/zivpn.key"
    cfg["obfs"]=cfg.get("obfs") or "zivpn"
    write_json_atomic(CONFIG_FILE,cfg)
    shell("systemctl restart zivpn.service")

# ===== HTML (Android-friendly, counters + green Save, inline Edit page) =====
HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta http-equiv="refresh" content="120">
<title>{{ title }}</title>
<style>
 :root{
  --bg:#0b0f14; --fg:#e6edf3; --muted:#9aa5b1; --card:#0f1622; --bd:#1e293b;
  --ok:#10b981; --bad:#ef4444; --unk:#9ca3af; --btn:#111827; --btnbd:#334155; --green:#10b981;
 }
 html,body{background:var(--bg);color:var(--fg)}
 body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:0;padding:14px}
 header{position:sticky;top:0;background:var(--bg);padding:10px 0 12px;z-index:10;border-bottom:1px solid var(--bd)}
 .wrap{max-width:1000px;margin:0 auto}
 h1{margin:0;font-size:20px;font-weight:800}
 .row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
 .pill{display:inline-block;padding:6px 12px;border-radius:999px;background:#0d1320;border:1px solid var(--bd);font-size:13px}
 .btn{padding:10px 14px;border-radius:10px;border:1px solid var(--btnbd);background:var(--btn);color:var(--fg);text-decoration:none;cursor:pointer}
 .btn-green{background:var(--green);border-color:var(--green);color:#081016;font-weight:800}
 .box{margin:12px 0;padding:12px;border:1px solid var(--bd);border-radius:14px;background:var(--card)}
 label{display:block;margin:6px 0 3px;font-size:13px;color:var(--muted)}
 input{width:100%;max-width:420px;padding:11px 12px;border:1px solid var(--bd);border-radius:12px;background:#0a1220;color:var(--fg)}
 .form-inline{display:flex;gap:10px;flex-wrap:wrap}
 .form-inline > div{min-width:180px;flex:1}
 table{border-collapse:collapse;width:100%}
 th,td{border:1px solid var(--bd);padding:10px;text-align:left}
 th{font-size:13px;background:#0d1624}
 td{font-size:14px}
 .ok{background:var(--ok);color:#04140c}
 .bad{background:var(--bad)}
 .unk{background:var(--unk)}
 .tag{font-size:12px;color:var(--muted)}
 .center{display:flex;align-items:center;gap:10px}
 .right{margin-left:auto}
 .msg{color:var(--ok)}
 .err{color:var(--bad)}
 @media (max-width:480px){ body{padding:10px} th,td{font-size:13px} .btn{padding:10px 12px} }
</style>
</head><body>

<header>
  <div class="wrap row">
    <img src="{{ logo }}" alt="logo" style="height:38px;border-radius:10px">
    <div>
      <h1>{{ title }}</h1>
      <div class="tag">Total {{ counts.total }} • Online {{ counts.online }} • Offline {{ counts.offline }} • Expired {{ counts.expired }}</div>
    </div>
    <div class="right row">
      <a class="btn" href="https://m.me/upkvpnfastvpn" target="_blank" rel="noopener">💬 Messenger</a>
      {% if authed %}<a class="btn" href="/logout">Logout</a>{% endif %}
    </div>
  </div>
</header>

<div class="wrap">
{% if not authed %}
  <div class="box" style="max-width:440px;margin:40px auto">
    {% if err %}<div class="err">{{err}}</div>{% endif %}
    <form method="post" action="/login" style="margin-top:6px">
      <label>Username</label><input name="u" autofocus required>
      <label style="margin-top:8px">Password</label><input name="p" type="password" required>
      <button class="btn btn-green" type="submit" style="margin-top:12px;width:100%">Login</button>
    </form>
  </div>
{% else %}

  <div class="box">
    <h3 style="margin:4px 0 8px">➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
    {% if msg %}<div class="msg">{{msg}}</div>{% endif %}
    {% if err %}<div class="err">{{err}}</div>{% endif %}
    <form method="post" action="/add" class="form-inline">
      <div><label>User</label><input name="user" required></div>
      <div><label>Password</label><input name="password" required></div>
      <div><label>Expires</label><input name="expires" placeholder="YYYY-MM-DD or days"></div>
      <div><label>UDP Port</label><input name="port" placeholder="auto"></div>
      <div><label>Bind IP (1 device)</label><input name="bind_ip" placeholder="auto when online…"></div>
      <div style="flex-basis:100%"></div>
      <div style="width:100%"><button class="btn btn-green" type="submit" style="width:100%">Save + Sync</button></div>
    </form>
  </div>

  <div class="box" style="overflow-x:auto">
    <table>
      <tr>
        <th>User</th><th>Password</th><th>Expires</th><th>Port</th><th>Bind IP</th><th>Status</th><th>Edit</th><th>Del</th>
      </tr>
      {% for u in users %}
      <tr>
        <td>{{u.user}}</td>
        <td>{{u.password}}</td>
        <td>{% if u.expires %}{{u.expires}}{% else %}<span class="tag">—</span>{% endif %}</td>
        <td>{% if u.port %}{{u.port}}{% else %}<span class="tag">—</span>{% endif %}</td>
        <td>{% if u.bind_ip %}<span class="tag">{{u.bind_ip}}</span>{% else %}<span class="tag">—</span>{% endif %}</td>
        <td>
          {% if u.status == "Online" %}<span class="pill ok">Online</span>
          {% elif u.status == "Offline" %}<span class="pill bad">Offline</span>
          {% else %}<span class="pill unk">Unknown</span>
          {% endif %}
        </td>
        <td>
          <form method="get" action="/edit">
            <input type="hidden" name="user" value="{{u.user}}">
            <button class="btn" type="submit">✏️</button>
          </form>
        </td>
        <td>
          <form method="post" action="/delete" onsubmit="return confirm('Delete?')">
            <input type="hidden" name="user" value="{{u.user}}">
            <button class="btn" type="submit">🗑️</button>
          </form>
        </td>
      </tr>
      {% endfor %}
    </table>
  </div>
{% endif %}
</div>
</body></html>
"""

# ===== Views =====
def _counts(view_list):
    total = len(view_list)
    online = sum(1 for x in view_list if x.status == "Online")
    offline = sum(1 for x in view_list if x.status == "Offline")
    today = datetime.now().strftime("%Y-%m-%d")
    expired = sum(1 for x in view_list if x.expires and x.expires < today)
    return {"total": total, "online": online, "offline": offline, "expired": expired}

def build_view(msg="", err=""):
    if not require_login():
        return render_template_string(HTML, authed=False, logo=LOGO_URL, title=TITLE,
                                      err=session.pop("login_err", None),
                                      counts={"total":0,"online":0,"offline":0,"expired":0})
    users = load_users()

    # auto-capture first src ip for online ports (optional)
    changed = False
    for u in users:
        if u.get("port") and not u.get("bind_ip"):
            ip = first_recent_src_ip(u["port"])
            if ip:
                u["bind_ip"] = ip
                changed = True
    if changed: save_users(users)

    apply_device_limits(users)
    active = get_udp_listen_ports()
    listen_port = get_listen_port_from_config()

    view = []
    for u in users:
        view.append(type("U",(),{
            "user": u.get("user",""),
            "password": u.get("password",""),
            "expires": u.get("expires",""),
            "port": u.get("port",""),
            "bind_ip": u.get("bind_ip",""),
            "status": status_for_user(u, active, listen_port)
        }))
    view.sort(key=lambda x:(x.user or "").lower())
    return render_template_string(
        HTML, authed=True, logo=LOGO_URL, title=TITLE, users=view,
        counts=_counts(view), msg=msg, err=err
    )

@app.route("/login", methods=["GET","POST"])
def login():
    if request.method=="POST":
        if not login_enabled(): return redirect(url_for('index'))
        u=(request.form.get("u") or "").strip()
        p=(request.form.get("p") or "").strip()
        if hmac.compare_digest(u, ADMIN_USER) and hmac.compare_digest(p, ADMIN_PASS):
            session["auth"]=True
            return redirect(url_for('index'))
        session["auth"]=False
        session["login_err"]="မှန်ကန်မှုမရှိပါ (username/password)"
        return redirect(url_for('login'))
    # GET
    if not login_enabled():
        return redirect(url_for('index'))
    return render_template_string(HTML, authed=False, logo=LOGO_URL, title=TITLE,
                                  err=session.pop("login_err", None),
                                  counts={"total":0,"online":0,"offline":0,"expired":0})

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

    if not user or not password:
        return build_view(err="User နှင့် Password လိုအပ်သည်")
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

@app.route("/edit", methods=["GET","POST"])
def edit_user():
    if not require_login(): return redirect(url_for('login'))
    if request.method=="GET":
        q=(request.args.get("user") or "").strip().lower()
        users=load_users(); target=[u for u in users if u.get("user","").lower()==q]
        if not target: return build_view(err="မတွေ့ပါ")
        u=target[0]
        frm = """
        <div class='box'>
          <h3 style='margin:0 0 10px'>✏️ Edit: """+u.get('user','')+"""</h3>
          <form method='post' action='/edit' class='form-inline'>
            <input type='hidden' name='orig' value='"""+u.get('user','')+"""'>
            <div><label>User</label><input name='user' value='"""+u.get('user','')+"""' required></div>
            <div><label>Password</label><input name='password' value='"""+u.get('password','')+"""' required></div>
            <div><label>Expires</label><input name='expires' value='"""+(u.get('expires','') or '')+"""' placeholder='YYYY-MM-DD or days'></div>
            <div><label>UDP Port</label><input name='port' value='"""+str(u.get('port',''))+"""'></div>
            <div><label>Bind IP</label><input name='bind_ip' value='"""+(u.get('bind_ip','') or '')+"""' placeholder='blank = no lock'></div>
            <div style='flex-basis:100%'></div>
            <div style='width:100%'><button class='btn btn-green' type='submit' style='width:100%'>Save</button></div>
          </form>
        </div>"""
        base = build_view()
        return base.replace("</div>\n</body>","</div>"+frm+"</body>")
    # POST
    orig=(request.form.get("orig") or "").strip().lower()
    user=(request.form.get("user") or "").strip()
    password=(request.form.get("password") or "").strip()
    expires=(request.form.get("expires") or "").strip()
    port=(request.form.get("port") or "").strip()
    bind_ip=(request.form.get("bind_ip") or "").strip()
    if expires.isdigit():
        expires=(datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")
    if not user or not password: return build_view(err="User/Password လိုအပ်")
    if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)):
        return build_view(err="Port အကွာအဝေး 6000-19999")

    users=load_users(); found=False
    for u in users:
        if u.get("user","").lower()==orig:
            old_port=u.get("port","")
            if old_port and (str(old_port)!=str(port) or u.get("bind_ip","")!=bind_ip):
                remove_limit_rules(old_port)
            u.update({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip})
            found=True; break
    if not found: return build_view(err="မတွေ့ပါ")
    save_users(users); sync_config_passwords()
    return redirect(url_for('index'))

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

@app.route("/api/users", methods=["GET","POST"])
def api_users():
    if not require_login():
        return make_response(jsonify({"ok": False, "err":"login required"}), 401)
    if request.method=="GET":
        users=load_users(); active=get_udp_listen_ports(); listen_port=get_listen_port_from_config()
        for u in users: u["status"]=status_for_user(u,active,listen_port)
        return jsonify(users)
    data=request.get_json(silent=True) or {}
    user=(data.get("user") or "").strip()
    password=(data.get("password") or "").strip()
    expires=(data.get("expires") or "").strip()
    port=str(data.get("port") or "").strip()
    bind_ip=str(data.get("bind_ip") or "").strip()
    if expires.isdigit(): expires=(datetime.now()+timedelta(days=int(expires))).strftime("%Y-%m-%d")
    if not user or not password: return jsonify({"ok":False,"err":"user/password required"}),400
    if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)):
        return jsonify({"ok":False,"err":"invalid port"}),400
    if not port: port=pick_free_port()
    users=load_users(); replaced=False
    for u in users:
        if u.get("user","").lower()==user.lower():
            if u.get("port") and (u.get("port")!=port or u.get("bind_ip","")!=bind_ip):
                remove_limit_rules(u.get("port"))
            u.update({"password":password,"expires":expires,"port":port,"bind_ip":bind_ip}); replaced=True; break
    if not replaced:
        users.append({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip})
    save_users(users); sync_config_passwords(); apply_device_limits(users)
    return jsonify({"ok":True})

@app.route("/favicon.ico", methods=["GET"])
def favicon(): return ("",204)

@app.errorhandler(405)
def handle_405(e): return redirect(url_for('index'))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
