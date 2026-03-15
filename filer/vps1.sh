#!/bin/bash
# /root/vps_monitor.sh
# 一键安装：VPS 定时推送 + Telegram 交互机器人（/主机名 /status /ip /cpu /help）
# 兼容 Alpine / Debian / Ubuntu

CONFIG_FILE="/root/vps_config.conf"
SCRIPT_FILE="/root/vps_report.py"
BOT_FILE="/root/bot.py"
SERVICE_FILE="/etc/systemd/system/vps_report.service"
TIMER_FILE="/etc/systemd/system/vps_report.timer"
BOT_SERVICE_FILE="/etc/systemd/system/vps_bot.service"
CRON_MARK="# vps_report_cron_job"

green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }

echo
green "=== VPS 自动推送 + Telegram 机器人 安装器 ==="
green "提示：1 分钟 = 60 秒，输入推送间隔时请使用秒（例如 600 表示 10 分钟）"
echo

PKG_MANAGER=""
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
elif command -v apt >/dev/null 2>&1; then
    PKG_MANAGER="apt"
else
    red "未检测到 apk 或 apt 包管理器，请手动安装 python3, psutil, requests"
    exit 1
fi

green "检测到包管理器：$PKG_MANAGER"

install_deps() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        green "Alpine 系统：安装 python3 及模块"
        apk update
        apk add --no-cache python3 py3-pip curl
        apk add --no-cache py3-psutil py3-requests 2>/dev/null || true
        python3 -m pip install --no-cache-dir psutil requests >/dev/null 2>&1 || true
    else
        green "Debian/Ubuntu 系统：安装 python3 及模块"
        apt update -y
        apt install -y python3 python3-pip curl
        apt install -y python3-psutil python3-requests 2>/dev/null || true
        python3 -m pip install --no-cache-dir psutil requests >/dev/null 2>&1 || true
    fi
}

echo
python3 -c "import psutil,requests" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    green "缺少依赖，开始安装..."
    install_deps
else
    green "依赖已满足"
fi
echo

green "请输入 BOT_TOKEN："
read -r BOT_TOKEN

green "请输入 CHAT_ID："
read -r CHAT_ID

while true; do
    green "请输入推送间隔（秒，最少 60，1 分钟 = 60 秒）："
    read -r interval
    if [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -ge 60 ]; then
        break
    fi
    red "❗ 请输入整数秒，且最小为 60"
done

green "请输入主机名（仅英文/数字/下划线/短横线，可留空使用系统默认主机名）："
read -r CUSTOM_HOSTNAME
if [ -z "$CUSTOM_HOSTNAME" ]; then
    CUSTOM_HOSTNAME=$(hostname)
fi

PUSH_IP=1
PUSH_CPU=1

cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
INTERVAL="$interval"
HOSTNAME="$CUSTOM_HOSTNAME"
PUSH_IP="$PUSH_IP"
PUSH_CPU="$PUSH_CPU"
EOF
chmod 600 "$CONFIG_FILE"
green "配置已保存到 $CONFIG_FILE"
echo

# 生成 vps_report.py（支持 --print）
cat > "$SCRIPT_FILE" <<'PYEOF'
#!/usr/bin/env python3
import psutil, requests, datetime, socket, os, sys

cfg = {}
with open("/root/vps_config.conf") as f:
    exec(f.read(), cfg)

BOT_TOKEN = cfg.get("BOT_TOKEN", "")
CHAT_ID = cfg.get("CHAT_ID", "")
HOSTNAME = cfg.get("HOSTNAME", socket.gethostname())
PUSH_IP = str(cfg.get("PUSH_IP", "1"))
PUSH_CPU = str(cfg.get("PUSH_CPU", "1"))

def format_uptime():
    uptime_seconds = int(datetime.datetime.now().timestamp() - psutil.boot_time())
    hours = uptime_seconds // 3600
    minutes = (uptime_seconds % 3600) // 60
    return f"{hours} 小时 {minutes} 分钟"

