# /etc/zivpn/web2day.py (Modified by Gemini)

import json
import os
import datetime
import random
from flask import Flask, render_template_string, request, redirect, url_for, session

# --- CONFIGURATION (MODIFIED) ---
USERS_FILE = '/etc/zivpn/users.json'
# 🔑 ADMIN_USER နှင့် ADMIN_PASS ကို သင်စိတ်ကြိုက် ပြင်ဆင်ပါ
ADMIN_USER = 'upkvip'
ADMIN_PASS = 'your_strong_admin_password_here' # 👈 သင့်ရဲ့ Admin Password အသစ်ကို ဒီနေရာမှာ ထည့်ပါ
VPS_IP = '43.220.135.219' 
DEFAULT_EXPIRY_DAYS = 2  # 👈 သက်တမ်းကို ၂ ရက်သို့ ပြောင်းလိုက်ပါ
# --- END CONFIGURATION ---

# --- DUMMY FUNCTION FOR ZIVPN CORE (To be implemented by user) ---
def zivpn_core_delete_user(username):
    """
    ⚠️ ဤနေရာတွင် သက်တမ်းကုန်ဆုံးသည့်အခါ သုံးစွဲသူအား SSH/V2RAY စနစ်မှ ဖျက်ပစ်ရန် Command ကို ထည့်သွင်းရမည်။
    ဥပမာ- os.system(f'zivpn delete {username}')
    """
    print(f"DEBUG: ZIVPN CORE DELETE COMMAND FOR {username} SHOULD RUN HERE.")
    pass
# ----------------------------------------------------------------

app = Flask(__name__)
app.secret_key = 'supersecretkeyforzivpn'

