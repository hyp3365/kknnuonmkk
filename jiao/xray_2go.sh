#!/bin/bash

# ==============================================================================
# Xray 模块化管理脚本 (仅支持 VLESS-XHTTP 直连 + CDN)
# 供其他脚本使用时，请使用：source xray_module.sh
# ==============================================================================

# 定义颜色与输出函数
[ -z "${re}" ] && re="\033[0m"
[ -z "${red}" ] && red="\033[1;91m"
[ -z "${green}" ] && green="\e[1;32m"
[ -z "${yellow}" ] && yellow="\e[1;33m"
[ -z "${purple}" ] && purple="\e[1;35m"
[ -z "${skyblue}" ] && skyblue="\e[1;36m"

_xray_red() { echo -e "\e[1;91m$1\033[0m"; }
_xray_green() { echo -e "\e[1;32m$1\033[0m"; }
_xray_yellow() { echo -e "\e[1;33m$1\033[0m"; }
_xray_purple() { echo -e "\e[1;35m$1\033[0m"; }
_xray_reading() { read -p "$(_xray_red "$1")" "$2"; }

# 定义内部常量与环境变量
XRAY_SERVER_NAME="xray"
XRAY_WORK_DIR="/etc/xray"
XRAY_CONFIG_DIR="${XRAY_WORK_DIR}/config.json"

export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 36 | head -n 1 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5-\6-\7-\8/')}
export PORT=${PORT:-$(shuf -i 1000-60000 -n 1 2>/dev/null || echo 10000)}
export CFIP=${CFIP:-'cdns.doon.eu.org'} 
export CFPORT=${CFPORT:-'443'}   
CDN_DOMAIN="cloudflare.com"

# 1. 检查 Xray 状态
check_xray() {
    if [ -f "${XRAY_WORK_DIR}/${XRAY_SERVER_NAME}" ]; then
        if [ -f /etc/alpine-release ]; then
            rc-service xray status | grep -q "started" && echo "running" && return 0 || echo "not running" && return 1
        else 
            [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && echo "running" && return 0 || echo "not running" && return 1
        fi
    else
        echo "not installed"
        return 2
    fi
}

# 2. 获取公网IP
_get_realip() {
  ip=$(curl -s --max-time 2 ipv4.ip.sb)
  if [ -z "$ip" ]; then
      ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
      echo "[$ipv6]"
  else
      if echo "$(curl -s http://ipinfo.io/org 2>/dev/null)" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
          ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
          echo "[$ipv6]"
      else
          echo "$ip"
      fi
  fi
}

# 3. 安装 Xray
install_xray() {
    _xray_purple "正在安装 Xray 中，请稍等..."

    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64'; ARCH_ARG='64' ;;
        'x86' | 'i686' | 'i386') ARCH='386'; ARCH_ARG='32' ;;
        'aarch64' | 'arm64') ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
        'armv7l') ARCH='armv7'; ARCH_ARG='arm32-v7a' ;;
        's390x') ARCH='s390x' ;;
        *) _xray_red "不支持的架构: ${ARCH_RAW}"; return 1 ;;
    esac

    [ ! -d "${XRAY_WORK_DIR}" ] && mkdir -p "${XRAY_WORK_DIR}" && chmod 777 "${XRAY_WORK_DIR}"
    curl -sLo "${XRAY_WORK_DIR}/${XRAY_SERVER_NAME}.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip"
    unzip -qo "${XRAY_WORK_DIR}/${XRAY_SERVER_NAME}.zip" -d "${XRAY_WORK_DIR}/"
    chmod +x ${XRAY_WORK_DIR}/${XRAY_SERVER_NAME}
    rm -rf "${XRAY_WORK_DIR}/${XRAY_SERVER_NAME}.zip" "${XRAY_WORK_DIR}/geosite.dat" "${XRAY_WORK_DIR}/geoip.dat" "${XRAY_WORK_DIR}/README.md" "${XRAY_WORK_DIR}/LICENSE" 

    XHTTP_PORT=$(($PORT + 1))
    CDN_XHTTP_PORT=$(($PORT + 2))

    iptables -F > /dev/null 2>&1 && iptables -P INPUT ACCEPT > /dev/null 2>&1 && iptables -P FORWARD ACCEPT > /dev/null 2>&1 && iptables -P OUTPUT ACCEPT > /dev/null 2>&1
    command -v ip6tables &> /dev/null && ip6tables -F > /dev/null 2>&1 && ip6tables -P INPUT ACCEPT > /dev/null 2>&1 && ip6tables -P FORWARD ACCEPT > /dev/null 2>&1 && ip6tables -P OUTPUT ACCEPT > /dev/null 2>&1

    output=$(${XRAY_WORK_DIR}/xray x25519)
    private_key=$(echo "${output}" | grep 'PrivateKey:' | awk '{print $2}')
    public_key=$(echo "${output}" | grep 'Password (PublicKey):' | awk '{print $3}')

