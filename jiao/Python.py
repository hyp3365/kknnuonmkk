#!/usr/bin/env python3
import time, os, json, subprocess, signal

# ============================
# 这里写你的 BOT_TOKEN 和 CHAT_ID
# ============================
BOT_TOKEN = "在这里填你的BOT_TOKEN"
CHAT_ID = "在这里填你的CHAT_ID"

# 主机名（用于 /主机名 命令）
HOSTNAME = "MyServer"

# 推送间隔（秒）
INTERVAL = 180

# 开关
PUSH_IP = True
PUSH_CPU_INFO = True
PUSH_CPU_USAGE = True

# ============================
# 容器优雅退出
# ============================
RUNNING = True
def handle_stop(signum, frame):
    global RUNNING
    print("收到停止信号，正在退出…")
    RUNNING = False

signal.signal(signal.SIGTERM, handle_stop)
signal.signal(signal.SIGINT, handle_stop)

# ============================
# 工具函数
# ============================
def get(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, timeout=5).decode().strip()
    except:
        return ""

def get_ipv4():
    for u in ["https://api.ipify.org", "https://ifconfig.me/ip"]:
        r = get(f"curl -4s {u}")
        if "." in r:
            return r
    return "获取失败"

def get_ipv6():
    for u in ["https://v6.ident.me", "https://api6.ipify.org"]:
        r = get(f"curl -6s {u}")
        if ":" in r:
            return r
    return "获取失败"

def get_geo():
    try:
        r = get("curl -s http://ip-api.com/json/?lang=zh-CN")
        j = json.loads(r)
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
    usage = get("grep 'cpu ' /proc/stat | awk '{u=($2+$4)*100/($2+$4+$5)} END {print u}'")
    return f"{usage}%" if usage else "获取失败"

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

def send(chat, text):
    text=text.replace('"','\\"')
    os.system(f'curl -s -X POST https://api.telegram.org/bot{BOT_TOKEN}/sendMessage -d chat_id={chat} -d text="{text}" >/dev/null')

# ============================
# 构建推送内容
# ============================
def build():
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
    t.append(f"🖥 主机名：{HOSTNAME}\n")

    if PUSH_IP:
        t.append(f"🌐 IPv4：{ipv4}\n")
        t.append(f"🌐 IPv6：{ipv6}\n")

    t.append(f"\n📍 地区：{country} {region} {city}\n")

    if PUSH_CPU_INFO:
        t.append(f"\n🧠 CPU 型号：{cpu_model}\n")
        t.append(f"🔢 核心数：{cpu_cores}\n")
        t.append(f"⏱ 主频：{cpu_freq}\n")

    if PUSH_CPU_USAGE:
        t.append(f"🔥 CPU 使用率：{cpu_usage}\n")

    t.append(f"\n📦 内存：{mem_pct}%（{mem_used}MB / {mem_total}MB）\n")
    t.append(f"💾 硬盘：{disk_pct}%（{disk_used}GB / {disk_total}GB）\n")
    t.append(f"\n⏳ 运行时间：{up}\n")

    return "".join(t)

# ============================
# 主循环（含 offset 自动修复）
# ============================
def bot_loop():
    last=0
    offset=0
    empty_count=0

    while RUNNING:
        now=int(time.time())

        if now-last>=INTERVAL:
            send(CHAT_ID, build())
            last=now

        r=get(f"curl -s 'https://api.telegram.org/bot{BOT_TOKEN}/getUpdates?timeout=20&offset={offset}'")

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
            cid=msg.get("chat",{}).get("id",CHAT_ID)

            if text in (f"/{HOSTNAME}", "/status"):
                send(cid, build())

            elif text=="/ip":
                send(cid,f"IPv4：{get_ipv4()}\nIPv6：{get_ipv6()}")

            elif text=="/cpu":
                cpu_model, cpu_cores, cpu_freq=get_cpu_info()
                send(cid,f"CPU：{cpu_model}\n核心：{cpu_cores}\n主频：{cpu_freq}")

            elif text=="/help":
                send(cid,
                     f"/{HOSTNAME} - 查看状态\n"
                     "/status - 查看状态\n"
                     "/ip - 查看 IP\n"
                     "/cpu - 查看 CPU\n"
                )

        time.sleep(1)

# ============================
# 启动
# ============================
print("机器人已启动（Pterodactyl 容器模式）")
bot_loop()
print("机器人已退出")
