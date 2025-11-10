# /etc/zivpn/web2day.py — Public ZIVPN Panel (Light UI)
# - No login
# - Auto expiry: 2 days from created_on
# - Auto delete when expired (+ remove per-user DNAT)
# - KPI: Today Created, This Month Created, Online, Expired
# - User cards: Username + (Online/Active/Inactive) + Password + Data (KB/MB/GB) + Port + Bind IP + Expires
# - Per-user DNAT rules with counters (nat PREROUTING) to detect Online & Data
# - Delete button removed

from flask import Flask, render_template_string, request, redirect, url_for, session
import json, subprocess, os, tempfile, re
from datetime import datetime, timedelta, date

# ------------------ CONFIG / PATHS ------------------
USERS_FILE   = "/etc/zivpn/users.json"
CONFIG_FILE  = "/etc/zivpn/config.json"
TRAFFIC_FILE = "/var/lib/zivpn/traffic.json"   # optional fallback {"user": bytes}
WEB_PORT     = int(os.environ.get("WEB_PORT", "8080"))
DEFAULT_DAYS = 2

app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET", "change-me-dev")

# ------------------ UTILITIES ------------------
def read_json(path, default):
    try:
        with open(path, "r") as f: return json.load(f)
    except Exception:
        return default

def write_json_atomic(path, data):
    body = json.dumps(data, ensure_ascii=False, indent=2)
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w") as f: f.write(body)
        os.replace(tmp, path)
    finally:
        try: os.remove(tmp)
        except: pass

def save_users(users): write_json_atomic(USERS_FILE, users)

def load_users():
    vs = read_json(USERS_FILE, [])
    out=[]
    for u in vs:
        out.append({
            "user": u.get("user",""),
            "password": u.get("password",""),
            "created_on": u.get("created_on",""),
            "expires": u.get("expires",""),
            "port": str(u.get("port","")) if u.get("port","")!="" else "",
            "bind_ip": u.get("bind_ip",""),
        })
    return out

def shell(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def vps_ip():
    for c in [
        "ip route get 1.1.1.1 | awk '{print $7; exit}'",
        "hostname -I | awk '{print $1}'"
    ]:
        try:
            ip = shell(c).stdout.strip()
            if re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}", ip): return ip
        except: pass
    return "SERVER_IP"
VPS_IP = vps_ip()

def bytes_to_human(n_bytes):
    try: n=int(n_bytes)
    except: return "0 B"
    if n < 1024: return f"{n} B"
    if n < 1024**2: return f"{n/1024:.2f} KB"
    if n < 1024**3: return f"{n/1024**2:.2f} MB"
    return f"{n/1024**3:.2f} GB"

def get_listen_port():
    cfg = read_json(CONFIG_FILE, {})
    s = str(cfg.get("listen","")).strip()
    m = re.search(r":(\d+)$", s) if s else None
    return m.group(1) if m else "5667"

# -------- Per-user DNAT (nat PREROUTING) with counters --------
def nat_rule_exists(user, port):
    out = shell("iptables -t nat -S PREROUTING").stdout.splitlines()
    tag = f"user:{user}"
    patt = re.compile(rf"-A PREROUTING .* -p udp .* --dport {port}\b .* -j DNAT .* --to-destination :5667 .* -m comment --comment {re.escape(tag)}")
    return any(patt.search(l) for l in out)

def nat_rule_add(user, port):
    if not (user and port): return
    if nat_rule_exists(user, port): return
    tag = f"user:{user}"
    shell(f"iptables -t nat -I PREROUTING -p udp --dport {port} -m comment --comment {tag} -j DNAT --to-destination :5667")

def nat_rule_del(user=None, port=None):
    lines = shell("iptables -t nat -S PREROUTING").stdout.splitlines()
    for l in lines:
        if user and f"--comment user:{user}" not in l: 
            continue
        if port and f"--dport {port}" not in l:
            continue
        rule = l.replace("-A PREROUTING","").strip()
        shell(f"iptables -t nat -D PREROUTING {rule}")

