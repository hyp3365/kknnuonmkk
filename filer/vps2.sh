#!/bin/bash
# /root/vps_ultra.sh
# 超轻量版：单进程 bot + 定时推送，常驻内存约 6–10MB
# 兼容 Debian/Ubuntu/Alpine，安全卸载，不删 curl/python3

CONFIG_FILE="/root/vps_config.conf"
ULTRA_PY="/root/vps_ultra.py"
SERVICE_FILE="/etc/systemd/system/vps_ultra.service"
CRON_MARK="# vps_ultra_cron_job"

green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

echo
green "=== VPS 超轻量版：定时推送 + Telegram 机器人 一键安装 ==="
echo

PKG=""
if command -v apk >/dev/null 2>&1; then
  PKG="apk"
elif command -v apt >/dev/null 2>&1; then
  PKG="apt"
else
  red "未检测到 apk/apt，请手动安装 python3 和 curl"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  green "未检测到 curl，正在安装..."
  if [ "$PKG" = "apk" ]; then
    apk add --no-cache curl
  else
    apt update -y
    apt install -y curl
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  green "未检测到 python3，正在安装..."
  if [ "$PKG" = "apk" ]; then
    apk add --no-cache python3 py3-pip
  else
    apt update -y
    apt install -y python3 python3-pip
  fi
fi

if ! python3 -c "import aiohttp" >/dev/null 2>&1; then
  green "安装 aiohttp（超轻量网络库）..."
  python3 -m pip install --no-cache-dir aiohttp >/dev/null 2>&1 || {
    red "安装 aiohttp 失败，请检查网络后重试。"
    exit 1
  }
fi

echo
green "请输入 Telegram BOT_TOKEN："
read -r BOT_TOKEN
[ -z "$BOT_TOKEN" ] && { red "BOT_TOKEN 不能为空"; exit 1; }

green "请输入 Telegram CHAT_ID："
read -r CHAT_ID
[ -z "$CHAT_ID" ] && { red "CHAT_ID 不能为空"; exit 1; }

