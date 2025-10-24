#!/bin/bash
# ZIVPN UDP Server Installation Script (Modified by Gemini AI - API Check Reinstated)

# --- CONFIGURATION ---
PYTHON_APP_PATH="/etc/zivpn/web.py"
ENV_FILE="/etc/zivpn/web.env"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/zivpn-web.service"
# Original API endpoint
API_SERVER="http://43.229.135.219:8088"
# ---------------------

echo "--- ZIVPN Server Setup ---"

# 1. Install Dependencies
if ! command -v python3 &> /dev/null || ! command -v pip3 &> /dev/null; then
    echo "Installing Python and required packages..."
    apt update
    apt install -y python3 python3-pip curl netfilter-persistent
fi
pip3 install flask

# 2. Check and Apply One-Time Key Logic (REINSTATED)
echo ""
echo "--- One-Time Key Check ---"
read -p "Please Enter One-Time Key: " KEY_INPUT
KEY_INPUT=$(echo "$KEY_INPUT" | tr -d '[:space:]')
SERVER_IP=$(curl -s ifconfig.me)

if [ -z "$KEY_INPUT" ]; then
    echo "Error: Key cannot be empty."
    exit 1
fi

echo "Checking Key with API Server..."
API_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"key\": \"$KEY_INPUT\", \"ip\": \"$SERVER_IP\"}" "$API_SERVER/usekey")
STATUS=$(echo "$API_RESPONSE" | grep -o '"status":"[^"]*"' | cut -d':' -f2 | tr -d '"')
MESSAGE=$(echo "$API_RESPONSE" | grep -o '"message":"[^"]*"' | cut -d':' -f2 | tr -d '"')

if [ "$STATUS" == "success" ]; then
    echo "Key successfully authorized! Message: $MESSAGE"
else
    echo "Error: Key authorization failed. Status: $STATUS, Message: $MESSAGE"
    exit 1
fi

# 3. Get Admin Credentials
echo ""
echo "--- Web Admin Panel Setup ---"
read -p "Enter new Admin Username: " ADMIN_USER
read -s -p "Enter new Admin Password: " ADMIN_PASS
echo ""

# Save credentials to ENV file (chmod 600 ensures only root can read)
mkdir -p /etc/zivpn
echo "ADMIN_USER='${ADMIN_USER}'" > "$ENV_FILE"
echo "ADMIN_PASS='${ADMIN_PASS}'" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "Admin credentials saved to ${ENV_FILE}"

# 4. Create the New web.py (Python Flask App)
# The web.py content is the same as the previous response (with improved UI and features)
cat << 'EOF_PYTHON' > "$PYTHON_APP_PATH"
# /etc/zivpn/web.py (Modified by Gemini AI for enhanced UI and features)
from flask import Flask, request, redirect, url_for, render_template_string
from datetime import datetime, timedelta
import json, os, hashlib, subprocess, re, time

# --- Configuration & Files ---
CONFIG_FILE = "/etc/zivpn/config.json"
USERS_FILE = "/etc/zivpn/users.json"
ENV_FILE = "/etc/zivpn/web.env"
LOGO_URL = "https://example.com/logo.png" # Replace with your logo URL
IPTABLES_CHAIN = "ZIVPN_LIMIT"

app = Flask(__name__)

# --- Utility Functions ---

def load_env():
    env = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.strip().split('=', 1)
                    env[key] = value.strip("'\"")
    return env

def load_users():
    if not os.path.exists(USERS_FILE): return []
    try:
        with open(USERS_FILE, 'r') as f:
            return json.load(f)
    except:
        return []

def save_users(users):
    write_json_atomic(USERS_FILE, users)

def write_json_atomic(filename, data):
    """Write JSON data to a file safely using a temporary file."""
    temp_filename = filename + ".tmp"
    with open(temp_filename, 'w') as f:
        json.dump(data, f, indent=2)
    os.rename(temp_filename, filename)

def pick_free_port():
    users = load_users()
    used_ports = {int(u["port"]) for u in users if u.get("port", "").isdigit()}
    for port in range(6000, 20000):
        if port not in used_ports:
            return str(port)
    return "auto" # Fallback, should not happen

def hash_pass(p):
    return hashlib.sha256(p.encode()).hexdigest()

def require_login():
    env = load_env()
    admin_user = env.get("ADMIN_USER")
    admin_pass_hash = hash_pass(env.get("ADMIN_PASS", ""))
    
    auth_header = request.headers.get("Authorization")
    if auth_header and auth_header.startswith("Basic "):
        try:
            auth_decoded = base64.b64decode(auth_header.split(" ")[1]).decode()
            user, password = auth_decoded.split(':', 1)
            if user == admin_user and hash_pass(password) == admin_pass_hash:
                return True
        except:
            pass
            
    if request.form.get("user") == admin_user and hash_pass(request.form.get("password", "")) == admin_pass_hash:
        # Successful login via form, set a basic session/cookie for simplicity (optional, for stateless just use Basic Auth)
        # Using a simple redirect and check for simplicity in this script's context
        return True 

    # For simplicity in this script, we rely on the redirect back to login and re-submission of form
    return False

def check_login():
    env = load_env()
    admin_user = env.get("ADMIN_USER")
    admin_pass_hash = hash_pass(env.get("ADMIN_PASS", ""))
    
    if request.form.get("user") == admin_user and hash_pass(request.form.get("password", "")) == admin_pass_hash:
        return True
    return False

