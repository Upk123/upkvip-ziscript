#!/bin/bash
# ZIVPN UDP Server + Web UI Installer (download web.py from repo)
# - Uses your API server (KEY_API_URL:/api/consume) unchanged
# - Downloads web.py from: https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/web.py
# - Android-friendly UI, per-user Edit, one-device lock (handled inside web.py)
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

# ===== One-Time Key Gate (API UNCHANGED) =====
KEY_API_URL="${KEY_API_URL:-http://43.229.135.219:8088}"   # override via env if you like
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
  echo -ne "${C}Enter one-time key: ${Z}"; read -r -s ONE_TIME_KEY; echo
  [ -z "${ONE_TIME_KEY:-}" ] && { echo -e "${Y}⚠️ key မထည့်ရသေး — ထပ်ထည့်ပါ${Z}"; continue; }
  consume_one_time_key "$ONE_TIME_KEY" && break || echo -ે "${Y}🔁 ထပ်စမ်းပါ${Z}"
done

# ===== apt guard & packages =====
wait_for_apt(){ for _ in $(seq 1 60); do
  if pgrep -x apt >/dev/null || pgrep -x apt-get >/devnull 2>&1 || pgrep -f 'apt.systemd.daily' >/dev/null || pgrep -x unattended-upgrade >/dev/null; then sleep 5; else return 0; fi
done; }
CNF_CONF="/etc/apt/apt.conf.d/50command-not-found"
apt_guard_start(){ wait_for_apt; if [ -f "$CNF_CONF" ]; then mv "$CNF_CONF" "${CNF_CONF}.disabled"; CNF_DISABLED=1; else CNF_DISABLED=0; fi; }
apt_guard_end(){ dpkg --configure -a >/dev/null 2>&1 || true; apt-get -f install -y >/dev/null 2>&1 || true; if [ "${CNF_DISABLED:-0}" = 1 ] && [ -f "${CNF_CONF}.disabled" ]; then mv "${CNF_CONF}.disabled" "$CNF_CONF"; fi; }

say "${Y}📦 Packages တင်နေ...${Z}"
apt_guard_start
apt-get update -y -o APT::Update::Post-Invoke::= >/dev/null
apt-get install -y curl ufw jq python3 python3-flask python3-apt iproute2 conntrack ca-certificates openssl >/dev/null
apt_guard_end

# Stop old services (avoid text busy)
systemctl stop zivpn.service 2>/dev/null || true
systemctl stop zivpn-web.service 2>/dev/null || true

# ===== Paths =====
BIN="/usr/local/bin/zivpn"
CFG="/etc/zivpn/config.json"
USERS="/etc/zivpn/users.json"
ENVF="/etc/zivpn/web.env"
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

# ===== Self-signed certs =====
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  say "${Y}🔐 SSL ဖန်တီးနေ...${Z}"
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=UPK/OU=Net/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# ===== Optional Web Admin auth =====
say "${Y}🔒 Web Admin Login UI ထည့်မလား? (Enter=disable)${Z}"
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

# ===== Initial passwords =====
say "${G}🔏 VPN Password List (ကော်မာဖြင့်ခွဲ) eg: upkvip,alice,pass1${Z}"
read -r -p "Passwords (Enter=zi): " input_pw
if [ -z "${input_pw:-}" ]; then
  PW_LIST='["zi"]'
else
  PW_LIST=$(echo "$input_pw" | awk -F',' '{printf("["); for(i=1;i<=NF;i++){gsub(/^ *| *$/,"",$i); printf("%s\"%s\"", (i>1?",":""), $i)}; printf("]")}')
fi

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

# ===== Web Panel: download web.py from your repo (NO HEREDOC) =====
WEBPY_URL="${WEBPY_URL:-https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/web.py}"
say "${Y}🖥️ web.py ကို repo မှ ယူပြီး သွင်းနေ...${Z}"
if ! curl -fsSL "$WEBPY_URL" -o /etc/zivpn/web.py; then
  echo -e "${R}❌ web.py ဒေါင်းလို့မရ — URL စစ်ပါ: $WEBPY_URL${Z}"; exit 3
fi
chmod 644 /etc/zivpn/web.py

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

# ===== CRLF sanitize & enable =====
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
