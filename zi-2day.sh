#!/bin/bash
# ZIVPN UDP Server + Web UI (Myanmar, One-Device Lock + Edit UI)
# Authors: Zahid Islam (udp-zivpn) + UPK tweaks + DEV-U PHOE KAUNT UI polish (+ device lock by bind_ip)
# Features:
#  - apt-guard, packages
#  - ZIVPN binary fetch + config
#  - Flask Web UI (Android-friendly) with:
#      * Total accounts count
#      * Per-user ✏️ Edit page
#      * One-device limit (bind_ip) -> iptables INPUT rules (ACCEPT for bind_ip, DROP for others)
#      * "Lock now"/"Clear" buttons + Auto-Lock from conntrack
#  - UFW/iptables NAT, sysctl forward
#  - systemd services: zivpn.service, zivpn-web.service

set -euo pipefail

B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"
say(){ echo -e "$1"; }

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP Server + Web UI ကို U PHOE KAUNT မှ ပြန်တည်းဖြတ်ပြီးသွင်းနေပါတယ်${Z}\n$LINE"

# ===== Root check =====
if [ "$(id -u)" -ne 0 ]; then echo -e "${R}❌ root လိုပါသည် (sudo -i)${Z}"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive

# =====================================================================
#                (REMOVED) ONE-TIME KEY GATE — no key required
# =====================================================================

# ===== apt guards =====
wait_for_apt() {
  echo -e "${Y}⏳ apt ပိတ်မချင်း စောင့်နေ...${Z}"
  for _ in $(seq 1 60); do
    if pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null || pgrep -f 'apt.systemd.daily' >/dev/null || pgrep -x unattended-upgrade >/dev/null; then
      sleep 5
    else
      return 0
    fi
  done
  echo -e "${Y}⚠️ apt timers ကို ယာယီရပ်...${Z}"
  systemctl stop --now unattended-upgrades.service 2>/dev/null || true
  systemctl stop --now apt-daily.service apt-daily.timer 2>/dev/null || true
  systemctl stop --now apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true
}
apt_guard_start(){ wait_for_apt; CNF_CONF="/etc/apt/apt.conf.d/50command-not-found"; if [ -f "$CNF_CONF" ]; then mv "$CNF_CONF" "${CNF_CONF}.disabled"; CNF_DISABLED=1; else CNF_DISABLED=0; fi; }
apt_guard_end(){
  dpkg --configure -a >/dev/null 2>&1 || true
  apt-get -f install -y >/dev/null 2>&1 || true
  if [ "${CNF_DISABLED:-0}" = "1" ] && [ -f "${CNF_CONF}.disabled" ]; then mv "${CNF_CONF}.disabled" "$CNF_CONF"; fi
}

# ===== Packages =====
say "${Y}📦 Packages တင်နေ...${Z}"
apt_guard_start
apt-get update -y -o APT::Update::Post-Invoke::= >/dev/null
apt-get install -y curl ufw jq python3 python3-flask python3-apt iproute2 conntrack ca-certificates openssl >/dev/null || true
apt_guard_end

# stop old services to avoid text busy
systemctl stop zivpn.service 2>/dev/null || true
systemctl stop zivpn-web.service 2>/dev/null || true

# ===== Paths =====
BIN="/usr/local/bin/zivpn"
CFG="/etc/zivpn/config.json"
USERS="/etc/zivpn/users.json"
ENVF="/etc/zivpn/web.env"
WEB_PY="/etc/zivpn/web.py" # <--- New path for web.py
mkdir -p /etc/zivpn

# ===== Download ZIVPN binary =====
say "${Y}⬇️ ZIVPN binary ဒေါင်းနေ...${Z}"
PRIMARY_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
FALLBACK_URL="https://github.com/zahidbd2/udp-zivpn/releases/latest/download/udp-zivpn-linux-amd64"
TMP_BIN="$(mktemp)"
if ! curl -fsSL -o "$TMP_BIN" "$PRIMARY_URL"; then
  echo -e "${Y}Primary မရ — latest ဆက်စမ်း...${Z}"
  curl -fSL -o "$TMP_BIN" "$FALLBACK_URL"