def nat_counters():
    """
    Return {port: (pkts, bytes)} from nat PREROUTING counters.
    """
    out = shell("iptables -t nat -L PREROUTING -v -x -n").stdout.splitlines()
    res={}
    # example line includes: pkts   bytes  ... udp dpt:6003 to::5667 /* user:vip */
    for line in out:
        m = re.search(r"^\s*(\d+)\s+(\d+).*\budp\b.*dpt:(\d+).*DNAT.*\bto::5667\b", line)
        if m:
            pk, by, pt = int(m.group(1)), int(m.group(2)), m.group(3)
            res[pt] = (pk, by)
    return res

def status_for_user_by_counters(port, counters):
    if not port: return "Inactive"
    pk, _ = counters.get(str(port), (0,0))
    return "Online" if pk > 0 else "Inactive"

def try_autolock_bind_ip(u):
    if u.get("bind_ip"): 
        return
    ip = shell("conntrack -L -p udp 2>/dev/null | awk '/dport=5667/ {for(i=1;i<=NF;i++) if($i~/src=/){split($i,a,\"=\"); print a[2]; exit}}'").stdout.strip()
    if re.fullmatch(r'(\d{1,3}\.){3}\d{1,3}', ip):
        u["bind_ip"]=ip

# -------- Mirror panel passwords into ZIVPN config --------
def sync_config_pw():
    cfg=read_json(CONFIG_FILE, {})
    users=load_users()
    pws=sorted({str(u["password"]) for u in users if u.get("password")})
    if not isinstance(cfg.get("auth"), dict): cfg["auth"]={}
    cfg["auth"]["mode"]="passwords"; cfg["auth"]["config"]=pws
    cfg["listen"]=cfg.get("listen") or ":5667"
    cfg["cert"]=cfg.get("cert") or "/etc/zivpn/zivpn.crt"
    cfg["key"]=cfg.get("key") or "/etc/zivpn/zivpn.key"
    cfg["obfs"]=cfg.get("obfs") or "zivpn"
    write_json_atomic(CONFIG_FILE, cfg)
    shell("systemctl restart zivpn.service")

# -------- Ensure expiry defaults + auto prune (and remove DNAT) --------
def ensure_expiry_and_prune(users):
    today = date.today()
    changed=False; kept=[]
    for u in users:
        if not u.get("created_on"):
            u["created_on"]=today.strftime("%Y-%m-%d"); changed=True
        if not u.get("expires"):
            u["expires"]=(today+timedelta(days=DEFAULT_DAYS)).strftime("%Y-%m-%d"); changed=True
        try: exp=datetime.strptime(u["expires"], "%Y-%m-%d").date()
        except Exception:
            exp=today+timedelta(days=DEFAULT_DAYS)
            u["expires"]=exp.strftime("%Y-%m-%d"); changed=True
        if exp < today:
            # auto remove + per-user DNAT clear
            nat_rule_del(user=u.get("user",""), port=u.get("port"))
            continue
        kept.append(u)
    if changed or len(kept)!=len(users): save_users(kept)
    return kept

# ------------------ THEME / HTML ------------------
LOGO_URL="https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png"

