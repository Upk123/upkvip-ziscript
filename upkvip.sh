#!/usr/bin/env bash
# upkvip.sh — zivpn UDP installer + password expiry support (simple)
set -euo pipefail

echo "[1/7] Update packages"
sudo apt-get update -y
sudo apt-get install -y jq curl ca-certificates cron

echo "[2/7] Stop old service if exists"
sudo systemctl stop zivpn.service >/dev/null 2>&1 || true

echo "[3/7] Download zivpn binary"
sudo install -Dm755 /dev/stdin /usr/local/bin/zivpn <<'BIN'
$(curl -fsSL https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 | base64 -w0 2>/dev/null || true)
BIN
# Fallback if the inline download failed (e.g., no base64). Use wget quietly.
if ! command -v zivpn >/dev/null 2>&1; then
  sudo wget -q https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
  sudo chmod +x /usr/local/bin/zivpn
fi

echo "[4/7] Prepare /etc/zivpn"
sudo mkdir -p /etc/zivpn /etc/zivpn/backups
sudo wget -q https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json -O /etc/zivpn/config.json

echo "[5/7] Generate TLS cert (1 year)"
sudo openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
  -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn" \
  -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1

echo "[6/7] Systemd service"
sudo tee /etc/systemd/system/zivpn.service >/dev/null <<'EOF'
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
sudo systemctl daemon-reload

# ---------- Passwords with expiry ----------
# users.json format: [{"user":"u1","pass":"p1","expires":"2025-10-31T23:59:59+07:00"}, ...]
USERS_FILE=/etc/zivpn/users.json
if [ ! -f "$USERS_FILE" ]; then
  echo
  echo "[7/7] Setup passwords with expiry"
  read -rp "How many accounts? (default 1): " N; N=${N:-1}
  : > /tmp/users.new.json
  echo "[" >> /tmp/users.new.json
  for i in $(seq 1 "$N"); do
    read -rp "  Username #$i: " U
    read -rp "  Password #$i: " P
    read -rp "  Expiry ISO8601 (e.g. 2025-10-31T23:59:59+07:00): " E
    printf '  {"user":"%s","pass":"%s","expires":"%s"}' "$U" "$P" "$E" >> /tmp/users.new.json
    if [ "$i" -lt "$N" ]; then echo "," >> /tmp/users.new.json; fi
  done
  echo "]" >> /tmp/users.new.json
  sudo mv /tmp/users.new.json "$USERS_FILE"
  sudo chmod 600 "$USERS_FILE"
fi

# Helper that reads users.json, keeps only non-expired, writes passwords to config.json
sudo tee /usr/local/bin/zivpn-update.sh >/dev/null <<'UPD'
#!/usr/bin/env bash
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

# Turn bash array -> JSON array
json_arr=$(printf '%s\n' "${allowed_pw[@]-}" | jq -R -s 'if length==0 then "[]" else split("\n")[:-1] end')

tmp=$(mktemp)
jq --argjson arr "$json_arr" '.auth.config = $arr' "$CONFIG" > "$tmp" && sudo mv "$tmp" "$CONFIG"

# Reload service if active
if systemctl is-enabled --quiet zivpn.service 2>/dev/null; then
  systemctl restart zivpn.service || true
fi
echo "Updated passwords: ${#allowed_pw[@]} active"
UPD
sudo chmod +x /usr/local/bin/zivpn-update.sh

# Run once now
sudo /usr/local/bin/zivpn-update.sh

# NAT + firewall (best effort)
IFACE=$(ip -4 route show default | awk '/default/ {print $5; exit}')
sudo iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 6000:19999/udp || true
  sudo ufw allow 5667/udp || true
fi

# Enable service + hourly refresh via cron
sudo systemctl enable --now zivpn.service
( sudo crontab -l 2>/dev/null | grep -v 'zivpn-update.sh'; echo "0 * * * * /usr/local/bin/zivpn-update.sh >/var/log/zivpn-update.log 2>&1" ) | sudo crontab -

echo "✅ Done. zivpn running. Passwords auto-refresh hourly based on /etc/zivpn/users.json"# replace only the config line in JSON that has "config": [...]
sudo sed -i -E "s/\"config\": *\[[^]]*\]/${new_config_str}/" /etc/zivpn/config.json

# enable & start
sudo systemctl daemon-reload
sudo systemctl enable zivpn.service
sudo systemctl start zivpn.service

# firewall / NAT (best-effort)
IFACE=$(ip -4 route show default | awk '/default/ {print $5; exit}')
sudo iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667

if command -v ufw >/dev/null; then
  sudo ufw allow 6000:19999/udp || true
  sudo ufw allow 5667/udp || true
fi

echo "ZIVPN UDP Installed ✅"
