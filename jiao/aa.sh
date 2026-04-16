#!/bin/bash

# --- 定义颜色代码 ---
re='\033[0m'
red='\033[1;31m'
green='\033[1;32m'
yellow='\033[1;33m'  
purple='\033[1;35m'

# --- 定义颜色打印函数 ---
green() { echo -e "${green}$1${re}"; }
purple() { echo -e "${purple}$1${re}"; }
red() { echo -e "${red}$1${re}"; }
yellow() { echo -e "${yellow}$1${re}"; } 
reading() { read -p "$(echo -e "${green}$1${re}")" "$2"; }

ip_address() {
    ipv4_address=$(curl -s -m 2 ipv4.ip.sb)
    ipv6_address=$(curl -s -m 2 ipv6.ip.sb)
}

manage_packages() {
    local action=$1
    shift
    if command -v apt >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    else
        red "未检测到支持的包管理器，请手动安装依赖。"
        return 1
    fi
    for package in "$@"; do
        if [ "$action" = "install" ]; then
            if command -v "$package" >/dev/null 2>&1; then
                continue
            fi      
            yellow "正在安装依赖: ${package}..."
            case "$PKG_MGR" in
                apt)
                    apt update -y >/dev/null 2>&1
                    apt install -y "$package" >/dev/null 2>&1
                    ;;
                dnf|yum)
                    $PKG_MGR install -y "$package" >/dev/null 2>&1
                    ;;
                apk)
                    apk add "$package" >/dev/null 2>&1
                    ;;
            esac
        fi
    done
    return 0
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

add_swap() {
    clear
    purple "=== 虚拟内存 (Swap) ==="
    echo ""
    current_swap=$(free -m | awk '/Swap/ {print $2}')
    green "当前系统 Swap 容量: ${current_swap}MB"
    echo ""
    reading "请输入需要设置的 Swap 大小 (单位 MB): " swap_size
    if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
        red "错误: 请输入有效的数字！"
        sleep 2
        return
    fi
    
    echo "正在处理中..."
    swapoff -a >/dev/null 2>&1
    rm -f /swapfile
    
    if ! fallocate -l ${swap_size}M /swapfile; then
        dd if=/dev/zero of=/swapfile bs=1M count=$swap_size status=progress
    fi
    
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    
    echo ""
    green "设置成功！当前系统内存状态："
    free -h
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}

