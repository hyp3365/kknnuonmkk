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

# 用于存放已分配端口的数组
declare -A used_ports
get_available_port() {
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        if [ -n "${used_ports[$port]}" ]; then
            continue
        fi
        if command -v ss >/dev/null 2>&1; then
            if ss -tuln | grep -qE ":$port\b"; then
                continue
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tuln | grep -qE ":$port\b"; then
                continue
            fi
        fi
        used_ports[$port]=1
        echo "$port"
        break
    done
}

# 自动检测并安装 nftables
check_and_install_nftables() {
    if ! command -v nft &> /dev/null; then
        echo -e "\033[0;33m[!] 检测到系统未安装 nftables，正在自动安装...\033[0m"
        if [ -f /etc/debian_version ]; then
            apt-get update -y && apt-get install -y nftables
        elif [ -f /etc/redhat-release ]; then
            yum install -y nftables 2>/dev/null || dnf install -y nftables
        else
            echo -e "\033[0;31m[-] 未知的 Linux 系统类型，请手动安装 nftables！\033[0m"
            return 1
        fi
        
        systemctl enable nftables >/dev/null 2>&1
        systemctl start nftables >/dev/null 2>&1
        echo -e "\033[0;32m[+] nftables 自动安装完成！\033[0m"
        sleep 1
    fi
}


# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
config_dir="${conf_dir}/config.json"
client_dir="${work_dir}/url.txt"
export CFIP=${CFIP:-'cf.877774.xyz'} 
export CFPORT=${CFPORT:-'443'} 
uuid=$(cat /proc/sys/kernel/random/uuid)
nginx_port=$(get_available_port)
tuic_port=$(get_available_port)
socks_port=$(get_available_port)
http_port=$(get_available_port)
anytls_port=$(get_available_port)
xtls_reality=$(get_available_port)
h2_reality=$(get_available_port)
hy2_port=$(get_available_port)
grpc_reality=$(get_available_port)
vless_wstls_cdn_port=$(get_available_port)
vless_ws_cdn_port=$(get_available_port)
vmess_ws_cdn_port=$(get_available_port)
username=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 15)
password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)

to_chinese() {
    local clean_status=$(echo "$1" | sed 's/\x1b\[[0-9;]*m//g')
    [ -z "$clean_status" ] && clean_status="unknown" 
    case "$clean_status" in
        "running")       echo -e "\033[1;32m运行中\033[0m" ;;
        "not running")   echo -e "\033[1;33m未运行\033[0m" ;;
        "not installed") echo -e "\033[1;31m未安装\033[0m" ;;
        *)               echo -e "\033[0;37m$clean_status\033[0m" ;;
    esac
}

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

# 根据系统类型安装、卸载依赖
manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    action=$1
    shift

    # 首次安装更新系统
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在更新系统软件包...\n"
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y && DEBIAN_FRONTEND=noninteractive apt upgrade -y
        elif command_exists dnf; then
            dnf update -y
        elif command_exists yum; then
            yum update -y
        elif command_exists apk; then
            apk update && apk upgrade
        else
            yellow "Unknown system!\n"
        fi
        green "finished updated system\n"
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk add "$package"
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
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
    ip=$(curl -4 -sL -m 3 ip.sb)
    ipv6() { curl -6 -sL -m 3 ip.sb; }

    if [ -z "$ip" ]; then
        echo "[$(ipv6)]"
    elif curl -4 -sL -m 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        v6=$(ipv6)
        if [ -n "$v6" ]; then
            echo "[$v6]"
        else
            echo "$ip"
        fi
    else
        echo "$ip"
    fi
}
ip_address() {
    ipv4_address=$(curl -s -m 2 ipv4.ip.sb)
    ipv6_address=$(curl -s -m 2 ipv6.ip.sb)
}

# 80 端口申请模式
run_ssl_task() {
    local domain="$1"
    [[ -z "$domain" ]] && reading "请输入域名: " domain
    [[ -z "$domain" ]] && red "域名不能为空" && return 1
    
    manage_packages "install" "curl" "socat" "cron" "psmisc"
    mkdir -p "$HOME/.acme.sh"
    cat << 'EOF' > "$HOME/.acme.sh/release_80.sh"
#!/bin/bash
if command -v ss >/dev/null 2>&1; then
    pid=$(ss -tulpn 'sport = :80' | grep -o 'pid=[0-9]*' | cut -d'=' -f2 | head -n1)
    occupant=$(ss -tulpn 'sport = :80' | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | head -n1)
    if [[ -n "$pid" || -n "$occupant" ]]; then
        if [[ -n "$occupant" ]] && systemctl is-active --quiet "$occupant" 2>/dev/null; then
            systemctl stop "$occupant" >/dev/null 2>&1
            echo "$occupant" > "$HOME/.acme.sh/last_80_occupant.txt"
            sleep 1
        fi
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" >/dev/null 2>&1
            sleep 1
        fi
        if command -v fuser >/dev/null 2>&1; then
            fuser -k -9 80/tcp >/dev/null 2>&1
            sleep 1
        fi
    fi
fi
EOF
    chmod +x "$HOME/.acme.sh/release_80.sh"

    cat << 'EOF' > "$HOME/.acme.sh/restore_80.sh"
#!/bin/bash
if [[ -f "$HOME/.acme.sh/last_80_occupant.txt" ]]; then
    occupant=$(cat "$HOME/.acme.sh/last_80_occupant.txt")
    if [[ -n "$occupant" ]]; then
        systemctl start "$occupant" >/dev/null 2>&1
    fi
    rm -f "$HOME/.acme.sh/last_80_occupant.txt"
fi
EOF
    chmod +x "$HOME/.acme.sh/restore_80.sh"
    if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
        skyblue "正在安装 acme.sh..."
        curl -s https://get.acme.sh | sh -s email="cert_${RANDOM}@gmail.com"
        if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
            manage_packages "install" "git"
            git clone https://gitee.com/neilpang/acme.sh.git "$HOME/acme_git_tmp" >/dev/null 2>&1
            if [[ -d "$HOME/acme_git_tmp" ]]; then
                cd "$HOME/acme_git_tmp" && ./acme.sh --install -m "cert_${RANDOM}@gmail.com" >/dev/null 2>&1
                cd - >/dev/null && rm -rf "$HOME/acme_git_tmp"
            fi
        fi
    fi

    if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
        red "错误: acme.sh 安装失败！"
        return 1
    fi

    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1    
    local save_path="/root/cert/${domain}"
    mkdir -p "$save_path"    

    skyblue "正在为 ${domain} 申请证书..."
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone --httpport 80 --force \
        --pre-hook "$HOME/.acme.sh/release_80.sh" \
        --post-hook "$HOME/.acme.sh/restore_80.sh"
        
    if [ $? -eq 0 ]; then
        "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" \
            --key-file "${save_path}/privkey.pem" \
            --fullchain-file "${save_path}/fullchain.pem"
      
        chmod 600 "${save_path}/privkey.pem"
        cert_file="${save_path}/fullchain.pem"
        key_file="${save_path}/privkey.pem"
        green "申请成功！"
        green "证书: ${cert_file}"
        green "私钥: ${key_file}"      
        "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1
    else
        red "申请失败，请手动排查 80 端口或域名解析状态！"
        return 1
    fi
}


# Cloudflare DNS API 模式申请证书函数
issue_cf_dns_cert() {
    if [[ -z "$domain" ]]; then
        reading "请输入域名 (支持通配符如 *.example.com): " domain
    fi
    [[ -z "$domain" ]] && red "域名不能为空" && return 1    
    reading "请输入 Cloudflare 登录邮箱: " cf_email
    [[ -z "$cf_email" ]] && red "邮箱不能为空" && return 1    
    reading "请输入 Cloudflare Global API Key: " cf_key
    [[ -z "$cf_key" ]] && red "API Key 不能为空" && return 1      
    export CF_Email=$(echo "$cf_email" | tr -d '[:space:]')
    export CF_Key=$(echo "$cf_key" | tr -d '[:space:]')      
    manage_packages "install" "curl" "socat" "cron" "psmisc"     
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        skyblue "正在安装 acme.sh..."
        curl https://get.acme.sh | sh -s email="$CF_Email" >/dev/null 2>&1
    fi      
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1      
    local save_path="/root/cert/${domain}"
    mkdir -p "$save_path"  
    skyblue "正在通过 DNS API 为 ${domain} 申请证书..."
    "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$domain" --keylength ec-256 --force   
    if [ $? -eq 0 ]; then
        "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" --ecc \
            --key-file "${save_path}/privkey.pem" \
            --fullchain-file "${save_path}/fullchain.pem"                
        chmod 600 "${save_path}/privkey.pem"
        cert_file="${save_path}/fullchain.pem"
        key_file="${save_path}/privkey.pem"        
        green "申请成功！"
        green "证书: ${cert_file}"
        green "私钥: ${key_file}"      
        "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1
    else
        red "申请失败，请检查 CF 邮箱/Key 是否正确，或 API 频率限制。"
        return 1
    fi
}

# 综合证书检查与申请 调用check_and_issue_ssl || return 1
check_and_issue_ssl() {
    local input_domain="$1"
    [[ -z "$input_domain" ]] && reading "请输入域名: " input_domain
    [[ -z "$input_domain" ]] && red "域名不能为空!" && return 1  
    domain="$input_domain"
    cert_file="/root/cert/${domain}/fullchain.pem"
    key_file="/root/cert/${domain}/privkey.pem"

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        skyblue "检测到域名 ${domain} 的证书已存在，直接使用。"
        return 0
    fi
    if [[ "$domain" == *.*.* ]]; then
        local parent_domain=$(echo "$domain" | cut -d'.' -f2-)
        local p_cert="/root/cert/${parent_domain}/fullchain.pem"
        local p_key="/root/cert/${parent_domain}/privkey.pem"

        if [[ -f "$p_cert" && -f "$p_key" ]]; then
            yellow "当前域名无证书，但检测到父域名 ${parent_domain} 已有证书。"
            reading "是否直接使用父域名证书？(y/n): " use_parent
            if [[ "$use_parent" == "y" ]]; then
                cert_file="$p_cert"
                key_file="$p_key"
                green "已选择使用 ${parent_domain} 的证书。"
                return 0
            fi
        fi
    fi
    echo -e "未检测到可用证书，请选择申请方式"
	echo -e "通过80端口申请 确保域名已解析到服务器并且已关闭代理模式"
    echo -e "1) 通过 80 端口申请 "
    echo -e "2) 通过 Cloudflare DNS API"
    reading "请输入选择 [1-2]: " ssl_choice

    case "$ssl_choice" in
        1) run_ssl_task "$domain" ;;
        2) issue_cf_dns_cert "$domain" ;;
        *) red "无效选择"; return 1 ;;
    esac
    if [[ $? -eq 0 && -f "$cert_file" ]]; then
        green "证书申请成功并已就绪！"
        return 0
    else
        red "证书申请失败，请检查日志。"
        return 1
    fi
}

