#!/usr/bin/env python3
import http.server
import http.cookies
import json
import os
import subprocess
import urllib.parse
import random
import time
import threading
import socket
from concurrent.futures import ThreadPoolExecutor

CONFIG_FILE = "/etc/sing-box/web_config.json"
FAILED_LOCK_UNTIL = 0

def load_or_generate_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                cfg = json.load(f)
                port = cfg.get("port")
                pwd = cfg.get("password")
                if port and pwd:
                    return int(port), str(pwd)
        except:
            pass
    port = 9999
    plain_password = str(random.randint(1000, 9999))
    cfg = {"port": port, "password": plain_password}
    try:
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump(cfg, f, indent=2)
    except:
        pass
    return port, plain_password

PORT, WEB_PASSWORD = load_or_generate_config()

# === 目录和文件定义 ===
SB_CONF_DIR = "/etc/sing-box/conf"
XRAY_CONF_DIR = "/etc/xray/conf"

SB_ROUTE_FILE = os.path.join(SB_CONF_DIR, "route.json")
XRAY_ROUTE_FILE = os.path.join(XRAY_CONF_DIR, "route.json")
SB_OUTBOUND_FILE = os.path.join(SB_CONF_DIR, "outbounds.json")
SB_INBOUND_FILE = os.path.join(SB_CONF_DIR, "inbounds.json")
XRAY_OUTBOUND_FILE = os.path.join(XRAY_CONF_DIR, "outbounds.json")
FANOUT_FILE = "/var/lib/fanout/xray.json"

TAG_NAME_MAP = {
    "direct": "直连",
    "block": "拦截",
    "dns-out": "DNS"
}

def ensure_route_file(filepath, is_xray=False):
    if not os.path.exists(filepath):
        os.makedirs(os.path.dirname(filepath), exist_ok=True)
        if is_xray:
            default_route = {"routing": {"rules": [{"type": "field", "outboundTag": "direct"}]}}
        else:
            default_route = {"route": {"rules": [{"outbound": "direct"}]}}
        try:
            with open(filepath, "w") as f:
                json.dump(default_route, f, indent=2)
        except:
            pass

ensure_route_file(SB_ROUTE_FILE, False)

# === 增加重启锁与按需重启函数（已优化延时 2 秒） ===
RESTART_LOCK = threading.Lock()

def restart_services_async(restart_sb=True, restart_xray=True):
    def _restart():
        # 给前端 2 秒充足的“逃生”时间接收数据并渲染页面
        time.sleep(2)
        with RESTART_LOCK:
            if restart_sb:
                subprocess.run(["systemctl", "restart", "sing-box"], check=False)
            if restart_xray:
                subprocess.run(["systemctl", "restart", "xray"], check=False)
    threading.Thread(target=_restart, daemon=True).start()

# === 出站节点 TCP 测速功能 ===
def get_outbound_servers():
    servers = {"direct": {"type": "direct"}}
    
    # 1. 扫描 Sing-box 出站
    if os.path.exists(SB_OUTBOUND_FILE):
        try:
            with open(SB_OUTBOUND_FILE, "r") as f:
                for o in json.load(f).get("outbounds", []):
                    tag = o.get("tag")
                    if tag:
                        servers[tag] = {
                            "type": o.get("type", ""),
                            "server": o.get("server"),
                            "port": o.get("server_port"),
                            "user": o.get("username", ""),
                            "pass": o.get("password", "")
                        }
        except: pass

    # 2. 扫描 Xray 出站
    if os.path.exists(XRAY_CONF_DIR):
        for fname in os.listdir(XRAY_CONF_DIR):
            if fname.endswith(".json"):
                try:
                    with open(os.path.join(XRAY_CONF_DIR, fname), "r") as nf:
                        data = json.load(nf)
                        for o in data.get("outbounds", []):
                            tag = o.get("tag")
                            proto = o.get("protocol", "")
                            settings = o.get("settings", {})
                            server_info = {}
                            
                            if "vnext" in settings and settings["vnext"]:
                                server_info = settings["vnext"][0]
                            elif "servers" in settings and settings["servers"]:
                                server_info = settings["servers"][0]

                            user, pwd = "", ""
                            if "users" in server_info and server_info["users"]:
                                user = server_info["users"][0].get("user", "")
                                pwd = server_info["users"][0].get("pass", "")

                            if tag:
                                servers[tag] = {
                                    "type": proto,
                                    "server": server_info.get("address"),
                                    "port": server_info.get("port"),
                                    "user": user,
                                    "pass": pwd
                                }
                except: pass
    return servers

def ping_target(tag, info):
    proto = str(info.get("type", "")).lower()
    server = info.get("server")
    port = info.get("port")
    user = info.get("user", "")
    pwd = info.get("pass", "")

    if tag == "direct" or proto == "direct":
        return tag, "N/A"
        
    if not server or not port:
        return tag, "无效节点"

    # 复刻 Bash: 针对 socks/http 协议使用 curl 穿透测试
    if proto in ["socks", "http", "socks5"]:
        scheme = "http" if proto == "http" else "socks5h"
        # 拼装带有账密的代理链接
        auth = f"{user}:{pwd}@" if user and pwd else ""
        proxy_url = f"{scheme}://{auth}{server}:{port}"

        cmd = [
            "curl", "-m", "4", "-s", "-o", "/dev/null",
            "-w", "%{http_code}|%{time_total}",
            "-x", proxy_url,
            "https://www.gstatic.com/generate_204"
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True)
            parts = res.stdout.strip().split('|')
            if len(parts) == 2:
                http_code = parts[0]
                # 规避某些 Linux 系统的逗号小数点问题
                time_total = parts[1].replace(',', '.') 
                # 只有真实返回了 200 或 204 才算通
                if http_code in ["204", "200"]:
                    ms_delay = int(float(time_total) * 1000)
                    return tag, f"{ms_delay}ms"
                else:
                    return tag, "超时/不通"
            return tag, "连接超时"
        except:
            return tag, "测速异常"
    else:
        # 对 VMess/VLESS 等原生协议回退到 TCP 探活 (显示 [协议名])
        return tag, f"[{proto}]"