# --- HELPER FUNCTIONS (MODIFIED) ---
def load_users():
    if not os.path.exists(USERS_FILE):
        return []
    try:
        with open(USERS_FILE, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return []

def save_users(users):
    with open(USERS_FILE, 'w') as f:
        json.dump(users, f, indent=4)

def check_auth(u, p):
    return u == ADMIN_USER and p == ADMIN_PASS

def check_user_status(user):
    # DUMMY STATUS: This should be connected to your actual ZIVPN status checker
    return {
        "status": random.choice(["Online", "Offline"]),
        "traffic": f"{random.randint(1, 99):.2f} GB", 
    }

def get_expired_count(users):
    today = datetime.date.today().strftime('%Y-%m-%d')
    return sum(1 for u in users if u.get('expires', '2099-12-31') < today)

def get_online_count(users):
    return sum(1 for u in users if u.get('status') == 'Online')

def sort_users(users):
    def sort_key(user):
        expires = user.get('expires', '2099-12-31')
        today_str = datetime.date.today().strftime('%Y-%m-%d')
        is_expired = expires < today_str
        # Sort by Expired users first, then by online status, then by username alphabetically.
        return (is_expired, user.get('status') != 'Online', user.get('user', '').lower())
    
    # Expired users should be at the bottom, so reverse=False (True by is_expired)
    return sorted(users, key=sort_key, reverse=False)

def check_and_delete_expired_users(users):
    today = datetime.date.today().strftime('%Y-%m-%d')
    
    # သက်တမ်းကုန်ဆုံးသူများကို စစ်ဆေးပါ
    expired_users = [u for u in users if u.get('expires', '2099-12-31') < today]
    
    if expired_users:
        print(f"INFO: Deleting {len(expired_users)} expired users...")
        for user in expired_users:
            # ZIVPN core မှ သုံးစွဲသူကို ဖျက်ရန် ခေါ်ဆိုပါ
            zivpn_core_delete_user(user['user'])
        
        # users.json မှ သက်တမ်းကုန်ဆုံးသူများကို ဖယ်ရှားပါ
        users = [u for u in users if u.get('expires', '2099-12-31') >= today]
        save_users(users)
        
    return users


# 🚨 HTML TEMPLATE: USER LIST LAYOUT MODIFIED 🚨
# (This section is too long to display fully, only the relevant CSS/HTML change is highlighted)
# ... (HTML content remains the same but updated for new layout)
HTML = """
<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta http-equiv="refresh" content="120">
<title>ZIVPN User Panel - DEV-U PHOE KAUNT</title>
<style>
 /* Global & Theme */
 :root{
  --bg:#f8f9fa; --fg:#212529; --muted:#6c757d; --card:#ffffff; --bd:#dee2e6;
  --ok:#198754; --bad:#dc3545; --primary:#0d6efd; 
 }
 html,body{background:var(--bg);color:var(--fg)}
 body{font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;margin:0;padding:12px 12px 70px 12px; min-height:100vh}
 .wrap{max-width:800px;margin:0 auto}
 
 /* Header & Navigation */
 header{position:sticky;top:0;background:var(--bg);padding:10px 0 12px;z-index:10;border-bottom:1px solid var(--bd)}
 .header-wrap{display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:space-between}
 h1{margin:0;font-size:18px;font-weight:700}
 .sub{color:var(--muted);font-size:12px}
 
 /* Buttons */
 .btn{padding:8px 12px;border-radius:8px;border:1px solid var(--bd);
      background:#fff;color:var(--fg);text-decoration:none;cursor:pointer;
      transition: background 0.1s ease; font-weight:500; font-size:13px; text-align:center; display:inline-block;}
 .btn:hover{background:#e9ecef}
 .btn-primary{background:var(--primary);border-color:var(--primary);color:#fff}
 .btn-primary:hover{background:#0b5ed7}
 .btn-success{background:var(--ok);border-color:var(--ok);color:#fff}
 .btn-success:hover{background:#157347}
 
 /* Forms & Boxes */
 .box{margin:14px 0;padding:16px;border:none;border-radius:12px;background:var(--card);box-shadow:0 4px 6px -1px rgba(0,0,0,.1), 0 2px 4px -2px rgba(0,0,0,.1)}
 label{display:block;margin:6px 0 3px;font-size:13px;color:var(--muted);font-weight:500}
 input{width:100%;padding:10px 12px;border:1px solid var(--bd);border-radius:8px;background:#fff;color:var(--fg);box-sizing:border-box;}
 .form-inline{display:grid;grid-template-columns:1fr 1fr;gap:12px;}
 @media (max-width: 480px) { .form-inline { grid-template-columns: 1fr; } }
 .form-inline-full-width { grid-column: 1 / -1; }
 
 /* 30-Day Count Box */
 .count-box {
    padding: 12px;
    background: #e9f7f0; 
    border-radius: 10px;
    text-align: center;
    margin: 10px 0;
 }
 .count-box p { margin: 0; font-size: 13px; color: var(--ok); font-weight: 500;}
 .count-box .number { font-size: 20px; font-weight: 700; color: var(--fg); margin-top: 2px; display: block; }
 
 /* USER LIST (MODIFIED LAYOUT) */
 .user-list{display:grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 12px; margin-top:12px;}
 .user-card {
    padding: 12px;
    border: none;
    border-radius: 10px;
    background: var(--card);
    box-shadow: 0 1px 3px rgba(0,0,0,.08);
 }
 .user-card.expired {
    background: #f8d7da; /* Light red for expired */
 }
 .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 1px solid var(--bd);
    padding-bottom: 8px;
    margin-bottom: 8px;
 }
 .user-name {
    font-size: 16px;
    font-weight: 700;
    color: var(--fg);
 }
 .status-dot {
    height: 10px;
    width: 10px;
    background-color: var(--muted);
    border-radius: 50%;
    display: inline-block;
    margin-right: 4px;
 }
 .status-dot.online {
    background-color: var(--ok);
 }
 .status-text {
     font-size: 13px;
     font-weight: 600;
     color: var(--muted);
 }
 .status-text.online {
     color: var(--ok);
 }
 .status-text.expired {
     color: var(--bad);
 }

 .card-details {
     font-size: 13px;
     color: var(--muted);
     margin: 4px 0;
 }
 .card-actions {
     margin-top: 10px;
     display: flex;
     gap: 8px;
 }
 
 /* Copy Button Styling */
 .copy-row {
    display: flex;
    align-items: center;
    gap: 8px;
 }
 .copy-btn {
    padding: 8px;
    font-size: 12px;
 }

 /* Footer Navigation */
 footer {
    position: fixed;
    bottom: 0;
    left: 0;
    right: 0;
    background: var(--card);
    border-top: 1px solid var(--bd);
    padding: 8px 0;
    z-index: 1000;
 }
 .nav-bar {
    display: flex;
    justify-content: space-around;
    max-width: 800px;
    margin: 0 auto;
    padding: 0 12px;
 }
 .nav-item {
    flex-grow: 1;
    text-align: center;
 }
 .nav-link {
    display: flex;
    flex-direction: column;
    align-items: center;
    text-decoration: none;
    font-size: 11px;
    color: var(--muted);
    font-weight: 600;
 }
 .nav-link.active {
    color: var(--primary);
 }
 .nav-link-icon {
    font-size: 16px;
    margin-bottom: 2px;
 }
</style>
<script>
  function fallbackCopy(text) {
    var textArea = document.createElement("textarea");
    textArea.value = text;
    textArea.style.position = "fixed";
    textArea.style.opacity = "0";
    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();
    try {
      var successful = document.execCommand('copy');
      if (successful) {
        alert('ကူးယူပြီးပါပြီ (Legacy): ' + text);
      } else {
        alert('ကူးယူမရပါ (Manual copy): ' + text);
      }
    } catch (err) {
      alert('ကူးယူမရပါ (Error): ' + text);
    }
    document.body.removeChild(textArea);
  }

  function copyToClipboard(text, event) {
    if (navigator.clipboard) {
      navigator.clipboard.writeText(text).then(function() {
        alert('ကူးယူပြီးပါပြီ: ' + text);
      }, function(err) {
        console.warn('Clipboard API failed, falling back...');
        fallbackCopy(text);
      });
    } else {
      fallbackCopy(text);
    }
    if (event) event.preventDefault();
  }
</script>
</head><body>

{% if info_page %}
  <div class="wrap" style="max-width:500px">
  <div class="box info-box">
    <h2 style="margin-top:0;color:var(--ok)">✅ အကောင့်အသစ် ဖွင့်ပြီးပါပြီ</h2>
    <p class="muted">အောက်ပါ အချက်အလက်များကို client တွင် ထည့်သွင်းအသုံးပြုနိုင်ပါသည်။</p>

    <div style="margin-top:16px">
        <label>👤 User Name</label>
        <div class="copy-row">
            <input type="text" value="{{ info.user }}" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.user }}', event)">Copy</button>
        </div>
        
        <label style="margin-top:12px">🔑 Password</label>
        <div class="copy-row">
            <input type="text" value="{{ info.password }}" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.password }}', event)">Copy</button>
        </div>
        
        <label style="margin-top:12px">🌐 VPS IP (Server Address)</label>
        <div class="copy-row">
            <input type="text" value="{{ info.vps_ip }}" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.vps_ip }}', event)">Copy</button>
        </div>
        
        <label style="margin-top:12px">⏰ သက်တမ်းကုန်ဆုံးရက်</label>
        <div class="copy-row">
            <input type="text" value="{{ info.expires }} ({{ default_expiry_days }} ရက်)" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.expires }}', event)">Copy</button>
        </div>
        
        <label style="margin-top:12px">🔌 Port (Device Lock)</label>
        <div class="copy-row">
            <input type="text" value="{{ info.port }}" readonly>
            <button class="copy-btn" onclick="copyToClipboard('{{ info.port }}', event)">Copy</button>
        </div>
    </div>
    <a href="{{ url_for('index') }}" class="btn btn-primary" style="margin-top:16px;width:100%;text-align:center;">🏠 Dashboard သို့ပြန်သွားရန်</a>
  </div>
 </div>

{% elif edit_page %}
  <div class="wrap">
  <div class="box" style="max-width:600px;margin:20px auto">
    <h3 style="margin:4px 0 16px;border-bottom:1px solid var(--bd);padding-bottom:8px">✏️ အသုံးပြုသူ ပြင်ဆင်ခြင်း: {{ edit_user.user }}</h3>
    {% if msg %}<div style="color:var(--ok);margin:6px 0">{{msg}}</div>{% endif %}
    {% if err %}<div style="color:var(--bad);margin:6px 0">{{err}}</div>{% endif %}
    <form method="post" action="{{ url_for('edit_user') }}">
      <input type='hidden' name='orig' value='{{ edit_user.user }}'>
      <input type='hidden' name='created_at' value='{{ edit_user.created_at or "" }}'>
      
      <div class="form-inline">
        <div><label>User Name</label><input name='user' value='{{ edit_user.user }}' required></div>
        <div><label>Password</label><input name='password' value='{{ edit_user.password }}' required></div>
        <div><label>သက်တမ်းကုန်ဆုံးရက် (YYYY-MM-DD)</label><input name='expires' value='{{ edit_user.expires or "" }}' placeholder='{{ default_expiry_days }} (ရက်) သို့ 2025-12-31'></div>
        <div><label>UDP Port (6000-19999)</label><input name='port' value='{{ edit_user.port or "" }}' placeholder='အလိုအလျောက် ရွေးမယ်'></div>
        <div class="form-inline-full-width"><label>📱 ချိတ်ထားသော IP (Device Lock)</label><input name='bind_ip' value='{{ edit_user.bind_ip or "" }}' placeholder='ချိတ်ထားသည့် IP (သို့) ရှင်းလင်းထားရန်'></div>
      </div>
      
      <div class="card-actions" style="margin-top:16px">
        <button class="btn btn-primary" type="submit" style="flex:1">💾 Save Changes</button>
        <a class="btn" href="{{ url_for('index') }}" style="flex:1;text-align:center">❌ Cancel</a>
      </div>

      <div style="margin-top:16px; border-top:1px solid var(--bd); padding-top:16px;" class="card-actions">
          <form style="display:inline; flex:1" method="post" action="{{ url_for('lock_now', user=edit_user.user) }}">
            <input type="hidden" name="user" value="{{ edit_user.user }}">
            <button class="btn btn-success" name="op" value="lock" title="Lock to current IP" style="width:100%">Lock Now</button>
          </form>
          <form style="display:inline; flex:1" method="post" action="{{ url_for('lock_now', user=edit_user.user) }}">
            <input type="hidden" name="user" value="{{ edit_user.user }}">
            <button class="btn btn-del" name="op" value="clear" title="Clear lock" style="width:100%">Clear Lock</button>
          </form>
      </div>
    </form>
    
    <form style="display:block; margin-top:16px; padding-top:16px; border-top:1px solid var(--bd);" method="post" action="{{ url_for('delete_user_html') }}" onsubmit="return confirm('{{edit_user.user}} ကို ဖျက်မလား?')" >
        <input type="hidden" name="user" value="{{edit_user.user}}">
        <button type="submit" class="btn btn-del" style="width:100%">🗑️ Delete User</button>
    </form>
  </div>
</div>
{% else %}
<header>
 <div class="wrap header-wrap">
   <div style="flex:1">
     <h1>DEV-U PHOE KAUNT</h1>
     <div class="sub">ZIVPN User Panel • Total: <span class="count">{{ total }}</span></div>
   </div>
   <div style="display:flex; gap:8px;">
     <form method="post" action="{{ url_for('refresh_status', filter=filter_type) }}"><button class="btn btn-primary" type="submit">🔄 Scan Status</button></form>
     {% if authed %}<a class="btn" href="/logout">Logout</a>{% endif %}
   </div>
 </div>
</header>

<div class="wrap">
{% if not authed %}
  <div class="box" style="max-width:440px;margin:40px auto">
    {% if err %}<div style="color:var(--bad);margin-bottom:8px">{{err}}</div>{% endif %}
    <form method="post" action="/login">
      <label>Username</label><input name="u" autofocus required>
      <label style="margin-top:8px">Password</label><input name="p" type="password" required>
      <button class="btn btn-primary" type="submit" style="margin-top:12px;width:100%">Login</button>
    </form>
  </div>
{% else %}

{% if filter_type == 'all' %}
<div class="count-box">
  <p>TextView. ရက်({{ default_expiry_days }})အတွင်း စုစုပေါင်း အကောင့်ဖွင့်သူ</p>
  <span class="number">{{ total_30_day_users }}</span>
</div>

<div class="box">
  <h3 style="margin:4px 0 8px">➕ အသုံးပြုသူ အသစ်ထည့်ရန် ({{ default_expiry_days }} ရက် သက်တမ်း)</h3>
  {% if msg %}<div style="color:var(--ok);margin:6px 0">{{msg}}</div>{% endif %}
  {% if err %}<div style="color:var(--bad);margin:6px 0">{{err}}</div>{% endif %}
  <form method="post" action="/add">
    <div class="form-inline">
      <div><label>👤 User</label><input name="user" required></div>
      <div><label>🔑 Password</label><input name="password" required></div>
    </div>
    <div class="form-inline-full-width"> 
        <button class="btn btn-success" type="submit" style="margin-top:12px;width:100%">Save & Show Info</button>
    </div>
  </form>
</div>
{% endif %}

<div class="user-list">
  {% for u in users %}
  {% if u.expires >= today or filter_type == 'all' or filter_type == 'expired' %}
  
  <div class="user-card {% if u.is_expired %}expired{% endif %}">
    
    <div class="card-header">
        <div class="user-name">{{u.user}}</div>
        <div>
            {% if u.is_expired %}
                 <span class="status-dot"></span><span class="status-text expired">Expired</span>
            {% else %}
                 <span class="status-dot {% if u.status == 'Online' %}online{% endif %}"></span>
                 <span class="status-text {% if u.status == 'Online' %}online{% endif %}">{{u.status}}</span>
            {% endif %}
        </div>
    </div>
    
    <div class="card-details">
        ⏰ ကုန်ရက်: {% if u.expires %}{{u.expires}}{% else %}—{% endif %}
    </div>
    <div class="card-details">
        🔗 ချိတ်ထားသည်: {% if u.bind_ip %}{{u.bind_ip}}{% else %}—{% endif %}
    </div>
    <div class="card-actions">
        <a class="btn" href="{{ url_for('edit_user_page', user=u.user) }}" style="flex:1">✏️ Edit</a>
        <form style="flex:1" method="post" action="{{ url_for('delete_user_html') }}" onsubmit="return confirm('{{u.user}} ကို ဖျက်မလား?')" >
            <input type="hidden" name="user" value="{{u.user}}">
            <button type="submit" class="btn" style="width:100%">🗑️ Delete</button>
        </form>
    </div>
    
  </div>
  {% endif %}
  {% endfor %}
</div>
{% endif %}
</div>
<footer>
    <div class="nav-bar">
        <div class="nav-item">
            <a href="{{ url_for('index', filter='all') }}" class="nav-link {% if filter_type == 'all' %}active{% endif %}"> All ({{ total }})</a>
        </div>
        <div class="nav-item">
            <a href="{{ url_for('index', filter='expired') }}" class="nav-link {% if filter_type == 'expired' %}active{% endif %}"> Expired ({{ expired_count }})</a>
        </div>
        <div class="nav-item">
            <a href="{{ url_for('index', filter='online') }}" class="nav-link {% if filter_type == 'online' %}active{% endif %}"> Online ({{ online_count }})</a>
        </div>
        <div class="nav-item">
            <a href="https://m.me/upkvpnfastvpn" target="_blank" rel="noopener" class="nav-link"> Support</a>
        </div>
    </div>
</footer>
{% endif %}
</body></html>
"""
# ----------------------------------------------------------------------------------------------------
# 🚨 PYTHON APPLICATION ROUTES START HERE 🚨
# ----------------------------------------------------------------------------------------------------

@app.before_request
def check_expiry_and_delete():
    # ဤ function သည် Request တိုင်းမတိုင်မီ အလုပ်လုပ်ပြီး သက်တမ်းကုန်ဆုံးသူများကို ဖျက်ပေးမည်
    if request.path.startswith('/static') or request.path.startswith('/favicon'):
        return # Static files အတွက် မလိုအပ်ပါ
    
    users_data = load_users()
    new_users_data = check_and_delete_expired_users(users_data)
    
    # Session ထဲမှာ user list အဟောင်းရှိနေရင် update လုပ်ဖို့ မလိုပါဘူး (ဒါက Flask application မှာသာ သက်ဆိုင်သည်)
    pass 


@app.route('/')
@app.route('/index')
@app.route('/index/<filter_type>')
def index(filter_type='all'):
    authed = session.get('logged_in', False)
    users_data = load_users()
    today_str = datetime.date.today().strftime('%Y-%m-%d')
    
    # အကယ်၍ Admin User Login ဝင်ထားပါက သက်တမ်းကုန်ဆုံးသူများကို စစ်ဆေးဖျက်ပစ်ပါမည်
    if authed:
        users_data = check_and_delete_expired_users(users_data)


    if not authed and filter_type == 'all':
        return render_template_string(HTML, authed=False)

    for u in users_data:
        u['expires'] = u.get('expires', '')
        # is_expired ကို အပေါ်မှာ သက်တမ်းစစ်ပြီး delete လုပ်ထားရင်တောင် အတိအကျသိရှိဖို့ ပြန်စစ်ပါ
        u['is_expired'] = u['expires'] < today_str if u['expires'] else False
        u.update(check_user_status(u['user']))

    if filter_type == 'expired':
        filtered_users = [u for u in users_data if u['is_expired']]
    elif filter_type == 'online':
        filtered_users = [u for u in users_data if u['status'] == 'Online' and not u['is_expired']]
    else: 
        filtered_users = users_data

    sorted_users = sort_users(filtered_users)

    total = len(users_data)
    expired_count = get_expired_count(users_data)
    online_count = get_online_count(users_data)
    
    thirty_days_ago = (datetime.date.today() - datetime.timedelta(days=30)).strftime('%Y-%m-%d')
    total_30_day_users = sum(1 for u in users_data if u.get('created_at', '1970-01-01') >= thirty_days_ago)


    data = {
        'authed': authed,
        'users': sorted_users,
        'total': total,
        'expired_count': expired_count,
        'online_count': online_count,
        'filter_type': filter_type,
        'today': today_str,
        'default_expiry_days': DEFAULT_EXPIRY_DAYS,
        'total_30_day_users': total_30_day_users
    }

    return render_template_string(HTML, **data)

# --- LOGIN/LOGOUT (UNCHANGED) ---
@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['u']
        password = request.form['p']
        if check_auth(username, password):
            session['logged_in'] = True
            return redirect(url_for('index'))
        else:
            return render_template_string(HTML, authed=False, err='Invalid username or password')
    return redirect(url_for('index'))

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('index'))

