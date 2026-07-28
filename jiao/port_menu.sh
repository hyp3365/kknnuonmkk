#!/bin/bash

# =============================
# 端口网速与流量限制管理
# =============================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

CONF_DIR="/etc/port_manager"
SCRIPT_PATH=$(readlink -f "$0")

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m[-] 错误: 请使用 root (sudo) 权限运行此脚本\033[0m"
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

check_and_block() {
    local CURRENT_MONTH=$(date +%Y%m)
    
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local PORT=$(basename "$conf" .conf)
        source "$conf"
        
        local CHAIN_NAME="LIMIT_P_${PORT}"
        
        if [ "$RESET_MODE" == "MONTHLY" ] && [ "$CURRENT_MONTH" != "$LAST_RESET_MONTH" ]; then
            iptables -F "$CHAIN_NAME" 2>/dev/null
            iptables -A "$CHAIN_NAME" -j ACCEPT 2>/dev/null
            
            sed -i "s/LAST_RESET_MONTH=.*/LAST_RESET_MONTH=\"$CURRENT_MONTH\"/" "$conf"
            
            continue
        fi
        
        if [ "$QUOTA" == "UNLIMITED" ]; then
            continue
        fi
        
        local BYTES=$(iptables -L "$CHAIN_NAME" -v -x 2>/dev/null | awk 'NR>2 {sum+=$2} END {print sum + 0}')
        local MB=$(awk "BEGIN {print $BYTES / 1048576}")
        
        local EXCEEDED=$(awk "BEGIN {print ($MB >= $QUOTA) ? 1 : 0}")
        if [ "$EXCEEDED" -eq 1 ]; then
            if ! iptables -L "$CHAIN_NAME" -v -n 2>/dev/null | grep -q "DROP"; then
                iptables -I "$CHAIN_NAME" 1 -j DROP
            fi
        fi
    done
}

if [ "$1" == "cron" ]; then
    check_and_block
    exit 0
fi

install_cron() {
    (crontab -l 2>/dev/null | grep -v "port_menu" | grep -v "port_quota") | crontab -
    (
        crontab -l 2>/dev/null
        echo "* * * * * /bin/bash $SCRIPT_PATH cron >/dev/null 2>&1"
        echo "* * * * * sleep 30; /bin/bash $SCRIPT_PATH cron >/dev/null 2>&1"
    ) | crontab -
}
install_cron

rebuild_tc_filters() {
    tc filter del dev "$INTERFACE" parent 1:0 prio 1 2>/dev/null
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local p=$(basename "$conf" .conf)
        source "$conf"
        
        if [ "$RATE" != "UNLIMITED" ]; then
            local HEX=$(printf "%x" "$p")
            tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip dport "$p" 0xffff flowid 1:$HEX
            tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip sport "$p" 0xffff flowid 1:$HEX
        fi
    done
}

apply_limit() {
    local p=$1
    local r=$2
    local q=$3
    local rm=$4
    local lm=$(date +%Y%m)
    local HEX=$(printf "%x" "$p")
    local CHAIN_NAME="LIMIT_P_${p}"

    echo -e "RATE=\"$r\"\nQUOTA=\"$q\"\nRESET_MODE=\"$rm\"\nLAST_RESET_MONTH=\"$lm\"" > "$CONF_DIR/${p}.conf"

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

    iptables -N "$CHAIN_NAME" 2>/dev/null || true
    iptables -F "$CHAIN_NAME"
    iptables -A "$CHAIN_NAME" -j ACCEPT

    iptables -D INPUT -p tcp --dport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D INPUT -p udp --dport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D OUTPUT -p udp --sport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D FORWARD -p tcp --dport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D FORWARD -p udp --dport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D FORWARD -p tcp --sport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D FORWARD -p udp --sport "$p" -j "$CHAIN_NAME" 2>/dev/null || true

    iptables -I INPUT 1 -p tcp --dport "$p" -j "$CHAIN_NAME"
    iptables -I INPUT 1 -p udp --dport "$p" -j "$CHAIN_NAME"
    iptables -I OUTPUT 1 -p tcp --sport "$p" -j "$CHAIN_NAME"
    iptables -I OUTPUT 1 -p udp --sport "$p" -j "$CHAIN_NAME"
    iptables -I FORWARD 1 -p tcp --dport "$p" -j "$CHAIN_NAME"
    iptables -I FORWARD 1 -p udp --dport "$p" -j "$CHAIN_NAME"
    iptables -I FORWARD 1 -p tcp --sport "$p" -j "$CHAIN_NAME"
    iptables -I FORWARD 1 -p udp --sport "$p" -j "$CHAIN_NAME"
}

remove_limit() {
    local p=$1
    local HEX=$(printf "%x" "$p")
    local CHAIN_NAME="LIMIT_P_${p}"

    tc class del dev "$INTERFACE" classid 1:$HEX 2>/dev/null
    rm -f "$CONF_DIR/${p}.conf"
    rebuild_tc_filters

    iptables -D INPUT -p tcp --dport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D INPUT -p udp --dport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D OUTPUT -p udp --sport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D FORWARD -p tcp --dport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D FORWARD -p udp --dport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D FORWARD -p tcp --sport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D FORWARD -p udp --sport "$p" -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -X "$CHAIN_NAME" 2>/dev/null || true
}

show_ports() {
    check_and_block

    echo -e "\033[36m当前网卡: $INTERFACE\033[0m"
    echo "------------------------------------------------"
    printf " %-6s | %-8s | %-8s | %-8s | %-8s | %b\n" "端口" "流量" "网速" "已用" "周期" "状态"
    echo "------------------------------------------------"
    
    local count=0
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        count=$((count+1))
        local PORT=$(basename "$conf" .conf)
        source "$conf"
        
        local CHAIN_NAME="LIMIT_P_${PORT}"
        local COLOR_STATUS="\033[32m正常\033[0m"
        local USED_MB="0.00"
        
        if iptables -L "$CHAIN_NAME" -v -x &> /dev/null; then
            local BYTES=$(iptables -L "$CHAIN_NAME" -v -x | awk 'NR>2 {sum+=$2} END {print sum + 0}')
            USED_MB=$(awk "BEGIN {printf \"%.2f\", $BYTES / 1048576}")
            if iptables -L "$CHAIN_NAME" -v -n | grep -q "DROP"; then
                COLOR_STATUS="\033[31m阻断\033[0m"
            fi
        fi
        
        local Q_DISP="无限制"
        [ "$QUOTA" != "UNLIMITED" ] && Q_DISP="${QUOTA}MB"
        
        local R_DISP="无限制"
        [ "$RATE" != "UNLIMITED" ] && R_DISP="${RATE/mbit/Mbps}"

        local M_DISP="一次性"
        [ "$RESET_MODE" == "MONTHLY" ] && M_DISP="每月"
        
        printf " %-6s | %-8s | %-8s | %-8s | %-8s | %b\n" "$PORT" "$Q_DISP" "$R_DISP" "${USED_MB}MB" "$M_DISP" "$COLOR_STATUS"
    done
    
    if [ "$count" -eq 0 ]; then
        echo -e "                   \033[33m当前暂未设置任何端口限制\033[0m"
    fi
    echo "-------------------------------------------------"
}

while true; do
    clear
    echo "============================================"
    echo "               端口网速与流量限制管理"
    echo "============================================"
    echo "  1. 新增 端口限制"
    echo "  2. 修改 端口限制 (会清零当前已用流量)"
    echo "  3. 删除 端口限制"
    echo "  4. 退出 脚本"
    echo "============================================"
    echo -e "已设置的端口:\n"
    show_ports
    
    read -p "请输入选项 [1-4]: " choice
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

            # 新增：询问是否按月重置
            echo -e "\n\033[36m>>> 直接按回车默认为一次性限制 <<<\033[0m"
            read -p "是否按月自动重置流量？(输入 y 开启): " is_monthly
            if [[ "$is_monthly" == "y" || "$is_monthly" == "Y" ]]; then
                reset_mode="MONTHLY"
                echo -e " -> \033[32m已设为: 每月重置\033[0m"
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
        4)
            echo -e "\033[32m退出脚本。后台 30 秒轮询与跨月监控运行中。\033[0m"
            exit 0
            ;;
        *)
            echo "无效选项，请重新输入。"
            sleep 1
            ;;
    esac
done
