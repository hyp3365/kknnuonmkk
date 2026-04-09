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
    mkdir -p /etc/sing-box
    local config_file="/etc/sing-box/config.json"
    local client_file="/etc/sing-box/url.txt"
    local work_dir="/usr/local/bin"
    if [ -f "$config_file" ]; then
        uuid=$(grep -m 1 '"uuid":' "$config_file" | awk -F '"' '{print $4}')
    fi
    [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid)
    if [ -f "$config_file" ]; then
        private_key=$(grep -m 1 '"private_key":' "$config_file" | awk -F '"' '{print $4}')
    fi
    if [ -f "$client_file" ]; then
        public_key=$(grep -m 1 'pbk=' "$client_file" | sed -n 's/.*pbk=\([^&]*\).*/\1/p')
    fi
    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        if [ -f "${work_dir}/sing-box" ]; then
            output=$(${work_dir}/sing-box generate reality-keypair)
            private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
            public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')
        fi
    fi
    h2_reality=$(shuf -i 10000-60000 -n 1)
	socks_port=$(shuf -i 10000-60000 -n 1)
	anytls_port=$(shuf -i 10000-60000 -n 1)
	grpc_reality=$(shuf -i 10000-60000 -n 1)
	vless_ws_cdn_port=$(shuf -i 10000-60000 -n 1)
	username=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 15)
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
    short_id=$(openssl rand -hex 6)
}


# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
export vless_port=${PORT:-$(shuf -i 1000-65000 -n 1)}
export CFIP=${CFIP:-'cf.877774.xyz'} 
export CFPORT=${CFPORT:-'443'} 

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

# 检查nginx状态
check_nginx() {
    command_exists nginx || { red "not installed"; return 2; }
    check_service "nginx" "$(command -v nginx)"
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

# 处理防火墙
allow_port() {
    has_ufw=0
    has_firewalld=0
    has_iptables=0
    has_ip6tables=0

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    # 出站和基础规则
    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --zone=public --set-target=ACCEPT >/dev/null 2>&1
    [ "$has_iptables" -eq 1 ] && {
        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i lo -j ACCEPT
        iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p icmp -j ACCEPT
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    }
    [ "$has_ip6tables" -eq 1 ] && {
        ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT 3 -i lo -j ACCEPT
        ip6tables -C INPUT -p icmp -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p icmp -j ACCEPT
        ip6tables -P FORWARD DROP 2>/dev/null || true
        ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    }

    # 入站
    for rule in "$@"; do
        port=${rule%/*}
        proto=${rule#*/}
        [ "$has_ufw" -eq 1 ] && ufw allow in ${port}/${proto} >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        [ "$has_iptables" -eq 1 ] && (iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT)
        [ "$has_ip6tables" -eq 1 ] && (ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT)
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1

    # 规则持久化
    if command_exists rc-service 2>/dev/null; then
        [ "$has_iptables" -eq 1 ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null
        [ "$has_ip6tables" -eq 1 ] && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    else
        if ! command_exists netfilter-persistent; then
            manage_packages install iptables-persistent || yellow "请手动安装netfilter-persistent或保存iptables规则" 
            netfilter-persistent save >/dev/null 2>&1
        elif command_exists service; then
            service iptables save 2>/dev/null
            service ip6tables save 2>/dev/null
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

   # 生成随机端口和密码
    nginx_port=$(($vless_port + 1)) 
    tuic_port=$(($vless_port + 2))
    hy2_port=$(($vless_port + 3)) 
    uuid=$(cat /proc/sys/kernel/random/uuid)
	username=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 15)
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
    output=$(/etc/sing-box/sing-box generate reality-keypair)
	short_id=$(/etc/sing-box/sing-box generate rand --hex 6)
    private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')

    # 放行端口
    allow_port $vless_port/tcp $nginx_port/tcp $tuic_port/udp $hy2_port/udp > /dev/null 2>&1

    # 生成自签名证书
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
    
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
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $vless_port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    },
    {
         "type": "vmess",
         "tag": "vmess-ws",
         "listen": "127.0.0.1",
         "listen_port": 8002, 
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
     },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": $hy2_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "ignore_client_bandwidth": false,
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": $tuic_port,
      "users": [
        {
          "uuid": "$uuid",
          "password": "$password"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
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
      "type": "direct",
      "tag": "native-out",
      "bind_interface": "eth0"#vps原生网卡
   },
   {
     "type": "direct",
     "tag": "he-out",
     "bind_interface": "he-ipv6"#he隧道网卡 没啥用的
	 #在/etc/network/interfaces 文件最后添加  没什么大用
    },
	{
      "type": "socks",
      "tag": "socks-out",  
      "server": "35.212.208.203",    
      "server_port": 8080,       
      "version": "5",          
      "username": "ssaampp",    
      "password": "semppspsa",
      "udp_over_tcp": false       
     },
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
        "inbound": ["tuic"], // 限制只针对这个节点 可以增加多个节点
        "domain_suffix": [
          "ping.pe"
          #"ip.sb",
          #"youtube.com",
          #"googlevideo.com",
          #"ytimg.com",
          #"ggpht.com",
          #"youtube-nocookie.com",
          #"youtu.be"
          ],
          "outbound": "socks-out"
      },
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
  clear
  isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" | tr -d '\n' | awk -F\" '{c="";o="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="org")o=$(x+2)};if(c&&o)print c"-"o}' | sed 's/ /_/g' || echo "$hostname")
  
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

  VMESS="{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/mPaxe1996Ko-5203aap?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowlnsecure\": \"flase\"}"

  cat > ${work_dir}/url.txt <<EOF
vless://${uuid}@${server_ip}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${isp}

vmess://$(echo "$VMESS" | base64 -w0)

hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=www.bing.com&insecure=1&alpn=h3&obfs=none#${isp}

tuic://${uuid}:${password}@${server_ip}:${tuic_port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${isp}

EOF
echo ""
while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt
base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt
chmod 644 ${work_dir}/sub.txt
yellow "\n温馨提醒：需打开V2rayN或其他软件里的 "跳过证书验证"，或将节点的Insecure或TLS里设置为"true"\n"
green "V2rayN,Shadowrocket,Nekobox,Loon,Karing,Sterisand订阅链接：http://${server_ip}:${nginx_port}/${password}\n"
}

