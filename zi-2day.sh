import json import os import datetime import random from flask import Flask, render_template_string, request, redirect, url_for, session

--- CONFIGURATION (ENV-READY) ---

USERS_FILE = os.getenv('ZIVPN_USERS_FILE', '/etc/zivpn/users.json') VPS_IP = os.getenv('ZIVPN_VPS_IP', '43.220.135.219') DEFAULT_EXPIRY_DAYS = int(os.getenv('ZIVPN_DEFAULT_EXPIRY_DAYS', '2'))

--- DUMMY FUNCTION FOR ZIVPN CORE ---

def zivpn_core_delete_user(username): """ Put real delete command here, e.g.: os.system(f'zivpn delete {username}') """ print(f"DEBUG: ZIVPN CORE DELETE COMMAND FOR {username} SHOULD RUN HERE.")

Flask app (LOGIN-FREE)

app = Flask(name)

⚠️ Change secret in production

app.secret_key = os.getenv('ZIVPN_PANEL_SECRET', 'supersecretkeyforzivpn_free_panel')

--- HELPERS ---

def ensure_users_dir(): os.makedirs(os.path.dirname(USERS_FILE), exist_ok=True)

def load_users(): ensure_users_dir() if not os.path.exists(USERS_FILE): return [] try: with open(USERS_FILE, 'r') as f: return json.load(f) except json.JSONDecodeError: return []

def save_users(users): ensure_users_dir() with open(USERS_FILE, 'w') as f: json.dump(users, f, indent=4)

def check_user_status(username): # DEMO ONLY — replace with real status status = random.choice(["Online", "Offline"])  # demo return { "status": status, "traffic": f"{random.randint(1, 99):.2f} GB", "bind_ip": f"192.168.1.{random.randint(100, 250)}" if status == 'Online' else None }

def get_expired_count(users): today = datetime.date.today().strftime('%Y-%m-%d') return sum(1 for u in users if u.get('expires', '2099-12-31') < today)

def get_online_count(users): return sum(1 for u in users if u.get('status') == 'Online')

def sort_users(users): def sort_key(user): expires = user.get('expires', '2099-12-31') today_str = datetime.date.today().strftime('%Y-%m-%d') is_expired = expires < today_str return (is_expired, user.get('status') != 'Online', user.get('user', '').lower()) return sorted(users, key=sort_key, reverse=False)

def check_and_delete_expired_users(users): today = datetime.date.today().strftime('%Y-%m-%d') expired_users = [u for u in users if u.get('expires', '2099-12-31') < today] if expired_users: print(f"INFO: Deleting {len(expired_users)} expired users...") for user in expired_users: zivpn_core_delete_user(user['user']) users = [u for u in users if u.get('expires', '2099-12-31') >= today] save_users(users) return users

--- CAPTCHA ---

def generate_captcha(): num1 = random.randint(1, 9) num2 = random.randint(1, 9) session['captcha_answer'] = num1 + num2 return f"{num1} + {num2} = ?"

--- HTML TEMPLATE (LOGIN-FREE + UI IMPROVED) ---