def run_speedtest():
    servers = get_outbound_servers()
    results = {}
    with ThreadPoolExecutor(max_workers=15) as executor:
        futures = [executor.submit(ping_target, tag, info) for tag, info in servers.items()]
        for f in futures:
            tag, res = f.result()
            results[tag] = res
    return results


# === 核心扫描与分类功能 ===
def gather_nodes():
    inbounds = []
    outbounds = []
    inbound_core_map = {} 
    
    ignore_outbounds = ["direct", "dns-out", "block"]
    
    # 1. 扫描 Sing-box
    if os.path.exists(SB_OUTBOUND_FILE):
        try:
            with open(SB_OUTBOUND_FILE, "r") as f:
                for o in json.load(f).get("outbounds", []):
                    tag = o.get("tag")
                    if tag and tag not in ignore_outbounds and tag not in outbounds:
                        outbounds.append(tag)
        except: pass
        
    if os.path.exists(SB_INBOUND_FILE):
        try:
            with open(SB_INBOUND_FILE, "r") as f:
                for ib in json.load(f).get("inbounds", []):
                    tag = ib.get("tag")
                    if tag and tag not in inbounds:
                        inbounds.append(tag)
                        inbound_core_map[tag] = "singbox"
        except: pass
        
    if os.path.exists(SB_CONF_DIR):
        sb_files = [
            f for f in os.listdir(SB_CONF_DIR)
            if f.endswith(".json")
            and f not in ["route.json", "outbounds.json", "inbounds.json"]
        ]
        for node_filename in sb_files:
            node_filepath = os.path.join(SB_CONF_DIR, node_filename)
            try:
                with open(node_filepath, "r") as nf:
                    node_data = json.load(nf)
                if node_filename == "endpoints.json":
                    for ep in node_data.get("endpoints", []):
                        if isinstance(ep, dict) and ep.get("tag"):
                            tag = ep["tag"]
                            if tag not in ignore_outbounds and tag not in outbounds:
                                outbounds.append(tag)
                else:
                    found_tag = None
                    if "inbounds" in node_data and len(node_data["inbounds"]) > 0:
                        found_tag = node_data["inbounds"][0].get("tag")
                    elif "tag" in node_data:
                        found_tag = node_data.get("tag")
                    if found_tag and found_tag not in inbounds:
                        inbounds.append(found_tag)
                        inbound_core_map[found_tag] = "singbox"
            except: pass
            
    # 2. 扫描 Xray
    if os.path.exists(XRAY_CONF_DIR):
        for fname in os.listdir(XRAY_CONF_DIR):
            if fname.endswith(".json"):
                fpath = os.path.join(XRAY_CONF_DIR, fname)
                try:
                    with open(fpath, "r") as nf:
                        data = json.load(nf)
                        for o in data.get("outbounds", []):
                            tag = o.get("tag")
                            if tag and tag not in ignore_outbounds and tag not in outbounds:
                                outbounds.append(tag)
                        for ib in data.get("inbounds", []):
                            tag = ib.get("tag")
                            if tag and tag not in inbounds:
                                inbounds.append(tag)
                                inbound_core_map[tag] = "xray"
                except: pass
                
    mapped_outbounds = [TAG_NAME_MAP.get(t, t) for t in outbounds]
    return inbounds, mapped_outbounds, inbound_core_map

# === 路由规则容器通用解析器 ===
def get_route_rules_container(r_json, is_xray=False):
    if is_xray:
        if "routing" in r_json and isinstance(r_json["routing"], dict) and "rules" in r_json["routing"]:
            return r_json["routing"], r_json["routing"]["rules"]
        elif "route" in r_json and isinstance(r_json["route"], dict) and "rules" in r_json["route"]:
            return r_json["route"], r_json["route"]["rules"]
        elif "rules" in r_json and isinstance(r_json["rules"], list):
            return r_json, r_json["rules"]
        else:
            if "routing" not in r_json or not isinstance(r_json["routing"], dict):
                r_json["routing"] = {}
            if "rules" not in r_json["routing"]:
                r_json["routing"]["rules"] = []
            return r_json["routing"], r_json["routing"]["rules"]
    else:
        if "route" in r_json and isinstance(r_json["route"], dict) and "rules" in r_json["route"]:
            return r_json["route"], r_json["route"]["rules"]
        elif "rules" in r_json and isinstance(r_json["rules"], list):
            return r_json, r_json["rules"]
        else:
            if "route" not in r_json or not isinstance(r_json["route"], dict):
                r_json["route"] = {}
            if "rules" not in r_json["route"]:
                r_json["route"]["rules"] = []
            return r_json["route"], r_json["route"]["rules"]

def is_managed_rule_sb(r):
    if not isinstance(r, dict):
        return False
    if "outbound" not in r:
        return False
    conditions = [
        "domain", "domain_suffix", "domain_keyword", "domain_regex",
        "rule_set", "geoip", "ip_cidr", "port", "network", "protocol", "inbound"
    ]
    if any(c in r for c in conditions):
        return True
    return False

def is_managed_rule_xray(r):
    if not isinstance(r, dict):
        return False
    if r.get("type") != "field":
        return False
    if "outboundTag" not in r:
        return False
    conditions = ["domain", "ip", "port", "network", "inboundTag"]
    if any(c in r for c in conditions):
        return True
    return False

def is_hidden_xray_rule(r):
    if not isinstance(r, dict):
        return False
    if r.get("type") == "field" and "network" in r and r.get("outboundTag") == "direct":
        if not any(k in r for k in ["domain", "ip", "port", "inboundTag", "protocol", "balancerTag"]):
            return True
    return False