# --- IPTABLES (Connection Limit) Sync ---
def sync_conn_limits():
    """Applies iptables rules to limit connections to 1 per source IP per port."""
    
    # 1. ZIVPN_LIMIT Chain ကို ပြန်လည်စတင်ခြင်း (အဟောင်းတွေကို ရှင်းပစ်၊ အသစ်ဖန်တီး)
    subprocess.run(f"iptables -t filter -F {IPTABLES_CHAIN} 2>/dev/null || true", shell=True)
    subprocess.run(f"iptables -t filter -X {IPTABLES_CHAIN} 2>/dev/null || true", shell=True)
    subprocess.run(f"iptables -t filter -N {IPTABLES_CHAIN}", shell=True)

    # 2. INPUT chain ထဲမှာ ZIVPN_LIMIT ကို ခေါ်ဖို့ rule ထည့် (ရှိပြီးသားဆို ထပ်မထည့်ရ)
    subprocess.run(f"iptables -t filter -C INPUT -p udp --dport 6000:19999 -j {IPTABLES_CHAIN} 2>/dev/null || "
                   f"iptables -t filter -A INPUT -p udp --dport 6000:19999 -j {IPTABLES_CHAIN}", shell=True)
    
    users = load_users()
    LIMIT_COUNT = 1 # 1 Connection per IP
    
    # 3. User တစ်ဦးချင်းစီအတွက် Connection Limit Rule များကို ထည့်
    for u in users:
      port = str(u.get("port", "")).strip()
      if port and port.isdigit() and 6000 <= int(port) <= 19999:
          rule = (f"iptables -t filter -A {IPTABLES_CHAIN} -p udp --dport {port} "
                  f"-m connlimit --connlimit-above {LIMIT_COUNT} --connlimit-mask 32 -j DROP")
          subprocess.run(rule, shell=True)

    # 4. ကျန်တဲ့ traffic တွေကို လက်ခံဖို့
    subprocess.run(f"iptables -t filter -A {IPTABLES_CHAIN} -j ACCEPT", shell=True)
    
    # 5. Save iptables rules permanently
    subprocess.run("netfilter-persistent save", shell=True)


def sync_config_passwords(mode="mirror"):
    """Reads user list and updates the ZIVPN main config."""
    users = load_users()
    # Check if config file exists and load it, otherwise create a new structure
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            cfg = json.load(f)
    else:
        cfg = {"mode": "mirror", "configs": {}}
        
    cfg["configs"] = {}
    for u in users:
        # Note: Expires is for display only, the main ZIVPN logic handles it based on its own internal check
        cfg["configs"][u["user"]] = u["password"]

    write_json_atomic(CONFIG_FILE, cfg)
    
    # After saving user config, sync the iptables connection limits
    sync_conn_limits()
    
    # Restart ZIVPN service to apply changes
    subprocess.run("systemctl restart zivpn.service", shell=True)