HTML = """ <!doctype html>

<html lang=\"my\"><head><meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">
<meta http-equiv=\"refresh\" content=\"120\">
<title>ZIVPN User Panel - DEV-U PHOE KAUNT (FREE)</title>
<style>
 :root{ --bg:#f8f9fa; --fg:#212529; --muted:#6c757d; --card:#ffffff; --bd:#dee2e6; --ok:#198754; --bad:#dc3545; --primary:#0d6efd }
 html,body{background:var(--bg);color:var(--fg)}
 body{font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;margin:0;padding:12px 12px 80px;min-height:100vh}
 .wrap{max-width:900px;margin:0 auto}
 header{position:sticky;top:0;background:var(--bg);padding:10px 0 12px;z-index:10;border-bottom:1px solid var(--bd)}
 .header-wrap{display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:space-between}
 h1{margin:0;font-size:18px;font-weight:700}
 .sub{color:var(--muted);font-size:12px}
 .btn{padding:8px 12px;border-radius:8px;border:1px solid var(--bd);background:#fff;color:var(--fg);text-decoration:none;cursor:pointer;transition:.1s; font-weight:500; font-size:13px; display:inline-block}
 .btn:hover{background:#e9ecef}
 .btn-primary{background:var(--primary);border-color:var(--primary);color:#fff}
 .btn-primary:hover{background:#0b5ed7}
 .btn-success{background:var(--ok);border-color:var(--ok);color:#fff}
 .btn-success:hover{background:#157347}
 .box{margin:14px 0;padding:16px;border:none;border-radius:12px;background:var(--card);box-shadow:0 4px 6px -1px rgba(0,0,0,.1), 0 2px 4px -2px rgba(0,0,0,.1)}
 label{display:block;margin:6px 0 3px;font-size:13px;color:var(--muted);font-weight:500}
 input{width:100%;padding:10px 12px;border:1px solid var(--bd);border-radius:8px;background:#fff;color:var(--fg);box-sizing:border-box}
 .form-inline{display:grid;grid-template-columns:1fr 1fr;gap:12px}
 @media (max-width: 520px) { .form-inline { grid-template-columns: 1fr } }
 .form-inline-full-width{grid-column:1/-1}
 .search-row{display:flex;gap:8px;align-items:center}
 .pill{padding:2px 8px;border-radius:999px;border:1px solid var(--bd);font-size:11px;color:var(--muted)}
 .pill.ok{border-color:var(--ok);color:var(--ok)}
 .pill.bad{border-color:var(--bad);color:var(--bad)}
 .user-list{display:grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 12px; margin-top:12px}
 .user-card{padding:12px;border:none;border-radius:10px;background:var(--card);box-shadow:0 1px 3px rgba(0,0,0,.08)}
 .user-card.expired{background:#f8d7da}
 .card-header{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid var(--bd);padding-bottom:8px;margin-bottom:8px}
 .user-name{font-size:16px;font-weight:700}
 .status-block{display:flex;align-items:center;font-size:13px;font-weight:600}
 .status-dot{height:10px;width:10px;background-color:var(--muted);border-radius:50%;display:inline-block;margin-right:4px}
 .status-dot.online{background-color:var(--ok)}
 .status-text{color:var(--muted)}
 .status-text.online{color:var(--ok)}
 .status-text.expired{color:var(--bad)}
 .card-details{font-size:13px;color:var(--muted);margin:4px 0}
 footer{position:fixed;bottom:0;left:0;right:0;background:var(--card);border-top:1px solid var(--bd);padding:8px 0;z-index:1000}
 .nav-bar{display:flex;justify-content:space-around;max-width:900px;margin:0 auto;padding:0 12px}
 .nav-item{flex-grow:1;text-align:center}
 .nav-link{display:flex;flex-direction:column;align-items:center;text-decoration:none;font-size:11px;color:var(--muted);font-weight:600}
 .nav-link.active{color:var(--primary)}
 .count-box{padding:12px;background:#e9f7f0;border-radius:10px;text-align:center;margin:10px 0}
 .count-box p{margin:0;font-size:13px;color:var(--ok);font-weight:500}
 .count-box .number{font-size:20px;font-weight:700;color:var(--fg);margin-top:2px;display:block}
 .copy-row{display:flex;align-items:center;gap:8px}
 .copy-btn{padding:8px;font-size:12px}
 .toggle{cursor:pointer}
</style>
<script>
  function fallbackCopy(text){
    var textArea=document.createElement('textarea');
    textArea.value=text; textArea.style.position='fixed'; textArea.style.opacity='0'; document.body.appendChild(textArea);
    textArea.focus(); textArea.select();
    try{var ok=document.execCommand('copy'); alert(ok?'ကူးယူပြီးပါပြီ (Legacy): '+text:'ကူးယူမရပါ (Manual copy): '+text);}catch(err){alert('ကူးယူမရပါ (Error): '+text);} document.body.removeChild(textArea);
  }
  function copyToClipboard(text,ev){ if(navigator.clipboard){ navigator.clipboard.writeText(text).then(function(){alert('ကူးယူပြီးပါပြီ: '+text)},function(){fallbackCopy(text)});} else {fallbackCopy(text)} if(ev) ev.preventDefault(); }
  function copyAllInfo(){ var lines=[]; document.querySelectorAll('[data-copy="kv"]').forEach(function(el){ lines.push(el.getAttribute('data-label')+': '+el.value); }); var payload=lines.join('\n'); copyToClipboard(payload); }
  function filterCards(){ var q=(document.getElementById('q')||{}).value?.toLowerCase()||''; document.querySelectorAll('.user-card').forEach(function(card){ var name=(card.querySelector('.user-name')?.textContent||'').toLowerCase(); var ip=(card.querySelector('[data-ip]')?.textContent||'').toLowerCase(); card.style.display=(name.includes(q)||ip.includes(q))?'block':'none'; }); }
  function toggleTheme(){ const dark=document.documentElement.dataset.theme==='dark'; if(dark){ delete document.documentElement.dataset.theme; document.documentElement.style.setProperty('--bg','#f8f9fa'); document.documentElement.style.setProperty('--fg','#212529'); document.documentElement.style.setProperty('--card','#ffffff'); document.documentElement.style.setProperty('--bd','#dee2e6'); document.documentElement.style.setProperty('--muted','#6c757d'); } else { document.documentElement.dataset.theme='dark'; document.documentElement.style.setProperty('--bg','#0b1220'); document.documentElement.style.setProperty('--fg','#e7ecf3'); document.documentElement.style.setProperty('--card','#111a2e'); document.documentElement.style.setProperty('--bd','#22304d'); document.documentElement.style.setProperty('--muted','#9fb0cc'); } }
</script>
</head><body>{% if info_page %}

  <div class=\"wrap\" style=\"max-width:520px\">
  <div class=\"box info-box\">
    <h2 style=\"margin-top:0;color:var(--ok)\">✅ အကောင့်အသစ် ဖွင့်ပြီးပါပြီ</h2>
    <p class=\"muted\">အောက်ပါ အချက်အလက်များကို client တွင် ထည့်သွင်းအသုံးပြုနိုင်ပါသည်။</p>
    <div style=\"margin-top:16px\">
        <label>👤 User Name</label>
        <div class=\"copy-row\">
            <input type=\"text\" value=\"{{ info.user }}\" readonly data-copy=\"kv\" data-label=\"User\">
            <button class=\"copy-btn\" onclick=\"copyToClipboard('{{ info.user }}', event)\">Copy</button>
        </div>
        <label style=\"margin-top:12px\">🔑 Password</label>
        <div class=\"copy-row\">
            <input type=\"text\" value=\"{{ info.password }}\" readonly data-copy=\"kv\" data-label=\"Password\">
            <button class=\"copy-btn\" onclick=\"copyToClipboard('{{ info.password }}', event)\">Copy</button>
        </div>
        <label style=\"margin-top:12px\">🌐 VPS IP (Server Address)</label>
        <div class=\"copy-row\">
            <input type=\"text\" value=\"{{ info.vps_ip }}\" readonly data-copy=\"kv\" data-label=\"VPS IP\">
            <button class=\"copy-btn\" onclick=\"copyToClipboard('{{ info.vps_ip }}', event)\">Copy</button>
        </div>
        <label style=\"margin-top:12px\">⏰ သက်တမ်းကုန်ဆုံးရက်</label>
        <div class=\"copy-row\">
            <input type=\"text\" value=\"{{ info.expires }} ({{ default_expiry_days }} ရက်)\" readonly data-copy=\"kv\" data-label=\"Expires\">
            <button class=\"copy-btn\" onclick=\"copyToClipboard('{{ info.expires }}', event)\">Copy</button>
        </div>
        <label style=\"margin-top:12px\">🔌 Port (Device Lock)</label>
        <div class=\"copy-row\">
            <input type=\"text\" value=\"{{ info.port }}\" readonly data-copy=\"kv\" data-label=\"Port\">
            <button class=\"copy-btn\" onclick=\"copyToClipboard('{{ info.port }}', event)\">Copy</button>
        </div>
    </div>
    <button class=\"btn\" style=\"margin-top:12px;width:100%\" onclick=\"copyAllInfo()\">📋 Copy All</button>
    <a href=\"{{ url_for('index') }}\" class=\"btn btn-primary\" style=\"margin-top:12px;width:100%;text-align:center;\">🏠 Dashboard သို့ပြန်သွားရန်</a>
  </div>
 </div>{% elif edit_page %}

  <div class=\"wrap\" style=\"max-width:520px\">
     <div class=\"box info-box\">
         <h2 style=\"margin-top:0;color:var(--bad)\">⚠️ စီမံခန့်ခွဲခွင့် ပိတ်ထားပါသည်</h2>
         <p class=\"muted\">Edit နှင့် Delete လုပ်ဆောင်ချက်များကို Free Panel တွင် ပိတ်ထားပါသည်။</p>
         <a href=\"{{ url_for('index') }}\" class=\"btn btn-primary\" style=\"margin-top:16px;width:100%;text-align:center;\">🏠 Dashboard သို့ပြန်သွားရန်</a>
     </div>
  </div>
{% else %}
<header>
 <div class=\"wrap header-wrap\">
   <div style=\"flex:1\">
     <h1>DEV-U PHOE KAUNT (Free Panel)</h1>
     <div class=\"sub\">ZIVPN User Panel • Total: <span class=\"count\">{{ total }}</span></div>
   </div>
   <div style=\"display:flex; gap:8px; align-items:center;\">
     <div class=\"search-row\">
        <input id=\"q\" placeholder=\"🔎 username / IP ရှာရန်\" oninput=\"filterCards()\" style=\"min-width:220px\">
        <span class=\"pill\">Expired: {{ expired_count }}</span>
        <span class=\"pill ok\">Online: {{ online_count }}</span>
     </div>
     <button class=\"btn\" onclick=\"toggleTheme()\">🌓</button>
     <form method=\"post\" action=\"{{ url_for('refresh_status', filter=filter_type) }}\"><button class=\"btn btn-primary\" type=\"submit\">🔄 Scan Status</button></form>
   </div>
 </div>
</header><div class=\"wrap\">{% if filter_type == 'all' %}

<div class=\"count-box\">
  <p>ရက်({{ default_expiry_days }})အတွင်း စုစုပေါင်း အကောင့်ဖွင့်သူ</p>
  <span class=\"number\">{{ total_30_day_users }}</span>
</div><div class=\"box\">
  <h3 style=\"margin:4px 0 8px\">➕ အသုံးပြုသူ အသစ်ထည့်ရန် ({{ default_expiry_days }} ရက် သက်တမ်း)</h3>
  {% if msg %}<div style=\"color:var(--ok);margin:6px 0\">{{msg}}</div>{% endif %}
  {% if err %}<div style=\"color:var(--bad);margin:6px 0\">{{err}}</div>{% endif %}
  <form method=\"post\" action=\"/add\">
    <div class=\"form-inline\">
      <div><label>👤 User</label><input name=\"user\" required></div>
      <div><label>🔑 Password</label><input name=\"password\" required></div>
    </div>
    <div class=\"form-inline\">
        <div class=\"form-inline-full-width\" style=\"display:flex; align-items:center; gap:12px\">
          <div style=\"font-weight:700;color:var(--primary)\">🤖 CAPTCHA: {{ captcha_question }}</div>
          <div style=\"flex:1\"><label>အဖြေ (Bot ကာကွယ်ရန်)</label><input type=\"number\" name=\"captcha_answer\" required></div>
        </div>
    </div>
    <div class=\"form-inline-full-width\"> 
        <button class=\"btn btn-success\" type=\"submit\" style=\"margin-top:12px;width:100%\">Save & Show Info</button>
    </div>
  </form>
</div>
{% endif %}<div class=\"user-list\">
  {% for u in users %}
  {% if u.expires >= today or filter_type == 'all' or filter_type == 'expired' %}
  <div class=\"user-card {% if u.is_expired %}expired{% endif %}\">
    <div class=\"card-header\">
        <div class=\"user-name\">{{u.user}}</div>
        <div class=\"status-block\">
            {% if u.is_expired %}
                 <span class=\"status-dot\"></span><span class=\"status-text expired\">Expired</span>
            {% elif u.status == 'Online' %}
                 <span class=\"status-dot online\"></span><span class=\"status-text online\">Active</span>
            {% else %}
                 <span class=\"status-dot\"></span><span class=\"status-text\">Inactive</span>
            {% endif %}
        </div>
    </div>
    <div class=\"card-details\">⏰ ကုန်ရက်: {% if u.expires %}{{u.expires}}{% else %}—{% endif %}</div>
    <div class=\"card-details\">🔗 ချိတ်ထားသည်: <span data-ip>{% if u.bind_ip %}{{u.bind_ip}}{% else %}—{% endif %}</span></div>
  </div>
  {% endif %}
  {% endfor %}
</div></div>
<footer>
    <div class=\"nav-bar\">
        <div class=\"nav-item\"><a href=\"{{ url_for('index', filter='all') }}\" class=\"nav-link {% if filter_type == 'all' %}active{% endif %}\"> All ({{ total }})</a></div>
        <div class=\"nav-item\"><a href=\"{{ url_for('index', filter='expired') }}\" class=\"nav-link {% if filter_type == 'expired' %}active{% endif %}\"> Expired ({{ expired_count }})</a></div>
        <div class=\"nav-item\"><a href=\"{{ url_for('index', filter='online') }}\" class=\"nav-link {% if filter_type == 'online' %}active{% endif %}\"> Online ({{ online_count }})</a></div>
        <div class=\"nav-item\"><a href=\"https://m.me/upkvpnfastvpn\" target=\"_blank\" rel=\"noopener\" class=\"nav-link\"> Support</a></div>
    </div>
</footer>
{% endif %}
</body></html>
"""----------------------------------------------------------------------------------------------------

