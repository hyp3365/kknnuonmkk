#!/bin/bash 
# /root/vps_monitor.sh
# 兼容 Alpine / Debian 的一键安装器（绿色提示、可选主机名、自动检测公网 IP 与国家）
# 安装完成后可输入 1 立即测试（无需手动输入命令）
# 提示：1 分钟 = 60 秒

CONFIG_FILE="/root/vps_config.conf"
SCRIPT_FILE="/root/vps_report.py"
SERVICE_FILE="/etc/systemd/system/vps_report.service"
TIMER_FILE="/etc/systemd/system/vps_report.timer"
CRON_MARK="# vps_report_cron_job"

# 颜色函数
green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }

echo
green "=== VPS 自动推送安装器 ==="
green "提示：1 分钟 = 60 秒，输入推送间隔时请使用秒（例如 600 表示 10 分钟）"
echo

# 检测包管理器
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

# 安装依赖函数
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

# 检查并安装依赖
echo
python3 -c "import psutil,requests" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    green "缺少依赖，开始安装..."
    install_deps
else
    green "依赖已满足"
fi
echo

# 交互输入配置（绿色提示）
green "请输入 BOT_TOKEN："
read -r BOT_TOKEN

green "请输入 CHAT_ID："
read -r CHAT_ID

# 推送间隔（秒）
while true; do
    green "请输入推送间隔（秒，最少 60，1 分钟 = 60 秒）："
    read -r interval
    if [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -ge 60 ]; then
        break
    fi
    red "❗ 请输入整数秒，且最小为 60"
done

green "请输入主机名（可留空使用系统默认主机名）："
read -r CUSTOM_HOSTNAME

if [ -z "$CUSTOM_HOSTNAME" ]; then
    CUSTOM_HOSTNAME=$(hostname)
fi

# 保存配置
cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
INTERVAL="$interval"
HOSTNAME="$CUSTOM_HOSTNAME"
EOF
chmod 600 "$CONFIG_FILE"
green "配置已保存到 $CONFIG_FILE"
echo

# 生成 Python 脚本（包含公网 IP 与国家检测）
cat > "$SCRIPT_FILE" <<'PYEOF'
#!/usr/bin/env python3
import psutil, requests, datetime, socket, os

# 读取配置
cfg = {}
with open("/root/vps_config.conf") as f:
    exec(f.read(), cfg)

BOT_TOKEN = cfg.get("BOT_TOKEN", "")
CHAT_ID = cfg.get("CHAT_ID", "")
HOSTNAME = cfg.get("HOSTNAME", socket.gethostname())

def format_uptime():
    uptime_seconds = int(datetime.datetime.now().timestamp() - psutil.boot_time())
    hours = uptime_seconds // 3600
    minutes = (uptime_seconds % 3600) // 60
    return f"{hours} 小时 {minutes} 分钟"

def get_real_ipv6():
    """
    获取真实 IPv6（不会被 NAT64 映射）
    """
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
            if ":" in ip:  # IPv6 一定包含冒号
                return ip
        except:
            continue
    return ""

def get_geo_info():
    """
    获取 IPv4 / IPv6 + 中文地区
    """
    info = {"ipv4":"", "ipv6":"", "country":"", "region":"", "city":""}

    # IPv4
    try:
        r = requests.get("https://api.ipify.org?format=json", timeout=5)
        info["ipv4"] = r.json().get("ip", "")
    except:
        pass

    # 真实 IPv6
    info["ipv6"] = get_real_ipv6()

    # 中文地区（最稳定）
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
    """
    获取 CPU 型号、核心数、主频（适配所有 VPS）
    """
    model = "未知"
    freq = "未知"
    cores = psutil.cpu_count(logical=False) or 1

    # 1) 从 /proc/cpuinfo 读取（最常见）
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if "model name" in line:
                    model = line.split(":", 1)[1].strip()
                if "Hardware" in line:  # ARM VPS
                    model = line.split(":", 1)[1].strip()
                if "cpu MHz" in line:
                    mhz = float(line.split(":", 1)[1].strip())
                    freq = f"{mhz/1000:.2f} GHz" if mhz > 1000 else f"{mhz:.0f} MHz"
    except:
        pass

    # 2) 如果型号仍未知，尝试 lscpu
    if model == "未知":
        try:
            import subprocess
            out = subprocess.check_output("lscpu", shell=True).decode()
            for line in out.splitlines():
                if "Model name" in line:
                    model = line.split(":", 1)[1].strip()
                if "CPU max MHz" in line:
                    mhz = float(line.split(":", 1)[1].strip())
                    freq = f"{mhz/1000:.2f} GHz"
        except:
            pass

    # 3) 如果还是未知，尝试 dmidecode（部分商家隐藏型号）
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

def get_status():
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

    text = f"""
📡 VPS 状态报告

🖥 主机名：{HOSTNAME}

🌐 IPv4：{ipv4}
🌐 IPv6：{ipv6}

📍 地区：{country} {region} {city}

🧠 CPU 型号：{cpu_model}
🔢 核心数：{cpu_cores} 核
⏱ 主频：{cpu_freq}

🔥 CPU：{cpu}%
📦 内存：{mem.percent}%（{mem.used//1024**2}MB / {mem.total//1024**2}MB）
💾 硬盘：{disk.percent}%（{disk.used//1024**3}GB / {disk.total//1024**3}GB）

📡 流量使用：
⬆ 上传：{sent:.2f} GB
⬇ 下载：{recv:.2f} GB

⏳ 运行时间：{uptime}
⏰ 时间：{datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
"""
    return text

def send_tg(text):
    if not BOT_TOKEN or not CHAT_ID:
        return
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    data = {"chat_id": CHAT_ID, "text": text}
    try:
        requests.post(url, data=data, timeout=10)
    except:
        pass

if __name__ == "__main__":
    send_tg(get_status())
PYEOF

chmod +x "$SCRIPT_FILE"
green "脚本已生成：$SCRIPT_FILE"
echo

# 检测 systemd
if pidof systemd >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
    green "检测到 systemd，生成 systemd service + timer"
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
else
    # 使用 crontab（按分钟粒度）
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
green "输入 1 并回车即可立即发送测试推送（无需手动输入命令），直接回车退出。"
read -r CHOICE
if [ "$CHOICE" = "1" ]; then
    green "正在发送测试消息，请稍候..."
    # 运行脚本并捕获退出码
    /usr/bin/python3 "$SCRIPT_FILE"
    if [ $? -eq 0 ]; then
        green "测试消息已发送（请检查 Telegram）。"
    else
        red "测试消息发送可能失败，请手动运行： python3 /root/vps_report.py"
    fi
else
    echo "已退出安装器。"
fi

echo
green "你可以随时重新运行本安装器修改配置： bash /root/vps.sh"

