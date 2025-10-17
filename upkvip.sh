############################################
# [ADD-ON] ZiVPN users with expiry (APPEND)
############################################

# 0) ensure base dirs
mkdir -p /etc/zivpn /etc/zivpn/backups

# 1) users.json မရှိရင် ဖန်တီး (မနဲ့နေတဲ့ sample ၁ခု)
if [ ! -f /etc/zivpn/users.json ]; then
  cat >/etc/zivpn/users.json <<'JSON'
[
  { "user": "demo", "pass": "demo123", "expires": "2025-12-31T23:59:59+07:00" }
]
JSON
  chmod 600 /etc/zivpn/users.json
fi

# 2) updater script — users.json ထဲက expiry မကုန်သေးတဲ့ password တွေကို
#    /etc/zivpn/config.json ရဲ့ "auth.config" ထဲ update လုပ်ပေးမယ်
cat >/usr/local/bin/zivpn-update.sh <<'PYSH'
#!/bin/bash
set -euo pipefail
USERS="/etc/zivpn/users.json"
CONF="/etc/zivpn/config.json"
BACKUP_DIR="/etc/zivpn/backups"
mkdir -p "$BACKUP_DIR"
cp -a "$CONF" "$BACKUP_DIR/config.json.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true

python3 - <<'PY'
import json
from pathlib import Path
from datetime import datetime, timezone

USERS = Path("/etc/zivpn/users.json")
CONF  = Path("/etc/zivpn/config.json")
now = datetime.now(timezone.utc)

def parse_iso(s: str):
    if not s: return None
    s = s.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except Exception:
        return None

# load users
users = []
try:
    users = json.loads(USERS.read_text(encoding="utf-8"))
except Exception:
    users = []

# keep only non-expired passwords
active_passwords = []
for u in users:
    exp = parse_iso(u.get("expires"))
    if exp and exp > now:
        pw = u.get("pass") or ""
        if pw:
            active_passwords.append(pw)

# load config and update auth.config
try:
    data = json.loads(CONF.read_text(encoding="utf-8"))
except Exception:
    data = {}
auth = data.get("auth", {})
auth["mode"] = "passwords"
auth["config"] = active_passwords
data["auth"] = auth
CONF.write_text(json.dumps(data, indent=2), encoding="utf-8")
PY

# service reload (best-effort)
systemctl restart zivpn.service >/dev/null 2>&1 || true
PYSH
chmod +x /usr/local/bin/zivpn-update.sh

# 3) add-user helper — command တစ်ကြောင်းနဲ့ user အသစ် + expiry ထည့်ပြီး update လုပ်မယ်
cat >/usr/local/bin/zivpn-add-user <<'SH'
#!/bin/bash
# Usage: zivpn-add-user <username> <password> <expiry-ISO8601>
# Example: zivpn-add-user upkvip upkvip '2025-11-01T23:59:59+07:00'
set -euo pipefail
if [ $# -lt 3 ]; then
  echo "Usage: $0 <username> <password> <expiry-ISO8601>"
  exit 2
fi
U="$1"; P="$2"; E="$3"
JSON_FILE="/etc/zivpn/users.json"
TMP=$(mktemp)

python3 - <<PY
import json,sys
from pathlib import Path
p=Path("$JSON_FILE")
arr=[]
if p.exists():
    try: arr=json.loads(p.read_text())
    except Exception: arr=[]
arr.append({"user":"$U","pass":"$P","expires":"$E"})
p.write_text(json.dumps(arr,indent=2))
PY

/usr/local/bin/zivpn-update.sh
echo "Added user: $U (expires $E)"
SH
chmod +x /usr/local/bin/zivpn-add-user

# 4) run once now to sync config.json
/usr/local/bin/zivpn-update.sh

# 5) hourly auto-refresh (expired တွေကို အလိုအလျောက် ဖယ်)
( crontab -l 2>/dev/null | grep -v 'zivpn-update.sh'; echo "0 * * * * /usr/local/bin/zivpn-update.sh >/var/log/zivpn-update.log 2>&1" ) | crontab -

echo "✅ Expiry add-on installed. Add users with:  zivpn-add-user <user> <pass> <ISO8601>"
############################################
