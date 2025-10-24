#!/bin/bash
# ZIVPN UDP Server + Web UI Installer (Myanmar) — One-Device Lock + Edit UI
# - Keeps your API server UNCHANGED. Uses KEY_API_URL:/api/consume only.
# - Android-friendly UI, per-user Edit, one-device limit via iptables.
# - Services: zivpn.service, zivpn-web.service

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"
say(){ echo -e "$1"; }

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP Server + Web UI ကို ထည့်သွင်းနေသည်${Z}\n$LINE"

# ===== Root check =====
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}❌ root အဖြစ် chạy ပါ (sudo -i)${Z}"; exit 1
fi

# ======= ONE-TIME KEY GATE (API UNCHANGED; call /api/consume) =======
KEY_API_URL="${KEY_API_URL:-http://43.229.135.219:8088}"   # <- မိမိ API URL ရှိရင် ENV ကနေ override လုပ်နိုင်
consume_one_time_key() {
  local _key="$1" _url="${KEY_API_URL%/}/api/consume" resp
  command -v curl >/dev/null 2>&1 || { echo -e "${R}curl မရှိ — apt install -y curl${Z}"; exit 2; }
  echo -e "${Y}🔑 One-time key စစ်နေ...${Z}"
  set +e
  resp=$(curl -fsS -X POST "$_url" -H 'Content-Type: application/json' -d "{\"key\":\"${_key}\"}")
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then echo -e "${R}❌ Key server မချိတ်ဘူး${Z}"; exit 2; fi
  if echo "$resp" | grep -q '"ok":\s*true'; then
    echo -e "${G}✅ Key မှန် (consumed) — ဆက်လုပ်မယ်${Z}"
  else
    echo -e "${R}❌ Key မမှန်/ပြီးသုံးပြီး:${Z} $resp"; return 1
  fi
}
while :; do
  echo -ne "${C}Enter one-time key: ${Z}"
  read -r -s ONE_TIME_KEY; echo
  [ -z "${ONE_TIME_KEY:-}" ] && { echo -e "${Y}⚠️ key မထည့်ရသေး — ထပ်ထည့်ပါ${Z}"; continue; }
  consume_one_time_key "$ONE_TIME_KEY" && break || echo -e "${Y}🔁 ထပ်စမ်းပါ${Z}"
done

# ======= apt guard & packages =======
wait_for_apt(){ for _ in $(seq 1 60); do
  if pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -f 'apt.systemd.daily' >/dev/null || pgrep -x unattended-upgrade >/dev/null; then sleep 5; else return 0; fi
done; }
CNF_CONF="/etc/apt/apt.conf.d/50command-not-found"
apt_guard_start(){ wait_for_apt; if [ -f "$CNF_CONF" ]; then mv "$CNF_CONF" "${CNF_CONF}.disabled"; CNF_DISABLED=1; else CNF_DISABLED=0; fi; }
apt_guard_end(){ dpkg --configure -a >/dev/null 2>&1 || true; apt-get -f install -y >/dev/null 2>&1 || true; if [ "${CNF_DISABLED:-0}" = 1 ] && [ -f "${CNF_CONF}.disabled" ]; then mv "${CNF_CONF}.disabled" "$CNF_CONF"; fi; }

say "${Y}📦 Packages တင်နေ...${Z}"
apt_guard_start
apt-get update -y -o APT::Update::Post-Invoke::= >/dev/null
apt-get install -y curl ufw jq python3 python3-flask python3-apt iproute2 conntrack ca-certificates openssl >/dev/null
apt_guard_end

# ======= Paths =======
BIN="/usr/local/bin/zivpn"
CFG="/etc/zivpn/config.json"
USERS="/etc/zivpn/users.json"
ENVF="/etc/zivpn/web.env"
mkdir -p /etc/zivpn

# ======= Download ZIVPN binary =======
say "${Y}⬇️ ZIVPN binary ဒေါင်းနေ...${Z}"
PRIMARY_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
FALLBACK_URL="https://github.com/zahidbd2/udp-zivpn/releases/latest/download/udp-zivpn-linux-amd64"
TMP_BIN="$(mktemp)"
if ! curl -fsSL -o "$TMP_BIN" "$PRIMARY_URL"; then
  echo -e "${Y}Primary မရ — latest ဆက်စမ်း...${Z}"
  curl -fSL -o "$TMP_BIN" "$FALLBACK_URL"