# 处理防火墙
allow_port() {
    local has_ufw=0
    local has_firewalld=0
    local has_nft=0

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists nft && has_nft=1

    # 出站和基础规则
    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --zone=public --set-target=ACCEPT >/dev/null 2>&1
    
    # 初始化 nftables 原生基础表和链（如果不存在）
    if [ "$has_nft" -eq 1 ]; then
        if ! nft list table inet filter &>/dev/null; then
            nft add table inet filter
            nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
            nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'
            nft add chain inet filter output '{ type filter hook output priority 0; policy accept; }'
        fi
        # 放行本地回环和 ICMP (Ping)
        nft add rule inet filter input iif "lo" accept 2>/dev/null
        nft add rule inet filter input ip protocol icmp accept 2>/dev/null
        nft add rule inet filter input ip6 nexthdr icmpv6 accept 2>/dev/null
    fi

    # 入站规则处理
    for rule in "$@"; do
        local port=${rule%/*}
        local proto=${rule#*/}
        # 如果传入的参数没有包含协议(例如直接传入 80 而不是 80/tcp)，则默认使用 tcp
        [ "$port" == "$proto" ] && proto="tcp"

        [ "$has_ufw" -eq 1 ] && ufw allow in ${port}/${proto} >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        
        # 原生 nftables 内存规则写入 (inet 自动双栈生效)
        if [ "$has_nft" -eq 1 ]; then
            # 避免重复添加规则
            if ! nft list chain inet filter input 2>/dev/null | grep -qw "$proto dport $port"; then
                nft add rule inet filter input $proto dport $port accept comment "ScriptManaged" 2>/dev/null
            fi
        fi
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1

    # 规则持久化：直接导出当前原生规则覆盖配置文件
    if [ "$has_nft" -eq 1 ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null
    fi
}

# 批量关闭端口 (完全适配原生 nftables)
close_port() {
    local has_nft=0
    command_exists nft && has_nft=1
    
    for rule in "$@"; do
        local port=${rule%/*}
        
        if [ "$has_nft" -eq 1 ]; then
            # 在原生 nftables 中，删除规则最安全的方式是获取 handle 句柄并删除
            # 通过 awk 提取匹配该端口规则的 handle 值
            for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$port" '$0~"dport "p {print $NF}'); do
                nft delete rule inet filter input handle $handle 2>/dev/null
            done
        fi
    done
    
    # 删除完毕后，将新的规则状态持久化到文件
    if [ "$has_nft" -eq 1 ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null
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
    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}" && mkdir -p "${conf_dir}"
    # 下载sing-box,cloudflared
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
    
    # 放行端口
    allow_port $nginx_port/tcp $tuic_port/udp > /dev/null 2>&1

    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
    
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')
    
    dns_strategy=$(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || \
        (ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))
    
   # 生成配置文件
cat > "${config_dir}" << EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "local",
        "type": "local"
      }
    ],
    "strategy": "$dns_strategy"
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
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf/
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
    local remote_url="http://sb.133134.xyz"
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
command_args="run -C /etc/sing-box/conf"
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
# sing-box 订阅配置
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

    # 禁止访问隐藏文件
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    # 检查主配置文件是否存在
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
       

# === Argo 域名自动更新监控函数 ===
install_argo_watchdog() {
    if [ -f /etc/os-release ]; then
        local os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        if [[ "$os_id" != "ubuntu" && "$os_id" != "debian" ]]; then
            return 1
        fi
    else
        return 1
    fi
    local work_dir="/etc/sing-box"
    local log_file="${work_dir}/argo.log"
    local url_file="${work_dir}/url.txt"
    local sub_file="${work_dir}/sub.txt"

    cat > ${work_dir}/argo_watchdog.sh <<EOF
#!/bin/bash
touch "${log_file}"
touch "${sub_file}"
tail -F "${log_file}" | grep --line-buffered -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' | while read -r FULL_URL
do
    ARGODOMAIN=\$(echo "\$FULL_URL" | sed 's|https://||')
    if [ -s "${url_file}" ]; then
        TMP_FILE=\$(mktemp)
        while IFS= read -r line || [ -n "\$line" ]; do
            if [[ "\$line" == vmess://* ]]; then
                CONTENT=\$(echo "\$line" | sed 's/vmess:\/\///' | base64 -d 2>/dev/null)
                if echo "\$CONTENT" | jq -r '.ps' | grep -qi "argo"; then
                    NEW_JSON=\$(echo "\$CONTENT" | jq --arg dom "\$ARGODOMAIN" '.host = \$dom | .sni = \$dom')
                    echo "vmess://\$(echo "\$NEW_JSON" | base64 -w0)" >> "\$TMP_FILE"
                else
                    echo "\$line" >> "\$TMP_FILE"
                fi
            else
                echo "\$line" >> "\$TMP_FILE"
            fi
        done < "${url_file}"
        mv "\$TMP_FILE" "${url_file}"
        if [ -f "${sub_file}" ]; then
            base64 -w0 "${url_file}" > "${sub_file}"
        fi
    fi
done
EOF

    chmod +x ${work_dir}/argo_watchdog.sh

    cat > /etc/systemd/system/argo-watchdog.service <<EOF
[Unit]
Description=Argo Watchdog
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash ${work_dir}/argo_watchdog.sh
Restart=always
RestartSec=10
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable argo-watchdog
    systemctl restart argo-watchdog
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
		        # 停止 sing-box、argo 和 监控脚本
                systemctl stop "${server_name}"
                systemctl stop argo
                systemctl stop argo-watchdog &>/dev/null
				
                systemctl disable "${server_name}"
                systemctl disable argo
                systemctl disable argo-watchdog &>/dev/null

                # 重新加载 systemd
                systemctl daemon-reload || true

            fi
           # 删除配置文件和日志
           rm -rf "${work_dir}" || true
           rm -rf "${log_dir}" || true
           rm -rf /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service /etc/systemd/system/argo-watchdog.service > /dev/null 2>&1
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
    green "1. 修改Reality伪装域名"
    skyblue "------------"
    green "2. 添加hysteria2端口跳跃"
    skyblue "------------"
    green "3. 删除hysteria2端口跳跃"
    skyblue "------------"
	green "4. hysteria2开启混淆"
    skyblue "------------"
    green "5. hysteria2关闭混淆"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)  
		  clear
          green "\n1. www.joom.com\n\n2. www.stengg.com\n\n3. www.wedgehr.com\n\n4. www.cerebrium.ai\n\n5. www.nazhumi.com\n\n6. 自定义域名\n"
          reading "\n请输入新的Reality伪装域名序号(回车使用默认1): " new_sni
  
          case "$new_sni" in
            "1"|"") new_sni="www.joom.com" ;;
            "2") new_sni="www.stengg.com" ;;
            "3") new_sni="www.wedgehr.com" ;;
            "4") new_sni="www.cerebrium.ai" ;;
            "5") new_sni="www.nazhumi.com" ;;
            "6")
              reading "\n请输入自定义的伪装域名(例如 www.example.com): " new_sni
              [[ -z "$new_sni" ]] && new_sni="www.joom.com"
              ;;
            *) new_sni="$new_sni" ;;
           esac
           
          conf_base_dir=$(dirname "$config_dir")
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
        2) 
		    generate_vars
            purple "端口跳跃需确保跳跃区间的端口没有被占用，NAT机请注意可用端口范围。\n"
            local check_cmds=("nft" "curl" "shuf" "python3")
            local install_pkgs=("nftables" "curl" "coreutils" "python3")
            
            for i in "${!check_cmds[@]}"; do
                if ! command -v "${check_cmds[$i]}" &> /dev/null; then
                    yellow "检测到缺少依赖 ${install_pkgs[$i]}，正在安装..."
                    if [ -f /etc/debian_version ]; then
                        apt-get update && apt-get install -y "${install_pkgs[$i]}"
                    elif [ -f /etc/redhat-release ]; then
                        yum install -y "${install_pkgs[$i]}"
                    fi
                fi
            done
            
            reading "请输入跳跃起始端口: " min_port
            while [ -z "$min_port" ]; do
                red "不能为空，请重新输入: "
                read min_port
            done
            yellow "起始端口为：$min_port"
            reading "请输入跳跃结束端口 (需大于起始端口，回车默认+100): " max_port
            [ -z "$max_port" ] && max_port=$(($min_port + 100)) 
            yellow "结束端口为：$max_port\n"
            
            listen_port=$(grep '"listen_port"' /etc/sing-box/conf/hysteria2.json | head -n 1 | awk -F': ' '{print $2}' | tr -d ', "')
            if [ -z "$listen_port" ]; then
                red "无法自动获取 Hysteria2 监听端口，请检查配置文件！"
                exit 1
            fi
            
            purple "正在设置端口跳跃规则..."
            
            sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
            [ -f /proc/sys/net/ipv6/conf/all/forwarding ] && sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
            
            nft add table ip nat 2>/dev/null
            nft 'add chain ip nat prerouting { type nat hook prerouting priority -100; policy accept; }' 2>/dev/null
            nft add rule ip nat prerouting udp dport $min_port-$max_port dnat to :$listen_port comment "Hysteria2_Hop" 2>/dev/null

            if [ -f /proc/net/if_inet6 ]; then
                nft add table ip6 nat 2>/dev/null
                nft 'add chain ip6 nat prerouting { type nat hook prerouting priority -100; policy accept; }' 2>/dev/null
                nft add rule ip6 nat prerouting udp dport $min_port-$max_port dnat to :$listen_port comment "Hysteria2_Hop" 2>/dev/null
            fi
            
            nft list ruleset > /etc/nftables.conf
            
            if command -v systemctl &> /dev/null; then
                systemctl enable nftables >/dev/null 2>&1
                systemctl start nftables >/dev/null 2>&1
            elif command -v rc-service &> /dev/null; then
                rc-update add nftables default 2>/dev/null
            fi

            restart_singbox
            ip=$(get_realip)
            uuid=$(grep -oP 'hysteria2://\K[^@]+' "$client_dir" | head -n 1)
            sed -i "/hysteria2:/d" "$client_dir"
            key_path=$(grep '"key_path"' /etc/sing-box/conf/hysteria2.json | head -n 1 | sed -E 's/.*"key_path"\s*:\s*"([^"]+)".*/\1/')
            if [[ "$key_path" =~ \/root\/cert\/([^\/]+)\/ ]]; then
                custom_sni="${BASH_REMATCH[1]}"
                url_param="sni=${custom_sni}"
            else
                custom_sni="www.bing.com"
                url_param="sni=www.bing.com&insecure=1"
            fi
            node_remark="${isp}_hysteria2"
            sed -i "/hysteria2:/d" "$client_dir"
            obfs_param="obfs=none"
            if [ -f "/etc/sing-box/conf/hysteria2.json" ]; then
                obfs_info=$(python3 -c "
import json
try:
    with open('/etc/sing-box/conf/hysteria2.json', 'r', encoding='utf-8') as f:
        data = json.load(f)
    obfs = {}
    if isinstance(data, dict):
        if 'inbounds' in data:
            for ib in data['inbounds']:
                if ib.get('type') == 'hysteria2':
                    obfs = ib.get('obfs', {})
        else:
            obfs = data.get('obfs', {})
    
    if obfs.get('type') == 'salamander' and obfs.get('password'):
        print(f\"obfs=salamander&obfs-password={obfs.get('password')}\")
    else:
        print(\"obfs=none\")
except:
    print(\"obfs=none\")
" 2>/dev/null)
                [ -n "$obfs_info" ] && obfs_param="$obfs_info"
            fi
            echo "hysteria2://$uuid@$ip:$listen_port?${url_param}&alpn=h3&${obfs_param}&mport=$listen_port,$min_port-$max_port#$node_remark" >> "$client_dir"        
            # ------------------------------------------------

            base64 -w0 "$client_dir" > /etc/sing-box/sub.txt         
            green "\nHysteria2 端口跳跃已开启"
            purple "跳跃区间：$min_port-$max_port"
            ;;

        3)  
            purple "正在清理端口跳跃规则..."
            if nft list chain ip nat prerouting &>/dev/null; then
                for handle in $(nft -a list chain ip nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                    nft delete rule ip nat prerouting handle $handle 2>/dev/null
                done
            fi
            
            if [ -f /proc/net/if_inet6 ] && nft list chain ip6 nat prerouting &>/dev/null; then
                for handle in $(nft -a list chain ip6 nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                    nft delete rule ip6 nat prerouting handle $handle 2>/dev/null
                done
            fi
            
            nft list ruleset > /etc/nftables.conf 2>/dev/null

            if [ -f "/etc/sing-box/url.txt" ]; then
                sed -i '/hysteria2/s/&mport=[^#&]*//g' /etc/sing-box/url.txt
                base64 -w0 "/etc/sing-box/url.txt" > /etc/sing-box/sub.txt
            fi
            
            green "\n[✔] 端口跳跃已关闭"
            ;;
		4)  # 检测并自动补全 python3 依赖
if ! command -v python3 &> /dev/null; then
    yellow "检测到缺少依赖 python3，正在安装..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y python3
    elif [ -f /etc/redhat-release ]; then
        yum install -y python3
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache python3
    fi
fi

            if [ ! -f "/etc/sing-box/conf/hysteria2.json" ] || ! grep -q "hysteria2://" "/etc/sing-box/url.txt"; then
                red "未检测到 Hysteria2 节点配置或链接，请先安装 Hysteria2！"
                exit 1
            fi
            obfs_pwd=$(tr -dc 'a-zA-Z' < /dev/urandom | head -c 12)   
            python3 -c "
import json
path = '/etc/sing-box/conf/hysteria2.json'
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    obfs_data = {
        'type': 'salamander',
        'password': '$obfs_pwd'
    }

    if isinstance(data, dict):
        if 'inbounds' in data:
            for ib in data['inbounds']:
                if ib.get('type') == 'hysteria2':
                    ib['obfs'] = obfs_data
        else:
            data['obfs'] = obfs_data

    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f'修改 JSON 失败: {e}')
"
            sed -i -E 's/&obfs-password=[^&#]+//g' /etc/sing-box/url.txt
            sed -i -E "s/obfs=[^&#]+/obfs=salamander\&obfs-password=${obfs_pwd}/g" /etc/sing-box/url.txt
            base64 -w0 "/etc/sing-box/url.txt" > "/etc/sing-box/sub.txt" 2>/dev/null
            if command -v restart_singbox &> /dev/null; then
                restart_singbox
            else
                systemctl restart sing-box >/dev/null 2>&1
            fi
            hy2_link=$(grep -oP 'hysteria2://.*' /etc/sing-box/url.txt | head -n 1)
            
            echo ""
            green "=================================================="
            green "Hysteria2 Salamander 混淆已开启！"
            green "=================================================="
            green "${hy2_link}"
            green "=================================================="
            echo "" 
            ;;
		5)
            if [ ! -f "/etc/sing-box/conf/hysteria2.json" ] || ! grep -q "hysteria2://" "/etc/sing-box/url.txt"; then
                red "未检测到 Hysteria2 节点配置或链接！"
                exit 1
            fi
            python3 -c "
import json
path = '/etc/sing-box/conf/hysteria2.json'
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    if isinstance(data, dict):
        if 'inbounds' in data:
            for ib in data['inbounds']:
                if ib.get('type') == 'hysteria2' and 'obfs' in ib:
                    del ib['obfs']
        elif 'obfs' in data:
            del data['obfs']

    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f'清理 JSON 混淆配置失败: {e}')
"
            sed -i -E 's/&obfs-password=[^&#]+//g' /etc/sing-box/url.txt
            sed -i -E "s/obfs=[^&#]+/obfs=none/g" /etc/sing-box/url.txt
            base64 -w0 "/etc/sing-box/url.txt" > "/etc/sing-box/sub.txt" 2>/dev/null
            if command -v restart_singbox &> /dev/null; then
                restart_singbox
            else
                systemctl restart sing-box >/dev/null 2>&1
            fi
            hy2_link=$(grep -oP 'hysteria2://.*' /etc/sing-box/url.txt | head -n 1)
            
            echo ""
            green "=================================================="
            green "Hysteria2 混淆已关闭！"
            green "=================================================="
            green "${hy2_link}"
            green "=================================================="
            echo ""
            ;;

        0)  menu ;;
        *)  read "无效的选项！" ;; 
    esac
}


disable_open_sub() {
    local nginx_status=$(check_nginx 2>/dev/null)
    
    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"
        sleep 1
        menu
        return
    fi

    clear
    echo ""
    green "=== 节点订阅管理 ===\n"
    printf "${purple}--Nginx 状态: %s${re}\n" "$(to_chinese "$nginx_status")"
    skyblue "------------"
    green "1. 启动nginx"
    skyblue "------------"
	green "2. 停止gninx"
    skyblue "------------"
	green "3. 重启nginx"
    skyblue "------------"
	green "4. nginx配置"
    skyblue "------------"
    green "5. 关闭节点订阅"
    skyblue "------------"
    green "6. 开启重置订阅"
    skyblue "------------"
	green "7. 启用域名订阅"
    skyblue "------------"
	green "8. 删除域名订阅"
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
            while true; do
                clear
                green "=== Nginx配置 ==="
                skyblue "------------"
                avail_dir="/etc/nginx/sites-available"
                enabled_dir="/etc/nginx/sites-enabled"                        
                mapfile -t all_conf < <(ls "$avail_dir" | grep '\.conf$')
				disabled_list=()
                enabled_list=()
                for conf in "${all_conf[@]}"; do
                    if [ -L "$enabled_dir/$conf" ]; then
                        enabled_list+=("$conf")
                    else
                        disabled_list+=("$conf")
                    fi
                done
                local idx=1
                local mapping=()

                # --- 上部分：显示未启用 (不在 sites-enabled 中) ---
                green "未启用配置 (输入数字启用):"
                if [ ${#disabled_list[@]} -eq 0 ]; then
                    echo " (暂无)"
                else
                    for conf in "${disabled_list[@]}"; do
                        echo -e " $idx. \033[33m$conf\033[0m"
                        mapping[$idx]="$conf:enable"
                        ((idx++))
                    done
                fi
                skyblue "------------"
                # --- 下部分：显示已启用 (已链接到 sites-enabled) ---
                green "已启用配置 (输入数字停用):"
                if [ ${#enabled_list[@]} -eq 0 ]; then
                    echo " (暂无)"
                else
                    for conf in "${enabled_list[@]}"; do
                        echo -e " $idx. \033[32m$conf\033[0m"
                        mapping[$idx]="$conf:disable"
                        ((idx++))
                    done
                fi

                skyblue "------------"
                purple "0. 返回上级菜单"
                skyblue "------------"
                echo -n "请选择操作数字: "
                read sub_choice

                [ "$sub_choice" == "0" ] && break

                target_info=${mapping[$sub_choice]}
                if [ -z "$target_info" ]; then
                    yellow "选择无效，请重新输入"
                    sleep 1
                    continue
                fi
                filename=${target_info%:*}
                action=${target_info#*:}
                if [ "$action" == "enable" ]; then
                    # 启用：创建软链接
                    ln -sf "$avail_dir/$filename" "$enabled_dir/$filename"
                    green "已创建软链接: $filename"
                else
                    # 停用：删除软链接 (源文件在 sites-available 不受影响)
                    rm -f "$enabled_dir/$filename"
                    yellow "已断开软链接: $filename"
                fi

                echo -e "\033[1;33m正在验证 Nginx 配置...\033[0m"
                if nginx -t > /dev/null 2>&1; then
                    if command_exists rc-service 2>/dev/null; then
                        rc-service nginx reload
                    else 
                        systemctl reload nginx
                    fi
                    green "Nginx 配置正常，已自动重载！"
                else
                    red "错误：Nginx 配置语法检查失败，请手动排查！"
                fi
                sleep 2
            done
            ;;
        5)
           rm -f /etc/nginx/conf.d/sing-box.conf
		   restart_nginx
		   green "节点订阅已删除"
		   ;;
        6)
		   nginx_port=$(shuf -i 1000-65000 -n 1)
		   server_ip=$(get_realip)
           password=$(tr -dc A-Za-z < /dev/urandom | head -c 32) 
		   cat > /etc/nginx/conf.d/sing-box.conf << EOF
server {
    listen $nginx_port;
    listen [::]:$nginx_port;
    server_name _;

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
EOF
		   allow_port $nginx_port/tcp > /dev/null 2>&1   
           restart_nginx
           green "新的订阅链接为：http://$server_ip:$sub_port/$password"
		    ;;
		7)
		   stop_nginx
		   check_and_issue_ssl
		   nginx2_port=$(shuf -i 1000-65000 -n 1)
           password=$(tr -dc A-Za-z < /dev/urandom | head -c 32) 
		   cat > /etc/nginx/conf.d/sing-box1.conf << EOF
server {
    listen $nginx2_port ssl;
    listen [::]:$nginx2_port ssl;
    server_name $domain;

    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;

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
EOF
		   allow_port $nginx2_port/tcp > /dev/null 2>&1   
           restart_nginx
           green "域名订阅链接为：https://$domain:$nginx2_port/$password"
		    ;;
		8)
		   rm -f /etc/nginx/conf.d/sing-box1.conf
		   restart_nginx
		   green "域名订阅已删除"
		   ;;
        0)  menu ;; 
        *)  red "无效的选项！" ;;
    esac
}



manage_nodes_menu() {
    if [ -z "$private_key" ]; then
        output=$(${work_dir}/sing-box generate reality-keypair)
        private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
        public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')
		short_id=$(openssl rand -hex 6)
    fi
    while true; do
        local CONF_DIR="/etc/sing-box/conf"
        local width=45
        local node_list=(
		    "xtls-reality.json|xtls-Reality|1"
			"hysteria2.json|hysteria2|2"
			"tuic.json|tuic|3"
            "h2-reality.json|http-Reality|4"
            "grpc-reality.json|gRPC-Reality|5"
            "anytls.json|anytls|6"
            "socks5.json|socks5|7"
            "http.json|HTTP|8"
			"vless-wstls-cdn.json|vless-ws-tls-cdn|9"
			"vless-ws-cdn.json|vless-ws-cdn|10"
			"vmess-ws-cdn.json|vmess-ws-cdn|11"			
        )
		
        clear
        yellow "============================================="
        echo -e "             添加节点               "
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
		echo -e "\033[31m 0. 返回上一级菜单\033[0m"
        echo -ne "\n"
        reading "请选择操作: " choice
		case "${choice}" in
		1) 
                generate_vars
                server_ip=$(get_realip)    
echo ""
while true; do
    read -rp "请输入 xtls + Reality 端口 (100-65535, 默认 ${xtls_reality}): " custom_port
    if [ -z "$custom_port" ]; then
        custom_port=$xtls_reality
        break
    fi
    if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
        if [ -f "${conf_dir}/node_${custom_port}.json" ] || ss -tuln | grep -qE ":$custom_port\b"; then
            red "该端口已被占用，请重新输入！"
            continue
        fi      
        xtls_reality=$custom_port
        break
    else
        red "输入错误！请输入有效的端口号 (100-65535)。"
    fi
done
                yellow "正在配置 xtls + Reality ..."
                cat > /etc/sing-box/conf/xtls-reality.json << EOF
{
  "inbounds": [
     {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $xtls_reality,
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
    }
  ]
}
EOF
          allow_port $xtls_reality/tcp > /dev/null 2>&1
		  node_remark="${isp}_vless_tcp_reality"
		  url="vless://${uuid}@${server_ip}:${xtls_reality}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${node_remark}"
          if [ -f "/etc/sing-box/url.txt" ]; then
           sed -i "/#${node_remark}$/d" "/etc/sing-box/url.txt"
          fi
          echo "$url" >> "/etc/sing-box/url.txt"
		  echo "" >> "/etc/sing-box/url.txt"
          base64 -w0 "/etc/sing-box/url.txt" > "/etc/sing-box/sub.txt" 2>/dev/null
          restart_singbox 
          green "==============================================="
          green " xtls + Reality 节点已添加!"
          green " 节点链接: $url"
          green "==============================================="
            ;;
        2) 
                generate_vars
				stop_nginx
                server_ip=$(get_realip)
				while true; do
              read -rp "请输入 hysteria2 端口 (1000-65535, 默认 ${hy2_port}): " custom_port
              if [ -z "$custom_port" ]; then
                  custom_port=$hy2_port
                  break
              fi
              if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
                  if [ -f "${conf_dir}/node_${custom_port}.json" ] || ss -tuln | grep -qE ":$custom_port\b"; then
                    red "该端口已被占用，请重新输入！"
                    continue
                  fi      
				  hy2_port=$custom_port
                  break
              else
                  red "输入错误！请输入有效的端口号 (1000-65535)。"
              fi
              done
                echo -e "\n请选择 TLS 证书类型:"
				echo -e "1) \e[32m使用自签名证书\e[0m"
                echo -e "2) \e[32m使用域名申请证书\e[0m"
                read -rp "请输入数字 [1-2] (默认 1): " cert_type
                [ -z "$cert_type" ] && cert_type=1
                if [ "$cert_type" -eq 2 ]; then
                    if check_and_issue_ssl; then
                        cert_path="$cert_file"
                        key_path="$key_file"
                        url_param="sni=${domain}" 
                    else
                        red "证书申请或获取失败，脚本退出！"
                        return 1
                    fi
                else
                    cert_path="$work_dir/cert.pem"
                    key_path="$work_dir/private.key"
                    url_param="insecure=1&sni=www.bing.com"
                fi

                yellow "正在配置 hysteria2..."
                cat > /etc/sing-box/conf/hysteria2.json << EOF
{
  "inbounds": [
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
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    }
  ]
}
EOF
                allow_port $hy2_port/udp > /dev/null 2>&1
                node_remark="${isp}_hysteria2"                
                url="hysteria2://${uuid}@${server_ip}:${hy2_port}/?${url_param}&alpn=h3&obfs=none#${node_remark}"								              
                if [ -f "/etc/sing-box/url.txt" ]; then
                    grep -q "#${isp}$" "/etc/sing-box/url.txt" && sed -i "/#${isp}$/{N;d;}" "/etc/sing-box/url.txt"
                fi
                echo "$url" >> /etc/sing-box/url.txt
                echo "" >> /etc/sing-box/url.txt
                base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                restart_singbox
                restart_nginx
                green "==============================================="
                green " hysteria2 节点已添加!"
                green " 节点链接: $url"
                green "==============================================="
                ;;
	    3) 
                generate_vars
				stop_nginx
                server_ip=$(get_realip)
				while true; do
              read -rp "请输入 tuic 端口 (1000-65535, 默认 ${tuic_port} 推荐443端口): " custom_port
              if [ -z "$custom_port" ]; then
                  custom_port=$tuic_port
                  break
              fi
              if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
                  if [ -f "${conf_dir}/node_${custom_port}.json" ] || ss -tuln | grep -qE ":$custom_port\b"; then
                     red "该端口已被占用，请重新输入！"
                     continue
                  fi      
				  tuic_port=$custom_port
                  break
              else
                  red "输入错误！请输入有效的端口号 (1000-65535)。"
              fi
              done
                echo -e "\n请选择 TLS 证书类型:"
				echo -e "1) \e[32m使用自签名证书\e[0m"
                echo -e "2) \e[32m使用域名申请证书\e[0m"
                read -rp "请输入数字 [1-2] (默认 1): " cert_type
                [ -z "$cert_type" ] && cert_type=1
                if [ "$cert_type" -eq 2 ]; then
                    if check_and_issue_ssl; then
                        cert_path="$cert_file"
                        key_path="$key_file"
                        url_param="sni=${domain}" 
                    else
                        red "证书申请或获取失败，脚本退出！"
                        return 1
                    fi
                else
                    cert_path="$work_dir/cert.pem"
                    key_path="$work_dir/private.key"
                    url_param="allow_insecure=1&sni=www.bing.com"
                fi
                yellow "正在配置 tuic..."
                cat > /etc/sing-box/conf/tuic.json << EOF
{
  "inbounds": [
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
		"certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    }
  ]
}
EOF
                allow_port $tuic_port/udp > /dev/null 2>&1
                node_remark="${isp}_tuic"                
                url="tuic://${uuid}:${password}@${server_ip}:${tuic_port}/?${url_param}&alpn=h3&obfs=none#${node_remark}"			
                if [ -f "/etc/sing-box/url.txt" ]; then
                    grep -q "#${isp}$" "/etc/sing-box/url.txt" && sed -i "/#${isp}$/{N;d;}" "/etc/sing-box/url.txt"
                fi
                echo "$url" >> /etc/sing-box/url.txt
                echo "" >> /etc/sing-box/url.txt
                base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                restart_singbox
                restart_nginx
                green "==============================================="
                green " tuic 节点已添加!"
                green " 节点链接: $url"
                green "==============================================="
                ;;

        4) 
                generate_vars
                server_ip=$(get_realip)  
				while true; do
              read -rp "请输入 H2 + Reality 端口 (100-65535, 默认 ${h2_reality}): " custom_port
              if [ -z "$custom_port" ]; then
                  custom_port=$h2_reality
                  break
              fi
              if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
                  if [ -f "${conf_dir}/node_${custom_port}.json" ] || ss -tuln | grep -qE ":$custom_port\b"; then
                    red "该端口已被占用，请重新输入！"
                    continue
                  fi      
				  h2_reality=$custom_port
                  break
              else
                  red "输入错误！请输入有效的端口号 (100-65535)。"
              fi
              done			
                yellow "正在配置 H2 + Reality ..."
                cat > /etc/sing-box/conf/h2-reality.json << EOF
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
          allow_port $h2_reality/tcp > /dev/null 2>&1
		  node_remark="${isp}_vless_http_reality"
          url="vless://${uuid}@${server_ip}:${h2_reality}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=http#${node_remark}"
          if [ -f "/etc/sing-box/url.txt" ]; then
           sed -i "/#${node_remark}$/d" "/etc/sing-box/url.txt"
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
            5) 
			  generate_vars
              server_ip=$(get_realip)  
			  while true; do
              read -rp "请输入 grpc + Reality 端口 (100-65535, 默认 ${grpc_reality}): " custom_port
              if [ -z "$custom_port" ]; then
                  custom_port=$grpc_reality
                  break
              fi
              if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1 ] && [ "$custom_port" -le 65535 ]; then
                  if [ -f "${conf_dir}/node_${custom_port}.json" ] || ss -tuln | grep -qE ":$custom_port\b"; then
                     red "该端口已被占用，请重新输入！"
                     continue
                  fi      
				  grpc_reality=$custom_port
                  break
              else
                  red "输入错误！请输入有效的端口号 (100-65535)。"
              fi
              done			
			yellow "正在配置 gRPC + Reality..."
            cat > /etc/sing-box/conf/grpc-reality.json << EOF
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
			allow_port $grpc_reality/tcp > /dev/null 2>&1
            node_remark="${isp}_vless_grpc_reality"
            url="vless://${uuid}@${server_ip}:${grpc_reality}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=grpc&serviceName=grpc#${node_remark}"
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
            6) yellow "正在配置 anytls..."
               generate_vars
               server_ip=$(get_realip)
               mkdir -p /etc/sing-box
               cat > /etc/sing-box/conf/anytls.json << EOF
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
			allow_port $anytls_port/tcp > /dev/null 2>&1
            node_remark="${isp}_anytls"
            url="anytls://${password}@${server_ip}:${anytls_port}?sni=addons.mozilla.org&insecure=1#${node_remark}"
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
            7) yellow "正在配置 Socks5..."
                generate_vars
                server_ip=$(get_realip)
                cat > /etc/sing-box/conf/socks5.json << EOF
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
				allow_port $socks_port/tcp > /dev/null 2>&1
				node_remark="${isp}_socks5"
                url="socks://${username}:${password}@${server_ip}:${socks_port}#${node_remark}"
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
            8) 
			yellow "正在配置 HTTP 代理..."
            generate_vars
            server_ip=$(get_realip)
            cat > /etc/sing-box/conf/http.json << EOF
{
  "inbounds": [
    {
      "type": "http",
      "tag": "http-in",
      "listen": "::",
      "listen_port": $http_port,
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
            allow_port "$http_port/tcp" > /dev/null 2>&1     
            node_remark="${isp}_http"
            url="http://${username}:${password}@${server_ip}:${http_port}#${node_remark}"
            if [ -f "/etc/sing-box/url.txt" ]; then
                sed -i "/#${node_remark}$/,+1d" "/etc/sing-box/url.txt"
            fi      
            echo "$url" >> /etc/sing-box/url.txt
            echo "" >> /etc/sing-box/url.txt
            base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null            
            restart_singbox
            
            green "==============================================="
            green " HTTP 节点已添加!"
            green " 节点链接: $url"
            green "==============================================="
            ;;
		9)
        check_and_issue_ssl || return 1
        generate_vars
        mkdir -p /etc/sing-box
        cat > /etc/sing-box/conf/vless-wstls-cdn.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-wstls-cdn",
      "listen": "::",
      "listen_port": $vless_wstls_cdn_port,
      "users": [ { "uuid": "$uuid" } ],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "certificate_path": "$cert_file",
        "key_path": "$key_file"
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
			allow_port $vless_wstls_cdn_port/tcp > /dev/null 2>&1
			node_remark="${isp}_vless_wstls_cdn"
            encoded_path=$(echo "$ws_path" | sed 's/\//%2F/g')
            VLESS_URL="vless://${uuid}@cf.877774.xyz:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=/sspaasksavxssaszass%3Fed%3D2560#${node_remark}"
            if [ -f "${work_dir}/url.txt" ]; then
                grep -q "#${node_remark}$" "${work_dir}/url.txt" && sed -i "/#${node_remark}$/{N;d;}" "${work_dir}/url.txt"
            fi
            echo "$VLESS_URL" >> "${work_dir}/url.txt"
            echo "" >> "${work_dir}/url.txt"
            base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt"
            restart_singbox
			green "--------------------------------------------------"
            green " 节点连接 $VLESS_URL"
            green "--------------------------------------------------"
            yellow " 已生成节点，请去 Cloudflare 添加端口回源规则："
            yellow " 回源端口: $vless_ws_cdn_port"
			yellow " Cloudflare -> SSL/TLS -> 概述：模式改为 '完全 (Flexible)'"
            green "--------------------------------------------------"
            ;;
			10) 
            generate_vars
            mkdir -p /etc/sing-box
            read -p '请输入域名 (例如: b.a.com): ' domain
            [ -z "$domain" ] && red "域名不能为空!" && return 1
            cat > /etc/sing-box/conf/vless-ws-cdn.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-cdn",
      "listen": "::",
      "listen_port": $vless_ws_cdn_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/sspsksavxaszass",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF
			allow_port $vless_ws_cdn_port/tcp > /dev/null 2>&1
            node_remark="${isp}_vless_ws_cdn"
            vless_url="vless://${uuid}@cf.877774.xyz:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=/sspsksavxaszass#${node_remark}"         
            if [ -f "/etc/sing-box/url.txt" ]; then
                sed -i "/#${node_remark}$/,+1d" "/etc/sing-box/url.txt"
            fi                    
            echo "$vless_url" >> /etc/sing-box/url.txt
            echo "" >> /etc/sing-box/url.txt
            base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null           
            
            restart_singbox      
          
            green "--------------------------------------------------"
            green " 节点连接 $vless_url"
            green "--------------------------------------------------"
            yellow " 已生成节点，请去 Cloudflare 添加端口回源规则："
            yellow " 回源端口: $vless_ws_cdn_port"
			yellow " Cloudflare -> SSL/TLS -> 概述：模式改为 '灵活'"
            green "--------------------------------------------------"
            ;;
	      11)
            generate_vars
            mkdir -p /etc/sing-box
            read -p '请输入域名 (例如: b.a.com): ' domain
            [ -z "$domain" ] && red "域名不能为空!" && return 1
            cat > /etc/sing-box/conf/vmess-ws-cdn.json << EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws-cdn",
      "listen": "::",
      "listen_port": $vmess_ws_cdn_port,
      "users": [
        {
          "uuid": "$uuid",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/sspsksavxaszassas"
      }
    }
  ]
}
EOF
            allow_port $vmess_ws_cdn_port/tcp > /dev/null 2>&1      
            node_remark="${isp}_vmess_ws_cdn"
            VMESS="{ \"v\": \"2\", \"ps\": \"${node_remark}\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${domain}\", \"path\": \"/sspsksavxaszassas\", \"tls\": \"tls\", \"sni\": \"${domain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": false }"
            vmess_url="vmess://$(echo -n "$VMESS" | base64 -w0)"
            if [ -f "/etc/sing-box/url.txt" ]; then
                sed -i "/#.*${node_remark}$/{N;d;}" /etc/sing-box/url.txt
            fi                              
            echo "$vmess_url" >> /etc/sing-box/url.txt
            echo "" >> /etc/sing-box/url.txt
            base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null                    
            
            restart_singbox                            
            green "--------------------------------------------------"
            green " 节点连接: $vmess_url"
            green "--------------------------------------------------"
            yellow " 已生成 VMess 节点，请去 Cloudflare 添加端口回源规则："
            yellow " 回源端口: $vmess_ws_cdn_port"
            yellow " Cloudflare -> SSL/TLS -> 概述：模式改为 '灵活'"
            green "--------------------------------------------------"
            ;;   
		
            # --- 完整的删除逻辑 ---
            51) 
			target="_vless_tcp_reality"
            target_conf="/etc/sing-box/conf/xtls-reality.json"
            if [ -f "$target_conf" ]; then
			    xtls_reality=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$xtls_reality" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$xtls_reality" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;

            52) 
            target="_hysteria2"
            target_conf="/etc/sing-box/conf/hysteria2.json"
            if [ -f "$target_conf" ]; then
				hy2_port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
				
                # 安全清理 Hysteria2 的 NAT 端口跳跃规则
                if nft list chain ip nat prerouting &>/dev/null; then
                    for handle in $(nft -a list chain ip nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                        nft delete rule ip nat prerouting handle $handle 2>/dev/null
                    done
                fi
                if [ -f /proc/net/if_inet6 ] && nft list chain ip6 nat prerouting &>/dev/null; then
                    for handle in $(nft -a list chain ip6 nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                        nft delete rule ip6 nat prerouting handle $handle 2>/dev/null
                    done
                fi

                # 清理入站放行规则
                if [ -n "$hy2_port" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$hy2_port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi

                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;

			53) 
			target="_tuic"
            target_conf="/etc/sing-box/conf/tuic.json"
            if [ -f "$target_conf" ]; then
				tuic_port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$tuic_port" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$tuic_port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;	

            54) 
			target="_vless_http_reality"
            target_conf="/etc/sing-box/conf/h2-reality.json"
            if [ -f "$target_conf" ]; then
			    h2_reality=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$h2_reality" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$h2_reality" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;
            55)
            target="_vless_grpc_reality"
            target_conf="/etc/sing-box/conf/grpc-reality.json"
            if [ -f "$target_conf" ]; then
			    grpc_reality=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$grpc_reality" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$grpc_reality" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;
            56)
			target="_anytls"
            target_conf="/etc/sing-box/conf/anytls.json"
            if [ -f "$target_conf" ]; then
			    anytls_port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$anytls_port" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$anytls_port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;
            57)
			target="_socks5"
            target_conf="/etc/sing-box/conf/socks5.json"
            if [ -f "$target_conf" ]; then
			    socks_port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$socks_port" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$socks_port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;
            58)
			target="_http"
            target_conf="/etc/sing-box/conf/http.json"
            if [ -f "$target_conf" ]; then
			    http_port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$http_port" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$http_port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;
		    59) 
			target="_vless_wstls_cdn"
            target_conf="/etc/sing-box/conf/vless-wstls-cdn.json"
            if [ -f "$target_conf" ]; then
			    vless_wstls_cdn_port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$vless_wstls_cdn_port" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$vless_wstls_cdn_port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                     sed -i "/${target}/d" /etc/sing-box/url.txt
                     sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					 echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;
			60) 
			target="_vless_ws_cdn"
            target_conf="/etc/sing-box/conf/vless-ws-cdn.json"
            if [ -f "$target_conf" ]; then
			    vless_ws_cdn_port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$vless_ws_cdn_port" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$vless_ws_cdn_port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;	
		    61) 
		    target="_vmess_ws_cdn"
            target_conf="/etc/sing-box/conf/vmess-ws-cdn.json"
            if [ -f "$target_conf" ]; then
			    vmess_ws_cdn_port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
                if [ -n "$vmess_ws_cdn_port" ]; then
                    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$vmess_ws_cdn_port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    new_urls=$(while read -r line; do
                        [ -z "$line" ] && continue              
                        if [[ "$line" == vmess://* ]]; then
                            content=$(echo "${line#vmess://}" | cut -d'#' -f1 | base64 -d 2>/dev/null)
                            if [[ ! "$content" =~ "$target" ]]; then
                                echo "$line"
                                echo "" 
                            fi
                        else
                            echo "$line"
                            echo ""
                        fi
                    done < "/etc/sing-box/url.txt")
                    echo "$new_urls" > "/etc/sing-box/url.txt"
					sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi      
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
			;;

            0) break ;;
            *) red "无效选项"; sleep 1; continue ;;
        esac       
        echo -e "\n\033[31m按任意键返回菜单...\033[0m"
        read -n 1
    done
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

