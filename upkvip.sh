#!/bin/bash
# ZIVPN UDP + Modern Web Panel (Myanmar UI)
# Original: Zahid Islam | MM UI: U Phote Kaunt | Consolidated by ChatGPT
# One-shot installer: ZIVPN binary + systemd + DNAT + UFW + sysctl + Web UI (+users/config sync)

set -euo pipefail

B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"
say(){ echo -e "$1"; }

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP Server + Web UI ကို တစ်ကြိမ်တည်း တပ်ဆင်နေပါတယ်…${Z}\n$LINE"

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then echo -e "${R}run as root (sudo -i)${Z}"; exit 1; fi

# --- APT guards ---
wait_for_apt(){ for _ in $(seq 1 60); do pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -f apt.systemd.daily >/dev/null || pgrep -x unattended-upgrade >/dev/null && sleep 5 || return 0; done
  systemctl stop --now unattended-upgrades.service 2>/dev/null || true
  systemctl stop --now apt-daily.service apt-daily.timer 2>/dev/null || true
  systemctl stop --now apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true; }
apt_guard_start(){ wait_for_apt; CNF="/etc/apt/apt.conf.d/50command-not-found"; if [ -f "$CNF" ]; then mv "$CNF" "$CNF.disabled"; CNF_DISABLED=1; else CNF_DISABLED=0; fi; }
apt_guard_end(){ dpkg --configure -a >/dev/null 2>&1 || true; apt-get -f install -y >/dev/null 2>&1 || true; if [ "${CNF_DISABLED:-0}" = "1" ] && [ -f "$CNF.disabled" ]; then mv "$CNF.disabled" "$CNF"; fi; }

# --- Packages ---
say "${Y}📦 Installing packages…${Z}"
export DEBIAN_FRONTEND=noninteractive
apt_guard_start
apt-get update -y -o APT::Update::Post-Invoke::= -o APT::Update::Post-Invoke-Success::= >/dev/null
apt-get install -y curl jq ufw iproute2 python3 python3-flask python3-apt conntrack iptables-persistent >/dev/null || true
apt_guard_end

# --- Stop old services (if any) ---
systemctl stop zivpn.service 2>/dev/null || true
systemctl stop zivpn-web.service 2>/dev/null || true

# --- Paths ---
BIN="/usr/local/bin/zivpn"
CFG="/etc/zivpn/config.json"
USERS="/etc/zivpn/users.json"
mkdir -p /etc/zivpn

# --- Get binary ---
say "${Y}⬇️ Downloading ZIVPN binary…${Z}"
TMP="/usr/local/bin/zivpn.new"
PURL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
FURL="https://github.com/zahidbd2/udp-zivpn/releases/latest/download/udp-zivpn-linux-amd64"
if ! curl -fsSL -o "$TMP" "$PURL"; then curl -fSL -o "$TMP" "$FURL"; fi
chmod +x "$TMP"; mv -f "$TMP" "$BIN"

# --- Base config & certs ---
if [ ! -f "$CFG" ]; then
  say "${Y}🧩 Creating base config.json…${Z}"
  curl -fsSL -o "$CFG" "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json"
fi
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  say "${Y}🔐 Generating self-signed cert…${Z}"
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=UPK/OU=Net/CN=zivpn" \
    -keyout /etc/zivpn/zivpn.key -out /etc/zivpn/zivpn.crt >/dev/null 2>&1
fi