def parse_sb_rule(r, original_index):
    inbound_val = r.get("inbound", [])
    inbounds = [inbound_val] if isinstance(inbound_val, str) else (inbound_val if isinstance(inbound_val, list) else [])
    r_type = "match_all"
    vals = "(全匹配 - 所有流量)"
    if "domain_suffix" in r:
        r_type = "domain_suffix"
        val = r["domain_suffix"]
        vals = ", ".join(val) if isinstance(val, list) else str(val)
    elif "rule_set" in r:
        r_type = "rule_set"
        val = r["rule_set"]
        vals = ", ".join(val) if isinstance(val, list) else str(val)
    return {
        "type": r_type, "values": vals, "inbounds": inbounds,
        "outbound": r.get("outbound", "direct"),
        "_file": "singbox", "_index": original_index
    }

def parse_xray_rule(r, original_index):
    inbound_val = r.get("inboundTag", [])
    inbounds = [inbound_val] if isinstance(inbound_val, str) else (inbound_val if isinstance(inbound_val, list) else [])
    r_type = "match_all"
    vals = "(全匹配 - 所有流量)"
    domain = r.get("domain", [])
    if domain:
        if any(d.startswith("geosite:") for d in domain):
            r_type = "rule_set"
            vals = ", ".join([d.replace("geosite:", "") for d in domain if d.startswith("geosite:")])
        else:
            r_type = "domain_suffix"
            vals = ", ".join([str(d).replace("domain:", "").replace("domain=", "") for d in domain])
    return {
        "type": r_type, "values": vals, "inbounds": inbounds,
        "outbound": r.get("outboundTag", "direct"),
        "_file": "xray", "_index": original_index
    }

def get_all_rules():
    rules = []
    try:
        with open(SB_ROUTE_FILE, "r") as f:
            r_json = json.load(f)
            _, r_list = get_route_rules_container(r_json, is_xray=False)
            for i, r in enumerate(r_list):
                if is_managed_rule_sb(r):
                    rules.append(parse_sb_rule(r, i))
    except: pass
    
    if os.path.exists(XRAY_ROUTE_FILE):
        try:
            with open(XRAY_ROUTE_FILE, "r") as f:
                r_json = json.load(f)
                _, r_list = get_route_rules_container(r_json, is_xray=True)
                for i, r in enumerate(r_list):
                    if is_hidden_xray_rule(r):
                        continue
                    if is_managed_rule_xray(r):
                        rules.append(parse_xray_rule(r, i))
        except: pass
        
    return rules

def add_to_singbox(data, inbounds):
    r_type = data.get("type", "domain_suffix")
    val_str = data.get("value", "").strip()
    outbound = data.get("outbound")
    
    rule = {"outbound": outbound}
    if val_str:
        if r_type == "domain_suffix":
            rule["domain_suffix"] = [v.strip() for v in val_str.split(",") if v.strip()]
        else:
            rule["rule_set"] = [val_str]
    if inbounds:
        rule["inbound"] = inbounds
        
    ensure_route_file(SB_ROUTE_FILE, is_xray=False)
    with open(SB_ROUTE_FILE, "r") as f: r_json = json.load(f)
    _, r_list = get_route_rules_container(r_json, is_xray=False)
    r_list.insert(0, rule)
    with open(SB_ROUTE_FILE, "w") as f: json.dump(r_json, f, indent=2)

def add_to_xray(data, inbounds):
    if not os.path.exists(XRAY_ROUTE_FILE):
        return False
        
    r_type = data.get("type", "domain_suffix")
    val_str = data.get("value", "").strip()
    outbound = data.get("outbound")
    
    rule = {"type": "field", "outboundTag": outbound}
    if val_str:
        if r_type == "domain_suffix":
            rule["domain"] = [f"domain:{v.strip()}" for v in val_str.split(",") if v.strip()]
        else:
            rule["domain"] = [f"geosite:{val_str}"]
    if inbounds:
        rule["inboundTag"] = inbounds
        
    try:
        with open(XRAY_ROUTE_FILE, "r") as f: r_json = json.load(f)
        _, r_list = get_route_rules_container(r_json, is_xray=True)
        r_list.insert(0, rule)
        with open(XRAY_ROUTE_FILE, "w") as f: json.dump(r_json, f, indent=2)
        return True
    except:
        return False