bbr_menu() {
    local bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control)
    green "=== BBR ===\n"
    green "当前拥塞控制算法: $bbr_status\n"
    green "1. 开启 BBR"
    skyblue "------------"
    green "2. 关闭 BBR"
    skyblue "------------"
    green "0. 返回主菜单"
    skyblue "------------"
    read -rp "请选择操作 [0-2]: " choice
    case "$choice" in
        0)
            menu
            ;;
        1)
            enable_bbr
            bbr_menu
            ;;
        2)
            disable_bbr
            bbr_menu
            ;;
        *)
            echo -e "${red}无效的选项，请重新选择。${plain}\n"
            bbr_menu
            ;;
    esac
}

disable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${yellow}BBR 当前未处于开启状态。${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        rm -f /etc/sysctl.d/99-bbr-x-ui.conf
    fi

    if [ -f "/etc/sysctl.conf" ]; then
        sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
        sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
    fi

    sysctl -w net.core.default_qdisc=pfifo_fast > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${green}BBR 已成功替换为 CUBIC。${plain}"
    else
        echo -e "${red}未能将 BBR 替换为 CUBIC，请检查系统配置。${plain}"
    fi
}

enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${green}BBR 已经处于开启状态！${plain}"
        before_show_menu
    fi

    if [ -d "/etc/sysctl.d/" ]; then
        {
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "/etc/sysctl.d/99-bbr-x-ui.conf"
        
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/^net.core.default_qdisc/# &/' /etc/sysctl.conf
            sed -i 's/^net.ipv4.tcp_congestion_control/# &/' /etc/sysctl.conf
        fi
        
        sysctl -p /etc/sysctl.d/99-bbr-x-ui.conf
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        echo -e "${green}BBR 已成功开启。${plain}"
    else
        echo -e "${red}开启 BBR 失败，请检查系统配置。${plain}"
    fi
}


