#!/bin/bash

# ========================
# 老王sing-box四合一安装脚本
# vless-version-reality|vmess-ws-tls(tunnel)|hysteria2|tuic5
# 最后更新时间: 2026.3.05
# =========================

export LANG=en_US.UTF-8
# --- 颜色和基础工具函数 ---
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

generate_vars() {
  local cc=$(curl -sm 3 "https://api.ip.sb/geoip" | awk -F\" '{for(x=1;x<=NF;x++) if($x=="country_code") print $(x+2)}' | head -n 1)
  [ -z "$cc" ] && cc=$(curl -sm 3 "https://ipapi.co/json" | awk -F\" '{for(x=1;x<=NF;x++) if($x=="country_code") print $(x+2)}' | head -n 1)
  if echo "$cc" | grep -q '^[A-Z][A-Z]$'; then
      isp=$(printf $(echo "$cc" | awk '{
          chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
          i1 = index(chars, substr($0, 1, 1))
          i2 = index(chars, substr($0, 2, 1))
          printf("\\xF0\\x9F\\x87\\x%X\\xF0\\x9F\\x87\\x%X", 165+i1, 165+i2)
      }'))
  else
      isp="🌐" 
  fi     
}


# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
export CFIP=${CFIP:-'cf.877774.xyz'} 
export CFPORT=${CFPORT:-'443'} 
uuid=$(cat /proc/sys/kernel/random/uuid)

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本" && exit 1

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_service() {
    local service_name=$1
    local service_file=$2

    [[ -n "${service_file}" && ! -f "${service_file}" ]] && { red "not installed"; return 2; }

    if command_exists rc-service; then
        rc-service "${service_name}" status 2>&1 | grep -qE "started|running" && { green "running"; return 0; } || { yellow "not running"; return 1; }
    elif command_exists systemctl; then
        systemctl is-active --quiet "${service_name}" && { green "running"; return 0; } || { yellow "not running"; return 1; }
    else
        yellow "service manager not found"
        return 2
    fi
}

# 检查sing-box状态
check_singbox() {
    check_service "sing-box" "${work_dir}/${server_name}"
}

# 检查argo状态
check_argo() {
    check_service "argo" "${work_dir}/argo"
}


#根据系统类型安装、卸载依赖
manage_packages() {
    # 参数检查
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    # 先检测包管理器（优先检测存在的命令）
    detect_pkg_manager() {
        if command -v apt >/dev/null 2>&1; then
            PKG_MGR="apt"
        elif command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
        elif command -v yum >/dev/null 2>&1; then
            PKG_MGR="yum"
        elif command -v apk >/dev/null 2>&1; then
            PKG_MGR="apk"
        else
            PKG_MGR=""
        fi
    }

    # 检测 libc 类型（musl 或 glibc），结果写入全局 LIBC
    detect_libc() {
        if command -v ldd >/dev/null 2>&1; then
            if ldd --version 2>&1 | grep -qi musl; then
                LIBC="musl"
            else
                LIBC="glibc"
            fi
        else
            # 没有 ldd 时尝试 /lib/ld-musl 或 /lib64/ld-linux 判断
            if [ -f /lib/ld-musl-x86_64.so.1 ] || [ -f /lib/ld-musl.so.1 ]; then
                LIBC="musl"
            else
                LIBC="glibc"
            fi
        fi
    }

    detect_pkg_manager
    detect_libc

    action=$1
    shift

    for package in "$@"; do
        if [ "$action" = "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            case "$PKG_MGR" in
                apt)
                    DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1
                    DEBIAN_FRONTEND=noninteractive apt install -y "$package"
                    ;;
                dnf)
                    dnf install -y "$package"
                    ;;
                yum)
                    yum install -y "$package"
                    ;;
                apk)
                    # 区分 OpenWrt 与 Alpine（OpenWrt 的 apk 可能缺少某些包）
                    if [ -f /etc/openwrt_release ]; then
                        # OpenWrt: 尝试安装，若失败提示用户
                        apk update >/dev/null 2>&1 || true
                        if ! apk add "$package"; then
                            yellow "OpenWrt: package ${package} may not be available in default repos"
                        fi
                    else
                        # Alpine
                        apk update
                        apk add "$package"
                    fi
                    ;;
                *)
                    red "Unknown system or package manager!"
                    return 1
                    ;;
            esac

        elif [ "$action" = "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            case "$PKG_MGR" in
                apt)
                    apt remove -y "$package" && apt autoremove -y
                    ;;
                dnf)
                    dnf remove -y "$package" && dnf autoremove -y
                    ;;
                yum)
                    yum remove -y "$package" && yum autoremove -y
                    ;;
                apk)
                    apk del "$package"
                    ;;
                *)
                    red "Unknown system or package manager!"
                    return 1
                    ;;
            esac

        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

# 获取ip
get_realip() {
    ip=$(curl -4 -sm 2 ip.sb)
    ipv6() { curl -6 -sm 2 ip.sb; }
    if [ -z "$ip" ]; then
        echo "[$(ipv6)]"
    elif curl -4 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        echo "[$(ipv6)]"
    else
        resp=$(curl -sm 8 "https://status.eooce.com/api/$ip" | jq -r '.status')
        if [ "$resp" = "Available" ]; then
            echo "$ip"
        else
            v6=$(ipv6)
            [ -n "$v6" ] && echo "[$v6]" || echo "$ip"
        fi
    fi
}

# 下载并安装 sing-box,cloudflared
install_singbox() {
    clear
    purple "正在安装sing-box中，请稍后..."
    # 判断系统架构
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l') ARCH='armv7' ;;
        's390x') ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    # 下载sing-box,cloudflared
    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}"
    latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[] | select(.prerelease==false)][0].tag_name | sub("^v"; "")')
    work_dir=${work_dir:-/etc/sing-box}
mkdir -p "$work_dir"
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; armv7l) ARCH=armv7;; i386|i686) ARCH=386;; *) ARCH="$ARCH_RAW";; esac
if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then LIBC=musl; else LIBC=glibc; fi
latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[]|select(.prerelease==false)][0].tag_name|sub("^v";"")')
[ -z "$latest_version" ] && latest_version=1.8.10
TAR="sing-box-${latest_version}-linux-${ARCH}-${LIBC}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/${TAR}"
curl -fSL -o "${work_dir}/${TAR}" "$URL" && tar -xzf "${work_dir}/${TAR}" -C "$work_dir" && mv "${work_dir}/sing-box-${latest_version}-linux-${ARCH}-${LIBC}/sing-box" "${work_dir}/sing-box" && chmod +x "${work_dir}/sing-box" && rm -rf "${work_dir}/${TAR}" "${work_dir}/sing-box-${latest_version}-linux-${ARCH}-${LIBC}"
       
    CF_ARCH=$(uname -m); case "$CF_ARCH" in x86_64) CF_ARCH=amd64;; aarch64|arm64) CF_ARCH=arm64;; armv7l) CF_ARCH=armv7;; i386|i686) CF_ARCH=386;; esac
    curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  
    chown root:root ${work_dir} && chmod +x ${work_dir}/${server_name} ${work_dir}/argo
    
    # 检测网络类型并设置DNS策略
    dns_strategy=$(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || (ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))

   # 生成配置文件
