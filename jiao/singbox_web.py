#!/usr/bin/env python3
import http.server
import http.cookies
import json
import os
import subprocess
import urllib.parse
import secrets
import random

# ================= 自动随机配置区 =================
CONFIG_FILE = "/etc/sing-box/web_config.json"

def load_or_generate_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                cfg = json.load(f)
                port = cfg.get("port")
                password = cfg.get("password")
                if port and password:
                    return int(port), str(password)
        except:
            pass
    
    # 首次运行：自动随机生成端口 (10000-60000之间) 和 16 位随机密码
    port = random.randint(10000, 50000)
    password = secrets.token_hex(8)  # 16位随机十六进制字符串
    
    cfg = {"port": port, "password": password}
    try:
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump(cfg, f, indent=2)
    except Exception as e:
        print(f"保存随机配置失败: {e}")
        
    return port, password

PORT, WEB_PASSWORD = load_or_generate_config()

CONF_DIR = "/etc/sing-box/conf"
ROUTE_FILE = os.path.join(CONF_DIR, "route.json")
OUTBOUND_FILE = os.path.join(CONF_DIR, "outbounds.json")
FANOUT_FILE = "/var/lib/fanout/xray.json"
# ==========================================

LOGIN_PAGE = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>身份验证</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f4f6f9; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .login-box { background: #fff; padding: 30px 40px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); text-align: center; }
        h3 { color: #333; margin-top: 0; margin-bottom: 20px; }
        input { padding: 12px; width: 220px; border: 1px solid #ddd; border-radius: 6px; margin-bottom: 15px; font-size: 15px; text-align: center; }
        input:focus { border-color: #1a73e8; outline: none; }
        button { padding: 12px 24px; background: #1a73e8; color: #fff; border: none; border-radius: 6px; cursor: pointer; font-size: 15px; font-weight: bold; width: 100%; }
        button:hover { background: #1557b0; }
    </style>
</head>
<body>
    <div class="login-box">
        <h3>你好</h3>
        <input type="password" id="pwd" placeholder="请输入密码">
        <br>
        <button onclick="login()">登 录</button>
    </div>
    <script>
        if (document.cookie.includes('auth=')) {
            document.getElementById('pwd').placeholder = "密码错误，请重新输入";
            document.getElementById('pwd').style.borderColor = "red";
        }
        function login() {
            let p = document.getElementById('pwd').value;
            if (!p) return;
            document.cookie = "auth=" + p + "; path=/; max-age=2592000";
            window.location.href = '/?t=' + new Date().getTime();
        }
        document.getElementById('pwd').addEventListener('keypress', function (e) {
            if (e.key === 'Enter') login();
        });
    </script>
</body>
</html>
"""

HTML_PAGE = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Sing-box 分流面板</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 950px; margin: 30px auto; padding: 0 15px; background: #f4f6f9; color: #333; }
        h2 { color: #1a73e8; border-bottom: 2px solid #e0e0e0; padding-bottom: 10px; margin-bottom: 20px; }
        .card { background: #fff; padding: 20px; margin-bottom: 20px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { padding: 12px 10px; border-bottom: 1px solid #eee; text-align: left; font-size: 14px; }
        th { background: #fafafa; color: #555; }
        select, input[type="text"] { padding: 8px 12px; border-radius: 6px; border: 1px solid #ccc; background: #fff; font-size: 14px; margin-right: 8px; }
        input[type="text"] { width: 340px; }
        button { padding: 8px 16px; background: #1a73e8; color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: 500; font-size: 14px; }
        button:hover { background: #1557b0; }
        button.success { background: #137333; }
        button.success:hover { background: #0b5121; }
        button.danger { background: #d93025; }
        button.danger:hover { background: #b31412; }
        .form-group { margin-bottom: 15px; display: flex; align-items: flex-start; flex-wrap: wrap; gap: 10px; }
        .form-group label { min-width: 110px; font-weight: bold; padding-top: 8px; }
        .type-badge { display: inline-block; padding: 3px 8px; border-radius: 4px; font-weight: 600; font-size: 12px; background: #e8f0fe; color: #1a73e8; }
        .help-text { font-size: 12px; color: #666; margin-top: 4px; width: 100%; }
    </style>
</head>
<body>
    <h2>分流管理</h2>

    <!-- 同步节点 -->
    <div class="card" style="display: flex; justify-content: flex-end; align-items: center; background: #f8f9fa;">
        <button class="success" onclick="syncFanout()">🔄 同步</button>
    </div>

    <!-- 添加新规则 -->
    <div class="card">
        <h3>➕ 添加分流规则</h3>
        
        <div class="form-group">
            <label>1. 规则与内容:</label>
            <div>
                <select id="new-rule-type" onchange="toggleRuleInput()">
                    <option value="domain_suffix">域名后缀 (支持逗号多选)</option>
                    <option value="rule_set">规则集 (GeoSite)</option>
                </select>
                <span id="input-container-domain">
                    <input type="text" id="new-domain-value" placeholder="例如: ping0.cc, google.com">
                </span>
                <span id="input-container-ruleset" style="display: none;">
                    <select id="new-ruleset-select"></select>
                </span>
                <div class="help-text">域名可输入多个用英文逗号隔开；规则集将直接从 route.json 中读取已有标签。</div>
            </div>
        </div>

        <div class="form-group">
            <label>2. 生效节点:</label>
            <div>
                <select id="new-rule-inbounds" multiple style="height: 90px; width: 340px;"></select>
                <div class="help-text"><b>如果不选任何项（留空），则默认对全部节点生效。</b></div>
            </div>
        </div>

        <div class="form-group">
            <label>3. 选择出站:</label>
            <div>
                <select id="new-rule-outbound"></select>
                <button onclick="addRule()" style="margin-left: 10px;">确认添加规则</button>
            </div>
        </div>
    </div>

    <!-- 规则列表 -->
    <div class="card">
        <h3>⚡ 已有分流规则列表</h3>
        <table>
            <thead>
                <tr>
                    <th style="width: 12%;">类型</th>
                    <th style="width: 35%;">内容 / 规则集</th>
                    <th style="width: 18%;">生效入口</th>
                    <th style="width: 15%;">当前出站</th>
                    <th style="width: 20%;">操作</th>
                </tr>
            </thead>
            <tbody id="rules-table">
                <tr><td colspan="5" style="text-align:center;">正在加载规则...</td></tr>
            </tbody>
        </table>
    </div>

<script>
let globalData = { outbounds: [], inbounds: [], available_rule_sets: [], rules: [] };

function toggleRuleInput() {
    let type = document.getElementById('new-rule-type').value;
    if (type === 'rule_set') {
        document.getElementById('input-container-domain').style.display = 'none';
        document.getElementById('input-container-ruleset').style.display = 'inline-block';
    } else {
        document.getElementById('input-container-domain').style.display = 'inline-block';
        document.getElementById('input-container-ruleset').style.display = 'none';
    }
}

async function loadData() {
    try {
        let res = await fetch('/api/status?' + new Date().getTime());
        if (res.status === 401) {
            window.location.reload();
            return;
        }
        globalData = await res.json();
        
        let outHtml = '';
        if (globalData.outbounds.length === 0) {
            outHtml = '<option value="" disabled>(无可用出站)</option>';
        } else {
            globalData.outbounds.forEach(o => {
                outHtml += `<option value="${o}">${o}</option>`;
            });
        }
        document.getElementById('new-rule-outbound').innerHTML = outHtml;

        let inHtml = '';
        if (globalData.inbounds.length === 0) {
            inHtml = '<option value="" disabled>(未检测到入站节点)</option>';
        } else {
            globalData.inbounds.forEach(ib => {
                inHtml += `<option value="${ib}">${ib}</option>`;
            });
        }
        document.getElementById('new-rule-inbounds').innerHTML = inHtml;

        let rsHtml = '';
        if (globalData.available_rule_sets.length === 0) {
            rsHtml = '<option value="">(未发现 rule_set 定义)</option>';
        } else {
            globalData.available_rule_sets.forEach(rs => {
                rsHtml += `<option value="${rs}">${rs}</option>`;
            });
        }
        document.getElementById('new-ruleset-select').innerHTML = rsHtml;

        let ruleHtml = '';
        if (globalData.rules.length === 0) {
            ruleHtml = '<tr><td colspan="5" style="text-align:center; color:#888;">当前无自定义分流规则</td></tr>';
        } else {
            globalData.rules.forEach((r, idx) => {
                let opts = '';
                let isOutboundInList = false;
                
                globalData.outbounds.forEach(o => {
                    let selected = (o === r.outbound) ? 'selected' : '';
                    if (o === r.outbound) isOutboundInList = true;
                    opts += `<option value="${o}" ${selected}>${o}</option>`;
                });
                
                if (!isOutboundInList && r.outbound) {
                    opts = `<option value="${r.outbound}" selected>${r.outbound}</option>` + opts;
                }
                
                let typeName = r.type === 'domain_suffix' ? '域名后缀' : '规则集';
                let inboundsText = (r.inbounds && r.inbounds.length > 0) ? r.inbounds.join('<br>') : '<span style="color:#888;">全部节点</span>';
                
                ruleHtml += `<tr>
                    <td><span class="type-badge">${typeName}</span></td>
                    <td style="word-break: break-all;"><b>${r.values}</b></td>
                    <td><span style="font-size:12px; color:#555;">${inboundsText}</span></td>
                    <td><span style="color: #1a73e8; font-weight:600;">${r.outbound}</span></td>
                    <td>
                        <select id="rule-sel-${idx}">${opts}</select>
                        <button onclick="updateRule(${idx})">切换</button>
                        <button class="danger" onclick="deleteRule(${idx})">删除</button>
                    </td>
                </tr>`;
            });
        }
        document.getElementById('rules-table').innerHTML = ruleHtml;
    } catch (e) {
        alert('获取数据失败');
    }
}

async function syncFanout() {
    let res = await fetch('/api/sync_fanout?' + new Date().getTime());
    let result = await res.json();
    alert(result.msg);
    if (result.code === 0) {
        loadData();
    }
}

async function addRule() {
    let type = document.getElementById('new-rule-type').value;
    let outbound = document.getElementById('new-rule-outbound').value;
    let val = '';

    if (type === 'domain_suffix') {
        val = document.getElementById('new-domain-value').value.trim();
        if (!val) { alert('请输入要匹配的域名后缀！'); return; }
    } else {
        val = document.getElementById('new-ruleset-select').value;
        if (!val) { alert('未选中有效规则集！'); return; }
    }

    let inboundsSelect = document.getElementById('new-rule-inbounds');
    let selectedInbounds = Array.from(inboundsSelect.selectedOptions).map(opt => opt.value);

    let payload = { type: type, value: val, inbounds: selectedInbounds, outbound: outbound };

    let res = await fetch('/api/add_rule', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    });
    let result = await res.json();
    
    alert(result.msg);
    if (result.code === 0) { 
        document.getElementById('new-domain-value').value = '';
        loadData(); 
    }
}

async function updateRule(idx) {
    let val = document.getElementById(`rule-sel-${idx}`).value;
    let res = await fetch(`/api/set_rule?index=${idx}&outbound=${encodeURIComponent(val)}&` + new Date().getTime());
    let result = await res.json();
    
    alert(result.msg);
    if (result.code === 0) { loadData(); }
}

async function deleteRule(idx) {
    if (!confirm('确认要删除这条分流规则吗？')) return;
    let res = await fetch(`/api/del_rule?index=${idx}&` + new Date().getTime());
    let result = await res.json();
    
    alert(result.msg);
    if (result.code === 0) { loadData(); }
}

loadData();
</script>
</body>
</html>
"""

class PanelHandler(http.server.BaseHTTPRequestHandler):
    
    def check_auth(self):
        cookie_header = self.headers.get('Cookie')
        if cookie_header:
            cookies = http.cookies.SimpleCookie(cookie_header)
            if 'auth' in cookies and cookies['auth'].value == WEB_PASSWORD:
                return True
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

        elif path == "/api/status":
            data = {"outbounds": [], "inbounds": [], "available_rule_sets": [], "rules": []}
            try:
                ignore_outbounds = ["direct", "proxy", "dns-out", "block"]
                if os.path.exists(OUTBOUND_FILE):
                    with open(OUTBOUND_FILE, "r") as f:
                        o_json = json.load(f)
                        for o in o_json.get("outbounds", []):
                            tag = o.get("tag")
                            if tag and tag not in ignore_outbounds and tag not in data["outbounds"]:
                                data["outbounds"].append(tag)

                if os.path.exists(CONF_DIR):
                    for root, dirs, files in os.walk(CONF_DIR):
                        for file in files:
                            if file.endswith(".json"):
                                f_path = os.path.join(root, file)
                                try:
                                    with open(f_path, "r") as f:
                                        j_data = json.load(f)
                                        ib_list = j_data.get("inbounds", [])
                                        if isinstance(ib_list, list):
                                            for ib in ib_list:
                                                if isinstance(ib, dict) and "tag" in ib:
                                                    tag = ib["tag"]
                                                    if tag and tag not in data["inbounds"]:
                                                        data["inbounds"].append(tag)
                                except:
                                    pass

                if os.path.exists(ROUTE_FILE):
                    with open(ROUTE_FILE, "r") as f:
                        r_json = json.load(f)
                        route_cfg = r_json.get("route", {})
                        
                        rule_sets = route_cfg.get("rule_set", [])
                        for rs in rule_sets:
                            if isinstance(rs, dict) and "tag" in rs:
                                data["available_rule_sets"].append(rs["tag"])
                            elif isinstance(rs, str):
                                data["available_rule_sets"].append(rs)

                        rules = route_cfg.get("rules", [])
                        for r in rules:
                            for r_type in ["domain_suffix", "rule_set"]:
                                if r_type in r:
                                    val = r.get(r_type)
                                    vals = ", ".join(val) if isinstance(val, list) else str(val)
                                    
                                    inbound_val = r.get("inbound", [])
                                    if isinstance(inbound_val, str):
                                        inbounds = [inbound_val]
                                    elif isinstance(inbound_val, list):
                                        inbounds = inbound_val
                                    else:
                                        inbounds = []

                                    data["rules"].append({
                                        "type": r_type,
                                        "values": vals,
                                        "inbounds": inbounds,
                                        "outbound": r.get("outbound", "direct")
                                    })
                                    break
            except Exception as e:
                pass

            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(data, ensure_ascii=False).encode("utf-8"))

        elif path == "/api/sync_fanout":
            msg = self.do_sync_fanout_action()
            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(msg, ensure_ascii=False).encode("utf-8"))

        elif path == "/api/set_rule":
            try:
                idx = int(query.get("index", [0])[0])
                outbound = query.get("outbound", ["direct"])[0]
                
                with open(ROUTE_FILE, "r") as f:
                    r_json = json.load(f)
                
                valid_rules = 0
                for r in r_json["route"]["rules"]:
                    if any(k in r for k in ["domain_suffix", "rule_set"]):
                        if valid_rules == idx:
                            r["outbound"] = outbound
                            break
                        valid_rules += 1
                
                with open(ROUTE_FILE, "w") as f:
                    json.dump(r_json, f, indent=2)
                
                subprocess.run(["systemctl", "restart", "sing-box"], check=False)
                msg = {"code": 0, "msg": f"切换成功！已调整为 {outbound}"}
            except Exception as e:
                msg = {"code": 1, "msg": f"切换失败: {str(e)}"}

            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(msg, ensure_ascii=False).encode("utf-8"))

        elif path == "/api/del_rule":
            try:
                idx = int(query.get("index", [0])[0])
                with open(ROUTE_FILE, "r") as f:
                    r_json = json.load(f)
                
                rules = r_json["route"]["rules"]
                valid_rules = 0
                target_i = -1
                
                for i, r in enumerate(rules):
                    if any(k in r for k in ["domain_suffix", "rule_set"]):
                        if valid_rules == idx:
                            target_i = i
                            break
                        valid_rules += 1
                
                if target_i != -1:
                    rules.pop(target_i)
                    with open(ROUTE_FILE, "w") as f:
                        json.dump(r_json, f, indent=2)
                    subprocess.run(["systemctl", "restart", "sing-box"], check=False)
                    msg = {"code": 0, "msg": "规则删除成功！"}
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
                r_type = data.get("type", "domain_suffix")
                val_str = data.get("value", "").strip()
                inbounds = data.get("inbounds", [])
                outbound = data.get("outbound")
                
                if not val_str:
                    raise Exception("匹配内容不能为空")
                if not outbound:
                    raise Exception("未选择有效出站")

                with open(ROUTE_FILE, "r") as f:
                    r_json = json.load(f)
                
                if r_type == "domain_suffix":
                    vals = [v.strip() for v in val_str.split(",") if v.strip()]
                    new_rule = { "domain_suffix": vals, "outbound": outbound }
                else:
                    new_rule = { "rule_set": [val_str], "outbound": outbound }
                
                if inbounds and len(inbounds) > 0:
                    new_rule["inbound"] = inbounds

                if "rules" not in r_json["route"]:
                    r_json["route"]["rules"] = []
                
                r_json["route"]["rules"].insert(0, new_rule)
                
                with open(ROUTE_FILE, "w") as f:
                    json.dump(r_json, f, indent=2)
                
                subprocess.run(["systemctl", "restart", "sing-box"], check=False)
                msg = {"code": 0, "msg": "添加规则成功！"}
            except Exception as e:
                msg = {"code": 1, "msg": f"添加失败: {str(e)}"}

            self.send_no_cache_response(200, "application/json; charset=utf-8", json.dumps(msg, ensure_ascii=False).encode("utf-8"))

    def do_sync_fanout_action(self):
        if not os.path.exists(FANOUT_FILE):
            return {"code": 1, "msg": f"找不到 Fanout 配置文件 ({FANOUT_FILE})"}
        
        try:
            with open(FANOUT_FILE, "r") as f:
                xray_data = json.load(f)
            
            new_fanout_nodes = []
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
                            
                            new_fanout_nodes.append({
                                "type": "socks",
                                "tag": f"fanout-{port}",
                                "server": address,
                                "server_port": port,
                                "username": username,
                                "password": password
                            })
            
            outbound_data = {"outbounds": []}
            if os.path.exists(OUTBOUND_FILE):
                with open(OUTBOUND_FILE, "r") as f:
                    try: outbound_data = json.load(f)
                    except: pass
            
            if "outbounds" not in outbound_data:
                outbound_data["outbounds"] = []
                
            outbound_data["outbounds"] = [
                o for o in outbound_data["outbounds"] 
                if not (isinstance(o, dict) and str(o.get("tag", "")).startswith("fanout-"))
            ]
            outbound_data["outbounds"].extend(new_fanout_nodes)
            
            os.makedirs(os.path.dirname(OUTBOUND_FILE), exist_ok=True)
            with open(OUTBOUND_FILE, "w") as f:
                json.dump(outbound_data, f, indent=2)
                
            subprocess.run(["systemctl", "restart", "sing-box"], check=False)
            return {"code": 0, "msg": f"同步成功！已提取 {len(new_fanout_nodes)} 个 Fanout 节点。"}
        except Exception as e:
            return {"code": 1, "msg": f"同步出错: {str(e)}"}

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", PORT), PanelHandler)
    print("=" * 50)
    print(f"🚀 Web Panel 已启动！")
    print(f"🔗 访问地址: http://<你的服务器IP>:{PORT}")
    print(f"🔑 随机密码: {WEB_PASSWORD}")
    print("=" * 50)
    server.serve_forever()