APP ROUTES (LOGIN-FREE)

----------------------------------------------------------------------------------------------------

@app.before_request def check_expiry_and_delete(): # Public panel — no login at all. Only skip static requests. if request.path.startswith('/static') or request.path.startswith('/favicon'): return

# Clear stale captcha when landing on index so each visit gets a fresh challenge
if request.endpoint == 'index' and 'captcha_answer' in session:
    session.pop('captcha_answer', None)

# Auto-remove expired accounts (simple mode)
users_data = load_users()
check_and_delete_expired_users(users_data)

@app.route('/', defaults={'filter_type': 'all'}) @app.route('/index', defaults={'filter_type': 'all'}) @app.route('/index/<filter_type>') def index(filter_type): users_data = load_users() today_str = datetime.date.today().strftime('%Y-%m-%d')

users_data = check_and_delete_expired_users(users_data)

# recent count aligned with DEFAULT_EXPIRY_DAYS window
window_ago = (datetime.date.today() - datetime.timedelta(days=DEFAULT_EXPIRY_DAYS)).strftime('%Y-%m-%d')
total_30_day_users = sum(1 for u in users_data if u.get('created_on', '1970-01-01') >= window_ago)

for u in users_data:
    u['expires'] = u.get('expires', '')
    u['is_expired'] = u['expires'] < today_str if u['expires'] else False
    u.update(check_user_status(u['user']))
    u['bind_ip'] = u.get('bind_ip')