cat > "${config_dir}" << EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  },
    "dns":{
        "servers":[
            {
                "type":"local"
            }
        ],
        "strategy": "prefer_ipv4"
  },
   "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
   },
  "inbounds": [
    {
         "type": "vmess",
         "tag": "vmess-ws",
         "listen": "::",
         "listen_port": 8001, 
         "users": [
           {
            "uuid": "$uuid"
           }
          ],
        "transport": {
          "type": "ws",
          "path": "/mPaxe1996Ko-5203aap",
          "early_data_header_name": "Sec-WebSocket-Protocol"
         }
     }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": [
        "172.16.0.2/32",
        "2606:4700:110:8dfe:d141:69bb:6b80:925/128"
      ],
      "private_key": "YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
      "peers": [
        {
          "address": "engage.cloudflareclient.com",
           #洛杉矶ip 2606:4700:d0::a29f:c001 
		   #洛杉矶ip 162.159.195.1
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": [
            "0.0.0.0/0",
            "::/0"
          ],
          "reserved": [
            78,
            135,
            76
          ]
        }
      ]
    }
  ],
  "outbounds": [
	{
    "type": "socks",
    "tag": "socks-40000",
    "server": "127.0.0.1",
    "server_port": 40000
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rule_set": [
      {
        "tag": "openai",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs",
        "download_detour": "direct"
      },
      {
        "tag": "netflix",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs",
        "download_detour": "direct"
      }
    ],
    "rules": [
      {
        "rule_set": ["openai", "netflix"],
        "outbound": "wireguard-out"
      }
    ],
    "final": "direct"
  }
}
EOF
}
# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --url http://localhost:8001 --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1"
Restart=on-failure
RestartSec=5s

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
    systemctl daemon-reload 
    systemctl enable sing-box
    systemctl start sing-box
    systemctl enable argo
    systemctl start argo
}

# 创建快捷指令（自动下载脚本到本地保存）
create_shortcut() {
    local remote_url="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/sing-box08.sh"
    local local_file="$work_dir/sb.sh"
    if [ ! -s "$local_file" ]; then
        mkdir -p "$work_dir"
        curl -Lss "$remote_url" -o "$local_file"
    fi
    if [ -s "$local_file" ]; then
        chmod +x "$local_file"
        ln -sf "$local_file" /usr/bin/sb
		ln -sf "$local_file" /usr/bin/b
        if [ -x /usr/bin/sb ]; then
            green "\n快捷指令 sb 已创建\n"
        fi
		if [ -x /usr/bin/b ]; then
            green "\n快捷指令 b 已创建\n"
        fi
    else
        red "\n本地化保存失败，请检查网络后重新运行\n"
        rm -f "$local_file" 
    fi
}

# 适配alpine 守护进程
alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run

description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    cat > /etc/init.d/argo << 'EOF'
#!/sbin/openrc-run

description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/sing-box/argo tunnel --url http://localhost:8001 --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1'"
command_background=true
pidfile="/var/run/argo.pid"
EOF

    chmod +x /etc/init.d/sing-box
    chmod +x /etc/init.d/argo

    rc-update add sing-box default > /dev/null 2>&1
    rc-update add argo default > /dev/null 2>&1

}

# 生成节点和订阅链接
get_info() {  
  yellow "\nip检测中,请稍等...\n"
  server_ip=$(get_realip)
  local cc=$(curl -sm 3 "https://api.ip.sb/geoip" | awk -F\" '{for(x=1;x<=NF;x++) if($x=="country_code") print $(x+2)}' | head -n 1)
  [ -z "$cc" ] && cc=$(curl -sm 3 "https://ipapi.co/json" | awk -F\" '{for(x=1;x<=NF;x++) if($x=="country_code") print $(x+2)}' | head -n 1)
  if echo "$cc" | grep -q '^[A-Z][A-Z]$'; then
      isp=$(printf $(echo "$cc" | awk '{
          chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
          i1 = index(chars, substr($0, 1, 1))
          i2 = index(chars, substr($0, 2, 1))
          printf("\\xF0\\x9F\\x87\\x%X\\xF0\\x9F\\x87\\x%X", 165+i1, 165+i2)
      }'))
  else
      isp="🌐" 
  fi
  clear
  if [ -f "${work_dir}/argo.log" ]; then
      for i in {1..5}; do
          purple "第 $i 次尝试获取ArgoDoamin中..."
          argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
          [ -n "$argodomain" ] && break
          sleep 2
      done
  else
      restart_argo
      sleep 6
      argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
  fi

  green "\nArgoDomain：${purple}$argodomain${re}\n"

  VMESS="{ \"v\": \"2\", \"ps\": \"${isp}_vmess_ws_argo\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/mPaxe1996Ko-5203aap?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowlnsecure\": \"flase\"}"
    
  cat > ${work_dir}/url.txt <<EOF
vmess://$(echo "$VMESS"| base64 -w0)

EOF
echo ""
while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt
base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt
chmod 644 ${work_dir}/sub.txt
yellow "\n温馨提醒：需打开V2rayN或其他软件里的 "跳过证书验证"，或将节点的Insecure或TLS里设置为"true"\n"
green "V2rayN,Shadowrocket,Nekobox,Loon,Karing,Sterisand订阅链接：http://${server_ip}:${nginx_port}/${password}\n"
}

# 通用服务管理函数
manage_service() {
    local service_name="$1"
    local action="$2"

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"
        return 1
    fi
    
    local status=$(check_service "$service_name" 2>/dev/null)

    case "$action" in
        "start")
            if [ "$status" == "running" ]; then 
                yellow "${service_name} 正在运行\n"
                return 0
            elif [ "$status" == "not installed" ]; then 
                yellow "${service_name} 尚未安装!\n"
                return 1
            else 
                yellow "正在启动 ${service_name} 服务\n"
                if command_exists rc-service; then
                    rc-service "$service_name" start
                elif command_exists systemctl; then
                    systemctl daemon-reload
                    systemctl start "$service_name"
                fi
                
                if [ $? -eq 0 ]; then
                    green "${service_name} 服务已成功启动\n"
                    return 0
                else
                    red "${service_name} 服务启动失败\n"
                    return 1
                fi
            fi
            ;;
            
        "stop")
            if [ "$status" == "not installed" ]; then 
                yellow "${service_name} 尚未安装！\n"
                return 2
            elif [ "$status" == "not running" ]; then
                yellow "${service_name} 未运行\n"
                return 1
            else
                yellow "正在停止 ${service_name} 服务\n"
                if command_exists rc-service; then
                    rc-service "$service_name" stop
                elif command_exists systemctl; then
                    systemctl stop "$service_name"
                fi
                
                if [ $? -eq 0 ]; then
                    green "${service_name} 服务已成功停止\n"
                    return 0
                else
                    red "${service_name} 服务停止失败\n"
                    return 1
                fi
            fi
            ;;
            
        "restart")
            if [ "$status" == "not installed" ]; then
                yellow "${service_name} 尚未安装！\n"
                return 1
            else
                yellow "正在重启 ${service_name} 服务\n"
                if command_exists rc-service; then
                    rc-service "$service_name" restart
                elif command_exists systemctl; then
                    systemctl daemon-reload
                    systemctl restart "$service_name"
                fi
                
                if [ $? -eq 0 ]; then
                    green "${service_name} 服务已成功重启\n"
                    return 0
                else
                    red "${service_name} 服务重启失败\n"
                    return 1
                fi
            fi
            ;;
            
        *)
            red "无效的操作: $action\n"
            red "可用操作: start, stop, restart\n"
            return 1
            ;;
    esac
}