fi
install -m 0755 "$TMP_BIN" "$BIN"; rm -f "$TMP_BIN"

# ======= Base config =======
if [ ! -f "$CFG" ]; then
  say "${Y}🧩 config.json ဖန်တီးနေ...${Z}"
  curl -fsSL -o "$CFG" "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json" || echo '{}' > "$CFG"
fi

# ======= Self-signed certs =======
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  say "${Y}🔐 SSL ဖန်တီးနေ...${Z}"
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=UPK/OU=Net/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# ======= Web Admin (optional) =======
say "${Y}🔒 Web Admin Login UI ထည့်မလား? (Enter = disable)${Z}"
read -r -p "Web Admin Username: " WEB_USER
if [ -n "${WEB_USER:-}" ]; then
  read -r -s -p "Web Admin Password: " WEB_PASS; echo
  if command -v openssl >/dev/null 2>&1; then WEB_SECRET="$(openssl rand -hex 32)"; else WEB_SECRET="$(python3 - <<'PY'\nimport secrets;print(secrets.token_hex(32))\nPY\n)"; fi
  printf "WEB_ADMIN_USER=%s\nWEB_ADMIN_PASSWORD=%s\nWEB_SECRET=%s\n" "$WEB_USER" "$WEB_PASS" "$WEB_SECRET" > "$ENVF"
  chmod 600 "$ENVF"; say "${G}✅ Web login UI ဖွင့်ထားသည်${Z}"
else
  rm -f "$ENVF" 2>/dev/null || true
  say "${Y}ℹ️ Web login UI မဖွင့်ထားပါ (dev mode)${Z}"
fi

# ======= Initial passwords =======
say "${G}🔏 VPN Password List (ကော်မာဖြင့်ခွဲ) eg: upkvip,alice,pass1${Z}"
read -r -p "Passwords (Enter=zi): " input_pw
if [ -z "${input_pw:-}" ]; then
  PW_LIST='["zi"]'
else
  PW_LIST=$(echo "$input_pw" | awk -F',' '{
    printf("["); for(i=1;i<=NF;i++){gsub(/^ *| *$/,"",$i); printf("%s\"%s\"", (i>1?",":""), $i)}; printf("]")
  }')
fi