users_data = sort_users(users_data)

if filter_type == 'expired':
    filtered_users = [u for u in users_data if u['is_expired']]
elif filter_type == 'online':
    filtered_users = [u for u in users_data if u['status'] == 'Online' and not u['is_expired']]
else:
    filtered_users = users_data

captcha_question = generate_captcha()

return render_template_string(
    HTML,
    users=filtered_users,
    total=len(users_data),
    expired_count=get_expired_count(users_data),
    online_count=get_online_count(users_data),
    today=today_str,
    filter_type=filter_type,
    default_expiry_days=DEFAULT_EXPIRY_DAYS,
    total_30_day_users=total_30_day_users,
    captcha_question=captcha_question,
    msg=request.args.get('msg'),
    err=request.args.get('err')
)

@app.route('/add', methods=['POST']) def add_user(): user = request.form.get('user', '').strip() password = request.form.get('password', '').strip() captcha_input = request.form.get('captcha_answer', '').strip()

# CAPTCHA verify (robust)
expected_answer = session.pop('captcha_answer', None)
try:
    valid_captcha = captcha_input and expected_answer is not None and int(captcha_input) == int(expected_answer)
except ValueError:
    valid_captcha = False
if not valid_captcha:
    return redirect(url_for('index', err="Bot ကာကွယ်ရေး အဖြေ မမှန်ကန်ပါ။"))