# nginx订阅配置
add_nginx_conf() {
    if ! command_exists nginx; then
        red "nginx未安装,无法配置订阅服务"
        return 1
    else
        manage_service "nginx" "stop" > /dev/null 2>&1
        pkill nginx  > /dev/null 2>&1
    fi

    mkdir -p /etc/nginx/conf.d

    [[ -f "/etc/nginx/conf.d/sing-box.conf" ]] && cp /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/sing-box.conf.bak.sb
    cat > /etc/nginx/conf.d/sing-box.conf << EOF
# ======= 1. 订阅服务 (监听订阅端口) =======
server {
    listen $nginx_port;
    listen [::]:$nginx_port;
    server_name _;

    # 安全设置
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /$password {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location / {
        return 404;
    }
	location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}

# ======= 2. 后端连接池 =======
upstream vmess_ws { server 127.0.0.1:8002; keepalive 32; }
upstream vless_ws { server 127.0.0.1:8003; keepalive 32; }

# ======= 3. 核心分流转发 (这里的 \$ 符号确保 Nginx 正常识别) =======
server {
    listen 127.0.0.1:8001 so_keepalive=on;
    http2 on; 
    server_name _;

    tcp_nodelay on;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_http_version 1.1;
    
    # 注意：下面这些 \$ 符号是必须的，否则写入文件时变量会丢失
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

    # VMess WS
    location /mPaxe1996Ko-5203aap {
        proxy_pass http://vmess_ws;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }

    # VLESS WS
    location /lPaxe1996Ko-5203aap {
        proxy_pass http://vless_ws;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
    location / { return 404; }
	location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    if [ -f "/etc/nginx/nginx.conf" ]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.sb > /dev/null 2>&1
        sed -i -e '15{/include \/etc\/nginx\/modules\/\*\.conf/d;}' -e '18{/include \/etc\/nginx\/conf\.d\/\*\.conf/d;}' /etc/nginx/nginx.conf > /dev/null 2>&1
        # 检查是否已包含配置目录
        if ! grep -q "include.*conf.d" /etc/nginx/nginx.conf; then
            http_end_line=$(grep -n "^}" /etc/nginx/nginx.conf | tail -1 | cut -d: -f1)
            if [ -n "$http_end_line" ]; then
                sed -i "${http_end_line}i \    include /etc/nginx/conf.d/*.conf;" /etc/nginx/nginx.conf > /dev/null 2>&1
            fi
        fi
    else 
        cat > /etc/nginx/nginx.conf << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  65;
    
    include /etc/nginx/conf.d/*.conf;
}
EOF
    fi

    # 检查nginx配置语法
    if nginx -t > /dev/null 2>&1; then
    
        if nginx -s reload > /dev/null 2>&1; then
            green "nginx订阅配置已加载"
        else
            start_nginx  > /dev/null 2>&1
        fi
    else
        yellow "nginx配置失败,订阅不可应,但不影响节点使用, issues反馈: https://github.com/eooce/Sing-box/issues"
        restart_nginx  > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            green "nginx订阅配置已生效"
        else
            [[ -f "/etc/nginx/nginx.conf.bak.sb" ]] && cp "/etc/nginx/nginx.conf.bak.sb" /etc/nginx/nginx.conf > /dev/null 2>&1
            restart_nginx  > /dev/null 2>&1
        fi
    fi
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

# 启动 nginx
start_nginx() {
    manage_service "nginx" "start"
}

# 停止 nginx
stop_nginx() {
    manage_service "nginx" "stop"
}

# 重启 nginx
restart_nginx() {
    manage_service "nginx" "restart"
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
           # 删除配置文件和日志
           rm -rf "${work_dir}" || true
           rm -rf "${log_dir}" || true
           rm -rf /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service > /dev/null 2>&1
           rm  -rf /etc/nginx/conf.d/sing-box.conf > /dev/null 2>&1
           
           # 卸载Nginx
           reading "\n是否卸载 Nginx？${green}(卸载请输入 ${yellow}y${re} ${green}回车将跳过卸载Nginx) (y/n): ${re}" choice
            case "${choice}" in
                y|Y)
				    stop_nginx
                    manage_packages uninstall nginx
					rm -f /etc/nginx/conf.d/sing-box.conf
                    rm -f /etc/nginx/conf.d/sing-box.conf.bak*
                    ;;
                 *) 
                    yellow "取消卸载Nginx\n\n"
                    ;;
            esac

            green "\nsing-box 卸载成功\n\n" && exit 0
           ;;
       *)
           purple "已取消卸载操作\n\n"
           ;;
   esac
}

# 创建快捷指令
create_shortcut() {
  cat > "$work_dir/sb.sh" << EOF
#!/usr/bin/env bash
bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/sing-box08.sh) \$1
EOF
  chmod +x "$work_dir/sb.sh"
  ln -sf "$work_dir/sb.sh" /usr/bin/sb
  if [ -s /usr/bin/sb ]; then
    green "\n快捷指令 sb 创建成功\n"
  else
    red "\n快捷指令创建失败\n"
  fi
}

# 适配alpine运行argo报错用户组和dns的问题
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# 变更配置
change_config() {
    # 检查sing-box状态
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?
    
    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"
        sleep 1
        menu
        return
    fi
    
    clear
    echo ""
    green "=== 修改节点配置 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 修改端口"
    skyblue "------------"
    green "2. 修改UUID"
    skyblue "------------"
    green "3. 修改Reality伪装域名"
    skyblue "------------"
    green "4. 添加hysteria2端口跳跃"
    skyblue "------------"
    green "5. 删除hysteria2端口跳跃"
    skyblue "------------"
    green "6. 修改vmess-argo优选域名"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            echo ""
            green "1. 修改vless-reality端口"
            skyblue "------------"
            green "2. 修改hysteria2端口"
            skyblue "------------"
            green "3. 修改tuic端口"
            skyblue "------------"
            green "4. 修改vmess-argo端口"
            skyblue "------------"
            purple "0. 返回上一级菜单"
            skyblue "------------"
            reading "请输入选择: " choice
            case "${choice}" in
                1)
                    reading "\n请输入vless-reality端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    sed -i '/"type": "vless"/,/listen_port/ s/"listen_port": [0-9]\+/"listen_port": '"$new_port"'/' $config_dir
                    restart_singbox
                    allow_port $new_port/tcp > /dev/null 2>&1
                    sed -i 's/\(vless:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nvless-reality端口已修改成：${purple}$new_port${re} ${green}请更新订阅或手动更改vless-reality端口${re}\n"
                    ;;
                2)
                    reading "\n请输入hysteria2端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    sed -i '/"type": "hysteria2"/,/listen_port/ s/"listen_port": [0-9]\+/"listen_port": '"$new_port"'/' $config_dir
                    restart_singbox
                    allow_port $new_port/udp > /dev/null 2>&1
                    sed -i 's/\(hysteria2:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    base64 -w0 $client_dir > /etc/sing-box/sub.txt
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nhysteria2端口已修改为：${purple}${new_port}${re} ${green}请更新订阅或手动更改hysteria2端口${re}\n"
                    ;;
                3)
                    reading "\n请输入tuic端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    sed -i '/"type": "tuic"/,/listen_port/ s/"listen_port": [0-9]\+/"listen_port": '"$new_port"'/' $config_dir
                    restart_singbox
                    allow_port $new_port/udp > /dev/null 2>&1
                    sed -i 's/\(tuic:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    base64 -w0 $client_dir > /etc/sing-box/sub.txt
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\ntuic端口已修改为：${purple}${new_port}${re} ${green}请更新订阅或手动更改tuic端口${re}\n"
                    ;;
                4)  
                    reading "\n请输入vmess-argo端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    sed -i '/"type": "vmess"/,/listen_port/ s/"listen_port": [0-9]\+/"listen_port": '"$new_port"'/' $config_dir
                    allow_port $new_port/tcp > /dev/null 2>&1
                    if command_exists rc-service; then
                        if grep -q "localhost:" /etc/init.d/argo; then
                            sed -i 's/localhost:[0-9]\{1,\}/localhost:'"$new_port"'/' /etc/init.d/argo
                            get_quick_tunnel
                            change_argo_domain 
                        fi
                    else
                        if grep -q "localhost:" /etc/systemd/system/argo.service; then
                            sed -i 's/localhost:[0-9]\{1,\}/localhost:'"$new_port"'/' /etc/systemd/system/argo.service
                            get_quick_tunnel
                            change_argo_domain 
                        fi
                    fi

                    if [ -f /etc/sing-box/tunnel.yml ]; then
                        sed -i 's/localhost:[0-9]\{1,\}/localhost:'"$new_port"'/' /etc/sing-box/tunnel.yml
                        restart_argo
                    fi

                    if ([ -f /etc/systemd/system/argo.service ] && grep -q -- "--token" /etc/systemd/system/argo.service) || \
                       ([ -f /etc/init.d/argo ] && grep -q -- "--token" /etc/init.d/argo); then
                        yellow "请在cloudflared里也对应修改端口为：${purple}${new_port}${re}\n"
                    fi

                    restart_singbox
                    green "\nvmess-argo端口已修改为：${purple}${new_port}${re}\n"
                    ;;                    
                0)  change_config ;;
                *)  red "无效的选项，请输入 1 到 4" ;;
            esac
            ;;
        2)
            reading "\n请输入新的UUID: " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            sed -i -E '
                s/"uuid": "([a-f0-9-]+)"/"uuid": "'"$new_uuid"'"/g;
                s/"uuid": "([a-f0-9-]+)"$/\"uuid\": \"'$new_uuid'\"/g;
                s/"password": "([a-f0-9-]+)"/"password": "'"$new_uuid"'"/g
            ' $config_dir

            restart_singbox
            sed -i -E 's/(vless:\/\/|hysteria2:\/\/)[^@]*(@.*)/\1'"$new_uuid"'\2/' $client_dir
            sed -i "s/tuic:\/\/[0-9a-f\-]\{36\}/tuic:\/\/$new_uuid/" /etc/sing-box/url.txt
            isp=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')
            argodomain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${work_dir}/argo.log" | sed 's@https://@@')
            VMESS="{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"www.visa.com.tw\", \"port\": \"443\", \"id\": \"${new_uuid}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"\", \"allowlnsecure\": \"flase\"}"
            encoded_vmess=$(echo "$VMESS" | base64 -w0)
            sed -i -E '/vmess:\/\//{s@vmess://.*@vmess://'"$encoded_vmess"'@}' $client_dir
            base64 -w0 $client_dir > /etc/sing-box/sub.txt
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nUUID已修改为：${purple}${new_uuid}${re} ${green}请更新订阅或手动更改所有节点的UUID${re}\n"
            ;;
        3)  
            clear
            green "\n1. www.joom.com\n\n2. www.stengg.com\n\n3. www.wedgehr.com\n\n4. www.cerebrium.ai\n\n5. www.nazhumi.com\n"
            reading "\n请输入新的Reality伪装域名(回车使用默认1): " new_sni
    
            case "$new_sni" in
              "1"|"") new_sni="www.joom.com" ;;
              "2") new_sni="www.stengg.com" ;;
              "3") new_sni="www.wedgehr.com" ;;
              "4") new_sni="www.cerebrium.ai" ;;
              "5") new_sni="www.nazhumi.com" ;;
              *) new_sni="$new_sni" ;;
             esac
          conf_base_dir=$(dirname "$config_dir")
          # 替换 server_name 和 handshake server，使用 [ \t]* 兼容所有系统的空格匹配
          sed -i "s/\"server_name\":[ \t]*\"[^\"]*\"/\"server_name\": \"$new_sni\"/g" "${conf_base_dir}"/*.json
          sed -i "s/\"server\":[ \t]*\"[^\"]*\"/\"server\": \"$new_sni\"/g" "${conf_base_dir}"/*.json
          restart_singbox
          if [ -f "$client_dir" ]; then
            # 通用正则替换 sni 参数
            sed -i "s/sni=[^&]*/sni=$new_sni/g" "$client_dir"
            base64 "$client_dir" | tr -d '\n' > /etc/sing-box/sub.txt
          fi
          while IFS= read -r line; do yellow "$line"; done < "${work_dir}/url.txt"
          green "\nReality SNI 已修改为：${purple}${new_sni}${re}\n"
           ;;
        4)  
            purple "端口跳跃需确保跳跃区间的端口没有被占用，nat鸡请注意可用端口范围，否则可能造成节点不通\n"
            reading "请输入跳跃起始端口 (回车跳过将使用随机端口): " min_port
            [ -z "$min_port" ] && min_port=$(shuf -i 50000-65000 -n 1)
            yellow "你的起始端口为：$min_port"
            reading "\n请输入跳跃结束端口 (需大于起始端口): " max_port
            [ -z "$max_port" ] && max_port=$(($min_port + 100)) 
            yellow "你的结束端口为：$max_port\n"
            purple "正在安装依赖，并设置端口跳跃规则中，请稍等...\n"
            listen_port=$(sed -n '/"tag": "hysteria2"/,/}/s/.*"listen_port": \([0-9]*\).*/\1/p' $config_dir)
            iptables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            command -v ip6tables &> /dev/null && ip6tables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            if command_exists rc-service 2>/dev/null; then
                iptables-save > /etc/iptables/rules.v4
                command -v ip6tables &> /dev/null && ip6tables-save > /etc/iptables/rules.v6

                cat << 'EOF' > /etc/init.d/iptables
#!/sbin/openrc-run

depend() {
    need net
}

start() {
    [ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
    command -v ip6tables &> /dev/null && [ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6
}
EOF

                chmod +x /etc/init.d/iptables && rc-update add iptables default && /etc/init.d/iptables start
            elif [ -f /etc/debian_version ]; then
                DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent > /dev/null 2>&1 && netfilter-persistent save > /dev/null 2>&1 
                systemctl enable netfilter-persistent > /dev/null 2>&1 && systemctl start netfilter-persistent > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                manage_packages install iptables-services > /dev/null 2>&1 && service iptables save > /dev/null 2>&1
                systemctl enable iptables > /dev/null 2>&1 && systemctl start iptables > /dev/null 2>&1
                command -v ip6tables &> /dev/null && service ip6tables save > /dev/null 2>&1
                systemctl enable ip6tables > /dev/null 2>&1 && systemctl start ip6tables > /dev/null 2>&1
            else
                red "未知系统,请自行将跳跃端口转发到主端口" && exit 1
            fi            
            restart_singbox
            ip=$(get_realip)
            uuid=$(sed -n 's/.*hysteria2:\/\/\([^@]*\)@.*/\1/p' $client_dir)
            line_number=$(grep -n 'hysteria2://' $client_dir | cut -d':' -f1)
            isp=$(curl -s --max-time 2 https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g' || echo "vps")
            sed -i.bak "/hysteria2:/d" $client_dir
            sed -i "${line_number}i hysteria2://$uuid@$ip:$listen_port?peer=www.bing.com&insecure=1&alpn=h3&obfs=none&mport=$listen_port,$min_port-$max_port#$isp" $client_dir
            base64 -w0 $client_dir > /etc/sing-box/sub.txt
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nhysteria2端口跳跃已开启,跳跃端口为：${purple}$min_port-$max_port${re} ${green}请更新订阅或手动复制以上hysteria2节点${re}\n"
            ;;
        5)  
            iptables -t nat -F PREROUTING  > /dev/null 2>&1
            command -v ip6tables &> /dev/null && ip6tables -t nat -F PREROUTING  > /dev/null 2>&1
            if command_exists rc-service 2>/dev/null; then
                rc-update del iptables default && rm -rf /etc/init.d/iptables 
            elif [ -f /etc/redhat-release ]; then
                netfilter-persistent save > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                service iptables save > /dev/null 2>&1
                command -v ip6tables &> /dev/null && service ip6tables save > /dev/null 2>&1
            else
                manage_packages uninstall iptables ip6tables iptables-persistent iptables-service > /dev/null 2>&1
            fi
            sed -i '/hysteria2/s/&mport=[^#&]*//g' /etc/sing-box/url.txt
            base64 -w0 $client_dir > /etc/sing-box/sub.txt
            green "\n端口跳跃已删除\n"
            ;;
        6)  change_cfip ;;
        0)  menu ;;
        *)  read "无效的选项！" ;; 
    esac
}

disable_open_sub() {
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?
    
    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"
        sleep 1
        menu
        return
    fi

    clear
    echo ""
    green "=== 节点订阅管理 ===\n"
    skyblue "------------"
    green "1. 启动nginx"
    skyblue "------------"
	green "2. 停止gninx"
    skyblue "------------"
	green "3. 重启nginx"
    skyblue "------------"
    green "4. 关闭节点订阅"
    skyblue "------------"
    green "5. 开启节点订阅"
    skyblue "------------"
    green "6. 更换订阅端口"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
	    1)
            start_nginx
            green "Nginx 服务已启动"
            ;;
        2)
            stop_nginx
            yellow "Nginx 服务已停止"
            ;;
        3)
            restart_nginx
            green "Nginx 服务已重启"
            ;;
        4)
              if [ -f "/etc/nginx/conf.d/sing-box.conf" ]; then
                cp "/etc/nginx/conf.d/sing-box.conf" "/etc/nginx/conf.d/sing-box.conf.bak_$(date +%Y%m%d_%H%M%S)"
                rm -f "/etc/nginx/conf.d/sing-box.conf"
                if command_exists rc-service 2>/dev/null; then
                    rc-service nginx restart
                else 
                    systemctl restart nginx
                fi
                green "节点订阅已关闭"
            else
                yellow "未发现 /etc/nginx/conf.d/sing-box.conf 文件，无需操作"
            fi
            ;; 
        5)
                
            echo -e "\n\033[1;33m[系统排错] 正在寻找备份文件...\033[0m"
            bak_file=$(ls /etc/nginx/conf.d/sing-box.conf.bak* 2>/dev/null | sort -r | head -n 1)
            
            if [ -n "$bak_file" ] && [ -f "$bak_file" ]; then
                \cp -f "$bak_file" "/etc/nginx/conf.d/sing-box.conf"
    
                if [ -f "/etc/nginx/conf.d/sing-box.conf" ]; then
                    echo -e "\033[1;32m[系统排错] 恢复成功！原配置已就位。\033[0m"
                    # 清理多余的备份文件
                    rm -f /etc/nginx/conf.d/sing-box.conf.bak*
                else
                    echo -e "\033[1;91m[系统排错] 严重错误：复制命令已执行，但 sing-box.conf 依然不存在！请检查目录权限。\033[0m"
                    return 1
                fi
            else
                if [ ! -f "/etc/nginx/conf.d/sing-box.conf" ]; then
                    echo -e "\033[1;91m[系统排错] 致命错误：找不到备份文件，且原配置文件也不存在！\033[0m"
                    echo -e "\033[1;33m[系统排错] 当前 /etc/nginx/conf.d/ 目录下的内容如下：\033[0m"
                    ls -la /etc/nginx/conf.d/
                    return 1
                fi
            fi
            server_ip=$(get_realip)
            password=$(tr -dc A-Za-z < /dev/urandom | head -c 32) 
            sed -i "s|location = /[^ {]*|location = /$password|g" /etc/nginx/conf.d/sing-box.conf
            
            sub_port=$(grep -E 'listen [0-9]+;' "/etc/nginx/conf.d/sing-box.conf" | awk '{print $2}' | tr -d ';' | head -n 1)
            
            restart_nginx
            green "\n已开启节点订阅并重新生成链接"
            
            if [ "$sub_port" = "80" ] || [ -z "$sub_port" ]; then
                link="http://$server_ip/$password"
            else
                green "订阅端口：$sub_port"
                link="http://$server_ip:$sub_port/$password"
            fi
            green "新的节点订阅链接：$link\n"
            ;;

        6)
            reading "请输入新的订阅端口[1-65535]:" sub_port
            [ -z "$sub_port" ] && sub_port=$(shuf -i 2000-65000 -n 1)

			# 检查端口是否被占用
            while netstat -tunl | grep -q ":$sub_port "; do
               echo -e "${red}端口 $sub_port 已经被占用，请更换端口重试${re}"
               read -p "请输入新的订阅端口(1-65535，回车随机生成): " sub_port
               [[ -z $sub_port ]] && sub_port=$(shuf -i 2000-65000 -n 1)
            done


            # 备份当前配置
            if [ -f "/etc/nginx/conf.d/sing-box.conf" ]; then
                cp "/etc/nginx/conf.d/sing-box.conf" "/etc/nginx/conf.d/sing-box.conf.bak.$(date +%Y%m%d)"
            fi
            
            # 更新端口配置
            sed -i 's/listen [0-9]\+;/listen '$sub_port';/g' "/etc/nginx/conf.d/sing-box.conf"
            sed -i 's/listen \[::\]:[0-9]\+;/listen [::]:'$sub_port';/g' "/etc/nginx/conf.d/sing-box.conf"
            path=$(sed -n 's|.*location = /\([^ ]*\).*|\1|p' "/etc/nginx/conf.d/sing-box.conf")
            server_ip=$(get_realip)
            
            # 放行新端口
            allow_port $sub_port/tcp > /dev/null 2>&1
            
            # 测试nginx配置
            if nginx -t > /dev/null 2>&1; then
                # 尝试重新加载配置
                if nginx -s reload > /dev/null 2>&1; then
                    green "nginx配置已重新加载，端口更换成功"
                else
                    yellow "配置重新加载失败，尝试重启nginx服务..."
                    restart_nginx
                fi
                green "\n订阅端口更换成功\n"
                green "新的订阅链接为：http://$server_ip:$sub_port/$path\n"
            else
                red "nginx配置测试失败，正在恢复原有配置..."
                if [ -f "/etc/nginx/conf.d/sing-box.conf.bak."* ]; then
                    latest_backup=$(ls -t /etc/nginx/conf.d/sing-box.conf.bak.* | head -1)
                    cp "$latest_backup" "/etc/nginx/conf.d/sing-box.conf"
                    yellow "已恢复原有nginx配置"
                fi
                return 1
            fi
            ;; 
        0)  menu ;; 
        *)  red "无效的选项！" ;;
    esac
}



