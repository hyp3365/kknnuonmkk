#!/bin/bash

# --- 1. 定义颜色代码 ---
re='\033[0m'
red='\033[0;31m'
green='\033[0;32m'
purple='\033[0;35m'

# --- 2. 定义基础函数 ---
green() { echo -e "${green}$1${re}"; }
purple() { echo -e "${purple}$1${re}"; }
red() { echo -e "${red}$1${re}"; }
reading() { read -p "$(echo -e "${green}$1${re}")" "$2"; }

# --- 3. 定义功能函数 (必须放在主循环之前) ---
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

# --- 4. 主菜单与逻辑循环 ---
while true; do
   clear
   echo ""
   green "1. 增加虚拟内存"
   echo  "==============="
   red "0. 退出脚本"
   echo "==========="
   reading "请输入选择(0-1): " choice
   echo ""

   case $choice in
        1)
            add_swap
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