# Iptables简单管理
ipt_msg() { echo -e "${1}${2}\033[0m"; }

save_nft_rules() {
    echo "flush ruleset" > /etc/nftables.conf
    nft list ruleset 2>/dev/null | awk '/table inet port_manager/{p=1;next} /^table /{p=0} !p' >> /etc/nftables.conf
}


check_rule_files() {
    local conf="/etc/nftables.conf"
    if ! command -v nft &> /dev/null; then return; fi
    
    if ! nft list table inet filter &>/dev/null; then
        cat > "$conf" << EOF
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
        iif "lo" accept
        ct state established,related accept
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
        nft -f "$conf" 2>/dev/null
    fi
}

iptables_ssl() {
    check_and_install_nftables
    clear
    check_rule_files
    local tag="ScriptManaged"
    
    local status_text=""
    local mode_text=""
    local svc_status=$(systemctl is-active nftables 2>/dev/null)
    local pm_status=$(systemctl is-active port_manager 2>/dev/null)
    
    local policy=$(nft list chain inet filter input 2>/dev/null | awk '/policy/ {print $NF}' | tr -d ';')
    local rule_count=$(nft list ruleset 2>/dev/null | grep -vE "^table|^chain|^}" | wc -l)

    if ! command -v nft &> /dev/null; then
        status_text="\033[0;31m未安装\033[0m"
        mode_text="\033[0;37m未知\033[0m"
    elif [ "$rule_count" -gt 0 ] || [ "$svc_status" == "active" ]; then
        status_text="\033[0;32m运行中\033[0m"
        if [ "$policy" == "drop" ]; then
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

    local nat_rules=$(nft list ruleset 2>/dev/null | awk '/dnat to/ {
        port=""; to="";
        for(i=1;i<=NF;i++){
            if($i=="dport") port=$(i+1);
            if($i=="to") to=$(i+1);
        }
        if(port != "") { print " 端口:" port " -> 转发至:" to }
    }')
    [ -z "$nat_rules" ] && nat_rules="  暂无转发规则"
	
    echo ""
    green "=== 防火墙与流量管理面板 ==="
    echo -e "防火墙状态: $status_text"
    echo -e "拦截模式: $mode_text"
    
    # 联动显示选项 8 流量管控服务状态
    if [ "$pm_status" == "active" ]; then
        local pm_cnt=$(ls -1 /etc/port_manager/*.conf 2>/dev/null | wc -l)
        echo -e "流量管控: \033[0;32m运行中\033[0m (已设置 $pm_cnt 个端口)"
    else
        echo -e "流量管控: \033[0;37m未启用\033[0m"
    fi
    
    ipt_msg "\033[0;36m" "系统当前 SSH 端口: ${ssh_p}"
    echo -e "\033[0;33m$nat_rules\033[0m"
    skyblue "---------------------------"

    ipt_msg "\033[0;33m" "已在防火墙放行的端口:"
    printf "%-13s %-19s %-15s\n" "端口号" "所属服务" "说明"   

    local allowed_ports=""
    if command -v nft &> /dev/null; then
        allowed_ports=$(nft list chain inet filter input 2>/dev/null | awk '/dport.*accept/ {
            for(i=1;i<=NF;i++) if($i=="dport") { print $(i+1); break; }
        }' | tr -d '{};' | tr ',' '\n' | grep -E "^[0-9]+$" | sort -un)
        
        for port in $allowed_ports; do
            local is_script=$(nft list chain inet filter input 2>/dev/null | grep -E "dport.*$port.*$tag")
            local note="系统/手动"
            [ -n "$is_script" ] && note="脚本放行"
            
            if [ -f "/etc/port_manager/${port}.conf" ]; then
                note="${note}[限速中]"
            fi
            
            local name="未运行"
            local ss_line=$(ss -tunlp | grep ":$port " | head -n1)
            if [[ "$ss_line" =~ \"([^\"]+)\" ]]; then
                name="${BASH_REMATCH[1]}"
            fi
            printf "\033[0;32m%-10s %-15s %-10s\033[0m\n" "$port" "$name" "$note"
        done
    fi
    
    echo -e "\033[0;36m---------------------------\033[0m"
    ipt_msg "\033[0;35m" "检测到正在运行但【未放行】的端口"
    printf "%-13s %-19s %-15s\n" "端口号"    "所属服务"    "监听IP/状态"    
    ss -tunlp | awk 'NR>1 {
        addr = $5; n = split(addr, a, ":"); port = a[n];
        ip = ""; for(i=1; i<n; i++) ip = (ip == "" ? a[i] : ip ":" a[i]);
        if (ip ~ /:/ || ip ~ /\[/) next;
        if (ip == "" || ip == "*") ip = "0.0.0.0";
        name = "未知服务"; if ($NF ~ /"/) { split($NF, s, "\""); name = s[2] }
        if (port ~ /^[0-9]+$/ && port > 0) print port, name, ip}' | sort -un | sort -n -k1,1 | while read -r p_port p_name p_ip; do
        if ! echo "$allowed_ports" | grep -qw "$p_port"; then
            local warn_extra=""
            if [ -f "/etc/port_manager/${p_port}.conf" ]; then
                warn_extra=" (已限速但未放行!)"
            fi
            printf "\033[0;31m%-10s %-15s %-10s\033[0m\n" "$p_port" "$p_name" "${p_ip}${warn_extra}"
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
    red   "8. 端口流量网速设置"
    green "9. 清理未运行端口"
	green "10. 修改SSH连接端口"
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
                if nft list chain inet filter input 2>/dev/null | grep -qw "$o_port"; then
                    yellow "端口 $o_port 规则已存在，无需重复添加"
                else
                    nft add rule inet filter input tcp dport $o_port accept comment "$tag" 2>/dev/null
                    nft add rule inet filter input udp dport $o_port accept comment "$tag" 2>/dev/null
                    save_nft_rules
                    green "成功：端口 $o_port 已放行 (原生双栈生效)"
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
                for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$c_port" '$0~"dport "p {print $NF}'); do
                    nft delete rule inet filter input handle $handle 2>/dev/null
                done
                save_nft_rules
                green "清理完成：端口 $c_port 已关闭"
            fi
            sleep 1 && iptables_ssl ;;

        3)
            yellow "正在开启拦截..."
            ssh_ports=$(grep -E "^Port\s+" /etc/ssh/sshd_config | awk '{print $2}')
            [ -z "$ssh_ports" ] && ssh_ports=22
            
            # 基础放行规则
            nft add rule inet filter input iif "lo" accept 2>/dev/null
            nft add rule inet filter input ct state established,related accept 2>/dev/null
            nft add rule inet filter input ip6 nexthdr icmpv6 icmpv6 type { nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept 2>/dev/null
            
            # 放行 SSH 端口
            for port in $ssh_ports; do
                nft add rule inet filter input tcp dport $port accept comment "SSH_Port" 2>/dev/null
            done
            
            for conf in /etc/port_manager/*.conf; do
                [ -e "$conf" ] || continue
                local pm_p=$(basename "$conf" .conf)
                if [ -n "$pm_p" ] && [ "$pm_p" -gt 0 ] 2>/dev/null; then
                    nft add rule inet filter input tcp dport $pm_p accept comment "PortManager" 2>/dev/null
                    nft add rule inet filter input udp dport $pm_p accept comment "PortManager" 2>/dev/null
                fi
            done
            
            nft 'add chain inet filter input { type filter hook input priority 0; policy drop; }' 2>/dev/null
            save_nft_rules
            
            green "开启拦截成功 (已自动放行 SSH 及限速管控端口)" && sleep 1
            iptables_ssl ;;
            
         4)
            yellow "正在关闭拦截..."
            nft 'add chain inet filter input { type filter hook input priority 0; policy accept; }' 2>/dev/null
            save_nft_rules
            green "已关闭拦截 (默认放行所有)" && sleep 1
            iptables_ssl ;;
            
        5)
            yellow "正在配置环境..."
            [[ $EUID -ne 0 ]] && red "请使用 root 用户运行此脚本！" && exit 1      
            if [ -f /etc/debian_version ]; then
                apt-get update -y
                apt-get install -y nftables
            elif [ -f /etc/redhat-release ]; then
                yum install -y nftables
            fi
            systemctl enable nftables 2>/dev/null
            systemctl start nftables 2>/dev/null
            check_rule_files
            save_nft_rules
            green "环境配置完成。" 
            sleep 1 && iptables_ssl ;;
            
        6)
            yellow "正在停止防火墙并清空规则..."
            systemctl stop nftables 2>/dev/null
            systemctl stop port_manager 2>/dev/null
            nft flush ruleset
            green "防火墙及流量限制服务已停止，规则已清空。"
            sleep 1 && iptables_ssl ;;
            
        7)
            yellow "正在重载并激活防火墙与流量限制规则..."
            systemctl enable nftables >/dev/null 2>&1
            systemctl start nftables >/dev/null 2>&1
            if [ -f "/etc/nftables.conf" ]; then
                nft -f /etc/nftables.conf && green " (/etc/nftables.conf) 防火墙规则已重载。"
            fi
            if [ -f "/usr/local/bin/port_menu.sh" ]; then
                systemctl restart port_manager >/dev/null 2>&1 && green " (port_manager) 流量限制服务已同步重启。"
            fi
            green "重载操作执行完毕。"
            sleep 1 && iptables_ssl ;;
            
        8) 
            clear
            yellow "正在初始化"
            if ! command -v tc &> /dev/null; then
                yellow "检测到系统缺少 tc 工具，正在自动安装"
                if [ -f /etc/debian_version ]; then
                    apt-get update -y && apt-get install -y iproute2
                elif [ -f /etc/redhat-release ]; then
                    yum install -y iproute 2>/dev/null || dnf install -y iproute
                fi
            fi

            cat << 'EOF' > /usr/local/bin/port_menu.sh
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

CONF_DIR="/etc/port_manager"
TARGET_PATH="/usr/local/bin/port_menu.sh"

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m[-] 错误: 请使用 root 权限运行此脚本\033[0m"
    exit 1
fi

mkdir -p "$CONF_DIR"

get_interface() {
    local dev
    dev=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    if [ -z "$dev" ]; then
        dev=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n1)
    fi
    echo "$dev"
}
INTERFACE=$(get_interface)

get_bj_time() {
    TZ='Asia/Shanghai' date "+%Y %m %d %H %M"
}

init_nft_table() {
    nft add table inet port_manager 2>/dev/null || true
    nft 'add chain inet port_manager prerouting { type filter hook prerouting priority 0; policy accept; }' 2>/dev/null || true
    nft 'add chain inet port_manager postrouting { type filter hook postrouting priority 0; policy accept; }' 2>/dev/null || true
    nft 'add chain inet port_manager output { type filter hook output priority 0; policy accept; }' 2>/dev/null || true
    nft 'add chain inet port_manager input { type filter hook input priority 0; policy accept; }' 2>/dev/null || true
}

check_and_block() {
    init_nft_table
    read -r BJ_YEAR BJ_MONTH BJ_DAY BJ_HOUR BJ_MINUTE <<< "$(get_bj_time)"
    local CURRENT_MONTH_STR="${BJ_YEAR}${BJ_MONTH}"
    
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local PORT=$(basename "$conf" .conf)
        source "$conf"
        
        local CHAIN_NAME="LIMIT_P_${PORT}"
        
        [ -z "$STORED_TOTAL" ] && STORED_TOTAL=0
        [ -z "$LAST_IPT_BYTES" ] && LAST_IPT_BYTES=0
        [ -z "$RATE" ] && RATE="UNLIMITED"
        [ -z "$LAST_RESET_MONTH" ] && LAST_RESET_MONTH=""
        
        if [ "$RESET_MODE" == "MONTHLY" ]; then
            local should_reset=0
            if [ "$CURRENT_MONTH_STR" != "$LAST_RESET_MONTH" ]; then
                if [ "$BJ_DAY" -gt 1 ]; then
                    should_reset=1
                elif [ "$BJ_DAY" -eq 1 ]; then
                    if [ "$BJ_HOUR" -gt 0 ] || { [ "$BJ_HOUR" -eq 0 ] && [ "$BJ_MINUTE" -ge 1 ]; }; then
                        should_reset=1
                    fi
                fi
            fi
            
            if [ "$should_reset" -eq 1 ]; then
                nft flush chain inet port_manager "$CHAIN_NAME" 2>/dev/null
                nft add rule inet port_manager "$CHAIN_NAME" counter accept 2>/dev/null
                STORED_TOTAL=0
                LAST_IPT_BYTES=0
                sed -i "s/LAST_RESET_MONTH=.*/LAST_RESET_MONTH=\"$CURRENT_MONTH_STR\"/" "$conf"
                sed -i "s/STORED_TOTAL=.*/STORED_TOTAL=\"0\"/" "$conf"
                sed -i "s/LAST_IPT_BYTES=.*/LAST_IPT_BYTES=\"0\"/" "$conf"
                continue
            fi
        fi
        
        local NFT_BYTES
        NFT_BYTES=$(nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | awk '/bytes/ {for(i=1;i<=NF;i++) if($i=="bytes") {print $(i+1); exit}}')
        [ -z "$NFT_BYTES" ] && NFT_BYTES=0
        
        local DIFF=0
        if [ "$NFT_BYTES" -ge "$LAST_IPT_BYTES" ]; then
            DIFF=$(( NFT_BYTES - LAST_IPT_BYTES ))
        else
            DIFF="$NFT_BYTES"
        fi
        
        STORED_TOTAL=$(( STORED_TOTAL + DIFF ))
        LAST_IPT_BYTES="$NFT_BYTES"
        
        sed -i "s/STORED_TOTAL=.*/STORED_TOTAL=\"$STORED_TOTAL\"/" "$conf"
        sed -i "s/LAST_IPT_BYTES=.*/LAST_IPT_BYTES=\"$LAST_IPT_BYTES\"/" "$conf"

        if [ "$QUOTA" == "UNLIMITED" ]; then
            continue
        fi
        
        local LIMIT_BYTES=$(( QUOTA * 1048576 ))
        if [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ]; then
            if ! nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | grep -q "drop"; then
                nft insert rule inet port_manager "$CHAIN_NAME" index 0 drop 2>/dev/null || true
            fi
        fi
    done
}

rebuild_tc_filters() {
    tc filter del dev "$INTERFACE" parent 1:0 prio 1 2>/dev/null
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local p=$(basename "$conf" .conf)
        source "$conf"
        
        if [ "$RATE" != "UNLIMITED" ]; then
            local HEX=$(printf "%x" "$p")
            tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip dport "$p" 0xffff flowid 1:$HEX 2>/dev/null
            tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip sport "$p" 0xffff flowid 1:$HEX 2>/dev/null
        fi
    done
}

restore_rules_func() {
    modprobe nf_tables 2>/dev/null || true
    
    while [ -z "$INTERFACE" ]; do
        sleep 2
        INTERFACE=$(get_interface)
    done

    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30 2>/dev/null
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate 1000mbit 2>/dev/null
    tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit 2>/dev/null

    init_nft_table

    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local p=$(basename "$conf" .conf)
        source "$conf"
        local HEX=$(printf "%x" "$p")
        local CHAIN_NAME="LIMIT_P_${p}"

        if [ "$RATE" != "UNLIMITED" ]; then
            tc class add dev "$INTERFACE" parent 1:1 classid 1:$HEX htb rate "$RATE" ceil "$RATE" 2>/dev/null || true
        fi

        nft add chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
        nft flush chain inet port_manager "$CHAIN_NAME"
        nft add rule inet port_manager "$CHAIN_NAME" counter accept

        nft add rule inet port_manager input tcp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
        nft add rule inet port_manager input udp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
        nft add rule inet port_manager output tcp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
        nft add rule inet port_manager output udp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true

        if [ "$QUOTA" != "UNLIMITED" ]; then
            local LIMIT_BYTES=$(( QUOTA * 1048576 ))
            if [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ]; then
                nft insert rule inet port_manager "$CHAIN_NAME" index 0 drop 2>/dev/null || true
            fi
        fi
    done
    rebuild_tc_filters
}

if [ "$1" == "daemon" ]; then
    restore_rules_func
    while true; do
        if ! nft list table inet port_manager &>/dev/null; then
            restore_rules_func
        fi
        check_and_block
        sleep 3
    done
    exit 0
fi

apply_limit() {
    local p=$1
    local r=$2
    local q=$3
    local rm=$4
    read -r lm_y lm_m _ _ _ <<< "$(get_bj_time)"
    local lm="${lm_y}${lm_m}"
    local HEX=$(printf "%x" "$p")
    local CHAIN_NAME="LIMIT_P_${p}"

    echo -e "RATE=\"$r\"\nQUOTA=\"$q\"\nRESET_MODE=\"$rm\"\nLAST_RESET_MONTH=\"$lm\"\nSTORED_TOTAL=\"0\"\nLAST_IPT_BYTES=\"0\"" > "$CONF_DIR/${p}.conf"

    tc class del dev "$INTERFACE" classid 1:$HEX 2>/dev/null
    if [ "$r" != "UNLIMITED" ]; then
        if ! tc qdisc show dev "$INTERFACE" | grep -q "htb"; then
            tc qdisc add dev "$INTERFACE" root handle 1: htb default 30
            tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate 1000mbit
            tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit
        fi
        tc class add dev "$INTERFACE" parent 1:1 classid 1:$HEX htb rate "$r" ceil "$r"
    fi
    rebuild_tc_filters

    init_nft_table
    nft add chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
    nft flush chain inet port_manager "$CHAIN_NAME"
    nft add rule inet port_manager "$CHAIN_NAME" counter accept

    nft add rule inet port_manager input tcp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
    nft add rule inet port_manager input udp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
    nft add rule inet port_manager output tcp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
    nft add rule inet port_manager output udp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
}

remove_limit() {
    local p=$1
    local HEX=$(printf "%x" "$p")
    local CHAIN_NAME="LIMIT_P_${p}"

    tc class del dev "$INTERFACE" classid 1:$HEX 2>/dev/null
    rm -f "$CONF_DIR/${p}.conf"
    rebuild_tc_filters

    nft flush chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
    nft delete chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
}

show_ports() {
    check_and_block
    echo -e "\033[36m当前网卡: $INTERFACE \033[0m"
    echo "---------------------------------------------"
    printf " %-6s | %-8s | %-8s | %-8s | %-8s | %b\n" "端口" "流量上限" "网速上限" "已用流量" "周期" "状态"
    echo "---------------------------------------------"
    
    local count=0
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        count=$((count+1))
        local PORT=$(basename "$conf" .conf)
        source "$conf"
        
        local CHAIN_NAME="LIMIT_P_${PORT}"
        local COLOR_STATUS="\033[32m正常\033[0m"
        
        [ -z "$STORED_TOTAL" ] && STORED_TOTAL=0
        
        if [ "$STORED_TOTAL" -eq 0 ]; then
            local LIVE_BYTES
            LIVE_BYTES=$(nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | awk '/bytes/ {for(i=1;i<=NF;i++) if($i=="bytes") {print $(i+1); exit}}')
            [ -n "$LIVE_BYTES" ] && [ "$LIVE_BYTES" -gt 0 ] && STORED_TOTAL="$LIVE_BYTES"
        fi
        
        local USED_MB=$(awk "BEGIN {printf \"%.2f\", $STORED_TOTAL / 1048576}")
        
        local is_dropped=0
        if nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | grep -q "drop"; then
            is_dropped=1
        elif [ "$QUOTA" != "UNLIMITED" ]; then
            local LIMIT_BYTES=$(( QUOTA * 1048576 ))
            [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ] && is_dropped=1
        fi

        if [ "$is_dropped" -eq 1 ]; then
            COLOR_STATUS="\033[31m阻断\033[0m"
            if ! nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | grep -q "drop"; then
                nft insert rule inet port_manager "$CHAIN_NAME" index 0 drop 2>/dev/null || true
            fi
        fi
        
        local Q_DISP="无限制"
        [ "$QUOTA" != "UNLIMITED" ] && Q_DISP="${QUOTA}MB"
        
        local R_DISP="无限制"
        [ "$RATE" != "UNLIMITED" ] && R_DISP="${RATE/mbit/Mbps}"

        local M_DISP="一次性"
        [ "$RESET_MODE" == "MONTHLY" ] && M_DISP="每月(1日00:01)"
        
        printf " %-6s | %-8s | %-8s | %-8s | %-8s | %b\n" "$PORT" "$Q_DISP" "$R_DISP" "${USED_MB}MB" "$M_DISP" "$COLOR_STATUS"
    done
    
    if [ "$count" -eq 0 ]; then
        echo -e "                   \033[33m当前暂未设置任何端口限制\033[0m"
    fi
    echo "---------------------------------------------"
}

while true; do
    clear
    echo "============================================="
    echo "     端口网速与流量限制"
    echo "============================================="
    echo "  1. 新增 端口限制"
    echo "  2. 修改 端口限制 (会清零当前已用流量)"
    echo "  3. 删除 端口限制"
    echo "  0. 返回 上级菜单"
    echo "============================================="
    echo -e "已设置的端口:\n"
    show_ports
    
    read -p "请输入选项 [1-3, 0]: " choice
    case $choice in
        1|2)
            if [ "$choice" == "2" ]; then
                read -p "请输入要【修改】的端口号: " port
                if [ ! -f "$CONF_DIR/${port}.conf" ]; then
                    echo -e "\033[31m[-] 未找到该端口的配置！\033[0m"
                    read -p "按回车键继续..."
                    continue
                fi
                remove_limit "$port"
            else
                read -p "请输入要【限制】的端口号 (如 443): " port
            fi
            
            if [ -z "$port" ]; then
                echo -e "\033[31m[-] 端口号不能为空！\033[0m"
                read -p "按回车键继续..."
                continue
            fi

            echo -e "\n\033[36m>>> 直接按回车跳过流量限制 <<<\033[0m"
            read -p "请输入流量上限(MB): " quota
            if [ -z "$quota" ]; then
                quota="UNLIMITED"
                echo -e " -> \033[33m已设为: 不限制流量\033[0m"
            fi

            echo -e "\n\033[36m>>> 直接输入数字即可 (默认单位 Mbps)，直接按回车跳过网速限制 <<<\033[0m"
            read -p "请输入网速上限(如输入 5 代表 5Mbps): " rate_num
            if [ -z "$rate_num" ]; then
                rate="UNLIMITED"
                echo -e " -> \033[33m已设为: 不限制网速\033[0m"
            else
                rate="${rate_num}mbit"
                echo -e " -> \033[32m已设为: ${rate_num} Mbps\033[0m"
            fi

            echo -e "\n\033[36m>>> 直接按回车默认为一次性限制 <<<\033[0m"
            read -p "是否按月自动重置流量？(输入 y 开启，每月北京时间1日00:01重置): " is_monthly
            if [[ "$is_monthly" == "y" || "$is_monthly" == "Y" ]]; then
                reset_mode="MONTHLY"
                echo -e " -> \033[32m已设为: 每月重置 (北京时间1日00:01)\033[0m"
            else
                reset_mode="ONCE"
                echo -e " -> \033[33m已设为: 一次性限制 (用完即永久阻断)\033[0m"
            fi
            
            apply_limit "$port" "$rate" "$quota" "$reset_mode"
            echo -e "\n\033[32m[+] 端口 $port 限制配置成功！\033[0m"
            read -p "按回车键继续..."
            ;;
        3)
            read -p "请输入要删除限制的端口号: " port
            if [ -f "$CONF_DIR/${port}.conf" ]; then
                remove_limit "$port"
                echo -e "\033[32m[+] 端口 $port 限制已彻底移除！\033[0m"
            else
                echo -e "\033[31m[-] 未找到该端口的配置！\033[0m"
            fi
            read -p "按回车键继续..."
            ;;
        0)
            echo -e "\033[32m返回防火墙。\033[0m"
            break
            ;;
        *)
            echo "无效选项，请重新输入。"
            sleep 1
            ;;
    esac