manage_nodes_menu() {
    while true; do
        local CONF_DIR="/etc/sing-box"
        local width=45
        local node_list=(
            "h2-reality.json|http-Reality|1"
            "grpc-reality.json|gRPC-Reality|2"
            "anytls.json|anytls|3"
            "socks5.json|Socks5|4"
            "http.json|HTTP|5"
			"vless-ws-cf.json|vless-ws-cf|6"
			"vless-ws-cdn.json|vless-ws-cdn|7"
        )

        clear
        yellow "============================================="
        echo -e "             添加删除节点               "
        yellow "============================================="
        echo -e "\e[1;34m[ 未添加节点 ]\033[0m"
        local has_unadded=false
        for item in "${node_list[@]}"; do
            local file=$(echo $item | cut -d'|' -f1)
            local name=$(echo $item | cut -d'|' -f2)
            local id=$(echo $item | cut -d'|' -f3)
            
            if [ ! -f "$CONF_DIR/$file" ]; then
                local left_text=" ${id}. ${name}节点"
                local right_text="(未添加) -> 输入 ${id} 开始配置"
                printf "%s%$(($width - ${#left_text}))s\n" "$left_text" "$(red "$right_text")"
                has_unadded=true
            fi
        done
        [ "$has_unadded" = false ] && echo -e " (所有节点已添加)"

        echo -e "\n============================================="
        echo -e "\e[1;32m[ 已添加节点 ]\033[0m"
        local has_added=false
        for item in "${node_list[@]}"; do
            local file=$(echo $item | cut -d'|' -f1)
            local name=$(echo $item | cut -d'|' -f2)
            local id=$(echo $item | cut -d'|' -f3)
            local del_id=$((id + 50))
            
            if [ -f "$CONF_DIR/$file" ]; then
                local left_text=" ${del_id}. ${name}节点"
                local right_text="(已添加) -> 输入 ${del_id} 删除节点"
                printf "%s%$(($width - ${#left_text}))s\n" "$left_text" "$(green "$right_text")"
                has_added=true
            fi
        done
        [ "$has_added" = false ] && echo -e " (当前无运行中节点)"

        yellow "============================================="
        echo -e " 0. 返回上一级菜单"
        echo -ne "\n"
        reading "请选择操作: " choice
		case "${choice}" in
        1) 
                generate_vars
                server_ip=$(curl -sS4 ip.sb || curl -sS4 ifconfig.me)                
                yellow "正在配置 H2 + Reality (端口: $h2_reality)..."
                cat > /etc/sing-box/h2-reality.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "h2-reality",
      "listen": "::",
      "listen_port": $h2_reality,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      },
      "transport": {
        "type": "http"
      },
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": 1000,
          "down_mbps": 1000
        }
      }
    }
  ]
}
EOF
                isp="H2-Reality-Node_h2_reality"
                url="vless://${uuid}@${server_ip}:${h2_reality}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=http#${isp}"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    grep -q "#${isp}$" "/etc/sing-box/url.txt" && sed -i "/#${isp}$/{N;d;}" "/etc/sing-box/url.txt"
                fi
                echo "$url" >> "/etc/sing-box/url.txt"
                echo "" >> "/etc/sing-box/url.txt"
                base64 -w0 "/etc/sing-box/url.txt" > "/etc/sing-box/sub.txt" 2>/dev/null
                restart_singbox 
                green "==============================================="
                green " H2 + Reality 节点已添加!"
                green " 节点链接: $url"
                green "==============================================="
                ;;
            2) yellow "正在配置 gRPC + Reality..."
            generate_vars
            server_ip=$(get_realip)
            mkdir -p /etc/sing-box
            cat > /etc/sing-box/grpc-reality.json << EOF
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"grpc-reality",
            "listen":"::",
            "listen_port":$grpc_reality,
            "users":[
                {
                    "uuid":"$uuid"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"www.iij.ad.jp",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"www.iij.ad.jp",
                        "server_port":443
                    },
                    "private_key": "$private_key",
                    "short_id": ["$short_id"]
                }
            },
            "transport":{
                "type": "grpc",
                "service_name": "grpc"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":true,
                    "up_mbps":200,
                    "down_mbps":200
                }
            }
        }
    ]
}
EOF

            isp="grpc-Reality-Node_grpc_reality"
            url="vless://${uuid}@${server_ip}:${grpc_reality}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=grpc&serviceName=grpc#${isp}"
            if [ -f "/etc/sing-box/url.txt" ]; then
                grep -q "#${isp}$" "/etc/sing-box/url.txt" && sed -i "/#${isp}$/{N;d;}" "/etc/sing-box/url.txt"
            fi
            echo "$url" >> "/etc/sing-box/url.txt"
            echo "" >> "/etc/sing-box/url.txt"
            base64 -w0 "/etc/sing-box/url.txt" > "/etc/sing-box/sub.txt" 2>/dev/null
            restart_singbox
            green "==============================================="
            green " VLESS-gRPC-Reality 节点已添加并重启!"
            green " 节点链接: $url"
            green "==============================================="
            ;;
            3) yellow "正在配置 anytls..."
               generate_vars
               server_ip=$(get_realip)
               mkdir -p /etc/sing-box
               cat > /etc/sing-box/anytls.json << EOF
{
    "inbounds":[
        {
            "type":"anytls",
            "tag":"anytls",
            "listen":"::",
            "listen_port":$anytls_port,
            "users":[
                {
                    "password":"$password"
                }
            ],
            "padding_scheme":[],
            "tls":{
                "enabled":true,
                "certificate_path": "$work_dir/cert.pem",
                "key_path": "$work_dir/private.key"
            }
        }
    ]
}
EOF
            isp="AnyTLS-Node_anytls"
            url="anytls://${password}@${server_ip}:${anytls_port}?sni=addons.mozilla.org&insecure=1#${isp}"
            if [ -f "/etc/sing-box/url.txt" ]; then
                grep -q "#${isp}$" "/etc/sing-box/url.txt" && sed -i "/#${isp}$/{N;d;}" "/etc/sing-box/url.txt"
            fi
            echo "$url" >> "/etc/sing-box/url.txt"
            echo "" >> "/etc/sing-box/url.txt"
            base64 -w0 "/etc/sing-box/url.txt" > "/etc/sing-box/sub.txt" 2>/dev/null
            restart_singbox
            green "==============================================="
            green " AnyTLS 节点已添加并重启!"
            green " 节点链接: $url"
            green "==============================================="
            ;;
            4) yellow "正在配置 Socks5..."
                generate_vars
                server_ip=$(get_realip)
                yellow "正在配置 Socks5 (端口: $socks_port)..."
                cat > /etc/sing-box/socks5.json << EOF
{
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "::",
      "listen_port": $socks_port,
      "users": [
        {
          "username": "$username",
          "password": "$password"
        }
      ]
    }
  ]
}
EOF
            isp="Socks5-Node_socks5"
                url="socks://${username}:${password}@${server_ip}:${socks_port}#${isp}"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    grep -q "#${isp}$" "/etc/sing-box/url.txt" && sed -i "/#${isp}$/{N;d;}" "/etc/sing-box/url.txt"
                fi
                echo "$url" >> /etc/sing-box/url.txt
                echo "" >> /etc/sing-box/url.txt
                base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                restart_singbox
                green "==============================================="
                green " Socks5 节点已添加!"
                green " 节点链接: $url"
                green "==============================================="
                ;;
            5) yellow "正在配置 HTTP...";;
			6) yellow "正在配置 vless-ws隧道..."
			generate_vars
            mkdir -p /etc/sing-box
            if [ -f "${work_dir}/argo.log" ]; then
                argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -n 1)
            fi

            # 2. 第二优先级：日志失效时，从 url.txt 的历史 VMess 节点中解码提取
            if [ -z "$argodomain" ] && [ -f "${work_dir}/url.txt" ]; then
                purple "正在获取cf隧道域名..."
                argodomain=$(grep "vmess://" "${work_dir}/url.txt" | while read -r line; do
                    decoded=$(echo "${line#vmess://}" | base64 -d 2>/dev/null)
                    echo "$decoded" | grep -oE '"host":\s*"[^"]+"' | cut -d'"' -f4 | grep "trycloudflare.com"
                done | head -n 1)
            fi

            # 3. 第三优先级：从现有的 VLESS/明文链接获取
            if [ -z "$argodomain" ] && [ -f "${work_dir}/url.txt" ]; then
                argodomain=$(grep "trycloudflare.com" "${work_dir}/url.txt" | grep -oE "(sni|host)=[^&]+" | head -n 1 | cut -d'=' -f2)
            fi

            # 4. 报错退出机制
            if [ -z "$argodomain" ]; then
                red "======================================================"
                red " 错误：无法获取 Argo 域名！"
                red " 请检查：1. argo.log 是否存在； 2. url.txt 是否有旧节点。"
                red " 为了系统安全，程序已停止，未生成新的隧道域名。"
                red "======================================================"
                break # 在菜单循环中使用 break 而不是 return
            fi

            # 5. 生成配置文件 (关键步骤)
            cat > /etc/sing-box/vless-ws-cf.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "127.0.0.1",
      "listen_port": 8003,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/lPaxe1996Ko-5203aap",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF
        isp_base=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || echo "Argo-Node")
        node_remark="${isp_base}_vless_ws_cf"
        VLESS_URL="vless://${uuid}@cf.877774.xyz:443?encryption=none&security=tls&sni=${argodomain}&type=ws&host=${argodomain}&path=%2FlPaxe1996Ko-5203aap%3Fed%3D2560#${node_remark}"
        if [ -f "${work_dir}/url.txt" ]; then
            grep -q "#${node_remark}$" "${work_dir}/url.txt" && sed -i "/#${node_remark}$/{N;d;}" "${work_dir}/url.txt"
        fi
        echo "$VLESS_URL" >> "${work_dir}/url.txt"
        echo "" >> "${work_dir}/url.txt"
        base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt"
        restart_singbox

        green "==============================================="
        green " VLESS-WS隧道 添加完成！"
        green " 节点链接: $VLESS_URL"
        green "==============================================="
        ;;
		7) 
		    generate_vars
            mkdir -p /etc/sing-box
            yellow "正在启动自动证书申请流程..."
            yellow "注意：申请前请务必在 Cloudflare 后台关闭域名代理模式，改为 [仅限 DNS]！"
            read -p "确认已关闭小黄云并继续？(y/n): " confirm
            [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return 1
             # 1. 环境预检 (自动安装 cron 和放行防火墙)
            green "正在优化系统环境..."
            if [ -f /usr/bin/apt ]; then
                apt update && apt install curl socat cron -y
                ufw allow 80/tcp >/dev/null 2>&1
            elif [ -f /usr/bin/yum ]; then
                yum install curl socat crontabs -y
                firewall-cmd --add-port=80/tcp --permanent >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
            fi
            systemctl enable --now cron >/dev/null 2>&1

            # 2. 安装 acme.sh 并强制切换到更稳定的 Let's Encrypt
            if [ ! -f ~/.acme.sh/acme.sh ]; then
                curl https://get.acme.sh | sh -s email=my@example.com
                ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            fi

            read -p "请输入域名: " domain
            [ -z "$domain" ] && red "域名不能为空!" && return 1

            # 3. 强力释放 80 端口 (防止 Nginx 没关干净)
            if systemctl is-active --quiet nginx; then
                systemctl stop nginx
            fi
            # 这一行是保险：杀死任何依然占用 80 的进程
            fuser -k 80/tcp >/dev/null 2>&1 

            # 4. 申请证书
            green "正在向 Let's Encrypt 申请证书，通常只需 10-30 秒..."
            ~/.acme.sh/acme.sh --issue --standalone -d "$domain" --keylength ec-256 --force
            
            if [ $? -ne 0 ]; then
                red "申请失败！请检查：1. 域名是否关闭了小黄云 2. 解析是否生效。"
                systemctl start nginx >/dev/null 2>&1
                return 1
            fi

            # 5. 自动配置与恢复
            ssl_dir="/etc/sing-box/ssl"
            mkdir -p "$ssl_dir"
            ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
                --fullchain-file "${ssl_dir}/${domain}.pem" \
                --key-file "${ssl_dir}/${domain}.key"

            systemctl start nginx >/dev/null 2>&1


            # 6. 无论成功与否，尝试恢复 Nginx 运行
            if [ "$need_start_nginx" = true ]; then
                yellow "恢复 Nginx 运行..."
                systemctl start nginx
            fi

            # 7. 判断申请结果并配置
            if [ $acme_ret -ne 0 ]; then
                red "证书申请失败！可能原因：1.小黄云未关 2.域名未解析到此IP 3.80端口仍被占用"
                return 1
            fi

            # 定义路径并安装证书
            ssl_dir="/etc/sing-box/ssl"
            mkdir -p "$ssl_dir"
            cert_path="${ssl_dir}/${domain}.pem"
            key_path="${ssl_dir}/${domain}.key"

            ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
                --fullchain-file "$cert_path" \
                --key-file "$key_path"

            # 8. 生成 vless-ws-cdn.json 配置
            generate_vars # 确保变量 uuid 和 vless_ws_cdn_port 已生成
            cat > /etc/sing-box/vless-ws-cdn.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-cdn",
      "listen": "::",
      "listen_port": $vless_ws_cdn_port,
      "users": [ { "uuid": "$uuid" } ],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      },
      "transport": {
        "type": "ws",
        "path": "/sspaasksavxssaszass",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF
            # 生成节点链接并更新订阅 (保持你原有的逻辑)
            isp="VLESS-WS-CDN"
            url="vless://${uuid}@${domain}:${vless_ws_cdn_port}?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=%2Fsspaasksavxssaszass#${isp}"
            echo "$url" >> "/etc/sing-box/url.txt"
            base64 -w0 "/etc/sing-box/url.txt" > "/etc/sing-box/sub.txt" 2>/dev/null
            
            restart_singbox
            green "==============================================="
            green " 证书申请并配置完成！"
            green " 域名: $domain"
            green " 注意：现在可以回到 CF 后台重新开启小黄云了。"
            green "==============================================="
            ;;


        
  
      
            # --- 完整的删除逻辑 ---
            51) 
                isp="H2-Reality-Node_h2_reality"
                if [ -f "$CONF_DIR/h2-reality.json" ]; then
                    rm -f "$CONF_DIR/h2-reality.json"
                    [ -f "/etc/sing-box/url.txt" ] && sed -i "/#${isp}$/{N;d;}" /etc/sing-box/url.txt
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                    restart_singbox
                    green "已删除"
                else
                    red "文件不存在"
                fi
                ;;
            52)
            isp="grpc-Reality-Node_grpc_reality"
            target_conf="/etc/sing-box/grpc_reality.json"

            if [ -f "$target_conf" ]; then
                rm -f "$target_conf"
                [ -f "/etc/sing-box/url.txt" ] && sed -i "/#${isp}$/{N;d;}" /etc/sing-box/url.txt
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox
                
                green "==============================================="
                green " VLESS-gRPC-Reality 已删除!"
                green "==============================================="
            else
                red "错误: 未找到该节点配置文件 ($target_conf)"
            fi
            ;;
            53)
                isp="AnyTLS-Node_anytls"
                if [ -f "/etc/sing-box/anytls.json" ]; then
                    rm -f "/etc/sing-box/anytls.json"
                    [ -f "/etc/sing-box/url.txt" ] && sed -i "/#${isp}$/{N;d;}" /etc/sing-box/url.txt
                    if [ -s "/etc/sing-box/url.txt" ]; then
                        base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                    else
                        truncate -s 0 /etc/sing-box/sub.txt
                    fi
                    restart_singbox
                    green "==============================================="
                    green " AnyTLS已删除!"
                    green "==============================================="
                else
                    red "错误: 未找到 AnyTLS 配置文件 (/etc/sing-box/anytls.json)"
                fi
                ;;
            54)
                isp="Socks5-Node_socks5"
                if [ -f "$CONF_DIR/socks5.json" ]; then
                    rm -f "$CONF_DIR/socks5.json"
                    [ -f "/etc/sing-box/url.txt" ] && sed -i "/#${isp}$/{N;d;}" /etc/sing-box/url.txt
                    if [ -s "/etc/sing-box/url.txt" ]; then
                        base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                    else
                        truncate -s 0 /etc/sing-box/sub.txt
                    fi
                    restart_singbox
                    green "已删除"
                else
                    red "文件不存在"
                fi
                ;;
            55)
                if [ -f "$CONF_DIR/http.json" ]; then
                    rm -f "$CONF_DIR/http.json"
                    green "HTTP 配置已移除"
                    restart_singbox
                else
                    red "文件不存在"
                fi
                ;;
		     56) 
                if [ -f "$CONF_DIR/vless-ws-cf.json" ]; then
                    rm -f "$CONF_DIR/vless-ws-cf.json"
                    
                    if [ -f "/etc/sing-box/url.txt" ]; then
                        sed -i "/_vless_ws_cf$/{N;d;}" /etc/sing-box/url.txt
                    fi
                    if [ -s "/etc/sing-box/url.txt" ]; then
                        base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                    else
                        truncate -s 0 /etc/sing-box/sub.txt
                    fi            
                    restart_singbox
                    green "==============================================="
                    green " VLESS-WS 隧道配置及节点已成功删除！"
                    green "==============================================="
                else
                    red "未发现 VLESS-WS 配置文件，无需删除。"
                fi
                ;;
				57) 
            isp="VLESS-WS-CDN-Node_vless_ws_cdn"
            if [ -f "/etc/sing-box/vless-ws-cdn.json" ]; then
                rm -f "/etc/sing-box/vless-ws-cdn.json"
                [ -f "/etc/sing-box/url.txt" ] && sed -i "/#${isp}$/{N;d;}" /etc/sing-box/url.txt
                base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                restart_singbox
                green "VLESS-WS-CDN 节点已删除"
            else
                red "文件不存在"
            fi
            ;;
		
            0) break ;;
            *) red "无效选项"; sleep 1; continue ;;
        esac
        
        echo -e "\n按任意键返回菜单..."
        read -n 1
    done
}


