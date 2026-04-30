#!/bin/bash

# 定义颜色
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

# 定义常量
server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
# 定义环境变量
export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export PORT=${PORT:-$(shuf -i 1000-60000 -n 1)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'} 
export CFPORT=${CFPORT:-'443'}   

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本" && exit 1

# 检查 xray 是否已安装
check_xray() {
if [ -f "${work_dir}/${server_name}" ]; then
    if [ -f /etc/alpine-release ]; then
        rc-service xray status | grep -q "started" && green "running" && return 0 || yellow "not running" && return 1
    else 
        [ "$(systemctl is-active xray)" = "active" ] && green "running" && return 0 || yellow "not running" && return 1
    fi
else
    red "not installed"
    return 2
fi
}

#根据系统类型安装、卸载依赖
manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action" 
        return 1
    fi

    action=$1
    shift

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command -v "$package" &>/dev/null; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command -v apt &>/dev/null; then
                DEBIAN_FRONTEND=noninteractive apt-get update -y && apt install -y "$package"
            elif command -v dnf &>/dev/null; then
                dnf update -y && dnf install -y "$package"
            elif command -v yum &>/dev/null; then
                yum update -y &7 yum install -y "$package"
            elif command -v apk &>/dev/null; then
                apk update && apk add "$package"
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command -v "$package" &>/dev/null; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command -v apt &>/dev/null; then
                apt remove -y "$package" && apt autoremove -y
            elif command -v dnf &>/dev/null; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command -v yum &>/dev/null; then
                yum remove -y "$package" && yum autoremove -y
            elif command -v apk &>/dev/null; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

# 获取ip
get_realip() {
  ip=$(curl -s --max-time 2 ipv4.ip.sb)
  if [ -z "$ip" ]; then
      ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
      echo "[$ipv6]"
  else
      if echo "$(curl -s http://ipinfo.io/org)" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
          ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
          echo "[$ipv6]"
      else
          echo "$ip"
      fi
  fi
}

# 下载并安装 xray,cloudflared
install_xray() {
    clear
    purple "正在安装Xray中，请稍等..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64'; ARCH_ARG='64' ;;
        'x86' | 'i686' | 'i386') ARCH='386'; ARCH_ARG='32' ;;
        'aarch64' | 'arm64') ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
        'armv7l') ARCH='armv7'; ARCH_ARG='arm32-v7a' ;;
        's390x') ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    # 下载xray
    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}"
    curl -sLo "${work_dir}/${server_name}.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip"
    unzip "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1 && chmod +x ${work_dir}/${server_name}
    rm -rf "${work_dir}/${server_name}.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE" 

   # 生成随机UUID和密码
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
    GRPC_PORT=$(($PORT + 1))
    XHTTP_PORT=$(($PORT + 2))
    output=$(/etc/xray/xray x25519)
    private_key=$(echo "${output}" | grep 'PrivateKey:' | awk '{print $2}')
    public_key=$(echo "${output}" | grep 'Password (PublicKey):' | awk '{print $3}')

   # 生成配置文件
cat > "${config_dir}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": $ARGO_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none",
        "fallbacks": [
          { "dest": 3001 }, { "path": "/vless-argo", "dest": 3002 },
          { "path": "/vmess-argo", "dest": 3003 }
        ]
      },
      "streamSettings": { "network": "tcp" }
    },
    {
      "port": 3001, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "none" }
    },
    {
      "port": 3002, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID", "level": 0 }], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "port": 3003, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-argo" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "listen":"::","port": $XHTTP_PORT, "protocol": "vless","settings": {"clients": [{"id": "$UUID"}],"decryption": "none"},
      "streamSettings": {"network": "xhttp","security": "reality","realitySettings": {"target": "www.nazhumi.com:443","xver": 0,"serverNames": 
      ["www.nazhumi.com"],"privateKey": "$private_key","shortIds": [""]}},"sniffing": {"enabled": true,"destOverride": ["http","tls","quic"]}
    },
    {
      "listen":"::","port":$GRPC_PORT,"protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
      "streamSettings":{"network":"grpc","security":"reality","realitySettings":{"dest":"www.iij.ad.jp:443","serverNames":["www.iij.ad.jp"],
      "privateKey":"$private_key","shortIds":[""]},"grpcSettings":{"serviceName":"grpc"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
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
}
# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=$work_dir/xray -c $config_dir
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    systemctl daemon-reload
    systemctl enable xray
    systemctl is-active --quiet xray || systemctl start xray
}
# 适配alpine 守护进程
alpine_openrc_services() {
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
}

get_info() {  
  clear
  IP=$(get_realip)

  isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || echo "vps")

  cat > ${work_dir}/url.txt <<EOF
vless://${UUID}@${IP}:${GRPC_PORT}?encryption=none&security=reality&sni=www.google.com&fp=chrome&pbk=${public_key}&allowInsecure=1&type=grpc&serviceName=grpc#${isp}-Reality-gRPC

vless://${UUID}@${IP}:${XHTTP_PORT}?encryption=none&security=reality&sni=www.google.com&fp=chrome&pbk=${public_key}&allowInsecure=1&type=xhttp#${isp}-Reality-xHTTP
EOF

  green "--- Xray 节点信息 ---"
  echo ""
  while IFS= read -r line; do 
      purple "$line"
  done < "${work_dir}/url.txt"
  echo ""

  yellow "温馨提醒：如果是 NAT 机，请确保 Reality 端口（$GRPC_PORT/$XHTTP_PORT）在可用端口范围内。"
  echo ""
}

