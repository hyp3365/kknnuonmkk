#!/bin/bash

CONFIG_FILE="/root/vps_config.conf"
SCRIPT_FILE="/root/vps_ultra_noaio.py"
SERVICE_FILE="/etc/systemd/system/vps_ultra_noaio.service"

green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

echo
green "=== VPS向电报推送运行信息脚本ai版 ==="
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
# Python 主程序（无 aiohttp + offset 自动修复 + CPU 分离）
# -------------------------
cat > "$SCRIPT_FILE" <<'PYEOF'
#!/usr/bin/env python3
import time, os, json, subprocess

CONFIG="/root/vps_config.conf"

def load_cfg():
    cfg={}
    with open(CONFIG) as f:
        exec(f.read(), cfg)
    return cfg

def get(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, timeout=5).decode().strip()
    except:
        return ""

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

def get_geo():
    try:
        r=get("curl -s http://ip-api.com/json/?lang=zh-CN")
        j=json.loads(r)
        return j.get("country",""), j.get("regionName",""), j.get("city","")
    except:
        return "","",""

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

def get_cpu_usage():
    usage = get("top -bn1 | grep 'Cpu(s)' | awk '{print $2}'")
    return usage + "%" if usage else "获取失败"

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

def get_disk():
    st=os.statvfs("/")
    total=st.f_blocks*st.f_frsize//1024**3
    free=st.f_bfree*st.f_frsize//1024**3
    used=total-free
    pct=used*100//total
    return used,total,pct

def uptime():
    sec=int(float(open("/proc/uptime").read().split()[0]))
    h=sec//3600
    m=(sec%3600)//60
    return f"{h} 小时 {m} 分钟"

def send(token, chat, text):
    text=text.replace('"','\\"')
    os.system(f'curl -s -X POST https://api.telegram.org/bot{token}/sendMessage -d chat_id={chat} -d text="{text}" >/dev/null')

def build(cfg):
    ipv4=get_ipv4()
    ipv6=get_ipv6()
    country,region,city=get_geo()
    cpu_model, cpu_cores, cpu_freq=get_cpu_info()
    cpu_usage=get_cpu_usage()
    mem_used, mem_total, mem_pct=get_mem()
    disk_used, disk_total, disk_pct=get_disk()
    up=uptime()

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

    t.append(f"\n📦 内存：{mem_pct}%（{mem_used}MB / {mem_total}MB）\n")
    t.append(f"💾 硬盘：{disk_pct}%（{disk_used}GB / {disk_total}GB）\n")
    t.append(f"\n⏳ 运行时间：{up}\n")

    return "".join(t)

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
Description=VPS Ultra-light Bot (No aiohttp)
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

# -------------------------
# t 菜单（含 CPU 信息/CPU 使用率分离）
# -------------------------
cat > /usr/local/bin/t <<'EOF'
#!/bin/bash
CONFIG="/root/vps_config.conf"
SERVICE="/etc/systemd/system/vps_ultra_noaio.service"

green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

load_cfg(){ . "$CONFIG"; }

save_cfg(){
cat > "$CONFIG" <<EOF2
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
INTERVAL="$INTERVAL"
HOSTNAME="$HOSTNAME"
PUSH_IP="$PUSH_IP"
PUSH_CPU_INFO="$PUSH_CPU_INFO"
PUSH_CPU_USAGE="$PUSH_CPU_USAGE"
EOF2
chmod 600 "$CONFIG"
}

restart_service(){
    systemctl daemon-reload
    systemctl restart vps_ultra_noaio.service
}

menu(){
    while true; do
        load_cfg
        echo
        green "====== VPS 超轻量版管理菜单 (t) ======"
        echo "主机名：$HOSTNAME"
        echo "推送间隔：$INTERVAL 秒"
        echo "IP 推送：$( [ "$PUSH_IP" = "1" ] && echo 开启 || echo 关闭 )"
        echo "CPU 信息：$( [ "$PUSH_CPU_INFO" = "1" ] && echo 开启 || echo 关闭 )"
        echo "CPU 使用率：$( [ "$PUSH_CPU_USAGE" = "1" ] && echo 开启 || echo 关闭 )"
        echo "--------------------------------------"
        echo "1) 开关 IP 推送"
        echo "2) 开关 CPU 信息（型号/核心/主频）"
        echo "3) 开关 CPU 使用率"
        echo "4) 修改推送间隔"
        echo "5) 修改主机名"
        echo "6) 重启服务"
        echo "7) 卸载"
        echo "q) 退出"
        read -rp "请选择: " c

        case "$c" in
            1)
                load_cfg
                [ "$PUSH_IP" = "1" ] && PUSH_IP=0 || PUSH_IP=1
                save_cfg
                restart_service
                ;;
            2)
                load_cfg
                [ "$PUSH_CPU_INFO" = "1" ] && PUSH_CPU_INFO=0 || PUSH_CPU_INFO=1
                save_cfg
                restart_service
                ;;
            3)
                load_cfg
                [ "$PUSH_CPU_USAGE" = "1" ] && PUSH_CPU_USAGE=0 || PUSH_CPU_USAGE=1
                save_cfg
                restart_service
                ;;
            4)
                read -rp "请输入新的推送间隔（>=60）： " new
                if [[ "$new" =~ ^[0-9]+$ ]] && [ "$new" -ge 60 ]; then
                    INTERVAL="$new"
                    save_cfg
                    restart_service
                else
                    red "无效输入"
                fi
                ;;
            5)
                read -rp "请输入新的主机名： " new
                if [ -n "$new" ]; then
                    HOSTNAME="$new"
                    save_cfg
                    restart_service
                else
                    red "主机名不能为空"
                fi
                ;;
            6)
                restart_service
                green "服务已重启"
                ;;
            7)
                read -rp "确认卸载？输入 yes： " ans
                if [ "$ans" = "yes" ]; then
                    systemctl disable --now vps_ultra_noaio.service
                    rm -f "$SERVICE"
                    rm -f "$CONFIG"
                    rm -f /root/vps_ultra_noaio.py
                    rm -f /usr/local/bin/t
                    systemctl daemon-reload
                    green "卸载完成"
                    exit 0
                fi
                ;;
            q|Q)
                exit 0
                ;;
            *)
                red "无效选项"
                ;;
        esac
    done
}

menu
EOF

chmod +x /usr/local/bin/t

green "安装完成！"
green "机器人已运行：vps_ultra_noaio.service"
green "管理命令：t"
green "Telegram 命令：/${HOSTNAME} /status /ip /cpu /help"