def get_real_ipv6():
    urls = [
        "https://v6.ident.me",
        "https://api6.ipify.org",
        "https://ipv6.icanhazip.com",
        "https://ifconfig.co/ip"
    ]
    for u in urls:
        try:
            r = requests.get(u, timeout=5)
            ip = r.text.strip()
            if ":" in ip:
                return ip
        except:
            continue
    return ""

def get_geo_info():
    info = {"ipv4":"", "ipv6":"", "country":"", "region":"", "city":""}
    try:
        r = requests.get("https://api.ipify.org?format=json", timeout=5)
        info["ipv4"] = r.json().get("ip", "")
    except:
        pass
    info["ipv6"] = get_real_ipv6()
    try:
        r = requests.get("http://ip-api.com/json/?lang=zh-CN", timeout=6)
        data = r.json()
        info["country"] = data.get("country", "")
        info["region"] = data.get("regionName", "")
        info["city"] = data.get("city", "")
    except:
        pass
    return info

def get_cpu_info():
    model = "未知"
    freq = "未知"
    cores = psutil.cpu_count(logical=False) or 1
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if "model name" in line:
                    model = line.split(":", 1)[1].strip()
                if "Hardware" in line:
                    model = line.split(":", 1)[1].strip()
                if "cpu MHz" in line:
                    try:
                        mhz = float(line.split(":", 1)[1].strip())
                        freq = f"{mhz/1000:.2f} GHz" if mhz > 1000 else f"{mhz:.0f} MHz"
                    except:
                        pass
    except:
        pass
    if model == "未知":
        try:
            import subprocess
            out = subprocess.check_output("lscpu", shell=True).decode()
            for line in out.splitlines():
                if "Model name" in line:
                    model = line.split(":", 1)[1].strip()
                if "CPU max MHz" in line:
                    try:
                        mhz = float(line.split(":", 1)[1].strip())
                        freq = f"{mhz/1000:.2f} GHz"
                    except:
                        pass
        except:
            pass
    if model == "未知":
        try:
            import subprocess
            out = subprocess.check_output("dmidecode -t processor", shell=True).decode()
            for line in out.splitlines():
                if "Version:" in line:
                    model = line.split(":", 1)[1].strip()
        except:
            pass
    return model, cores, freq

def get_status_text():
    cpu = psutil.cpu_percent(interval=1)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    net = psutil.net_io_counters()
    sent = net.bytes_sent / 1024**3
    recv = net.bytes_recv / 1024**3
    uptime = format_uptime()

    geo = get_geo_info()
    ipv4 = geo["ipv4"]
    ipv6 = geo["ipv6"]
    country = geo["country"]
    region = geo["region"]
    city = geo["city"]

    cpu_model, cpu_cores, cpu_freq = get_cpu_info()

    parts = []
    parts.append("📡 VPS 状态报告\n")
    parts.append(f"🖥 主机名：{HOSTNAME}\n")

    if PUSH_IP == "1":
        parts.append(f"🌐 IPv4：{ipv4}\n")
        parts.append(f"🌐 IPv6：{ipv6}\n")
        parts.append(f"\n📍 地区：{country} {region} {city}\n")
    else:
        parts.append(f"\n📍 地区：{country} {region} {city}\n")

    if PUSH_CPU == "1":
        parts.append(f"\n🧠 CPU 型号：{cpu_model}\n")
        parts.append(f"🔢 核心数：{cpu_cores} 核\n")
        parts.append(f"⏱ 主频：{cpu_freq}\n")

    parts.append(f"\n🔥 CPU：{cpu}%\n")
    parts.append(f"📦 内存：{mem.percent}%（{mem.used//1024**2}MB / {mem.total//1024**2}MB）\n")
    parts.append(f"💾 硬盘：{disk.percent}%（{disk.used//1024**3}GB / {disk.total//1024**3}GB）\n")
    parts.append("\n📡 流量使用：\n")
    parts.append(f"⬆ 上传：{sent:.2f} GB\n")
    parts.append(f"⬇ 下载：{recv:.2f} GB\n")
    parts.append(f"\n⏳ 运行时间：{uptime}\n")
    parts.append(f"⏰ 时间：{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")

    return "".join(parts)