# 启动 xray
start_xray() {
if [ ${check_xray} -eq 1 ]; then
    yellow "\n正在启动 ${server_name} 服务\n" 
    if [ -f /etc/alpine-release ]; then
        rc-service xray start
    else
        systemctl daemon-reload
        systemctl start "${server_name}"
    fi
   if [ $? -eq 0 ]; then
       green "${server_name} 服务已成功启动\n"
   else
       red "${server_name} 服务启动失败\n"
   fi
elif [ ${check_xray} -eq 0 ]; then
    yellow "xray 正在运行\n"
    sleep 1
    menu
else
    yellow "xray 尚未安装!\n"
    sleep 1
    menu
fi
}

# 停止 xray
stop_xray() {
if [ ${check_xray} -eq 0 ]; then
   yellow "\n正在停止 ${server_name} 服务\n"
    if [ -f /etc/alpine-release ]; then
        rc-service xray stop
    else
        systemctl stop "${server_name}"
    fi
   if [ $? -eq 0 ]; then
       green "${server_name} 服务已成功停止\n"
   else
       red "${server_name} 服务停止失败\n"
   fi

elif [ ${check_xray} -eq 1 ]; then
    yellow "xray 未运行\n"
    sleep 1
    menu
else
    yellow "xray 尚未安装！\n"
    sleep 1
    menu
fi
}

# 重启 xray
restart_xray() {
if [ ${check_xray} -eq 0 ]; then
   yellow "\n正在重启 ${server_name} 服务\n"
    if [ -f /etc/alpine-release ]; then
        rc-service ${server_name} restart
    else
        systemctl daemon-reload
        systemctl restart "${server_name}"
    fi
    if [ $? -eq 0 ]; then
        green "${server_name} 服务已成功重启\n"
    else
        red "${server_name} 服务重启失败\n"
    fi
elif [ ${check_xray} -eq 1 ]; then
    yellow "xray 未运行\n"
    sleep 1
    menu
else
    yellow "xray 尚未安装！\n"
    sleep 1
    menu
fi
}

# 卸载 xray
uninstall_xray() {
   reading "确定要卸载 xray 吗? (y/n): " choice
   case "${choice}" in
       y|Y)
           yellow "正在卸载 xray"
           if [ -f /etc/alpine-release ]; then
                rc-service xray stop
                rc-update del xray default
           else
                systemctl stop "${server_name}"
                systemctl disable "${server_name}"
                systemctl daemon-reload || true
            fi
           rm -rf "${work_dir}" || true
	       rm -rf /etc/systemd/system/xray.service /etc/systemd/system/tunnel.service 2>/dev/null	
            green "\nXray卸载成功\n"
           ;;
       *)
           purple "已取消卸载操作\n"
           ;;
   esac
}

# 适配alpine运行argo报错用户组和dns的问题
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# 查看节点信息和订阅链接
check_nodes() {
if [ ${check_xray} -eq 0 ]; then
    while IFS= read -r line; do purple "${purple}$line"; done < ${work_dir}/url.txt
else 
    yellow "Xray-2go 尚未安装或未运行,请先安装或启动Xray-2go"
    sleep 1
    menu
fi
}

# xray 管理
manage_xray() {
    green "1. 启动xray服务"
    skyblue "-------------------"
    green "2. 停止xray服务"
    skyblue "-------------------"
    green "3. 重启xray服务"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_xray ;;  
        2) stop_xray ;;
        3) restart_xray ;;
        0) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# 捕获 Ctrl+C 信号
trap 'red "已取消操作"; exit' INT

# 主菜单
menu() {
while true; do
   check_xray &>/dev/null; check_xray=$?
   check_xray_status=$(check_xray) > /dev/null 2>&1
   clear
   echo ""
   purple "=== 老王Xray一键安装脚本 ===\n"
   purple " Xray 状态: ${check_xray_status}\n"
   green "1. 安装Xray"
   red "2. 卸载Xray"
   echo "==============="
   green "3. Xray管理"
   green "4. 查看节点"
   echo  "==============="
   red "0. 退出脚本"
   echo "==========="
   reading "请输入选择(0-4): " choice
   echo ""
   case "${choice}" in
        1)  
            if [ ${check_xray} -eq 0 ]; then
                yellow "Xray已经安装！"
            else
                manage_packages install jq unzip iptables openssl coreutils lsof
                install_xray

                if [ -x "$(command -v systemctl)" ]; then
                    main_systemd_services
                elif [ -x "$(command -v rc-update)" ]; then
                    alpine_openrc_services
                    change_hosts
                    rc-service xray restart
                else
                    echo "Unsupported init system"
                    exit 1 
                fi

                sleep 3
				get_info
            fi
           ;;
        2) uninstall_xray ;;
        3) manage_xray ;;
		4) check_nodes ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 4" ;; 
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
done
}
menu
