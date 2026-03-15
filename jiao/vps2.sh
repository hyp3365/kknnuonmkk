#!/bin/bash
CONFIG_FILE="/root/vps_config.conf"
SCRIPT_FILE="/root/vps_ultra_noaio.py"
SERVICE_FILE="/etc/systemd/system/vps_ultra_noaio.service"

green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

echo
green "=== VPS向电报推送运行信息脚本 ==="
echo

# -------------------------
# 依赖检查
# -------------------------
if ! command -v curl >/dev/null 2>&1; then
    green "安装 curl..."
    apt update -y
    apt install -y curl
fi

if ! command -v python3 >/dev/null 2>&1; then
    green "安装 python3..."
    apt update -y
    apt install -y python3
fi

# -------------------------
# 用户输入
# -------------------------
green "请输入 BOT_TOKEN："
read -r BOT_TOKEN

green "请输入 CHAT_ID："
read -r CHAT_ID

green "请输入推送间隔（秒，>=60）："
read -r INTERVAL
[ -z "$INTERVAL" ] && INTERVAL=600

green "请输入主机名（用于 /主机名 命令）："
read -r HOSTNAME
[ -z "$HOSTNAME" ] && HOSTNAME=$(hostname)

# -------------------------
# 写入配置
# -------------------------
cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
INTERVAL="$INTERVAL"
HOSTNAME="$HOSTNAME"
PUSH_IP="1"
PUSH_CPU_INFO="1"
PUSH_CPU_USAGE="1"
EOF

chmod 600 "$CONFIG_FILE"

green "配置已写入：$CONFIG_FILE"

# -------------------------
# 写入 Python 主程序（多网卡合计 + 每月重置）
# -------------------------
cat > "$SCRIPT_FILE" <<'PYEOF'
#!/usr/bin/env python3
import time, os, json, subprocess, re

CONFIG="/root/vps_config.conf"
TRAFFIC_FILE="/root/vps_traffic.json"

# -------------------------
# 加载配置
# -------------------------
def load_cfg():
    cfg={}
    with open(CONFIG) as f:
        exec(f.read(), cfg)
    return cfg

# -------------------------
# 通用执行命令
# -------------------------
def get(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, timeout=5).decode().strip()
    except:
        return ""

# -------------------------
# IP 获取
# -------------------------
def get_ipv4():
    for u in ["https://api.ipify.org", "https://ifconfig.me/ip"]:
        r=get(f"curl -4s {u}")
        if "." in r:
            return r
    return "获取失败"

def get_ipv6():
    for u in ["https://v6.ident.me", "https://api6.ipify.org"]:
        r=get(f"curl -6s {u}")
        if ":" in r:
            return r
    return "获取失败"

# -------------------------
# 地区
# -------------------------
def get_geo():
    try:
        r=get("curl -s http://ip-api.com/json/?lang=zh-CN")
        j=json.loads(r)
        return j.get("country",""), j.get("regionName",""), j.get("city","")
    except:
        return "","",""

# -------------------------
# CPU 信息
# -------------------------
def get_cpu_info():
    model="未知"; cores="未知"; freq="未知"
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if "model name" in line:
                    model=line.split(":",1)[1].strip()
                if "cpu cores" in line:
                    cores=line.split(":",1)[1].strip()
                if "cpu MHz" in line:
                    mhz=float(line.split(":",1)[1].strip())
                    freq=f"{mhz/1000:.2f} GHz"
    except:
        pass
    return model, cores, freq

# -------------------------
# CPU 使用率
# -------------------------
def get_cpu_usage():
    usage = get("top -bn1 | grep 'Cpu(s)' | awk '{print $2}'")
    return usage + "%" if usage else "获取失败"

