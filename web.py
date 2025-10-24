#!/usr/bin/env python3
# ZIVPN Web Panel (Android-friendly, Edit, One-device lock, Counters)
# Author: DEV-U PHOE KAUNT (clean rewrite)

from flask import Flask, jsonify, render_template_string, request, redirect, url_for, session, make_response
import json, subprocess, os, tempfile, hmac, re
from datetime import datetime, timedelta

# ===== Paths / Defaults =====
USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LISTEN_FALLBACK = "5667"
LOGO_URL = os.environ.get(
    "ZIVPN_LOGO_URL",
    "https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png"
)

# ===== Flask app & Admin guard =====
app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET", "dev-secret-change-me")
ADMIN_USER = os.environ.get("WEB_ADMIN_USER", "").strip()
ADMIN_PASS = os.environ.get("WEB_ADMIN_PASSWORD", "").strip()

def login_enabled() -> bool:
    return bool(ADMIN_USER and ADMIN_PASS)

def is_authed() -> bool:
    return session.get("auth") is True

# ===== Small utils =====
def sh(cmd: str):
    """Run shell and return CompletedProcess (text)."""
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def read_json(path: str, default):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return default

def write_json_atomic(path: str, data):
    d = json.dumps(data, ensure_ascii=False, indent=2)
    dirn = os.path.dirname(path)
    os.makedirs(dirn, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=dirn)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(d)
        os.replace(tmp, path)
    finally:
        try:
            os.remove(tmp)
        except Exception:
            pass

# ===== Data helpers =====
def load_users():
    v = read_json(USERS_FILE, [])
    out = []
    for u in v:
        out.append({
            "user": u.get("user", ""),
            "password": u.get("password", ""),
            "expires": u.get("expires", ""),
            "port": str(u.get("port", "")) if str(u.get("port", "")) != "" else "",
            "bind_ip": u.get("bind_ip", "")
        })
    return out

def save_users(users): write_json_atomic(USERS_FILE, users)

def get_listen_port_from_config():
    cfg = read_json(CONFIG_FILE, {})
    listen = str(cfg.get("listen", "")).strip()
    m = re.search(r":(\d+)$", listen) if listen else None
    return (m.group(1) if m else LISTEN_FALLBACK)

def get_udp_listen_ports():
    out = sh("ss -uHln").stdout
    return set(re.findall(r":(\d+)\s", out))

def pick_free_port():
    used = {str(u.get("port", "")) for u in load_users() if str(u.get("port", ""))}
    used |= get_udp_listen_ports()
    for p in range(6000, 20000):
        if str(p) not in used:
            return str(p)
    return ""

# ===== Online/Offline detection =====
def _conntrack_has(port: str) -> bool:
    if not port:
        return False
    out = sh(f"grep -E '\\bdport={port}\\b|\\bsport={port}\\b' /proc/net/nf_conntrack 2>/dev/null | head -n1 || true").stdout
    if out.strip():
        return True
    out2 = sh(f"conntrack -L -p udp 2>/dev/null | grep -E '\\bdport={port}\\b|\\bsport={port}\\b' | head -n1 || true").stdout
    return bool(out2.strip())

def first_recent_src_ip(port: str) -> str:
    if not port:
        return ""
    out = sh(
        "conntrack -L -p udp 2>/dev/null | "
        f"awk \"/dport={port}\\b/ {{for(i=1;i<=NF;i++) if($i~/src=/){{split($i,a,'='); print a[2]; exit}}}}\""
    ).stdout.strip()
    return out if re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", out) else ""

def status_for_user(u, active_ports, listen_port):
    port = str(u.get("port", "")) or listen_port
    if _conntrack_has(port):
        return "Online"
    if port in active_ports:
        return "Offline"
    return "Unknown"

# ===== One-device lock (iptables) =====
def ipt(cmd: str): return sh(cmd)

def ensure_limit_rules(port: str, ip: str):
    if not (port and ip):
        return
    ipt(f"iptables -C INPUT -p udp --dport {port} -s {ip} -j ACCEPT 2>/dev/null") or \
        ipt(f"iptables -I INPUT -p udp --dport {port} -s {ip} -j ACCEPT")
    ipt(f"iptables -C INPUT -p udp --dport {port} ! -s {ip} -j DROP 2>/dev/null") or \
        ipt(f"iptables -I INPUT -p udp --dport {port} ! -s {ip} -j DROP")

