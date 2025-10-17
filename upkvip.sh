#!/bin/bash
# Zivpn UDP Module installer (Modified)
# Creator: Zahid Islam | Modified by ChatGPT

echo -e "Updating server"
apt-get update -y && apt-get upgrade -y

systemctl stop zivpn.service 1>/dev/null 2>/dev/null || true

echo -e "Downloading UDP Service"
wget -q https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn

# Create config folder
mkdir -p /etc/zivpn

# Default config.json (if not exists)
if [ ! -f /etc/zivpn/config.json ]; then
  cat <<EOF >/etc/zivpn/config.json
{
  "listen": ":5667",
  "config": ["zi"]
}
EOF
fi

# Default users.json (if not exists)
if [ ! -f /etc/zivpn/users.json ]; then
  echo "[]" >/etc/zivpn/users.json
fi

echo "Generating cert files:"
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
  -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn" \
  -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt"

sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1

# systemd service
cat <<EOF >/etc/systemd/system/zivpn.service
[Unit]
Description=zivpn VPN Server
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

# ---- Add-user helper script ----
cat <<'SH' >/usr/local/bin/add_zivpn_user
#!/usr/bin/env bash
set -e
USER="$1"
PASS="$2"
EXPIRES="${3:-2030-01-01T23:59:59+07:00}"

if [ -z "$USER" ] || [ -z "$PASS" ]; then
  echo "Usage: $0 <username> <password> [expires]"
  exit 2
fi

mkdir -p /etc/zivpn
[ -f /etc/zivpn/users.json ] || echo "[]" >/etc/zivpn/users.json
[ -f /etc/zivpn/config.json ] || echo '{"listen":":5667","config":["zi"]}' >/etc/zivpn/config.json

# Add to users.json
tmp=$(mktemp)
jq --arg u "$USER" --arg p "$PASS" --arg e "$EXPIRES" \
  '(. + [{"user":$u,"pass":$p,"expires":$e}]) | unique_by(.user)' \
  /etc/zivpn/users.json >"$tmp" && mv "$tmp" /etc/zivpn/users.json

# Ensure password inside config.json
tmp=$(mktemp)
jq --arg p "$PASS" 'if (.config // []) | index($p) then . else .config = ((.config // []) + [$p]) end' \
  /etc/zivpn/config.json >"$tmp" && mv "$tmp" /etc/zivpn/config.json

systemctl restart zivpn || true
echo "✅ Added user $USER ($EXPIRES) with pass $PASS"
SH
chmod +x /usr/local/bin/add_zivpn_user
# -------------------------------

systemctl daemon-reload
systemctl enable zivpn.service
systemctl restart zivpn.service

# Firewall / NAT rules
IFC=$(ip -4 route ls|grep default|awk '{print $5}'|head -1)
iptables -t nat -A PREROUTING -i $IFC -p udp --dport 6000:19999 -j DNAT --to-destination :5667
ufw allow 6000:19999/udp
ufw allow 5667/udp

echo -e "🎉 ZIVPN UDP Installed"
echo -e "Use: sudo add_zivpn_user <user> <pass> <expires>"