# -------------------------
# 内存
# -------------------------
def get_mem():
    d={}
    with open("/proc/meminfo") as f:
        for line in f:
            k=line.split(":")[0]
            v=line.split()[1]
            d[k]=int(v)
    total=d["MemTotal"]//1024
    free=d.get("MemAvailable", d.get("MemFree"))//1024
    used=total-free
    pct=used*100//total
    return used,total,pct

# -------------------------
# 硬盘
# -------------------------
def get_disk():
    st=os.statvfs("/")
    total=st.f_blocks*st.f_frsize//1024**3
    free=st.f_bfree*st.f_frsize//1024**3
    used=total-free
    pct=used*100//total
    return used,total,pct

# -------------------------
# 运行时间
# -------------------------
def uptime():
    sec=int(float(open("/proc/uptime").read().split()[0]))
    h=sec//3600
    m=(sec%3600)//60
    return f"{h} 小时 {m} 分钟"

# ============================================================
# 多网卡流量统计（增量 + 累计 + 每月重置）
# ============================================================

def list_valid_ifaces():
    ifaces=[]
    with open("/proc/net/dev") as f:
        for line in f:
            if ":" not in line:
                continue
            iface=line.split(":")[0].strip()
            # 排除无意义网卡
            if iface in ["lo","docker0","virbr0"]:
                continue
            if iface.startswith("veth") or iface.startswith("br-"):
                continue
            ifaces.append(iface)
    return ifaces

def read_netdev_all():
    total_rx=0
    total_tx=0
    ifaces=list_valid_ifaces()

    with open("/proc/net/dev") as f:
        for line in f:
            if ":" not in line:
                continue
            iface=line.split(":")[0].strip()
            if iface not in ifaces:
                continue
            parts=re.split(r"\s+", line.replace(":", " ").strip())
            rx=int(parts[1])
            tx=int(parts[9])
            total_rx+=rx
            total_tx+=tx

    return total_rx, total_tx

def load_traffic():
    if not os.path.exists(TRAFFIC_FILE):
        return {"last_rx":0,"last_tx":0,"month_rx":0,"month_tx":0,"month":time.strftime("%Y-%m")}
    try:
        return json.load(open(TRAFFIC_FILE))
    except:
        return {"last_rx":0,"last_tx":0,"month_rx":0,"month_tx":0,"month":time.strftime("%Y-%m")}

def save_traffic(data):
    with open(TRAFFIC_FILE,"w") as f:
        json.dump(data,f)

def format_bytes(b):
    if b < 1024:
        return f"{b} B"
    if b < 1024**2:
        return f"{b/1024:.2f} KB"
    if b < 1024**3:
        return f"{b/1024**2:.2f} MB"
    return f"{b/1024**3:.2f} GB"

def get_traffic():
    rx, tx = read_netdev_all()
    data = load_traffic()
    now_month = time.strftime("%Y-%m")

    # 月份变化 → 重置累计
    if data["month"] != now_month:
        data = {"last_rx":rx,"last_tx":tx,"month_rx":0,"month_tx":0,"month":now_month}

    # 计算增量
    diff_rx = max(0, rx - data["last_rx"])
    diff_tx = max(0, tx - data["last_tx"])

    # 累计
    data["month_rx"] += diff_rx
    data["month_tx"] += diff_tx

    # 保存当前值
    data["last_rx"] = rx
    data["last_tx"] = tx

    save_traffic(data)

    return diff_rx, diff_tx, data["month_rx"], data["month_tx"]

# ============================================================

# -------------------------
# 发送消息
# -------------------------
def send(token, chat, text):
    text=text.replace('"','\\"')
    os.system(f'curl -s -X POST https://api.telegram.org/bot{token}/sendMessage -d chat_id={chat} -d text="{text}" >/dev/null')

