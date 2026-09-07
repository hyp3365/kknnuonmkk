#!/bin/bash
# ==========================================
# Route64 IPv6 隧道管理脚本
# ==========================================
set -u # 开启未定义变量检查

readonly G="\033[1;32m"
readonly R="\033[1;31m"
readonly NC="\033[0m"

readonly IFACE="route64"
readonly WG_DIR="/etc/wireguard"
readonly WG_FILE="$WG_DIR/$IFACE.conf"
readonly CONFIG_FILE="/etc/route64.conf"
readonly LIST_FILE="/etc/route64-ips.list"
readonly OUTBOUND_FILE="/etc/sing-box/conf/outbounds.json"
readonly ROUTE_FILE="/etc/sing-box/conf/route.json"
readonly SERVICE_FILE="/etc/systemd/system/route64-ipv6.service"
readonly HELPER_FILE="/usr/local/bin/route64-helper"

[ "$(id -u)" != "0" ] && {
    echo -e "${R}请使用 root 运行${NC}"
    exit 1
}

# 全局变量占位，避免 set -u 报错
PREFIX56=""
TABLE=""
INTERFACE=""

install_dep() {
    local NEED=""
    command -v wg >/dev/null || NEED="$NEED wireguard-tools"
    command -v ip >/dev/null || NEED="$NEED iproute2"
    command -v curl >/dev/null || NEED="$NEED curl"
    command -v jq >/dev/null || NEED="$NEED jq"
    if [ -n "$NEED" ]; then
        echo "安装依赖: $NEED"
        if command -v apt >/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y $NEED
        elif command -v apk >/dev/null; then
            apk add $NEED
        elif command -v yum >/dev/null; then
            yum install -y $NEED
        else
            echo "无法自动安装依赖，请手动安装: $NEED"
            exit 1
        fi
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

normalize_prefix56() {
    local p="${1:-}"
    p="${p%/56}"
    p="${p%::}"
    p="${p%:}"
    local p1 p2 p3 p4
    IFS=':' read -r p1 p2 p3 p4 _ <<< "$p"
    if [ -z "${p1:-}" ] || [ -z "${p2:-}" ] || [ -z "${p3:-}" ] || [ -z "${p4:-}" ]; then
        return 1
    fi
    printf '%x:%x:%x:%04x::/56' "$((16#$p1))" "$((16#$p2))" "$((16#$p3))" "$((16#$p4))"
}

generate_random_ipv6() {
    local prefix="${1:-}"
    prefix="${prefix%/56}"
    prefix="${prefix%::}"
    prefix="${prefix%:}"

    local p1 p2 p3 p4
    IFS=':' read -r p1 p2 p3 p4 _ <<< "$prefix"

    # 生成 9 字节的高质量随机数 (2位子网 + 16位接口ID)
    local r
    r=$(od -An -N9 -tx1 /dev/urandom | tr -d ' \n')
    
    local subnet="${r:0:2}"
    local h1="${r:2:4}"
    local h2="${r:6:4}"
    local h3="${r:10:4}"
    local h4="${r:14:4}"
    
    local p4_padded
    p4_padded=$(printf "%04x" "$((16#$p4))")
    local p4_base="${p4_padded:0:2}"

    printf '%x:%x:%x:%s:%s:%s:%s:%s\n' \
        "$((16#$p1))" "$((16#$p2))" "$((16#$p3))" "${p4_base}${subnet}" \
        "$h1" "$h2" "$h3" "$h4"
}

add_singbox_outbound() {
    [ ! -f "$OUTBOUND_FILE" ] && return 1
    if ! jq empty "$OUTBOUND_FILE" >/dev/null 2>&1; then
        echo -e "${R}outbounds.json 格式错误，中止修改！${NC}"
        return 1
    fi

    local IP="${1:-}"
    local NUM TAG TMP
    
    NUM=$(jq -r '
        [
            .outbounds[]? 
            | select((.tag // "") | startswith("route64-ipv6-")) 
            | (.tag | sub("route64-ipv6-"; "") | tonumber)
        ] | max // 0
    ' "$OUTBOUND_FILE" 2>/dev/null)
    NUM=$((NUM+1))
    TAG="route64-ipv6-$NUM"
    
    TMP=$(mktemp)
    if ! jq --arg tag "$TAG" --arg ip "$IP" '
        .outbounds += [{
            "type": "direct",
            "tag": $tag,
            "bind_interface": "route64",
            "inet6_bind_address": $ip
        }]
    ' "$OUTBOUND_FILE" > "$TMP"; then
        rm -f "$TMP"
        return 1
    fi
    mv "$TMP" "$OUTBOUND_FILE"
    echo "sing-box 出站添加成功: $TAG"
    return 0
}

delete_singbox_outbound() {
    [ ! -f "$OUTBOUND_FILE" ] && return 0
    if ! jq empty "$OUTBOUND_FILE" >/dev/null 2>&1; then
        echo -e "${R}outbounds.json 格式错误，跳过清理！${NC}"
        return 1
    fi

    local IP="${1:-}"
    local TAG TMP
    
    TAG=$(jq -r --arg ip "$IP" '
        .outbounds[]?
        | select(.inet6_bind_address == $ip)
        | .tag
        | select(type == "string")
    ' "$OUTBOUND_FILE" | head -n1)
    
    [ -z "$TAG" ] && return 0

    TMP=$(mktemp)
    if jq --arg ip "$IP" '
        .outbounds |= map(select(.inet6_bind_address != $ip))
    ' "$OUTBOUND_FILE" > "$TMP"; then
        mv "$TMP" "$OUTBOUND_FILE"
    else
        rm -f "$TMP"
        return 1
    fi

    if [ -f "$ROUTE_FILE" ] && jq empty "$ROUTE_FILE" >/dev/null 2>&1; then
        TMP=$(mktemp)
        if jq --arg tag "$TAG" '
            .route.rules = ((.route.rules // []) | map(select(.outbound != $tag)))
        ' "$ROUTE_FILE" > "$TMP"; then
            mv "$TMP" "$ROUTE_FILE"
        else
            rm -f "$TMP"
        fi
    fi
    echo "清理 sing-box 规则: $TAG"
    return 0
}

check_main_ipv6_route() {
    echo -e "${G}========== 主 IPv6 默认路由 ==========${NC}"
    local MAIN_DEFAULT
    MAIN_DEFAULT=$(ip -6 route show table main default 2>/dev/null)
    if [ -n "$MAIN_DEFAULT" ]; then
        echo "$MAIN_DEFAULT"
    else
        echo "无 IPv6 默认路由"
    fi

    if echo "$MAIN_DEFAULT" | grep -q "dev $IFACE"; then
        echo -e "${R}警告：主路由表默认 IPv6 被指向 $IFACE，主网可能被劫持！${NC}"
        return 1
    fi
    echo -e "状态正常：主路由表未使用 Route64"
    return 0
}

create_systemd_helper() {
    cat > "$HELPER_FILE" <<'EOF'
#!/bin/bash
set -u
CONFIG_FILE="/etc/route64.conf"
LIST_FILE="/etc/route64-ips.list"

[ -f "$CONFIG_FILE" ] || exit 0
source "$CONFIG_FILE"

T="${TABLE:-200}"
IF="${INTERFACE:-route64}"

start_routing() {
    ip -6 rule del from "$PREFIX56" table "$T" 2>/dev/null || true
    ip -6 rule del pref 100 from "$PREFIX56" lookup "$T" 2>/dev/null || true
    ip -6 rule add pref 100 from "$PREFIX56" table "$T"
    ip -6 route replace default dev "$IF" table "$T"
    
    if [ -f "$LIST_FILE" ]; then
        while read -r ip; do
            [ -n "$ip" ] && ip -6 addr add "$ip/128" dev lo 2>/dev/null || true
        done < "$LIST_FILE"
    fi
}

stop_routing() {
    ip -6 rule del pref 100 from "$PREFIX56" lookup "$T" 2>/dev/null || true
    ip -6 rule del from "$PREFIX56" table "$T" 2>/dev/null || true
    ip -6 route flush table "$T" 2>/dev/null || true
}

case "${1:-}" in
    start) start_routing ;;
    stop)  stop_routing ;;
    *) echo "Usage: $0 {start|stop}" ;;
esac
EOF
    chmod +x "$HELPER_FILE"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Route64 IPv6 Policy Routing and IP Restore
After=wg-quick@${IFACE}.service
Requires=wg-quick@${IFACE}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HELPER_FILE} start
ExecStop=${HELPER_FILE} stop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

add_route64() {
    clear
    echo -e "${G}========================================${NC}"
    echo -e "${G}        添加 / 重置 Route64 隧道${NC}"
    echo -e "${G}========================================${NC}"
    echo "请粘贴 ROUTE64 WireGuard 配置。"
    echo -e "粘贴完成后，${G}连续按两次回车${NC}继续："
    
    local tmp_conf="/tmp/route64.conf.$$"
    rm -f "$tmp_conf"
    local EMPTY_COUNT=0
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            EMPTY_COUNT=$((EMPTY_COUNT+1))
        else
            EMPTY_COUNT=0
            printf '%s\n' "$line" >> "$tmp_conf"
        fi
        [ "$EMPTY_COUNT" -ge 2 ] && break
    done

    if [ ! -s "$tmp_conf" ]; then
        echo "未读取到 WireGuard 配置。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    if ! grep -q '^\[PrivateKey' "$tmp_conf" && ! grep -q '^PrivateKey' "$tmp_conf"; then
        echo "缺少 PrivateKey。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi

    echo "请输入 ROUTE64 分配给你的 IPv6 /56 区段。"
    echo "例如：2a11:6c7:2001:c400::/56"
    local raw_prefix
    read -r -p "IPv6 /56： " raw_prefix
    raw_prefix="${raw_prefix//[[:space:]]/}"
    
    local prefix56_canonical
    prefix56_canonical=$(normalize_prefix56 "$raw_prefix")
    if [ -z "$prefix56_canonical" ]; then
        echo -e "${R}错误：解析 /56 失败，请检查格式。${NC}"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi

    echo -e "\n----------------------------------------"
    echo "WireGuard 配置预览："
    cat "$tmp_conf"
    echo "规范化 Route64 /56："
    echo -e "${G}$prefix56_canonical${NC}"
    echo "----------------------------------------"
    read -r -p "回车确认继续，输入其他内容取消： " confirm
    if [ -n "$confirm" ]; then
        echo "已取消。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 0
    fi

    echo "正在配置 Route64..."
    systemctl stop wg-quick@${IFACE}.service 2>/dev/null || true
    systemctl stop route64-ipv6.service 2>/dev/null || true
    
    mkdir -p "$WG_DIR"
    sed -i '/^[[:space:]]*Table[[:space:]]*=/d' "$tmp_conf"
    awk '
    BEGIN { done=0 }
    /^\[Interface\][[:space:]]*$/ {
        print
        print "Table = off"
        done=1
        next
    }
    { print }
    ' "$tmp_conf" > "$WG_FILE"
    chmod 600 "$WG_FILE"
    rm -f "$tmp_conf"

    cat > "$CONFIG_FILE" <<EOF
PREFIX56=$prefix56_canonical
TABLE=200
INTERFACE=$IFACE
EOF
    chmod 600 "$CONFIG_FILE"

    if ! grep -qE '^[[:space:]]*200[[:space:]]+route64[[:space:]]*$' /etc/iproute2/rt_tables; then
        echo "200 route64" >> /etc/iproute2/rt_tables
    fi

    touch "$LIST_FILE"
    chmod 600 "$LIST_FILE"
    
    # 构建并启用系统服务
    create_systemd_helper
    systemctl enable wg-quick@${IFACE}.service >/dev/null 2>&1
    systemctl enable route64-ipv6.service >/dev/null 2>&1
    
    # 启动隧道及依赖服务
    systemctl daemon-reload
    if ! systemctl restart "wg-quick@${IFACE}.service"; then
        echo -e "${R}Route64 WireGuard 启动失败。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi
    if ! systemctl restart route64-ipv6.service; then
        echo -e "${R}Route64 策略路由服务启动失败。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi

    echo -e "\n${G}========================================${NC}"
    echo -e "${G}        Route64 配置完成${NC}"
    echo -e "${G}========================================${NC}"
    
    echo -e "\n等待 Peer 握手..."
    sleep 2
    wg show "$IFACE" latest-handshakes | grep -v '0$' || echo -e "${R}暂未检测到有效握手，请稍后在状态中复核。${NC}"
    
    check_main_ipv6_route
    read -r -p "按回车返回..."
}

delete_route64() {
    clear
    echo -e "${R}即将彻底清理 Route64 隧道及路由策略...${NC}"
    load_config

    systemctl stop route64-ipv6.service 2>/dev/null || true
    systemctl disable route64-ipv6.service 2>/dev/null || true
    if [ -f "$OUTBOUND_FILE" ] && jq empty "$OUTBOUND_FILE" >/dev/null 2>&1; then
        local TMP
        TMP=$(mktemp)
        if jq '.outbounds |= map(select((.tag // "") | startswith("route64-ipv6-") | not))' "$OUTBOUND_FILE" > "$TMP"; then
            mv "$TMP" "$OUTBOUND_FILE"
        else
            rm -f "$TMP"
        fi
    fi
    if [ -f "$ROUTE_FILE" ] && jq empty "$ROUTE_FILE" >/dev/null 2>&1; then
        local TMP
        TMP=$(mktemp)
        if jq '.route.rules = ((.route.rules // []) | map(select((.outbound // "") | startswith("route64-ipv6-") | not)))' "$ROUTE_FILE" > "$TMP"; then
            mv "$TMP" "$ROUTE_FILE"
        else
            rm -f "$TMP"
        fi
    fi

    if [ -n "${PREFIX56:-}" ] && [ -n "${TABLE:-}" ]; then
        ip -6 rule del pref 100 from "$PREFIX56" lookup "$TABLE" 2>/dev/null || true
        ip -6 rule del from "$PREFIX56" table "$TABLE" 2>/dev/null || true
        ip -6 route flush table "$TABLE" 2>/dev/null || true
    fi

    wg-quick down "$IFACE" 2>/dev/null || true
    systemctl disable "wg-quick@${IFACE}.service" 2>/dev/null || true

    rm -f "$WG_FILE"
    rm -f "$SERVICE_FILE"
    rm -f "$HELPER_FILE"
    rm -f "$CONFIG_FILE"
    # list保留或清除均可，这里做彻底清除
    rm -f "$LIST_FILE" 

    echo -e "${G}Route64 已彻底删除清理。${NC}"
    read -r -p "按回车返回..."
}

add_ipv6() {
    clear
    echo -e "${G}========================================${NC}"
    echo -e "${G}          添加 Route64 IPv6${NC}"
    echo -e "${G}========================================${NC}"
    load_config
    if [ -z "${PREFIX56:-}" ]; then
        echo -e "${R}未找到 Route64 /56 配置文件，请先添加隧道。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi

    [ ! -f "$LIST_FILE" ] && touch "$LIST_FILE"

    local NEW_IPV6=""
    local i
    for i in $(seq 1 100); do
        NEW_IPV6=$(generate_random_ipv6 "$PREFIX56")
        if ! grep -qxF "$NEW_IPV6" "$LIST_FILE" 2>/dev/null; then
            break
        fi
        NEW_IPV6=""
    done

    if [ -z "$NEW_IPV6" ]; then
        echo -e "${R}生成随机 IPv6 失败。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi

    echo "生成的随机 IPv6：$NEW_IPV6"
    
    # 事务化添加逻辑
    if ! ip -6 addr add "$NEW_IPV6/128" dev lo 2>/dev/null; then
        echo -e "${R}IPv6 绑定系统失败。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi

    if ! add_singbox_outbound "$NEW_IPV6"; then
        echo -e "${R}sing-box 配置失败，正在回滚系统 IP...${NC}"
        ip -6 addr del "$NEW_IPV6/128" dev lo 2>/dev/null || true
        read -r -p "按回车返回..."
        return 1
    fi

    echo "$NEW_IPV6" >> "$LIST_FILE"
    echo -e "${G}IPv6 添加成功，已就绪！${NC}"
    read -r -p "按回车返回..."
}

list_ipv6() {
    if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
        echo "暂无分配的 IPv6"
        return 1
    fi
    nl -w2 -s ". " "$LIST_FILE"
    return 0
}

delete_ipv6() {
    clear
    echo -e "${R}========== 删除 IPv6 ==========${NC}"
    if ! list_ipv6; then
        read -r -p "按回车返回..."
        return 1
    fi
    
    local NUM IP
    read -r -p "输入要删除的编号: " NUM
    IP=$(sed -n "${NUM}p" "$LIST_FILE" 2>/dev/null)
    if [ -z "${IP:-}" ]; then
        echo -e "${R}编号错误。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi

    echo "准备删除: $IP"
    
    # 事务化删除逻辑
    if ! delete_singbox_outbound "$IP"; then
        echo -e "${R}sing-box 规则清理失败，终止系统 IP 删除操作以保持数据一致性。${NC}"
        read -r -p "按回车返回..."
        return 1
    fi

    ip -6 addr del "$IP/128" dev lo 2>/dev/null || true
    sed -i "${NUM}d" "$LIST_FILE"
    echo -e "${G}删除完成。${NC}"
    read -r -p "按回车返回..."
}

status() {
    clear
    load_config
    echo -e "${G}========== Route64 接口及隧道状态 ==========${NC}"
    if ip link show "$IFACE" >/dev/null 2>&1; then
        echo "接口状态: UP"
        wg show "$IFACE" latest-handshakes | grep -v '0$' || echo -e "${R}无最新握手数据${NC}"
        wg show "$IFACE" transfer
    else
        echo -e "${R}接口 route64 未启动或不存在${NC}"
    fi
    
    echo -e "\n${G}========== Route64 策略路由 ==========${NC}"
    if [ -n "${PREFIX56:-}" ] && [ -n "${TABLE:-}" ]; then
        ip -6 rule | grep "$PREFIX56" || echo -e "${R}无策略路由 rule${NC}"
        ip -6 route show table "$TABLE" || echo -e "${R}无 $TABLE 表路由${NC}"
    else
        echo "配置文件缺失或未加载"
    fi
    
    echo -e "\n"
    check_main_ipv6_route

    echo -e "\n${G}========== 当前地址池 ==========${NC}"
    list_ipv6
    
    read -r -p "按回车返回..."
}

test_ipv6() {
    clear
    if ! list_ipv6 >/dev/null; then
        echo -e "${R}没有可用的 IPv6 地址${NC}"
        read -r -p "按回车返回..."
        return
    fi
    echo -e "${G}========== IPv6 出口测试 ==========${NC}"
    local TOTAL=0 OK=0 FAIL=0
    while IFS= read -r IP; do
        [ -z "$IP" ] && continue
        TOTAL=$((TOTAL+1))
        echo "[$TOTAL] 正在测试源地址: $IP"
        
        local START END TIME RESULT
        START=$(date +%s%3N)
        # 尝试 ip.sb, 如果失败则尝试备用 API
        RESULT=$(curl -6 --interface "$IP" --connect-timeout 5 --max-time 10 -s https://api64.ipify.org 2>/dev/null)
        [ -z "$RESULT" ] && RESULT=$(curl -6 --interface "$IP" --connect-timeout 5 --max-time 10 -s https://ip.sb 2>/dev/null)
        END=$(date +%s%3N)
        TIME=$((END-START))
        
        if [ -n "$RESULT" ]; then
            echo -e "  ${G}✓ 成功${NC} | 出口 IP: $RESULT | 耗时: ${TIME} ms"
            OK=$((OK+1))
        else
            echo -e "  ${R}✗ 失败${NC} | 无法建立连接或超时"
            FAIL=$((FAIL+1))
        fi
    done < "$LIST_FILE"
    
    echo "=============================="
    echo "总数: $TOTAL | 成功: $OK | 失败: $FAIL"
    read -r -p "按回车返回..."
}

menu() {
    while true; do
        clear
        echo -e "${G}========== Route64 IPv6 管理 v2 ==========${NC}"
        echo -e "${G}1. 添加 / 重置 Route64 隧道${NC}"
        echo -e "${G}2. 删除 Route64 隧道${NC}"
        echo -e "${G}3. 随机添加 IPv6 地址${NC}"
        echo -e "${G}4. 删除 IPv6 地址${NC}"
        echo -e "${G}5. 查看网络策略状态${NC}"
        echo -e "${G}6. 批量测试 IPv6 出口连通性${NC}"
        echo -e "${G}0. 退出${NC}"
        echo -e "${G}==========================================${NC}"
        read -r -p "选择 [0-6]: " CHOOSE
        case "$CHOOSE" in
            1) add_route64 ;;
            2) delete_route64 ;;
            3) add_ipv6 ;;
            4) delete_ipv6 ;;
            5) status ;;
            6) test_ipv6 ;;
            0) exit 0 ;;
            *) 
                echo -e "${R}输入错误${NC}"
                sleep 1
                ;;
        esac
    done
}

install_dep
menu

