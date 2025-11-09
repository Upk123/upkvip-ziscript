# ... (Existing imports and definitions) ...
# ... (load_users, save_users, etc. functions remain the same as previous revision) ...

# ... (HTML template starts here) ...
# 🚨 MODIFIED: HTML Template (CSS and User List Markup changed to show only Expired status) 🚨
HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta http-equiv="refresh" content="120">
<title>ZIVPN User Panel - DEV-U PHOE KAUNT</title>
<style>
 /* Global & Theme */
 :root{
  --bg:#f8f9fa; --fg:#212529; --muted:#6c757d; --card:#ffffff; --bd:#dee2e6;
  --ok:#198754; --bad:#dc3545; --primary:#0d6efd; 
  --expired-color: #dc3545;
 }
 html,body{background:var(--bg);color:var(--fg)}
 body{font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;margin:0;padding:12px 12px 70px 12px; min-height:100vh}
 .wrap{max-width:800px;margin:0 auto}
 
 /* Header & Navigation */
 header{position:sticky;top:0;background:var(--bg);padding:10px 0 12px;z-index:10;border-bottom:1px solid var(--bd)}
 .header-wrap{display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:space-between}
 h1{margin:0;font-size:18px;font-weight:700}
 .sub{color:var(--muted);font-size:12px}
 
 /* Buttons (Only for Header/Login/Add) */
 .btn{padding:8px 12px;border-radius:8px;border:1px solid var(--btn-border);
      background:var(--btn-light);color:var(--fg);text-decoration:none;cursor:pointer;
      transition: background 0.1s ease; font-weight:500; font-size:13px; text-align:center; display:inline-block;}
 .btn:hover{background:#e9ecef}
 .btn-primary{background:var(--primary);border-color:var(--primary);color:#fff}
 .btn-primary:hover{background:#0b5ed7}
 .btn-success{background:var(--ok);border-color:var(--ok);color:#fff}
 .btn-success:hover{background:#157347}
 
 /* Forms & Boxes */
 .box{margin:14px 0;padding:16px;border:none;border-radius:12px;background:var(--card);box-shadow:0 4px 6px -1px rgba(0,0,0,.1), 0 2px 4px -2px rgba(0,0,0,.1)}
 label{display:block;margin:6px 0 3px;font-size:13px;color:var(--secondary);font-weight:500}
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

 
 /* 🚨 MODIFIED: User List Minimal Text Row Style */
 .user-list{display:flex; flex-direction:column; gap:1px; margin-top:10px; }
 .user-row{
    padding:8px 0;
    border-bottom:1px dashed var(--bd); /* Minimal divider */
 }
 .user-row:last-child { border-bottom: none; }

 /* Username and Status Pill */
 .main-info {
    display: flex;
    justify-content: space-between;
    align-items: flex-start; 
    gap: 8px; 
 }
 .user-name-block {
    display: flex;
    flex-direction: column;
    flex-grow: 1;
 }
 .user-name {
    font-size: 15px;
    font-weight: 700;
    color: var(--fg);
    margin-bottom: 2px; 
 }

 /* Status Pill (Text Only - Only for Expired) */
 .status-pill{
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 700;
    white-space: nowrap;
 }
 /* ONLY KEEP EXPIRED STATUS CSS */
 .status-expired{background:#f8d7da;color:var(--expired-color);font-weight:700;border:1px solid var(--expired-color)}


 /* Expires Date Row */
 .details-expires {
    font-size: 13px;
    color: var(--muted);
 }
 .details-expires.expired-date {
     color: var(--expired-color);
     font-weight: 600;
 }

 /* Remove copy-row styling if any */
 .copy-row {
    display: flex;
    align-items: center;
    gap: 8px;
 }
 .copy-btn {
    padding: 8px;
    font-size: 12px;
 }
</style>
<script>
  // ... (Existing copyToClipboard function - Unchanged) ...
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
  <p>TextView. ရက်(30)အတွင်း စုစုပေါင်း အကောင့်ဖွင့်သူ</p>
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
  
  <div class="user-row">
    
    <div class="main-info">
        <div class="user-name-block">
            <div class="user-name">{{u.user}}</div>
            
            <div class="details-expires {% if u.is_expired %}expired-date{% endif %}">
                ⏰ ကုန်ရက်: {% if u.expires %}{{u.expires}}{% else %}—{% endif %}
            </div>
        </div>
      
        {% if u.is_expired %}<span class="status-pill status-expired">Expired</span>{% endif %}
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

# ... (The rest of the Python code remains identical to the previous revision, including the sorting logic) ...
