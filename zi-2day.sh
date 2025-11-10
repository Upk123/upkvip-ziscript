from flask import Flask, jsonify, render_template_string, request, redirect, url_for, session, make_response
import json, subprocess, os, tempfile, hmac, re
from datetime import datetime, timedelta

USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
TRAFFIC_FILE = "/var/lib/zivpn/traffic.json" # ZIVPN traffic data file
LISTEN_FALLBACK = "5667"
RECENT_SECONDS = 120

# Helper function to convert bytes to human-readable format (MB or GB)
def bytes_to_human(n_bytes):
    if n_bytes is None: return "0 MB"
    try: n_bytes=int(n_bytes)
    except: return "0 MB"
    if n_bytes < 1024 * 1024:
        return f"{n_bytes / 1024:.2f} KB"
    elif n_bytes < 1024 * 1024 * 1024:
        return f"{n_bytes / (1024 * 1024):.2f} MB"
    else:
        return f"{n_bytes / (1024 * 1024 * 1024):.2f} GB"

# Get VPS IP Address for Show Info
def get_vps_ip():
    try:
        result = subprocess.run("ip route get 1.1.1.1 | awk '{print $7; exit}'", shell=True, capture_output=True, text=True)
        ip = result.stdout.strip()
        if re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}", ip): return ip
    except Exception: pass
    try:
        result = subprocess.run("hostname -I | awk '{print $1}'", shell=True, capture_output=True, text=True)
        ip = result.stdout.strip()
        if re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}", ip): return ip
    except Exception: pass
    return "SERVER_IP"

VPS_IP = get_vps_ip()
LOGO_URL = "https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png" 
WEB_PORT = os.environ.get("WEB_PORT", "8080")

app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET","dev-secret-change-me")
ADMIN_USER = os.environ.get("WEB_ADMIN_USER","").strip()
ADMIN_PASS = os.environ.get("WEB_ADMIN_PASSWORD","").strip()

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

def load_users():
  v=read_json(USERS_FILE,[])
  out=[]
  for u in v:
    out.append({"user":u.get("user",""),
                "password":u.get("password",""),
                "expires":u.get("expires",""),
                "port":str(u.get("port","")) if u.get("port","")!="" else "",
                "bind_ip":u.get("bind_ip","")})
  return out

def get_traffic_data():
    """Reads ZIVPN traffic data from the dedicated file."""
    # The traffic file stores data in bytes. Example: {"user1": 123456789, "user2": 987654321}
    return read_json(TRAFFIC_FILE, {})

def save_users(users): write_json_atomic(USERS_FILE, users)

def shell(cmd): return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def get_listen_port_from_config():
  cfg=read_json(CONFIG_FILE,{})
  listen=str(cfg.get("listen","")).strip()
  m=re.search(r":(\d+)$", listen) if listen else None
  return (m.group(1) if m else LISTEN_FALLBACK)

def pick_free_port():
  used={str(u.get("port","")) for u in load_users() if str(u.get("port",""))}
  used_ports_output=shell(f"ss -uHln | grep -E ':(6[0-9]{{3}}|1[0-9]{{4}}|{get_listen_port_from_config()})\\b' || true").stdout
  used |= set(re.findall(r":(\d+)\s", used_ports_output))
  for p in range(6000,20000):
    if str(p) not in used: return str(p)
  return ""

def has_recent_udp_activity_for_port(port):
  if not port: return False
  out=shell(f"conntrack -L -p udp 2>/dev/null | grep -w 'dport={port}' | head -n1 || true").stdout
  return bool(out.strip())

def first_recent_src_ip(port):
  if not port: return ""
  out=shell(f"conntrack -L -p udp 2>/dev/null | awk \"/dport={port}\\b/ {{for(i=1;i<=NF;i++) if($i~/src=/){{split($i,a,'='); print a[2]; exit}}}}\"").stdout.strip()
  return out if re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}", out) else ""

def status_for_user(u, listen_port):
  port=str(u.get("port","")) or listen_port
  if has_recent_udp_activity_for_port(port):
    return "Online"
  if u.get("bind_ip"):
     return "Offline (Locked)"
  return "Offline"