def send_tg(text):
    if not BOT_TOKEN or not CHAT_ID:
        return
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    data = {"chat_id": CHAT_ID, "text": text}
    try:
        requests.post(url, data=data, timeout=10)
    except:
        pass

if "--print" in sys.argv:
    print(get_status_text())
    sys.exit(0)

if __name__ == "__main__":
    send_tg(get_status_text())
PYEOF

chmod +x "$SCRIPT_FILE"
green "vps_report.py 已生成：$SCRIPT_FILE"
echo

# 生成 Telegram 机器人脚本 /root/bot.py
cat > "$BOT_FILE" <<'PYBOT'
#!/usr/bin/env python3
import requests, time, subprocess, os

CONFIG_FILE = "/root/vps_config.conf"

def load_config():
    cfg = {}
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            exec(f.read(), cfg)
    return cfg

def tg_send(token, chat_id, text):
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    try:
        requests.post(url, data={"chat_id": chat_id, "text": text}, timeout=10)
    except:
        pass

def get_status_text():
    try:
        out = subprocess.check_output(
            ["python3", "/root/vps_report.py", "--print"],
            stderr=subprocess.STDOUT
        ).decode()
        return out
    except Exception as e:
        return f"获取状态失败：{e}"

def get_ip_info():
    ipv4, ipv6 = "", ""
    try:
        ipv4 = requests.get("https://api.ipify.org").text.strip()
    except:
        ipv4 = "获取失败"
    try:
        ipv6 = requests.get("https://v6.ident.me", timeout=5).text.strip()
    except:
        ipv6 = "获取失败"
    return f"🌐 IPv4：{ipv4}\n🌐 IPv6：{ipv6}"

def get_cpu_info():
    try:
        out = subprocess.check_output(
            ["python3", "/root/vps_report.py", "--print"],
            stderr=subprocess.STDOUT
        ).decode()
        lines = out.splitlines()
        cpu_lines = [l for l in lines if "CPU 型号" in l or "核心数" in l]
        return "\n".join(cpu_lines) if cpu_lines else "无法获取 CPU 信息"
    except:
        return "无法获取 CPU 信息"

def main():
    print("Telegram Bot 已启动，等待消息…")
    offset = None
    while True:
        cfg = load_config()
        BOT_TOKEN = cfg.get("BOT_TOKEN", "")
        CHAT_ID = cfg.get("CHAT_ID", "")
        HOSTNAME = cfg.get("HOSTNAME", "server")

        if not BOT_TOKEN:
            time.sleep(5)
            continue

        url = f"https://api.telegram.org/bot{BOT_TOKEN}/getUpdates"
        params = {"timeout": 30, "offset": offset}
        try:
            r = requests.get(url, params=params, timeout=35)
            data = r.json()
        except:
            time.sleep(2)
            continue

        if "result" not in data:
            continue

        for item in data["result"]:
            offset = item["update_id"] + 1
            if "message" not in item:
                continue
            msg = item["message"]
            chat_id = msg["chat"]["id"]
            text = msg.get("text", "").strip()

            if text == f"/{HOSTNAME}":
                tg_send(BOT_TOKEN, chat_id, get_status_text())
                continue
            if text == "/status":
                tg_send(BOT_TOKEN, chat_id, get_status_text())
                continue
            if text == "/ip":
                tg_send(BOT_TOKEN, chat_id, get_ip_info())
                continue
            if text == "/cpu":
                tg_send(BOT_TOKEN, chat_id, get_cpu_info())
                continue
            if text == "/help":
                tg_send(BOT_TOKEN, chat_id,
                    f"可用命令：\n"
                    f"/{HOSTNAME} - 查看完整 VPS 状态\n"
                    f"/status - 查看完整 VPS 状态\n"
                    f"/ip - 查看 IP 信息\n"
                    f"/cpu - 查看 CPU 信息\n"
                )
                continue

            tg_send(BOT_TOKEN, chat_id, "未知命令，发送 /help 查看可用命令")

        time.sleep(1)

