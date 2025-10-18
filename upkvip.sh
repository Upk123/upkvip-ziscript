#!/bin/bash
# ZIVPN UDP Module + Web Panel (Myanmar UI)
# Original: Zahid Islam | Tweaks & MM UI: U Phote Kaunt
# Patch: apt-wait + apt_pkg guard, download fallback, UFW 8080 allow, iproute2
# Extra: Live per-user Online/Offline via conntrack + users.json <-> config.json sync
# Extra fix: Add User POST => render immediately (no redirect) + CRLF sanitize + safe heredocs

set -e

# ===== Pretty =====
B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; M="\e[1;35m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"
say() { echo -e "$1"; }

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP Server ကို တပ်ဆင်/ညှိနှိုင်းနေပါတယ်... (Live Online/Offline)${Z}\n$LINE"

# ===== Pre-flight =====
say "${C}🔑 Root အခွင့်အရေး 필요${Z}"
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}ဤ script ကို root အဖြစ် chạy ရပါမယ် (sudo -i)${Z}"; exit 1
fi

# --- apt guards ---
wait_for_apt() {
  echo -e "${Y}⏳ apt ပိတ်မချင်း စောင့်နေပါတယ်...${Z}"
  for _ in $(seq 1 60); do
    if pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null || pgrep -f 'apt.systemd.daily' >/dev/null || pgrep -x unattended-upgrade >/dev/null; then
      sleep 5
    else
      return 0
    fi
  done
  echo -e "${Y}⚠️ apt မပြီးသေး — timers ကို ယာယီရပ်နေပါတယ်${Z}"
  systemctl stop --now unattended-upgrades.service 2>/dev/null || true
  systemctl stop --now apt-daily.service apt-daily.timer 2>/dev/null || true
  systemctl stop --now apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true
}

apt_guard_start() {
  wait_for_apt
  CNF_CONF="/etc/apt/apt.conf.d/50command-not-found"
  if [ -f "$CNF_CONF" ]; then
    mv "$CNF_CONF" "${CNF_CONF}.disabled"
    CNF_DISABLED=1
  else
    CNF_DISABLED=0
  fi
}

apt_guard_end() {
  dpkg --configure -a >/dev/null 2>&1 || true
  apt-get -f install -y >/dev/null 2>&1 || true
  if [ "${CNF_DISABLED:-0}" = "1" ] && [ -f "${CNF_CONF}.disabled" ]; then
    mv "${CNF_CONF}.disabled" "$CNF_CONF"
  fi
}

# ===== Packages =====
say "${Y}📦 Packages တွေ အပ်ဒိတ်လုပ်နေပါတယ်... (အချိန်ကြာနိုင်)${Z}"
export DEBIAN_FRONTEND=noninteractive
apt_guard_start
apt-get update -y -o APT::Update::Post-Invoke-Success::= -o APT::Update::Post-Invoke::= >/dev/null
apt-get install -y curl ufw jq python3 python3-flask python3-apt iproute2 conntrack >/dev/null || {
  apt-get install -y -o DPkg::Lock::Timeout=60 python3-apt >/dev/null || true
  apt-get install -y curl ufw jq python3 python3-flask iproute2 conntrack >/dev/null
}
apt_guard_end

# Stop old services to avoid 'text file busy'
systemctl stop zivpn.service 2>/dev/null || true
systemctl stop zivpn-web.service 2>/dev/null || true

# ===== Download / Install ZIVPN binary =====
say "${Y}⬇️ ZIVPN binary ကို ဒေါင်းနေပါတယ်...${Z}"
BIN_TMP="/usr/local/bin/zivpn.new"
BIN="/usr/local/bin/zivpn"
PRIMARY_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
FALLBACK_URL="https://github.com/zahidbd2/udp-zivpn/releases/latest/download/udp-zivpn-linux-amd64"

if ! curl -fsSL -o "$BIN_TMP" "$PRIMARY_URL"; then
  echo -e "${Y}Primary URL မရ — latest ကို စမ်းပါတယ်...${Z}"
  curl -fSL -o "$BIN_TMP" "$FALLBACK_URL"
fi
chmod +x "$BIN_TMP"
mv -f "$BIN_TMP" "$BIN"