HTML = """
<!doctype html>
<html lang="my">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>ZIVPN • DEV-U PHOE KAUNT (Free)</title>
<style>
:root{
  --bg:#f4f6fb; --card:#ffffff; --bd:#e5e7eb; --muted:#6b7280; --fg:#111827;
  --accent:#2563eb; --ok:#10b981; --bad:#ef4444; --unk:#9ca3af;
}
*{box-sizing:border-box}
html,body{background:var(--bg);color:var(--fg)}
body{font-family:ui-sans-serif,system-ui,Segoe UI,Roboto,Arial;margin:0;padding:12px 12px 84px;min-height:100vh}
.wrap{max-width:1024px;margin:0 auto}
header{position:sticky;top:0;background:rgba(244,246,251,.9);backdrop-filter:blur(6px);border-bottom:1px solid var(--bd);z-index:10}
.head{display:flex;gap:12px;align-items:center;justify-content:space-between;padding:10px 0}
h1{font-size:18px;margin:0;font-weight:800}
.sub{color:var(--muted);font-size:12px}
.logo{height:40px;width:auto;border-radius:10px}

.grid{display:grid;gap:12px}
@media(min-width:720px){.grid{grid-template-columns:1fr 1fr 1fr 1fr}}

.card{background:var(--card);border:1px solid var(--bd);border-radius:14px;padding:14px;box-shadow:0 1px 2px rgba(0,0,0,.05)}
.kpi{display:flex;align-items:center;justify-content:space-between}
.kpi .label{color:var(--muted);font-size:12px}
.kpi .value{font-weight:800;font-size:20px}

.btn{display:inline-flex;align-items:center;justify-content:center;padding:10px 14px;border-radius:10px;border:1px solid var(--bd);background:#eef2ff;color:#1e3a8a;text-decoration:none;cursor:pointer}
.btn:hover{filter:brightness(0.98)}
.btn-primary{background:var(--accent);border-color:var(--accent);color:#fff}

.form{display:grid;gap:10px}
.form-inline{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px}
input{width:100%;padding:12px;border-radius:10px;border:1px solid var(--bd);background:#fff;color:#111827;outline:none}
label{font-size:12px;color:var(--muted);margin-bottom:4px;display:block}

.userlist{display:grid;gap:12px;margin-top:12px}
@media(min-width:720px){.userlist{grid-template-columns:repeat(2,1fr)}}
@media(min-width:980px){.userlist{grid-template-columns:repeat(3,1fr)}}

.ucard{background:var(--card);border:1px solid var(--bd);border-radius:16px;padding:12px;word-break:break-word}
.uhead{display:flex;align-items:center;justify-content:space-between;border-bottom:1px dashed var(--bd);padding-bottom:8px;margin-bottom:8px}
.uname{font-weight:800;letter-spacing:.2px}
.badge{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:999px;font-size:11px;font-weight:700}
.dot{width:8px;height:8px;border-radius:50%}
.b-online{background:#dcfce7;color:#065f46}.b-online .dot{background:var(--ok)}
.b-active{background:#dbeafe;color:#1e40af}.b-active .dot{background:#3b82f6}
.b-inact{background:#f3f4f6;color:#374151}.b-inact .dot{background:var(--unk)}

.infobox{background:#ecfdf5;border:1px solid #a7f3d0;border-radius:14px;padding:14px;margin-top:14px}
.copyrow{display:flex;gap:8px;align-items:center;margin:6px 0}
.copybtn{padding:10px 12px;border-radius:10px;background:var(--accent);color:#fff;border:none}

footer{position:fixed;left:0;right:0;bottom:0;background:var(--card);border-top:1px solid var(--bd);padding:10px}
.nav{display:flex;gap:8px;justify-content:space-around}
.nav a{color:var(--muted);text-decoration:none;font-size:12px}
.nav a.active{color:#111827;font-weight:800}
</style>
<script>
function copyToClipboard(text){
  if(navigator.clipboard){navigator.clipboard.writeText(text).then(()=>alert('Copied: '+text));}
  else {var t=document.createElement('textarea'); t.value=text; document.body.appendChild(t); t.select(); document.execCommand('copy'); document.body.removeChild(t); alert('Copied: '+text);}
}
</script>
</head>
<body>

<header>
  <div class="wrap head">
    <div style="display:flex;gap:10px;align-items:center">
      <img class="logo" src="{{ logo }}">
      <div>
        <h1>DEV-U PHOE KAUNT</h1>
        <div class="sub">ZIVPN Free Panel • Total <b>{{ total }}</b></div>
      </div>
    </div>
    <form method="post" action="{{ url_for('refresh_status', filter=filter_type) }}">
      <button class="btn btn-primary">🔄 Scan</button>
    </form>
  </div>
</header>

<div class="wrap" style="margin-top:12px">

  <!-- KPI -->
  <div class="grid">
    <div class="card kpi"><div class="label">Today Created</div><div class="value">{{ today_new }}</div></div>
    <div class="card kpi"><div class="label">This Month Created</div><div class="value">{{ month_new }}</div></div>
    <div class="card kpi"><div class="label">Online</div><div class="value">{{ online_count }}</div></div>
    <div class="card kpi"><div class="label">Expired (auto-removed)</div><div class="value">{{ expired_count }}</div></div>
  </div>

  {% if info_page %}
  <div class="infobox">
    <div style="font-weight:800;margin-bottom:6px">✅ Account Created</div>
    <div class="copyrow"><label>User</label><input value="{{ info.user }}" readonly><button class="copybtn" onclick="copyToClipboard('{{ info.user }}')">Copy</button></div>
    <div class="copyrow"><label>Password</label><input value="{{ info.password }}" readonly><button class="copybtn" onclick="copyToClipboard('{{ info.password }}')">Copy</button></div>
    <div class="copyrow"><label>Port</label><input value="{{ info.port }}" readonly><button class="copybtn" onclick="copyToClipboard('{{ info.port }}')">Copy</button></div>
    <div class="copyrow"><label>Server IP</label><input value="{{ info.vps_ip }}" readonly><button class="copybtn" onclick="copyToClipboard('{{ info.vps_ip }}')">Copy</button></div>
    <div class="copyrow"><label>Expires</label><input value="{{ info.expires }}" readonly><button class="copybtn" onclick="copyToClipboard('{{ info.expires }}')">Copy</button></div>
    <a class="btn" style="margin-top:10px" href="{{ url_for('index') }}">🏠 Back to Dashboard</a>
  </div>
  {% endif %}

  <!-- Add user (auto 2 days) -->
  <div class="card">
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
      <div style="font-weight:800">➕ အသုံးပြုသူ အသစ် (Auto {{ default_days }} days)</div>
      {% if msg %}<div style="color:#059669">{{ msg }}</div>{% endif %}
      {% if err %}<div style="color:#b91c1c">{{ err }}</div>{% endif %}
    </div>
    <form class="form" method="post" action="/add">
      <div class="form-inline">
        <div><label>👤 Username</label><input name="user" required></div>
        <div><label>🔑 Password</label><input name="password" required></div>
      </div>
      <button class="btn btn-primary" type="submit">Save & Show Info</button>
    </form>
  </div>

  <!-- User list -->
  <div class="userlist">
    {% for u in users %}
      <div class="ucard">
        <div class="uhead">
          <div class="uname">{{ u.user }}</div>
          {% if u.status == "Online" %}
            <div class="badge b-online"><span class="dot"></span>Online</div>
          {% elif u.status == "Active" %}
            <div class="badge b-active"><span class="dot"></span>Active</div>
          {% else %}
            <div class="badge b-inact"><span class="dot"></span>Inactive</div>
          {% endif %}
        </div>

        <div style="display:grid;gap:6px">
          <div style="display:flex;justify-content:space-between;font-size:13px"><span class="muted">Password</span><span><b>{{ u.password }}</b></span></div>
          <div style="display:flex;justify-content:space-between;font-size:13px"><span class="muted">Data</span><span><b>{{ u.traffic }}</b></span></div>
          <div style="display:flex;justify-content:space-between;font-size:13px"><span class="muted">Port</span><span><b>{{ u.port or listen_port }}</b></span></div>
          <div style="display:flex;justify-content:space-between;font-size:13px"><span class="muted">Bind IP</span><span><b>{{ u.bind_ip or "—" }}</b></span></div>
          <div style="display:flex;justify-content:space-between;font-size:13px"><span class="muted">Expires</span><span><b>{{ u.expires }}</b></span></div>
        </div>

        <div style="display:flex;gap:8px;margin-top:10px">
          <a class="btn" href="{{ url_for('edit_user', user=u.user) }}">✏️ Edit</a>
          <!-- Delete button intentionally removed -->
        </div>
      </div>
    {% endfor %}
  </div>

</div>

<footer>
  <div class="wrap">
    <div class="nav">
      <a href="{{ url_for('index', filter='all') }}" class="{% if filter_type=='all' %}active{% endif %}">All ({{ total }})</a>
      <a href="{{ url_for('index', filter='online') }}" class="{% if filter_type=='online' %}active{% endif %}">Online ({{ online_count }})</a>
      <a href="{{ url_for('index', filter='expired') }}" class="{% if filter_type=='expired' %}active{% endif %}">Expired ({{ expired_count }})</a>
    </div>
  </div>
</footer>

</body></html>
"""