if __name__ == "__main__":
    main()
PYBOT

chmod +x "$BOT_FILE"
green "bot.py 已生成：$BOT_FILE"
echo

# systemd 或 crontab 定时
if pidof systemd >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
    green "检测到 systemd，生成 vps_report.service + vps_report.timer"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VPS Status Report

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $SCRIPT_FILE
EOF

    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run VPS Report Automatically

[Timer]
OnBootSec=30
OnUnitActiveSec=$interval

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vps_report.timer
    green "systemd 定时器已启用（每 $interval 秒）"
    echo "查看状态： systemctl status vps_report.timer"

    # 生成 bot 的 systemd 服务
    cat > "$BOT_SERVICE_FILE" <<EOF
[Unit]
Description=Telegram VPS Bot Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $BOT_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now vps_bot.service
    green "Telegram 机器人已启用（systemd 服务 vps_bot.service）"
else
    green "未检测到 systemd，使用 crontab（按分钟粒度）"
    minutes=$(( (interval + 59) / 60 ))
    if [ "$minutes" -lt 1 ]; then minutes=1; fi
    echo "将以每 $minutes 分钟执行一次（因为 crontab 以分钟为单位）"

    crontab -l 2>/dev/null | sed "/${CRON_MARK}/d" > /tmp/cron_tmp || true
    echo "*/$minutes * * * * /usr/bin/python3 $SCRIPT_FILE $CRON_MARK" >> /tmp/cron_tmp
    crontab /tmp/cron_tmp
    rm -f /tmp/cron_tmp
    green "crontab 已更新：每 $minutes 分钟执行一次"
    echo "查看 crontab： crontab -l"
fi

echo
green "安装完成。"
green "输入 1 并回车即可立即发送测试推送（无需手动输入命令），直接回车跳过。"
read -r CHOICE
if [ "$CHOICE" = "1" ]; then
    green "正在发送测试消息，请稍候..."
    /usr/bin/python3 "$SCRIPT_FILE"
    if [ $? -eq 0 ]; then
        green "测试消息已发送（请检查 Telegram）。"
    else
        red "测试消息发送可能失败，请手动运行： python3 /root/vps_report.py"
    fi
fi

# 创建交互命令 t
cat > /usr/local/bin/t <<'BASH'
#!/usr/bin/env bash
CONFIG="/root/vps_config.conf"
SCRIPT="/root/vps_report.py"
BOT="/root/bot.py"
SERVICE_FILE="/etc/systemd/system/vps_report.service"
TIMER_FILE="/etc/systemd/system/vps_report.timer"
BOT_SERVICE_FILE="/etc/systemd/system/vps_bot.service"
CRON_MARK="# vps_report_cron_job"
PROFILE_FILE="/etc/profile.d/vpsctl.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 身份运行此命令。"
  exit 1
fi

detect_pkgmgr(){
  if command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v apt >/dev/null 2>&1; then
    echo "apt"
  else
    echo ""
  fi
}

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
  : "${BOT_TOKEN:=}"
  : "${CHAT_ID:=}"
  : "${HOSTNAME:=$(hostname)}"
}