# ======= Update config.json =======
if jq . >/dev/null 2>&1 <<<'{}'; then
  TMP=$(mktemp)
  jq --argjson pw "$PW_LIST" '
    .auth.mode = "passwords" |
    .auth.config = $pw |
    .listen = (."listen" // ":5667") |
    .cert = "/etc/zivpn/zivpn.crt" |
    .key  = "/etc/zivpn/zivpn.key" |
    .obfs = (."obfs" // "zivpn")
  ' "$CFG" > "$TMP" && mv "$TMP" "$CFG"
fi
[ -f "$USERS" ] || echo "[]" > "$USERS"
chmod 644 "$CFG" "$USERS"

# ======= systemd: ZIVPN =======
say "${Y}🧰 systemd service (zivpn) သွင်းနေ...${Z}"
cat >/etc/systemd/system/zivpn.service <<'EOF'
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
EOF

# ======= Flask Web UI (Android-friendly + Edit + One-Device Lock) =======
say "${Y}🖥️ Web Panel (Flask) ထည့်နေ...${Z}"
cat >/etc/zivpn/web.py <<'PY'
from flask import Flask, jsonify, render_template_string, request, redirect, url_for, session, make_response
import json, subprocess, os, tempfile, hmac, re
from datetime import datetime, timedelta

USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LISTEN_FALLBACK = "5667"
LOGO_URL = "https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png"

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

def save_users(users): write_json_atomic(USERS_FILE, users)

def sh(cmd):
  return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def get_listen_port_from_config():
  cfg=read_json(CONFIG_FILE,{})
  listen=str(cfg.get("listen","")).strip()
  m=re.search(r":(\d+)$", listen) if listen else None
  return (m.group(1) if m else LISTEN_FALLBACK)

def get_udp_listen_ports():
  out=sh("ss -uHln").stdout
  return set(re.findall(r":(\d+)\s", out))

def pick_free_port():
  used={str(u.get("port","")) for u in load_users() if str(u.get("port",""))}
  used |= get_udp_listen_ports()
  for p in range(6000,20000):
    if str(p) not in used: return str(p)
  return ""

def has_recent_udp_activity(port):
  if not port: return False
  out=sh(f"conntrack -L -p udp 2>/dev/null | grep -w 'dport={port}' | head -n1 || true").stdout
  return bool(out.strip())

def first_recent_src_ip(port):
  if not port: return ""
  out=sh(f"conntrack -L -p udp 2>/dev/null | awk \"/dport={port}\\b/ {{for(i=1;i<=NF;i++) if($i~/src=/){{split($i,a,'='); print a[2]; exit}}}}\"").stdout.strip()
  return out if re.fullmatch(r'(?:\d{1,3}\.){3}\d{1,3}', out) else ""

def status_for_user(u, active_ports, listen_port):
  port=str(u.get("port",""))
  check_port=port if port else listen_port
  if has_recent_udp_activity(check_port): return "Online"
  if check_port in active_ports: return "Offline"
  return "Unknown"

def ipt(cmd): return sh(cmd)
def ensure_limit_rules(port, ip):
  if not (port and ip): return
  ipt(f"iptables -C INPUT -p udp --dport {port} -s {ip} -j ACCEPT 2>/dev/null") or ipt(f"iptables -I INPUT -p udp --dport {port} -s {ip} -j ACCEPT")
  ipt(f"iptables -C INPUT -p udp --dport {port} ! -s {ip} -j DROP 2>/dev/null") or ipt(f"iptables -I INPUT -p udp --dport {port} ! -s {ip} -j DROP")

def remove_limit_rules(port):
  if not port: return
  for _ in range(20):
    line=ipt(f"iptables -S INPUT | grep -E \"-p udp .* --dport {port}\\b .* (-j DROP|-j ACCEPT)\" | head -n1 || true").stdout.strip()
    if not line: break
    rule=line.replace('-A ','')
    ipt(f"iptables -D INPUT {rule}")

def apply_device_limits(users):
  for u in users:
    p=str(u.get("port","") or "")
    ip=(u.get("bind_ip","") or "").strip()
    if p and ip: ensure_limit_rules(p, ip)
    elif p: remove_limit_rules(p)

def login_enabled(): return bool(ADMIN_USER and ADMIN_PASS)
def is_authed(): return session.get("auth") == True
def require_login(): return (not login_enabled()) or is_authed()

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
  sh("systemctl restart zivpn.service")

HTML = """<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>ZIVPN Panel</title>
<style>
:root{--bg:#0b0f14;--fg:#e6edf3;--muted:#9aa7b3;--card:#111823;--bd:#1f2a37;--ok:#22c55e;--bad:#ef4444;--unk:#9ca3af}
html,body{background:var(--bg);color:var(--fg)} body{font-family:system-ui,Segoe UI,Roboto,'Noto Sans Myanmar',sans-serif;margin:0;padding:14px}
.wrap{max-width:1000px;margin:0 auto}
header{display:flex;gap:12px;align-items:center;margin-bottom:10px}
h1{margin:0;font-size:20px} .sub{color:var(--muted);font-size:13px}
.btn{padding:9px 12px;border-radius:999px;border:1px solid var(--bd);background:#0e1623;color:var(--fg);text-decoration:none}
.box{margin:12px 0;padding:12px;border:1px solid var(--bd);border-radius:14px;background:var(--card)}
table{border-collapse:collapse;width:100%} th,td{border:1px solid var(--bd);padding:10px;text-align:left;font-size:14px}
th{background:#0d1420;font-size:12.5px}
.pill{display:inline-block;padding:4px 10px;border-radius:999px}
.ok{background:var(--ok);color:#001009}.bad{background:var(--bad);color:#1b0000}.unk{background:var(--unk);color:#0b0f14}
input{width:100%;max-width:420px;padding:10px;border:1px solid var(--bd);border-radius:12px;background:#0a1220;color:var(--fg)}
.form-inline{display:flex;gap:10px;flex-wrap:wrap}.form-inline>div{min-width:180px;flex:1}
@media(max-width:480px){ th,td{font-size:13px} .btn{padding:9px 10px} body{padding:10px} }
</style></head><body>
<div class="wrap">
<header>
  <img src="{{logo}}" style="height:40px;border-radius:10px">
  <div style="flex:1">
    <h1>DEV-U PHOE KAUNT</h1>
    <div class="sub">ZIVPN Panel • Total: {{total}}</div>
  </div>
  {% if authed %}<a class="btn" href="/logout">Logout</a>{% endif %}
</header>

{% if not authed %}
  <div class="box" style="max-width:440px;margin:40px auto">
    {% if err %}<div style="color:var(--bad);margin-bottom:8px">{{err}}</div>{% endif %}
    <form method="post" action="/login">
      <label>Username</label><input name="u" autofocus required>
      <label style="margin-top:8px">Password</label><input name="p" type="password" required>
      <button class="btn" type="submit" style="margin-top:12px;width:100%">Login</button>
    </form>
  </div>
{% else %}

<div class="box">
  <h3 style="margin:4px 0 8px">➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
  {% if msg %}<div style="color:var(--ok);margin:6px 0">{{msg}}</div>{% endif %}
  {% if err %}<div style="color:var(--bad);margin:6px 0">{{err}}</div>{% endif %}
  <form method="post" action="/add" class="form-inline">
    <div><label>👤 User</label><input name="user" required></div>
    <div><label>🔑 Password</label><input name="password" required></div>
    <div><label>⏰ Expires</label><input name="expires" placeholder="2025-12-31 or 30"></div>
    <div><label>🔌 UDP Port</label><input name="port" placeholder="auto"></div>
    <div><label>📱 Bind IP (1 device)</label><input name="bind_ip" placeholder="auto when online…"></div>
    <div style="align-self:end"><button class="btn" type="submit">Save + Sync</button></div>
  </form>
</div>

<table>
  <tr>
    <th>👤 User</th><th>🔑 Password</th><th>⏰ Expires</th><th>🔌 Port</th><th>📱 Bind IP</th><th>🔎 Status</th><th>✏️ Edit</th><th>🗑️ Delete</th>
  </tr>
  {% for u in users %}
  <tr>
    <td>{{u.user}}</td>
    <td>{{u.password}}</td>
    <td>{% if u.expires %}{{u.expires}}{% else %}<span style="opacity:.6">—</span>{% endif %}</td>
    <td>{{u.port or "—"}}</td>
    <td>{{u.bind_ip or "—"}}</td>
    <td>{% if u.status=="Online" %}<span class="pill ok">Online</span>{% elif u.status=="Offline" %}<span class="pill bad">Offline</span>{% else %}<span class="pill unk">Unknown</span>{% endif %}</td>
    <td>
      <form method="get" action="/edit" style="display:inline">
        <input type="hidden" name="user" value="{{u.user}}">
        <button class="btn" type="submit">Edit</button>
      </form>
    </td>
    <td>
      <form method="post" action="/delete" onsubmit="return confirm('ဖျက်မလား?')" style="display:inline">
        <input type="hidden" name="user" value="{{u.user}}">
        <button class="btn" style="background:#2a0f0f;border-color:#3b1d1d">Delete</button>
      </form>
    </td>
  </tr>
  {% endfor %}
</table>

{% endif %}
</div>
</body></html>
"""

def get_active_ports(): return get_udp_listen_ports()

def build_view(msg="", err=""):
  if login_enabled() and session.get("auth")!=True:
    return render_template_string(HTML, authed=False, logo=LOGO_URL, err=session.pop("login_err", None), total=0)
  users=load_users()
  # Auto-bind when online (first src IP)
  changed=False
  for u in users:
    if u.get("port") and not u.get("bind_ip"):
      ip=first_recent_src_ip(u["port"])
      if ip: u["bind_ip"]=ip; changed=True
  if changed: save_users(users)
  apply_device_limits(users)
  active=get_active_ports()
  listen_port=get_listen_port_from_config()
  view=[]
  for u in users:
    view.append(type("U",(),{
      "user":u.get("user",""),
      "password":u.get("password",""),
      "expires":u.get("expires",""),
      "port":u.get("port",""),
      "bind_ip":u.get("bind_ip",""),
      "status":("Online" if has_recent_udp_activity(u.get("port") or listen_port) else ("Offline" if (u.get("port") or listen_port) in active else "Unknown"))
    }))
  view.sort(key=lambda x:(x.user or "").lower())
  return render_template_string(HTML, authed=True, logo=LOGO_URL, users=view, msg=msg, err=err, total=len(view))

def login_enabled(): return bool(ADMIN_USER and ADMIN_PASS)

@app.route("/login", methods=["GET","POST"])
def login():
  if not login_enabled(): return redirect(url_for('index'))
  if request.method=="POST":
    u=(request.form.get("u") or "").strip()
    p=(request.form.get("p") or "").strip()
    if hmac.compare_digest(u, ADMIN_USER) and hmac.compare_digest(p, ADMIN_PASS):
      session["auth"]=True; return redirect(url_for('index'))
    session["auth"]=False; session["login_err"]="မှန်ကန်မှုမရှိပါ (username/password)"; return redirect(url_for('login'))
  return render_template_string(HTML, authed=False, logo=LOGO_URL, err=session.pop("login_err", None), total=0)

@app.route("/logout", methods=["GET"])
def logout():
  session.pop("auth", None)
  return redirect(url_for('login') if login_enabled() else url_for('index'))

@app.route("/", methods=["GET"])
def index(): return build_view()

@app.route("/add", methods=["POST"])
def add_user():
  if login_enabled() and session.get("auth")!=True: return redirect(url_for('login'))
  user=(request.form.get("user") or "").strip()
  password=(request.form.get("password") or "").strip()
  expires=(request.form.get("expires") or "").strip()
  port=(request.form.get("port") or "").strip()
  bind_ip=(request.form.get("bind_ip") or "").strip()
  if expires.isdigit(): expires=(datetime.now()+timedelta(days=int(expires))).strftime("%Y-%m-%d")
  if not user or not password: return build_view(err="User/Password လိုအပ်")
  if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)): return build_view(err="Port 6000–19999")
  if not port: port=pick_free_port()
  users=load_users(); rep=False
  for u in users:
    if u.get("user","").lower()==user.lower():
      u.update({"password":password,"expires":expires,"port":port,"bind_ip":bind_ip}); rep=True; break
  if not rep: users.append({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip})
  save_users(users); sync_config_passwords()
  return build_view(msg="Saved & Synced")