# -------------------------
# 构建推送内容
# -------------------------
def build(cfg):
    ipv4=get_ipv4()
    ipv6=get_ipv6()
    country,region,city=get_geo()
    cpu_model, cpu_cores, cpu_freq=get_cpu_info()
    cpu_usage=get_cpu_usage()
    mem_used, mem_total, mem_pct=get_mem()
    disk_used, disk_total, disk_pct=get_disk()
    up=uptime()

    diff_rx, diff_tx, month_rx, month_tx = get_traffic()

    t=[]
    t.append("📡 VPS 状态报告\n")
    t.append(f"🖥 主机名：{cfg['HOSTNAME']}\n")

    if cfg["PUSH_IP"]=="1":
        t.append(f"🌐 IPv4：{ipv4}\n")
        t.append(f"🌐 IPv6：{ipv6}\n")

    t.append(f"\n📍 地区：{country} {region} {city}\n")

    if cfg["PUSH_CPU_INFO"]=="1":
        t.append(f"\n🧠 CPU 型号：{cpu_model}\n")
        t.append(f"🔢 核心数：{cpu_cores}\n")
        t.append(f"⏱ 主频：{cpu_freq}\n")

    if cfg["PUSH_CPU_USAGE"]=="1":
        t.append(f"🔥 CPU 使用率：{cpu_usage}\n")

    t.append("\n📶 流量（多网卡合计）：\n")
    t.append(f"⬇ 下载：{format_bytes(diff_rx)}（本月累计 {format_bytes(month_rx)}）\n")
    t.append(f"⬆ 上传：{format_bytes(diff_tx)}（本月累计 {format_bytes(month_tx)}）\n")

    t.append(f"\n📦 内存：{mem_pct}%（{mem_used}MB / {mem_total}MB）\n")
    t.append(f"💾 硬盘：{disk_pct}%（{disk_used}GB / {disk_total}GB）\n")
    t.append(f"\n⏳ 运行时间：{up}\n")

    return "".join(t)

# -------------------------
# 主循环
# -------------------------
def bot_loop():
    cfg=load_cfg()
    token=cfg["BOT_TOKEN"]
    chat=cfg["CHAT_ID"]
    hostname=cfg["HOSTNAME"]
    interval=int(cfg["INTERVAL"])

    last=0
    offset=0
    empty_count=0

    while True:
        now=int(time.time())

        if now-last>=interval:
            send(token, chat, build(cfg))
            last=now

        r=get(f"curl -s 'https://api.telegram.org/bot{token}/getUpdates?timeout=20&offset={offset}'")

        try:
            j=json.loads(r)
        except:
            offset=0
            empty_count=0
            time.sleep(1)
            continue

        result=j.get("result",[])

        if not result:
            empty_count+=1
            if empty_count>=10:
                offset=0
                empty_count=0
            time.sleep(1)
            continue

        empty_count=0

        for item in result:
            offset=item["update_id"]+1
            msg=item.get("message",{})
            text=msg.get("text","")
            cid=msg.get("chat",{}).get("id",chat)

            if text in (f"/{hostname}", "/status"):
                send(token,cid,build(cfg))

            elif text=="/ip":
                send(token,cid,f"IPv4：{get_ipv4()}\nIPv6：{get_ipv6()}")

            elif text=="/cpu":
                cpu_model, cpu_cores, cpu_freq=get_cpu_info()
                send(token,cid,f"CPU：{cpu_model}\n核心：{cpu_cores}\n主频：{cpu_freq}")

            elif text=="/help":
                send(token,cid,
                     f"/{hostname} - 查看状态\n"
                     "/status - 查看状态\n"
                     "/ip - 查看 IP\n"
                     "/cpu - 查看 CPU\n"
                )

        time.sleep(1)

if __name__=="__main__":
    bot_loop()
PYEOF

chmod +x "$SCRIPT_FILE"

# -------------------------
# systemd 服务
# -------------------------
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS Ultra-light Bot (Multi-NIC)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SCRIPT_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vps_ultra_noaio.service

green "安装完成！"
green "机器人已运行：vps_ultra_noaio.service"
green "Telegram 命令：/${HOSTNAME} /status /ip /cpu /help"
