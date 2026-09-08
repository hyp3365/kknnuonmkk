#!/bin/bash
# ==========================================
# HE IPv6 隧道脚本 (Netplan 独占持久版)
# ==========================================
NETPLAN_FILE="/etc/netplan/99-he-tunnel.yaml"
CONFIG_RECORD="/etc/he-ipv6.conf"
LIST_FILE="/etc/he-ipv6-ips.list"
IFACE="he-ipv6"
PUBLIC_V4=""
OUTBOUND_FILE="/etc/sing-box/conf/outbounds.json"
ROUTE_FILE="/etc/sing-box/conf/route.json"

# 检查 Root 权限
[ "$(id -u)" != "0" ] && echo "错误: 请使用 root 权限运行此脚本！" && exit 1

install_dep(){
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install curl iproute2 gawk jq netplan.io -y
    fi

    if ! command -v netplan >/dev/null 2>&1; then
        echo "错误: 未检测到 Netplan 环境，请确认当前系统支持 Netplan！"
        exit 1
    fi
}

list_ipv6(){
    if [ -f "$LIST_FILE" ] && [ -s "$LIST_FILE" ]; then
        awk '{print NR". "$0}' "$LIST_FILE"
    else
        echo "无附加记录"
    fi
}

detect_public_ipv4(){
    echo "正在检测本机公网 IPv4..."
    PUBLIC_V4=$(curl -4 -s --connect-timeout 5 https://ip.sb || \
                curl -4 -s --connect-timeout 5 https://api.ipify.org || \
                curl -4 -s --connect-timeout 5 https://ifconfig.me)
    
    PUBLIC_V4=$(echo "$PUBLIC_V4" | tr -d '[:space:]')
    
    if [ -z "$PUBLIC_V4" ]; then
        echo "警告: 无法自动获取公网 IPv4"
        read -p "请手动输入本机的公网 IPv4 地址: " PUBLIC_V4
        if [ -z "$PUBLIC_V4" ]; then
            echo "错误: 未提供有效的 IPv4 地址！"
            exit 1
        fi
    else
        echo "检测到公网 IPv4: $PUBLIC_V4"
    fi
}

add_singbox_outbound(){
    [ ! -f "$OUTBOUND_FILE" ] && return
    local IP="$1"
    local NUM
    NUM=$(jq -r '
        .outbounds[]?
        | select(.tag|startswith("he-ipv6-"))
        | .tag
        | sub("he-ipv6-";"")
    ' "$OUTBOUND_FILE" 2>/dev/null | sort -n | tail -1)
    if [ -z "$NUM" ]; then
        NUM=1
    else
        NUM=$((NUM+1))
    fi
    local TAG="he-ipv6-$NUM"
    TMP_JSON=$(mktemp)
    jq \
    --arg tag "$TAG" \
    --arg ip "$IP" \
    '
    .outbounds += [{
        "type":"direct",
        "tag":$tag,
        "bind_interface":"he-ipv6",
        "inet6_bind_address":$ip
    }]
    ' "$OUTBOUND_FILE" > "$TMP_JSON"
    mv "$TMP_JSON" "$OUTBOUND_FILE"
    echo "sing-box 出站添加成功: tag [$TAG] -> $IP"
}

delete_singbox_route(){
    [ ! -f "$ROUTE_FILE" ] && return
    local TAG="$1"
    TMP_JSON=$(mktemp)
    jq \
    --arg tag "$TAG" \
    '
    .route.rules |= map(
        select(
            .outbound != $tag
        )
    )
    ' "$ROUTE_FILE" > "$TMP_JSON"
    mv "$TMP_JSON" "$ROUTE_FILE"
    echo "sing-box 路由规则已清除: outbound [$TAG]"
}

delete_singbox_outbound(){
    [ ! -f "$OUTBOUND_FILE" ] && return
    local IP="$1"
    TAG=$(jq -r \
    --arg ip "$IP" '
    .outbounds[]?
    | select(.inet6_bind_address==$ip)
    | .tag
    ' "$OUTBOUND_FILE")
    [ -z "$TAG" ] && return
    TMP_JSON=$(mktemp)
    jq \
    --arg ip "$IP" \
    '
    .outbounds |= map(
        select(.inet6_bind_address != $ip)
    )
    ' "$OUTBOUND_FILE" > "$TMP_JSON"
    mv "$TMP_JSON" "$OUTBOUND_FILE"
    echo "sing-box 出站已删除: $TAG"
    delete_singbox_route "$TAG"
    if systemctl is-active sing-box >/dev/null 2>&1; then
        systemctl restart sing-box
    fi
}

load_record(){
    if [ -f "$CONFIG_RECORD" ]; then
        source "$CONFIG_RECORD"
    fi
}

setup_systemd_restore(){
    cat > /usr/local/bin/he-ipv6-restore << 'EOF'
#!/bin/bash
LIST_FILE="/etc/he-ipv6-ips.list"
[ -f "$LIST_FILE" ] || exit 0
while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    ip -6 addr add "$ip/128" dev lo 2>/dev/null || true
done < "$LIST_FILE"
EOF
    chmod +x /usr/local/bin/he-ipv6-restore

    cat > /etc/systemd/system/he-ipv6-restore.service << 'EOF'
[Unit]
Description=HE IPv6 Additional Addresses Restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/he-ipv6-restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable he-ipv6-restore.service >/dev/null 2>&1
}

rebuild_and_apply(){
    load_record
    if [ -z "$HE_SERVER_V4" ] || [ -z "$HE_SERVER_V6" ] || [ -z "$CLIENT_IPV6" ]; then
        echo "错误: 缺少核心配置记录，请重新添加 HE 隧道。"
        return 1
    fi
    mkdir -p /etc/netplan
    detect_public_ipv4
    
    local CLEAN_CLIENT_IPV6
    CLEAN_CLIENT_IPV6=$(echo "$CLIENT_IPV6" | sed -E 's|/.*||')

    cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  tunnels:
    $IFACE:
      mode: sit
      remote: $HE_SERVER_V4
      local: $PUBLIC_V4
      addresses:
        - "$CLEAN_CLIENT_IPV6/64"
      routes:
        - to: default
          via: "$HE_SERVER_V6"
EOF
    echo
    echo "========== 生成 Netplan 配置 =========="
    cat "$NETPLAN_FILE"
    echo "========================================"
    echo
    echo "正在检查 Netplan 配置..."
    if ! netplan generate; then
        echo "错误: Netplan 配置语法检查失败！"
        return 1
    fi
    echo "正在应用 Netplan 配置..."
    if ! netplan apply; then
        echo "错误: Netplan 应用失败！"
        return 1
    fi
    
    ip link set "$IFACE" mtu 1480 2>/dev/null || true
    setup_systemd_restore
    
    if [ -f "$LIST_FILE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            ip -6 addr replace "$ip/128" dev lo 2>/dev/null || true
        done < "$LIST_FILE"
    fi
    echo "配置更新并应用成功！"
    return 0
}

add_he(){
    echo "========== 添加/配置 HE IPv6 隧道 =========="
    echo "请根据 TunnelBroker (HE) 页面提供的数据填写："
    echo
    read -p "1. Server IPv4 Address (HE 对端 IPv4): " HE_SERVER_V4
    read -p "2. Server IPv6 Address (HE 对端 IPv6): " HE_SERVER_V6
    read -p "3. Client IPv6 Address (本地客户端 IPv6，如 ...::2/64): " CLIENT_IPV6
    read -p "4. Routed IPv6 Prefix (分配的前缀，如 2001:470:xxxx::/48 或 /64): " ROUTED_PREFIX

    if [ -z "$HE_SERVER_V4" ] || [ -z "$HE_SERVER_V6" ] || [ -z "$CLIENT_IPV6" ] || [ -z "$ROUTED_PREFIX" ]; then
        echo "错误: 输入参数不完整，取消操作！"
        return 1
    fi

    # 规范化处理前缀格式
    ROUTED_PREFIX=$(echo "$ROUTED_PREFIX" | sed -E 's/[[:space:]]+//;s|/.*||;s/::$//')
    IFS=':' read -ra PREFIX_PARTS <<< "$ROUTED_PREFIX"
    if [ "${#PREFIX_PARTS[@]}" -eq 3 ]; then
        PREFIX_LEN=48
    elif [ "${#PREFIX_PARTS[@]}" -eq 4 ]; then
        PREFIX_LEN=64
    else
        echo "错误: IPv6 前缀格式不正确，示例: 2001:470:xxxx 或 2001:470:xxxx:yyyy"
        return 1
    fi

    cat > "$CONFIG_RECORD" <<EOF
HE_SERVER_V4="$HE_SERVER_V4"
HE_SERVER_V6="$HE_SERVER_V6"
CLIENT_IPV6="$CLIENT_IPV6"
ROUTED_PREFIX="$ROUTED_PREFIX"
PREFIX_LEN="$PREFIX_LEN"
EOF

    echo
    echo "保存核心参数成功，正在构建网络配置..."
    if rebuild_and_apply; then
        echo
        echo "========================================"
        echo "HE IPv6 隧道配置成功！"
        echo "配置文件: $NETPLAN_FILE"
        echo "路由前缀: $ROUTED_PREFIX/$PREFIX_LEN"
        echo "========================================"
    else
        echo "隧道配置应用失败，请检查填写参数是否正确。"
    fi
}

delete_he(){
    echo "正在删除 HE 隧道及相关配置..."
    if [ -f "$OUTBOUND_FILE" ]; then
        jq '
        .outbounds |= map(
            select((.tag // "") | startswith("he-ipv6-") | not)
        )
        ' "$OUTBOUND_FILE" > /tmp/out.json && mv /tmp/out.json "$OUTBOUND_FILE"
    fi
    if [ -f "$ROUTE_FILE" ]; then
        jq '
        .route.rules |= map(
            select((.outbound // "") | startswith("he-ipv6-") | not)
        )
        ' "$ROUTE_FILE" > /tmp/route.json && mv /tmp/route.json "$ROUTE_FILE"
    fi
    
    rm -f "$NETPLAN_FILE"
    systemctl disable he-ipv6-restore.service 2>/dev/null || true
    rm -f /etc/systemd/system/he-ipv6-restore.service
    rm -f /usr/local/bin/he-ipv6-restore
    systemctl daemon-reload
    netplan apply 2>/dev/null || true
    
    ip link set "$IFACE" down 2>/dev/null || true
    ip tunnel del "$IFACE" 2>/dev/null || true
    rm -f "$CONFIG_RECORD" "$LIST_FILE"
    
    if systemctl is-active sing-box >/dev/null 2>&1; then
        systemctl restart sing-box
    fi
    echo "HE 隧道已彻底清理完成！"
}

add_ipv6(){
    load_record
    if [ -z "$CLIENT_IPV6" ]; then
        echo "请先通过选项 1 添加并配置 HE 隧道！"
        read -p "按回车键继续..."
        return
    fi
    
    BASE_PREFIX="$ROUTED_PREFIX"
    if [ -z "$BASE_PREFIX" ]; then
        echo "未找到保存的前缀，请重新通过选项 1 初始化隧道。"
        read -p "按回车键继续..."
        return
    fi
    
    PREFIX=$(echo "$BASE_PREFIX" | sed 's|/.*||')
    HEX=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
    R1="${HEX:0:4}"
    R2="${HEX:4:4}"
    R3="${HEX:8:4}"
    R4="${HEX:12:4}"
    R5="${HEX:16:4}"
    
    IFS=':' read -ra PARTS <<< "$PREFIX" 
    if [ "${#PARTS[@]}" -eq 3 ]; then
        # /48 前缀生成方式
        NEW_IPV6="${PARTS[0]}:${PARTS[1]}:${PARTS[2]}:${R1}:${R2}:${R3}:${R4}:${R5}"
    elif [ "${#PARTS[@]}" -eq 4 ]; then
        # /64 前缀生成方式
        NEW_IPV6="${PARTS[0]}:${PARTS[1]}:${PARTS[2]}:${PARTS[3]}:${R1}:${R2}:${R3}:${R4}"
    else
        echo "IPv6 前缀格式不正确"
        return
    fi

    # 1. 写入列表
    echo "$NEW_IPV6" >> "$LIST_FILE"

    # 2. 应用网络变动
    if ! rebuild_and_apply; then
        echo -e "\n发生错误，撤销本次 IP 添加..."
        sed -i '$d' "$LIST_FILE" 
        read -p "按回车键继续..."
        return
    fi  

    # 3. 校验 IP 绑定
    if ip -6 addr show dev lo | grep -q "$NEW_IPV6"; then
        echo "✓ 校验成功: 附加 IPv6 ($NEW_IPV6) 已绑定至 lo 接口"
    else
        echo "✗ 警告: 未能在 lo 接口上检测到该 IP"
    fi
    
    # 4. 自动添加 sing-box 出站
    add_singbox_outbound "$NEW_IPV6"
    read -p "按回车键继续..."
}

delete_ipv6(){
    if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
        echo "没有可删除的附加 IPv6 地址"
        read -p "按回车键继续..."
        return
    fi
    echo "========== 当前已配置的附加 IPv6 地址 =========="
    list_ipv6
    echo
    read -p "输入要删除的编号: " NUM
    [ -z "$NUM" ] && return
    
    DEL_IP=$(sed -n "${NUM}p" "$LIST_FILE")
    if [ -z "$DEL_IP" ]; then
        echo "编号无效！"
        read -p "按回车键继续..."
        return
    fi
    
    delete_singbox_outbound "$DEL_IP"
    sed -i "${NUM}d" "$LIST_FILE"
    echo "已移除 IP 记录: $DEL_IP"
    rebuild_and_apply
    read -p "按回车键继续..."
}

status(){
    clear
    echo "========== HE IPv6 隧道设备状态 =========="
    ip link show "$IFACE" 2>/dev/null || echo "隧道设备未启动"
    echo
    echo "========== 主接口 IPv6 地址 =========="
    ip -6 addr show dev "$IFACE" 2>/dev/null | grep 'scope global' | awk '{print $2}' || echo "无"
    echo
    echo "========== 附加 IPv6 地址清单 (lo 接口) =========="
    list_ipv6
    echo
    read -p "按回车键返回主菜单..."
}

test_ipv6(){
    echo ""
    echo "========== HE IPv6 出口连通性测试 =========="
    echo ""
    if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
        echo "未找到附加 IPv6 地址列表：$LIST_FILE"
        read -p "按回车键继续..."
        return
    fi
    local total=0
    local success=0
    local failed=0
    while IFS= read -r TEST_IP; do
        [ -z "$TEST_IP" ] && continue
        total=$((total + 1))
        echo "----------------------------------------"
        echo "[$total] 测试 IP: $TEST_IP"
        local START_TIME END_TIME COST RESULT CURL_STATUS
        START_TIME=$(date +%s%3N)
        
        RESULT=$(curl -6 \
            --interface "$TEST_IP" \
            --connect-timeout 8 \
            --max-time 12 \
            -sS \
            https://ip.sb 2>/dev/null)
        CURL_STATUS=$?
        END_TIME=$(date +%s%3N)
        COST=$((END_TIME - START_TIME))
        
        if [ "$CURL_STATUS" -eq 0 ] && [ -n "$RESULT" ]; then
            success=$((success + 1))
            echo "✓ 连通成功 | 出口 IP: $RESULT | 耗时: ${COST} ms"
        else
            failed=$((failed + 1))
            echo "✗ 连通失败 | 耗时: ${COST} ms"
        fi
    done < "$LIST_FILE"
    
    echo ""
    echo "========================================"
    echo "测试统计: 总数: $total | 成功: $success | 失败: $failed"
    echo "========================================"
    read -p "按回车键继续..."
}

menu(){
    while true
    do
        clear
        echo "========== HE IPv6 隧道 (Netplan 持久版) =========="
        echo "1. 添加/重置 HE 隧道"
        echo "2. 删除 HE 隧道"
        echo "3. 随机添加附加 IPv6 地址"
        echo "4. 删除指定附加 IPv6 地址"
        echo "5. 查看隧道与 IP 状态"
        echo "6. 测试 IPv6 出口连通性"
        echo "0. 退出"
        echo "=================================================="
        read -p "选择 [0-6]: " CHOOSE
        case $CHOOSE in
            1) add_he; read -p "按回车键继续..." ;;
            2) delete_he; read -p "按回车键继续..." ;;
            3) add_ipv6 ;;
            4) delete_ipv6 ;;
            5) status ;;
            6) test_ipv6 ;;
            0) exit 0 ;;
            *) echo "输入错误，请重新选择！"; sleep 1 ;;
        esac
    done
}

install_dep
menu
