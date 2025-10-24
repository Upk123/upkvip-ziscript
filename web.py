from flask import Flask, jsonify, render_template_string, request, redirect, url_for, session, make_response
import json, subprocess, os, tempfile, hmac, re
from datetime import datetime, timedelta

# ===== Paths =====
USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LISTEN_FALLBACK = "5667"
LOGO_URL = "https://raw.githubusercontent.com/Upk123/upkvip-ziscript/refs/heads/main/20251018_231111.png"

# ===== App / Admin =====
app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET","dev-secret-change-me")
ADMIN_USER = os.environ.get("WEB_ADMIN_USER","").strip()
ADMIN_PASS = os.environ.get("WEB_ADMIN_PASSWORD","").strip()

# ===== Utils =====
def read_json(path, default):
    try:
        with open(path,"r") as f: return json.load(f)
    except Exception:
        return default

def write_json_atomic(path, data):
    d=json.dumps(data, ensure_ascii=False, indent=2)
    dirn=os.path.dirname(path); os.makedirs(dirn, exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=".tmp-", dir=dirn)
    try:
        with os.fdopen(fd,"w") as f: f.write(d)
        os.replace(tmp,path)
    finally:
        try: os.remove(tmp)
        except: pass

def shell(cmd: str):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def get_listen_port_from_config():
    cfg=read_json(CONFIG_FILE,{})
    listen=str(cfg.get("listen","")).strip()
    m=re.search(r":(\d+)$", listen) if listen else None
    return (m.group(1) if m else LISTEN_FALLBACK)

def get_udp_listen_ports():
    out=shell("ss -uHln").stdout
    return set(re.findall(r":(\d+)\s", out))

def pick_free_port():
    used={str(u.get("port","")) for u in read_json(USERS_FILE,[]) if str(u.get("port",""))}
    used |= get_udp_listen_ports()
    for p in range(6000,20000):
        if str(p) not in used: return str(p)
    return ""

def has_recent_udp_activity(port):
    if not port: return False
    out=shell(f"conntrack -L -p udp 2>/dev/null | grep -w \"dport={port}\" | head -n1 || true").stdout
    return bool(out.strip())

def first_recent_src_ip(port):
    if not port: return ""
    awk = r"""awk "/dport="""+str(port)+r"""\b/ {for(i=1;i<=NF;i++) if(\$i~/src=/){split(\$i,a,"="); print a[1+0]; exit}}"""
    out=shell(f"conntrack -L -p udp 2>/dev/null | {awk}").stdout.strip()
    return out if re.fullmatch(r'(?:\d{1,3}\.){3}\d{1,3}', out) else ""

def status_for_user(u, active_ports, listen_port):
    port=str(u.get("port",""))
    check_port=port if port else listen_port
    if has_recent_udp_activity(check_port): return "Online"
    if check_port in active_ports: return "Offline"
    return "Unknown"

def _ipt(cmd): return shell(cmd)

def ensure_limit_rules(port, ip):
    if not (port and ip): return
    _ipt(f"iptables -C INPUT -p udp --dport {port} -s {ip} -j ACCEPT 2>/dev/null") or _ipt(f"iptables -I INPUT -p udp --dport {port} -s {ip} -j ACCEPT")
    _ipt(f"iptables -C INPUT -p udp --dport {port} ! -s {ip} -j DROP 2>/dev/null") or _ipt(f"iptables -I INPUT -p udp --dport {port} ! -s {ip} -j DROP")

def remove_limit_rules(port):
    if not port: return
    # remove both ACCEPT & DROP rules bound to this port
    while True:
        chk=_ipt(f"iptables -S INPUT | grep -E \"-p udp .* --dport {port}\\b .* (-j DROP|-j ACCEPT)\" | head -n1 || true").stdout.strip()
        if not chk: break
        rule=chk.replace(\"-A\",\"\",1).strip()
        _ipt(f\"iptables -D INPUT {rule}\")

def apply_device_limits(users):
    for u in users:
        port=str(u.get(\"port\",\"\") or \"\")
        ip=(u.get(\"bind_ip\",\"\") or \"\").strip()
        if port and ip:
            ensure_limit_rules(port, ip)
        elif port and not ip:
            remove_limit_rules(port)

def login_enabled(): return bool(ADMIN_USER and ADMIN_PASS)
def is_authed(): return session.get(\"auth\") is True
def require_login():
    if login_enabled() and not is_authed():
        return False
    return True

def load_users(): return read_json(USERS_FILE, [])
def save_users(v): write_json_atomic(USERS_FILE, v)

def sync_config_passwords():