@app.route("/edit", methods=["GET","POST"])
def edit_user():
  if login_enabled() and session.get("auth")!=True: return redirect(url_for('login'))
  if request.method=="GET":
    q=(request.args.get("user") or "").strip().lower()
    users=load_users(); t=[u for u in users if u.get("user","").lower()==q]
    if not t: return build_view(err="မတွေ့ပါ")
    u=t[0]
    frm=f"""<div class='wrap box'><h3>✏️ Edit: {u.get('user')}</h3>
    <form method='post' action='/edit' class='form-inline'>
      <input type='hidden' name='orig' value='{u.get('user')}'>
      <div><label>👤 User</label><input name='user' value='{u.get('user')}' required></div>
      <div><label>🔑 Password</label><input name='password' value='{u.get('password')}' required></div>
      <div><label>⏰ Expires</label><input name='expires' value='{u.get('expires','')}' placeholder='2025-12-31 or 30'></div>
      <div><label>🔌 UDP Port</label><input name='port' value='{u.get('port','')}'></div>
      <div><label>📱 Bind IP</label><input name='bind_ip' value='{u.get('bind_ip','')}' placeholder='blank = no lock'></div>
      <div style='align-self:end'><button class='btn' type='submit'>Save</button> <a class='btn' href='/'>Cancel</a></div>
    </form></div>"""
    base=build_view(); return base.replace("</div>\n</body>","</div>"+frm+"</body>")
  orig=(request.form.get("orig") or "").strip().lower()
  user=(request.form.get("user") or "").strip()
  password=(request.form.get("password") or "").strip()
  expires=(request.form.get("expires") or "").strip()
  port=(request.form.get("port") or "").strip()
  bind_ip=(request.form.get("bind_ip") or "").strip()
  if expires.isdigit(): expires=(datetime.now()+timedelta(days=int(expires))).strftime("%Y-%m-%d")
  if not user or not password: return build_view(err="User/Password လိုအပ်")
  if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)): return build_view(err="Port 6000–19999")
  users=load_users(); found=False
  for u in users:
    if u.get("user","").lower()==orig:
      oldp=u.get("port"); oldip=u.get("bind_ip","")
      if oldp and (str(oldp)!=str(port) or oldip!=bind_ip): remove_limit_rules(oldp)
      u.update({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip}); found=True; break
  if not found: return build_view(err="မတွေ့ပါ")
  save_users(users); sync_config_passwords()
  return redirect(url_for('index'))

