#!/bin/bash
# ZIVPN UDP Server + Web UI (Myanmar, One-Device Lock + Public Free Mode)
# Author: U PHOE KAUNT (Free Edition)
# Features:
#   - One-Device Limit
#   - Auto Delete Expired
#   - Public Panel (NO LOGIN / NO KEY)
#   - Ready for Android browser access

set -euo pipefail

B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"
say(){ echo -e "$1"; }

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP Server + Public Web UI ကို U PHOE KAUNT Free Version နဲ့ သွင်းနေပါတယ်${Z}\n$LINE"

# ===== Root check =====
if [ "$(id -u)" -ne 0 ]; then echo -e "${R}❌ root လိုပါတယ် (sudo -i)${Z}"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive

# ===== apt guard =====
wait_for_apt() {
  for _ in $(seq 1 60); do
    if pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null || pgrep -f 'apt.systemd.daily' >/dev/null; then
      sleep 5
    else
      return 0
    fi
  done
  systemctl stop --now unattended-upgrades.service 2>/dev/null || true
  systemctl stop --now apt-daily.service apt-daily.timer 2>/dev/null || true
  systemctl stop --now apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true
}
apt_guard_start(){ wait_for_apt; CNF="/etc/apt/apt.conf.d/50command-not-found"; [ -f "$CNF" ] && mv "$CNF" "${CNF}.disabled" || true; }
apt_guard_end(){ dpkg --configure -a >/dev/null 2>&1 || true; apt-get -f install -y >/dev/null 2>&1 || true; [ -f "${CNF}.disabled" ] && mv "${CNF}.disabled" "$CNF" || true; }

# ===== Packages =====
say "${Y}📦 Packages တင်နေ...${Z}"
apt_guard_start
apt-get update -y -o APT::Update::Post-Invoke::= >/dev/null
apt-get install -y curl ufw jq python3 python3-flask python3-apt iproute2 conntrack ca-certificates openssl >/dev/null
apt_guard_end

# ===== Stop old services =====
systemctl stop zivpn.service 2>/dev/null || true
systemctl stop zivpn-web.service 2>/dev/null || true

# ===== Paths =====
BIN="/usr/local/bin/zivpn"
CFG="/etc/zivpn/config.json"
USERS="/etc/zivpn/users.json"
WEB_PY="/etc/zivpn/web.py"
mkdir -p /etc/zivpn

# ===== Download binary =====
say "${Y}⬇️ ZIVPN binary ဒေါင်းနေ...${Z}"
PRIMARY_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
FALLBACK_URL="https://github.com/zahidbd2/udp-zivpn/releases/latest/download/udp-zivpn-linux-amd64"
TMP="$(mktemp)"
curl -fsSL -o "$TMP" "$PRIMARY_URL" || curl -fSL -o "$TMP" "$FALLBACK_URL"
install -m 0755 "$TMP" "$BIN"; rm -f "$TMP"

# ===== Base config =====
if [ ! -f "$CFG" ]; then
  say "${Y}🧩 config.json ဖန်တီးနေ...${Z}"
  curl -fsSL -o "$CFG" "https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json" || echo '{}' > "$CFG"
fi

# ===== Certs =====
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  say "${Y}🔐 SSL cert ဖန်တီးနေ...${Z}"
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=UPK/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# ===== Web Login Disabled (PUBLIC MODE) =====
rm -f /etc/zivpn/web.env 2>/dev/null || true
say "${Y}🌐 Web Login ကို ဖျက်ပြီးဖြစ်ပါသည် (PUBLIC mode)${Z}"

# ===== VPN Password =====
say "${G}🔏 VPN Passwords (ကော်မာဖြင့်ခွဲ) eg: upk,zi${Z}"
read -r -p "Passwords (Enter=zi): " input_pw
if [ -z "${input_pw:-}" ]; then PW_LIST='["zi"]'; else
  PW_LIST=$(echo "$input_pw" | awk -F',' '{printf("["); for(i=1;i<=NF;i++){gsub(/^ *| *$/,"",$i); printf("%s\"%s\"", (i>1?",":""), $i)}; printf("]")}'); fi

# ===== Update config =====
if jq . >/dev/null 2>&1 <<<'{}'; then
  TMP=$(mktemp)
  jq --argjson pw "$PW_LIST" '
    .auth.mode = "passwords" |
    .auth.config = $pw |
    .listen = (."listen" // ":5667") |
    .cert = "/etc/zivpn/zivpn.crt" |
    .key  = "/etc/zivpn/zivpn.key"
  ' "$CFG" > "$TMP" && mv "$TMP" "$CFG"
fi
[ -f "$USERS" ] || echo "[]" > "$USERS"
chmod 644 "$CFG" "$USERS"

# ===== systemd: ZIVPN =====
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

[Install]
WantedBy=multi-user.target
EOF

# ===== Web Panel =====
say "${Y}🖥️ Web Panel (Flask) ဒေါင်းနေ...${Z}"
WEB_PY_URL="https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/web2day.py"
curl -fsSL -o "$WEB_PY" "$WEB_PY_URL"
chmod 644 "$WEB_PY"

cat >/etc/systemd/system/zivpn-web.service <<'EOF'
[Unit]
Description=ZIVPN Web Panel (Public Free)
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

# ===== NAT + UFW =====
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
IFACE=$(ip route | awk '/default/ {print $5;exit}')
iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -I POSTROUTING -o "$IFACE" -j MASQUERADE
ufw allow 8080/tcp >/dev/null 2>&1 || true
ufw allow 5667/udp >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true

# ===== Start services =====
systemctl daemon-reload
systemctl enable --now zivpn.service
systemctl enable --now zivpn-web.service

IP=$(hostname -I | awk '{print $1}')
echo -e "\n$LINE\n${G}✅ Installation Complete${Z}"
echo -e "${C}Web Panel   :${Z} ${Y}http://$IP:8080${Z}"
echo -e "${C}users.json  :${Z} ${Y}/etc/zivpn/users.json${Z}"
echo -e "${C}config.json :${Z} ${Y}/etc/zivpn/config.json${Z}"
echo -e "${C}Services    :${Z} ${Y}systemctl restart zivpn  •  systemctl restart zivpn-web${Z}"
echo -e "$LINE"