# 启动 sing-box
start_singbox() {
    manage_service "sing-box" "start"
}

# 停止 sing-box
stop_singbox() {
    manage_service "sing-box" "stop"
}

# 重启 sing-box
restart_singbox() {
    manage_service "sing-box" "restart"
}

# 启动 argo
start_argo() {
    manage_service "argo" "start"
}

# 停止 argo
stop_argo() {
    manage_service "argo" "stop"
}

# 重启 argo
restart_argo() {
    manage_service "argo" "restart"
}

# 卸载 sing-box
uninstall_singbox() {
   reading "确定要卸载 sing-box 吗? (y/n): " choice
   case "${choice}" in
       y|Y)
           yellow "正在卸载 sing-box"
           if command_exists rc-service; then
                rc-service sing-box stop
                rc-service argo stop
                rm /etc/init.d/sing-box /etc/init.d/argo
                rc-update del sing-box default
                rc-update del argo default
           else
                # 停止 sing-box和 argo 服务
                systemctl stop "${server_name}"
                systemctl stop argo
                # 禁用 sing-box 服务
                systemctl disable "${server_name}"
                systemctl disable argo

                # 重新加载 systemd
                systemctl daemon-reload || true
            fi
           rm -rf "${work_dir}" || true
           rm -rf "${log_dir}" || true
           rm -rf /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service > /dev/null 2>&1
           rm  -rf /etc/nginx/conf.d/sing-box.conf > /dev/null 2>&1
            esac
            green "\nsing-box 卸载成功\n\n" && exit 0
           ;;
       *)
           purple "已取消卸载操作\n\n"
           ;;
   esac
}

# 适配alpine运行argo报错用户组和dns的问题
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

update_script() {
    local remote_url="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/sing-box08.sh"
    local local_file="$work_dir/sb.sh"

    if curl -Lss "$remote_url" -o "${local_file}.tmp"; then
        if [ -s "${local_file}.tmp" ]; then
            mv -f "${local_file}.tmp" "$local_file"
            chmod +x "$local_file"
            ln -sf "$local_file" /usr/bin/sb
            green "\n脚本已更新！"
            sleep 1
            exec bash "$local_file"
        else
            rm -f "${local_file}.tmp"
            red "\n更新失败：下载的文件为空"
        fi
    else
        red "\n更新失败：请检查网络连接"
    fi
}


# BBR
enable_bbr() {
    local kernel_ver=$(uname -r)
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            alpine)
                echo -e "${yellow}正在初始化内核模块...${plain}"      
                for module in tcp_bbr sch_fq; do
                    if ! lsmod | grep -q "$module"; then
                        modprobe $module >/dev/null 2>&1
                        if ! grep -q "$module" /etc/modules 2>/dev/null; then
                            echo "$module" >> /etc/modules
                        fi
                    fi
                done
                ;;
        esac
    fi
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]] && [[ "$current_qdisc" =~ ^(fq|cake)$ ]]; then
        echo -e "${green}BBR 已经处于启用状态。${plain}"
    else
        echo -e "${yellow}正在为 ${ID:-系统} 配置 BBR...${plain}"
        if [ -d "/etc/sysctl.d/" ]; then
            cat > "/etc/sysctl.d/99-bbr-x-ui.conf" <<EOF
# Optimized BBR Config
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
            if [ -f "/etc/sysctl.conf" ]; then
                sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
                sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
            fi
            sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1
        else
            sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
            sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
        fi
        
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
        current_qdisc=$(sysctl -n net.core.default_qdisc)
    fi
    echo -e "---------------------------------------"
    echo -e "${green}系统类型:${plain}  ${yellow}${ID:-Unknown}${plain}"
    echo -e "${green}内核版本:${plain}  ${yellow}${kernel_ver}${plain}"
    echo -e "${green}TCP 算法:${plain}  ${blue}${current_cc}${plain}"
    echo -e "${green}队列规则:${plain}  ${blue}${current_qdisc}${plain}"
    echo -e "---------------------------------------"

    if [[ "$current_cc" != "bbr" ]]; then
        echo -e "${red}错误: 无法切换到 BBR，请检查您的系统内核或虚拟化环境（OpenVZ不支持）。${plain}"
    else
        echo -e "${green}BBR 开启成功！${plain}"
    fi
}

