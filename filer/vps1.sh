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
  echo "即将卸载：将删除脚本、配置、systemd 定时器/cron 条目、别名，并尝试卸载安装器安装的软件包。"
  read -rp "确认要卸载并删除所有内容吗？输入 yes 确认： " ans
  if [ "$ans" != "yes" ]; then
    echo "已取消卸载。"
    return 0
  fi

  if _has_systemd; then
    systemctl disable --now vps_report.timer 2>/dev/null || true
    systemctl stop vps_report.timer 2>/dev/null || true
    systemctl disable --now vps_report.service 2>/dev/null || true
    systemctl disable --now vps_bot.service 2>/dev/null || true
    systemctl stop vps_bot.service 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$BOT_SERVICE_FILE"
    systemctl daemon-reload
    echo "systemd 定时器/服务已移除（如存在）"
  else
    crontab -l 2>/dev/null | sed "/${CRON_MARK}/d" | crontab - 2>/dev/null || true
    echo "crontab 条目已移除（如存在）"
  fi

  rm -f "$SCRIPT" "$CONFIG" "$BOT" /usr/local/bin/t "$PROFILE_FILE"
  echo "脚本与配置已删除：$SCRIPT, $CONFIG, $BOT, /usr/local/bin/t, $PROFILE_FILE"

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