clean_system() {
    clear
    purple "=== 系统清理 ==="
    echo ""
    yellow "正在识别系统包管理器并清理，请稍候..."
    echo ""
    green "1. 正在清理系统日志 (Journal)..."
    journalctl --vacuum-time=1s >/dev/null 2>&1
    journalctl --vacuum-size=50M >/dev/null 2>&1
    if command -v apt &>/dev/null; then
        green "2. 正在清理 Debian/Ubuntu 冗余组件..."
        apt autoremove --purge -y >/dev/null 2>&1
        apt clean -y >/dev/null 2>&1
        apt autoclean -y >/dev/null 2>&1
        apt remove --purge $(dpkg -l | awk '/^rc/ {print $2}') -y >/dev/null 2>&1
        green "3. 正在移除旧内核..."
        apt remove --purge $(dpkg -l | awk '/^ii linux-(image|headers)-[^ ]+/{print $2}' | grep -v $(uname -r | sed 's/-.*//') | xargs) -y >/dev/null 2>&1

    elif command -v yum &>/dev/null; then
        green "2. 正在清理 CentOS/RHEL 冗余组件..."
        yum autoremove -y >/dev/null 2>&1
        yum clean all >/dev/null 2>&1
        green "3. 正在移除旧内核..."
        yum remove $(rpm -q kernel | grep -v $(uname -r)) -y >/dev/null 2>&1

    elif command -v dnf &>/dev/null; then
        green "2. 正在清理 Fedora/New CentOS 冗余组件..."
        dnf autoremove -y >/dev/null 2>&1
        dnf clean all >/dev/null 2>&1
        green "3. 正在移除旧内核..."
        dnf remove $(rpm -q kernel | grep -v $(uname -r)) -y >/dev/null 2>&1

    elif command -v apk &>/dev/null; then
        green "2. 正在清理 Alpine 冗余组件..."
        apk autoremove -y >/dev/null 2>&1
        apk clean >/dev/null 2>&1
        green "3. 正在移除旧内核..."
        apk del $(apk info -vv | grep -E 'linux-[0-9]' | grep -v $(uname -r) | awk '{print $1}') -y >/dev/null 2>&1
    else
        red "未检测到支持的包管理器，清理跳过。"
    fi

    echo ""
    green "系统清理完成！"
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}
#s-ui面板
sui_panel_menu() {
    while true; do
        clear
        purple "=== sui 面板==="
        echo "--------------"
        green  "1. 安装 sui 面板"
        red    "2. 卸载 sui 面板"
        echo "--------------"
        purple "0. 返回上一级菜单"
        reading "请输入选择 [0-2]: " sub_choice
		case $sub_choice in
                  1)
                    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
                    read -n 1 -s -r -p "按任意键继续..."
					;;
                  2)
                    systemctl disable sing-box --now
                    systemctl disable s-ui --now

                    rm -f /etc/systemd/system/s-ui.service
                    systemctl daemon-reload

                    rm -fr /usr/local/s-ui
                    clear
                    echo -e "${green}sui面板已卸载${re}"
                    break_end
                    ;;
            0) break ;;
        esac
    done
}

# 3x-ui面板
xui_panel_menu() {
    while true; do
        clear
        purple "=== 3x-ui 面板 ==="
        echo "--------------"
        green  "1. 安装 3x-ui "
        red    "2. 卸载 3x-ui "
        echo "--------------"
        purple "0. 返回上一级菜单"
        echo "--------------"
        reading "请输入选择 [0-2]: " sub_choice
        case $sub_choice in
            1)
                yellow "正在获取 3x-ui 安装脚本..."
                bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
                echo ""
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            2)
                yellow "正在卸载 3x-ui 并清理所有数据..."
                systemctl stop x-ui >/dev/null 2>&1
                systemctl disable x-ui >/dev/null 2>&1
                rm -f /etc/systemd/system/x-ui.service
                systemctl daemon-reload
                rm -rf /usr/local/x-ui
                rm -f /usr/bin/x-ui

                clear
                green "3x-ui 面板已卸载。"
                sleep 2
                break # 卸载完成返回上一级
                ;;
            0) 
                break 
                ;;
            *)
                red "无效输入，请输入 0-2"
                sleep 1
                ;;
        esac
    done
}