# SSH
vps_ssl() {
    while true; do
        clear
        green  "=== SSH配置 ==="
        skyblue "-----------------------"
        green  "1. 配置密钥 (生成秘钥/禁用密码)"
        skyblue "-----------------------"
        green  "2. 修改SSH登录端口"
        skyblue "-----------------------"
        green  "3. 安全组件更新 "
        skyblue "-----------------------"
        green  "4. 重启SSH服务 (使配置生效)"
        skyblue "-----------------------"
        green  "0. 返回主菜单"
        skyblue "-----------------------"
        reading "请输入选择 [0-4]: " ssl_choice

        case "${ssl_choice}" in
            1)
                yellow "正在配置 Ed25519 密钥认证..."
                [ ! -d ~/.ssh ] && mkdir -p ~/.ssh && chmod 700 ~/.ssh
                ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "vps_admin"
                cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
                chmod 600 ~/.ssh/authorized_keys
                sed -i '/^#\?PubkeyAuthentication/d' /etc/ssh/sshd_config
                sed -i '/^#\?PasswordAuthentication/d' /etc/ssh/sshd_config
                sed -i '/^#\?KbdInteractiveAuthentication/d' /etc/ssh/sshd_config
                sed -i '/^#\?ChallengeResponseAuthentication/d' /etc/ssh/sshd_config
                sed -i '/^#\?PermitRootLogin/d' /etc/ssh/sshd_config
                {
                    echo "PubkeyAuthentication yes"
                    echo "PasswordAuthentication no"
                    echo "KbdInteractiveAuthentication no"
                    echo "ChallengeResponseAuthentication no"
                    echo "PermitRootLogin yes"
                } >> /etc/ssh/sshd_config
                
                red "--------------------------------------------------"
                red "请务必保存下方私钥到本地 (id_ed25519)："
                echo ""
                yellow "$(cat ~/.ssh/id_ed25519)"
                echo ""
                red "--------------------------------------------------"
                rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
                green "配置完成！私钥已从服务器删除。"
                yellow "注意：请保存好私钥，并在重启 SSH 前确认端口已放行！"
                ;;
            2)
                read -p "请输入新的SSH登录端口号 (1024-65535): " new_port
                if [[ $new_port -ge 1024 && $new_port -le 65535 ]]; then
                    # 先删再加端口，防止重复
                    sed -i '/^#\?Port/d' /etc/ssh/sshd_config
                    echo "Port $new_port" >> /etc/ssh/sshd_config
                    green "端口已修改为 $new_port"
                    yellow "温馨提醒：重启SSH前请确保防火墙已放行 $new_port 端口。"
                else
                    red "错误：请输入 1024-65535 之间的数字。"
                fi
                ;;
            3)
                yellow "正在更新系统安全组件..."
                apt-get update && apt-get upgrade -y
                green "安全更新执行完毕！"
                ;;
            4)
                yellow "正在重启 SSH 服务..."
                if systemctl restart sshd; then
                    green "SSH 服务重启成功！"
                    yellow "请尝试用新端口/密钥开启新窗口连接，切勿立即关闭当前窗口！"
                else
                    red "重启失败，请检查 /etc/ssh/sshd_config 配置。"
                fi
                ;;
            0)
                return 0 # 跳出循环，返回主菜单
                ;;
            *)
                red "无效选项，请重新输入。"
                ;;
        esac
        
        echo ""
        read -n 1 -s -r -p $'\033[1;33m操作完成，按任意键菜单...\033[0m'
    done
}

# Iptables简单管理工具
ipt_msg() { echo -e "${1}${2}\033[0m"; }

check_rule_files() {
    local r4="/etc/iptables/rules.v4"
    local r6="/etc/iptables/rules.v6"
    if [ ! -d "/etc/iptables" ]; then
        mkdir -p /etc/iptables
    fi
    if [ ! -f "$r4" ] || ! grep -q "COMMIT" "$r4"; then
        cat > "$r4" << EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
EOF
    fi
    if [ ! -f "$r6" ] || ! grep -q "COMMIT" "$r6"; then
        cat > "$r6" << EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
EOF
    fi
}

