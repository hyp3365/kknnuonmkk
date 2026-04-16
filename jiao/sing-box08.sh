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
  # 获取国家代码
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
    h2_reality=$(shuf -i 10000-60000 -n 1)
	socks_port=$(shuf -i 10000-60000 -n 1)
	http_port=$(shuf -i 10000-60000 -n 1)
	anytls_port=$(shuf -i 10000-60000 -n 1)
	grpc_reality=$(shuf -i 10000-60000 -n 1)
	vless_wstls_cdn_port=$(shuf -i 10000-60000 -n 1)
	vless_ws_cdn_port=$(shuf -i 10000-60000 -n 1)
	vmess_ws_cdn_port=$(shuf -i 10000-60000 -n 1)
	username=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 15)
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
    short_id=$(openssl rand -hex 6)
}


# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
export vless_port=${PORT:-$(shuf -i 1000-59000 -n 1)}
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
ip_address() {
    ipv4_address=$(curl -s -m 2 ipv4.ip.sb)
    ipv6_address=$(curl -s -m 2 ipv6.ip.sb)
}

# 80 端口申请模式
run_ssl_task() {
    local domain="$1"
    [[ -z "$domain" ]] && reading "请输入域名: " domain
    [[ -z "$domain" ]] && red "域名不能为空" && return 1
    manage_packages "install" "curl" "socat"
    if command -v ss >/dev/null 2>&1; then
        local occupant=$(ss -ntlp | grep ":80 " | awk -F'users:\\(\\("' '{print $2}' | awk -F'"' '{print $1}' | head -n1)
        [[ -n "$occupant" ]] && red "错误: 80 端口正被 [${occupant}] 占用" && return 1
    fi
    [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && skyblue "正在安装 acme.sh..." && curl -s https://get.acme.sh | sh >/dev/null 2>&1
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1    
    local save_path="/root/cert/${domain}"
    mkdir -p "$save_path"    
    skyblue "正在为 ${domain} 申请证书..."
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone --httpport 80 --force        
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
        red "申请失败，请检查域名解析和 80 端口"
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
    mkdir -p /etc/iptables
    for rule in "$@"; do
        p_port=${rule%/*}
        p_proto=${rule#*/}
        tag="ScriptManaged"
        [ ! -f /etc/iptables/rules.v4 ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null
        if [ -f /etc/iptables/rules.v4 ]; then
            if ! grep -q "\--dport $p_port " /etc/iptables/rules.v4 2>/dev/null; then
                sed -i "/\*filter/,/COMMIT/ { /COMMIT/ i -A INPUT -p $p_proto --dport $p_port -m comment --comment \"$tag\" -j ACCEPT
                }" /etc/iptables/rules.v4
            fi
        fi
        [ ! -f /etc/iptables/rules.v6 ] && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        if [ -f /etc/iptables/rules.v6 ]; then
            if ! grep -q "\--dport $p_port " /etc/iptables/rules.v6 2>/dev/null; then
                sed -i "/\*filter/,/COMMIT/ { /COMMIT/ i -A INPUT -p $p_proto --dport $p_port -m comment --comment \"$tag\" -j ACCEPT
                }" /etc/iptables/rules.v6
            fi
        fi
    done
    if command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1
    elif command_exists service; then
        service iptables save 2>/dev/null
        service ip6tables save 2>/dev/null
    fi
}

