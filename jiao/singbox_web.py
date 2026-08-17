cat << 'EOF' > /etc/sing-box/singbox_web.py
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

# ================= 配置区 =================
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
    except Exception as e:
        print(f"保存配置失败: {e}")
        
    return port, plain_password

PORT, WEB_PASSWORD = load_or_generate_config()

CONF_DIR = "/etc/sing-box/conf"
ROUTE_FILE = os.path.join(CONF_DIR, "route.json")
OUTBOUND_FILE = os.path.join(CONF_DIR, "outbounds.json")
FANOUT_FILE = "/var/lib/fanout/xray.json"
# ==========================================

def restart_singbox_async():
    def _restart():
        subprocess.run(["systemctl", "restart", "sing-box"], check=False)
    threading.Thread(target=_restart, daemon=True).start()

def is_managed_rule(r):
    if not isinstance(r, dict):
        return False
    if "domain_suffix" in r or "rule_set" in r:
        return True
    conditions = ["domain", "domain_suffix", "domain_keyword", "domain_regex", "geosite", "geoip", "ip_cidr", "ip_is_private", "port", "port_range", "source_ip_cidr", "source_ip_is_private", "source_port", "source_port_range", "network", "type", "protocol", "user", "clash_mode", "rule_set", "auth_user", "client", "pcap"]
    if not any(c in r for c in conditions):
        return True
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
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f4f6f9; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; padding: 20px; }
        .login-box { background: #fff; padding: 30px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); text-align: center; width: 100%; max-width: 320px; }
        h3 { color: #333; margin-top: 0; margin-bottom: 20px; }
        input { padding: 12px; width: 100%; border: 1px solid #ddd; border-radius: 6px; margin-bottom: 15px; font-size: 16px; text-align: center; }
        button { padding: 12px 24px; background: #1a73e8; color: #fff; border: none; border-radius: 6px; cursor: pointer; font-size: 16px; font-weight: bold; width: 100%; }
        button:hover { background: #1557b0; }
    </style>
</head>
<body>
    <div class="login-box">
        <h3>面板登录</h3>
        <input type="password" id="pwd" placeholder="请输入访问密码">
        <button onclick="login()">登 录</button>
    </div>
    <script>
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
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <title>Sing-box 分流面板</title>
    <style>
        * { box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 950px; margin: 0 auto; padding: 15px; background: #f4f6f9; color: #333; }
        h2 { color: #1a73e8; margin-top: 0; border-bottom: 2px solid #e0e0e0; padding-bottom: 10px; }
        .card { background: #fff; padding: 15px; margin-bottom: 15px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
        .table-container { width: 100%; overflow-x: auto; }
        table { width: 100%; min-width: 600px; border-collapse: collapse; margin-top: 10px; }
        th, td { padding: 10px; border-bottom: 1px solid #eee; text-align: left; font-size: 14px; vertical-align: top; }
        th { background: #fafafa; color: #555; }
        select, input[type="text"] { width: 100%; max-width: 300px; padding: 8px; border-radius: 6px; border: 1px solid #ccc; margin-bottom: 5px; font-size: 14px; }
        button { padding: 8px 16px; background: #1a73e8; color: white; border: none; border-radius: 6px; cursor: pointer; font-size: 14px; transition: all 0.2s; }
        button:hover:not(:disabled) { background: #1557b0; }
        button:disabled { cursor: not-allowed; opacity: 0.6; }
        .success { background: #137333; }
        .success:hover:not(:disabled) { background: #0b5121; }
        .danger { background: #d93025; }
        .danger:hover:not(:disabled) { background: #b31412; }
        .edit-btn { background: #e8f0fe; color: #1a73e8; font-size: 12px; padding: 3px 8px; margin-top: 6px; border-radius: 4px; border: 1px solid #d2e3fc; display: inline-block; cursor: pointer; font-weight: bold; }
        .edit-btn:hover { background: #d2e3fc; }
        .form-group { margin-bottom: 15px; }
        .form-group label { display: block; font-weight: bold; margin-bottom: 5px; }
        .type-badge { display: inline-block; padding: 3px 8px; border-radius: 4px; font-weight: 600; font-size: 12px; background: #e8f0fe; color: #1a73e8; }
        .type-badge.all { background: #fce8e6; color: #d93025; }
        
        .modal-overlay { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); z-index: 99; }
        .modal-content { display: none; position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background: #fff; padding: 20px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.15); z-index: 100; width: 90%; max-width: 400px; }
    </style>
</head>
<body>
    <h2>🚀 分流与节点管理</h2>
    <div class="card" style="text-align: right; background: #f8f9fa;">
        <button class="success" onclick="syncFanout(this)">🔄 同步 Fanout 节点</button>
    </div>

    <div class="card">
        <h3>➕ 添加规则</h3>
        <div class="form-group">
            <label>规则类型与内容:</label>
            <select id="new-rule-type" onchange="toggleRuleInput('new')">
                <option value="domain_suffix">域名后缀</option>
                <option value="rule_set">规则集</option>
            </select>
            <input type="text" id="new-domain-value" placeholder="输入域名 (留空则匹配所有流量)">
            <select id="new-ruleset-select" style="display: none;"></select>
        </div>
        <div class="form-group">
            <label>生效节点:</label>
            <select id="new-rule-inbounds" multiple style="height: 70px;"></select>
            <div style="font-size:12px; color:#666; margin-top:2px;">留空则默认对全部节点生效</div>
        </div>
        <div class="form-group">
            <label>出站节点:</label>
            <select id="new-rule-outbound"></select>
            <button onclick="addRule(this)" style="width: 100%; max-width: 300px; margin-top: 10px;">确认添加规则</button>
        </div>
    </div>

    <div class="card">
        <h3>⚡ 已有分流规则列表</h3>
        <div class="table-container">
            <table>
                <thead>
                    <tr>
                        <th style="width: 15%;">类型</th>
                        <th style="width: 30%;">内容</th>
                        <th style="width: 15%;">入口</th>
                        <th style="width: 15%;">出站</th>
                        <th style="width: 25%;">操作</th>
                    </tr>
                </thead>
                <tbody id="rules-table">
                    <tr><td colspan="5" style="text-align:center;">加载中...</td></tr>
                </tbody>
            </table>
        </div>
    </div>

    <div id="modalOverlay" class="modal-overlay" onclick="closeEditModal()"></div>
    <div id="editModal" class="modal-content">
        <h3 style="margin-top:0;">✏️ 修改规则内容</h3>
        <input type="hidden" id="edit-idx">
        <div class="form-group">
            <label>新规则类型与内容:</label>
            <select id="edit-rule-type" onchange="toggleRuleInput('edit')" style="width: 100%; max-width: 100%;">
                <option value="domain_suffix">域名后缀</option>
                <option value="rule_set">规则集</option>
            </select>
            <input type="text" id="edit-domain-value" placeholder="输入域名 (留空则匹配所有流量)" style="width: 100%; max-width: 100%; margin-top: 8px;">
            <select id="edit-ruleset-select" style="display: none; width: 100%; max-width: 100%; margin-top: 8px;"></select>
        </div>
        <div style="display: flex; gap: 10px; margin-top: 20px;">
            <button onclick="saveEdit(this)" style="flex: 1;">保存修改</button>
            <button onclick="closeEditModal()" style="flex: 1; background: #f1f3f4; color: #333;">取消</button>
        </div>
    </div>

<script>
let globalData = { outbounds: [], inbounds: [], available_rule_sets: [], rules: [] };

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

async function loadData() {
    try {
        let res = await fetch('/api/status?' + new Date().getTime());
        if (res.status === 401) {
            window.location.reload();
            return;
        }
        globalData = await res.json();
        
        let outHtml = '';
        globalData.outbounds.forEach(o => outHtml += `<option value="${o}">${o}</option>`);
        document.getElementById('new-rule-outbound').innerHTML = outHtml || '<option disabled>(无可用出站)</option>';

        let inHtml = '';
        globalData.inbounds.forEach(ib => inHtml += `<option value="${ib}">${ib}</option>`);
        document.getElementById('new-rule-inbounds').innerHTML = inHtml || '<option disabled>(无入站节点)</option>';

        let rsHtml = '<option value="">(不选择，匹配所有流量)</option>';
        globalData.available_rule_sets.forEach(rs => rsHtml += `<option value="${rs}">${rs}</option>`);
        document.getElementById('new-ruleset-select').innerHTML = rsHtml;

        let ruleHtml = '';
        if (globalData.rules.length === 0) {
            ruleHtml = '<tr><td colspan="5" style="text-align:center; color:#888;">暂无规则</td></tr>';
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
                
                let typeName = r.type === 'domain_suffix' ? '域名后缀' : (r.type === 'rule_set' ? '规则集' : '全部流量');
                let badgeClass = r.type === 'match_all' ? 'type-badge all' : 'type-badge';
                let inboundsText = (r.inbounds && r.inbounds.length > 0) ? r.inbounds.join('<br>') : '<span style="color:#888;">全部</span>';
                
                ruleHtml += `<tr>
                    <td><span class="${badgeClass}">${typeName}</span></td>
                    <td>
                        <div style="word-break: break-all;"><b>${r.values}</b></div>
                        <div class="edit-btn" onclick="openEditModal(${idx})">✏️ 修改内容</div>
                    </td>
                    <td><span style="font-size:12px; color:#555;">${inboundsText}</span></td>
                    <td><span style="color: #1a73e8; font-weight:600;">${r.outbound}</span></td>
                    <td>
                        <select id="rule-sel-${idx}" style="width: auto; margin-bottom: 5px;">${opts}</select>
                        <div style="display: flex; gap: 5px;">
                            <button onclick="updateRule(${idx}, this)" style="padding: 4px 8px;">切换</button>
                            <button class="danger" onclick="deleteRule(${idx}, this)" style="padding: 4px 8px;">删除</button>
                        </div>
                    </td>
                </tr>`;
            });
        }
        document.getElementById('rules-table').innerHTML = ruleHtml;
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

// 通用异步请求处理：不弹成功提示，强制转3秒给后台重启留时间
async function handleReq(btn, reqPromise, onSuccess) {
    let oldHtml = btn.innerHTML;
    btn.innerHTML = "⏳ 处理中...";
    btn.disabled = true;
    
    let resObj = null;
    try {
        let res = await reqPromise;
        resObj = await res.json();
        // 只有报错时才提示
        if (resObj.code !== 0) {
            alert(resObj.msg);
        } else if (onSuccess) {
            onSuccess();
        }
    } catch (e) {
        alert("网络请求异常");
    }

    // 强制按钮转3秒钟
    setTimeout(() => {
        btn.innerHTML = oldHtml;
        btn.disabled = false;
        if (resObj && resObj.code === 0) {
            loadData(); // 数据更新
        }
    }, 3000);
}

function syncFanout(btn) {
    let req = fetch('/api/sync_fanout?' + new Date().getTime());
    handleReq(btn, req);
}

function addRule(btn) {
    let type = document.getElementById('new-rule-type').value;
    let outbound = document.getElementById('new-rule-outbound').value;
    let val = type === 'domain_suffix' ? document.getElementById('new-domain-value').value.trim() : document.getElementById('new-ruleset-select').value;

    let inboundsSelect = document.getElementById('new-rule-inbounds');
    let selectedInbounds = Array.from(inboundsSelect.selectedOptions).map(opt => opt.value);

    let req = fetch('/api/add_rule', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ type: type, value: val, inbounds: selectedInbounds, outbound: outbound })
    });
    
    handleReq(btn, req, () => {
        document.getElementById('new-domain-value').value = '';
    });
}

function updateRule(idx, btn) {
    let val = document.getElementById(`rule-sel-${idx}`).value;
    let req = fetch(`/api/set_rule?index=${idx}&outbound=${encodeURIComponent(val)}&` + new Date().getTime());
    handleReq(btn, req);
}

function deleteRule(idx, btn) {
    if (!confirm('确认删除？')) return;
    let req = fetch(`/api/del_rule?index=${idx}&` + new Date().getTime());
    handleReq(btn, req);
}

function saveEdit(btn) {
    let idx = document.getElementById('edit-idx').value;
    let type = document.getElementById('edit-rule-type').value;
    let val = type === 'domain_suffix' ? document.getElementById('edit-domain-value').value.trim() : document.getElementById('edit-ruleset-select').value;

    let req = fetch('/api/edit_rule', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ index: parseInt(idx), type: type, value: val })
    });
    
    handleReq(btn, req, () => {
        closeEditModal();
    });
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
                input_pwd = cookies['auth'].value
                if input_pwd == WEB_PASSWORD:
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
                            if is_managed_rule(r):
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
                    if is_managed_rule(r):
                        if valid_rules == idx:
                            r["outbound"] = outbound
                            break
                        valid_rules += 1
                
                with open(ROUTE_FILE, "w") as f:
                    json.dump(r_json, f, indent=2)
                
                restart_singbox_async()
                msg = {"code": 0, "msg": "success"}
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
                    if is_managed_rule(r):
                        if valid_rules == idx:
                            target_i = i
                            break
                        valid_rules += 1
                
                if target_i != -1:
                    rules.pop(target_i)
                    with open(ROUTE_FILE, "w") as f:
                        json.dump(r_json, f, indent=2)
                    restart_singbox_async()
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
                r_type = data.get("type", "domain_suffix")
                val_str = data.get("value", "").strip()
                inbounds = data.get("inbounds", [])
                outbound = data.get("outbound")
                
                if not outbound:
                    raise Exception("未选择有效出站")

                with open(ROUTE_FILE, "r") as f:
                    r_json = json.load(f)
                
                new_rule = { "outbound": outbound }
                
                if val_str:
                    if r_type == "domain_suffix":
                        vals = [v.strip() for v in val_str.split(",") if v.strip()]
                        if vals:
                            new_rule["domain_suffix"] = vals
                    else:
                        new_rule["rule_set"] = [val_str]
                
                if inbounds and len(inbounds) > 0:
                    new_rule["inbound"] = inbounds

                if "rules" not in r_json["route"]:
                    r_json["route"]["rules"] = []
                
                r_json["route"]["rules"].insert(0, new_rule)
                
                with open(ROUTE_FILE, "w") as f:
                    json.dump(r_json, f, indent=2)
                
                restart_singbox_async()
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
                r_type = data.get("type", "domain_suffix")
                val_str = data.get("value", "").strip()
                
                with open(ROUTE_FILE, "r") as f:
                    r_json = json.load(f)
                
                rules = r_json["route"].get("rules", [])
                valid_rules = 0
                target_r = None
                
                for r in rules:
                    if is_managed_rule(r):
                        if valid_rules == idx:
                            target_r = r
                            break
                        valid_rules += 1
                
                if target_r is not None:
                    target_r.pop("domain_suffix", None)
                    target_r.pop("rule_set", None)
                    
                    if val_str:
                        if r_type == "domain_suffix":
                            vals = [v.strip() for v in val_str.split(",") if v.strip()]
                            if vals:
                                target_r["domain_suffix"] = vals
                        else:
                            target_r["rule_set"] = [val_str]
                    
                    with open(ROUTE_FILE, "w") as f:
                        json.dump(r_json, f, indent=2)
                    
                    restart_singbox_async()
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
                
            restart_singbox_async()
            return {"code": 0, "msg": "success"}
        except Exception as e:
            return {"code": 1, "msg": f"同步出错: {str(e)}"}

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", PORT), PanelHandler)
    print(WEB_PASSWORD)
    server.serve_forever()
EOF