# ------------------ VIEW BUILDER ------------------
def build_view(msg="", err="", info_user=None):
    users = ensure_expiry_and_prune(load_users())   # ensure defaults + prune + DNAT cleanup
    today_str = datetime.now().strftime("%Y-%m-%d")
    month_start = datetime.now().replace(day=1).strftime("%Y-%m-%d")
    listen = get_listen_port()

    # ensure per-user DNAT rules exist
    for u in users:
        if u.get("port"): nat_rule_add(u.get("user",""), u.get("port"))
    ctr = nat_counters()  # read counters once

    processed=[]; online=0; expired=0; today_new=0; month_new=0
    for u in users:
        st = status_for_user_by_counters(u.get("port"), ctr)
        if st == "Online":
            online += 1
            if not u.get("bind_ip"):
                try_autolock_bind_ip(u); save_users(users)

        _, by = ctr.get(str(u.get("port","")), (0,0))
        t_h = bytes_to_human(by)

        if u.get("created_on","") == today_str: today_new += 1
        if u.get("created_on","") >= month_start: month_new += 1
        if u.get("expires","") < today_str: expired += 1

        processed.append({
            "user": u.get("user",""),
            "password": u.get("password",""),
            "expires": u.get("expires",""),
            "port": u.get("port",""),
            "bind_ip": u.get("bind_ip",""),
            "status": st,
            "traffic": t_h
        })

    f = request.args.get("filter","all")
    if f == "online": view = [x for x in processed if x["status"]=="Online"]
    elif f == "expired": view = [x for x in processed if x["expires"] < today_str]
    else: view = processed

    view.sort(key=lambda x: (x["status"]!="Online", (x["user"] or "").lower()))

    if info_user:
        return render_template_string(
            HTML, info_page=True, info=info_user, logo=LOGO_URL,
            listen_port=listen, default_days=DEFAULT_DAYS,
            today_new=today_new, month_new=month_new,
            online_count=online, expired_count=expired,
            total=len(processed), filter_type=f, msg=msg, err=err
        )

    return render_template_string(
        HTML, users=view, logo=LOGO_URL,
        listen_port=listen, default_days=DEFAULT_DAYS,
        today_new=today_new, month_new=month_new,
        online_count=online, expired_count=expired,
        total=len(processed), filter_type=f, msg=msg, err=err
    )