iptables_ssl() {
    clear
    check_rule_files
    local tag="ScriptManaged"
    
    local status_text=""
    local mode_text=""
    local policy=$(iptables -L INPUT -n 2>/dev/null | head -n 1 | awk '{print $4}' | tr -d ')')
    local rule_count=$(iptables -L INPUT -n 2>/dev/null | grep -vE "^Chain|^target|^$" | wc -l)
    local svc_status=$(systemctl is-active netfilter-persistent 2>/dev/null)

    if ! command -v iptables &> /dev/null; then
        status_text="\033[0;31m未安装\033[0m"
        mode_text="\033[0;37m未知\033[0m"
    elif [ "$rule_count" -gt 0 ] || [ "$svc_status" == "active" ]; then
        status_text="\033[0;32m运行中\033[0m"
        if [ "$policy" == "DROP" ]; then
            mode_text="\033[0;32m开启\033[0m"
        else
            mode_text="\033[0;31m关闭\033[0m"
        fi
    else
        status_text="\033[0;31m已停止\033[0m"
        mode_text="\033[0;37m未拦截\033[0m"
    fi
	
    local ssh_p=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    [ -z "$ssh_p" ] && ssh_p=22

    local nat_rules=$(iptables -t nat -S PREROUTING 2>/dev/null | grep "DNAT" | awk '{
        port=""; to="";
        for(i=1;i<=NF;i++){
            if($i=="--dport") port=$(i+1);
            if($i=="--to-destination") to=$(i+1);
        }
        gsub(/:/, "-", port); 
        sub(/^:/, "", to);
        
        if(port != "") {
            print " 端口:" port " -> 转发至:" to
        }
    }')
    [ -z "$nat_rules" ] && nat_rules="  暂无转发规则"
	
    echo ""
    green "=== Iptables 防火墙管理 ==="
    echo -e "运行状态: $status_text"
    echo -e "拦截模式: $mode_text"
    ipt_msg "\033[0;36m" "系统当前 SSH 端口: ${ssh_p}"
	echo -e "\033[0;33m$nat_rules\033[0m"
    skyblue "---------------------------"

	    ipt_msg "\033[0;33m" "已在防火墙放行的端口:"
    printf "%-13s %-19s %-15s\n" "端口号" "所属服务" "说明"   
    local allowed_ports=""
    if command -v iptables &> /dev/null; then
        allowed_ports=$(iptables -L INPUT -n | grep "ACCEPT" | awk '{if($0 ~ /dpt:/) {split($0,a,"dpt:"); split(a[2],b," "); if(b[1]>0) print b[1]}}' | sort -un)
        iptables -L INPUT -n | grep "ACCEPT" | awk -v tag="$tag" '{
            port=""; if($0 ~ /dpt:/) { split($0, a, "dpt:"); split(a[2], b, " "); port=b[1] }
            if (port != "" && port != "ALL" && port > 0) {
                if (!seen[port]++) {
                    # 标识说明
                    note=($0 ~ tag) ? "脚本放行" : "系统/手动";
                    cmd = "ss -tunlp | grep \":" port " \" | head -n1"
                    name = "未运行"
                    if ((cmd | getline ss_line) > 0) {
                        if (ss_line ~ /"/) {
                            split(ss_line, s, "\"");
                            name = s[2];
                        }
                    }
                    close(cmd)
                    printf "\033[0;32m%-10s %-15s %-10s\033[0m\n", port, name, note
                }
            }
        }'
    fi
    
    echo -e "\033[0;36m---------------------------\033[0m"
    ipt_msg "\033[0;35m" "检测到正在运行但【未放行】的端口"
    printf "%-13s %-19s %-15s\n" "端口号"    "所属服务"    "监听IP"    
    ss -tunlp | awk 'NR>1 {
        addr = $5; n = split(addr, a, ":"); port = a[n];
        ip = ""; for(i=1; i<n; i++) ip = (ip == "" ? a[i] : ip ":" a[i]);
        if (ip ~ /:/ || ip ~ /\[/) next;
        if (ip == "" || ip == "*") ip = "0.0.0.0";
        name = "未知服务"; if ($NF ~ /"/) { split($NF, s, "\""); name = s[2] }
        if (port ~ /^[0-9]+$/ && port > 0) print port, name, ip}' | sort -un | sort -n -k1,1 | while read -r p_port p_name p_ip; do
        if ! echo "$allowed_ports" | grep -qw "$p_port"; then
            printf "\033[0;31m%-10s %-15s %-10s\033[0m\n" "$p_port" "$p_name" "$p_ip"
        fi
    done
    skyblue "---------------------------"
    
    green "1. 开启端口"
    green "2. 关闭端口"
    green "3. 开启拦截"
    green "4. 关闭拦截"
    green "5. 安装更新"
    green "6. 停止运行"
    green "7. 程序重启"
    purple "0. 回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " ipt_choice
    case "${ipt_choice}" in
         1)
            read -p "请输入要开放的端口号: " o_port
            if [ -z "$o_port" ]; then
                yellow "未输入端口号，操作已取消。"
            elif [ "$o_port" -eq 0 ] 2>/dev/null; then
                red "错误：端口号不能为 0"
            else
                if ! grep -q "\--dport $o_port " /etc/iptables/rules.v4 2>/dev/null; then
                    sed -i "/\*filter/,/COMMIT/ { /COMMIT/ i -A INPUT -p tcp --dport $o_port -m comment --comment \"$tag\" -j ACCEPT
                    }" /etc/iptables/rules.v4
                    sed -i "/\*filter/,/COMMIT/ { /COMMIT/ i -A INPUT -p udp --dport $o_port -m comment --comment \"$tag\" -j ACCEPT
                    }" /etc/iptables/rules.v4
                    
                    if [ -f "/etc/iptables/rules.v6" ]; then
                        sed -i "/\*filter/,/COMMIT/ { /COMMIT/ i -A INPUT -p tcp --dport $o_port -m comment --comment \"$tag\" -j ACCEPT
                        }" /etc/iptables/rules.v6
                        sed -i "/\*filter/,/COMMIT/ { /COMMIT/ i -A INPUT -p udp --dport $o_port -m comment --comment \"$tag\" -j ACCEPT
                        }" /etc/iptables/rules.v6
                    fi

                    if iptables-restore < /etc/iptables/rules.v4; then
                        [ -f "/etc/iptables/rules.v6" ] && ip6tables-restore < /etc/iptables/rules.v6
                        green "成功：端口 $o_port 已放行 (IPv4/IPv6)"
                    else
                        red "错误：iptables 配置文件格式损坏，请检查 /etc/iptables/rules.v4"
                    fi
                else
                    yellow "端口 $o_port 规则已存在，无需重复添加"
                fi
            fi
            sleep 1 && iptables_ssl ;;
        2)
            read -p "请输入要关闭端口号: " c_port
            if [ -z "$c_port" ]; then
                yellow "未输入端口号，操作取消"
            elif [ "$c_port" -eq 0 ] 2>/dev/null; then
                red "错误：端口号不能为 0"
            else
                sed -i "/--dport $c_port /d" /etc/iptables/rules.v4
                [ -f "/etc/iptables/rules.v6" ] && sed -i "/--dport $c_port /d" /etc/iptables/rules.v6
                
                iptables-restore < /etc/iptables/rules.v4
                [ -f "/etc/iptables/rules.v6" ] && ip6tables-restore < /etc/iptables/rules.v6
                green "清理完成：端口 $c_port 已关闭"
            fi
            sleep 1 && iptables_ssl ;;

        3)
        yellow "正在开启拦截..."
        ssh_ports=$(grep -E "^Port\s+" /etc/ssh/sshd_config | awk '{print $2}')
        [ -z "$ssh_ports" ] && ssh_ports=22
        if ! iptables-save | grep -q "RELATED,ESTABLISHED"; then
            iptables -I INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
        fi
        if ! iptables-save | grep -q "INPUT -i lo"; then
            iptables -I INPUT -i lo -j ACCEPT
        fi
        for port in $ssh_ports; do
            if ! iptables-save | grep -q "INPUT .*--dport $port .*ACCEPT"; then
                iptables -I INPUT -p tcp --dport $port -m comment --comment "SSH_Port" -j ACCEPT
            fi
        done
        iptables -P INPUT DROP
        if command -v ip6tables &> /dev/null; then
            if ! ip6tables-save | grep -q "RELATED,ESTABLISHED"; then
                ip6tables -I INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
            fi
            if ! ip6tables-save | grep -q "INPUT -i lo"; then
                ip6tables -I INPUT -i lo -j ACCEPT
            fi
			if ! ip6tables-save | grep -q "INPUT -p ipv6-icmp -j ACCEPT"; then
            ip6tables -I INPUT -p ipv6-icmp -j ACCEPT
            fi           
            for port in $ssh_ports; do
                if ! ip6tables-save | grep -q "INPUT .*--dport $port .*ACCEPT"; then
                    ip6tables -I INPUT -p tcp --dport $port -m comment --comment "SSH_Port" -j ACCEPT
                fi
            done
            ip6tables -P INPUT DROP
        fi
        iptables-save > /etc/iptables/rules.v4
        [ -f "/etc/iptables/rules.v6" ] && ip6tables-save > /etc/iptables/rules.v6
        
        green "开启拦截成功 (已自动放行 SSH 端口: $ssh_ports)" && sleep 1
        iptables_ssl ;;
         4)
            yellow "正在关闭拦截..."
            iptables -P INPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -P OUTPUT ACCEPT
            iptables-save > /etc/iptables/rules.v4
            if command -v ip6tables &> /dev/null; then
                ip6tables -P INPUT ACCEPT
                ip6tables -P FORWARD ACCEPT
                ip6tables -P OUTPUT ACCEPT
                # 只有当 rules.v6 文件存在或需要持久化时才保存
                ip6tables-save > /etc/iptables/rules.v6
            fi
            green "已关闭拦截" && sleep 1
            iptables_ssl ;;
		5)
        yellow "正在配置环境..."
        [[ $EUID -ne 0 ]] && red "请使用 root 用户运行此脚本！" && exit 1      
        if [ -f /etc/debian_version ]; then
            apt-get update -y
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
            apt-get install -y iptables iptables-persistent
        elif [ -f /etc/redhat-release ]; then
            yum install -y iptables-services
            systemctl enable iptables && systemctl start iptables
            systemctl enable ip6tables && systemctl start ip6tables
        fi
        check_rule_files
        iptables-restore < /etc/iptables/rules.v4
        [ -f "/etc/iptables/rules.v6" ] && ip6tables-restore < /etc/iptables/rules.v6     
        green "环境配置完成！已初始化规则文件并开启防火墙。" 
        sleep 1 && iptables_ssl ;;
		6)
            yellow "正在停止防火墙并清空内存规则..."
            systemctl stop netfilter-persistent 2>/dev/null
            systemctl stop iptables 2>/dev/null
            systemctl stop ip6tables 2>/dev/null
            iptables -P INPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -P OUTPUT ACCEPT
            iptables -F
            iptables -X
            iptables -Z
            if command -v ip6tables >/dev/null; then
                ip6tables -P INPUT ACCEPT
                ip6tables -P FORWARD ACCEPT
                ip6tables -P OUTPUT ACCEPT
                ip6tables -F
                ip6tables -X
                ip6tables -Z
            fi
            green "防火墙已停止，内存规则已清空。重启系统服务可恢复。"
            sleep 1 && iptables_ssl ;;
        7)
            yellow "正在重载并激活防火墙规则..."
            if command -v systemctl >/dev/null 2>&1; then
                for svc in netfilter-persistent iptables ip6tables; do
                    if systemctl list-unit-files | grep -q "^$svc.service"; then
                        if [ "$(systemctl is-active $svc)" != "active" ]; then
                            yellow "检测到 $svc 服务未运行，正在启动..."
                            systemctl enable $svc >/dev/null 2>&1
                            systemctl start $svc >/dev/null 2>&1
                        fi
                    fi
                done
            fi
            if [ -f "/etc/iptables/rules.v4" ]; then
                if iptables-restore < /etc/iptables/rules.v4; then
                    green "IPv4 规则已从 rules.v4 同步至内存。"
                else
                    red "错误：IPv4 规则文件格式异常，加载失败。"
                fi
            else
                yellow "未发现 IPv4 规则文件，略过加载。"
            fi
            if [ -f "/etc/iptables/rules.v6" ]; then
                if command -v ip6tables-restore >/dev/null 2>&1; then
                    if ip6tables-restore < /etc/iptables/rules.v6; then
                        green "IPv6 规则已从 rules.v6 同步至内存。"
                    else
                        red "错误：IPv6 规则文件格式异常，加载失败。"
                    fi
                else
                    yellow "系统不支持 ip6tables-restore 命令，略过加载。"
                fi
            else
                [ -f /proc/net/if_inet6 ] && yellow "未发现 IPv6 规则文件，略过加载。"
            fi
            green "重载操作执行完毕。"
            sleep 1 && iptables_ssl ;;
        0) menu ;;
        *) iptables_ssl ;;
    esac
}

