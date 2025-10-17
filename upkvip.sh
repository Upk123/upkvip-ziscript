# 1) backup
sudo cp -a /etc/zivpn/web.py /etc/zivpn/web.py.bak.$(date +%F-%H%M) 2>/dev/null || true

# 2) write new web.py with Myanmar UI + Text view
sudo tee /etc/zivpn/web.py >/dev/null <<'PY'
from flask import Flask, jsonify, render_template_string, Response
import json, re, subprocess, os

USERS_FILE = "/etc/zivpn/users.json"

HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<title>ZIVPN User Panel</title>
<meta http-equiv="refresh" content="10">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Noto+Sans+Myanmar:wght@400;600;700&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#0f172a; --card:#111827; --muted:#9ca3af; --ok:#22c55e; --bad:#ef4444; --acc:#38bdf8;
}
*{box-sizing:border-box}
body{
  margin:0; padding:0 20px 40px;
  font-family:"Noto Sans Myanmar", system-ui, Segoe UI, Roboto, Arial, "Myanmar Sans Pro";
  color:#e5e7eb; background:linear-gradient(180deg,#0b1220, #0f172a 60%, #0b1220);
}
.header{
  max-width:980px; margin:24px auto;
  background:linear-gradient(135deg,#0ea5e9 0%,#22c55e 100%);
  color:#0b1220; border-radius:18px; padding:18px 20px; box-shadow:0 10px 30px rgba(0,0,0,.25);
}
.h-title{font-size:28px; font-weight:800; letter-spacing:.3px}
.h-sub{opacity:.9; margin-top:6px}
.badge{display:inline-block; font-size:12px; padding:4px 10px; border-radius:999px; background:#0b1220; color:#a7f3d0; margin-left:8px}

.card{max-width:980px; margin:18px auto; background:var(--card); border:1px solid rgba(255,255,255,.06); border-radius:16px; overflow:hidden}
.tbl{width:100%; border-collapse:collapse}
.tbl th,.tbl td{padding:10px 12px; border-bottom:1px solid rgba(255,255,255,.06); text-align:left}
.tbl th{background:#0b1220; color:#cbd5e1; font-weight:700}
.status-ok{color:var(--ok); font-weight:700}
.status-bad{color:var(--bad); font-weight:700}
.status-mut{color:var(--muted); font-weight:600}
.note{max-width:980px; margin:8px auto 0; color:var(--muted); font-size:13px}
.actions{max-width:980px; margin:10px auto 0; display:flex; gap:10px; flex-wrap:wrap}
.btn{border:1px solid rgba(255,255,255,.12); background:#0b1220; color:#cbd5e1; padding:8px 12px; border-radius:10px; text-decoration:none}
.btn:hover{border-color:#38bdf8; color:#e0f2fe}
.footer{max-width:980px; margin:20px auto 0; color:#94a3b8; font-size:12px}
.brand{color:#e2f0ff; font-weight:700}
</style></head>
<body>
  <div class="header">
    <div class="h-title">ZIVPN VPN (UDP) — Control Panel
      <span class="badge">U Phue Kaunt မှ ပြန်လည် ပြုစုပြင်ဆင်ရေးသားထားသည်</span>
    </div>
    <div class="h-sub">တင်ထားသော အသုံးပြုသူများ၏ သက်တမ်း/အွန်လိုင်းအခြေအနေ ကို မိနစ်တိုင်း အလိုအလျောက် ပြန်လည် تازهတင် ပြသပေးပါသည်။</div>
  </div>

  <div class="card">
    <table class="tbl">
      <tr>
        <th style="width:32%">👤 အသုံးပြုသူ (User)</th>
        <th style="width:38%">⏳ သက်တမ်းကုန်ချိန် (Expires)</th>
        <th>📶 အခြေအနေ (Status)</th>
      </tr>
      {% if not users %}
      <tr><td colspan="3" class="status-mut">/etc/zivpn/users.json ထဲတွင် user မရှိသေးပါ — ဥပမာ
      {"user":"demo","pass":"demo123","expires":"2026-12-31T23:59:59+07:00","port":6001}</td></tr>
      {% endif %}
      {% for u in users %}
      <tr>
        <td>{{u.user}}</td>
        <td>{{u.expires}}</td>
        <td>
          {% if u.status=="Online" %}<span class="status-ok">Online</span>
          {% elif u.status=="Offline" %}<span class="status-bad">Offline</span>
          {% else %}<span class="status-mut">Unknown</span>
          {% endif %}
        </td>
      </tr>
      {% endfor %}
    </table>
  </div>

  <div class="actions">
    <a class="btn" href="/text">📝 Text View (မြန်မာ)</a>
    <a class="btn" href="/api/users">🔗 JSON API</a>
  </div>

  <div class="note">မှတ်ချက် — အွန်လိုင်း/အော့ဖ်လိုင်း ကို တိတိကျကျ ပြချင်ရင် users.json ထဲတွင်
  <b>"port": 6001</b> စသည်ဖြင့် client သုံးမယ့် UDP port ကို သတ်မှတ်ပေးပါ။</div>

  <div class="footer">© ZIVPN • Crafted with <span class="brand">U Phue Kaunt</span></div>
</body></html>
"""

app = Flask(__name__)

def load_users():
    try:
        with open(USERS_FILE,"r") as f:
            return json.load(f)
    except Exception:
        return []

def get_udp_ports():
    out = subprocess.run("ss -uHapn", shell=True, capture_output=True, text=True).stdout
    return set(re.findall(r":(\d+)\s", out))

@app.route("/")
def index():
    users = load_users()
    active = get_udp_ports()
    view = []
    for u in users:
        port = str(u.get("port",""))
        if port:
            status = "Online" if port in active else "Offline"
        else:
            status = "Unknown"
        view.append(type("U", (), {"user":u.get("user",""), "expires":u.get("expires",""), "status":status}))
    view.sort(key=lambda x: x.user.lower())
    return render_template_string(HTML, users=view)

@app.route("/api/users")
def api_users():
    users = load_users()
    active = get_udp_ports()
    for u in users:
        p = str(u.get("port",""))
        u["status"] = ("Online" if p in active else ("Offline" if p else "Unknown"))
    return jsonify(users)

# ➕ Text view in Burmese
@app.route("/text")
def text_view():
    users = load_users()
    active = get_udp_ports()
    lines = ["ZIVPN (UDP) — မြန်မာ Text View",
             "U Phue Kaunt မှ ပြန်လည် ပြုစုပြင်ဆင်ရေးသားထားသည်",
             "---------------------------------------"]
    if not users:
        lines.append("users.json တွင် user မရှိသေးပါ")
    for u in users:
        name = u.get("user","")
        exp  = u.get("expires","")
        p    = str(u.get("port",""))
        st   = ("Online" if (p and p in active) else ("Offline" if p else "Unknown"))
        lines.append(f"👤 {name} | ⏳ {exp} | 📶 {st}")
    txt = "\n".join(lines) + "\n"
    return Response(txt, mimetype="text/plain; charset=utf-8")

if __name__ == "__main__":
    port = int(os.environ.get("PORT","8080"))
    app.run(host="0.0.0.0", port=port)
PY

# 3) restart web service
sudo systemctl daemon-reload
sudo systemctl restart zivpn-web
sudo systemctl status zivpn-web --no-pager -n 10