# ------------------ ROUTES ------------------
@app.route("/", methods=["GET"])
def index(): 
    return build_view()

@app.route("/refresh_status", methods=["POST"])
def refresh_status():
    return redirect(url_for('index', filter=request.args.get('filter','all')))

# Public mode
def login_enabled(): return False
def require_login(): return True

@app.route("/add", methods=["POST"])
def add_user():
    user = (request.form.get("user") or "").strip()
    password = (request.form.get("password") or "").strip()
    if not user or not password:
        return build_view(err="User/Password လိုအပ်ပါသည်")

    users = load_users()
    today = date.today()
    expires = (today + timedelta(days=DEFAULT_DAYS)).strftime("%Y-%m-%d")
    created = today.strftime("%Y-%m-%d")
    # pick unique UDP port for this user
    # prefer free 6000-19999 (not used by others)
    used = {int(u.get("port") or 0) for u in users if u.get("port")}
    port = 0
    for p in range(6000, 20000):
        if p not in used: port = p; break
    if not port: return build_view(err="အသုံးပြုရန် UDP port မရှိတော့ပါ")
    rec = {"user":user,"password":password,"created_on":created,"expires":expires,"port":str(port),"bind_ip":""}

    replaced=False
    for u in users:
        if u.get("user","").lower()==user.lower():
            u.update(rec); replaced=True; break
    if not replaced: users.append(rec)

    save_users(users); sync_config_pw()
    nat_rule_add(user, str(port))  # ensure DNAT rule exists for this user

    session["new_info"]= {"user":user,"password":password,"expires":expires,"port":str(port),"vps_ip":VPS_IP}
    return redirect(url_for("show_info"))

@app.route("/show_info", methods=["GET"])
def show_info():
    info = session.pop("new_info", None)
    if not info: return redirect(url_for("index"))
    return build_view(info_user=info)

@app.route("/edit", methods=["GET","POST"])
def edit_user():
    # kept minimal for public panel
    return redirect(url_for("index"))

@app.route("/favicon.ico")
def favicon(): return ("",204)

@app.errorhandler(405)
def _405(e): return redirect(url_for("index"))

# ------------------ BOOT ------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=WEB_PORT)