# 一键开启 BBR2 + FQ 加速
enable_bbr() {
    clear
    # 1. 检查是否已经安装并开启
    local current_control=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    
    if [[ "$current_control" == "bbr" || "$current_control" == "bbr2" ]]; then
        green "==============================================="
        green " 检测到系统已开启 BBR 加速!"
        green " 当前算法: $current_control"
        green " 无需重复安装。"
        green "==============================================="
        return 0
    fi

    yellow "正在检测系统环境并配置 BBR 加速..."

    # 2. 自动识别并安装缺失依赖
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y procps ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y procps ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache procps ca-certificates
    fi

    # 3. 策略选择 (优先 bbr2)
    local strategy="bbr"
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr2"; then
        strategy="bbr2"
    fi

    cat > /etc/sysctl.d/99-bbr.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $strategy
EOF

    sysctl --system > /dev/null 2>&1

    # 6. 最终验证
    local final_control=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$final_control" == "bbr" || "$final_control" == "bbr2" ]]; then
        green "==============================================="
        green " 成功！BBR 加速已开启。"
        green " 当前算法: $final_control"
        green "==============================================="
    else
        red "开启失败，请检查内核版本是否支持 BBR。"
    fi
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
    while IFS= read -r line; do purple "${purple}$line"; done < ${work_dir}/url.txt
    server_ip=$(get_realip)
    lujing=$(sed -n 's|.*location = /\([^ ]*\).*|\1|p' "/etc/nginx/conf.d/sing-box.conf")
    sub_port=$(sed -n 's/^\s*listen \([0-9]\+\);/\1/p' "/etc/nginx/conf.d/sing-box.conf")
    base64_url="http://${server_ip}:${sub_port}/${lujing}"
	green "V2rayN,Shadowrocket,Nekobox,Loon,Karing,Sterisand订阅链接: ${purple}${base64_url}${re}\n"
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
   green "YouTube频道: ${purple}https://youtube.com/@eooce${re}"
   green "Github地址: ${purple}https://github.com/eooce/sing-box${re}\n"
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
   green  "10. 开启BBR加速"
   echo  "==============="
   purple "11. ssh综合工具箱"
   echo  "==============="
   red "0. 退出脚本"
   echo "==========="
   reading "请输入选择(0-11): " choice
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
        11) 
           clear
           bash <(curl -Ls ssh_tool.eooce.com)
           ;;           
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 10" ;;
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
done