LOGIN_PAGE = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>身份验证</title>
    <style>
        * { box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f4f6f9; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; padding: 15px; }
        .login-box { background: #fff; padding: 25px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.08); text-align: center; width: 100%; max-width: 300px; }
        h3 { color: #333; margin-top: 0; margin-bottom: 15px; }
        input { padding: 10px; width: 100%; border: 1px solid #ddd; border-radius: 6px; margin-bottom: 12px; font-size: 15px; text-align: center; }
        button { padding: 10px; background: #1a73e8; color: #fff; border: none; border-radius: 6px; cursor: pointer; font-size: 15px; font-weight: bold; width: 100%; }
        button:hover { background: #1557b0; }
    </style>
</head>
<body>
    <div class="login-box">
        <h3>你好</h3>
        <input type="password" id="pwd" placeholder="密码">
        <button onclick="login()">登 录</button>
    </div>
    <script>
        function login() {
            let p = document.getElementById('pwd').value;
            if (!p) return;
            document.cookie = "auth=" + p + "; path=/; max-age=2592000";
            window.location.href = window.location.pathname + '?t=' + new Date().getTime();
        }
        document.getElementById('pwd').addEventListener('keypress', function (e) { if (e.key === 'Enter') login(); });
    </script>
</body>
</html>
"""

HTML_PAGE = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <title>双端分流 (Sing-box & Xray)</title>
    <style>
        * { box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 900px; margin: 0 auto; padding: 12px; background: #f4f6f9; color: #333; line-height: 1.5; }
        h2 { color: #1a73e8; margin: 5px 0 12px 0; border-bottom: 2px solid #e0e0e0; padding-bottom: 8px; display: flex; justify-content: space-between; align-items: center; font-size: 18px; }
        .status-dot { height: 8px; width: 8px; background-color: #137333; border-radius: 50%; display: inline-block; margin-right: 4px; }
        .status-text { font-size: 12px; font-weight: normal; color: #666; }
        .card { background: #fff; padding: 14px 16px; margin-bottom: 14px; border-radius: 8px; box-shadow: 0 1px 4px rgba(0,0,0,0.06); }
        .table-container { width: 100%; overflow-x: auto; }
        table { width: 100%; min-width: 550px; border-collapse: collapse; margin-top: 8px; }
        th, td { padding: 8px 10px; border-bottom: 1px solid #eee; text-align: left; font-size: 13px; vertical-align: top; }
        th { background: #fafafa; color: #555; }
        select, input[type="text"] { width: 100%; max-width: 100%; padding: 8px 10px; border-radius: 6px; border: 1px solid #ccc; margin-bottom: 8px; font-size: 14px; background: #fff; }
        button { padding: 8px 14px; background: #1a73e8; color: white; border: none; border-radius: 6px; cursor: pointer; font-size: 13px; transition: all 0.2s; }
        button:hover:not(:disabled) { background: #1557b0; }
        button:disabled { cursor: not-allowed; opacity: 0.8; }
        .success { background: #137333; }
        .success:hover:not(:disabled) { background: #0b5121; }
        .danger { background: #d93025; }
        .danger:hover:not(:disabled) { background: #b31412; }
        .edit-btn { background: #e8f0fe; color: #1a73e8; font-size: 11px; padding: 3px 8px; margin-top: 6px; border-radius: 4px; border: 1px solid #d2e3fc; display: inline-block; cursor: pointer; font-weight: bold; }
        .edit-btn:hover { background: #d2e3fc; }
        .form-group { margin-bottom: 12px; }
        .form-group label { display: block; font-weight: bold; margin-bottom: 5px; font-size: 13px; color: #444; }
        .type-badge { display: inline-block; padding: 3px 7px; border-radius: 4px; font-weight: 600; font-size: 11px; background: #e8f0fe; color: #1a73e8; }
        .type-badge.all { background: #fce8e6; color: #d93025; }
        .modal-overlay { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); z-index: 99; }
        .modal-content { display: none; position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background: #fff; padding: 20px; border-radius: 10px; box-shadow: 0 4px 20px rgba(0,0,0,0.2); z-index: 100; width: 90%; max-width: 380px; }
    </style>
</head>
<body>
    <h2>
        <span>🚀 双端分流</span>
        <span class="status-text"><span class="status-dot"></span>在线</span>
    </h2>
    
    <div class="card" style="background: #f8f9fa; padding: 12px 14px;">
        <button class="success" onclick="syncFanout(this)" style="width: 100%; padding: 10px 0; font-size: 14px; font-weight: bold;">🔄 同步节点</button>
    </div>

    <div id="view-routing">
        <div class="card">
            <h3 style="margin: 0 0 10px 0; font-size: 15px;">➕ 添加规则</h3>
            <div class="form-group">
                <label>规则类型与内容:</label>
                <select id="new-rule-type" onchange="toggleRuleInput('new')">
                    <option value="domain_suffix">域名后缀</option>
                    <option value="rule_set">规则集</option>
                </select>
                <input type="text" id="new-domain-value" placeholder="输入域名 (留空匹配所有流量)">
                <select id="new-ruleset-select" style="display: none;"></select>
            </div>
            <div class="form-group">
                <label>生效节点:</label>
                <select id="new-rule-inbounds" multiple style="height: 75px;" onchange="checkXrayRuleSetRestriction()"></select>
                <div style="font-size:11px; color:#666; margin-top:3px;">留空默认对所有Xray和Singbox节点生效 (Xray 节点不支持规则集)</div>
            </div>
            <div class="form-group">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 5px;">
                    <label style="margin-bottom: 0;">出站节点:</label>
                    <button type="button" onclick="speedTest(this)" style="padding: 3px 10px; font-size: 11px; background: #34a853;">⚡ 一键测速</button>
                </div>
                <select id="new-rule-outbound"></select>
                <button id="add-btn" onclick="addRule()" style="width: 100%; margin-top: 8px;">添加规则</button>
            </div>
        </div>

        <div class="card">
            <h3 style="margin: 0 0 10px 0; font-size: 15px;">⚡ 已有分流规则列表</h3>
            <div class="table-container">
                <table>
                    <thead>
                        <tr>
                            <th style="width: 15%;">类型</th>
                            <th style="width: 32%;">内容</th>
                            <th style="width: 15%;">入口</th>
                            <th style="width: 15%;">出站</th>
                            <th style="width: 23%;">操作</th>
                        </tr>
                    </thead>
                    <tbody id="rules-table">
                        <tr><td colspan="5" style="text-align:center;">加载中...</td></tr>
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <div id="modalOverlay" class="modal-overlay" onclick="closeEditModal()"></div>
    <div id="editModal" class="modal-content">
        <h3 style="margin-top:0; font-size: 16px;">✏️ 修改规则内容</h3>
        <input type="hidden" id="edit-idx">
        <div class="form-group">
            <label>新规则类型与内容:</label>
            <select id="edit-rule-type" onchange="toggleRuleInput('edit')">
                <option value="domain_suffix">域名后缀</option>
                <option value="rule_set">规则集</option>
            </select>
            <input type="text" id="edit-domain-value" placeholder="输入域名" style="margin-top: 6px;">
            <select id="edit-ruleset-select" style="display: none; margin-top: 6px;"></select>
        </div>
        <div style="display: flex; gap: 8px; margin-top: 15px;">
            <button id="save-edit-btn" onclick="saveEdit()" style="flex: 1;">保存修改</button>
            <button onclick="closeEditModal()" style="flex: 1; background: #f1f3f4; color: #333;">取消</button>
        </div>
    </div>

<script>
let globalData = { outbounds: [], inbounds: [], inbound_core_map: {}, available_rule_sets: [], rules: [] };
let outboundLatencies = {};

// === 一键测速逻辑（并发测试，限制 5 秒） ===
async function speedTest(btn) {
    if (btn.disabled) return;
    const oldText = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = "⏳ 测速中...";

    try {
        let controller = new AbortController();
        let timeoutId = setTimeout(() => controller.abort(), 5200);

        let res = await fetch('/api/speedtest?' + Date.now(), { signal: controller.signal });
        clearTimeout(timeoutId);

        if (res.ok) {
            outboundLatencies = await res.json();
            renderSelects(); 
            renderTable();   
        }
    } catch (e) {
        console.error("测速超时或失败");
    } finally {
        btn.disabled = false;
        btn.innerHTML = oldText;
    }
}

function checkXrayRuleSetRestriction() {
    let inboundsSelect = document.getElementById('new-rule-inbounds');
    let selectedInbounds = inboundsSelect ? Array.from(inboundsSelect.selectedOptions).map(opt => opt.value) : [];
    let hasXray = selectedInbounds.some(ib => globalData.inbound_core_map && globalData.inbound_core_map[ib] === 'xray');
    
    let typeSelect = document.getElementById('new-rule-type');
    let ruleSetOption = typeSelect.querySelector('option[value="rule_set"]');
    
    if (hasXray) {
        if (ruleSetOption) ruleSetOption.disabled = true;
        if (typeSelect.value === 'rule_set') {
            typeSelect.value = 'domain_suffix';
            toggleRuleInput('new');
        }
    } else {
        if (ruleSetOption) ruleSetOption.disabled = false;
    }
}

function toggleRuleInput(prefix) {
    let type = document.getElementById(prefix + '-rule-type').value;
    if (type === 'rule_set') {
        document.getElementById(prefix + '-domain-value').style.display = 'none';
        document.getElementById(prefix + '-ruleset-select').style.display = 'inline-block';
    } else {
        document.getElementById(prefix + '-domain-value').style.display = 'inline-block';
        document.getElementById(prefix + '-ruleset-select').style.display = 'none';
    }
}

function renderTable() {
    let ruleHtml = '';
    if (globalData.rules.length === 0) {
        ruleHtml = '<tr><td colspan="5" style="text-align:center; color:#888;">暂无规则</td></tr>';
    } else {
        globalData.rules.forEach((r, idx) => {
            let opts = '';
            let isOutboundInList = false;
            globalData.outbounds.forEach(o => {
                let delayStr = outboundLatencies[o] ? ` (${outboundLatencies[o]})` : '';
                let selected = (o === r.outbound) ? 'selected' : '';
                if (o === r.outbound) isOutboundInList = true;
                opts += `<option value="${o}" ${selected}>${o}${delayStr}</option>`;
            });

            if (!isOutboundInList && r.outbound) {
                opts = `<option value="${r.outbound}" selected>${r.outbound}</option>` + opts;
            }
            
            let typeName = r.type === 'domain_suffix' ? '域名后缀' : (r.type === 'rule_set' ? '规则集' : '全部');
            let badgeClass = r.type === 'match_all' ? 'type-badge all' : 'type-badge';
            let inboundsText = (r.inbounds && r.inbounds.length > 0) ? r.inbounds.join('<br>') : '<span style="color:#888;">全局</span>';
            let coreTag = r._file === 'xray' ? '<br><span style="color:#e91e63;font-size:10px;">[Xray]</span>' : '<br><span style="color:#2196f3;font-size:10px;">[Singbox]</span>';
            
            ruleHtml += `<tr>
                <td><span class="${badgeClass}">${typeName}</span></td>
                <td>
                    <div style="word-break: break-all;"><b>${r.values}</b></div>
                    <div class="edit-btn" onclick="openEditModal(${idx})">✏️ 修改</div>
                </td>
                <td><span style="font-size:11px; color:#555;">${inboundsText}${coreTag}</span></td>
                <td><span style="color: #1a73e8; font-weight:600;">${r.outbound}</span></td>
                <td>
                    <select id="rule-sel-${idx}" style="width: auto; margin-bottom: 4px;">${opts}</select>
                    <div style="display: flex; gap: 4px;">
                        <button onclick="updateRule(${idx})" style="padding: 3px 8px; font-size:11px;">切换</button>
                        <button class="danger" onclick="deleteRule(${idx})" style="padding: 3px 8px; font-size:11px;">删除</button>
                    </div>
                </td>
            </tr>`;
        });
    }
    document.getElementById('rules-table').innerHTML = ruleHtml;
}

function renderSelects() {
    let outHtml = '';
    globalData.outbounds.forEach(o => {
        let delayStr = outboundLatencies[o] ? ` (${outboundLatencies[o]})` : '';
        outHtml += `<option value="${o}">${o}${delayStr}</option>`;
    });
    document.getElementById('new-rule-outbound').innerHTML = outHtml || '<option disabled>(无可用出站)</option>';
    
    let inHtml = '';
    globalData.inbounds.forEach(ib => {
        let core = globalData.inbound_core_map[ib] || 'singbox';
        let badge = core === 'xray' ? ' [Xray]' : ' [SB]';
        inHtml += `<option value="${ib}">${ib}${badge}</option>`;
    });
    let inEl = document.getElementById('new-rule-inbounds');
    if (inEl) inEl.innerHTML = inHtml || '<option disabled>(无入站节点)</option>';

    let rsHtml = '<option value="">(不选择，匹配所有流量)</option>';
    globalData.available_rule_sets.forEach(rs => rsHtml += `<option value="${rs}">${rs}</option>`);
    document.getElementById('new-ruleset-select').innerHTML = rsHtml;
    
    checkXrayRuleSetRestriction();
}

async function loadData() {
    try {
        let res = await fetch('/api/status?' + new Date().getTime());
        if (res.status === 401) { window.location.reload(); return; }
        globalData = await res.json();
        renderSelects();
        renderTable();
    } catch (e) {
        console.error('获取数据失败');
    }
}

function openEditModal(idx) {
    let rule = globalData.rules[idx];
    document.getElementById('edit-idx').value = idx;
    let rsHtml = '<option value="">(不选择，匹配所有流量)</option>';
    globalData.available_rule_sets.forEach(rs => rsHtml += `<option value="${rs}">${rs}</option>`);
    document.getElementById('edit-ruleset-select').innerHTML = rsHtml;

    if (rule.type === 'match_all') {
        document.getElementById('edit-rule-type').value = 'domain_suffix';
        document.getElementById('edit-domain-value').value = '';
    } else if (rule.type === 'rule_set') {
        document.getElementById('edit-rule-type').value = 'rule_set';
        document.getElementById('edit-ruleset-select').value = rule.values;
    } else {
        document.getElementById('edit-rule-type').value = 'domain_suffix';
        document.getElementById('edit-domain-value').value = rule.values !== '(全匹配 - 所有流量)' ? rule.values : '';
    }
    toggleRuleInput('edit');
    document.getElementById('modalOverlay').style.display = 'block';
    document.getElementById('editModal').style.display = 'block';
}

function closeEditModal() {
    document.getElementById('modalOverlay').style.display = 'none';
    document.getElementById('editModal').style.display = 'none';
}

async function runActionAndReload(btn, apiCallPromise) {
    if (btn.disabled) return;
    const oldHtml = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = "⏳ 处理中...";
    try {
        let resp = await apiCallPromise;
        let jsonRes = await resp.json();
        if (jsonRes.code !== 0) {
            alert(jsonRes.msg);
        } else {
            await new Promise(r => setTimeout(r, 500));
            await loadData();
        }
    } catch (e) {
        console.error(e);
    } finally {
        btn.disabled = false;
        btn.innerHTML = oldHtml;
    }
}

let addBtnCooldown = false;
async function addRule() {
    if (addBtnCooldown) return;
    const btn = document.getElementById('add-btn');
    let type = document.getElementById('new-rule-type').value;
    let outbound = document.getElementById('new-rule-outbound').value;
    let val = type === 'domain_suffix'
        ? document.getElementById('new-domain-value').value.trim()
        : document.getElementById('new-ruleset-select').value;

    let inboundsSelect = document.getElementById('new-rule-inbounds');
    let selectedInbounds = inboundsSelect
        ? Array.from(inboundsSelect.selectedOptions).map(opt => opt.value)
        : [];

    addBtnCooldown = true;
    btn.disabled = true;
    const originalText = btn.innerHTML;
    btn.innerHTML = "⏳ 处理中...";

    try {
        let resp = await fetch('/api/add_rule', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type: type, value: val, inbounds: selectedInbounds, outbound: outbound })
        });
        let jsonRes = await resp.json();
        if (jsonRes.code !== 0) {
            alert(jsonRes.msg);
        } else {
            await new Promise(r => setTimeout(r, 500));
            document.getElementById('new-domain-value').value = '';
            await loadData();
        }
    } catch(e) {
        console.error(e);
    }

    btn.innerHTML = "⏳ 冷却中(5s)...";
    setTimeout(() => {
        addBtnCooldown = false;
        btn.disabled = false;
        btn.innerHTML = originalText;
    }, 5000);
}

async function updateRule(idx) {
    const btn = event.currentTarget;
    const val = document.getElementById(`rule-sel-${idx}`).value;
    await runActionAndReload(btn, fetch(`/api/set_rule?index=${idx}&outbound=${encodeURIComponent(val)}&t=${Date.now()}`));
}

async function deleteRule(idx) {
    if (!confirm('确认删除？')) return;
    const btn = event.currentTarget;
    await runActionAndReload(btn, fetch(`/api/del_rule?index=${idx}&t=${Date.now()}`));
}

async function saveEdit() {
    const btn = document.getElementById('save-edit-btn');
    let idx = document.getElementById('edit-idx').value;
    let type = document.getElementById('edit-rule-type').value;
    let val = type === 'domain_suffix'
        ? document.getElementById('edit-domain-value').value.trim()
        : document.getElementById('edit-ruleset-select').value;

    if (btn.disabled) return;
    const oldHtml = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = "⏳ 处理中...";
    try {
        let resp = await fetch('/api/edit_rule', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ index: parseInt(idx), type: type, value: val })
        });
        let jsonRes = await resp.json();
        if (jsonRes.code !== 0) {
            alert(jsonRes.msg);
        } else {
            await new Promise(r => setTimeout(r, 500));
            closeEditModal();
            await loadData();
        }
    } catch (e) {
        console.error(e);
    } finally {
        btn.disabled = false;
        btn.innerHTML = oldHtml;
    }
}

let isSyncing = false; 
async function syncFanout(btn) {
    if (isSyncing) return;
    isSyncing = true;
    await runActionAndReload(btn, fetch('/api/sync_fanout?' + Date.now(), { cache: 'no-store' }));
    isSyncing = false;
}

loadData();
</script>
</body>
</html>
"""

class PanelHandler(http.server.BaseHTTPRequestHandler):
    def check_auth(self):
        global FAILED_LOCK_UNTIL
        current_time = time.time()
        if current_time < FAILED_LOCK_UNTIL:
            return False
        cookie_header = self.headers.get('Cookie')
        if cookie_header:
            cookies = http.cookies.SimpleCookie(cookie_header)
            if 'auth' in cookies:
                if cookies['auth'].value == WEB_PASSWORD:
                    FAILED_LOCK_UNTIL = 0
                    return True
                else:
                    FAILED_LOCK_UNTIL = current_time + 30
                    time.sleep(1)
        return False

    def send_no_cache_response(self, code, content_type, body_bytes):
        self.send_response(code)
        self.send_header("Content-type", content_type)
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.end_headers()
        self.wfile.write(body_bytes)

    def do_GET(self):
        parsed_path = urllib.parse.urlparse(self.path)
        path = parsed_path.path
        query = urllib.parse.parse_qs(parsed_path.query)

        if not self.check_auth():
            if path.startswith("/api"):
                self.send_no_cache_response(401, "application/json; charset=utf-8", b'{"status":"error","msg":"Unauthorized"}')
            else:
                self.send_no_cache_response(200, "text/html; charset=utf-8", LOGIN_PAGE.encode("utf-8"))
            return

        if path == "/":
            self.send_no_cache_response(200, "text/html; charset=utf-8", HTML_PAGE.encode("utf-8"))
        elif path == "/api/speedtest":
            results = run_speedtest()
            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(results, ensure_ascii=False).encode("utf-8"))
        elif path == "/api/status":
            inbounds, outbounds, inbound_core_map = gather_nodes()
            data = {
                "outbounds": outbounds,
                "inbounds": inbounds,
                "inbound_core_map": inbound_core_map,
                "available_rule_sets": [],
                "rules": get_all_rules()
            }
            try:
                if os.path.exists(SB_ROUTE_FILE):
                    with open(SB_ROUTE_FILE, "r") as f:
                        route_cfg = json.load(f).get("route", {})
                        for rs in route_cfg.get("rule_set", []):
                            if isinstance(rs, dict) and "tag" in rs:
                                data["available_rule_sets"].append(rs["tag"])
                            elif isinstance(rs, str):
                                data["available_rule_sets"].append(rs)
            except: pass
            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(data, ensure_ascii=False).encode("utf-8"))

        elif path == "/api/sync_fanout":
            msg = self.do_sync_fanout_action()
            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(msg, ensure_ascii=False).encode("utf-8"))

        elif path == "/api/set_rule":
            try:
                idx = int(query.get("index", [0])[0])
                outbound = query.get("outbound", ["direct"])[0]
                
                rules = get_all_rules()
                if idx < len(rules):
                    target = rules[idx]
                    real_idx = target["_index"]
                    if target["_file"] == "singbox":
                        ensure_route_file(SB_ROUTE_FILE, is_xray=False)
                        with open(SB_ROUTE_FILE, "r") as f: r_json = json.load(f)
                        _, r_list = get_route_rules_container(r_json, is_xray=False)
                        if real_idx < len(r_list):
                            r_list[real_idx]["outbound"] = outbound
                            with open(SB_ROUTE_FILE, "w") as f: json.dump(r_json, f, indent=2)
                            restart_services_async(restart_sb=True, restart_xray=False)
                    elif target["_file"] == "xray":
                        if os.path.exists(XRAY_ROUTE_FILE):
                            with open(XRAY_ROUTE_FILE, "r") as f: r_json = json.load(f)
                            _, r_list = get_route_rules_container(r_json, is_xray=True)
                            if real_idx < len(r_list):
                                r_list[real_idx]["outboundTag"] = outbound
                                with open(XRAY_ROUTE_FILE, "w") as f: json.dump(r_json, f, indent=2)
                                restart_services_async(restart_sb=False, restart_xray=True)
                    
                    msg = {"code": 0, "msg": "success"}
                else:
                    msg = {"code": 1, "msg": "规则索引越界"}
            except Exception as e:
                msg = {"code": 1, "msg": f"切换失败: {str(e)}"}
            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(msg, ensure_ascii=False).encode("utf-8"))

        elif path == "/api/del_rule":
            try:
                idx = int(query.get("index", [0])[0])
                rules = get_all_rules()
                if idx < len(rules):
                    target = rules[idx]
                    real_idx = target["_index"]
                    if target["_file"] == "singbox":
                        ensure_route_file(SB_ROUTE_FILE, is_xray=False)
                        with open(SB_ROUTE_FILE, "r") as f: r_json = json.load(f)
                        _, r_list = get_route_rules_container(r_json, is_xray=False)
                        if real_idx < len(r_list):
                            r_list.pop(real_idx)
                            with open(SB_ROUTE_FILE, "w") as f: json.dump(r_json, f, indent=2)
                            restart_services_async(restart_sb=True, restart_xray=False)
                    elif target["_file"] == "xray":
                        if os.path.exists(XRAY_ROUTE_FILE):
                            with open(XRAY_ROUTE_FILE, "r") as f: r_json = json.load(f)
                            _, r_list = get_route_rules_container(r_json, is_xray=True)
                            if real_idx < len(r_list):
                                r_list.pop(real_idx)
                                with open(XRAY_ROUTE_FILE, "w") as f: json.dump(r_json, f, indent=2)
                                restart_services_async(restart_sb=False, restart_xray=True)
                    
                    msg = {"code": 0, "msg": "success"}
                else:
                    msg = {"code": 1, "msg": "未找到指定规则"}
            except Exception as e:
                msg = {"code": 1, "msg": f"删除失败: {str(e)}"}
            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(msg, ensure_ascii=False).encode("utf-8"))

    def do_POST(self):
        if not self.check_auth():
            self.send_no_cache_response(401, "application/json; charset=utf-8", b'{"code":1, "msg":"Unauthorized"}')
            return
    
        parsed_path = urllib.parse.urlparse(self.path)
        path = parsed_path.path

        if path == "/api/add_rule":
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length).decode('utf-8')
            try:
                data = json.loads(post_data)
                req_inbounds = data.get("inbounds", [])
                r_type = data.get("type", "domain_suffix")
                _, _, core_map = gather_nodes()
                
                if r_type == "rule_set":
                    if any(core_map.get(ib) == "xray" for ib in req_inbounds):
                        self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps({"code": 1, "msg": "Xray 节点不支持选择规则集"}, ensure_ascii=False).encode("utf-8"))
                        return

                sb_modified = False
                xray_modified = False

                if not req_inbounds:
                    add_to_singbox(data, [])
                    xray_modified = add_to_xray(data, [])
                    sb_modified = True
                else:
                    sb_targets = []
                    xray_targets = []
                    for ib in req_inbounds:
                        core = core_map.get(ib, "singbox")
                        if core == "singbox": sb_targets.append(ib)
                        else: xray_targets.append(ib)
                    
                    if sb_targets: 
                        add_to_singbox(data, sb_targets)
                        sb_modified = True
                    if xray_targets: 
                        xray_modified = add_to_xray(data, xray_targets)

                restart_services_async(restart_sb=sb_modified, restart_xray=xray_modified)
                msg = {"code": 0, "msg": "success"}
            except Exception as e:
                msg = {"code": 1, "msg": f"添加失败: {str(e)}"}
            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(msg, ensure_ascii=False).encode("utf-8"))

        elif path == "/api/edit_rule":
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length).decode('utf-8')
            try:
                data = json.loads(post_data)
                idx = int(data.get("index", 0))
                new_type = data.get("type", "domain_suffix")
                new_val = data.get("value", "").strip()
                
                rules = get_all_rules()
                if idx < len(rules):
                    target = rules[idx]
                    real_idx = target["_index"]
                    
                    if target["_file"] == "singbox":
                        ensure_route_file(SB_ROUTE_FILE, is_xray=False)
                        with open(SB_ROUTE_FILE, "r") as f: r_json = json.load(f)
                        _, r_list = get_route_rules_container(r_json, is_xray=False)
                        if real_idx < len(r_list):
                            rule_obj = r_list[real_idx]
                            rule_obj.pop("domain_suffix", None)
                            rule_obj.pop("rule_set", None)
                            if new_val:
                                if new_type == "domain_suffix":
                                    rule_obj["domain_suffix"] = [v.strip() for v in new_val.split(",") if v.strip()]
                                else:
                                    rule_obj["rule_set"] = [new_val]
                            with open(SB_ROUTE_FILE, "w") as f: json.dump(r_json, f, indent=2)
                            restart_services_async(restart_sb=True, restart_xray=False)
                        
                    elif target["_file"] == "xray":
                        if os.path.exists(XRAY_ROUTE_FILE):
                            with open(XRAY_ROUTE_FILE, "r") as f: r_json = json.load(f)
                            _, r_list = get_route_rules_container(r_json, is_xray=True)
                            if real_idx < len(r_list):
                                rule_obj = r_list[real_idx]
                                rule_obj.pop("domain", None)
                                if new_val:
                                    if new_type == "domain_suffix":
                                        rule_obj["domain"] = [f"domain:{v.strip()}" for v in new_val.split(",") if v.strip()]
                                    else:
                                        rule_obj["domain"] = [f"geosite:{new_val}"]
                                with open(XRAY_ROUTE_FILE, "w") as f: json.dump(r_json, f, indent=2)
                                restart_services_async(restart_sb=False, restart_xray=True)
                        
                    msg = {"code": 0, "msg": "success"}
                else:
                    msg = {"code": 1, "msg": "未找到指定规则"}
            except Exception as e:
                msg = {"code": 1, "msg": f"修改失败: {str(e)}"}
            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(msg, ensure_ascii=False).encode("utf-8"))

    def do_sync_fanout_action(self):
        if not os.path.exists(FANOUT_FILE):
            return {"code": 1, "msg": f"找不到 Fanout 配置文件 ({FANOUT_FILE})"}
        try:
            with open(FANOUT_FILE, "r") as f:
                xray_data = json.load(f)
            
            new_fanout_nodes_sb = []
            new_fanout_nodes_xray = []
            
            for outbound in xray_data.get("outbounds", []):
                if outbound.get("protocol") == "socks":
                    tag = str(outbound.get("tag", ""))
                    if "fanout-" in tag:
                        servers = outbound.get("settings", {}).get("servers", [])
                        if servers:
                            server_info = servers[0]
                            port = server_info.get("port")
                            address = server_info.get("address")
                            users = server_info.get("users", [])
                            username = users[0].get("user") if users else ""
                            password = users[0].get("pass") if users else ""
                            
                            new_fanout_nodes_sb.append({
                                "type": "socks",
                                "tag": f"fanout-{port}",
                                "server": address,
                                "server_port": port,
                                "username": username,
                                "password": password
                            })
                            
                            xray_proxy_setting = {
                                "servers": [{
                                    "address": address,
                                    "port": port
                                }]
                            }
                            if username and password:
                                xray_proxy_setting["servers"][0]["users"] = [{
                                    "user": username,
                                    "pass": password
                                }]
                                
                            new_fanout_nodes_xray.append({
                                "tag": f"fanout-{port}",
                                "protocol": "socks",
                                "settings": xray_proxy_setting
                            })

            sb_outbound_data = {"outbounds": []}
            sb_outbound_file = os.path.join(SB_CONF_DIR, "outbounds.json")
            if os.path.exists(sb_outbound_file):
                with open(sb_outbound_file, "r") as f:
                    try: sb_outbound_data = json.load(f)
                    except: pass
            if "outbounds" not in sb_outbound_data:
                sb_outbound_data["outbounds"] = []
            
            sb_outbound_data["outbounds"] = [
                o for o in sb_outbound_data["outbounds"] 
                if not (isinstance(o, dict) and str(o.get("tag", "")).startswith("fanout-"))
            ]
            sb_outbound_data["outbounds"].extend(new_fanout_nodes_sb)
            os.makedirs(os.path.dirname(sb_outbound_file), exist_ok=True)
            with open(sb_outbound_file, "w") as f:
                json.dump(sb_outbound_data, f, indent=2)

            xray_synced = False
            if os.path.exists(XRAY_OUTBOUND_FILE):
                xray_outbound_data = {"outbounds": []}
                try:
                    with open(XRAY_OUTBOUND_FILE, "r") as f:
                        xray_outbound_data = json.load(f)
                except: pass
                
                if "outbounds" not in xray_outbound_data:
                    xray_outbound_data["outbounds"] = []
                    
                xray_outbound_data["outbounds"] = [
                    o for o in xray_outbound_data["outbounds"] 
                    if not (isinstance(o, dict) and str(o.get("tag", "")).startswith("fanout-"))
                ]
                xray_outbound_data["outbounds"].extend(new_fanout_nodes_xray)
                os.makedirs(os.path.dirname(XRAY_OUTBOUND_FILE), exist_ok=True)
                with open(XRAY_OUTBOUND_FILE, "w") as f:
                    json.dump(xray_outbound_data, f, indent=2)
                xray_synced = True

            restart_services_async(restart_sb=True, restart_xray=xray_synced)
            return {"code": 0, "msg": "success"}
        except Exception as e:
            return {"code": 1, "msg": f"同步出错: {str(e)}"}

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", PORT), PanelHandler)
    print(f"Panel is running on port {PORT}. Password: {WEB_PASSWORD}")
    server.serve_forever()