# --- USER MANAGEMENT (UNCHANGED) ---
@app.route('/add', methods=['POST'])
def add_user():
    if not session.get('logged_in'):
        return redirect(url_for('index'))
    
    user = request.form['user'].strip()
    password = request.form['password'].strip()
    
    users = load_users()
    if any(u['user'] == user for u in users):
        return render_template_string(HTML, authed=True, err=f'User "{user}" already exists!', filter_type='all')

    # DEFAULT_EXPIRY_DAYS = 2 ရက် ကို သုံးထားသည်
    expires_date = (datetime.date.today() + datetime.timedelta(days=DEFAULT_EXPIRY_DAYS)).strftime('%Y-%m-%d')
    
    new_user = {
        'user': user,
        'password': password, 
        'expires': expires_date,
        'port': random.randint(6000, 19999), 
        'bind_ip': '', 
        'created_at': datetime.date.today().strftime('%Y-%m-%d')
    }
    users.append(new_user)
    save_users(users)
    
    info = new_user.copy()
    info['vps_ip'] = VPS_IP

    return render_template_string(HTML, info_page=True, info=info, default_expiry_days=DEFAULT_EXPIRY_DAYS)


# --- DELETE USER (MODIFIED: Also calls ZIVPN core delete) ---
@app.route('/delete_user', methods=['POST'])
def delete_user_html():
    if not session.get('logged_in'):
        return redirect(url_for('index'))
    
    user_to_delete = request.form.get('user')
    
    # 1. ZIVPN Core မှ ဖျက်ပါ
    zivpn_core_delete_user(user_to_delete)
    
    # 2. users.json မှ ဖျက်ပါ
    users = load_users()
    users = [u for u in users if u['user'] != user_to_delete]
    save_users(users)
    
    return redirect(url_for('index'))

