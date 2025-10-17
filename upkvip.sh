#!/usr/bin/env bash
# Zivpn UDP installer (cleaned)

set -euo pipefail

echo "Updating server"
sudo apt-get update
sudo apt-get upgrade -y

# stop old service if exists (ignore errors)
sudo systemctl stop zivpn.service >/dev/null 2>&1 || true

echo "Downloading UDP Service"
sudo wget -q https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
sudo chmod +x /usr/local/bin/zivpn

# config dir
sudo mkdir -p /etc/zivpn

# base config
sudo wget -q https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json -O /etc/zivpn/config.json

echo "Generating cert files"
sudo openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
  -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn" \
  -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt"

# kernel buffers
sudo sysctl -w net.core.rmem_max=16777216 >/dev/null
sudo sysctl -w net.core.wmem_max=16777216 >/dev/null

# systemd unit
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

# ask passwords (comma-separated)
echo "ZIVPN UDP Passwords"
read -rp "Enter passwords separated by commas (default: zi): " input_config
if [ -n "${input_config:-}" ]; then
  IFS=',' read -r -a config <<<"$input_config"
  # if only one entry, duplicate it
  if [ ${#config[@]} -eq 1 ]; then config+=("${config[0]}"); fi
else
  config=("zi")
fi
new_config_str="\"config\": [$(printf "\"%s\"," "${config[@]}" | sed 's/,$//')]"
# replace only the config line in JSON that has "config": [...]
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

echo "ZIVPN UDP Installed ✅"#!/usr/bin/env bash
# Zivpn UDP installer (cleaned)

set -euo pipefail

echo "Updating server"
sudo apt-get update
sudo apt-get upgrade -y

# stop old service if exists (ignore errors)
sudo systemctl stop zivpn.service >/dev/null 2>&1 || true

echo "Downloading UDP Service"
sudo wget -q https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
sudo chmod +x /usr/local/bin/zivpn

# config dir
sudo mkdir -p /etc/zivpn

# base config
sudo wget -q https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json -O /etc/zivpn/config.json

echo "Generating cert files"
sudo openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
  -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn" \
  -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt"

# kernel buffers
sudo sysctl -w net.core.rmem_max=16777216 >/dev/null
sudo sysctl -w net.core.wmem_max=16777216 >/dev/null

# systemd unit
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

# ask passwords (comma-separated)
echo "ZIVPN UDP Passwords"
read -rp "Enter passwords separated by commas (default: zi): " input_config
if [ -n "${input_config:-}" ]; then
  IFS=',' read -r -a config <<<"$input_config"
  # if only one entry, duplicate it
  if [ ${#config[@]} -eq 1 ]; then config+=("${config[0]}"); fi
else
  config=("zi")
fi
new_config_str="\"config\": [$(printf "\"%s\"," "${config[@]}" | sed 's/,$//')]"
# replace only the config line in JSON that has "config": [...]
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
