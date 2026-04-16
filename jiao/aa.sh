#!/bin/bash

# --- 定义颜色代码 ---
re='\033[0m'
red='\033[1;31m'
green='\033[1;32m'
purple='\033[1;35m'

# --- 定义基础函数 ---
green() { echo -e "${green}$1${re}"; }
purple() { echo -e "${purple}$1${re}"; }
red() { echo -e "${red}$1${re}"; }
reading() { read -p "$(echo -e "${green}$1${re}")" "$2"; }

ip_address() {
    ipv4_address=$(curl -s -m 2 ipv4.ip.sb)
    ipv6_address=$(curl -s -m 2 ipv6.ip.sb)
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


# --- 主菜单与逻辑循环 ---
while true; do
   clear
   echo ""
   green "1. 虚拟内存"
   green "2. 系统清理"
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

