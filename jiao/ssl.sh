#!/bin/bash

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

# 检查 Root
[[ $EUID -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用 root 权限运行\n" && exit 1

# 1. 智能依赖检测与安装
check_dependencies() {
    local deps=("curl" "socat")
    local to_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            to_install+=("$dep")
        fi
    done

    if [ ${#to_install[@]} -ne 0 ]; then
        echo -e "${yellow}检测到缺少依赖: ${to_install[*]}，正在安装...${plain}"
        if command -v apt-get >/dev/null; then
            apt-get update && apt-get install -y "${to_install[@]}"
        elif command -v yum >/dev/null; then
            yum install -y "${to_install[@]}"
        fi
    else
        echo -e "${green}依赖检查通过 (curl/socat 已安装)${plain}"
    fi
}

# 2. 80 端口占用智能预检
check_port_80() {
    if command -v ss >/dev/null 2>&1; then
        local occupant=$(ss -ntlp | grep ':80 ' | awk -F'users:\\(\\("' '{print $2}' | awk -F'"' '{print $1}' | head -n1)
        if [ -n "$occupant" ]; then
            echo -e "${red}警告: 80 端口正被 [${occupant}] 占用！${plain}"
            echo -e "${yellow}建议执行: systemctl stop ${occupant} 后再试${plain}"
            return 1
        fi
    fi
    return 0
}

# 自动获取本机公网 IP
get_public_ip() {
    curl -s http://api4.ipify.org || curl -s http://ifconfig.me
}

# 安装 acme.sh
install_acme() {
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo -e "${green}正在安装 acme.sh 核心...${plain}"
        curl -s https://get.acme.sh | sh >/dev/null 2>&1
    fi
}

# 核心申请函数
issue_cert() {
    local target="$1"
    local is_ip_cert="$2"

    check_dependencies
    install_acme
    
    local certPath="/root/cert/${target}"
    [[ "$is_ip_cert" == "true" ]] && certPath="/root/cert/ip"
    mkdir -p "$certPath"
    
    echo -e "${blue}正在为 ${target} 申请证书 (通过 80 端口验证)...${plain}"
    
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    
    local cmd="~/.acme.sh/acme.sh --issue -d ${target} --standalone --httpport 80 --force"
    [[ "$is_ip_cert" == "true" ]] && cmd="$cmd --certificate-profile shortlived --days 6"

    eval "$cmd"
    
    if [ $? -eq 0 ]; then
        ~/.acme.sh/acme.sh --installcert -d "${target}" \
            --key-file "${certPath}/privkey.pem" \
            --fullchain-file "${certPath}/fullchain.pem"
        
        chmod 600 "${certPath}/privkey.pem"
        echo -e "${green}申请成功！文件已存至: ${certPath}${plain}"
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    else
        echo -e "${red}申请失败。请确保防火墙已开启 80 端口入站规则。${plain}"
    fi
}

# 主界面
clear
echo -e "${blue}=== 智能 SSL 证书管理工具 ===${plain}"
echo -e "1. 申请域名 SSL 证书 (90天)"
echo -e "2. 申请本机 IP SSL 证书 (6天/自动续期)"
read -rp "请选择: " choice

case $choice in
    1)
        read -rp "请输入你的域名: " domain
        if [[ -n "$domain" ]]; then
            check_port_80
            # 无论检查结果如何，都尝试申请，但上面的提示会告知用户原因
            issue_cert "$domain" "false"
        fi
        ;;
    2)
        myip=$(get_public_ip)
        echo -e "${green}检测到本机 IP: $myip${plain}"
        check_port_80
        issue_cert "$myip" "true"
        ;;
    *)
        echo "退出"
        ;;
esac
