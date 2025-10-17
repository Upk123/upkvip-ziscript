#!/bin/bash
# upkvip.sh — ZiVPN UDP Installer + Password expiry support
set -euo pipefail

echo "[1/7] Update packages"
sudo apt-get update -o APT::Update::Post-Invoke-Success='' || true
sudo apt-get install -y jq curl ca-certificates python3-apt || true

echo "[2/7] Stop old service if running"
systemctl stop zivpn.service >/dev/null 2>&1 || true

echo "[3/7] Download zivpn binary"
wget -q https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn

echo "[4/7] Create /etc/zivpn and default config"
mkdir -p /etc/zivpn /etc/zivpn/backups
cat <<EOF > /etc/zivpn/config.json
{
  "listen": ":5667",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": ["zi"]
  }
}
EOF

echo "[5/7] Generate TLS cert"
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
  -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn" \
  -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1

echo "[6/7] Create systemd service"
cat <<EOF > /etc/systemd/system/zivpn.service
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
systemctl daemon-reload

# ---------- Passwords with expiry ----------
USERS_FILE=/etc/zivpn/users.json
if [ ! -f "$USERS_FILE" ]; then
  echo "[7/7] Setup users.json (username / password / expiry)"
  echo "[" > "$USERS_FILE"
  read -rp "How many accounts? " COUNT
  for i in $(seq 1 $COUNT); do
    read -rp "  Username #$i: " U
    read -rp "  Password #$i: " P
    read -rp "  Expiry (e.g. 2025-10-31T23:59:59+07:00): " E
    echo "  {\"user\":\"$U\",\"pass\":\"$P\",\"expires\":\"$E\"}" >> "$USERS_FILE"
    if [ "$i" -lt "$COUNT" ]; then echo "," >> "$USERS_FILE"; fi
  done
  echo "]" >> "$USERS_FILE"
fi

# updater script
cat <<'EOF' > /usr/local/bin/zivpn-update.sh
#!/bin/bash
set -euo pipefail
USERS=/etc/zivpn/users.json
CONFIG=/etc/zivpn/config.json
BACKUP_DIR=/etc/zivpn/backups
mkdir -p "$BACKUP_DIR"
cp -a "$CONFIG" "$BACKUP_DIR/config.json.$(date -u +%Y%m%dT%H%M%SZ)" || true

now=$(date -u +%s)
mapfile -t rows < <(jq -r '.[] | "\(.user)|\(.pass)|\(.expires)"' "$USERS")

allowed_pw=()
for r in "${rows[@]}"; do
  IFS='|' read -r u p exp <<<"$r"
  exp_epoch=$(date -d "$exp" +%s 2>/dev/null || echo 0)
  if [ "$exp_epoch" -gt "$now" ]; then
    allowed_pw+=("$p")
  fi
done

json_arr=$(printf '%s\n' "${allowed_pw[@]-}" | jq -R -s 'if length==0 then "[]" else split("\n")[:-1] end')
tmp=$(mktemp)
jq --argjson arr "$json_arr" '.auth.config = $arr' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart zivpn.service || true
echo "Updated passwords: ${#allowed_pw[@]} active"
EOF
chmod +x /usr/local/bin/zivpn-update.sh

# Run update once
/usr/local/bin/zivpn-update.sh

# firewall / nat rules
IFACE=$(ip -4 route show default | awk '/default/ {print $5; exit}')
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 || true
ufw allow 6000:19999/udp || true
ufw allow 5667/udp || true

# enable service + cron
systemctl enable --now zivpn.service
( crontab -l 2>/dev/null | grep -v 'zivpn-update.sh'; echo "0 * * * * /usr/local/bin/zivpn-update.sh >/var/log/zivpn-update.log 2>&1" ) | crontab -

echo "✅ Installation finished. Users in $USERS_FILE, auto-refresh hourly."