fi
install -m 0755 "$TMP_BIN" "$BIN"; rm -f "$TMP_BIN"

# ===== Base config =====
if [ ! -f "$CFG" ]; then
  say "${Y}🧩 config.json ဖန်တီးနေ...${Z}"
  curl -fsSL -o "$CFG" "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json" || echo '{}' > "$CFG"
fi

# ===== Certs =====
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  say "${Y}🔐 SSL စိတျဖိုင် ဖန်တီးနေ...${Z}"
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=UPK/OU=Net/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# ===== Web Admin (Login UI credentials) =====
say "${Y}🔒 Web Admin Login UI ထည့်မလား? (လစ်: မဖိတ်)${Z}"
read -r -p "Web Admin Username (Enter=disable): " WEB_USER
if [ -n "${WEB_USER:-}" ]; then
  read -r -s -p "Web Admin Password: " WEB_PASS; echo
  if command -v openssl >/dev/null 2>&1; then WEB_SECRET="$(openssl rand -hex 32)"; else WEB_SECRET="$(python3 - <<'PY'
import secrets;print(secrets.token_hex(32))
PY
)"; fi
  { echo "WEB_ADMIN_USER=${WEB_USER}"; echo "WEB_ADMIN_PASSWORD=${WEB_PASS}"; echo "WEB_SECRET=${WEB_SECRET}"; } > "$ENVF"
  chmod 600 "$ENVF"; say "${G}✅ Web login UI ဖွင့်ထားသည်${Z}"
else
  rm -f "$ENVF" 2>/dev/null || true
  say "${Y}ℹ️ Web login UI မဖွင့်ထားပါ (dev mode)${Z}"
fi

# ===== Ask initial VPN passwords =====
say "${G}🔏 VPN Password List (ကော်မာဖြင့်ခွဲ) eg: upkvip,alice,pass1${Z}"
read -r -p "Passwords (Enter=zi): " input_pw
if [ -z "${input_pw:-}" ]; then PW_LIST='["zi"]'; else
  PW_LIST=$(echo "$input_pw" | awk -F',' '{printf("["); for(i=1;i<=NF;i++){gsub(/^ *| *$/,"",$i); printf("%s\"%s\"", (i>1?",":""), $i)}; printf("]")}'); fi

# ===== Update config.json =====
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

# ===== systemd: ZIVPN =====
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

# ===== Web Panel (Flask + Android UI + One-Device Lock) - Download from URL =====
say "${Y}🖥️ Web Panel (Flask) ဒေါင်းပြီးထည့်နေ...${Z}"
WEB_PY_URL="https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/web.py"
if curl -fsSL -o "$WEB_PY" "$WEB_PY_URL"; then
    say "${G}✅ web.py ကို ${WEB_PY_URL} မှ ဒေါင်းပြီးသိမ်းပြီးပါပြီ။${Z}"
else
    say "${R}❌ web.py ကို ဒေါင်းလုပ်ချရာတွင် အမှားတွေ့ရှိခဲ့ပါသည်။${Z}"
    exit 3
fi
chmod 644 "$WEB_PY"

# ===== Web systemd =====
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

# ===== Networking: forwarding + DNAT + MASQ + UFW =====
echo -e "${Y}🌐 UDP/DNAT + UFW + sysctl ဖွင့်နေ...${Z}"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

IFACE=$(ip -4 route ls | awk '/default/ {print $5; exit}') || true
[ -n "${IFACE:-}" ] || IFACE=eth0
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
iptables -t nat -I PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -I POSTROUTING -o "$IFACE" -j MASQUERADE

ufw allow 5667/udp >/dev/null 2>&1 || true
ufw allow 6000:19999/udp >/dev/null 2>&1 || true
ufw allow 8080/tcp >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true

# ===== CRLF sanitize =====
sed -i 's/\r$//' "$WEB_PY" /etc/systemd/system/zivpn.service /etc/systemd/system/zivpn-web.service || true

# ===== Enable services =====
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
