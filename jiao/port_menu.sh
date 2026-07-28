#!/bin/bash

# ==========================================
# 端口网速与流量限制
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

CONF_DIR="/etc/port_manager"
TARGET_PATH="/usr/local/bin/port_menu.sh"

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

# ==========================================
# 获取当前北京时间辅助函数
# ==========================================
get_bj_time() {
    # 输出格式: YYYY MM DD HH MM (全部基于北京时间)
    TZ='Asia/Shanghai' date "+%Y %m %d %H %M"
}

# ==========================================
# 核心阻断与流量持久化统计逻辑
# ==========================================
check_and_block() {
    # 获取北京时间的年、月、日、时、分
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
        
        # 每月重置判断：北京时间每月 1 号 00 点 01 分及以后，且当月还没重置过
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
                iptables -F "$CHAIN_NAME" 2>/dev/null
                iptables -A "$CHAIN_NAME" -j ACCEPT 2>/dev/null
                STORED_TOTAL=0
                LAST_IPT_BYTES=0
                sed -i "s/LAST_RESET_MONTH=.*/LAST_RESET_MONTH=\"$CURRENT_MONTH_STR\"/" "$conf"
                sed -i "s/STORED_TOTAL=.*/STORED_TOTAL=\"0\"/" "$conf"
                sed -i "s/LAST_IPT_BYTES=.*/LAST_IPT_BYTES=\"0\"/" "$conf"
                continue
            fi
        fi
        
        local IPT_BYTES=$(iptables -L "$CHAIN_NAME" -v -x 2>/dev/null | awk 'NR>2 {sum+=$2} END {print sum + 0}')
        
        local DIFF=0
        if [ "$IPT_BYTES" -ge "$LAST_IPT_BYTES" ]; then
            DIFF=$(( IPT_BYTES - LAST_IPT_BYTES ))
        else
            DIFF="$IPT_BYTES"
        fi
        
        STORED_TOTAL=$(( STORED_TOTAL + DIFF ))
        LAST_IPT_BYTES="$IPT_BYTES"
        
        sed -i "s/STORED_TOTAL=.*/STORED_TOTAL=\"$STORED_TOTAL\"/" "$conf"
        sed -i "s/LAST_IPT_BYTES=.*/LAST_IPT_BYTES=\"$LAST_IPT_BYTES\"/" "$conf"

        if [ "$QUOTA" == "UNLIMITED" ]; then
            continue
        fi
        
        local LIMIT_BYTES=$(( QUOTA * 1048576 ))
        if [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ]; then
            if ! iptables -L "$CHAIN_NAME" -v -n 2>/dev/null | grep -q "DROP"; then
                iptables -I "$CHAIN_NAME" 1 -j DROP 2>/dev/null || true
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
    modprobe ip_tables 2>/dev/null || true
    modprobe iptable_filter 2>/dev/null || true
    
    while [ -z "$INTERFACE" ]; do
        sleep 2
        INTERFACE=$(get_interface)
    done

    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30 2>/dev/null
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate 1000mbit 2>/dev/null
    tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit 2>/dev/null

    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local p=$(basename "$conf" .conf)
        source "$conf"
        local HEX=$(printf "%x" "$p")
        local CHAIN_NAME="LIMIT_P_${p}"

        if [ "$RATE" != "UNLIMITED" ]; then
            tc class add dev "$INTERFACE" parent 1:1 classid 1:$HEX htb rate "$RATE" ceil "$RATE" 2>/dev/null || true
        fi

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

        if [ "$QUOTA" != "UNLIMITED" ]; then
            local LIMIT_BYTES=$(( QUOTA * 1048576 ))
            if [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ]; then
                iptables -I "$CHAIN_NAME" 1 -j DROP 2>/dev/null || true
            fi
        fi
    done
    rebuild_tc_filters
}

# ==========================================
# 后台守护进程逻辑
# ==========================================
if [ "$1" == "daemon" ]; then
    restore_rules_func
    while true; do
        check_and_block
        sleep 3
    done
    exit 0
fi

# ==========================================
# 服务安装与自我更新逻辑
# ==========================================
install_systemd_service() {
    if [ "$(realpath "$0")" != "$(realpath "$TARGET_PATH")" ]; then
        cp -f "$0" "$TARGET_PATH"
        chmod +x "$TARGET_PATH"
    fi

    local SERVICE_FILE="/etc/systemd/system/port_manager.service"
    
    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Port Traffic Manager Background Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $TARGET_PATH daemon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable port_manager.service >/dev/null 2>&1
    systemctl restart port_manager.service >/dev/null 2>&1
}
install_systemd_service

# ==========================================
# 菜单操作逻辑
# ==========================================
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
    echo "------------------------------------------"
    printf " %-6s | %-8s | %-8s | %-8s | %-8s | %b\n" "端口" "流量上限" "网速上限" "已用流量" "周期" "状态"
    echo "------------------------------------------"
    
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
            local LIVE_BYTES=$(iptables -L "$CHAIN_NAME" -v -x 2>/dev/null | awk 'NR>2 {sum+=$2} END {print sum + 0}')
            [ "$LIVE_BYTES" -gt 0 ] && STORED_TOTAL="$LIVE_BYTES"
        fi
        
        local USED_MB=$(awk "BEGIN {printf \"%.2f\", $STORED_TOTAL / 1048576}")
        
        local is_dropped=0
        if iptables -L "$CHAIN_NAME" -v -n 2>/dev/null | grep -q "DROP"; then
            is_dropped=1
        elif [ "$QUOTA" != "UNLIMITED" ]; then
            local LIMIT_BYTES=$(( QUOTA * 1048576 ))
            [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ] && is_dropped=1
        fi

        if [ "$is_dropped" -eq 1 ]; then
            COLOR_STATUS="\033[31m阻断\033[0m"
            if ! iptables -L "$CHAIN_NAME" -v -n 2>/dev/null | grep -q "DROP"; then
                iptables -I "$CHAIN_NAME" 1 -j DROP 2>/dev/null || true
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
    echo "------------------------------------------"
}

while true; do
    clear
    echo "=========================================="
    echo "         端口网速与流量限制c"
    echo "=========================================="
    echo "  1. 新增 端口限制"
    echo "  2. 修改 端口限制 (会清零当前已用流量)"
    echo "  3. 删除 端口限制"
    echo "  0. 退出 脚本"
    echo "=========================================="
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
            echo -e "\033[32m退出脚本。\033[0m"
            exit 0
            ;;
        *)
            echo "无效选项，请重新输入。"
            sleep 1
            ;;
    esac
done