# --- HTML Templates (Single String for portability) ---
HTML = """
<!DOCTYPE html>
<html lang="my">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZIVPN Admin Panel</title>
    <style>
        :root {
            --primary-color: #007bff;
            --secondary-color: #6c757d;
            --success-color: #28a745;
            --danger-color: #dc3545;
            --bg-color: #f4f7f6;
            --card-bg: #ffffff;
            --text-color: #333;
        }
        body { font-family: 'Arial', sans-serif; background-color: var(--bg-color); color: var(--text-color); margin: 0; padding: 0; }
        .container { max-width: 1000px; margin: 20px auto; padding: 0 15px; }
        header { background-color: var(--card-bg); padding: 10px 15px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1); display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; }
        .header-info { flex: 1 1 50%; display: flex; align-items: center; }
        .header-info img { height: 50px; margin-right: 15px; border-radius: 4px; }
        .header-info h1 { font-size: 1.5em; margin: 0; color: var(--primary-color); }
        .header-info .sub { font-size: 0.9em; color: var(--secondary-color); margin-top: 5px; }
        .header-actions { flex: 1 1 auto; text-align: right; }

        /* Forms and Boxes */
        .box { background-color: var(--card-bg); padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0, 0, 0, 0.05); margin-bottom: 20px; }
        .box h3 { border-bottom: 2px solid var(--primary-color); padding-bottom: 10px; margin-top: 0; color: var(--primary-color); }
        .row { display: flex; gap: 10px; margin-bottom: 10px; flex-wrap: wrap; }
        .row > div { flex: 1; min-width: 150px; }
        label { display: block; font-weight: bold; margin-bottom: 5px; font-size: 0.9em; }
        input[type="text"], input[type="password"] { width: 100%; padding: 10px; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; }
        
        /* Buttons */
        .btn { padding: 10px 15px; border: none; border-radius: 4px; cursor: pointer; text-decoration: none; font-weight: bold; transition: background-color 0.3s; display: inline-block; text-align: center;}
        .btn-primary { background-color: var(--primary-color); color: white; }
        .btn-primary:hover { background-color: #0056b3; }
        .btn-success { background-color: var(--success-color); color: white; }
        .btn-success:hover { background-color: #1e7e34; }
        .btn-danger { background-color: var(--danger-color); color: white; }
        .btn-danger:hover { background-color: #bd2130; }
        .btn-secondary { background-color: var(--secondary-color); color: white; }
        .btn-secondary:hover { background-color: #5a6268; }

        /* Messages */
        .msg, .err { padding: 10px; border-radius: 4px; margin-bottom: 15px; font-weight: bold; }
        .msg { background-color: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .err { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
        
        /* Table */
        table { width: 100%; border-collapse: collapse; margin-top: 20px; background-color: var(--card-bg); border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0, 0, 0, 0.05); }
        th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #eee; font-size: 0.95em; }
        th { background-color: var(--primary-color); color: white; font-weight: 600; }
        tr:hover { background-color: #f8f9fa; }
        .expired { background-color: #fff0f0 !important; color: var(--danger-color); font-weight: bold;}
        .expired td { border-left: 5px solid var(--danger-color); }
        
        /* Action buttons in table */
        td .actions { display: flex; gap: 5px; }
        td .actions button, td .actions a { font-size: 0.8em; padding: 6px 8px; }
        td .actions form { margin: 0; display: inline; }
        
        /* Responsive Table (for small screens) */
        @media screen and (max-width: 600px) {
            header { flex-direction: column; align-items: flex-start; }
            .header-actions { margin-top: 10px; text-align: left; }
            .row { flex-direction: column; gap: 0; }
            .row > div { margin-bottom: 10px; }

            /* Make table columns stack */
            table, thead, tbody, th, td, tr { display: block; }
            thead tr { position: absolute; top: -9999px; left: -9999px; } /* Hide table headers */
            tr { border: 1px solid #ccc; margin-bottom: 15px; border-radius: 8px;}
            td { border: none; border-bottom: 1px solid #eee; position: relative; padding-left: 50%; text-align: right; }
            td:before { 
                position: absolute; 
                top: 6px; 
                left: 6px; 
                width: 45%; 
                padding-right: 10px; 
                white-space: nowrap;
                text-align: left; 
                font-weight: bold;
                color: var(--primary-color);
            }
            td:nth-of-type(1):before { content: "👤 User"; }
            td:nth-of-type(2):before { content: "🔑 Password"; }
            td:nth-of-type(3):before { content: "⏰ Expires"; }
            td:nth-of-type(4):before { content: "🔌 Port"; }
            td:nth-of-type(5):before { content: "⚙️ Manage"; border-bottom: none;}
            td .actions { justify-content: flex-end; }
        }
    </style>
</head>
<body>
<div class="container">
    <header>
        <div class="header-info">
            <div>
                <h1>ZIVPN Admin Panel</h1>
                <div class="sub">👥 Total Users: <strong>{{ user_count }}</strong> | Today: {{ today }}</div>
            </div>
        </div>
        <div class="header-actions">
            <form method="post" action="/logout">
                <button class="btn btn-secondary" type="submit">Logout</button>
            </form>
        </div>
    </header>

    {% if msg %}<div class="msg">{{msg}}</div>{% endif %}
    {% if err %}<div class="err">{{err}}</div>{% endif %}

    <div class="box">
        <h3>➕ အသုံးပြုသူအသစ် ထည့်သွင်းရန်</h3>
        <form method="post" action="/add">
            <div class="row">
                <div><label>👤 User</label><input name="user" required></div>
                <div><label>🔑 Password</label><input name="password" required></div>
                <div><label>⏰ Expires (YYYY-MM-DD or Days)</label><input name="expires" placeholder="2025-12-31 or 30"></div>
                <div><label>🔌 UDP Port (6000–19999)</label><input name="port" placeholder="auto"></div>
            </div>
            <button class="btn btn-success" type="submit">Add User + Sync</button>
        </form>
    </div>

    <div class="box">
        <h3>📋 အသုံးပြုသူ စာရင်း</h3>
        <table>
            <thead>
                <tr>
                    <th>👤 User</th>
                    <th>🔑 Password</th>
                    <th>⏰ Expires</th>
                    <th>🔌 Port</th>
                    <th>⚙️ Manage</th>
                </tr>
            </thead>
            <tbody>
                {% for u in users %}
                <tr class="{% if u.expires and u.expires < today %}expired{% endif %}">
                    <td>{{ u.user }}</td>
                    <td>{{ u.password }}</td>
                    <td>{{ u.expires if u.expires else "N/A" }}</td>
                    <td>{{ u.port if u.port else "N/A" }}</td>
                    <td>
                        <div class="actions">
                            <a class="btn btn-primary" href="/edit/{{ u.user }}">Edit</a> 
                            <form method="post" action="/delete" onsubmit="return confirm('User: {{ u.user }} ကို ဖျက်မလား? ပြန်ပြင်လို့မရပါ');">
                                <input type="hidden" name="user" value="{{u.user}}">
                                <button type="submit" class="btn btn-danger">Delete</button>
                            </form>
                        </div>
                    </td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
    </div>
</div>
</body>
</html>
"""

# --- Edit Template (Simple version, uses the same style) ---
EDIT_HTML = """
<div class="container">
    <header>
        <a href="/" class="btn btn-secondary" style="margin-right: 15px;">&larr; Back to Users</a>
        <div class="header-info">
            <div><h1>ZIVPN Admin Panel</h1></div>
        </div>
    </header>

    {% if msg %}<div class="msg">{{msg}}</div>{% endif %}
    {% if err %}<div class="err">{{err}}</div>{% endif %}

    <div class="box">
      <h3>✏️ အသုံးပြုသူ အချက်အလက် ပြန်ပြင်ရန်: {{ current_user.user }}</h3>
      <form method="post" action="/update">
        <input type="hidden" name="old_user" value="{{ current_user.user }}">
        <div class="row">
          <div><label>👤 User</label><input name="user" required value="{{ current_user.user }}"></div>
          <div><label>🔑 Password</label><input name="password" required value="{{ current_user.password }}"></div>
        </div>
        <div class="row">
          <div><label>⏰ Expires (YYYY-MM-DD or days)</label><input name="expires" placeholder="2025-12-31 or 30" value="{{ current_user.expires if current_user.expires else '' }}"></div>
          <div><label>🔌 UDP Port (6000–19999)</label><input name="port" placeholder="auto" value="{{ current_user.port if current_user.port else '' }}"></div>
        </div>
        <button class="btn btn-primary" type="submit">Save Changes + Sync</button>
      </form>
    </div>
</div>
"""

