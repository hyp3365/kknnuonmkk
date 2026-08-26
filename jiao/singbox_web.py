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
    password = str(random.randint(1000,9999))
    cfg = {
        "port": port,
        "password": password
    }
    try:
        os.makedirs(
            os.path.dirname(CONFIG_FILE),
            exist_ok=True
        )
        with open(CONFIG_FILE,"w") as f:
            json.dump(
                cfg,
                f,
                indent=2
            )
    except:
        pass
    return port,password
PORT, WEB_PASSWORD = load_or_generate_config()
SINGBOX_CONF = "/etc/sing-box/conf"
XRAY_CONF = "/etc/xray/conf"
SINGBOX_ROUTE_FILE = "/etc/sing-box/conf/route.json"
XRAY_ROUTE_FILE = "/etc/xray/conf/route.json"
SINGBOX_OUTBOUND_FILE = "/etc/sing-box/conf/outbounds.json"
XRAY_OUTBOUND_FILE = "/etc/xray/conf/outbounds.json"
SINGBOX_INBOUND_FILE = "/etc/sing-box/conf/inbounds.json"
XRAY_INBOUND_FILE = "/etc/xray/conf/inbounds.json"
FANOUT_FILE = "/var/lib/fanout/xray.json"
TAG_NAME_MAP = {
    "ipv6_only":"仅IPv6",
    "prefer_ipv6":"IPv6优先",
    "ipv4_only":"仅IPv4",
    "prefer_ipv4":"IPv4优先"
}
TAG_REVERSE_MAP = {
    v:k for k,v in TAG_NAME_MAP.items()
}
def get_tag_core(tag):
    for file,core in [
        (SINGBOX_OUTBOUND_FILE,"singbox"),
        (XRAY_OUTBOUND_FILE,"xray")
    ]:
        if not os.path.exists(file):
            continue
        try:
            with open(file,"r") as f:
                data=json.load(f)
            for o in data.get("outbounds",[]):
                if o.get("tag")==tag:
                    return core
        except:
            pass
    return None
def get_route_file(outbound):
    core=get_tag_core(outbound)
    if core=="singbox":
        return SINGBOX_ROUTE_FILE
    if core=="xray":
        return XRAY_ROUTE_FILE
    return SINGBOX_ROUTE_FILE
def restart_singbox_async():
    def restart():
        subprocess.run(
            [
                "systemctl",
                "restart",
                "sing-box"
            ],
            check=False
        )
    threading.Thread(
        target=restart,
        daemon=True
    ).start()
def restart_xray_async():
    def restart():
        subprocess.run(
            [
                "systemctl",
                "restart",
                "xray"
            ],
            check=False
        )
    threading.Thread(
        target=restart,
        daemon=True
    ).start()
def is_managed_rule(r):
    if not isinstance(r,dict):
        return False
    conditions=[
        "domain",
        "domain_suffix",
        "domain_keyword",
        "domain_regex",
        "rule_set",
        "geoip",
        "ip_cidr",
        "port",
        "port_range",
        "inbound",
        "network"
    ]
    if not any(
        x in r for x in conditions
    ):
        return True
    return True
LOGIN_PAGE = r"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>登录</title>
<style>
body{
font-family:sans-serif;
background:#f4f6f9;
display:flex;
height:100vh;
align-items:center;
justify-content:center;
}
.box{
background:white;
padding:25px;
border-radius:10px;
width:280px;
text-align:center;
}
input{
width:100%;
padding:10px;
margin:10px 0;
}
button{
width:100%;
padding:10px;
background:#1a73e8;
color:white;
border:0;
border-radius:6px;
}
</style>
</head>
<body>
<div class="box">
<h3>你好</h3>
<input
type="password"
id="pwd"
placeholder="密码">
<button onclick="login()">
登录
</button>
</div>
<script>
function login(){
let p=document.getElementById("pwd").value;
if(!p)return;
document.cookie=
"auth="+p+"; path=/; max-age=2592000";
location.reload();
}
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
<title>Sing-box 分流</title>
<style>
*{box-sizing:border-box}
body{
font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
width:100%;
max-width:900px;
margin:0 auto;
padding:10px;
background:#f4f6f9;
color:#333;
overflow-x:hidden;
}