if not user or not password:
    return redirect(url_for('index', err="User name နှင့် Password အပြည့်အစုံ ထည့်သွင်းပေးပါ။"))

users_data = load_users()

if any(u.get('user') == user for u in users_data):
    return redirect(url_for('index', err=f"အသုံးပြုသူ {user} သည် ရှိပြီးသား ဖြစ်ပါသည်။"))

expires_date = (datetime.date.today() + datetime.timedelta(days=DEFAULT_EXPIRY_DAYS)).strftime('%Y-%m-%d')
created_date = datetime.date.today().strftime('%Y-%m-%d')

# Random port (ensure no collision in current list)
existing_ports = {u.get('port') for u in users_data if 'port' in u}
port = random.randint(10000, 20000)
attempts = 0
while port in existing_ports and attempts < 50:
    port = random.randint(10000, 20000)
    attempts += 1

new_user = {
    'user': user,
    'password': password,
    'expires': expires_date,
    'created_on': created_date,
    'port': port,
    # Integrate your real ZIVPN create command here if needed.
    # os.system(f'your_zivpn_create_command {user} {password} {expires_date}')
}

users_data.append(new_user)
save_users(users_data)

return render_template_string(
    HTML,
    info_page=True,
    info={'user': user, 'password': password, 'vps_ip': VPS_IP, 'expires': expires_date, 'port': port},
    default_expiry_days=DEFAULT_EXPIRY_DAYS
)

@app.route('/refresh_status', methods=['POST']) def refresh_status(): filter_type = request.args.get('filter', 'all') return redirect(url_for('index', filter=filter_type))

@app.route('/edit/<user>') @app.route('/delete/<user>') def disabled_admin_action(user=None): return render_template_string(HTML, edit_page=True)

if name == 'main': debug = os.getenv('FLASK_DEBUG', '0') == '1' port = int(os.getenv('PORT', '5000')) app.run(debug=debug, host='0.0.0.0', port=port)