# --- Flask Routes ---

@app.route("/", methods=["GET"])
def index():
    if not check_login():
        return redirect(url_for('login'))
    return build_view()

@app.route("/", methods=["POST"])
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if check_login():
            return redirect(url_for('index'))
        return render_template_string(LOGIN_HTML, err="Invalid Username or Password")
    
    # Login HTML (Basic)
    LOGIN_HTML = """
    <!DOCTYPE html>
    <html lang="my">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Login</title>
        <style>
            body { font-family: 'Arial', sans-serif; background-color: #f4f7f6; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
            .login-box { background-color: #fff; padding: 40px; border-radius: 8px; box-shadow: 0 4px 10px rgba(0, 0, 0, 0.1); width: 300px; text-align: center; }
            .login-box h2 { color: #007bff; margin-bottom: 25px; }
            input { width: 100%; padding: 10px; margin-bottom: 15px; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; }
            button { width: 100%; padding: 10px; border: none; border-radius: 4px; background-color: #007bff; color: white; cursor: pointer; font-weight: bold; }
            .err { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; padding: 10px; border-radius: 4px; margin-bottom: 15px; font-weight: bold; font-size: 0.9em;}
        </style>
    </head>
    <body>
        <div class="login-box">
            <h2>Admin Login</h2>
            {% if err %}<div class="err">{{err}}</div>{% endif %}
            <form method="post" action="/login">
                <input type="text" name="user" placeholder="Username" required>
                <input type="password" name="password" placeholder="Password" required>
                <button type="submit">Login</button>
            </form>
        </div>
    </body>
    </html>
    """
    return render_template_string(LOGIN_HTML)

@app.route("/logout", methods=["POST"])
def logout():
    # Simple logout: redirect to login without setting auth headers
    return redirect(url_for('login'))