.card{
width:100%;
overflow:hidden;
}

table{
width:100%;
min-width:650px;
border-collapse:collapse;
}

.table-box{
width:100%;
overflow-x:auto;
-webkit-overflow-scrolling:touch;
}

td,th{
padding:8px 6px;
font-size:13px;
white-space:nowrap;
}

button{
max-width:100%;
font-size:14px;
}

select,input{
width:100%;
max-width:100%;
font-size:14px;
}

.modal-content{
width:92%;
max-width:380px;
max-height:85vh;
overflow-y:auto;
}
h2{
color:#1a73e8;
margin:5px 0 12px;
border-bottom:2px solid #ddd;
padding-bottom:8px;
display:flex;
justify-content:space-between
}
.card{
background:#fff;
padding:14px 16px;
margin-bottom:14px;
border-radius:8px;
box-shadow:0 1px 4px rgba(0,0,0,.06)
}
button{
padding:8px 14px;
background:#1a73e8;
color:white;
border:0;
border-radius:6px;
cursor:pointer
}
button:disabled{
opacity:.6
}
.danger{
background:#d93025
}
.success{
background:#137333
}
table{
width:100%;
border-collapse:collapse
}
td,th{
padding:8px;
border-bottom:1px solid #eee;
font-size:13px
}
select,input{
width:100%;
padding:8px;
border-radius:6px;
border:1px solid #ccc
}
.modal-overlay{
display:none;
position:fixed;
top:0;
left:0;
width:100%;
height:100%;
background:rgba(0,0,0,.5)
}
.modal-content{
display:none;
position:fixed;
top:50%;
left:50%;
transform:translate(-50%,-50%);
background:white;
padding:20px;
border-radius:10px;
width:90%;
max-width:380px
}
</style>
</head>
<body>
<h2>
<span>🚀 分流</span>
<span id="conn-status">在线</span>
</h2>
<div class="card">
<button class="success"
onclick="syncFanout(this)"
style="width:100%">
🔄 同步节点
</button>
</div>
<div class="card">
<h3>➕ 添加规则</h3>
<select id="new-rule-type"
onchange="toggleRuleInput('new')">
<option value="domain_suffix">
域名后缀
</option>
<option value="rule_set">
规则集
</option>
</select>
<input id="new-domain-value"
placeholder="输入域名">
<select id="new-ruleset-select"
style="display:none">
</select>
<h4>入口节点</h4>
<select id="new-rule-inbounds"
multiple
style="height:80px">
</select>
<h4>出站节点</h4>
<select id="new-rule-outbound">
</select>
<button id="add-btn"
onclick="addRule()"
style="width:100%;margin-top:10px">
添加规则
</button>
</div>
<div class="card">
<h3>已有规则</h3>
<table>
<thead>
<tr>
<th>类型</th>
<th>内容</th>
<th>入口</th>
<th>出站</th>
<th>操作</th>
</tr>
</thead>
<tbody id="rules-table">
</tbody>
</table>
</div>
<div id="modalOverlay"
class="modal-overlay"
onclick="closeEditModal()"></div>
<div id="editModal"
class="modal-content">
<h3>
修改规则
</h3>
<input type="hidden"
id="edit-idx">
<select id="edit-rule-type"
onchange="toggleRuleInput('edit')">
<option value="domain_suffix">
域名后缀
</option>
<option value="rule_set">
规则集
</option>
</select>
<input id="edit-domain-value">
<select id="edit-ruleset-select"
style="display:none">
</select>
<br><br>
<button id="save-edit-btn"
onclick="saveEdit()">
保存
</button>
<button onclick="closeEditModal()">
取消
</button>
</div>
<script>
let globalData={
outbounds:[],
inbounds:[],
available_rule_sets:[],
rules:[]
};
function toggleRuleInput(prefix){
let type=document.getElementById(
prefix+"-rule-type"
).value;
document.getElementById(
prefix+"-domain-value"
).style.display=
type==="domain_suffix"?
"block":"none";
document.getElementById(
prefix+"-ruleset-select"
).style.display=
type==="rule_set"?
"block":"none";
}
function renderSelects(){
let out="";
globalData.outbounds.forEach(o=>{
out+=`<option>${o}</option>`;
});
document.getElementById(
"new-rule-outbound"
).innerHTML=out;
let ib="";
globalData.inbounds.forEach(i=>{
ib+=`<option>${i}</option>`;
});
document.getElementById(
"new-rule-inbounds"
).innerHTML=ib;
let rs="";
globalData.available_rule_sets.forEach(r=>{
rs+=`<option>${r}</option>`;
});
document.getElementById(
"new-ruleset-select"
).innerHTML=rs;
}
function renderTable(){
let html="";
globalData.rules.forEach((r,i)=>{
html+=`
<tr>
<td>${r.type}</td>
<td>
${r.values}
<br>
<button onclick="openEditModal(${i})">
修改
</button>
</td>
<td>
${r.inbounds.join("<br>")}
</td>
<td>
${r.outbound}
</td>
<td>
<select id="rule-sel-${i}">
${globalData.outbounds.map(o=>
`<option>${o}</option>`
).join("")}
</select>
<button onclick="updateRule(${i})">
切换
</button>
<button class="danger"
onclick="deleteRule(${i})">
删除
</button>
</td>
</tr>
`;
});
document.getElementById(
"rules-table"
).innerHTML=html;
}
async function loadData(){
let r=await fetch(
"/api/status?t="+Date.now()
);
if(r.status===401){
location.reload();
return;
}
globalData=await r.json();
renderSelects();
renderTable();
}
async function addRule(){
let type=
document.getElementById(
"new-rule-type"
).value;
let value=
type==="domain_suffix"
?
document.getElementById(
"new-domain-value"
).value
:
document.getElementById(
"new-ruleset-select"
).value;
let inbounds=
Array.from(
document.getElementById(
"new-rule-inbounds"
).selectedOptions
).map(x=>x.value);
let outbound=
document.getElementById(
"new-rule-outbound"
).value;
await fetch(
"/api/add_rule",
{
method:"POST",
headers:{
"Content-Type":"application/json"
},
body:JSON.stringify({
type,
value,
inbounds,
outbound
})
}
);
loadData();
}
async function updateRule(idx){
let outbound=document.getElementById(
`rule-sel-${idx}`
).value;
await fetch(
`/api/set_rule?index=${idx}&outbound=${encodeURIComponent(outbound)}`
);
loadData();
}
async function deleteRule(idx){
if(!confirm("确认删除？"))
return;
await fetch(
`/api/del_rule?index=${idx}`
);
loadData();
}
function openEditModal(idx){
let r=globalData.rules[idx];
document.getElementById(
"edit-idx"
).value=idx;
document.getElementById(
"edit-rule-type"
).value=r.type;
if(r.type==="rule_set"){
document.getElementById(
"edit-ruleset-select"
).value=r.values;
}else{
document.getElementById(
"edit-domain-value"
).value=r.values;
}
toggleRuleInput("edit");
document.getElementById(
"modalOverlay"
).style.display="block";
document.getElementById(
"editModal"
).style.display="block";
}
function closeEditModal(){
document.getElementById(
"modalOverlay"
).style.display="none";
document.getElementById(
"editModal"
).style.display="none";
}
async function saveEdit(){
let idx=document.getElementById(
"edit-idx"
).value;
let type=document.getElementById(
"edit-rule-type"
).value;
let value;
if(type==="domain_suffix"){
value=document.getElementById(
"edit-domain-value"
).value;
}else{
value=document.getElementById(
"edit-ruleset-select"
).value;
}
await fetch(
"/api/edit_rule",
{
method:"POST",
headers:{
"Content-Type":"application/json"
},
body:JSON.stringify({
index:parseInt(idx),
type:type,
value:value
})
}
);
closeEditModal();
loadData();
}
async function syncFanout(btn){
btn.disabled=true;
btn.innerHTML="处理中...";
await fetch(
"/api/sync_fanout?t="+Date.now()
);
setTimeout(()=>{
btn.disabled=false;
btn.innerHTML="🔄 同步节点";
loadData();
},2000);
}
loadData();
</script>
</body>
</html>
"""
class PanelHandler(http.server.BaseHTTPRequestHandler):
    def check_auth(self):
        global FAILED_LOCK_UNTIL
        now=time.time()
        if now < FAILED_LOCK_UNTIL:
            return False
        cookie=self.headers.get("Cookie")
        if cookie:
            c=http.cookies.SimpleCookie(cookie)
            if "auth" in c:
                if c["auth"].value == WEB_PASSWORD:
                    FAILED_LOCK_UNTIL=0
                    return True
                else:
                    FAILED_LOCK_UNTIL=now+30
                    time.sleep(1)
        return False
    def send_no_cache_response(self,code,ctype,data):
        self.send_response(code)
        self.send_header(
            "Content-Type",
            ctype
        )
        self.send_header(
            "Cache-Control",
            "no-store"
        )
        self.end_headers()
        self.wfile.write(data)
    def get_route_file(self):
    if os.path.exists(SINGBOX_ROUTE_FILE):
        return SINGBOX_ROUTE_FILE

    if os.path.exists(XRAY_ROUTE_FILE):
        return XRAY_ROUTE_FILE

    return SINGBOX_ROUTE_FILE
    def do_GET(self):
        parsed=urllib.parse.urlparse(self.path)
        path=parsed.path
        query=urllib.parse.parse_qs(
            parsed.query
        )
        if not self.check_auth():
            if path.startswith("/api"):
                self.send_no_cache_response(
                    401,
                    "application/json",
                    b'{"code":1}'
                )
            else:
                self.send_no_cache_response(
                    200,
                    "text/html;charset=utf-8",
                    LOGIN_PAGE.encode()
                )
            return
        if path=="/":
            self.send_no_cache_response(
                200,
                "text/html;charset=utf-8",
                HTML_PAGE.encode()
            )
        elif path=="/api/status":
            data={
                "outbounds":[],
                "inbounds":[],
                "available_rule_sets":[],
                "rules":[]
            }
            try:
                # 出站节点扫描
node_files = [
    "vmess-argo.json",
    "hysteria2.json",
    "xtls-reality.json",
    "tuic.json",
    "anytls.json",
    "vless-ws-cdn.json",
    "vmess-ws-cdn.json",
    "trojan-ws-cdn.json",
    "h2-reality.json",
    "endpoints.json"
]

# 先读取标准 outbounds
scan_files = [
    SINGBOX_OUTBOUND_FILE,
    XRAY_OUTBOUND_FILE
]

for nf in node_files:
    for d in [
        SINGBOX_CONF,
        XRAY_CONF
    ]:
        scan_files.append(
            os.path.join(d,nf)
        )


for file in scan_files:

    if not os.path.exists(file):
        continue

    try:
        with open(file,"r") as f:
            cfg=json.load(f)

        # outbounds
        for o in cfg.get("outbounds",[]):

            tag=o.get("tag")

            if tag and tag not in data["outbounds"]:
                data["outbounds"].append(
                    TAG_NAME_MAP.get(tag,tag)
                )

        # endpoints
        for ep in cfg.get("endpoints",[]):

            tag=ep.get("tag")

            if tag and tag not in data["outbounds"]:
                data["outbounds"].append(tag)


        # inbound 文件里的入口
        for ib in cfg.get("inbounds",[]):

            tag=ib.get("tag")

            if tag and tag not in data["inbounds"]:
                data["inbounds"].append(tag)

    except:
        pass
                    if not os.path.exists(file):
                        continue
                    with open(file,"r") as f:
                        cfg=json.load(f)
                    for o in cfg.get(
                        "outbounds",
                        []
                    ):
                        tag=o.get("tag")
                        if tag and tag not in data["outbounds"]:
                            data["outbounds"].append(
                                TAG_NAME_MAP.get(
                                    tag,
                                    tag
                                )
                            )
                # 入站
                for file in [
                    SINGBOX_INBOUND_FILE,
                    XRAY_INBOUND_FILE
                ]:
                    if not os.path.exists(file):
                        continue
                    with open(file,"r") as f:
                        cfg=json.load(f)
                    for ib in cfg.get(
                        "inbounds",
                        []
                    ):
                        tag=ib.get("tag")
                        if tag and tag not in data["inbounds"]:
                            data["inbounds"].append(tag)
                route_file=self.get_route_file()
                if os.path.exists(route_file):
                    with open(route_file,"r") as f:
                        r_json=json.load(f)
                    route=r_json.get(
                        "route",
                        {}
                    )
                    for rs in route.get(
                        "rule_set",
                        []
                    ):
                        if isinstance(rs,dict):
                            tag=rs.get("tag")
                        else:
                            tag=rs
                        if tag:
                            data["available_rule_sets"].append(tag)
                    for r in route.get(
                        "rules",
                        []
                    ):
                        if not is_managed_rule(r):
                            continue
                        r_type="match_all"
                        vals="(全匹配 - 所有流量)"
                        if "domain_suffix" in r:
                            r_type="domain_suffix"
                            vals=r["domain_suffix"]
                            if isinstance(vals,list):
                                vals=",".join(vals)
                        elif "rule_set" in r:
                            r_type="rule_set"
                            vals=r["rule_set"]
                            if isinstance(vals,list):
                                vals=",".join(vals)
                        inbound=r.get(
                            "inbound",
                            []
                        )
                        if isinstance(inbound,str):
                            inbound=[inbound]
                        data["rules"].append({
                            "type":r_type,
                            "values":vals,
                            "inbounds":inbound,
                            "outbound":r.get(
                                "outbound",
                                "direct"
                            )
                        })
            except Exception as e:
                pass
            self.send_no_cache_response(
                200,
                "application/json;charset=utf-8",
                json.dumps(
                    data,
                    ensure_ascii=False
                ).encode()
            )
        elif path=="/api/set_rule":
            try:
                idx=int(
                    query.get(
                        "index",
                        [0]
                    )[0]
                )
                outbound=query.get(
                    "outbound",
                    ["direct"]
                )[0]
                outbound=TAG_REVERSE_MAP.get(
                    outbound,
                    outbound
                )
                route_file=self.get_route_file()
                with open(route_file,"r") as f:
                    cfg=json.load(f)
                rules=cfg.get(
                    "route",
                    {}
                ).get(
                    "rules",
                    []
                )
                count=0
                for r in rules:
                    if is_managed_rule(r):
                        if count==idx:
                            r["outbound"]=outbound
                            break
                        count+=1
                with open(route_file,"w") as f:
                    json.dump(
                        cfg,
                        f,
                        indent=2,
                        ensure_ascii=False
                    )
                restart_singbox_async()
                msg={
                    "code":0,
                    "msg":"success"
                }
            except Exception as e:
                msg={
                    "code":1,
                    "msg":str(e)
                }
            self.send_no_cache_response(
                200,
                "application/json",
                json.dumps(msg).encode()
            )
    def do_GET_continue(self):
        pass
    def delete_rule(self,idx):
        route_file=self.get_route_file()
        with open(route_file,"r") as f:
            cfg=json.load(f)
        rules=cfg.get(
            "route",
            {}
        ).get(
            "rules",
            []
        )
        target=-1
        count=0
        for i,r in enumerate(rules):
            if is_managed_rule(r):
                if count==idx:
                    target=i
                    break
                count+=1
        if target!=-1:
            rules.pop(target)
        with open(route_file,"w") as f:
            json.dump(
                cfg,
                f,
                indent=2,
                ensure_ascii=False
            )
        restart_singbox_async()
    def do_POST(self):
        if not self.check_auth():
            self.send_no_cache_response(
                401,
                "application/json",
                b'{"code":1}'
            )
            return
        parsed=urllib.parse.urlparse(
            self.path
        )
        path=parsed.path
        length=int(
            self.headers.get(
                "Content-Length",
                0
            )
        )
        body=self.rfile.read(
            length
        ).decode()
        try:
            data=json.loads(body)
        except:
            data={}
        route_file=self.get_route_file()
        if path=="/api/add_rule":
            try:
                r_type=data.get(
                    "type",
                    "domain_suffix"
                )
                value=data.get(
                    "value",
                    ""
                ).strip()
                outbound=data.get(
                    "outbound"
                )
                outbound=TAG_REVERSE_MAP.get(
                    outbound,
                    outbound
                )
                new_rule={
                    "outbound":outbound
                }
                if value:
                    if r_type=="rule_set":
                        new_rule["rule_set"]=[value]
                    else:
                        new_rule["domain_suffix"]=[
                            x.strip()
                            for x in value.split(",")
                            if x.strip()
                        ]
                inbounds=data.get(
                    "inbounds",
                    []
                )
                if inbounds:
                    new_rule["inbound"]=inbounds
                with open(route_file,"r") as f:
                    cfg=json.load(f)
                if "route" not in cfg:
                    cfg["route"]={}
                if "rules" not in cfg["route"]:
                    cfg["route"]["rules"]=[]
                cfg["route"]["rules"].insert(
                    0,
                    new_rule
                )
                with open(route_file,"w") as f:
                    json.dump(
                        cfg,
                        f,
                        indent=2,
                        ensure_ascii=False
                    )
                restart_singbox_async()
                msg={
                    "code":0,
                    "msg":"success"
                }
            except Exception as e:
                msg={
                    "code":1,
                    "msg":str(e)
                }
            self.send_no_cache_response(
                200,
                "application/json",
                json.dumps(msg).encode()
            )
        elif path=="/api/del_rule":
            try:
                query=urllib.parse.parse_qs(
                    parsed.query
                )
                idx=int(
                    query.get(
                        "index",
                        [0]
                    )[0]
                )
                self.delete_rule(idx)
                msg={
                    "code":0,
                    "msg":"success"
                }
            except Exception as e:
                msg={
                    "code":1,
                    "msg":str(e)
                }
            self.send_no_cache_response(
                200,
                "application/json",
                json.dumps(msg).encode()
            )
    def do_sync_fanout_action(self):
        if not os.path.exists(FANOUT_FILE):
            return {
                "code":1,
                "msg":f"找不到文件 {FANOUT_FILE}"
            }
        try:
            with open(FANOUT_FILE,"r") as f:
                xray_data=json.load(f)
            nodes=[]
            for outbound in xray_data.get(
                "outbounds",
                []
            ):
                if outbound.get(
                    "protocol"
                ) != "socks":
                    continue
                tag=str(
                    outbound.get(
                        "tag",
                        ""
                    )
                )
                if "fanout-" not in tag:
                    continue
                servers=outbound.get(
                    "settings",
                    {}
                ).get(
                    "servers",
                    []
                )
                if not servers:
                    continue
                server=servers[0]
                users=server.get(
                    "users",
                    []
                )
                username=""
                password=""
                if users:
                    username=users[0].get(
                        "user",
                        ""
                    )
                    password=users[0].get(
                        "pass",
                        ""
                    )
                nodes.append({
                    "type":"socks",
                    "tag":f"fanout-{server.get('port')}",
                    "server":server.get(
                        "address"
                    ),
                    "server_port":server.get(
                        "port"
                    ),
                    "username":username,
                    "password":password
                })
            outbound_file=SINGBOX_OUTBOUND_FILE
            if os.path.exists(outbound_file):
                with open(outbound_file,"r") as f:
                    try:
                        outbound_data=json.load(f)
                    except:
                        outbound_data={
                            "outbounds":[]
                        }
            else:
                outbound_data={
                    "outbounds":[]
                }
            if "outbounds" not in outbound_data:
                outbound_data["outbounds"]=[]
            outbound_data["outbounds"]=[
                x
                for x in outbound_data["outbounds"]
                if not (
                    isinstance(x,dict)
                    and str(
                        x.get(
                            "tag",
                            ""
                        )
                    ).startswith(
                        "fanout-"
                    )
                )
            ]
            outbound_data["outbounds"].extend(
                nodes
            )
            os.makedirs(
                os.path.dirname(outbound_file),
                exist_ok=True
            )
            with open(outbound_file,"w") as f:
                json.dump(
                    outbound_data,
                    f,
                    indent=2,
                    ensure_ascii=False
                )
            restart_singbox_async()
            return {
                "code":0,
                "msg":"success"
            }
        except Exception as e:
            return {
                "code":1,
                "msg":f"同步失败: {str(e)}"
            }
if __name__=="__main__":
    server=http.server.HTTPServer(
        (
            "0.0.0.0",
            PORT
        ),
        PanelHandler
    )
    print(
        f"Panel running port {PORT}, password {WEB_PASSWORD}"
    )
    server.serve_forever()