while true; do
  green "请输入推送间隔（秒，最少 60）："
  read -r INTERVAL
  if [[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$INTERVAL" -ge 60 ]; then
    break
  fi
  red "请输入 >=60 的整数秒"
done

green "请输入主机名（用于 /主机名 命令，留空则使用系统 hostname）："
read -r HOSTNAME
[ -z "$HOSTNAME" ] && HOSTNAME=$(hostname)

PUSH_IP=1
PUSH_CPU=1

cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
INTERVAL="$INTERVAL"
HOSTNAME="$HOSTNAME"
PUSH_IP="$PUSH_IP"
PUSH_CPU="$PUSH_CPU"
EOF
chmod 600 "$CONFIG_FILE"
green "配置已写入：$CONFIG_FILE"

cat > "$ULTRA_PY" <<'PYEOF'
#!/usr/bin/env python3
# 超轻量版：单进程 bot + 定时推送，aiohttp + /proc 采集

import asyncio
import aiohttp
import time
import os
import socket

CONFIG = "/root/vps_config.conf"

def load_cfg():
    cfg = {}
    if os.path.exists(CONFIG):
        with open(CONFIG) as f:
            exec(f.read(), cfg)
    # 默认值兜底
    cfg.setdefault("BOT_TOKEN", "")
    cfg.setdefault("CHAT_ID", "")
    cfg.setdefault("INTERVAL", "600")
    cfg.setdefault("HOSTNAME", socket.gethostname())
    cfg.setdefault("PUSH_IP", "1")
    cfg.setdefault("PUSH_CPU", "1")
    return cfg

async def get_ipv4(session):
    urls = [
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
        "https://ipv4.icanhazip.com"
    ]
    for u in urls:
        try:
            async with session.get(u, timeout=5) as r:
                t = (await r.text()).strip()
                if "." in t:
                    return t
        except:
            pass
    return "获取失败"

async def get_ipv6(session):
    urls = [
        "https://v6.ident.me",
        "https://api6.ipify.org",
        "https://ipv6.icanhazip.com"
    ]
    for u in urls:
        try:
            async with session.get(u, timeout=5) as r:
                t = (await r.text()).strip()
                if ":" in t:
                    return t
        except:
            pass
    return "获取失败"

def get_cpu_info():
    model = "未知"
    cores = 1
    freq = "未知"
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if "model name" in line:
                    model = line.split(":",1)[1].strip()
                if "cpu cores" in line:
                    try:
                        cores = int(line.split(":",1)[1].strip())
                    except:
                        pass
                if "cpu MHz" in line:
                    try:
                        mhz = float(line.split(":",1)[1].strip())
                        freq = f"{mhz/1000:.2f} GHz"
                    except:
                        pass
    except:
        pass
    return model, cores, freq

def get_mem():
    d = {}
    with open("/proc/meminfo") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                key = parts[0].rstrip(":")
                try:
                    d[key] = int(parts[1])
                except:
                    pass
    total = d.get("MemTotal", 1) // 1024
    free = d.get("MemAvailable", d.get("MemFree", 0)) // 1024
    used = total - free
    percent = used * 100 // total if total > 0 else 0
    return used, total, percent

def get_disk():
    st = os.statvfs("/")
    total = st.f_blocks * st.f_frsize // 1024**3
    free = st.f_bfree * st.f_frsize // 1024**3
    used = total - free
    percent = used * 100 // total if total > 0 else 0
    return used, total, percent

def get_uptime():
    with open("/proc/uptime") as f:
        sec = int(float(f.read().split()[0]))
    h = sec // 3600
    m = (sec % 3600) // 60
    return f"{h} 小时 {m} 分钟"

async def get_geo(session):
    try:
        async with session.get("http://ip-api.com/json/?lang=zh-CN", timeout=5) as r:
            j = await r.json()
            return j.get("country",""), j.get("regionName",""), j.get("city","")
    except:
        return "","",""

async def build_report(session, cfg):
    ipv4 = await get_ipv4(session)
    ipv6 = await get_ipv6(session)
    country, region, city = await get_geo(session)

    cpu_model, cpu_cores, cpu_freq = get_cpu_info()
    mem_used, mem_total, mem_pct = get_mem()
    disk_used, disk_total, disk_pct = get_disk()
    uptime = get_uptime()

    t = []
    t.append("📡 VPS 状态报告\n")
    t.append(f"🖥 主机名：{cfg['HOSTNAME']}\n")

    if cfg["PUSH_IP"] == "1":
        t.append(f"🌐 IPv4：{ipv4}\n")
        t.append(f"🌐 IPv6：{ipv6}\n")

    t.append(f"\n📍 地区：{country} {region} {city}\n")

    if cfg["PUSH_CPU"] == "1":
        t.append(f"\n🧠 CPU 型号：{cpu_model}\n")
        t.append(f"🔢 核心数：{cpu_cores}\n")
        t.append(f"⏱ 主频：{cpu_freq}\n")

    t.append(f"\n📦 内存：{mem_pct}%（{mem_used}MB / {mem_total}MB）\n")
    t.append(f"💾 硬盘：{disk_pct}%（{disk_used}GB / {disk_total}GB）\n")
    t.append(f"\n⏳ 运行时间：{uptime}\n")

    return "".join(t)

async def send_msg(session, token, chat_id, text):
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    try:
        await session.post(url, data={"chat_id": chat_id, "text": text})
    except:
        pass

async def bot_loop():
    cfg = load_cfg()
    token = cfg["BOT_TOKEN"]
    chat_id = cfg["CHAT_ID"]
    hostname = cfg["HOSTNAME"]
    interval = int(cfg["INTERVAL"])

    if not token or not chat_id:
        print("配置缺失 BOT_TOKEN/CHAT_ID")
        return

    offset = None
    last_push = 0

    async with aiohttp.ClientSession() as session:
        while True:
            now = int(time.time())
            if now - last_push >= interval:
                rep = await build_report(session, cfg)
                await send_msg(session, token, chat_id, rep)
                last_push = now

            try:
                url = f"https://api.telegram.org/bot{token}/getUpdates"
                params = {"timeout": 20, "offset": offset}
                async with session.get(url, params=params, timeout=25) as r:
                    data = await r.json()
            except:
                await asyncio.sleep(2)
                continue

            for item in data.get("result", []):
                offset = item["update_id"] + 1
                msg = item.get("message", {})
                text = msg.get("text", "").strip()
                cid = msg.get("chat", {}).get("id", chat_id)

                if text in (f"/{hostname}", "/status"):
                    rep = await build_report(session, cfg)
                    await send_msg(session, token, cid, rep)

                elif text == "/ip":
                    ipv4 = await get_ipv4(session)
                    ipv6 = await get_ipv6(session)
                    await send_msg(session, token, cid, f"IPv4：{ipv4}\nIPv6：{ipv6}")

                elif text == "/cpu":
                    cpu_model, cpu_cores, cpu_freq = get_cpu_info()
                    await send_msg(session, token, cid,
                        f"CPU：{cpu_model}\n核心：{cpu_cores}\n主频：{cpu_freq}"
                    )

                elif text == "/help":
                    await send_msg(session, token, cid,
                        f"/{hostname} - 查看状态\n"
                        "/status - 查看状态\n"
                        "/ip - 查看 IP\n"
                        "/cpu - 查看 CPU\n"
                    )

            await asyncio.sleep(1)

if __name__ == "__main__":
    asyncio.run(bot_loop())
PYEOF

chmod +x "$ULTRA_PY"
green "超轻量核心脚本已生成：$ULTRA_PY"

if pidof systemd >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
  green "检测到 systemd，创建 vps_ultra.service..."
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS Ultra-light Telegram Bot + Reporter
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $ULTRA_PY
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now vps_ultra.service
  green "已启动并设置开机自启：vps_ultra.service"
else
  green "未检测到 systemd，使用 crontab 每分钟拉起一次（若未运行）"
  cat > /usr/local/bin/vps_ultra_wrapper.sh <<'SH'
#!/bin/sh
if ! pgrep -f "vps_ultra.py" >/dev/null 2>&1; then
  /usr/bin/python3 /root/vps_ultra.py &
fi
SH
  chmod +x /usr/local/bin/vps_ultra_wrapper.sh
  crontab -l 2>/dev/null | sed "/$CRON_MARK/d" > /tmp/cron_ultra 2>/dev/null || true
  echo "*/1 * * * * /usr/local/bin/vps_ultra_wrapper.sh $CRON_MARK" >> /tmp/cron_ultra
  crontab /tmp/cron_ultra
  rm -f /tmp/cron_ultra
  green "已写入 crontab，每分钟确保进程存在。"
fi

cat > /usr/local/bin/t <<'BASH'
#!/usr/bin/env bash
CONFIG="/root/vps_config.conf"
SERVICE_FILE="/etc/systemd/system/vps_ultra.service"
CRON_MARK="# vps_ultra_cron_job"

if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 运行。"
  exit 1
fi

_has_systemd(){
  if pidof systemd >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
    return 0
  fi
  return 1
}

_read_cfg(){
  if [ -f "$CONFIG" ]; then
    . "$CONFIG"
  fi
  : "${PUSH_IP:=1}"
  : "${PUSH_CPU:=1}"
  : "${INTERVAL:=600}"
  : "${HOSTNAME:=$(hostname)}"
}

_write_cfg(){
  cat > "$CONFIG" <<EOF
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
INTERVAL="$INTERVAL"
HOSTNAME="$HOSTNAME"
PUSH_IP="$PUSH_IP"
PUSH_CPU="$PUSH_CPU"
EOF
  chmod 600 "$CONFIG"
}

show_info(){
  _read_cfg
  echo "当前配置："
  echo "  主机名：$HOSTNAME"
  echo "  推送间隔：$INTERVAL 秒"
  echo "  IP 推送：$( [ "$PUSH_IP" = "1" ] && echo 开启 || echo 关闭 )"
  echo "  CPU 推送：$( [ "$PUSH_CPU" = "1" ] && echo 开启 || echo 关闭 )"
  echo
  if _has_systemd; then
    systemctl is-active --quiet vps_ultra.service && echo "服务状态：运行中 (systemd)" || echo "服务状态：未运行 (systemd)"
  else
    pgrep -f "vps_ultra.py" >/dev/null 2>&1 && echo "服务状态：运行中 (手动/cron)" || echo "服务状态：未运行"
  fi
}

toggle_ip(){
  _read_cfg
  if [ "$PUSH_IP" = "1" ]; then
    PUSH_IP=0
    echo "已关闭 IP 推送"
  else
    PUSH_IP=1
    echo "已开启 IP 推送"
  fi
  _write_cfg
}

toggle_cpu(){
  _read_cfg
  if [ "$PUSH_CPU" = "1" ]; then
    PUSH_CPU=0
    echo "已关闭 CPU 推送"
  else
    PUSH_CPU=1
    echo "已开启 CPU 推送"
  fi
  _write_cfg
}

set_interval(){
  _read_cfg
  read -rp "请输入新的推送间隔（秒，>=60）： " new
  if ! [[ "$new" =~ ^[0-9]+$ ]] || [ "$new" -lt 60 ]; then
    echo "无效输入"
    return
  fi
  INTERVAL="$new"
  _write_cfg
  echo "已更新配置文件中的 INTERVAL=$INTERVAL（超轻量版内部按该值控制推送频率）"
}

set_hostname(){
  _read_cfg
  echo "当前主机名：$HOSTNAME"
  read -rp "请输入新的主机名： " new
  [ -z "$new" ] && { echo "主机名不能为空"; return; }
  HOSTNAME="$new"
  _write_cfg
  echo "已更新主机名为：$HOSTNAME"
}

_uninstall(){
  echo "即将卸载：删除脚本、配置、systemd/crontab，但不会删除 curl/python3。"
  read -rp "确认卸载？输入 yes 确认： " ans
  [ "$ans" != "yes" ] && { echo "已取消。"; return; }

  if _has_systemd; then
    systemctl disable --now vps_ultra.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo "已清理 systemd 服务。"
  else
    crontab -l 2>/dev/null | sed "/$CRON_MARK/d" | crontab - 2>/dev/null || true
    echo "已清理 crontab 条目。"
  fi

  rm -f /root/vps_ultra.py
  rm -f /root/vps_config.conf
  rm -f /usr/local/bin/t
  rm -f /usr/local/bin/vps_ultra_wrapper.sh
  rm -f /etc/profile.d/vpsctl.sh

  echo "卸载完成。curl/python3 保留，你可以随时重新安装。"
}

menu(){
  while true; do
    echo
    echo "====== VPS 超轻量版管理 (t) ======"
    echo "0) 查看当前配置与状态"
    echo "1) 开启/关闭 IP 推送"
    echo "2) 开启/关闭 CPU 推送"
    echo "3) 修改推送间隔（秒）"
    echo "4) 修改主机名（影响 /主机名 命令）"
    echo "5) 卸载"
    echo "q) 退出"
    read -rp "请选择: " c
    case "$c" in
      0) show_info ;;
      1) toggle_ip ;;
      2) toggle_cpu ;;
      3) set_interval ;;
      4) set_hostname ;;
      5) _uninstall; break ;;
      q|Q) break ;;
      *) echo "无效选项" ;;
    esac
  done
}

menu
BASH

chmod +x /usr/local/bin/t

cat > /etc/profile.d/vpsctl.sh <<'SH'
if [ -x /usr/local/bin/t ]; then
  alias t='/usr/local/bin/t'
fi
SH
chmod +x /etc/profile.d/vpsctl.sh

echo
green "安装完成："
green "  - 超轻量核心：$ULTRA_PY"
green "  - 管理命令：t（重新登录或执行 source /etc/profile.d/vpsctl.sh 生效）"
green "  - Telegram 命令：/${HOSTNAME} /status /ip /cpu /help"