@app.route("/lock", methods=["POST"])
def lock_now():
  if login_enabled() and session.get("auth")!=True: return redirect(url_for('login'))
  user=(request.form.get("user") or "").strip().lower()
  op=(request.form.get("op") or "").strip()
  users=load_users()
  for u in users:
    if u.get("user","").lower()==user:
      p=u.get("port","")
      if op=="clear":
        u["bind_ip"]=""; save_users(users); apply_device_limits(users)
        return build_view(msg=f"Cleared lock for {u['user']}")
      ip=first_recent_src_ip(p)
      if not ip: return build_view(err="UDP traffic မတွေ့ — client ချိတ်ပြီး Lock now ကိုပြန်နှိပ်")
      u["bind_ip"]=ip; save_users(users); apply_device_limits(users)
      return build_view(msg=f"Locked {u['user']} to {ip}")
  return build_view(err="မတွေ့ပါ")

@app.route("/delete", methods=["POST"])
def delete_user_html():
  if login_enabled() and session.get("auth")!=True: return redirect(url_for('login'))
  user=(request.form.get("user") or "").strip()
  if not user: return build_view(err="User လိုအပ်")
  remain=[]; removed=None
  for u in load_users():
    if u.get("user","").lower()==user.lower(): removed=u
    else: remain.append(u)
  if removed and removed.get("port"): remove_limit_rules(removed.get("port"))
  save_users(remain); sync_config_passwords(mode="mirror")
  return build_view(msg=f"Deleted: {user}")