cat > "${XRAY_CONFIG_DIR}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "listen": "::",
      "port": $XHTTP_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "target": "www.nazhumi.com:443",
          "xver": 0,
          "serverNames": ["www.nazhumi.com"],
          "privateKey": "$private_key",
          "shortIds": [""]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "listen": "0.0.0.0",
      "port": $CDN_XHTTP_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "/xhttp"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

    # 配置守护进程
    if [ -x "$(command -v systemctl)" ]; then
        cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=${XRAY_WORK_DIR}/xray -c ${XRAY_CONFIG_DIR}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray
        systemctl restart xray
    elif [ -x "$(command -v rc-update)" ]; then
        cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run

description="Xray service"
command="/etc/xray/xray"
command_args="-c /etc/xray/config.json"
command_background=true
pidfile="/var/run/xray.pid"
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default
        rc-service xray restart
    fi

    # 导出 public_key 供外部脚本读取（如果需要）
    export XRAY_PUBLIC_KEY="${public_key}"
    export XRAY_XHTTP_PORT="${XHTTP_PORT}"
    export XRAY_CDN_PORT="${CDN_XHTTP_PORT}"
    
    _xray_green "Xray 安装并启动成功！"
}

# 4. 卸载 Xray
uninstall_xray() {
   _xray_yellow "正在卸载 Xray..."
   if [ -f /etc/alpine-release ]; then
        rc-service xray stop 2>/dev/null
        rm -f /etc/init.d/xray
        rc-update del xray default 2>/dev/null
   else
        systemctl stop xray 2>/dev/null
        systemctl disable xray 2>/dev/null
        systemctl daemon-reload 2>/dev/null
   fi
  
   rm -rf "${XRAY_WORK_DIR}" || true
   rm -rf /etc/systemd/system/xray.service 2>/dev/null	

   _xray_green "Xray 卸载成功"
}

# 5. 启动 Xray
start_xray() {
    if [ -f /etc/alpine-release ]; then
        rc-service xray start
    else
        systemctl daemon-reload
        systemctl start xray
    fi
    [ $? -eq 0 ] && _xray_green "Xray 服务已启动" || _xray_red "Xray 服务启动失败"
}

# 6. 停止 Xray
stop_xray() {
    if [ -f /etc/alpine-release ]; then
        rc-service xray stop
    else
        systemctl stop xray
    fi
    [ $? -eq 0 ] && _xray_green "Xray 服务已停止" || _xray_red "Xray 服务停止失败"
}

# 7. 重启 Xray
restart_xray() {
    if [ -f /etc/alpine-release ]; then
        rc-service xray restart
    else
        systemctl daemon-reload
        systemctl restart xray
    fi
    [ $? -eq 0 ] && _xray_green "Xray 服务已重启" || _xray_red "Xray 服务重启失败"
}

# 8. 获取节点连接信息
get_info() {
  IP=$(_get_realip)
  
  # 如果公钥未在内存中，尝试从当前配置或重新生成（兜底处理）
  if [ -z "${public_key}" ]; then
      output=$(${XRAY_WORK_DIR}/xray x25519 2>/dev/null)
      public_key=$(echo "${output}" | grep 'Password (PublicKey):' | awk '{print $3}')
  fi

  isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null | tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || echo "vps")

  cat > ${XRAY_WORK_DIR}/url.txt <<EOF
vless://${UUID}@${IP}:${XHTTP_PORT:-3001}?encryption=none&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=${public_key}&allowInsecure=1&type=xhttp&mode=auto#${isp}-直连

vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${CDN_DOMAIN}&fp=chrome&type=xhttp&host=${CDN_DOMAIN}&path=%2Fxhttp#${isp}-CDN
EOF

  echo ""
  while IFS= read -r line; do echo -e "${purple}$line"; done < ${XRAY_WORK_DIR}/url.txt
  echo ""
}
