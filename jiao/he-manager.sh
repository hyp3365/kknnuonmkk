#!/bin/bash
# ==========================================
# HE IPv6 隧道脚本 (Netplan 纯粘贴原子化版1)
# ==========================================
NETPLAN_FILE="/etc/netplan/99-he-tunnel.yaml"
CONFIG_RECORD="/etc/he-ipv6.conf"
LIST_FILE="/etc/he-ipv6-ips.list"
IFACE="he-ipv6"
OUTBOUND_FILE="/etc/sing-box/conf/outbounds.json"
ROUTE_FILE="/etc/sing-box/conf/route.json"

# 检查 Root 权限
[ "$(id -u)" != "0" ] && echo "错误: 请使用 root 权限运行此脚本！" && exit 1

install_dep(){
    if command -v apt-get >/dev/null 2>&1; then
        local PKGS=()

        command -v curl >/dev/null 2>&1 || PKGS+=(curl)
        command -v ip >/dev/null 2>&1 || PKGS+=(iproute2)
        command -v awk >/dev/null 2>&1 || PKGS+=(gawk)
        command -v jq >/dev/null 2>&1 || PKGS+=(jq)
        command -v netplan >/dev/null 2>&1 || PKGS+=(netplan.io)

        if [ "${#PKGS[@]}" -gt 0 ]; then
            apt-get update -y
            apt-get install -y "${PKGS[@]}"
        fi
    fi

    # 最终断言检查
    for cmd in curl ip awk jq netplan; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "错误: 缺少核心依赖: $cmd，请手动排查包管理器问题！"
            exit 1
        fi
    done
}

list_ipv6(){
    if [ -f "$LIST_FILE" ] && [ -s "$LIST_FILE" ]; then
        awk '{print NR". "$0}' "$LIST_FILE"
    else
        echo "无附加记录"
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
    echo "sing-box 出站已写入 JSON (未重启 sing-box):"
    echo " tag: $TAG"
    echo " ipv6: $IP"
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
    echo "route 规则已删除:"
    echo " outbound: $TAG"
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
    echo "sing-box 出站已删除 (未重启 sing-box):"
    echo " tag: $TAG"
    delete_singbox_route "$TAG"
}

load_record(){
    if [ -f "$CONFIG_RECORD" ]; then
        source "$CONFIG_RECORD"
    fi
}