close_port() {
    mkdir -p /etc/iptables
    
    for rule in "$@"; do
        p_port=${rule%/*}
        if [ -f "/etc/iptables/rules.v4" ]; then
            sed -i -E "/--dport\s+$p_port(\s+|$)/d" /etc/iptables/rules.v4
        fi
        if [ -f "/etc/iptables/rules.v6" ]; then
            sed -i -E "/--dport\s+$p_port(\s+|$)/d" /etc/iptables/rules.v6
        fi
    done
    [ -f "/etc/iptables/rules.v4" ] && iptables-restore < /etc/iptables/rules.v4 2>/dev/null
    [ -f "/etc/iptables/rules.v6" ] && ip6tables-restore < /etc/iptables/rules.v6 2>/dev/null
    if command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1
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
    output=$(/etc/sing-box/sing-box generate reality-keypair)
	short_id=$(/etc/sing-box/sing-box generate rand --hex 6)
	username=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 15)
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
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
vless://${uuid}@${server_ip}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${isp}_vless-reality

vmess://$(echo "$VMESS"| base64 -w0)

hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=www.bing.com&insecure=1&alpn=h3&obfs=none#${isp}_hysteria2

tuic://${uuid}:${password}@${server_ip}:${tuic_port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${isp}_tuic

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
EOF
[[ -f "/etc/nginx/conf.d/s-sing-box.conf" ]] && cp /etc/nginx/conf.d/s-sing-box.conf /etc/nginx/conf.d/s-sing-box.conf.bak.sb
cat > /etc/nginx/conf.d/s-sing-box.conf << 'EOF'
upstream vmess_ws { 
    server 127.0.0.1:8002; 
    keepalive 1024; 
}
upstream vless_ws { 
    server 127.0.0.1:8003; 
    keepalive 1024; 
}

server {
    listen 127.0.0.1:8001 so_keepalive=on backlog=4096;
    server_name _;
    
    tcp_nodelay on;               
    proxy_buffering off;          
    proxy_request_buffering off;
    proxy_http_version 1.1;       
    
    proxy_connect_timeout 30s;    
    proxy_send_timeout 3600s;     
    proxy_read_timeout 3600s;
    
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

    # VMess WS
    location /mPaxe1996Ko-5203aap {
        proxy_pass http://vmess_ws;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # VLESS WS
    location /lPaxe1996Ko-5203aap {
        proxy_pass http://vless_ws;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location / { 
        access_log off;
        return 404; 
    }
    
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
					rm -f /etc/nginx/conf.d/s-sing-box.conf
                    rm -f /etc/nginx/conf.d/sing-box.conf.bak*
					rm -f /etc/nginx/conf.d/s-sing-box.conf.bak*
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
        if [ -x /usr/bin/sb ]; then
            green "\n快捷指令 sb 已创建\n"
        fi
    else
        red "\n本地化保存失败，请检查网络后重新运行\n"
        rm -f "$local_file" 
    fi
}
# 创建快捷指令远程
#create_shortcut() {
 # cat > "$work_dir/sb.sh" << EOF
#!/usr/bin/env bash
#bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/sing-box08.sh) \$1
#EOF
  #chmod +x "$work_dir/sb.sh"
  #ln -sf "$work_dir/sb.sh" /usr/bin/sb
  #if [ -s /usr/bin/sb ]; then
    #green "\n快捷指令 sb 创建成功\n"
  #else
    #red "\n快捷指令创建失败\n"
  #fi
#}

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
            purple "端口跳跃需确保跳跃区间的端口没有被占用，NAT机请注意可用端口范围。\n"
            local deps=("iptables" "curl" "shuf")
            for dep in "${deps[@]}"; do
                if ! command -v "$dep" &> /dev/null; then
                    yellow "检测到缺少依赖 $dep，正在安装..."
                    if [ -f /etc/debian_version ]; then
                        apt-get update && apt-get install -y "$dep"
                    elif [ -f /etc/redhat-release ]; then
                        yum install -y "$dep"
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
            listen_port=$(grep -A 15 '"tag": "hysteria2"' "$config_dir" | grep '"listen_port"' | head -n 1 | awk -F': ' '{print $2}' | tr -d ', ')
            if [ -z "$listen_port" ]; then
                red "无法自动获取 Hysteria2 监听端口，请检查配置文件！"
                exit 1
            fi
            purple "正在设置端口跳跃规则..."
            iptables -t nat -F PREROUTING > /dev/null 2>&1
            iptables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port
            
            if command -v ip6tables &> /dev/null; then
                ip6tables -t nat -F PREROUTING > /dev/null 2>&1
                ip6tables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port 2>/dev/null
            fi
            if command -v rc-service &> /dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                [ -x "$(command -v ip6tables)" ] && ip6tables-save > /etc/iptables/rules.v6
                cat << 'EOF' > /etc/init.d/iptables
#!/sbin/openrc-run
depend() { need net; }
start() {
    iptables-restore < /etc/iptables/rules.v4
    [ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6
}
EOF
                chmod +x /etc/init.d/iptables && rc-update add iptables default
            elif [ -f /etc/debian_version ]; then
                if ! dpkg -l | grep -q iptables-persistent; then
                    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
                fi
                netfilter-persistent save > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                yum install -y iptables-services
                systemctl enable iptables && service iptables save
                command -v ip6tables &> /dev/null && systemctl enable ip6tables && service ip6tables save
            fi
            restart_singbox
            ip=$(get_realip)
            uuid=$(grep -oP 'hysteria2://\K[^@]+' "$client_dir" | head -n 1)
            isp=$(curl -s --max-time 2 https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed 's/ /_/g' || echo "vps")
            sed -i "/hysteria2:/d" "$client_dir"
            echo "hysteria2://$uuid@$ip:$listen_port?peer=www.bing.com&insecure=1&alpn=h3&obfs=none&mport=$listen_port,$min_port-$max_port#$isp" >> "$client_dir"
            base64 -w0 "$client_dir" > /etc/sing-box/sub.txt         
            green "\nHysteria2 端口跳跃已开启！"
            purple "跳跃区间：$min_port-$max_port"
            ;;          
        5)  
            purple "正在清理端口跳跃规则..."
            iptables -t nat -F PREROUTING > /dev/null 2>&1
            if command -v ip6tables &> /dev/null; then
                ip6tables -t nat -F PREROUTING > /dev/null 2>&1
            fi
            if command_exists rc-service 2>/dev/null; then
                rc-update del iptables default > /dev/null 2>&1
                rm -f /etc/init.d/iptables 
            elif [ -f /etc/debian_version ]; then
                if command -v netfilter-persistent &> /dev/null; then
                    netfilter-persistent save > /dev/null 2>&1
                fi
            elif [ -f /etc/redhat-release ]; then
                if command -v service &> /dev/null; then
                    service iptables save > /dev/null 2>&1
                    command -v ip6tables &> /dev/null && service ip6tables save > /dev/null 2>&1
                fi
            fi
            if [ -f "/etc/sing-box/url.txt" ]; then
                sed -i '/hysteria2/s/&mport=[^#&]*//g' /etc/sing-box/url.txt
                base64 -w0 "/etc/sing-box/url.txt" > /etc/sing-box/sub.txt
            fi
            green "\n[✔] 端口跳跃已关闭"
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
	green "4. nginx配置"
    skyblue "------------"
    green "5. 关闭节点订阅"
    skyblue "------------"
    green "6. 开启节点订阅"
    skyblue "------------"
    green "7. 更换订阅端口"
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
        6)
                
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

        7)
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
            "socks5.json|socks5|4"
            "http.json|HTTP|5"
			"vless-ws-argo.json|vless-ws-argo|6"
			"vless-wstls-cdn.json|vless-ws-tls-cdn|7"
			"vless-ws-cdn.json|vless-ws-cdn|8"
			"vmess-ws-cdn.json|vmess-ws-cdn|9"
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
		echo -e "\033[31m 0. 返回上一级菜单\033[0m"
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
            4) yellow "正在配置 Socks5..."
                generate_vars
                server_ip=$(get_realip)
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
            5) 
			yellow "正在配置 HTTP 代理..."
            generate_vars
            server_ip=$(get_realip)
            cat > /etc/sing-box/http.json << EOF
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
			6) yellow "正在配置 vless-ws隧道..."
			generate_vars
            mkdir -p /etc/sing-box
            if [ -f "${work_dir}/url.txt" ]; then
                argodomain=$(grep "vmess://" "${work_dir}/url.txt" | while read -r line; do
                    encoded_part=$(echo "$line" | sed 's/vmess:\/\///' | cut -d'#' -f1)
                    decoded=$(echo "$encoded_part" | base64 -d 2>/dev/null)
                    if echo "$decoded" | grep -q "_vmess_ws_argo"; then
                        echo "$decoded" | grep -oE '"host":\s*"[^"]+"' | head -n 1 | cut -d'"' -f4
                        break
                    fi
                done)
            fi
            if [ -z "$argodomain" ] && [ -f "${work_dir}/argo.log" ]; then
                argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -n 1)
            fi   
            if [ -z "$argodomain" ]; then
                red "======================================================"
                red " 错误：无法获取任何 Argo 域名（固定或临时）！"
                red " 请检查隧道运行状态或 url.txt 记录。"
                red "======================================================"
                return 1
            fi
            cat > /etc/sing-box/vless-ws-argo.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-argo",
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
		allow_port "8003/tcp" "8003/udp" > /dev/null 2>&1
		node_remark="${isp}_vless_ws_argo"
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
		green " 节点如果不通 试着打开客服端ECH"
        green "==============================================="
        ;;
		7)
        check_and_issue_ssl || return 1
        generate_vars
        mkdir -p /etc/sing-box
        cat > /etc/sing-box/vless-wstls-cdn.json << EOF
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
			yellow " 节点如果不通 试着打开客服端ECH"
            green "--------------------------------------------------"
            ;;
			8) 
            generate_vars
            mkdir -p /etc/sing-box
            read -p '请输入域名 (例如: b.a.com): ' domain
            [ -z "$domain" ] && red "域名不能为空!" && return 1
            cat > /etc/sing-box/vless-ws-cdn.json << EOF
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
			yellow " 节点如果不通 试着打开客服端ECH"
            green "--------------------------------------------------"
            ;;
	      9)
            generate_vars
            mkdir -p /etc/sing-box
            read -p '请输入域名 (例如: b.a.com): ' domain
            [ -z "$domain" ] && red "域名不能为空!" && return 1
            cat > /etc/sing-box/vmess-ws-cdn.json << EOF
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
            yellow " 节点如果不通 试着打开客户端 ECH"
            green "--------------------------------------------------"
            ;;      
            # --- 完整的删除逻辑 ---
            51) 
			if [ -n "$h2_reality" ]; then
                close_port "${h2_reality}/tcp" "${h2_reality}/udp" > /dev/null 2>&1
            fi
			target="_vless_http_reality"
            target_conf="/etc/sing-box/h2-reality.json"
            if [ -f "$target_conf" ]; then
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
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
			if [ -n "$grpc_reality" ]; then
                close_port "${grpc_reality}/tcp" "${grpc_reality}/udp" > /dev/null 2>&1
            fi
            target="_vless_grpc_reality"
            target_conf="/etc/sing-box/grpc-reality.json"
            if [ -f "$target_conf" ]; then
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
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
			if [ -n "$anytls_port" ]; then
                close_port "${anytls_port}/tcp" "${anytls_port}/udp" > /dev/null 2>&1
            fi
			target="_anytls"
            target_conf="/etc/sing-box/anytls.json"
            if [ -f "$target_conf" ]; then
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
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
			if [ -n "$socks_port" ]; then
                close_port "${socks_port}/tcp" "${socks_port}/udp" > /dev/null 2>&1
            fi
			target="_socks5"
            target_conf="/etc/sing-box/socks5.json"
            if [ -f "$target_conf" ]; then
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
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
			if [ -n "$http_port" ]; then
                close_port "${http_port}/tcp" "${http_port}/udp" > /dev/null 2>&1
            fi
			target="_http"
            target_conf="/etc/sing-box/http.json"
            if [ -f "$target_conf" ]; then
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
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
			close_port "8003/tcp" "8003/udp" > /dev/null 2>&1
			target="_vless_ws_argo"
            target_conf="/etc/sing-box/vless-ws-argo.json"
            if [ -f "$target_conf" ]; then
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
					sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
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
			if [ -n "$vless_wstls_cdn_port" ]; then
                close_port "${vless_wstls_cdn_port}/tcp" "${vless_wstls_cdn_port}/udp" > /dev/null 2>&1
            fi
			target="_vless_wstls_cdn"
            target_conf="/etc/sing-box/vless-wstls-cdn.json"
            if [ -f "$target_conf" ]; then
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                     sed -i "/${target}/d" /etc/sing-box/url.txt
                     sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
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
			if [ -n "$vless_ws_cdn_port" ]; then
                close_port "${vless_ws_cdn_port}/tcp" "${vless_ws_cdn_port}/udp" > /dev/null 2>&1
            fi
			target="_vless_ws_cdn"
            target_conf="/etc/sing-box/vless-ws-cdn.json"
            if [ -f "$target_conf" ]; then
                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
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
			if [ -n "$vmess_ws_cdn_port" ]; then
                close_port "${vmess_ws_cdn_port}/tcp" "${vmess_ws_cdn_port}/udp" > /dev/null 2>&1
            fi
		    target="_vmess_ws_cdn"
            target_conf="/etc/sing-box/vmess-ws-cdn.json"
            if [ -f "$target_conf" ]; then
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


# BBR2管理
enable_bbr() {
    clear
    local script_path="./tcpx.sh"
    [[ ! -x "$(command -v wget)" ]] && apt-get update && apt-get install -y wget
    [[ ! -x "$(command -v lsmod)" ]] && apt-get update && apt-get install -y kmod

    if [ ! -f "$script_path" ]; then
        wget --no-check-certificate -O "$script_path" https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh
        chmod +x "$script_path"
    fi
    ./tcpx.sh
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

# 13. SSH
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
    if [ -f "$nginx_conf" ]; then
        server_ip=$(get_realip)
        lujing=$(sed -n 's|.*location = /\([^ ]*\).*|\1|p' "$nginx_conf")
        sub_port=$(sed -n 's/^\s*listen \([0-9]\+\);/\1/p' "$nginx_conf")      
        base64_url="http://${server_ip}:${sub_port}/${lujing}"        
        green "V2rayN,Shadowrocket,Nekobox,Loon,Karing,Stash订阅链接: ${purple}${base64_url}${re}\n"
    else
        # 文件不存在
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
   green  "10. BBR管理"
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
		8) 
           clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/aa.sh)
		   ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 15" ;;
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
done