@app.route("/api/users", methods=["GET"])
def api_users():
  if login_enabled() and session.get("auth")!=True:
    return make_response(jsonify({"ok": False, "err":"login required"}), 401)
  users=load_users(); active=get_udp_listen_ports(); listen_port=get_listen_port_from_config()
  for u in users: u["status"]=status_for_user(u,active,listen_port)
  return jsonify(users)

@app.route("/favicon.ico")
def favicon(): return ("",204)

@app.errorhandler(405)
def handle_405(e): return redirect(url_for('index'))

if __name__=="__main__":
  app.run(host="0.0.0.0", port=8080)
PY
chmod 644 /etc/zivpn/web.py

# ======= systemd: Web =======
cat >/etc/systemd/system/zivpn-web.service <<'EOF'
[Unit]
Description=ZIVPN Web Panel
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=-/etc/zivpn/web.env
ExecStart=/usr/bin/python3 /etc/zivpn/web.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ======= Networking (DNAT+MASQ + UFW) =======
echo -e "${Y}🌐 UDP DNAT + MASQUERADE + sysctl ဖွင့်နေ...${Z}"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

IFACE="$(ip -4 route ls | awk '/default/ {print $5; exit}')" || true
[ -n "${IFACE:-}" ] || IFACE=eth0
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
iptables -t nat -I PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -I POSTROUTING -o "$IFACE" -j MASQUERADE

ufw allow 5667/udp >/dev/null 2>&1 || true
ufw allow 6000:19999/udp >/dev/null 2>&1 || true
ufw allow 8080/tcp >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true

# ======= CRLF sanitize & enable =======
sed -i 's/\r$//' /etc/zivpn/web.py /etc/systemd/system/zivpn.service /etc/systemd/system/zivpn-web.service || true
systemctl daemon-reload
systemctl enable --now zivpn.service
systemctl enable --now zivpn-web.service

IP=$(hostname -I | awk '{print $1}')
echo -e "\n$LINE\n${G}✅ Done${Z}"
echo -e "${C}Web Panel   :${Z} ${Y}http://$IP:8080${Z}"
echo -e "${C}users.json  :${Z} ${Y}/etc/zivpn/users.json${Z}"
echo -e "${C}config.json :${Z} ${Y}/etc/zivpn/config.json${Z}"
echo -e "${C}Services    :${Z} ${Y}systemctl status|restart zivpn  •  systemctl status|restart zivpn-web${Z}"
echo -e "$LINE"