done
EOF

            chmod +x /usr/local/bin/port_menu.sh
            cat << 'SRVEOF' > /etc/systemd/system/port_manager.service
[Unit]
Description=Port Traffic Manager Background Service (nftables)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/port_menu.sh daemon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SRVEOF

            systemctl daemon-reload >/dev/null 2>&1
            systemctl enable port_manager.service >/dev/null 2>&1
            systemctl restart port_manager.service >/dev/null 2>&1
            systemctl stop restore_iptables.service >/dev/null 2>&1
            systemctl disable restore_iptables.service >/dev/null 2>&1
            rm -f /etc/systemd/system/restore_iptables.service
            bash /usr/local/bin/port_menu.sh menu
            sleep 1 && iptables_ssl
            ;;                  
        9)
            yellow "正在自动扫描并清理所有未运行的无用端口规则..."
            for port in $(nft list chain inet filter input 2>/dev/null | awk '/ScriptManaged/ {for(i=1;i<=NF;i++) if($i=="dport") print $(i+1)}' | tr -d '{};' | tr ',' '\n' | grep -E "^[0-9]+$" | sort -un); do
                if ! ss -tunlp | grep -q ":$port "; then
                    for handle in $(nft -a list chain inet filter input | awk -v p="$port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    green "已清理: $port"
                fi
            done
            save_nft_rules
            green "清理完成！配置文件已更新保存。"
            sleep 1 && iptables_ssl ;;
        10)
            clear
            sed -i 's/^#\s*Port/Port/' /etc/ssh/sshd_config
            current_port=$(grep -E '^Port\s+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
            [ -z "$current_port" ] && current_port=22
            
            ipt_msg "\033[0;36m" "当前的 SSH 端口号是: $current_port"
            skyblue "---------------------------"
            
            read -p $'\033[1;35m请输入新的 SSH 端口号 (1-65535): \033[0m' new_port
            
            if [ -z "$new_port" ]; then
                yellow "未输入端口号，操作取消"
                sleep 1 && iptables_ssl
            elif ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then
                red "错误：请输入 1-65535 之间的有效端口号！"
                sleep 1 && iptables_ssl
            elif [ "$new_port" -eq "$current_port" ]; then
                yellow "新端口与当前端口相同，无需修改。"
                sleep 1 && iptables_ssl
            else
                cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
                if grep -qE '^Port\s+[0-9]+' /etc/ssh/sshd_config; then
                    sed -i "s/^Port\s\+[0-9]\+/Port $new_port/g" /etc/ssh/sshd_config
                else
                    echo "Port $new_port" >> /etc/ssh/sshd_config
                fi
                
                if command -v systemctl &>/dev/null; then
                    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
                else
                    service sshd restart 2>/dev/null || service ssh restart 2>/dev/null
                fi
                
                green "成功：SSH 端口已修改为 $new_port"

                if command -v apt-get &>/dev/null; then
                    apt-get remove -y iptables-persistent ufw >/dev/null 2>&1
                elif command -v yum &>/dev/null; then
                    yum remove -y firewalld iptables-services >/dev/null 2>&1
                fi
                
                yellow "为了防止新端口未放行导致断网，正在自动关闭防火墙拦截模式..."
                nft 'add chain inet filter input { type filter hook input priority 0; policy accept; }' 2>/dev/null
                save_nft_rules
                green "拦截已关闭，防火墙当前为 [放行所有] 状态"
                
                sleep 2 && iptables_ssl
            fi
            ;;
		
        0) menu ;;
        *) iptables_ssl ;;
    esac
}