# --- EDIT USER, LOCK/CLEAR LOCK, REFRESH STATUS (UNCHANGED LOGIC) ---
@app.route('/edit', methods=['GET'])
def edit_user_page():
    if not session.get('logged_in'):
        return redirect(url_for('index'))
    
    user_to_edit = request.args.get('user')
    users = load_users()
    edit_user = next((u for u in users if u['user'] == user_to_edit), None)

    if not edit_user:
        return redirect(url_for('index'))
        
    return render_template_string(HTML, authed=True, edit_page=True, edit_user=edit_user)

@app.route('/edit_user', methods=['POST'])
def edit_user():
    if not session.get('logged_in'):
        return redirect(url_for('index'))
    
    orig_user = request.form['orig']
    new_user = request.form['user'].strip()
    password = request.form['password'].strip()
    expires = request.form.get('expires', '').strip()
    port = request.form.get('port', '').strip()
    bind_ip = request.form.get('bind_ip', '').strip()
    created_at = request.form.get('created_at', '')

    users = load_users()
    
    for i, user in enumerate(users):
        if user['user'] == orig_user:
            if orig_user != new_user and any(u['user'] == new_user for u in users if u['user'] != orig_user):
                return render_template_string(HTML, authed=True, edit_page=True, edit_user=user, err=f'User "{new_user}" already exists!')
            
            # User Name ပြောင်းလဲလျှင်၊ အရင် user ကို core မှ ဖျက်ပြီး အသစ်ကို ထည့်သွင်းရန် လိုအပ်သည်
            if orig_user != new_user:
                 zivpn_core_delete_user(orig_user)
                 # New user ကို ထည့်သွင်းခြင်း logic သည် add_user() function တွင်သာ ရှိသည်
            
            users[i]['user'] = new_user
            users[i]['password'] = password
            users[i]['expires'] = expires
            users[i]['port'] = int(port) if port.isdigit() else user.get('port')
            users[i]['bind_ip'] = bind_ip
            users[i]['created_at'] = created_at
            save_users(users)
            return redirect(url_for('index', msg=f'User {new_user} updated successfully!'))

    return redirect(url_for('index', err='User not found.'))