# ===== Config folder & base files =====
mkdir -p /etc/zivpn
CFG="/etc/zivpn/config.json"
if [ ! -f "$CFG" ]; then
  say "${Y}🧩 မူရင်း config.json ကို ဖန်တီးနေပါတယ်...${Z}"
  curl -fsSL -o "$CFG" "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json"
fi

# ===== Generate certs (once) =====
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  say "${Y}🔐 SSL စိတျဖိုင်တွေ ဖန်တီးနေပါတယ်...${Z}"
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=UPK/OU=Net/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# ===== Ask initial passwords =====
say "${G}🔏 \"Password List\" ထည့်ပါ (ကော်မာဖြင့်ခွဲ) eg: upkvip,alice,pass1 ${Z}"
read -r -p "Passwords (Enter ကို နှိပ်ရင် 'zi' သာ သုံးမယ်): " input_pw
if [ -z "$input_pw" ]; then
  PW_LIST='["zi"]'
else
  PW_LIST=$(echo "$input_pw" | awk -F',' '{
    printf("["); for(i=1;i<=NF;i++){gsub(/^ *| *$/,"",$i); printf("%s\"%s\"", (i>1?",":""), $i)}; printf("]")
  }')
fi

# Update config.json
if jq . >/dev/null 2>&1 <<<'{}'; then
  TMP=$(mktemp)
  jq --argjson pw "$PW_LIST" '
    .auth.mode = "passwords" |
    .auth.config = $pw |
    .listen = (."listen" // ":5667") |
    .cert = "/etc/zivpn/zivpn.crt" |
    .key  = "/etc/zivpn/zivpn.key" |
    .obfs = "zivpn"
  ' "$CFG" > "$TMP" && mv "$TMP" "$CFG"
fi
say "${G}✅ Password List ကို config.json ထဲသို့ ထည့်ပြီးပါပြီ${Z}"

# ===== users.json =====
USERS="/etc/zivpn/users.json"
[ -f "$USERS" ] || echo "[]" > "$USERS"
chown root:root "$USERS" "$CFG" 2>/dev/null || true
chmod 644 "$USERS" "$CFG" 2>/dev/null || true

# ===== systemd service for ZIVPN =====
say "${Y}🧰 systemd service (zivpn.service) ကို ထည့်နေပါတယ်...${Z}"
cat > /etc/systemd/system/zivpn.service <<'EOF'
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

# ===== Web Panel (Flask) =====
say "${Y}🖥️ Web Panel (Flask) ကိုတပ်နေပါတယ်...${Z}"
cat > /etc/zivpn/web.py <<'PY'
from flask import Flask, jsonify, render_template_string, request
import json, re, subprocess, os, tempfile
from datetime import datetime

USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LISTEN_FALLBACK = "5667"   # zivpn default listen port
RECENT_SECONDS = 120       # UDP activity threshold

HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<title>ZIVPN User Panel</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="10">
<style>
 body{font-family:system-ui,Segoe UI,Roboto,Arial;margin:24px}
 h2{margin:0 0 12px}
 .tip{color:#666;margin:6px 0 18px}
 table{border-collapse:collapse;width:100%;max-width:980px}
 th,td{border:1px solid #ddd;padding:8px;text-align:left}
 th{background:#f5f5f5}
 .ok{color:#0a0}.bad{color:#a00}.muted{color:#666}
 form{margin:18px 0;padding:12px;border:1px solid #ddd;border-radius:12px;background:#fafafa;max-width:980px}
 label{display:block;margin:6px 0 2px}
 input{width:100%;max-width:420px;padding:8px;border:1px solid #ccc;border-radius:8px}
 button{margin-top:10px;padding:8px 14px;border-radius:10px;border:1px solid #ccc;background:#fff;cursor:pointer}
 .row{display:flex;gap:18px;flex-wrap:wrap}
 .row>div{flex:1 1 220px}
 .msg{margin:10px 0;color:#0a0}
 .err{margin:10px 0;color:#a00}
</style></head><body>
<h2>📒 ZIVPN User Panel</h2>
<p class="tip">users.json ⇄ config.json(auth.config) ကို auto-sync လုပ်ထားပြီး၊ Online/Offline ကို UDP activity (conntrack) နဲ့ စစ်၊ LISTEN ကို fallback လုပ်ပါတယ် (10s auto refresh).</p>

<form method="post" action="/add">
  <h3>➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
  {% if msg %}<div class="msg">{{msg}}</div>{% endif %}
  {% if err %}<div class="err">{{err}}</div>{% endif %}
  <div class="row">
    <div><label>👤 User</label><input name="user" required></div>
    <div><label>🔑 Password (auth.config)</label><input name="password" required></div>
  </div>
  <div class="row">
    <div><label>⏰ Expires (YYYY-MM-DD)</label><input name="expires" placeholder="2025-12-31"></div>
    <div><label>🔌 UDP Port (6000–19999) — မထည့်လည်းရ</label><input name="port" placeholder=""></div>
  </div>
  <button type="submit">Save + Sync</button>
</form>

<table>
  <tr><th>👤 User</th><th>🔑 Password</th><th>⏰ Expires</th><th>🔌 Port</th><th>🔎 Status</th></tr>
  {% for u in users %}
  <tr>
    <td>{{u.user}}</td>
    <td>{{u.password}}</td>
    <td>{{u.expires}}</td>
    <td>{{u.port}}</td>
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

# ---------- helpers ----------
def read_json(path, default):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return default

def write_json_atomic(path, data):
    d = json.dumps(data, ensure_ascii=False, indent=2)
    dirn = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=dirn)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(d)
        os.replace(tmp, path)
    finally:
        try: os.remove(tmp)
        except: pass

def load_users():
    v = read_json(USERS_FILE, [])
    out = []
    for u in v:
        out.append({
            "user": u.get("user",""),
            "password": u.get("password",""),
            "expires": u.get("expires",""),
            "port": str(u.get("port","")) if u.get("port","")!="" else ""
        })
    return out

def save_users(users):
    write_json_atomic(USERS_FILE, users)

def get_listen_port_from_config():
    cfg = read_json(CONFIG_FILE, {})
    listen = str(cfg.get("listen", "")).strip()
    m = re.search(r":(\d+)$", listen) if listen else None
    return (m.group(1) if m else LISTEN_FALLBACK)

def get_udp_listen_ports():
    out = subprocess.run("ss -uHln", shell=True, capture_output=True, text=True).stdout
    return set(re.findall(r":(\d+)\s", out))

def pick_free_port():
    used = {str(u.get("port","")) for u in load_users() if str(u.get("port",""))}
    used |= get_udp_listen_ports()
    for p in range(6000, 20000):
        if str(p) not in used:
            return str(p)
    return ""

# ---- LIVE activity check via conntrack ----
def has_recent_udp_activity(port: str) -> bool:
    if not port:
        return False
    try:
        ext = subprocess.run(
            f"conntrack -L -p udp -o extended 2>/dev/null | grep 'dport={port}\\b'",
            shell=True, capture_output=True, text=True
        ).stdout
        for line in ext.splitlines():
            m = re.search(r'timeout=(\d+)', line)
            if m and int(m.group(1)) >= RECENT_SECONDS // 2:
                return True
        if ext:
            return True
        out = subprocess.run(
            f"conntrack -L -p udp 2>/dev/null | grep 'dport={port}\\b'",
            shell=True, capture_output=True, text=True
        ).stdout
        return bool(out)
    except Exception:
        return False

def status_for_user(u, active_ports, listen_port):
    port = str(u.get("port",""))
    check_port = port if port else listen_port
    if has_recent_udp_activity(check_port):
        return "Online"
    if check_port in active_ports:
        return "Offline" if port else "Online"
    return "Unknown"

def sync_config_passwords():
    cfg = read_json(CONFIG_FILE, {})
    pwlist = []
    if isinstance(cfg.get("auth",{}).get("config", None), list):
        pwlist = list(map(str, cfg["auth"]["config"]))
    users = load_users()
    merged = set(pwlist)
    for u in users:
        if u.get("password"): merged.add(str(u["password"]))
    new_pw = sorted(merged)
    if not isinstance(cfg.get("auth"), dict):
        cfg["auth"] = {}
    cfg["auth"]["mode"] = "passwords"
    cfg["auth"]["config"] = new_pw
    cfg["listen"] = cfg.get("listen") or ":5667"
    cfg["cert"] = cfg.get("cert") or "/etc/zivpn/zivpn.crt"
    cfg["key"]  = cfg.get("key")  or "/etc/zivpn/zivpn.key"
    cfg["obfs"] = cfg.get("obfs") or "zivpn"
    write_json_atomic(CONFIG_FILE, cfg)
    subprocess.run("systemctl restart zivpn.service", shell=True)

def build_view(msg="", err=""):
    users = load_users()
    active = get_udp_listen_ports()
    listen_port = get_listen_port_from_config()
    view = []
    for u in users:
        view.append(type("U", (), {
            "user":u.get("user",""),
            "password":u.get("password",""),
            "expires":u.get("expires",""),
            "port":u.get("port",""),
            "status":status_for_user(u, active, listen_port)
        }))
    view.sort(key=lambda x: (x.user or "").lower())
    return render_template_string(HTML, users=view, msg=msg, err=err)

app = Flask(__name__)

@app.route("/", methods=["GET"])
def index():
    return build_view()

@app.route("/add", methods=["POST"])
def add_user():
    user = (request.form.get("user") or "").strip()
    password = (request.form.get("password") or "").strip()
    expires = (request.form.get("expires") or "").strip()
    port = (request.form.get("port") or "").strip()

    if not user or not password:
        return build_view(err="User နှင့် Password လိုအပ်သည်")

    if expires:
        try: datetime.strptime(expires, "%Y-%m-%d")
        except ValueError:
            return build_view(err="Expires format မမှန်ပါ (YYYY-MM-DD)")

    if port:
        if not re.fullmatch(r"\d{2,5}", port) or not (6000 <= int(port) <= 19999):
            return build_view(err="Port အကွာအဝေး 6000-19999")
    else:
        port = pick_free_port()

    users = load_users()
    replaced = False
    for u in users:
        if u.get("user","").lower() == user.lower():
            u["password"]=password; u["expires"]=expires; u["port"]=port
            replaced=True; break
    if not replaced:
        users.append({"user":user,"password":password,"expires":expires,"port":port})

    save_users(users)
    sync_config_passwords()
    return build_view(msg="Saved & Synced")

@app.route("/api/users", methods=["GET","POST"])
def api_users():
    if request.method == "GET":
        users = load_users()
        active = get_udp_listen_ports()
        listen_port = get_listen_port_from_config()
        for u in users:
            u["status"] = status_for_user(u, active, listen_port)
        return jsonify(users)
    else:
        data = request.get_json(silent=True) or {}
        user = (data.get("user") or "").strip()
        password = (data.get("password") or "").strip()
        expires = (data.get("expires") or "").strip()
        port = str(data.get("port") or "").strip()
        if not user or not password:
            return jsonify({"ok":False, "err":"user/password required"}), 400
        if port and (not re.fullmatch(r"\d{2,5}", port) or not (6000 <= int(port) <= 19999)):
            return jsonify({"ok":False, "err":"invalid port"}), 400
        if not port:
            port = pick_free_port()
        users = load_users()
        replaced=False
        for u in users:
            if u.get("user","").lower() == user.lower():
                u["password"]=password; u["expires"]=expires; u["port"]=port
                replaced=True; break
        if not replaced:
            users.append({"user":user,"password":password,"expires":expires,"port":port})
        save_users(users)
        sync_config_passwords()
        return jsonify({"ok":True})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
PY

# ===== Web systemd unit =====
cat > /etc/systemd/system/zivpn-web.service <<'EOF'
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

# ===== Sanitize CRLF (safety) =====
sed -i 's/\r$//' /etc/systemd/system/zivpn.service /etc/systemd/system/zivpn-web.service /etc/zivpn/web.py 2>/dev/null || true

# ===== Enable services =====
systemctl daemon-reload
systemctl enable --now zivpn.service
systemctl enable --now zivpn-web.service

# ===== Done =====
IP=$(hostname -I | awk '{print $1}')
echo -e "\n$LINE\n${G}✅ အားလုံးပြီးပါပြီ!${Z}"
echo -e "${C}• UDP Server   : ${M}running${Z}"
echo -e "${C}• Web Panel    : ${Y}http://$IP:8080${Z}"
echo -e "${C}• config.json  : ${Y}/etc/zivpn/config.json${Z}"
echo -e "${C}• users.json   : ${Y}/etc/zivpn/users.json${Z}"
echo -e "${C}• Service cmds : ${Y}systemctl status|restart zivpn (or) zivpn-web${Z}"
echo -e "$LINE"