_write_cfg(){
  BOT_TOKEN_VAL="${BOT_TOKEN:-}"
  CHAT_ID_VAL="${CHAT_ID:-}"
  HOSTNAME_VAL="${HOSTNAME:-$(hostname)}"
  cat > "$CONFIG" <<EOF
BOT_TOKEN="$BOT_TOKEN_VAL"
CHAT_ID="$CHAT_ID_VAL"
INTERVAL="$INTERVAL"
HOSTNAME="$HOSTNAME_VAL"
PUSH_IP="$PUSH_IP"
PUSH_CPU="$PUSH_CPU"
EOF
  chmod 600 "$CONFIG"
}

toggle_push_ip(){
  _read_cfg
  if [ "$PUSH_IP" = "1" ]; then
    PUSH_IP=0
    echo "已关闭 IP 地址 推送"
  else
    PUSH_IP=1
    echo "已开启 IP 地址 推送"
  fi
  _write_cfg
}

toggle_push_cpu(){
  _read_cfg
  if [ "$PUSH_CPU" = "1" ]; then
    PUSH_CPU=0
    echo "已关闭 CPU 型号/核心 推送"
  else
    PUSH_CPU=1
    echo "已开启 CPU 型号/核心 推送"
  fi
  _write_cfg
}

set_interval(){
  read -rp "请输入新的推送间隔（秒，最小 60）： " new
  if ! [[ "$new" =~ ^[0-9]+$ ]] || [ "$new" -lt 60 ]; then
    echo "输入无效，必须为整数且 >= 60"
    return 1
  fi
  INTERVAL="$new"
  _write_cfg
  if _has_systemd; then
    if [ -f "$TIMER_FILE" ]; then
      sed -i "s/^OnUnitActiveSec=.*/OnUnitActiveSec=$INTERVAL/" "$TIMER_FILE"
      systemctl daemon-reload
      systemctl restart vps_report.timer
      echo "systemd timer 已更新为 $INTERVAL 秒并重启"
    else
      echo "未找到 $TIMER_FILE，无法更新 systemd timer"
    fi
  else
    minutes=$(( (INTERVAL + 59) / 60 ))
    if [ "$minutes" -lt 1 ]; then minutes=1; fi
    tmp=$(mktemp)
    crontab -l 2>/dev/null | sed "/${CRON_MARK}/d" > "$tmp" || true
    echo "*/$minutes * * * * /usr/bin/python3 $SCRIPT $CRON_MARK" >> "$tmp"
    crontab "$tmp"
    rm -f "$tmp"
    echo "crontab 已更新为每 $minutes 分钟执行一次"
  fi
}

send_once(){
  if [ -x "$SCRIPT" ]; then
    /usr/bin/python3 "$SCRIPT"
    echo "已触发一次推送（脚本已执行）"
  else
    echo "错误：找不到脚本 $SCRIPT"
  fi
}

show_info(){
  _read_cfg
  echo "当前配置："
  echo "  推送间隔（秒）： $INTERVAL"
  echo "  IP 推送： $( [ "$PUSH_IP" = "1" ] && echo "开启" || echo "关闭" )"
  echo "  CPU 推送： $( [ "$PUSH_CPU" = "1" ] && echo "开启" || echo "关闭" )"
  echo "  主机名： $HOSTNAME"
  echo
  echo "当前状态："
  if _has_systemd; then
    systemctl is-active --quiet vps_report.timer && echo "  定时器：已启用（systemd timer）" || echo "  定时器：未启用"
    systemctl is-active --quiet vps_bot.service && echo "  机器人：已启用（vps_bot.service）" || echo "  机器人：未启用"
  else
    crontab -l 2>/dev/null | grep -q "${CRON_MARK}" && echo "  定时器：已启用（crontab）" || echo "  定时器：未启用"
    echo "  机器人：无 systemd，需手动运行 $BOT"
  fi
}

bot_start(){
  if _has_systemd; then
    systemctl start vps_bot.service 2>/dev/null || echo "启动失败或未安装 vps_bot.service"
  else
    echo "当前系统无 systemd，无法管理 vps_bot.service"
  fi
}