def remove_limit_rules(port: str):
    if not port:
        return
    # delete any ACCEPT/DROP rules related to that port
    for _ in range(30):
        line = ipt(
            f"iptables -S INPUT | grep -E \"-p udp .* --dport {port}\\b .* (-j DROP|-j ACCEPT)\" | head -n1 || true"
        ).stdout.strip()
        if not line:
            break
        ipt(f"iptables -D INPUT {line.replace('-A ', '')}")

def apply_device_limits(users):
    for u in users:
        p = str(u.get("port", "") or "")
        ip = (u.get("bind_ip", "") or "").strip()
        if p and ip:
            ensure_limit_rules(p, ip)
        elif p:
            remove_limit_rules(p)

# ===== Mirror passwords -> config.json =====
def sync_config_passwords(mode: str = "mirror"):
    cfg = read_json(CONFIG_FILE, {})
    users = load_users()
    users_pw = sorted({str(u["password"]) for u in users if u.get("password")})
    if mode == "merge":
        old = []
        if isinstance(cfg.get("auth", {}).get("config", None), list):
            old = list(map(str, cfg["auth"]["config"]))
        new_pw = sorted(set(old) | set(users_pw))
    else:
        new_pw = users_pw
    if not isinstance(cfg.get("auth"), dict):
        cfg["auth"] = {}
    cfg["auth"]["mode"] = "passwords"
    cfg["auth"]["config"] = new_pw
    cfg["listen"] = cfg.get("listen") or ":5667"
    cfg["cert"] = cfg.get("cert") or "/etc/zivpn/zivpn.crt"
    cfg["key"] = cfg.get("key") or "/etc/zivpn/zivpn.key"
    cfg["obfs"] = cfg.get("obfs") or "zivpn"
    write_json_atomic(CONFIG_FILE, cfg)
    sh("systemctl restart zivpn.service")

