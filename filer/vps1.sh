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

# 默认开关：IP 推送与 CPU 推送均开启
PUSH_IP=1
PUSH_CPU=1

# 保存配置
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

# 生成 Python 脚本（包含公网 IP 与国家检测，且根据 PUSH_IP/PUSH_CPU 控制输出）
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
PUSH_IP = str(cfg.get("PUSH_IP", "1"))
PUSH_CPU = str(cfg.get("PUSH_CPU", "1"))

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
                    try:
                        mhz = float(line.split(":", 1)[1].strip())
                        freq = f"{mhz/1000:.2f} GHz" if mhz > 1000 else f"{mhz:.0f} MHz"
                    except:
                        pass
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
                    try:
                        mhz = float(line.split(":", 1)[1].strip())
                        freq = f"{mhz/1000:.2f} GHz"
                    except:
                        pass
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

    # IP 部分根据 PUSH_IP 控制
    if PUSH_IP == "1":
        parts.append(f"🌐 IPv4：{ipv4}\n")
        parts.append(f"🌐 IPv6：{ipv6}\n")
        parts.append(f"\n📍 地区：{country} {region} {city}\n")
    else:
        parts.append("\n📍 地区：{country} {region} {city}\n".format(country=country, region=region, city=city))

    # CPU 部分根据 PUSH_CPU 控制
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

if __name__ == "__main__":
    send_tg(get_status_text())
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
    /usr/bin/python3 "$SCRIPT_FILE"
    if [ $? -eq 0 ]; then
        green "测试消息已发送（请检查 Telegram）。"
    else
        red "测试消息发送可能失败，请手动运行： python3 /root/vps_report.py"
    fi
else
    echo "已退出安装器。"
fi

# 创建交互命令 t（菜单：1 开关 IP 推送；2 开关 CPU 推送；3 修改推送时间；4 一键卸载）
cat > /usr/local/bin/t <<'BASH'
#!/usr/bin/env bash
CONFIG="/root/vps_config.conf"
SCRIPT="/root/vps_report.py"
SERVICE_FILE="/etc/systemd/system/vps_report.service"
TIMER_FILE="/etc/systemd/system/vps_report.timer"
CRON_MARK="# vps_report_cron_job"
PROFILE_FILE="/etc/profile.d/vpsctl.sh"

# ensure running as root for operations that need it
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
  echo
  echo "当前状态："
  if _has_systemd; then
    systemctl is-active --quiet vps_report.timer && echo "  定时器：已启用（systemd timer）" || echo "  定时器：未启用"
  else
    crontab -l 2>/dev/null | grep -q "${CRON_MARK}" && echo "  定时器：已启用（crontab）" || echo "  定时器：未启用"
  fi
  echo
  echo "即时信息："
  python3 - <<'PY'
import requests,psutil,datetime
def ipv4():
    try: return requests.get("https://api.ipify.org?format=json",timeout=5).json().get("ip","")
    except: return ""
def ipv6():
    for u in ["https://v6.ident.me","https://api6.ipify.org","https://ipv6.icanhazip.com","https://ifconfig.co/ip"]:
        try:
            r=requests.get(u,timeout=5).text.strip()
            if ":" in r: return r
        except: pass
    return ""
def geo():
    try:
        r=requests.get("http://ip-api.com/json/?lang=zh-CN",timeout=6).json()
        return r.get("country",""), r.get("regionName",""), r.get("city","")
    except: return "","",""
def cpu():
    model="未知"; freq="未知"
    try:
        with open("/proc/cpuinfo") as f:
            t=f.read()
        import re
        m=re.search(r"model name\s+:\s+(.+)",t)
        if m: model=m.group(1).strip()
        m=re.search(r"cpu MHz\s+:\s+([\d\.]+)",t)
        if m:
            mhz=float(m.group(1)); freq=f"{mhz/1000:.2f} GHz" if mhz>1000 else f"{mhz:.0f} MHz"
    except:
        pass
    return model,freq
ipv4=ipv4(); ipv6=ipv6(); country,region,city=geo(); cpu_model,cpu_freq=cpu()
print("  IPv4:", ipv4)
print("  IPv6:", ipv6)
print("  地区:", country, region, city)
print("  CPU 型号:", cpu_model)
print("  CPU 频率:", cpu_freq)
print("  时间:", datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
PY
}

_uninstall(){
  echo "即将卸载：将删除脚本、配置、systemd 定时器/cron 条目、别名，并尝试卸载安装器安装的软件包。"
  read -rp "确认要卸载并删除所有内容吗？输入 yes 确认： " ans
  if [ "$ans" != "yes" ]; then
    echo "已取消卸载。"
    return 0
  fi

  # stop timer/cron
  if _has_systemd; then
    systemctl disable --now vps_report.timer 2>/dev/null || true
    systemctl stop vps_report.timer 2>/dev/null || true
    systemctl disable --now vps_report.service 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload
    echo "systemd 定时器/服务已移除（如存在）"
  else
    crontab -l 2>/dev/null | sed "/${CRON_MARK}/d" | crontab - 2>/dev/null || true
    echo "crontab 条目已移除（如存在）"
  fi

  # remove files
  rm -f "$SCRIPT" "$CONFIG" /usr/local/bin/t "$PROFILE_FILE"
  echo "脚本与配置已删除：$SCRIPT, $CONFIG, /usr/local/bin/t, $PROFILE_FILE"

  # try to remove packages installed by installer (best-effort)
  PKG=$(detect_pkgmgr)
  if [ -n "$PKG" ]; then
    echo "检测到包管理器： $PKG，尝试卸载安装器可能安装的软件（若存在）..."
    if [ "$PKG" = "apk" ]; then
      apk del --no-network py3-psutil py3-requests python3 py3-pip curl 2>/dev/null || true
    else
      apt remove -y python3-psutil python3-requests python3 python3-pip curl 2>/dev/null || true
      apt autoremove -y 2>/dev/null || true
    fi
    echo "卸载尝试完成（若包存在则已移除）"
  else
    echo "未检测到受支持的包管理器，跳过包卸载"
  fi

  echo "卸载完成。若需要彻底清理，请手动检查 /etc/systemd/system/ 与 crontab。"
}

menu(){
  while true; do
    echo
    echo "====== VPS推送管理 (快捷命令t) ======"
    echo "1) 开启/关闭 IP地址 推送"
    echo "2) 开启/关闭 CPU型号/核心 推送"
    echo "3) 修改推送时间（秒）"
    echo "4) 卸载"
    echo "q) 退出"
    echo "================================"
    read -rp "请选择 (1/2/3/4/q): " choice
    case "$choice" in
      1) toggle_push_ip ;;
      2) toggle_push_cpu ;;
      3) set_interval ;;
      4) _uninstall; break ;;
      q|Q) break ;;
      *) echo "无效选项" ;;
    esac
  done
}

# ensure config has flags
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

# create alias file for login shells
cat > /etc/profile.d/vpsctl.sh <<'SH'
# alias for vpsctl
if [ -x /usr/local/bin/t ]; then
  alias t='/usr/local/bin/t'
fi
SH
chmod +x /etc/profile.d/vpsctl.sh

echo "已安装交互命令 t。使别名立即生效： source /etc/profile.d/vpsctl.sh 或 重新登录。"
echo "运行 t 进入菜单。"