# 其他
vps_s() {
    ip_address    
    if [ "$(uname -m)" == "x86_64" ]; then
      cpu_info=$(cat /proc/cpuinfo | grep 'model name' | uniq | sed -e 's/model name[[:space:]]*: //')
    else
      cpu_info=$(lscpu | grep 'Model name' | sed -e 's/Model name[[:space:]]*: //')
    fi
    cpu_usage=$(top -bn1 | grep 'Cpu(s)' | awk '{print $2 + $4}')
    cpu_usage_percent=$(printf "%.2f" "$cpu_usage")%
    cpu_cores=$(nproc)
    mem_info=$(free -b | awk 'NR==2{printf "%.2f/%.2f MB (%.2f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')
    disk_info=$(df -h | awk '$NF=="/"{printf "%d/%dGB (%s)", $3,$2,$5}')
    country=$(curl -s ipinfo.io/country)
    city=$(curl -s ipinfo.io/city)
    isp_info=$(curl -s ipinfo.io/org)
    cpu_arch=$(uname -m)
    hostname=$(hostname)
    kernel_version=$(uname -r)
    congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control)
    queue_algorithm=$(sysctl -n net.core.default_qdisc)
    # 尝试使用 lsb_release 获取系统信息
    os_info=$(lsb_release -ds 2>/dev/null)
    if [ -z "$os_info" ]; then
      # 检查常见的发行文件
      if [ -f "/etc/os-release" ]; then
        os_info=$(source /etc/os-release && echo "$PRETTY_NAME")
      elif [ -f "/etc/debian_version" ]; then
        os_info="Debian $(cat /etc/debian_version)"
      elif [ -f "/etc/redhat-release" ]; then
        os_info=$(cat /etc/redhat-release)
      else
        os_info="Unknown"
      fi
    fi

    clear
    output=$(awk 'BEGIN { rx_total = 0; tx_total = 0 }
        NR > 2 { rx_total += $2; tx_total += $10 }
        END {
            rx_units = "Bytes";
            tx_units = "Bytes";
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "KB"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "MB"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "GB"; }

            if (tx_total > 1024) { tx_total /= 1024; tx_units = "KB"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "MB"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "GB"; }

            printf("总接收: %.2f %s\n总发送: %.2f %s\n", rx_total, rx_units, tx_total, tx_units);
        }' /proc/net/dev)
    current_time=$(date "+%Y-%m-%d %I:%M %p")
    swap_used=$(free -m | awk 'NR==3{print $3}')
    swap_total=$(free -m | awk 'NR==3{print $2}')

    if [ "$swap_total" -eq 0 ]; then
        swap_percentage=0
    else
        swap_percentage=$((swap_used * 100 / swap_total))
    fi
    swap_info="${swap_used}MB/${swap_total}MB (${swap_percentage}%)"
    runtime=$(cat /proc/uptime | awk -F. '{run_days=int($1 / 86400);run_hours=int(($1 % 86400) / 3600);run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}')
    echo ""
    echo -e "${white}系统信息详情${re}"
    echo "------------------------"
    echo -e "${white}主机名: ${purple}${hostname}${re}"
    echo -e "${white}运营商: ${purple}${isp_info}${re}"
    echo "------------------------"
    echo -e "${white}系统版本: ${purple}${os_info}${re}"
    echo -e "${white}Linux版本: ${purple}${kernel_version}${re}"
    echo "------------------------"
    echo -e "${white}CPU架构: ${purple}${cpu_arch}${re}"
    echo -e "${white}CPU型号: ${purple}${cpu_info}${re}"
    echo -e "${white}CPU核心数: ${purple}${cpu_cores}${re}"
    echo "------------------------"
    echo -e "${white}CPU占用: ${purple}${cpu_usage_percent}${re}"
    echo -e "${white}物理内存: ${purple}${mem_info}${re}"
    echo -e "${white}虚拟内存: ${purple}${swap_info}${re}"
    echo -e "${white}硬盘占用: ${purple}${disk_info}${re}"
    echo "------------------------"
    echo -e "${purple}$output${re}"
    echo "------------------------"
    echo -e "${white}网络拥堵算法: ${purple}${congestion_algorithm} ${queue_algorithm}${re}"
    echo "------------------------"
    echo -e "${white}公网IPv4地址: ${purple}${ipv4_address}${re}"
    echo -e "${white}公网IPv6地址: ${purple}${ipv6_address}${re}"
    echo "------------------------"
    echo -e "${white}地理位置: ${purple}${country} $city${re}"
    echo -e "${white}系统时间: ${purple}${current_time}${re}"
    echo "------------------------"
    echo -e "${white}系统运行时长: ${purple}${runtime}${re}"
    echo
}            