# --- Password list (initial) ---
say "${C}🔏 Password List (comma-separated) eg: upkvip,alice,pass1${Z}"
read -r -p "Passwords (Enter = 'zi'): " INPW
if [ -z "${INPW:-}" ]; then PW='["zi"]'
else PW=$(echo "$INPW" | awk -F',' '{printf("["); for(i=1;i<=NF;i++){gsub(/^ *| *$/,"",$i); printf("%s\"%s\"", (i>1?",":""), $i)}; printf("]")}'); fi
TMPJSON=$(mktemp)
jq --argjson pw "$PW" '
  .auth.mode="passwords" |
  .auth.config=$pw |
  .listen=(."listen" // ":5667") |
  .cert="/etc/zivpn/zivpn.crt" |
  .key="/etc/zivpn/zivpn.key" |
  .obfs=(.obfs // "zivpn")
' "$CFG" >"$TMPJSON" && mv "$TMPJSON" "$CFG"

# --- users.json ---
[ -f "$USERS" ] || echo "[]" > "$USERS"
chmod 644 "$USERS" "$CFG" 2>/dev/null || true

# --- systemd (zivpn) ---
say "${Y}🧰 Writing systemd service (zivpn)…${Z}"
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

# --- DNAT + UFW ---
say "${Y}🛡️ Setting DNAT & UFW…${Z}"
IFACE=$(ip -4 route ls | awk '/default/ {print $5; exit}')
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
ufw allow 6000:19999/udp >/dev/null 2>&1 || true
ufw allow 5667/udp       >/dev/null 2>&1 || true
ufw allow 8080/tcp       >/dev/null 2>&1 || true
netfilter-persistent save >/dev/null 2>&1 || true

# --- sysctl (safe) ---
say "${Y}⚙️ Applying UDP/conntrack sysctl…${Z}"
cat >/etc/sysctl.d/90-zivpn-udp.conf <<'EOF'
net.netfilter.nf_conntrack_udp_timeout=300
net.netfilter.nf_conntrack_udp_timeout_stream=600
net.netfilter.nf_conntrack_max=262144
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl --system >/dev/null || true

# --- Web Panel (Flask) ---
say "${Y}🖥️ Writing web.py…${Z}"
cat >/etc/zivpn/web.py <<'PY'
from flask import Flask, jsonify, render_template_string, request
import json, re, subprocess, os, tempfile
from datetime import datetime, timedelta

USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LISTEN_FALLBACK = "5667"
RECENT_SECONDS = 120

HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<title>ZIVPN User Panel</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="120">
<style>
:root{--bg:#0b1020;--card:#121932;--text:#e8ecff;--muted:#9aa4cc;--ok:#30d158;--bad:#ff453a;--acc:#6b8cff}
*{box-sizing:border-box} body{margin:0;font-family:Inter,system-ui,Segoe UI,Roboto,Arial;background:linear-gradient(135deg,#0b1020,#0e1530);color:var(--text)}
nav{display:flex;align-items:center;justify-content:space-between;padding:16px 20px;background:rgba(255,255,255,.04)}
nav .brand{font-weight:700} nav .ip{font-size:.9rem;color:var(--muted)}
main{max-width:1024px;margin:24px auto;padding:0 16px}
.card{background:var(--card);border:1px solid rgba(255,255,255,.08);border-radius:16px;padding:18px}
h3{margin:0 0 12px}.tip{color:var(--muted);font-size:.95rem;margin:6px 0 16px}
form .row{display:flex;gap:16px;flex-wrap:wrap}.control{flex:1 1 220px;display:flex;flex-direction:column}
label{color:var(--muted);font-size:.85rem;margin:0 0 6px}
input{background:#0e1430;border:1px solid rgba(255,255,255,.1);color:var(--text);border-radius:12px;padding:10px}
button{background:var(--acc);border:none;color:white;padding:10px 14px;border-radius:12px;margin-top:10px;cursor:pointer;font-weight:600}
table{width:100%;border-collapse:collapse;margin-top:14px}
th,td{padding:10px;border-bottom:1px solid rgba(255,255,255,.08);text-align:left}
th{color:#cbd5ff;font-weight:600}.bad{color:var(--bad);font-weight:600}.ok{color:var(--ok);font-weight:600}.muted{color:var(--muted)}
.msg{margin:8px 0;color:var(--ok)} .err{margin:8px 0;color:var(--bad)} kbd{background:#0e1430;border:1px solid rgba(255,255,255,.1);padding:2px 6px;border-radius:6px}
</style></head><body>
<nav>
  <div class="brand">🔐 ZIVPN User Panel</div>
  <div class="ip">{{server_ip}} ▸ <span class="ip">refresh 120s</span></div>
</nav>
<main>
  <div class="card">
    <p class="tip">users.json ⇄ config.json(auth.config) ကို auto-sync လုပ်ပြီး Online/Offline ကို UDP activity (conntrack) နဲ့စစ်ထားပါတယ်။ <kbd>Expires</kbd> မှာ <b>YYYY-MM-DD</b> သို့ <b>30</b> (ယနေ့ကနေ 30 ရက်) လို နံပါတ်ထည့်လို့ရပါတယ်။</p>
    <form method="post" action="/add">
      <h3>➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
      {% if msg %}<div class="msg">{{msg}}</div>{% endif %}
      {% if err %}<div class="err">{{err}}</div>{% endif %}
      <div class="row">
        <div class="control"><label>👤 User</label><input name="user" required></div>
        <div class="control"><label>🔑 Password (auth.config)</label><input name="password" required></div>
      </div>
      <div class="row">
        <div class="control"><label>⏰ Expires (YYYY-MM-DD or days)</label><input name="expires" placeholder="2025-12-31 OR 30"></div>
        <div class="control"><label>🔌 UDP Port (6000–19999) — မထည့်လည်းရ</label><input name="port" placeholder=""></div>
      </div>
      <button type="submit">Save + Sync</button>
    </form>
  </div>
  <div class="card" style="margin-top:18px">
    <table>
      <tr><th>👤 User</th><th>🔑 Password</th><th>⏰ Expires</th><th>🔌 Port</th><th>🔎 Status</th></tr>
      {% for u in users %}
      <tr>
        <td>{{u.user}}</td><td>{{u.password}}</td><td>{{u.expires}}</td><td>{{u.port}}</td>
        <td>{% if u.status=="Online" %}<span class="ok">Online</span>{% elif u.status=="Offline" %}<span class="bad">Offline</span>{% else %}<span class="muted">Unknown</span>{% endif %}</td>
      </tr>
      {% endfor %}
    </table>
  </div>
</main>
</body></html>"""

def _read(p, d): 
    try:
        with open(p,"r") as f: return json.load(f)
    except Exception: return d

def _write_atomic(p, data):
    s=json.dumps(data, ensure_ascii=False, indent=2)
    d=os.path.dirname(p); fd,tmp=tempfile.mkstemp(prefix=".tmp-",dir=d)
    with os.fdopen(fd,"w") as f: f.write(s)
    os.replace(tmp,p)

def load_users():
    v=_read(USERS_FILE,[]); out=[]
    for u in v:
        out.append({"user":u.get("user",""),"password":u.get("password",""),
                    "expires":u.get("expires",""),
                    "port":str(u.get("port","")) if u.get("port","")!="" else ""})
    return out

def save_users(users): _write_atomic(USERS_FILE, users)

def listen_port():
    cfg=_read(CONFIG_FILE,{}); ls=str(cfg.get("listen","")).strip()
    m=re.search(r":(\d+)$",ls) if ls else None
    return m.group(1) if m else LISTEN_FALLBACK

def udp_listen_ports():
    out=subprocess.run("ss -uHln",shell=True,capture_output=True,text=True).stdout
    return set(re.findall(r":(\d+)\s",out))

def pick_free_port():
    used={str(u.get("port","")) for u in load_users() if str(u.get("port",""))}
    used |= udp_listen_ports()
    for p in range(6000,20000):
        if str(p) not in used: return str(p)
    return ""

def recent_udp(port:str)->bool:
    if not port: return False
    try:
        ext=subprocess.run(f"conntrack -L -p udp -o extended 2>/dev/null | grep 'dport={port}\\b'",shell=True,capture_output=True,text=True).stdout
        for line in ext.splitlines():
            m=re.search(r'timeout=(\d+)',line)
            if m and int(m.group(1))>=RECENT_SECONDS//2: return True
        if ext: return True
        out=subprocess.run(f"conntrack -L -p udp 2>/dev/null | grep 'dport={port}\\b'",shell=True,capture_output=True,text=True).stdout
        return bool(out)
    except Exception:
        return False

def status_for(u, active, lport):
    p=str(u.get("port","")); c=p if p else lport
    if recent_udp(c): return "Online"
    if c in active: return "Offline" if p else "Online"
    return "Unknown"

def sync_passwords():
    cfg=_read(CONFIG_FILE,{})
    pw=list(map(str,cfg.get("auth",{}).get("config",[]))) if isinstance(cfg.get("auth",{}).get("config",[]),list) else []
    users=load_users()
    merged=sorted(set(pw+[str(u["password"]) for u in users if u.get("password")]))
    cfg.setdefault("auth",{})["mode"]="passwords"
    cfg["auth"]["config"]=merged
    cfg["listen"]=cfg.get("listen") or ":5667"
    cfg["cert"]=cfg.get("cert") or "/etc/zivpn/zivpn.crt"
    cfg["key"]=cfg.get("key") or "/etc/zivpn/zivpn.key"
    cfg["obfs"]=cfg.get("obfs") or "zivpn"
    _write_atomic(CONFIG_FILE,cfg)
    subprocess.run("systemctl restart zivpn.service",shell=True)

from flask import Flask
app=Flask(__name__)

def render(msg="",err=""):
    users=load_users(); act=udp_listen_ports(); lp=listen_port()
    rows=[]
    for u in users:
        rows.append(type("U",(),{"user":u.get("user",""),"password":u.get("password",""),
                                 "expires":u.get("expires",""),"port":u.get("port",""),
                                 "status":status_for(u,act,lp)}))
    rows.sort(key=lambda x:(x.user or "").lower())
    ip=subprocess.run("hostname -I | awk '{print $1}'",shell=True,capture_output=True,text=True).stdout.strip()
    return render_template_string(HTML, users=rows, msg=msg, err=err, server_ip=ip or "0.0.0.0:8080")

@app.get("/")
def index(): return render()

@app.route("/add", methods=["GET","POST"])
def add_user():
    if request.method=="GET": return render()
    user=(request.form.get("user") or "").strip()
    password=(request.form.get("password") or "").strip()
    expires=(request.form.get("expires") or "").strip()
    port=(request.form.get("port") or "").strip()
    if not user or not password: return render(err="User နှင့် Password လိုအပ်သည်")
    if expires:
        if re.fullmatch(r"\d{1,3}",expires):
            expires=(datetime.now()+timedelta(days=int(expires))).strftime("%Y-%m-%d")
        else:
            try: datetime.strptime(expires,"%Y-%m-%d")
            except ValueError: return render(err="Expires (YYYY-MM-DD or days)")
    if port:
        if not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999): return render(err="Port 6000–19999")
    else:
        port=pick_free_port()
    users=load_users(); rep=False
    for u in users:
        if u.get("user","").lower()==user.lower():
            u.update({"password":password,"expires":expires,"port":port}); rep=True; break
    if not rep: users.append({"user":user,"password":password,"expires":expires,"port":port})
    save_users(users); sync_passwords()
    return render(msg="Saved & Synced")

@app.route("/api/users", methods=["GET","POST"])
def api_users():
    if request.method=="GET":
        users=load_users(); act=udp_listen_ports(); lp=listen_port()
        for u in users: u["status"]=status_for(u,act,lp)
        return jsonify(users)
    data=request.get_json(silent=True) or {}
    user=(data.get("user") or "").strip(); password=(data.get("password") or "").strip()
    expires=(data.get("expires") or "").strip(); port=str(data.get("port") or "").strip()
    if not user or not password: return jsonify({"ok":False,"err":"user/password required"}),400
    if expires:
        if re.fullmatch(r"\d{1,3}",expires):
            expires=(datetime.now()+timedelta(days=int(expires))).strftime("%Y-%m-%d")
        else:
            try: datetime.strptime(expires,"%Y-%m-%d")
            except ValueError: return jsonify({"ok":False,"err":"bad expires"}),400
    if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)):
        return jsonify({"ok":False,"err":"invalid port"}),400
    if not port: port=pick_free_port()
    users=load_users(); rep=False
    for u in users:
        if u.get("user","").lower()==user.lower():
            u.update({"password":password,"expires":expires,"port":port}); rep=True; break
    if not rep: users.append({"user":user,"password":password,"expires":expires,"port":port})
    save_users(users); sync_passwords()
    return jsonify({"ok":True})

if __name__=="__main__":
    app.run(host="0.0.0.0", port=8080)
PY

# --- web service ---
cat >/etc/systemd/system/zivpn-web.service <<'EOF'
[Unit]
Description=ZIVPN Web Panel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /etc/zivpn/web.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# --- sanitize & enable ---
sed -i 's/\r$//' /etc/zivpn/web.py /etc/systemd/system/zivpn.service /etc/systemd/system/zivpn-web.service || true
systemctl daemon-reload
systemctl enable --now zivpn.service
systemctl enable --now zivpn-web.service

IP=$(hostname -I | awk '{print $1}')
echo -e "\n$LINE\n${G}✅ Done${Z}"
echo -e "${C}Web Panel:${Z} http://${IP}:8080"
echo -e "${C}users.json:${Z} /etc/zivpn/users.json"
echo -e "${C}config.json:${Z} /etc/zivpn/config.json"
echo -e "${C}Services:${Z} systemctl status|restart zivpn  •  systemctl status|restart zivpn-web"
echo -e "$LINE"