# ===== UI =====
HTML = """<!doctype html><html lang="my"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>ZIVPN Panel</title>
<style>
:root{--bg:#0b0f14;--fg:#e6edf3;--muted:#9aa7b3;--card:#101724;--bd:#1e293b;--ok:#22c55e;--bad:#ef4444;--unk:#9ca3af;--chip:#0f172a}
html,body{background:var(--bg);color:var(--fg)}
body{font-family:system-ui,Segoe UI,Roboto,'Noto Sans Myanmar',sans-serif;margin:0;padding:14px}
.wrap{max-width:1000px;margin:0 auto}
header{display:flex;gap:12px;align-items:center;margin-bottom:12px}
h1{margin:0;font-size:20px;font-weight:800}
.sub{color:var(--muted);font-size:12px}
.btn{padding:9px 12px;border-radius:999px;border:1px solid var(--bd);background:#0e1623;color:var(--fg);text-decoration:none;cursor:pointer}
.box{margin:12px 0;padding:12px;border:1px solid var(--bd);border-radius:14px;background:var(--card)}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid var(--bd);padding:10px;text-align:left}
th{background:#0c1420;font-size:12.5px}
td{font-size:14px}
.pill{display:inline-block;padding:4px 10px;border-radius:999px}
.ok{background:var(--ok);color:#071a0c}.bad{background:var(--bad);color:#1c0505}.unk{background:var(--unk);color:#111}
input{width:100%;max-width:420px;padding:10px;border:1px solid var(--bd);border-radius:12px;background:#0a1220;color:var(--fg)}
.form-inline{display:flex;gap:10px;flex-wrap:wrap}.form-inline>div{min-width:180px;flex:1}
.chips{display:flex;gap:8px;flex-wrap:wrap}
.chip{background:var(--chip);border:1px solid var(--bd);border-radius:999px;padding:8px 12px;font-size:13px}
.chip b{font-size:14px;margin-left:6px}
@media(max-width:480px){ th,td{font-size:13px} .btn{padding:9px 10px} body{padding:10px} }
</style></head><body>
<div class="wrap">
<header>
  <img src="{{logo}}" style="height:40px;border-radius:10px" alt="logo">
  <div style="flex:1">
    <h1>ZIVPN Panel</h1>
    <div class="sub">DEV-U PHOE KAUNT</div>
  </div>
  {% if authed %}<a class="btn" href="/logout">Logout</a>{% endif %}
</header>

{% if not authed %}
  <div class="box" style="max-width:440px;margin:40px auto">
    {% if err %}<div style="color:var(--bad);margin-bottom:8px">{{err}}</div>{% endif %}
    <form method="post" action="/login">
      <label>Username</label><input name="u" autofocus required>
      <label style="margin-top:8px">Password</label><input name="p" type="password" required>
      <button class="btn" type="submit" style="margin-top:12px;width:100%">Login</button>
    </form>
  </div>
{% else %}

<div class="chips" style="margin:6px 0 10px">
  <div class="chip">Total<b>{{counts.total}}</b></div>
  <div class="chip">Online<b>{{counts.online}}</b></div>
  <div class="chip">Offline<b>{{counts.offline}}</b></div>
  <div class="chip">Expired<b>{{counts.expired}}</b></div>
</div>

<div class="box">
  <h3 style="margin:4px 0 8px">➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
  {% if msg %}<div style="color:var(--ok);margin:6px 0">{{msg}}</div>{% endif %}
  {% if err %}<div style="color:var(--bad);margin:6px 0">{{err}}</div>{% endif %}
  <form method="post" action="/add" class="form-inline">
    <div><label>👤 User</label><input name="user" required></div>
    <div><label>🔑 Password</label><input name="password" required></div>
    <div><label>⏰ Expires</label><input name="expires" placeholder="2025-12-31 or 30"></div>
    <div><label>🔌 UDP Port</label><input name="port" placeholder="auto"></div>
    <div><label>📱 Bind IP (1 device)</label><input name="bind_ip" placeholder="auto when online…"></div>
    <div style="align-self:end"><button class="btn" type="submit">Save + Sync</button></div>
  </form>
</div>

<table>
  <tr>
    <th>👤 User</th><th>🔑 Password</th><th>⏰ Expires</th>
    <th>🔌 Port</th><th>📱 Bind IP</th><th>🔎 Status</th><th>✏️ Edit</th><th>🗑️ Delete</th>
  </tr>
  {% for u in users %}
  <tr>
    <td>{{u.user}}</td>
    <td>{{u.password}}</td>
    <td>{% if u.expires %}{{u.expires}}{% else %}<span style="opacity:.6">—</span>{% endif %}</td>
    <td>{{u.port or "—"}}</td>
    <td>{{u.bind_ip or "—"}}</td>
    <td>{% if u.status=="Online" %}<span class="pill ok">Online</span>{% elif u.status=="Offline" %}<span class="pill bad">Offline</span>{% else %}<span class="pill unk">Unknown</span>{% endif %}</td>
    <td>
      <form method="get" action="/edit" style="display:inline">
        <input type="hidden" name="user" value="{{u.user}}">
        <button class="btn" type="submit">Edit</button>
      </form>
    </td>
    <td>
      <form method="post" action="/delete" onsubmit="return confirm('ဖျက်မလား?')" style="display:inline">
        <input type="hidden" name="user" value="{{u.user}}">
        <button class="btn" style="background:#2a0f0f;border-color:#3b1d1d">Delete</button>
      </form>
    </td>
  </tr>
  {% endfor %}
</table>

{% endif %}
</div>
</body></html>
"""

# ===== View builder =====
def build_view(msg: str = "", err: str = ""):
    if login_enabled() and not is_authed():
        return render_template_string(
            HTML, authed=False, logo=LOGO_URL,
            err=session.pop("login_err", None),
            counts={"total": 0, "online": 0, "offline": 0, "expired": 0},
            users=[]
        )

    users = load_users()

    # Auto-bind first src IP when online and bind_ip empty
    changed = False
    for u in users:
        if u.get("port") and not u.get("bind_ip"):
            ip = first_recent_src_ip(str(u["port"]))
            if ip:
                u["bind_ip"] = ip
                changed = True
    if changed:
        save_users(users)

    apply_device_limits(users)

    active = get_udp_listen_ports()
    listen_port = get_listen_port_from_config()

    view = []
    today = datetime.now().strftime("%Y-%m-%d")
    counts = {"total": 0, "online": 0, "offline": 0, "expired": 0}
    for u in users:
        st = status_for_user(u, active, listen_port)
        counts["total"] += 1
        if st == "Online":
            counts["online"] += 1
        elif st == "Offline":
            counts["offline"] += 1
        if u.get("expires") and str(u["expires"]) < today:
            counts["expired"] += 1
        view.append(type("U", (), {
            "user": u.get("user", ""),
            "password": u.get("password", ""),
            "expires": u.get("expires", ""),
            "port": u.get("port", ""),
            "bind_ip": u.get("bind_ip", ""),
            "status": st
        }))
    view.sort(key=lambda x: (x.user or "").lower())

    return render_template_string(
        HTML, authed=True, logo=LOGO_URL, users=view, msg=msg, err=err, counts=counts
    )