vps_s() {
    ip_address    
    if [ "$(uname -m)" == "x86_64" ]; then
      cpu_info=$(cat /proc/cpuinfo | grep 'model name' | uniq | sed -e 's/model name[[:space:]]*: //')
    else
      cpu_info=$(lscpu | grep 'Model name' | sed -e 's/Model name[[:space:]]*: //')
    fi
    cpu_usage_percent=$(awk '/cpu /{u=$2+$4; d=$2+$4+$5; if(NR==2) {printf "%.2f%%", (u-lu)/(d-ld)*100} lu=u; ld=d}' <(grep 'cpu ' /proc/stat; sleep 0.2; grep 'cpu ' /proc/stat))
    
    cpu_cores=$(nproc)
    mem_info=$(free -b | awk 'NR==2{printf "%.2f/%.2f MB (%.2f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')
    disk_info=$(df -h | awk '$NF=="/"{printf "%d/%dGB (%s)", $3,$2,$5}')
    
    ip_api_res=$(curl -s --max-time 5 http://ip-api.com/json/?fields=status,country,city,isp)
    if echo "$ip_api_res" | grep -q '"success"'; then
        country=$(echo "$ip_api_res" | awk -F'"country":"' '{print $2}' | awk -F'"' '{print $1}')
        city=$(echo "$ip_api_res" | awk -F'"city":"' '{print $2}' | awk -F'"' '{print $1}')
        isp_info=$(echo "$ip_api_res" | awk -F'"isp":"' '{print $2}' | awk -F'"' '{print $1}')
    else
        country="未知"
        city="未知"
        isp_info="获取失败 (限流)"
    fi
    
    cpu_arch=$(uname -m)
    hostname=$(hostname)
    kernel_version=$(uname -r)
    congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control)
    queue_algorithm=$(sysctl -n net.core.default_qdisc)
    
    os_info=$(lsb_release -ds 2>/dev/null)
    if [ -z "$os_info" ]; then
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
    
	current_bytes=$(awk 'BEGIN { rx = 0; tx = 0 } NR > 2 { rx += $2; tx += $10 } END { printf "%.0f %.0f", rx, tx }' /proc/net/dev)
    read -r curr_rx curr_tx <<< "$current_bytes"

    traffic_file="$HOME/.vps_traffic_stats"
    cur_month=$(TZ="America/New_York" date "+%Y-%m")

    last_month="" ; last_rx=0 ; last_tx=0 ; monthly_rx=0 ; monthly_tx=0
    if [ -f "$traffic_file" ]; then source "$traffic_file" 2>/dev/null; fi

    if [ "$last_month" != "$cur_month" ]; then
        monthly_rx=0 ; monthly_tx=0 ; last_rx=0 ; last_tx=0
    fi

    if [ "$curr_rx" -ge "$last_rx" ]; then delta_rx=$((curr_rx - last_rx)); else delta_rx=$curr_rx; fi
    if [ "$curr_tx" -ge "$last_tx" ]; then delta_tx=$((curr_tx - last_tx)); else delta_tx=$curr_tx; fi

    monthly_rx=$((monthly_rx + delta_rx))
    monthly_tx=$((monthly_tx + delta_tx))

    cat << EOF > "$traffic_file"
last_month="$cur_month"
last_rx="$curr_rx"
last_tx="$curr_tx"
monthly_rx="$monthly_rx"
monthly_tx="$monthly_tx"
EOF

    monthly_output=$(awk -v rx="$monthly_rx" -v tx="$monthly_tx" '
        BEGIN {
            rx_units = "Bytes"; tx_units = "Bytes";
            if (rx > 1024) { rx /= 1024; rx_units = "KB"; }
            if (rx > 1024) { rx /= 1024; rx_units = "MB"; }
            if (rx > 1024) { rx /= 1024; rx_units = "GB"; }
            if (tx > 1024) { tx /= 1024; tx_units = "KB"; }
            if (tx > 1024) { tx /= 1024; tx_units = "MB"; }
            if (tx > 1024) { tx /= 1024; tx_units = "GB"; }
            printf("本月入站: %.2f %s\n本月出站: %.2f %s", rx, rx_units, tx, tx_units);
        }')

    current_time=$(date "+%Y-%m-%d %I:%M %p")
    swap_used=$(free -m | awk 'NR==3{print $3}')
    swap_total=$(free -m | awk 'NR==3{print $2}')

    if [ -z "$swap_total" ] || [ "$swap_total" -eq 0 ]; then
        swap_percentage=0
    else
        swap_percentage=$((swap_used * 100 / swap_total))
    fi
    swap_info="${swap_used:-0}MB/${swap_total:-0}MB (${swap_percentage}%)"
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
    echo -e "${purple}$monthly_output${re}"
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
    printf "${purple}singbox 状态: %s${re}\n\n" "$(to_chinese "$singbox_status")"
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
	printf "${purple}---Argo 状态: %s${re}\n" "$(to_chinese "$argo_status")"
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
				systemctl stop argo-watchdog &>/dev/null
                systemctl disable argo-watchdog &>/dev/null
                systemctl daemon-reload &>/dev/null 
				
			elif [[ $argo_auth =~ [A-Za-z0-9=]{120,250} ]]; then
                real_token=$(echo "$argo_auth" | grep -oE '[A-Za-z0-9=]{120,250}')        
                if command_exists rc-service 2>/dev/null; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $real_token 2>&1'\"" /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '$real_token' 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo
                sleep 1 
                change_argo_domain
                systemctl stop argo-watchdog &>/dev/null
                systemctl disable argo-watchdog &>/dev/null
                systemctl daemon-reload &>/dev/null  
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
			systemctl enable argo-watchdog &>/dev/null
            systemctl daemon-reload &>/dev/null 
            systemctl restart argo-watchdog &>/dev/null
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
   purple "=== 老王sing-box四合一安装脚本 0.2===\n"
   printf "${purple}---Argo 状态: %s${re}\n" "$(to_chinese "$argo_status")"
   printf "${purple}--Nginx 状态: %s${re}\n" "$(to_chinese "$nginx_status")"
   printf "${purple}singbox 状态: %s${re}\n\n" "$(to_chinese "$singbox_status")"
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
   red    "12. iptables"
   red    "13. 快捷指令"
   red    "14. 本机信息"
   echo  "==============="
   red "0. 退出脚本"
   echo "==========="
   reading "请输入选择(0-14): " choice
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
				install_argo_watchdog
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
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/sing.sh)
		   ;;
		9) manage_nodes_menu ;;
	    10) bbr_menu ;;
		11) update_script ;;
		12) iptables_ssl ;;
		13) 
           clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/aa.sh)
		   ;;
		14) vps_s ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 14" ;;
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
done