@app.route("/add", methods=["POST"])
def add_user():
    if not check_login(): return redirect(url_for('login', err="Please login again."))
    
    user=(request.form.get("user") or "").strip()
    password=(request.form.get("password") or "").strip()
    expires=(request.form.get("expires") or "").strip()
    port=(request.form.get("port") or "").strip()

    if expires.isdigit():
        expires=(datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")

    if not user or not password:
        return build_view(err="User နှင့် Password လိုအပ်သည်")
    
    if expires:
        try: datetime.strptime(expires,"%Y-%m-%d")
        except ValueError:
            return build_view(err="Expires format မမှန်ပါ (YYYY-MM-DD)")
    
    # Port validation and auto-assign
    if port:
        if not port.isdigit() or not (6000 <= int(port) <= 19999):
            return build_view(err="Port အကွာအဝေး 6000-19999 သို့မဟုတ် 'auto' ဖြစ်ရမည်")
    else:
        port=pick_free_port()

    users=load_users()
    # Check if user already exists (case-insensitive)
    for u in users:
        if u.get("user", "").lower() == user.lower():
            return build_view(err=f"User '{user}' ရှိပြီးသားဖြစ်သည်. Edit ကိုသုံးပါ")

    users.append({"user":user,"password":password,"expires":expires,"port":port})
    save_users(users); sync_config_passwords()
    return build_view(msg=f"User '{user}' successfully added and Synced")


@app.route("/delete", methods=["POST"])
def del_user():
    if not check_login(): return redirect(url_for('login', err="Please login again."))
    user=(request.form.get("user") or "").strip()
    if not user:
        return build_view(err="User name မပါဝင်ပါ")

    users=load_users()
    original_count = len(users)
    users = [u for u in users if (u.get("user","").lower() != user.lower())]
    
    if len(users) == original_count:
        return build_view(err=f"User '{user}' ကို ရှာမတွေ့ပါ")
    
    save_users(users); sync_config_passwords()
    return build_view(msg=f"User '{user}' successfully deleted and Synced")


@app.route("/edit/<user_name>", methods=["GET"])
def edit_user(user_name):
    if not check_login(): return redirect(url_for('login', err="Please login again."))
    
    users = load_users()
    current_user = next((u for u in users if u.get("user", "").lower() == user_name.lower()), None)
    
    if not current_user:
        return build_view(err=f"User '{user_name}' not found.")

    # Convert dict to simple object for easy template access
    class UserObject:
        def __init__(self, data):
            self.__dict__.update(data)
    u_obj = UserObject(current_user)
    
    return render_template_string(HTML.split('</style>')[0] + '</style></head><body>' + EDIT_HTML, 
                                  current_user=u_obj, logo=LOGO_URL)


@app.route("/update", methods=["POST"])
def update_user():
    if not check_login(): return redirect(url_for('login', err="Please login again."))
    
    old_user = (request.form.get("old_user") or "").strip()
    user=(request.form.get("user") or "").strip()
    password=(request.form.get("password") or "").strip()
    expires=(request.form.get("expires") or "").strip()
    port=(request.form.get("port") or "").strip()

    if expires.isdigit():
        expires=(datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")

    if not user or not password:
        return build_view(err="User နှင့် Password လိုအပ်သည်")
    if expires:
        try: datetime.strptime(expires,"%Y-%m-%d")
        except ValueError:
          return build_view(err="Expires format မမှန်ပါ (YYYY-MM-DD)")
    
    # Port validation
    if port:
        if not port.isdigit() or not (6000 <= int(port) <= 19999):
            return build_view(err="Port အကွာအဝေး 6000-19999 သို့မဟုတ် 'auto' ဖြစ်ရမည်")
    else:
        port=pick_free_port()

    users=load_users(); 
    # Old user ကို ဖျက်ပြီး update လုပ်မယ့် user name အသစ်နဲ့ အတူတူဆိုရင် edit လုပ်ခွင့်ပေးပါ
    users = [u for u in users if (u.get("user","").lower() != old_user.lower())]

    # Check if the NEW username already exists after removing OLD (if username was changed)
    for u in users:
        if u.get("user", "").lower() == user.lower():
            # Old user ကို ဖျက်ပစ်ပြီးသားမို့၊ ဒီနေရာမှာတွေ့ရင် တခြားသူဖြစ်နေမှာ
            return build_view(err=f"User '{user}' ရှိပြီးသားဖြစ်သည်. ကျေးဇူးပြု၍ တခြား နာမည်ပေးပါ")

    # Add the updated data
    users.append({"user":user,"password":password,"expires":expires,"port":port})
    
    save_users(users); sync_config_passwords()
    return build_view(msg=f"User '{old_user}' ကို '{user}' အဖြစ် အချက်အလက် ပြန်ပြင်ပြီး Synced လုပ်ပြီးပါပြီ")


def build_view(msg="", err=""):
    """Main view builder to show user list and counts."""
    users = load_users()
    
    # Sort users by expiration date (expired first)
    def sort_key(u):
        exp = u.get("expires", "9999-12-31")
        return (exp == "9999-12-31", exp) # Non-expiring users go last

    users.sort(key=sort_key)
    
    # Prepare data for template
    today = datetime.now().strftime("%Y-%m-%d")
    user_count = len(users)

    return render_template_string(HTML, 
                                  logo=LOGO_URL, 
                                  users=users, 
                                  msg=msg, 
                                  err=err, 
                                  today=today, 
                                  user_count=user_count)


if __name__ == '__main__':
    # Flask runs on port 8080 by default (as per original script logic)
    # The systemd service will handle running it with the correct config
    # app.run(host='0.0.0.0', port=8080)
    pass
EOF_PYTHON

# 5. Create/Update Systemd Service File
# (Service file remains the same, running web.py as root for iptables)
cat << EOF_SERVICE > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=ZIVPN Web Admin Panel
After=network.target

[Service]
# WARNING: Running as root is required for iptables (connlimit) in web.py
# For production use, consider using a non-root user and granting NET_ADMIN capabilities.
User=root
Group=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/bin/python3 ${PYTHON_APP_PATH}
Restart=always
EnvironmentFile=${ENV_FILE}

[Install]
WantedBy=multi-user.target
EOF_SERVICE

# 6. Apply Changes and Enable Service
echo "Enabling and starting ZIVPN Web Service..."
systemctl daemon-reload
systemctl enable zivpn-web.service
systemctl restart zivpn-web.service

# 7. Configure Firewall (UFW)
echo "Configuring UFW firewall for Web Panel (8080/tcp) and VPN Ports (5667/udp, 6000-19999/udp)..."
ufw allow 8080/tcp
ufw allow 5667/udp
ufw allow 6000:19999/udp
ufw enable

# 8. Initial Sync to apply iptables connection limits
echo "Performing initial sync to set connection limits and ZIVPN config..."
python3 -c "from web import sync_config_passwords; sync_config_passwords()"

echo "--- Setup Complete! ---"
echo "Web Admin Panel URL: http://<Your_Server_IP>:8080"
echo "Login with the credentials you provided."
      port = str(u.get("port", "")).strip()
      if port and port.isdigit() and 6000 <= int(port) <= 19999:
          rule = (f"iptables -t filter -A {IPTABLES_CHAIN} -p udp --dport {port} "
                  f"-m connlimit --connlimit-above {LIMIT_COUNT} --connlimit-mask 32 -j DROP")
          subprocess.run(rule, shell=True)

    # 4. ကျန်တဲ့ traffic တွေကို လက်ခံဖို့
    subprocess.run(f"iptables -t filter -A {IPTABLES_CHAIN} -j ACCEPT", shell=True)
    
    # 5. Save iptables rules permanently
    subprocess.run("netfilter-persistent save", shell=True)


def sync_config_passwords(mode="mirror"):
    """Reads user list and updates the ZIVPN main config."""
    users = load_users()
    # Check if config file exists and load it, otherwise create a new structure
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            cfg = json.load(f)
    else:
        cfg = {"mode": "mirror", "configs": {}}
        
    cfg["configs"] = {}
    for u in users:
        # Note: Expires is for display only, the main ZIVPN logic handles it based on its own internal check
        cfg["configs"][u["user"]] = u["password"]

    write_json_atomic(CONFIG_FILE, cfg)
    
    # After saving user config, sync the iptables connection limits
    sync_conn_limits()
    
    # Restart ZIVPN service to apply changes
    subprocess.run("systemctl restart zivpn.service", shell=True)


# --- HTML Templates (Single String for portability) ---
HTML = """
<!DOCTYPE html>
<html lang="my">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ZIVPN Admin Panel</title>
    <style>
        :root {
            --primary-color: #007bff;
            --secondary-color: #6c757d;
            --success-color: #28a745;
            --danger-color: #dc3545;
            --bg-color: #f4f7f6;
            --card-bg: #ffffff;
            --text-color: #333;
        }
        body { font-family: 'Arial', sans-serif; background-color: var(--bg-color); color: var(--text-color); margin: 0; padding: 0; }
        .container { max-width: 1000px; margin: 20px auto; padding: 0 15px; }
        header { background-color: var(--card-bg); padding: 10px 15px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1); display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; }
        .header-info { flex: 1 1 50%; display: flex; align-items: center; }
        .header-info img { height: 50px; margin-right: 15px; border-radius: 4px; }
        .header-info h1 { font-size: 1.5em; margin: 0; color: var(--primary-color); }
        .header-info .sub { font-size: 0.9em; color: var(--secondary-color); margin-top: 5px; }
        .header-actions { flex: 1 1 auto; text-align: right; }

        /* Forms and Boxes */
        .box { background-color: var(--card-bg); padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0, 0, 0, 0.05); margin-bottom: 20px; }
        .box h3 { border-bottom: 2px solid var(--primary-color); padding-bottom: 10px; margin-top: 0; color: var(--primary-color); }
        .row { display: flex; gap: 10px; margin-bottom: 10px; flex-wrap: wrap; }
        .row > div { flex: 1; min-width: 150px; }
        label { display: block; font-weight: bold; margin-bottom: 5px; font-size: 0.9em; }
        input[type="text"], input[type="password"] { width: 100%; padding: 10px; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; }
        
        /* Buttons */
        .btn { padding: 10px 15px; border: none; border-radius: 4px; cursor: pointer; text-decoration: none; font-weight: bold; transition: background-color 0.3s; display: inline-block; text-align: center;}
        .btn-primary { background-color: var(--primary-color); color: white; }
        .btn-primary:hover { background-color: #0056b3; }
        .btn-success { background-color: var(--success-color); color: white; }
        .btn-success:hover { background-color: #1e7e34; }
        .btn-danger { background-color: var(--danger-color); color: white; }
        .btn-danger:hover { background-color: #bd2130; }
        .btn-secondary { background-color: var(--secondary-color); color: white; }
        .btn-secondary:hover { background-color: #5a6268; }

        /* Messages */
        .msg, .err { padding: 10px; border-radius: 4px; margin-bottom: 15px; font-weight: bold; }
        .msg { background-color: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .err { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
        
        /* Table */
        table { width: 100%; border-collapse: collapse; margin-top: 20px; background-color: var(--card-bg); border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0, 0, 0, 0.05); }
        th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #eee; font-size: 0.95em; }
        th { background-color: var(--primary-color); color: white; font-weight: 600; }
        tr:hover { background-color: #f8f9fa; }
        .expired { background-color: #fff0f0 !important; color: var(--danger-color); font-weight: bold;}
        .expired td { border-left: 5px solid var(--danger-color); }
        
        /* Action buttons in table */
        td .actions { display: flex; gap: 5px; }
        td .actions button, td .actions a { font-size: 0.8em; padding: 6px 8px; }
        td .actions form { margin: 0; display: inline; }
        
        /* Responsive Table (for small screens) */
        @media screen and (max-width: 600px) {
            header { flex-direction: column; align-items: flex-start; }
            .header-actions { margin-top: 10px; text-align: left; }
            .row { flex-direction: column; gap: 0; }
            .row > div { margin-bottom: 10px; }

            /* Make table columns stack */
            table, thead, tbody, th, td, tr { display: block; }
            thead tr { position: absolute; top: -9999px; left: -9999px; } /* Hide table headers */
            tr { border: 1px solid #ccc; margin-bottom: 15px; border-radius: 8px;}
            td { border: none; border-bottom: 1px solid #eee; position: relative; padding-left: 50%; text-align: right; }
            td:before { 
                position: absolute; 
                top: 6px; 
                left: 6px; 
                width: 45%; 
                padding-right: 10px; 
                white-space: nowrap;
                text-align: left; 
                font-weight: bold;
                color: var(--primary-color);
            }
            td:nth-of-type(1):before { content: "👤 User"; }
            td:nth-of-type(2):before { content: "🔑 Password"; }
            td:nth-of-type(3):before { content: "⏰ Expires"; }
            td:nth-of-type(4):before { content: "🔌 Port"; }
            td:nth-of-type(5):before { content: "⚙️ Manage"; border-bottom: none;}
            td .actions { justify-content: flex-end; }
        }
    </style>
</head>
<body>
<div class="container">
    <header>
        <div class="header-info">
            <div>
                <h1>ZIVPN Admin Panel</h1>
                <div class="sub">👥 Total Users: <strong>{{ user_count }}</strong> | Today: {{ today }}</div>
            </div>
        </div>
        <div class="header-actions">
            <form method="post" action="/logout">
                <button class="btn btn-secondary" type="submit">Logout</button>
            </form>
        </div>
    </header>

    {% if msg %}<div class="msg">{{msg}}</div>{% endif %}
    {% if err %}<div class="err">{{err}}</div>{% endif %}

    <div class="box">
        <h3>➕ အသုံးပြုသူအသစ် ထည့်သွင်းရန်</h3>
        <form method="post" action="/add">
            <div class="row">
                <div><label>👤 User</label><input name="user" required></div>
                <div><label>🔑 Password</label><input name="password" required></div>
                <div><label>⏰ Expires (YYYY-MM-DD or Days)</label><input name="expires" placeholder="2025-12-31 or 30"></div>
                <div><label>🔌 UDP Port (6000–19999)</label><input name="port" placeholder="auto"></div>
            </div>
            <button class="btn btn-success" type="submit">Add User + Sync</button>
        </form>
    </div>

    <div class="box">
        <h3>📋 အသုံးပြုသူ စာရင်း</h3>
        <table>
            <thead>
                <tr>
                    <th>👤 User</th>
                    <th>🔑 Password</th>
                    <th>⏰ Expires</th>
                    <th>🔌 Port</th>
                    <th>⚙️ Manage</th>
                </tr>
            </thead>
            <tbody>
                {% for u in users %}
                <tr class="{% if u.expires and u.expires < today %}expired{% endif %}">
                    <td>{{ u.user }}</td>
                    <td>{{ u.password }}</td>
                    <td>{{ u.expires if u.expires else "N/A" }}</td>
                    <td>{{ u.port if u.port else "N/A" }}</td>
                    <td>
                        <div class="actions">
                            <a class="btn btn-primary" href="/edit/{{ u.user }}">Edit</a> 
                            <form method="post" action="/delete" onsubmit="return confirm('User: {{ u.user }} ကို ဖျက်မလား? ပြန်ပြင်လို့မရပါ');">
                                <input type="hidden" name="user" value="{{u.user}}">
                                <button type="submit" class="btn btn-danger">Delete</button>
                            </form>
                        </div>
                    </td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
    </div>
</div>
</body>
</html>
"""

# --- Edit Template (Simple version, uses the same style) ---
EDIT_HTML = """
<div class="container">
    <header>
        <a href="/" class="btn btn-secondary" style="margin-right: 15px;">&larr; Back to Users</a>
        <div class="header-info">
            <div><h1>ZIVPN Admin Panel</h1></div>
        </div>
    </header>

    {% if msg %}<div class="msg">{{msg}}</div>{% endif %}
    {% if err %}<div class="err">{{err}}</div>{% endif %}

    <div class="box">
      <h3>✏️ အသုံးပြုသူ အချက်အလက် ပြန်ပြင်ရန်: {{ current_user.user }}</h3>
      <form method="post" action="/update">
        <input type="hidden" name="old_user" value="{{ current_user.user }}">
        <div class="row">
          <div><label>👤 User</label><input name="user" required value="{{ current_user.user }}"></div>
          <div><label>🔑 Password</label><input name="password" required value="{{ current_user.password }}"></div>
        </div>
        <div class="row">
          <div><label>⏰ Expires (YYYY-MM-DD or days)</label><input name="expires" placeholder="2025-12-31 or 30" value="{{ current_user.expires if current_user.expires else '' }}"></div>
          <div><label>🔌 UDP Port (6000–19999)</label><input name="port" placeholder="auto" value="{{ current_user.port if current_user.port else '' }}"></div>
        </div>
        <button class="btn btn-primary" type="submit">Save Changes + Sync</button>
      </form>
    </div>
</div>
"""

# --- Flask Routes ---

@app.route("/", methods=["GET"])
def index():
    if not check_login():
        return redirect(url_for('login'))
    return build_view()

@app.route("/", methods=["POST"])
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if check_login():
            return redirect(url_for('index'))
        return render_template_string(LOGIN_HTML, err="Invalid Username or Password")
    
    # Login HTML (Basic)
    LOGIN_HTML = """
    <!DOCTYPE html>
    <html lang="my">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Login</title>
        <style>
            body { font-family: 'Arial', sans-serif; background-color: #f4f7f6; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
            .login-box { background-color: #fff; padding: 40px; border-radius: 8px; box-shadow: 0 4px 10px rgba(0, 0, 0, 0.1); width: 300px; text-align: center; }
            .login-box h2 { color: #007bff; margin-bottom: 25px; }
            input { width: 100%; padding: 10px; margin-bottom: 15px; border: 1px solid #ccc; border-radius: 4px; box-sizing: border-box; }
            button { width: 100%; padding: 10px; border: none; border-radius: 4px; background-color: #007bff; color: white; cursor: pointer; font-weight: bold; }
            .err { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; padding: 10px; border-radius: 4px; margin-bottom: 15px; font-weight: bold; font-size: 0.9em;}
        </style>
    </head>
    <body>
        <div class="login-box">
            <h2>Admin Login</h2>
            {% if err %}<div class="err">{{err}}</div>{% endif %}
            <form method="post" action="/login">
                <input type="text" name="user" placeholder="Username" required>
                <input type="password" name="password" placeholder="Password" required>
                <button type="submit">Login</button>
            </form>
        </div>
    </body>
    </html>
    """
    return render_template_string(LOGIN_HTML)

@app.route("/logout", methods=["POST"])
def logout():
    # Simple logout: redirect to login without setting auth headers
    return redirect(url_for('login'))

@app.route("/add", methods=["POST"])
def add_user():
    if not check_login(): return redirect(url_for('login', err="Please login again."))
    
    user=(request.form.get("user") or "").strip()
    password=(request.form.get("password") or "").strip()
    expires=(request.form.get("expires") or "").strip()
    port=(request.form.get("port") or "").strip()

    if expires.isdigit():
        expires=(datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")

    if not user or not password:
        return build_view(err="User နှင့် Password လိုအပ်သည်")
    
    if expires:
        try: datetime.strptime(expires,"%Y-%m-%d")
        except ValueError:
            return build_view(err="Expires format မမှန်ပါ (YYYY-MM-DD)")
    
    # Port validation and auto-assign
    if port:
        if not port.isdigit() or not (6000 <= int(port) <= 19999):
            return build_view(err="Port အကွာအဝေး 6000-19999 သို့မဟုတ် 'auto' ဖြစ်ရမည်")
    else:
        port=pick_free_port()

    users=load_users()
    # Check if user already exists (case-insensitive)
    for u in users:
        if u.get("user", "").lower() == user.lower():
            return build_view(err=f"User '{user}' ရှိပြီးသားဖြစ်သည်. Edit ကိုသုံးပါ")

    users.append({"user":user,"password":password,"expires":expires,"port":port})
    save_users(users); sync_config_passwords()
    return build_view(msg=f"User '{user}' successfully added and Synced")


@app.route("/delete", methods=["POST"])
def del_user():
    if not check_login(): return redirect(url_for('login', err="Please login again."))
    user=(request.form.get("user") or "").strip()
    if not user:
        return build_view(err="User name မပါဝင်ပါ")

    users=load_users()
    original_count = len(users)
    users = [u for u in users if (u.get("user","").lower() != user.lower())]
    
    if len(users) == original_count:
        return build_view(err=f"User '{user}' ကို ရှာမတွေ့ပါ")
    
    save_users(users); sync_config_passwords()
    return build_view(msg=f"User '{user}' successfully deleted and Synced")


@app.route("/edit/<user_name>", methods=["GET"])
def edit_user(user_name):
    if not check_login(): return redirect(url_for('login', err="Please login again."))
    
    users = load_users()
    current_user = next((u for u in users if u.get("user", "").lower() == user_name.lower()), None)
    
    if not current_user:
        return build_view(err=f"User '{user_name}' not found.")

    # Convert dict to simple object for easy template access
    class UserObject:
        def __init__(self, data):
            self.__dict__.update(data)
    u_obj = UserObject(current_user)
    
    return render_template_string(HTML.split('</style>')[0] + '</style></head><body>' + EDIT_HTML, 
                                  current_user=u_obj, logo=LOGO_URL)


@app.route("/update", methods=["POST"])
def update_user():
    if not check_login(): return redirect(url_for('login', err="Please login again."))
    
    old_user = (request.form.get("old_user") or "").strip()
    user=(request.form.get("user") or "").strip()
    password=(request.form.get("password") or "").strip()
    expires=(request.form.get("expires") or "").strip()
    port=(request.form.get("port") or "").strip()

    if expires.isdigit():
        expires=(datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")

    if not user or not password:
        return build_view(err="User နှင့် Password လိုအပ်သည်")
    if expires:
        try: datetime.strptime(expires,"%Y-%m-%d")
        except ValueError:
          return build_view(err="Expires format မမှန်ပါ (YYYY-MM-DD)")
    
    # Port validation
    if port:
        if not port.isdigit() or not (6000 <= int(port) <= 19999):
            return build_view(err="Port အကွာအဝေး 6000-19999 သို့မဟုတ် 'auto' ဖြစ်ရမည်")
    else:
        port=pick_free_port()

    users=load_users(); 
    # Old user ကို ဖျက်ပြီး update လုပ်မယ့် user name အသစ်နဲ့ အတူတူဆိုရင် edit လုပ်ခွင့်ပေးပါ
    users = [u for u in users if (u.get("user","").lower() != old_user.lower())]

    # Check if the NEW username already exists after removing OLD (if username was changed)
    for u in users:
        if u.get("user", "").lower() == user.lower():
            # Old user ကို ဖျက်ပစ်ပြီးသားမို့၊ ဒီနေရာမှာတွေ့ရင် တခြားသူဖြစ်နေမှာ
            return build_view(err=f"User '{user}' ရှိပြီးသားဖြစ်သည်. ကျေးဇူးပြု၍ တခြား နာမည်ပေးပါ")

    # Add the updated data
    users.append({"user":user,"password":password,"expires":expires,"port":port})
    
    save_users(users); sync_config_passwords()
    return build_view(msg=f"User '{old_user}' ကို '{user}' အဖြစ် အချက်အလက် ပြန်ပြင်ပြီး Synced လုပ်ပြီးပါပြီ")


def build_view(msg="", err=""):
    """Main view builder to show user list and counts."""
    users = load_users()
    
    # Sort users by expiration date (expired first)
    def sort_key(u):
        exp = u.get("expires", "9999-12-31")
        return (exp == "9999-12-31", exp) # Non-expiring users go last

    users.sort(key=sort_key)
    
    # Prepare data for template
    today = datetime.now().strftime("%Y-%m-%d")
    user_count = len(users)

    return render_template_string(HTML, 
                                  logo=LOGO_URL, 
                                  users=users, 
                                  msg=msg, 
                                  err=err, 
                                  today=today, 
                                  user_count=user_count)


if __name__ == '__main__':
    # Flask runs on port 8080 by default (as per original script logic)
    # The systemd service will handle running it with the correct config
    # app.run(host='0.0.0.0', port=8080)
    pass
EOF_PYTHON

# 5. Create/Update Systemd Service File
cat << EOF_SERVICE > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=ZIVPN Web Admin Panel
After=network.target

[Service]
# WARNING: Running as root is required for iptables (connlimit) in web.py
# For production use, consider using a non-root user and granting NET_ADMIN capabilities.
User=root
Group=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/bin/python3 ${PYTHON_APP_PATH}
Restart=always
EnvironmentFile=${ENV_FILE}

[Install]
WantedBy=multi-user.target
EOF_SERVICE

# 6. Apply Changes and Enable Service
echo "Enabling and starting ZIVPN Web Service..."
systemctl daemon-reload
systemctl enable zivpn-web.service
systemctl restart zivpn-web.service

# 7. Configure Firewall (UFW)
echo "Configuring UFW firewall for Web Panel (8080/tcp) and VPN Ports (5667/udp, 6000-19999/udp)..."
ufw allow 8080/tcp
ufw allow 5667/udp
ufw allow 6000:19999/udp
ufw enable

# 8. Initial Sync to apply iptables connection limits
echo "Performing initial sync to set connection limits and ZIVPN config..."
python3 -c "from web import sync_config_passwords; sync_config_passwords()"

echo "--- Setup Complete! ---"
echo "Web Admin Panel URL: http://<Your_Server_IP>:8080"
echo "Login with the credentials you provided."