@app.route('/lock_now/<user>', methods=['POST'])
def lock_now(user):
    if not session.get('logged_in'):
        return redirect(url_for('index'))
    
    op = request.form.get('op')
    users = load_users()

    # Client ရဲ့ IP ကို တကယ်တမ်းရဖို့အတွက် Nginx/Proxy config တွေ လိုအပ်နိုင်ပါတယ်
    # ဤနေရာတွင် Hardcode လုပ်ထားသည်ကို သင့်လျော်စွာ ပြောင်းလဲနိုင်သည်
    client_ip = request.headers.get('X-Forwarded-For', request.remote_addr).split(',')[0].strip()
    
    for i, u in enumerate(users):
        if u['user'] == user:
            if op == 'lock':
                users[i]['bind_ip'] = client_ip 
                msg = f'User {user} locked to {client_ip}!'
            elif op == 'clear':
                users[i]['bind_ip'] = ''
                msg = f'User {user} lock cleared!'
            else:
                msg = 'Invalid operation.'
            
            save_users(users)
            return redirect(url_for('edit_user_page', user=user, msg=msg))

    return redirect(url_for('index', err='User not found for lock operation.'))


@app.route('/refresh_status', methods=['POST'])
def refresh_status():
    if not session.get('logged_in'):
        return redirect(url_for('index'))
        
    filter_type = request.form.get('filter', 'all')
    return redirect(url_for('index', filter_type=filter_type))


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)