# ===== Routes =====
@app.route("/login", methods=["GET", "POST"])
def login():
    if not login_enabled():
        return redirect(url_for('index'))
    if request.method == "POST":
        u = (request.form.get("u") or "").strip()
        p = (request.form.get("p") or "").strip()
        if hmac.compare_digest(u, ADMIN_USER) and hmac.compare_digest(p, ADMIN_PASS):
            session["auth"] = True
            return redirect(url_for('index'))
        session["auth"] = False
        session["login_err"] = "မှန်ကန်မှုမရှိပါ (username/password)"
        return redirect(url_for('login'))
    return render_template_string(
        HTML, authed=False, logo=LOGO_URL,
        err=session.pop("login_err", None),
        counts={"total": 0, "online": 0, "offline": 0, "expired": 0},
        users=[]
    )

@app.route("/logout", methods=["GET"])
def logout():
    session.pop("auth", None)
    return redirect(url_for('login') if login_enabled() else url_for('index'))

@app.route("/", methods=["GET"])
def index():
    return build_view()

@app.route("/add", methods=["POST"])
def add_user():
    if login_enabled() and not is_authed():
        return redirect(url_for('login'))
    user = (request.form.get("user") or "").strip()
    password = (request.form.get("password") or "").strip()
    expires = (request.form.get("expires") or "").strip()
    port = (request.form.get("port") or "").strip()
    bind_ip = (request.form.get("bind_ip") or "").strip()

    if expires.isdigit():
        expires = (datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")

    if not user or not password:
        return build_view(err="User/Password လိုအပ်")
    if port:
        if not re.fullmatch(r"\d{2,5}", port) or not (6000 <= int(port) <= 19999):
            return build_view(err="Port 6000–19999")
    else:
        port = pick_free_port()

    users = load_users()
    replaced = False
    for u in users:
        if u.get("user", "").lower() == user.lower():
            u.update({"password": password, "expires": expires, "port": port, "bind_ip": bind_ip})
            replaced = True
            break
    if not replaced:
        users.append({"user": user, "password": password, "expires": expires, "port": port, "bind_ip": bind_ip})

    save_users(users)
    sync_config_passwords()
    return build_view(msg="Saved & Synced")

@app.route("/edit", methods=["GET", "POST"])
def edit_user():
    if login_enabled() and not is_authed():
        return redirect(url_for('login'))
    if request.method == "GET":
        q = (request.args.get("user") or "").strip().lower()
        users = load_users()
        target = [u for u in users if u.get("user", "").lower() == q]
        if not target:
            return build_view(err="မတွေ့ပါ")
        u = target[0]
        frm = f"""<div class='box'><h3>✏️ Edit: {u.get('user')}</h3>
        <form method='post' action='/edit' class='form-inline'>
          <input type='hidden' name='orig' value='{u.get('user')}'>
          <div><label>👤 User</label><input name='user' value='{u.get('user')}' required></div>
          <div><label>🔑 Password</label><input name='password' value='{u.get('password')}' required></div>
          <div><label>⏰ Expires</label><input name='expires' value='{u.get('expires','')}' placeholder='2025-12-31 or 30'></div>
          <div><label>🔌 UDP Port</label><input name='port' value='{u.get('port','')}'></div>
          <div><label>📱 Bind IP</label><input name='bind_ip' value='{u.get('bind_ip','')}' placeholder='blank = no lock'></div>
          <div style='align-self:end'><button class='btn' type='submit'>Save</button> <a class='btn' href='/'>Cancel</a></div>
        </form></div>"""
        base = build_view()
        return base.replace("</div>\n</body>", "</div>" + frm + "</body>")

    orig = (request.form.get("orig") or "").strip().lower()
    user = (request.form.get("user") or "").strip()
    password = (request.form.get("password") or "").strip()
    expires = (request.form.get("expires") or "").strip()
    port = (request.form.get("port") or "").strip()
    bind_ip = (request.form.get("bind_ip") or "").strip()

    if expires.isdigit():
        expires = (datetime.now() + timedelta(days=int(expires))).strftime("%Y-%m-%d")
    if not user or not password:
        return build_view(err="User/Password လိုအပ်")
    if port and (not re.fullmatch(r"\d{2,5}", port) or not (6000 <= int(port) <= 19999)):
        return build_view(err="Port 6000–19999")

    users = load_users()
    found = False
    for u in users:
        if u.get("user", "").lower() == orig:
            oldp = u.get("port")
            oldip = u.get("bind_ip", "")
            if oldp and (str(oldp) != str(port) or oldip != bind_ip):
                remove_limit_rules(oldp)
            u.update({"user": user, "password": password, "expires": expires, "port": port, "bind_ip": bind_ip})
            found = True
            break
    if not found:
        return build_view(err="မတွေ့ပါ")
    save_users(users)
    sync_config_passwords()
    return redirect(url_for('index'))

@app.route("/lock", methods=["POST"])
def lock_now():
    if login_enabled() and not is_authed():
        return redirect(url_for('login'))
    user = (request.form.get("user") or "").strip().lower()
    op = (request.form.get("op") or "").strip()
    users = load_users()
    for u in users:
        if u.get("user", "").lower() == user:
            p = u.get("port", "")
            if op == "clear":
                u["bind_ip"] = ""
                save_users(users)
                apply_device_limits(users)
                return build_view(msg=f"Cleared lock for {u['user']}")
            ip = first_recent_src_ip(str(p))
            if not ip:
                return build_view(err="UDP traffic မတွေ့ — client ချိတ်ပြီး Lock now ကိုပြန်နှိပ်")
            u["bind_ip"] = ip
            save_users(users)
            apply_device_limits(users)
            return build_view(msg=f"Locked {u['user']} to {ip}")
    return build_view(err="မတွေ့ပါ")

@app.route("/delete", methods=["POST"])
def delete_user_html():
    if login_enabled() and not is_authed():
        return redirect(url_for('login'))
    user = (request.form.get("user") or "").strip()
    if not user:
        return build_view(err="User လိုအပ်")
    remain = []
    removed = None
    for u in load_users():
        if u.get("user", "").lower() == user.lower():
            removed = u
        else:
            remain.append(u)
    if removed and removed.get("port"):
        remove_limit_rules(removed.get("port"))
    save_users(remain)
    sync_config_passwords(mode="mirror")
    return build_view(msg=f"Deleted: {user}")

@app.route("/api/users", methods=["GET"])
def api_users():
    if login_enabled() and not is_authed():
        return make_response(jsonify({"ok": False, "err": "login required"}), 401)
    users = load_users()
    active = get_udp_listen_ports()
    listen_port = get_listen_port_from_config()
    for u in users:
        u["status"] = status_for_user(u, active, listen_port)
    return jsonify(users)

@app.errorhandler(405)
def handle_405(e):
    return redirect(url_for('index'))

if __name__ == "__main__":
    # Bind 0.0.0.0 so external browser can reach it
    app.run(host="0.0.0.0", port=8080).sub{color:var(--muted);font-size:12px}
.btn{padding:9px 12px;border-radius:999px;border:1px solid var(--bd);background:#0e1623;color:var(--fg);text-decoration:none}
.box{margin:12px 0;padding:12px;border:1px solid var(--bd);border-radius:14px;background:var(--card)}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid var(--bd);padding:10px;text-align:left}
th{background:#0c1420;font-size:12.5px}
td{font-size:14px}
.pill{display:inline-block;padding:4px 10px;border-radius:999px}
.ok{background:var(--ok);color:#071a0c}.bad{background:var(--bad);color:#1c0505}.unk{background:var(--unk);color:#111}
input{width:100%;max-width:420px;padding:10px;border:1px solid var(--bd);border-radius:12px;background:#0a1220;color:var(--fg)}
.form-inline{display:flex;gap:10px;flex-wrap:wrap}.form-inline>div{min-width:180px;flex:1}
.chips{display:flex;gap:8px;flex-wrap:wrap}
.chip{background:var(--chip);border:1px solid var(--bd);border-radius:999px;padding:8px 12px;font-size:13px}
.chip b{font-size:14px;margin-left:6px}
@media(max-width:480px){ th,td{font-size:13px} .btn{padding:9px 10px} body{padding:10px} }
</style></head><body>
<div class="wrap">
<header>
  <img src="{{logo}}" style="height:40px;border-radius:10px">
  <div style="flex:1">
    <h1>ZIVPN Panel</h1>
    <div class="sub">DEV-U PHOE KAUNT</div>
  </div>
  {% if authed %}<a class="btn" href="/logout">Logout</a>{% endif %}
</header>

{% if not authed %}
  <div class="box" style="max-width:440px;margin:40px auto">
    {% if err %}<div style="color:var(--bad);margin-bottom:8px">{{err}}</div>{% endif %}
    <form method="post" action="/login">
      <label>Username</label><input name="u" autofocus required>
      <label style="margin-top:8px">Password</label><input name="p" type="password" required>
      <button class="btn" type="submit" style="margin-top:12px;width:100%">Login</button>
    </form>
  </div>
{% else %}

<div class="chips" style="margin:6px 0 10px">
  <div class="chip">Total<b>{{counts.total}}</b></div>
  <div class="chip">Online<b>{{counts.online}}</b></div>
  <div class="chip">Offline<b>{{counts.offline}}</b></div>
  <div class="chip">Expired<b>{{counts.expired}}</b></div>
</div>

<div class="box">
  <h3 style="margin:4px 0 8px">➕ အသုံးပြုသူ အသစ်ထည့်ရန်</h3>
  {% if msg %}<div style="color:var(--ok);margin:6px 0">{{msg}}</div>{% endif %}
  {% if err %}<div style="color:var(--bad);margin:6px 0">{{err}}</div>{% endif %}
  <form method="post" action="/add" class="form-inline">
    <div><label>👤 User</label><input name="user" required></div>
    <div><label>🔑 Password</label><input name="password" required></div>
    <div><label>⏰ Expires</label><input name="expires" placeholder="2025-12-31 or 30"></div>
    <div><label>🔌 UDP Port</label><input name="port" placeholder="auto"></div>
    <div><label>📱 Bind IP (1 device)</label><input name="bind_ip" placeholder="auto when online…"></div>
    <div style="align-self:end"><button class="btn" type="submit">Save + Sync</button></div>
  </form>
</div>

<table>
  <tr>
    <th>👤 User</th><th>🔑 Password</th><th>⏰ Expires</th>
    <th>🔌 Port</th><th>📱 Bind IP</th><th>🔎 Status</th><th>✏️ Edit</th><th>🗑️ Delete</th>
  </tr>
  {% for u in users %}
  <tr>
    <td>{{u.user}}</td>
    <td>{{u.password}}</td>
    <td>{% if u.expires %}{{u.expires}}{% else %}<span style="opacity:.6">—</span>{% endif %}</td>
    <td>{{u.port or "—"}}</td>
    <td>{{u.bind_ip or "—"}}</td>
    <td>{% if u.status=="Online" %}<span class="pill ok">Online</span>{% elif u.status=="Offline" %}<span class="pill bad">Offline</span>{% else %}<span class="pill unk">Unknown</span>{% endif %}</td>
    <td>
      <form method="get" action="/edit" style="display:inline">
        <input type="hidden" name="user" value="{{u.user}}">
        <button class="btn" type="submit">Edit</button>
      </form>
    </td>
    <td>
      <form method="post" action="/delete" onsubmit="return confirm('ဖျက်မလား?')" style="display:inline">
        <input type="hidden" name="user" value="{{u.user}}">
        <button class="btn" style="background:#2a0f0f;border-color:#3b1d1d">Delete</button>
      </form>
    </td>
  </tr>
  {% endfor %}
</table>

{% endif %}
</div>
</body></html>
"""

# ===== view builder =====
def build_view(msg="", err=""):
  if login_enabled() and session.get("auth")!=True:
    return render_template_string(HTML, authed=False, logo=LOGO_URL, err=session.pop("login_err", None), counts={"total":0,"online":0,"offline":0,"expired":0}, users=[])
  users=load_users()

  # auto-bind IP when traffic exists & bind_ip empty
  changed=False
  for u in users:
    if u.get("port") and not u.get("bind_ip"):
      # try to grab first observed src IP for that port
      out=sh(f"conntrack -L -p udp 2>/dev/null | awk \"/dport={u['port']}\\b/ {{for(i=1;i<=NF;i++) if($i~/src=/){{split($i,a,'='); print a[2]; exit}}}}\"").stdout.strip()
      if out and re.fullmatch(r'(?:\d{1,3}\.){3}\d{1,3}', out):
        u["bind_ip"]=out; changed=True
  if changed: save_users(users)

  apply_device_limits(users)

  active=get_udp_listen_ports()
  listen_port=get_listen_port_from_config()

  view=[]
  today=datetime.now().strftime("%Y-%m-%d")
  counts={"total":0,"online":0,"offline":0,"expired":0}
  for u in users:
    st=status_for_user(u, active, listen_port)
    counts["total"]+=1
    if st=="Online": counts["online"]+=1
    elif st=="Offline": counts["offline"]+=1
    if u.get("expires") and u["expires"]<today: counts["expired"]+=1
    view.append(type("U",(),{
      "user":u.get("user",""),
      "password":u.get("password",""),
      "expires":u.get("expires",""),
      "port":u.get("port",""),
      "bind_ip":u.get("bind_ip",""),
      "status":st
    }))
  view.sort(key=lambda x:(x.user or "").lower())
  return render_template_string(HTML, authed=True, logo=LOGO_URL, users=view, msg=msg, err=err, counts=counts)

# ===== routes =====
@app.route("/login", methods=["GET","POST"])
def login():
  if not login_enabled(): return redirect(url_for('index'))
  if request.method=="POST":
    u=(request.form.get("u") or "").strip()
    p=(request.form.get("p") or "").strip()
    if hmac.compare_digest(u, ADMIN_USER) and hmac.compare_digest(p, ADMIN_PASS):
      session["auth"]=True; return redirect(url_for('index'))
    session["auth"]=False; session["login_err"]="မှန်ကန်မှုမရှိပါ (username/password)"; return redirect(url_for('login'))
  return render_template_string(HTML, authed=False, logo=LOGO_URL, err=session.pop("login_err", None), counts={"total":0,"online":0,"offline":0,"expired":0}, users=[])

@app.route("/logout", methods=["GET"])
def logout():
  session.pop("auth", None)
  return redirect(url_for('login') if login_enabled() else url_for('index'))

@app.route("/", methods=["GET"])
def index(): return build_view()

@app.route("/add", methods=["POST"])
def add_user():
  if login_enabled() and session.get("auth")!=True: return redirect(url_for('login'))
  user=(request.form.get("user") or "").strip()
  password=(request.form.get("password") or "").strip()
  expires=(request.form.get("expires") or "").strip()
  port=(request.form.get("port") or "").strip()
  bind_ip=(request.form.get("bind_ip") or "").strip()

  if expires.isdigit(): expires=(datetime.now()+timedelta(days=int(expires))).strftime("%Y-%m-%d")
  if not user or not password: return build_view(err="User/Password လိုအပ်")
  if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)): return build_view(err="Port 6000–19999")
  if not port: port=pick_free_port()

  users=load_users(); rep=False
  for u in users:
    if u.get("user","").lower()==user.lower():
      u.update({"password":password,"expires":expires,"port":port,"bind_ip":bind_ip}); rep=True; break
  if not rep: users.append({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip})
  save_users(users); sync_config_passwords()
  return build_view(msg="Saved & Synced")

@app.route("/edit", methods=["GET","POST"])
def edit_user():
  if login_enabled() and session.get("auth")!=True: return redirect(url_for('login'))
  if request.method=="GET":
    q=(request.args.get("user") or "").strip().lower()
    users=load_users(); t=[u for u in users if u.get("user","").lower()==q]
    if not t: return build_view(err="မတွေ့ပါ")
    u=t[0]
    frm=f"""<div class='box'><h3>✏️ Edit: {u.get('user')}</h3>
    <form method='post' action='/edit' class='form-inline'>
      <input type='hidden' name='orig' value='{u.get('user')}'>
      <div><label>👤 User</label><input name='user' value='{u.get('user')}' required></div>
      <div><label>🔑 Password</label><input name='password' value='{u.get('password')}' required></div>
      <div><label>⏰ Expires</label><input name='expires' value='{u.get('expires','')}' placeholder='2025-12-31 or 30'></div>
      <div><label>🔌 UDP Port</label><input name='port' value='{u.get('port','')}'></div>
      <div><label>📱 Bind IP</label><input name='bind_ip' value='{u.get('bind_ip','')}' placeholder='blank = no lock'></div>
      <div style='align-self:end'><button class='btn' type='submit'>Save</button> <a class='btn' href='/'>Cancel</a></div>
    </form></div>"""
    base=build_view(); return base.replace("</div>\n</body>","</div>"+frm+"</body>")
  orig=(request.form.get("orig") or "").strip().lower()
  user=(request.form.get("user") or "").strip()
  password=(request.form.get("password") or "").strip()
  expires=(request.form.get("expires") or "").strip()
  port=(request.form.get("port") or "").strip()
  bind_ip=(request.form.get("bind_ip") or "").strip()
  if expires.isdigit(): expires=(datetime.now()+timedelta(days=int(expires))).strftime("%Y-%m-%d")
  if not user or not password: return build_view(err="User/Password လိုအပ်")
  if port and (not re.fullmatch(r"\d{2,5}",port) or not (6000<=int(port)<=19999)): return build_view(err="Port 6000–19999")

  users=load_users(); found=False
  for u in users:
    if u.get("user","").lower()==orig:
      oldp=u.get("port"); oldip=u.get("bind_ip","")
      if oldp and (str(oldp)!=str(port) or oldip!=bind_ip): remove_limit_rules(oldp)
      u.update({"user":user,"password":password,"expires":expires,"port":port,"bind_ip":bind_ip}); found=True; break
  if not found: return build_view(err="မတွေ့ပါ")
  save_users(users); sync_config_passwords()
  return redirect(url_for('index'))

@app.route("/lock", methods=["POST"])
def lock_now():
  if login_enabled() and session.get("auth")!=True: return redirect(url_for('login'))
  user=(request.form.get("user") or "").strip().lower()
  op=(request.form.get("op") or "").strip()
  users=load_users()
  for u in users:
    if u.get("user","").lower()==user:
      p=u.get("port","")
      if op=="clear":
        u["bind_ip"]=""; save_users(users); apply_device_limits(users)
        return build_view(msg=f"Cleared lock for {u['user']}")
      # try recent IP
      out=sh(f"conntrack -L -p udp 2>/dev/null | awk \"/dport={p}\\b/ {{for(i=1;i<=NF;i++) if($i~/src=/){{split($i,a,'='); print a[2]; exit}}}}\"").stdout.strip()
      if not out: return build_view(err="UDP traffic မတွေ့ — client ချိတ်ပြီး Lock now ကိုပြန်နှိပ်")
      u["bind_ip"]=out; save_users(users); apply_device_limits(users)
      return build_view(msg=f"Locked {u['user']} to {out}")
  return build_view(err="မတွေ့ပါ")

@app.route("/delete", methods=["POST"])
def delete_user_html():
  if login_enabled() and session.get("auth")!=True: return redirect(url_for('login'))
  user=(request.form.get("user") or "").strip()
  if not user: return build_view(err="User လိုအပ်")
  remain=[]; removed=None
  for u in load_users():
    if u.get("user","").lower()==user.lower(): removed=u
    else: remain.append(u)
  if removed and removed.get("port"): remove_limit_rules(removed.get("port"))
  save_users(remain); sync_config_passwords(mode="mirror")
  return build_view(msg=f"Deleted: {user}")

@app.route("/api/users", methods=["GET"])
def api_users():
  if login_enabled() and session.get("auth")!=True:
    return make_response(jsonify({"ok": False, "err":"login required"}), 401)
  users=load_users(); active=get_udp_listen_ports(); listen_port=get_listen_port_from_config()
  for u in users: u["status"]=status_for_user(u,active,listen_port)
  return jsonify(users)

@app.errorhandler(405)
def handle_405(e): return redirect(url_for('index'))

if __name__ == "__main__":
  app.run(host="0.0.0.0", port=8080)
PY

systemctl restart zivpn-web
'