bot_stop(){
  if _has_systemd; then
    systemctl stop vps_bot.service 2>/dev/null || echo "停止失败或未安装 vps_bot.service"
  else
    echo "当前系统无 systemd，无法管理 vps_bot.service"
  fi
}

bot_status(){
  if _has_systemd; then
    systemctl status vps_bot.service --no-pager
  else
    echo "当前系统无 systemd，无法管理 vps_bot.service"
  fi
}

set_hostname(){
  _read_cfg
  echo "当前主机名：$HOSTNAME"
  read -rp "请输入新的主机名（仅英文/数字/下划线/短横线）： " newname
  if [ -z "$newname" ]; then
    echo "主机名不能为空"
    return 1
  fi
  HOSTNAME="$newname"
  _write_cfg
  echo "主机名已更新为：$HOSTNAME"
}

_uninstall(){
  echo "即将卸载：将删除脚本、配置、systemd 定时器/cron 条目、别名，但不会删除 curl/python3/pip。"
  read -rp "确认要卸载并删除所有内容吗？输入 yes 确认： " ans
  if [ "$ans" != "yes" ]; then
    echo "已取消卸载。"
    return 0
  fi

  echo "正在停止并删除 systemd 服务（如果存在）..."

  if pidof systemd >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
    systemctl disable --now vps_report.timer 2>/dev/null || true
    systemctl disable --now vps_report.service 2>/dev/null || true
    systemctl disable --now vps_bot.service 2>/dev/null || true

    rm -f /etc/systemd/system/vps_report.service
    rm -f /etc/systemd/system/vps_report.timer
    rm -f /etc/systemd/system/vps_bot.service

    systemctl daemon-reload
    echo "systemd 服务与定时器已清理"
  else
    echo "未检测到 systemd，跳过 systemd 清理"
  fi

  echo "正在清理 crontab（如果存在）..."
  crontab -l 2>/dev/null | sed '/vps_report_cron_job/d' | crontab - 2>/dev/null || true

  echo "正在删除脚本与配置文件..."
  rm -f /root/vps_report.py
  rm -f /root/bot.py
  rm -f /root/vps_config.conf

  echo "正在删除命令与环境文件..."
  rm -f /usr/local/bin/t
  rm -f /etc/profile.d/vpsctl.sh
  echo "卸载完成"
}

menu(){
  while true; do
    echo
    echo "====== VPS推送管理 (快捷命令 t) ======"
    echo "0) 查看当前配置与状态"
    echo "1) 开启/关闭 IP地址 推送"
    echo "2) 开启/关闭 CPU型号/核心 推送"
    echo "3) 修改推送时间（秒）"
    echo "4) 卸载"
    echo "5) 启动 Telegram 机器人"
    echo "6) 停止 Telegram 机器人"
    echo "7) 查看 Telegram 机器人状态"
    echo "8) 修改主机名（影响 /主机名 命令）"
    echo "q) 退出"
    echo "================================"
    read -rp "请选择 (0/1/2/3/4/5/6/7/8/q): " choice
    case "$choice" in
      0) show_info ;;
      1) toggle_push_ip ;;
      2) toggle_push_cpu ;;
      3) set_interval ;;
      4) _uninstall; break ;;
      5) bot_start ;;
      6) bot_stop ;;
      7) bot_status ;;
      8) set_hostname ;;
      q|Q) break ;;
      *) echo "无效选项" ;;
    esac
  done
}

_read_cfg
if ! grep -q '^PUSH_IP=' "$CONFIG" 2>/dev/null || ! grep -q '^PUSH_CPU=' "$CONFIG" 2>/dev/null; then
  PUSH_IP="${PUSH_IP:-1}"
  PUSH_CPU="${PUSH_CPU:-1}"
  INTERVAL="${INTERVAL:-600}"
  _write_cfg
fi

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
green "已安装交互命令 t。重新登录或执行： source /etc/profile.d/vpsctl.sh"
green "在 Telegram 中可使用：/主机名 /status /ip /cpu /help"