cloudreve_menu() {
    while true; do
        clear
        purple "=== Cloudreve 云盘 ==="
        echo "--------------"
        green  "1. 安装 Cloudreve "
		green  "2. 配置域名访问 "
        red    "3. 卸载 Cloudreve "
        echo "--------------"
        purple "0. 返回上一级菜单"
        reading "请输入选择 [0-2]: " cr_choice
        case $cr_choice in
            1)
                yellow "正在获取最新版本号..."
                new_version=$(curl -s https://api.github.com/repos/cloudreve/Cloudreve/releases/latest | grep tag_name | cut -d '"' -f 4)               
                if [ -z "$new_version" ]; then
                    red "获取版本号失败，请检查网络！"
                    sleep 2 ; break
                fi             
                arch=$(uname -m)
                [[ "$arch" == "x86_64" ]] && pkg="cloudreve_${new_version}_linux_amd64.tar.gz"
                [[ "$arch" == "aarch64" ]] && pkg="cloudreve_${new_version}_linux_arm64.tar.gz"
                mkdir -p /usr/local/cloudreve
                cd /usr/local/cloudreve             
                yellow "正在下载并解压 ${new_version}..."
                wget -q --show-progress "https://github.com/cloudreve/Cloudreve/releases/download/${new_version}/${pkg}"
                tar -zxf ${pkg} && chmod +x cloudreve
                rm -f ${pkg}
                cat > /etc/systemd/system/cloudreve.service <<EOF
[Unit]
Description=Cloudreve
After=network.target

[Service]
WorkingDirectory=/usr/local/cloudreve
ExecStart=/usr/local/cloudreve/cloudreve
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable cloudreve --now >/dev/null 2>&1            
                clear
                green "Cloudreve 安装并启动成功！"
                echo "------------------------------------------------"
                green "访问地址: http://$(curl -s ipv4.icanhazip.com):5212"
                echo "------------------------------------------------"
                read -n 1 -s -r -p "按任意键返回菜单..."
                ;;
			2)
                clear
                purple "=== 配置 Cloudreve 域名及 SSL === "
                yellow "注意：请确保域名已解析到此 IP！"
                echo ""
                check_and_issue_ssl
                if [ $? -ne 0 ]; then
                    red "证书申请环节出错，无法继续配置 HTTPS。"
                    sleep 2 ; continue
                fi               
                domain_name="$domain"
                if ! command -v nginx &>/dev/null; then
                    yellow "正在安装 Nginx..."
                    manage_packages "install" "nginx"
                fi
                local conf_file="/etc/nginx/conf.d/cloudreve.conf"
                if [ -d "/etc/nginx/sites-available" ]; then
                    conf_file="/etc/nginx/sites-available/cloudreve.conf"
                    local symlink="/etc/nginx/sites-enabled/cloudreve.conf"
                fi
                cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name $domain_name;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain_name;

    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:5212;

        client_max_body_size 1024m;
    }
}
EOF
                if [ -n "$symlink" ]; then
                    ln -sf "$conf_file" "$symlink"
                fi
                yellow "正在校验 Nginx 配置并重启..."
                if nginx -t >/dev/null 2>&1; then
                    systemctl restart nginx
                    green "HTTPS 域名访问配置成功！"
                    echo "------------------------------------------------"
                    green "访问地址: https://$domain_name"
                    echo "------------------------------------------------"
                else
                    red "Nginx 配置检测失败，请检查端口占用或配置文件。"
                fi
                read -n 1 -s -r -p "按任意键返回菜单..."
                ;;
            3)
                yellow "正在卸载并清理所有数据..."
                systemctl disable cloudreve --now >/dev/null 2>&1
                rm -f /etc/systemd/system/cloudreve.service
                systemctl daemon-reload
                rm -f /etc/nginx/sites-available/cloudreve.conf
                rm -f /etc/nginx/sites-enabled/cloudreve.conf
                rm -f /etc/nginx/conf.d/cloudreve.conf
                if nginx -t >/dev/null 2>&1; then
                    systemctl restart nginx >/dev/null 2>&1
                fi
                rm -rf /usr/local/cloudreve                     
                green "Cloudreve 已卸载"
                sleep 2
                break 
                ;;
            0) break ;;
        esac
    done
}


# --- 主菜单与逻辑循环 ---
while true; do
   clear
   echo ""
   green "1. 虚拟内存"
   green "2. 系统清理"
   green "3. S-UI面板"
   green "4. 3X-UI面板"
   green "5. Cloudreve云盘"
   echo  "==============="
   red "0. 退出脚本"
   echo "==========="
   reading "请输入选择(0-1): " choice
   echo ""

   case $choice in
        1)
            add_swap
            ;;
        2)
            clean_system
            ;;
        3)
            sui_panel_menu
            ;;
		4)
            xui_panel_menu
            ;;
        5)
            cloudreve_menu
            ;;
        0)
            echo "退出脚本"
            exit 0
            ;;
        *)
            red "请输入正确的数字"
            sleep 1
            ;;
   esac
done