# singbox 管理
manage_singbox() {
    # 检查sing-box状态
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?
    
    clear
    echo ""
    green "=== sing-box 管理 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 启动sing-box服务"
    skyblue "-------------------"
    green "2. 停止sing-box服务"
    skyblue "-------------------"
    green "3. 重启sing-box服务"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_singbox ;;  
        2) stop_singbox ;;
        3) restart_singbox ;;
        0) menu ;;
        *) red "无效的选项！" && sleep 1 && manage_singbox;;
    esac
}            

# Argo 管理
manage_argo() {
    # 检查Argo状态
    local argo_status=$(check_argo 2>/dev/null)
    local argo_installed=$?

    clear
    echo ""
    green "=== Argo 隧道管理 ===\n"
    green "Argo当前状态: $argo_status\n"
    green "1. 启动Argo服务"
    skyblue "------------"
    green "2. 停止Argo服务"
    skyblue "------------"
    green "3. 重启Argo服务"
    skyblue "------------"
    green "4. 添加Argo固定隧道"
    skyblue "----------------"
    green "5. 切换回Argo临时隧道"
    skyblue "------------------"
    green "6. 重新获取Argo临时域名"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "-----------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1)  start_argo ;;
        2)  stop_argo ;; 
        3)  clear
            if command_exists rc-service 2>/dev/null; then
                grep -Fq -- '--url http://localhost' /etc/init.d/argo && get_quick_tunnel && change_argo_domain || { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            else
                grep -q 'ExecStart=.*--url http://localhost' /etc/systemd/system/argo.service && get_quick_tunnel && change_argo_domain || { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            fi
         ;; 
        4)
            clear
            yellow "\n固定隧道可为json或token，固定隧道端口为8001，自行在cf后台设置\n\njson在f佬维护的站点里获取，获取地址：${purple}https://fscarmen.cloudflare.now.cc${re}\n"
            reading "\n请输入你的argo域名: " argo_domain
            ArgoDomain=$argo_domain
            reading "\n请输入你的argo密钥(token或json): " argo_auth
            if [[ $argo_auth =~ TunnelSecret ]]; then
                echo $argo_auth > ${work_dir}/tunnel.json
                cat > ${work_dir}/tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$argo_auth")
credentials-file: ${work_dir}/tunnel.json
protocol: http2
                                           
ingress:
  - hostname: $ArgoDomain
    service: http://localhost:8001
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

                if command_exists rc-service 2>/dev/null; then
                    sed -i '/^command_args=/c\command_args="-c '\''/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1'\''"' /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo
                sleep 1 
                change_argo_domain

            elif [[ $argo_auth =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                if command_exists rc-service 2>/dev/null; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argo_auth 2>&1'\"" /etc/init.d/argo
                else

                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '$argo_auth' 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo
                sleep 1 
                change_argo_domain
            else
                yellow "你输入的argo域名或token不匹配，请重新输入"
                manage_argo            
            fi
            ;; 
        5)
            clear
            if command_exists rc-service 2>/dev/null; then
                alpine_openrc_services
            else
                main_systemd_services
            fi
            get_quick_tunnel
            change_argo_domain 
            ;; 

        6)  
            if command_exists rc-service 2>/dev/null; then
                if grep -Fq -- '--url http://localhost' "/etc/init.d/argo"; then
                    get_quick_tunnel
                    change_argo_domain 
                else
                    yellow "当前使用固定隧道，无法获取临时隧道"
                    sleep 2
                    menu
                fi
            else
                if grep -q 'ExecStart=.*--url http://localhost' "/etc/systemd/system/argo.service"; then
                    get_quick_tunnel
                    change_argo_domain 
                else
                    yellow "当前使用固定隧道，无法获取临时隧道"
                    sleep 2
                    menu
                fi
            fi 
            ;; 
        0)  menu ;; 
        *)  red "无效的选项！" ;;
    esac
}

# 获取argo临时隧道
get_quick_tunnel() {
restart_argo
yellow "获取临时argo域名中，请稍等...\n"
sleep 3
if [ -f /etc/sing-box/argo.log ]; then
  for i in {1..5}; do
      purple "第 $i 次尝试获取ArgoDoamin中..."
      get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "/etc/sing-box/argo.log")
      [ -n "$get_argodomain" ] && break
      sleep 2
  done
else
  restart_argo
  sleep 6
  get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "/etc/sing-box/argo.log")
fi
green "ArgoDomain：${purple}$get_argodomain${re}\n"
ArgoDomain=$get_argodomain
}

# 更新Argo域名到订阅
change_argo_domain() {
content=$(cat "$client_dir")
vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir")
vmess_prefix="vmess://"
encoded_vmess="${vmess_url#"$vmess_prefix"}"
decoded_vmess=$(echo "$encoded_vmess" | base64 --decode)
updated_vmess=$(echo "$decoded_vmess" | jq --arg new_domain "$ArgoDomain" '.host = $new_domain | .sni = $new_domain')
encoded_updated_vmess=$(echo "$updated_vmess" | base64 | tr -d '\n')
new_vmess_url="${vmess_prefix}${encoded_updated_vmess}"
new_content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
echo "$new_content" > "$client_dir"
base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt
green "vmess节点已更新,更新订阅或手动复制以下vmess-argo节点\n"
purple "$new_vmess_url\n" 
}