setup_systemd_restore(){
    # 使用 replace 指令替代 add，提升恢复时的稳定性
    cat > /usr/local/bin/he-ipv6-restore << 'EOF'
#!/bin/bash
LIST_FILE="/etc/he-ipv6-ips.list"
[ -f "$LIST_FILE" ] || exit 0
while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    ip -6 addr replace "$ip/128" dev lo 2>/dev/null || true
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

add_he(){
    echo "========== 添加 HE IPv6 隧道 =========="
    echo "请直接粘贴你的 Netplan 配置内容"
    echo "输入完成后按 Enter 换行并保持空行回车确认："
    echo
    local TMP
    TMP=$(mktemp)
    while IFS= read -r line; do
        [ -z "$line" ] && break
        printf '%s\n' "$line" >> "$TMP"
    done

    if [ ! -s "$TMP" ]; then
        echo "未输入任何配置，取消操作"
        rm -f "$TMP"
        return
    fi

    echo
    read -p "请输入 Routed IPv6 前缀 (必须明确包含 /48 或 /64，例如 2001:470:c::/48): " INPUT_PREFIX
    if [ -z "$INPUT_PREFIX" ]; then
        echo "错误: 未输入前缀，取消操作！"
        rm -f "$TMP"
        return
    fi

    # 校验 IPv6 前缀格式合法性（基础 Hex + 冒号与末尾掩码）
    if ! echo "$INPUT_PREFIX" | grep -qE '^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{0,4}/(48|64)$'; then
        echo "错误: 输入的前缀格式不合法！示例: 2001:470:c::/48 或 2001:470:c:ed9::/64"
        rm -f "$TMP"
        return
    fi

    local PREFIX_LEN=""
    if [[ "$INPUT_PREFIX" =~ /48$ ]]; then
        PREFIX_LEN=48
    elif [[ "$INPUT_PREFIX" =~ /64$ ]]; then
        PREFIX_LEN=64
    fi

    ROUTED_PREFIX=$(echo "$INPUT_PREFIX" | sed -E 's/[[:space:]]+//;s|/.*||;s/::$//')

    echo
    echo "========== 准备写入的配置总览 =========="
    echo "[Netplan 预览]"
    cat "$TMP"
    echo "----------------------------------------"
    echo "待分配 IPv6 前缀: $ROUTED_PREFIX/$PREFIX_LEN"
    echo "========================================"
    echo
    read -p "确认写入配置并生效? [y/N]: " OK
    if [ "$OK" != "y" ] && [ "$OK" != "Y" ]; then
        echo "取消操作"
        rm -f "$TMP"
        return
    fi

    mkdir -p /etc/netplan
    # 创建备份以支持回滚
    [ -f "$NETPLAN_FILE" ] && cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"
    cp "$TMP" "$NETPLAN_FILE"
    rm -f "$TMP"

    echo "正在测试 Netplan 语法..."
    if ! netplan generate; then
        echo "错误: Netplan 语法解析失败！正在自动回滚..."
        if [ -f "${NETPLAN_FILE}.bak" ]; then
            mv "${NETPLAN_FILE}.bak" "$NETPLAN_FILE"
        else
            rm -f "$NETPLAN_FILE"
        fi
        return 1
    fi

    echo "正在应用 Netplan 配置..."
    if ! netplan apply; then
        echo "错误: Netplan 应用失败！正在自动回滚..."
        if [ -f "${NETPLAN_FILE}.bak" ]; then
            mv "${NETPLAN_FILE}.bak" "$NETPLAN_FILE"
            netplan apply 2>/dev/null || true
        else
            rm -f "$NETPLAN_FILE"
        fi
        return 1
    fi

    # 应用成功，清理备份并保存持久化信息
    rm -f "${NETPLAN_FILE}.bak"

    cat > "$CONFIG_RECORD" <<EOF
ROUTED_PREFIX="$ROUTED_PREFIX"
PREFIX_LEN="$PREFIX_LEN"
EOF

    setup_systemd_restore
    echo
    echo "========================================"
    echo "HE IPv6 隧道配置完毕且生效！"
    echo "Netplan 配置文件: $NETPLAN_FILE"
    echo "已记录 IPv6 前缀: $ROUTED_PREFIX/$PREFIX_LEN"
    echo "========================================"
}

delete_he(){
    echo "正在清理 HE 隧道及相关配置..."
    local NEED_RESTART_SINGBOX=0

    # 1. 检查并清除 sing-box 配置
    if [ -f "$OUTBOUND_FILE" ]; then
        if jq -e '.outbounds[]? | select((.tag // "") | startswith("he-ipv6-"))' "$OUTBOUND_FILE" >/dev/null 2>&1; then
            jq '
            .outbounds |= map(
                select((.tag // "") | startswith("he-ipv6-") | not)
            )
            ' "$OUTBOUND_FILE" > /tmp/out.json && mv /tmp/out.json "$OUTBOUND_FILE"
            NEED_RESTART_SINGBOX=1
        fi
    fi

    if [ -f "$ROUTE_FILE" ]; then
        if jq -e '.route.rules[]? | select((.outbound // "") | startswith("he-ipv6-"))' "$ROUTE_FILE" >/dev/null 2>&1; then
            jq '
            .route.rules |= map(
                select((.outbound // "") | startswith("he-ipv6-") | not)
            )
            ' "$ROUTE_FILE" > /tmp/route.json && mv /tmp/route.json "$ROUTE_FILE"
            NEED_RESTART_SINGBOX=1
        fi
    fi

    # 2. 清理已挂载在 lo 上的 IPv6 地址，消除脏地址
    if [ -f "$LIST_FILE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && ip -6 addr del "$ip/128" dev lo 2>/dev/null || true
        done < "$LIST_FILE"
    fi

    # 3. 清理系统网络文件与开机恢复服务
    rm -f "$NETPLAN_FILE"
    systemctl disable he-ipv6-restore.service 2>/dev/null || true
    rm -f /etc/systemd/system/he-ipv6-restore.service
    rm -f /usr/local/bin/he-ipv6-restore
    systemctl daemon-reload
    netplan apply 2>/dev/null || true

    ip link set "$IFACE" down 2>/dev/null || true
    ip tunnel del "$IFACE" 2>/dev/null || true
    rm -f "$CONFIG_RECORD" "$LIST_FILE"

    echo "HE 网络隧道及网卡绑定已彻底清除！"

    # 4. 仅在确实修改了路由/出站配置文件时，才重启 sing-box
    if [ "$NEED_RESTART_SINGBOX" -eq 1 ]; then
        if systemctl is-active sing-box >/dev/null 2>&1; then
            echo "检测到已移除 sing-box 相关出站与路由规则，正在重启 sing-box..."
            systemctl restart sing-box
        fi
    fi
}

add_ipv6(){
    load_record
    if [ -z "$ROUTED_PREFIX" ] || [ -z "$PREFIX_LEN" ]; then
        echo "未检测到预置的前缀段，请先通过选项 1 添加隧道并设置前缀！"
        read -p "按回车键继续..."
        return
    fi

    PREFIX=$(echo "$ROUTED_PREFIX" | sed 's|/.*||')
    local MAX_RETRY=10
    local RETRY=0
    local NEW_IPV6=""

    # 随机生成并自动判重 (使用固定字符串精确匹配 -qsF / -qsxF)
    while [ $RETRY -lt $MAX_RETRY ]; do
        HEX=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
        R1="${HEX:0:4}"; R2="${HEX:4:4}"; R3="${HEX:8:4}"; R4="${HEX:12:4}"; R5="${HEX:16:4}"

        if [ "$PREFIX_LEN" -eq 48 ]; then
            NEW_IPV6="${PREFIX}:${R1}:${R2}:${R3}:${R4}:${R5}"
        else
            NEW_IPV6="${PREFIX}:${R1}:${R2}:${R3}:${R4}"
        fi

        if grep -qsxF "$NEW_IPV6" "$LIST_FILE" 2>/dev/null || ip -6 addr show dev lo | grep -qsF "$NEW_IPV6"; then
            RETRY=$((RETRY + 1))
        else
            break
        fi
    done

    if [ $RETRY -ge $MAX_RETRY ]; then
        echo "错误: 连续 $MAX_RETRY 次未能生成唯一的 IPv6 地址，请重试！"
        read -p "按回车键继续..."
        return
    fi

    # 1. 绑定 IPv6 到 lo 接口
    ip -6 addr add "$NEW_IPV6/128" dev lo 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "错误: 绑定 IPv6 至 lo 接口失败！"
        read -p "按回车键继续..."
        return
    fi

    # 2. 写入列表记录
    echo "$NEW_IPV6" >> "$LIST_FILE"
    echo "✓ 附加 IPv6 已成功绑定至 lo 接口: $NEW_IPV6"

    # 3. 添加 sing-box 出站 (不重启 sing-box)
    add_singbox_outbound "$NEW_IPV6"
    read -p "按回车键继续..."
}

delete_ipv6(){
    if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
        echo "没有可删除的额外 IPv6 地址"
        read -p "按回车键继续..."
        return
    fi
    echo "========== 当前配置的额外 IPv6 地址 =========="
    list_ipv6
    echo
    read -p "输入要删除的编号: " NUM
    [ -z "$NUM" ] && return
    DEL_IP=$(sed -n "${NUM}p" "$LIST_FILE")
    if [ -z "$DEL_IP" ]; then
        echo "输入的编号无效！"
        read -p "按回车键继续..."
        return
    fi

    # 1. 从 lo 接口解绑 IP
    ip -6 addr del "$DEL_IP/128" dev lo 2>/dev/null || true

    # 2. 删除 sing-box 出站 JSON (不重启 sing-box)
    delete_singbox_outbound "$DEL_IP"

    # 3. 从记录清单删除
    sed -i "${NUM}d" "$LIST_FILE"
    echo "已移除 IP 记录: $DEL_IP"
    read -p "按回车键继续..."
}

status(){
    clear
    echo "========== HE IPv6 设备状态 =========="
    ip link show "$IFACE" 2>/dev/null || echo "隧道设备未启动"
    echo
    echo "========== 已绑定的全局 IPv6 地址 =========="
    ip -6 addr show dev "$IFACE" 2>/dev/null | grep 'scope global' | awk '{print $2}' || echo "无"
    echo
    echo "========== 额外附加的 IPv6 地址清单 (lo 接口) =========="
    list_ipv6
    echo
    read -p "按回车键返回主菜单..."
}

test_ipv6(){
    echo ""
    echo "========== HE IPv6 全部 IP 测试 =========="
    echo ""
    if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
        echo "未找到额外 IPv6 地址列表：$LIST_FILE"
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
        echo "[$total] 测试 IPv6: $TEST_IP"
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
            echo "✓ 连通成功 | 出口 IPv6: $RESULT | 耗时: ${COST} ms"
        else
            failed=$((failed + 1))
            echo "✗ 连通失败 | 耗时: ${COST} ms"
        fi
    done < "$LIST_FILE"
    echo ""
    echo "========================================"
    echo "测试完成 | 总数: $total | 成功: $success | 失败: $failed"
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
        echo "5. 查看网卡与 IPv6 状态"
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