# IPTables functions remain the same...

def _ipt(cmd): return shell(cmd)
def ensure_limit_rules(port, ip):
  if not (port and ip): return
  _ipt(f"iptables -C INPUT -p udp --dport {port} -s {ip} -j ACCEPT 2>/dev/null") or _ipt(f"iptables -I INPUT -p udp --dport {port} -s {ip} -j ACCEPT")
  _ipt(f"iptables -C INPUT -p udp --dport {port} ! -s {ip} -j DROP 2>/dev/null") or _ipt(f"iptables -I INPUT -p udp --dport {port} ! -s {ip} -j DROP")
def remove_limit_rules(port):
  if not port: return
  for _ in range(10):
    chk=_ipt(f"iptables -S INPUT | grep -E \"-p udp .* --dport {port}\\b .* (-j DROP|-j ACCEPT)\" | head -n1 || true").stdout.strip()
    if not chk: break
    rule=chk.replace("-A","").strip()
    _ipt(f"iptables -D INPUT {rule}")
def apply_device_limits(users):
  existing_ports = {str(u.get("port","")) for u in users if str(u.get("port",""))}
  cleanup_rules_output = shell("iptables -S INPUT | grep -E ' -p udp .* --dport (6[0-9]{3}|1[0-9]{4}).* -j (ACCEPT|DROP)' || true").stdout.splitlines()
  for line in cleanup_rules_output:
      match = re.search(r'--dport (\d+)\b', line)
      if match and match.group(1) not in existing_ports:
          rule = line.replace("-A INPUT", "").strip()
          _ipt(f"iptables -D INPUT {rule}")
  for u in users:
    port=str(u.get("port","") or "")
    ip=(u.get("bind_ip","") or "").strip()
    if port and ip: ensure_limit_rules(port, ip)
    elif port and not ip: remove_limit_rules(port)

# ========= AUTH: Force PUBLIC MODE (login disabled) =========
def login_enabled(): 
  # always public panel
  return False

def is_authed(): 
  # in public mode we treat everyone as authed
  return True

def require_login():
  # no login required in public mode
  return True
# ============================================================

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

HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta http-equiv="refresh" content="120">
<title>ZIVPN User Panel - DEV-U PHOE KAUNT</title>
<style>
 /* Light Theme CSS */
 :root{
  --bg:#ffffff; --fg:#1f2937; --muted:#6b7280; --card:#f9fafb; --bd:#e5e7eb;
  --ok:#10b981; --bad:#ef4444; --unk:#9ca3af; --btn:#f3f4f6; --btnbd:#d1d5db;
  --succ:#10b981; --succbg:#ecfdf5; --primary:#2563eb;
 }
 html,body{background:var(--bg);color:var(--fg)}
 body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:0;padding:16px 16px 80px 16px; min-height:100vh}
 header{position:sticky;top:0;background:var(--bg);padding:10px 0 12px;z-index:10;border-bottom:1px solid var(--bd)}
 .wrap{max-width:1000px;margin:0 auto}
 .row{display:flex;gap:12px;align-items:center;flex-wrap:wrap}
 h1{margin:0;font-size:20px;font-weight:700}
 .sub{color:var(--muted);font-size:13px}
 .btn, .btn-nav{padding:10px 14px;border-radius:8px;border:1px solid var(--btnbd);
      background:var(--btn);color:var(--fg);text-decoration:none;cursor:pointer;
      transition: background 0.1s ease; font-weight:500; text-align:center;}
 .btn:hover, .btn-nav:hover{background:var(--btnbd)}
 .btn-success{background:var(--succ);border-color:var(--succ);color:#fff}
 .btn-success:hover{background:#059669}
 .btn-primary{background:var(--primary);border-color:var(--primary);color:#fff}
 .btn-primary:hover{background:#1d4ed8}
 .btn-del{background:#dc2626;border-color:#dc2626;color:#fff;font-weight:600;}
 .btn-del:hover{background:#b91c1c}
 table{border-collapse:collapse;width:100%;margin-top:14px;border-radius:8px;overflow:hidden;border:1px solid var(--bd)}
 th,td{border:1px solid var(--bd);padding:10px;text-align:left}
 th{background:var(--card);font-size:13px;font-weight:600}
 td{font-size:14px}
 .pill{display:inline-block;padding:4px 10px;border-radius:999px;font-size:12px;font-weight:600; white-space:nowrap}
 .ok{color:#fff;background:var(--ok)}
 .bad{color:#fff;background:var(--bad)}
 .unk{color:#fff;background:var(--unk)}
 .locked{color:#fff;background:#3b82f6}
 .muted{color:var(--muted)}
 .box{margin:14px 0;padding:16px;border:1px solid var(--bd);border-radius:12px;background:var(--card)}
 label{display:block;margin:6px 0 3px;font-size:13px;color:var(--muted);font-weight:500}
 input, select{width:100%;padding:11px 12px;border:1px solid var(--btnbd);border-radius:8px;background:#fff;color:var(--fg);box-sizing:border-box;}
 .actions{display:flex;gap:8px;flex-wrap:wrap}
 .count{font-weight:700;color:var(--primary)}
 
 /* Layout for Add User form */
 .form-inline{display:grid;grid-template-columns:repeat(auto-fit, minmax(200px, 1fr));gap:12px;}
 .form-inline-full-width { grid-column: 1 / -1; }
 
 /* Info Box for New User */
 .info-box{background:var(--succbg);padding:16px;border-radius:12px;margin-top:20px;border-color:var(--succ)}
 .copy-row{display:flex;align-items:center;margin-bottom:8px;gap:8px}
 .copy-row input{flex:1;padding:10px;font-size:14px;max-width:none; background:#fff}
 .copy-btn{padding:10px 12px;background:var(--primary);border:none;border-radius:8px;color:#fff;cursor:pointer}
 .copy-btn:hover{background:#1d4ed8}

 /* Footer Nav Bar */
 footer{
    position: fixed; bottom: 0; left: 0; right: 0;
    background: var(--card); border-top: 1px solid var(--bd);
    padding: 10px 0; z-index: 20;
 }
 .nav-bar{display:flex; justify-content:space-around; max-width:1000px; margin:0 auto; padding:0 10px}
 .nav-item{flex:1; text-align:center;}
 .nav-link{display:block; padding:8px 0; text-decoration:none; color:var(--muted); font-size:12px; border-radius:6px;}
 .nav-link.active{color:var(--primary); font-weight:700; background:#eff6ff;}
 
 @media (max-width:480px){ 
    body{padding:12px 12px 80px 12px;} 
    th,td{font-size:13px;padding:8px} 
    .btn{padding:8px 10px;font-size:13px} 
    .nav-link{font-size:11px}
 }
</style>
<script>
  function fallbackCopy(text) {
    var textArea = document.createElement("textarea");
    textArea.value = text;
    textArea.style.position = "fixed";  // Avoid scrolling to bottom
    textArea.style.opacity = "0";
    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();
    try {
      var successful = document.execCommand('copy');
      if (successful) {
        alert('ကူးယူပြီးပါပြီ (Legacy): ' + text);
      } else {
        alert('ကူးယူမရပါ (Manual copy): ' + text);
      }
    } catch (err) {
      alert('ကူးယူမရပါ (Error): ' + text);
    }
    document.body.removeChild(textArea);
  }

  function copyToClipboard(text, event) {
    if (navigator.clipboard) {
      navigator.clipboard.writeText(text).then(function() {
        alert('ကူးယူပြီးပါပြီ: ' + text);
      }, function(err) {
        console.warn('Clipboard API failed, falling back...');
        fallbackCopy(text);
      });
    } else {
      fallbackCopy(text);
    }
    if (event) event.preventDefault();
  }
</script>
</head><body>

{% if info_page %}
 <div class="wrap" style="max-width:500px">
  <div class="box info-box">
    <h2 style="margin-top:0;color:var(--succ)">✅ အကောင့်အသစ် ဖွင့်ပြီးပါပြီ</h2>
    <p class="muted">အောက်ပါ အချက်အလက်များကို client တွင် ထည့်သွင်းအသုံးပြုနိုင်ပါသည်။</p>

    <div style="margin-top:16px">
        <label>👤 User Name</label>
        <div class="copy-row">
            <input type="text" value="{{ info.user }}" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.user }}', event)">Copy</button>
        </div>
        
        <label style="margin-top:12px">🔑 Password</label>
        <div class="copy-row">
            <input type="text" value="{{ info.password }}" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.password }}', event)">Copy</button>
        </div>
        
        <label style="margin-top:12px">🔌 Port (Device Lock)</label>
        <div class="copy-row">
            <input type="text" value="{{ info.port }}" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.port }}', event)">Copy</button>
        </div>

        <label style="margin-top:12px">🌐 VPS IP (Server Address)</label>
        <div class="copy-row">
            <input type="text" value="{{ info.vps_ip }}" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.vps_ip }}', event)">Copy</button>
        </div>
        
        <label style="margin-top:12px">⏰ သက်တမ်းကုန်ဆုံးရက်</label>
        <div class="copy-row">
            <input type="text" value="{{ info.expires }}" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.expires }}', event)">Copy</button>
        </div>
    </div>
    <a href="{{ url_for('index') }}" class="btn btn-primary" style="margin-top:16px;width:100%;text-align:center;">🏠 Dashboard သို့ပြန်သွားရန်</a>
  </div>
 </div>
 
{% elif edit_page %}
<div class="wrap">
  <div class="box" style="max-width:600px;margin:20px auto">
    <h3 style="margin:4px 0 16px;border-bottom:1px solid var(--bd);padding-bottom:8px">✏️ အသုံးပြုသူ ပြင်ဆင်ခြင်း: {{ edit_user.user }}</h3>
    {% if msg %}<div style="color:var(--ok);margin:6px 0">{{msg}}</div>{% endif %}
    {% if err %}<div style="color:var(--bad);margin:6px 0">{{err}}</div>{% endif %}
    <form method="post" action="{{ url_for('edit_user') }}">
      <input type='hidden' name='orig' value='{{ edit_user.user }}'>
      
      <div class="form-inline">
        <div><label>User Name</label><input name='user' value='{{ edit_user.user }}' required></div>
        <div><label>Password</label><input name='password' value='{{ edit_user.password }}' required></div>
        <div><label>သက်တမ်းကုန်ဆုံးရက် (YYYY-MM-DD)</label><input name='expires' value='{{ edit_user.expires or "" }}' placeholder='2025-12-31 or 30 (ရက်)'></div>
        <div><label>UDP Port (6000-19999)</label><input name='port' value='{{ edit_user.port or "" }}' placeholder='အလိုအလျောက် ရွေးမယ်'></div>
        <div><label>📱 ချိတ်ထားသော IP (Device Lock)</label><input name='bind_ip' value='{{ edit_user.bind_ip or "" }}' placeholder='ချိတ်ထားသည့် IP (သို့) ရှင်းလင်းထားရန်'></div>
      </div>
      
      <div class="actions" style="margin-top:16px">
        <button class="btn btn-primary" type="submit" style="flex:1">💾 Save Changes</button>
        <a class="btn" href="{{ url_for('index') }}" style="flex:1;text-align:center">❌ Cancel</a>
      </div>

      <div style="margin-top:16px; border-top:1px solid var(--bd); padding-top:16px;" class="actions">
          <form style="display:inline; flex:1" method="post" action="{{ url_for('lock_now', user=edit_user.user) }}">
            <input type="hidden" name="user" value="{{ edit_user.user }}">
            <button class="btn btn-success" name="op" value="lock" title="Lock to current IP" style="width:100%">Lock Now</button>
          </form>
          <form style="display:inline; flex:1" method="post" action="{{ url_for('lock_now', user=edit_user.user) }}">
            <input type="hidden" name="user" value="{{ edit_user.user }}">
            <button class="btn btn-del" name="op" value="clear" title="Clear lock" style="width:100%">Clear Lock</button>
          </form>
      </div>
    </form>
  </div>
</div>

{% else %}
<header>
 <div class="wrap row">
   <img src="{{ logo }}" alt="DEV-U PHOE KAUNT" style="height:40px;width:auto;border-radius:8px">
   <div style="flex:1">
     <h1>DEV-U PHOE KAUNT</h1>
     <div class="sub">ZIVPN User Panel • Total: <span class="count">{{ total }}</span></div>
   </div>
   <div class="row">
     <a class="btn" href="https://m.me/upkvpnfastvpn" target="_blank" rel="noopener">💬 Messenger</a>
     <form method="post" action="{{ url_for('refresh_status', filter=filter_type) }}"><button class="btn btn-primary" type="submit">🔄 Scan Status</button></form>
     {# Login UI removed in public mode — no logout button #}
   </div>
 </div>
</header>

<div class="wrap">
{% if filter_type == 'all' %}
<div class="box">
  <h3 style="margin:4px 0 8px">➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
  {% if msg %}<div style="color:var(--succ);margin:6px 0">{{msg}}</div>{% endif %}
  {% if err %}<div style="color:var(--bad);margin:6px 0">{{err}}</div>{% endif %}
  <form method="post" action="/add">
    <div class="form-inline">
      <div><label>👤 User</label><input name="user" required></div>
      <div><label>🔑 Password</label><input name="password" required></div>
      <div><label>⏰ Expires (ရက်/YYYY-MM-DD)</label><input name="expires" placeholder="30 or 2025-12-31"></div>
      <div><label>🔌 UDP Port (Auto)</label><input name="port" placeholder="auto"></div>
      <div><label>📱 Bind IP (1 device)</label><input name="bind_ip" placeholder="auto when online…"></div>
    </div>
    <div class="form-inline-full-width"> 
        <button class="btn btn-success" type="submit" style="margin-top:12px;width:100%">Save & Show Info</button>
    </div>
  </form>
</div>
{% endif %}

<table>
  <thead>
  <tr>
    <th>👤 User</th><th>🔑 Password</th><th>⏰ Expires</th>
    <th>📊 Data Usage</th>
    <th>🔎 Status</th><th>⚙️ Actions</th>
  </tr>
  </thead>
  <tbody>
  {% for u in users %}
  <tr class="{% if u.expires and u.expires < today %}expired-row{% endif %}">
    <td>{{u.user}}</td>
    <td>{{u.password}}</td>
    <td style="white-space:nowrap">{% if u.expires %}{{u.expires}}{% else %}<span class="muted">—</span>{% endif %}</td>
    <td><span class="muted">{{ u.traffic }}</span></td>
    <td>
      {% if u.status == "Online" %}<span class="pill ok">Online</span>
      {% elif u.status.startswith("Offline") %}<span class="pill bad">Offline</span>
      {% else %}<span class="pill unk">Unknown</span>
      {% endif %}
    </td>
    <td class="actions">
      <a class="btn btn-primary" href="{{ url_for('edit_user', user=u.user) }}" style="width:60px; padding:6px 8px;">✏️ Edit</a>
      <form class="delform" method="post" action="{{ url_for('delete_user_html') }}" onsubmit="return confirm('{{u.user}} ကို ဖျက်မလား?')">
        <input type="hidden" name="user" value="{{u.user}}">
        <button type="submit" class="btn btn-del" style="width:60px; padding:6px 8px;">🗑️ Delete</button>
      </form>
    </td>
  </tr>
  {% endfor %}
  </tbody>
</table>

</div>
<footer>
    <div class="nav-bar">
        <div class="nav-item">
            <a href="{{ url_for('index', filter='all') }}" class="nav-link {% if filter_type == 'all' %}active{% endif %}">🏠 Home ({{ total }})</a>
        </div>
        <div class="nav-item">
            <a href="{{ url_for('index', filter='expired') }}" class="nav-link {% if filter_type == 'expired' %}active{% endif %}">⏰ သက်တမ်းကုန် ({{ expired_count }})</a>
        </div>
        <div class="nav-item">
            <a href="{{ url_for('index', filter='online') }}" class="nav-link {% if filter_type == 'online' %}active{% endif %}">🟢 Online ({{ online_count }})</a>
        </div>
    </div>
</footer>
{% endif %}
</body></html>
"""

def build_view(msg="", err="", info_user=None, edit_user_data=None):
  # Handle special pages first
  if info_user:
    today=datetime.now().strftime("%Y-%m-%d")
    return render_template_string(HTML, info_page=True, info={
        "user":info_user["user"],
        "password":info_user["password"],
        "expires":info_user["expires"] or today,
        "port":info_user["port"] or get_listen_port_from_config(),
        "vps_ip":VPS_IP
    })
  
  if edit_user_data:
      return render_template_string(HTML, edit_page=True, edit_user=edit_user_data, msg=msg, err=err)

  # PUBLIC MODE: no login gate
  users=load_users()
  traffic_data = get_traffic_data()
  changed=False
  today_str=datetime.now().strftime("%Y-%m-%d")
  listen_port=get_listen_port_from_config()
  
  processed_users = []
  online_count = 0
  expired_count = 0
  
  for u in users:
    current_status = status_for_user(u, listen_port)
    is_online = (current_status == "Online")
    is_expired = (u.get("expires") and u["expires"] < today_str)
    
    # Auto-Lock logic
    if u.get("port") and not u.get("bind_ip") and is_online:
        ip=first_recent_src_ip(u["port"])
        if ip:
            u["bind_ip"]=ip
            changed=True
    
    if is_online: online_count += 1
    if is_expired: expired_count += 1
    
    # Get Traffic Data
    traffic_bytes = traffic_data.get(u.get("user"), 0)
    traffic_human = bytes_to_human(traffic_bytes)
    
    processed_users.append(type("U",(),{
      "user":u.get("user",""),
      "password":u.get("password",""),
      "expires":u.get("expires",""),
      "port":u.get("port",""),
      "bind_ip":u.get("bind_ip",""),
      "status":current_status,
      "traffic":traffic_human
    }))
    
  if changed: save_users(users)
  apply_device_limits(users)
  
  # Filtering Logic
  filter_type = request.args.get('filter', 'all')
  
  if filter_type == 'online':
      view = [u for u in processed_users if u.status == "Online"]
  elif filter_type == 'expired':
      view = [u for u in processed_users if u.expires and u.expires < today_str]
  else: # 'all'
      view = processed_users
  
  view.sort(key=lambda x:(x.user or "").lower())
  
  return render_template_string(HTML, authed=True, logo=LOGO_URL, users=view, msg=msg, err=err, 
                                today=today_str, total=len(users), 
                                filter_type=filter_type, 
                                online_count=online_count, 
                                expired_count=expired_count)

# --- Routes (mostly remain the same, but login endpoints are no-ops in public mode) ---

@app.route("/refresh_status", methods=["POST"])
def refresh_status():
    return redirect(url_for('index', filter=request.args.get('filter', 'all')))

@app.route("/login", methods=["GET","POST"])
def login():
  # public mode: just go home
  return redirect(url_for('index'))

@app.route("/logout", methods=["GET"])
def logout():
  session.pop("auth", None)
  return redirect(url_for('index'))

@app.route("/", methods=["GET"])
def index(): return build_view()

@app.route("/add", methods=["POST"])
def add_user():
  # public mode (no login)
  user=(request.form.get("user") or "").strip()
  password=(request.form.get("password") or "").strip()
  expires=(request.form.get("expires") or "").strip()
  port=(request.form.get("port") or "").strip()
  bind_ip=(request.form.get("bind_ip") or "").strip()

  if expires.isdigit():
    try: expires=(datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")
    except Exception: pass

  if not user or not password: return build_view(err="User နှင့် Password လိုအပ်သည်")
  if expires:
    try: datetime.strptime(expires,"%Y-%m-%d")
    except ValueError: return build_view(err="Expires format မမှန်ပါ (YYYY-MM-DD)")
  
  if port:
    if not re.fullmatch(r"\d{2,5}",port) or not (6000 <= int(port) <= 19999):
      return build_view(err="Port အကွာအဝေး 6000-19999")
  else:
    port=pick_free_port()
    if not port: return build_view(err="အသုံးပြုရန် port မရှိပါ")

  users=load_users(); replaced=False; new_user_info={}
  for u in users:
    if u.get("user","").lower()==user.lower():
      u.update({"password":password,"expires":expires,"port":port,"bind_ip":bind_ip}); replaced=True; new_user_info=u; break
  if not replaced:
    new_user_info={"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip}
    users.append(new_user_info)
    
  save_users(users); sync_config_passwords()
  
  session["new_user_info"] = new_user_info
  return redirect(url_for('show_info'))
  
@app.route("/show_info", methods=["GET"])
def show_info():
    info = session.pop("new_user_info", None)
    if info is None: return redirect(url_for('index'))
    return build_view(info_user=info)

@app.route("/edit", methods=["GET","POST"])
def edit_user():
  if request.method=="GET":
    q=(request.args.get("user") or "").strip().lower()
    users=load_users(); target=[u for u in users if u.get("user","").lower()==q]
    if not target: return build_view(err="မတွေ့ပါ")
    return build_view(edit_user_data=target[0])
    
  orig=(request.form.get("orig") or "").strip().lower()
  user=(request.form.get("user") or "").strip()
  password=(request.form.get("password") or "").strip()
  expires=(request.form.get("expires") or "").strip()
  port=(request.form.get("port") or "").strip()
  bind_ip=(request.form.get("bind_ip") or "").strip()
  
  if expires.isdigit():
    try: expires=(datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")
    except Exception: pass
    
  if not user or not password: return build_view(err="User/Password လိုအပ်", edit_user_data=request.form)
  
  if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)):
    return build_view(err="Port အကွာအဝေး 6000-19999", edit_user_data=request.form)

  users=load_users(); found=False
  for u in users:
    if u.get("user","").lower()==orig:
      old_port=u.get("port",""); old_ip=u.get("bind_ip","")
      
      if old_port and (str(old_port)!=str(port) or old_ip!=bind_ip):
        remove_limit_rules(old_port)
        
      u.update({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip})
      found=True; break
      
  if not found: return build_view(err="မတွေ့ပါ")
  
  save_users(users); sync_config_passwords(); apply_device_limits(users)
  return redirect(url_for('index', filter=request.args.get('filter', 'all')))

@app.route("/lock", methods=["POST"])
def lock_now():
  user=(request.form.get("user") or "").strip().lower()
  op=(request.form.get("op") or "").strip()
  users=load_users()
  
  u_data=[u for u in users if u.get("user","").lower()==user]
  if not u_data: return build_view(err="မတွေ့ပါ")
  u = u_data[0]
  port = u.get("port","")
  
  if op=="clear":
    u["bind_ip"]=""
    save_users(users); apply_device_limits(users)
    return redirect(url_for('index', filter=request.args.get('filter', 'all')))
    
  if op=="lock":
    if not port:
        return build_view(err="User တွင် Port မသတ်မှတ်ရသေးပါ")
    ip=first_recent_src_ip(port)
    if not ip:
      return build_view(err="လက်ရှိ UDP traffic မတွေ့ — client ချိတ်ပြီး Lock now ကိုပြန်နှိပ်ပါ")
      
    u["bind_ip"]=ip
    save_users(users); apply_device_limits(users)
    return redirect(url_for('index', filter=request.args.get('filter', 'all')))

  return redirect(url_for('index', filter=request.args.get('filter', 'all')))

@app.route("/delete", methods=["POST"])
def delete_user_html():
  user = (request.form.get("user") or "").strip()
  if not user: return build_view(err="User လိုအပ်သည်")
  remain=[]; removed=None
  for u in load_users():
    if u.get("user","").lower()==user.lower():
      removed=u
    else:
      remain.append(u)
  if removed and removed.get("port"): remove_limit_rules(removed.get("port"))
  save_users(remain); sync_config_passwords(mode="mirror")
  return build_view(msg=f"Deleted: {user}", filter_type=request.args.get('filter', 'all'))

@app.route("/favicon.ico", methods=["GET"])
def favicon(): return ("",204)

@app.errorhandler(405)
def handle_405(e): return redirect(url_for('index'))

if __name__ == "__main__":
  app.run(host="0.0.0.0", port=int(WEB_PORT))