# 查看节点信息和订阅链接
check_nodes() {
    if [ -f "${work_dir}/url.txt" ]; then
        while IFS= read -r line; do 
            purple "$line"
        done < "${work_dir}/url.txt"
    fi

    local nginx_conf="/etc/nginx/conf.d/sing-box.conf"
    local domain_conf="/etc/nginx/conf.d/sing-box1.conf"
    local found_any=false 
    if [ -f "$domain_conf" ]; then
        local sub_domain=$(sed -n 's/^\s*server_name\s\+\([^;]\+\);.*/\1/p' "$domain_conf" | tr -d ' ')
        local sub_port=$(sed -n 's/^\s*listen\s\+\([0-9]\+\).*/\1/p' "$domain_conf" | head -n 1)
        local sub_path=$(sed -n 's|.*location = /\([^ {]*\).*|\1|p' "$domain_conf")
        
        if [ -n "$sub_domain" ] && [ "$sub_domain" != "_" ]; then
            local domain_url="https://${sub_domain}:${sub_port}/${sub_path}"
            green "订阅链接: ${purple}${domain_url}${re}"
            found_any=true
        fi
    fi
    if [ -f "$nginx_conf" ]; then
        server_ip=$(get_realip)
        lujing=$(sed -n 's|.*location = /\([^ ]*\).*|\1|p' "$nginx_conf")
        sub_port=$(sed -n 's/^\s*listen \([0-9]\+\);/\1/p' "$nginx_conf")      
        base64_url="http://${server_ip}:${sub_port}/${lujing}"        
        green "订阅链接: ${purple}${base64_url}${re}\n"
        found_any=true
    fi
    if [ "$found_any" = false ]; then
        red "订阅服务未配置或订阅已关闭\n"
    fi
}


change_cfip() {
    clear
    yellow "修改vmess-argo优选域名\n"
    green "1: cf.090227.xyz  2: cf.877774.xyz  3: cf.877771.xyz  4: cdns.doon.eu.org  5: cf.zhetengsha.eu.org  6: time.is\n"
    reading "请输入你的优选域名或优选IP\n(请输入1至6选项,可输入域名:端口 或 IP:端口,直接回车默认使用1): " cfip_input

    if [ -z "$cfip_input" ]; then
        cfip="cf.090227.xyz"
        cfport="443"
    else
        case "$cfip_input" in
            "1")
                cfip="cf.090227.xyz"
                cfport="443"
                ;;
            "2")
                cfip="cf.877774.xyz"
                cfport="443"
                ;;
            "3")
                cfip="cf.877771.xyz"
                cfport="443"
                ;;
            "4")
                cfip="cdns.doon.eu.org"
                cfport="443"
                ;;
            "5")
                cfip="cf.zhetengsha.eu.org"
                cfport="443"
                ;;
            "6")
                cfip="time.is"
                cfport="443"
                ;;
            *)
                if [[ "$cfip_input" =~ : ]]; then
                    cfip=$(echo "$cfip_input" | cut -d':' -f1)
                    cfport=$(echo "$cfip_input" | cut -d':' -f2)
                else
                    cfip="$cfip_input"
                    cfport="443"
                fi
                ;;
        esac
    fi

content=$(cat "$client_dir")
vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir")
encoded_part="${vmess_url#vmess://}"
decoded_json=$(echo "$encoded_part" | base64 --decode 2>/dev/null)
updated_json=$(echo "$decoded_json" | jq --arg cfip "$cfip" --argjson cfport "$cfport" \
    '.add = $cfip | .port = $cfport')
new_encoded_part=$(echo "$updated_json" | base64 -w0)
new_vmess_url="vmess://$new_encoded_part"
new_content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
echo "$new_content" > "$client_dir"
base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt"
green "\nvmess节点优选域名已更新为：${purple}${cfip}:${cfport},${green}更新订阅或手动复制以下vmess-argo节点${re}\n"
purple "$new_vmess_url\n"
}

# 主菜单
menu() {
   singbox_status=$(check_singbox 2>/dev/null)
   nginx_status=$(check_nginx 2>/dev/null)
   argo_status=$(check_argo 2>/dev/null)
   
   clear
   echo ""
   green "Telegram群组: ${purple}https://t.me/eooceu${re}"
   green "Github地址: ${purple}https://github.com/eooce/sing-box${re}\n"
   green "${purple}快捷命令sb或者b${re}"
   purple "=== 老王sing-box四合一安装脚本 ===\n"
   purple "---Argo 状态: ${argo_status}"   
   purple "--Nginx 状态: ${nginx_status}"
   purple "singbox 状态: ${singbox_status}\n"
   green "1. 安装sing-box"
   red "2. 卸载sing-box"
   echo "==============="
   green "3. sing-box管理"
   green "4. Argo隧道管理"
   echo  "==============="
   green  "5. 查看节点信息"
   green  "6. 修改节点配置"
   green  "7. 管理节点订阅"
   green  "8. 更新sing-box"
   green  "9. 添加删除节点"
   green  "10. 开启BBR"
   echo  "==============="
   red    "11. 更新脚本"
   red    "12. SSH配置"
   red    "13. iptables"
   red    "14. 本机信息"
   red    "15. 快捷指令"
   echo  "==============="
   red "0. 退出脚本"
   echo "==========="
   reading "请输入选择(0-15): " choice
   echo ""
}

# 捕获 Ctrl+C 退出信号
trap 'red "已取消操作"; exit' INT

# 主循环
while true; do
   menu
   case "${choice}" in
        1)  
            check_singbox &>/dev/null; check_singbox=$?
            if [ ${check_singbox} -eq 0 ]; then
                yellow "sing-box 已经安装！\n"
            else
                manage_packages install nginx jq tar openssl lsof coreutils
                install_singbox
                if command_exists systemctl; then
                    main_systemd_services
                elif command_exists rc-update; then
                    alpine_openrc_services
                    change_hosts
                    rc-service sing-box restart
                    rc-service argo restart
                else
                    echo "Unsupported init system"
                    exit 1 
                fi

                sleep 5
                get_info
                add_nginx_conf
				create_shortcut
            fi
           ;;
        2) uninstall_singbox ;;
        3) manage_singbox ;;
        4) manage_argo ;;
        5) check_nodes ;;
        6) change_config ;;
        7) disable_open_sub ;;
		8) 
           clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/sing.sh)
		   ;;
		9) manage_nodes_menu ;;
	    10) enable_bbr ;;
		11) update_script ;;
		12) vps_ssl ;;
		13) iptables_ssl ;;
		14) vps_s ;;
		15) 
           clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/aa.sh)
		   ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 15" ;;
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
done
