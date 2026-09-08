#!/bin/bash
# ==========================================
# Tunnel64 IPv6 隧道脚本
# ==========================================

T64_CONFIG_RECORD="/etc/tunnel64.conf"
T64_LIST_FILE="/etc/tunnel64-ips.list"
T64_IFACE="he68"
T64_TABLE="201"
T64_RULE_PREF="32764"

T64_LOCAL_V4=""
T64_REMOTE_V4=""
T64_TUNNEL_IPV6=""
T64_ROUTED_PREFIX=""
T64_MTU="1480"

T64_RESTORE_BIN="/usr/local/bin/tunnel64-restore"
T64_RESTORE_SERVICE="/etc/systemd/system/tunnel64-restore.service"

OUTBOUND_FILE="/etc/sing-box/conf/outbounds.json"
ROUTE_FILE="/etc/sing-box/conf/route.json"

NEED_RESTART_SINGBOX=0

# 检查 Root 权限
[ "$(id -u)" != "0" ] && echo "错误: 请使用 root 权限运行此脚本！" && exit 1

install_dep(){
    if command -v apt-get >/dev/null 2>&1; then
        local PKGS=()

        command -v curl >/dev/null 2>&1 || PKGS+=(curl)
        command -v ip >/dev/null 2>&1 || PKGS+=(iproute2)
        command -v awk >/dev/null 2>&1 || PKGS+=(gawk)
        command -v jq >/dev/null 2>&1 || PKGS+=(jq)

        if [ "${#PKGS[@]}" -gt 0 ]; then
            apt-get update -y
            apt-get install -y "${PKGS[@]}"
        fi
    fi

    for cmd in curl ip awk jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "错误: 缺少核心依赖: $cmd"
            exit 1
        fi
    done
}

generate_ipv6(){
    local prefix="$1"
    local hex

    hex=$(tr -d '-' < /proc/sys/kernel/random/uuid)

    printf '%s:%s:%s:%s:%s\n' \
        "$prefix" \
        "${hex:0:4}" \
        "${hex:4:4}" \
        "${hex:8:4}" \
        "${hex:12:4}"
}

load_record(){
    if [ -f "$T64_CONFIG_RECORD" ]; then
        source "$T64_CONFIG_RECORD"
    fi
}

save_record(){
    cat > "$T64_CONFIG_RECORD" <<EOF
T64_LOCAL_V4="$T64_LOCAL_V4"
T64_REMOTE_V4="$T64_REMOTE_V4"
T64_TUNNEL_IPV6="$T64_TUNNEL_IPV6"
T64_ROUTED_PREFIX="$T64_ROUTED_PREFIX"
T64_MTU="$T64_MTU"
EOF
}

list_ipv6(){
    if [ -f "$T64_LIST_FILE" ] && [ -s "$T64_LIST_FILE" ]; then
        awk '{print NR". "$0}' "$T64_LIST_FILE"
    else
        echo "无附加记录"
    fi
}

# ==========================================
# sing-box
# ==========================================

add_singbox_outbound(){
    [ ! -f "$OUTBOUND_FILE" ] && return 0

    local IP="$1"
    local NUM
    local TAG
    local TMP_JSON

    NUM=$(jq -r '
        .outbounds[]?
        | select(
            ((.tag // "") | startswith("tunnel64-ipv6-"))
        )
        | .tag
        | sub("tunnel64-ipv6-";"")
    ' "$OUTBOUND_FILE" 2>/dev/null | sort -n | tail -1)

    if [ -z "$NUM" ]; then
        NUM=1
    else
        NUM=$((NUM + 1))
    fi

    TAG="tunnel64-ipv6-$NUM"
    TMP_JSON=$(mktemp)

    if ! jq \
        --arg tag "$TAG" \
        --arg ip "$IP" \
        --arg iface "$T64_IFACE" \
        '
        .outbounds += [{
            "type":"direct",
            "tag":$tag,
            "bind_interface":$iface,
            "inet6_bind_address":$ip
        }]
        ' "$OUTBOUND_FILE" > "$TMP_JSON"; then
        rm -f "$TMP_JSON"
        return 1
    fi

    mv "$TMP_JSON" "$OUTBOUND_FILE"

    echo "sing-box 出站已写入 JSON (未重启 sing-box):"
    echo " tag: $TAG"
    echo " ipv6: $IP"

    return 0
}

delete_singbox_route(){
    [ ! -f "$ROUTE_FILE" ] && return 1

    local TAG="$1"
    local TMP_JSON

    if ! jq -e --arg tag "$TAG" '
        .route.rules[]?
        | select(.outbound == $tag)
    ' "$ROUTE_FILE" >/dev/null 2>&1; then
        return 1
    fi

    TMP_JSON=$(mktemp)

    if jq --arg tag "$TAG" '
        .route.rules |= map(
            select(.outbound != $tag)
        )
    ' "$ROUTE_FILE" > "$TMP_JSON"; then

        mv "$TMP_JSON" "$ROUTE_FILE"

        echo "route 规则已删除:"
        echo " outbound: $TAG"

        NEED_RESTART_SINGBOX=1

        return 0
    else
        rm -f "$TMP_JSON"
        return 1
    fi
}

delete_singbox_outbound(){
    [ ! -f "$OUTBOUND_FILE" ] && return 0

    local IP="$1"
    local TAGS=()
    local TAG
    local TMP_JSON

    mapfile -t TAGS < <(
        jq -r --arg ip "$IP" '
            .outbounds[]?
            | select(.inet6_bind_address == $ip)
            | .tag // empty
        ' "$OUTBOUND_FILE"
    )

    [ "${#TAGS[@]}" -eq 0 ] && return 0

    TMP_JSON=$(mktemp)

    if jq \
        --arg ip "$IP" '
        .outbounds |= map(
            select(.inet6_bind_address != $ip)
        )
        ' "$OUTBOUND_FILE" > "$TMP_JSON"; then

        mv "$TMP_JSON" "$OUTBOUND_FILE"

        echo "sing-box 出站已删除 (未重启 sing-box): $IP"

        for TAG in "${TAGS[@]}"; do
            [ -n "$TAG" ] && delete_singbox_route "$TAG"
        done

        return 0
    else
        rm -f "$TMP_JSON"
        return 1
    fi
}

delete_all_singbox(){
    NEED_RESTART_SINGBOX=0

    if [ -f "$OUTBOUND_FILE" ]; then
        local OUT_TMP

        OUT_TMP=$(mktemp)

        if jq '
            .outbounds |= map(
                select(
                    ((.tag // "") | startswith("tunnel64-ipv6-") | not)
                )
            )
        ' "$OUTBOUND_FILE" > "$OUT_TMP"; then
            if ! cmp -s "$OUTBOUND_FILE" "$OUT_TMP"; then
                mv "$OUT_TMP" "$OUTBOUND_FILE"
                echo "Tunnel64 sing-box 出站已全部删除"
            else
                rm -f "$OUT_TMP"
            fi
        else
            rm -f "$OUT_TMP"
        fi
    fi

    if [ -f "$ROUTE_FILE" ]; then
        local ROUTE_TMP

        ROUTE_TMP=$(mktemp)

        if jq '
            .route.rules |= map(
                select(
                    ((.outbound // "") | startswith("tunnel64-ipv6-") | not)
                )
            )
        ' "$ROUTE_FILE" > "$ROUTE_TMP"; then

            if ! cmp -s "$ROUTE_FILE" "$ROUTE_TMP"; then
                mv "$ROUTE_TMP" "$ROUTE_FILE"
                echo "Tunnel64 sing-box route 规则已删除"
                NEED_RESTART_SINGBOX=1
            else
                rm -f "$ROUTE_TMP"
            fi
        else
            rm -f "$ROUTE_TMP"
        fi
    fi
}

restart_singbox_if_needed(){
    if [ "$NEED_RESTART_SINGBOX" -eq 1 ]; then
        if systemctl is-active sing-box >/dev/null 2>&1; then
            echo "检测到 Tunnel64 删除了 sing-box 路由规则，正在重启 sing-box..."
            systemctl restart sing-box
        else
            echo "Tunnel64 删除了 sing-box 路由规则，但 sing-box 当前未运行，跳过重启"
        fi
    else
        echo "未删除 sing-box 路由规则，不重启 sing-box"
    fi
}

# ==========================================
# Tunnel64 系统网络
# ==========================================

setup_systemd_restore(){
    cat > "$T64_RESTORE_BIN" << 'EOF'
#!/bin/bash

CONFIG_RECORD="/etc/tunnel64.conf"
LIST_FILE="/etc/tunnel64-ips.list"

IFACE="he68"
TABLE="201"
RULE_PREF="32764"

[ -f "$CONFIG_RECORD" ] || exit 0

source "$CONFIG_RECORD"

[ -n "$T64_LOCAL_V4" ] || exit 0
[ -n "$T64_REMOTE_V4" ] || exit 0
[ -n "$T64_TUNNEL_IPV6" ] || exit 0
[ -n "$T64_ROUTED_PREFIX" ] || exit 0

# 删除残留旧接口
ip tunnel del "$IFACE" 2>/dev/null || true

# 创建 SIT / 6in4 隧道
ip tunnel add "$IFACE" \
    mode sit \
    remote "$T64_REMOTE_V4" \
    local "$T64_LOCAL_V4" \
    ttl 255 2>/dev/null || exit 1

ip link set "$IFACE" up mtu "${T64_MTU:-1480}"

# Tunnel IPv6
ip -6 addr replace "$T64_TUNNEL_IPV6" dev "$IFACE"

# 仅给 Tunnel64 Routed Prefix 建立主表精确路由
ip -6 route replace "$T64_ROUTED_PREFIX" dev "$IFACE"

# Tunnel64 专用策略路由表
ip -6 route replace default dev "$IFACE" table "$TABLE"

# 删除同优先级旧规则，避免重复
while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done

# Tunnel64 源地址策略路由
ip -6 rule add \
    pref "$RULE_PREF" \
    from "$T64_ROUTED_PREFIX" \
    lookup "$TABLE"

# 恢复 lo 上的附加 IPv6
if [ -f "$LIST_FILE" ]; then
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        ip -6 addr replace "$ip/128" dev lo 2>/dev/null || true
    done < "$LIST_FILE"
fi

exit 0
EOF

    chmod +x "$T64_RESTORE_BIN"

    cat > "$T64_RESTORE_SERVICE" << EOF
[Unit]
Description=Tunnel64 IPv6 Restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$T64_RESTORE_BIN
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tunnel64-restore.service >/dev/null 2>&1
}

remove_systemd_restore(){
    systemctl disable tunnel64-restore.service >/dev/null 2>&1 || true
    systemctl stop tunnel64-restore.service >/dev/null 2>&1 || true

    rm -f "$T64_RESTORE_SERVICE"
    rm -f "$T64_RESTORE_BIN"

    systemctl daemon-reload
}

setup_tunnel_runtime(){
    local OLD_IFACE_EXISTS=0

    if ip link show "$T64_IFACE" >/dev/null 2>&1; then
        OLD_IFACE_EXISTS=1
        ip link set "$T64_IFACE" down 2>/dev/null || true
        ip tunnel del "$T64_IFACE" 2>/dev/null || true
    fi

    ip tunnel add "$T64_IFACE" \
        mode sit \
        remote "$T64_REMOTE_V4" \
        local "$T64_LOCAL_V4" \
        ttl 255

    if [ $? -ne 0 ]; then
        echo "错误: 无法创建 Tunnel64 隧道接口"
        return 1
    fi

    ip link set "$T64_IFACE" up mtu "$T64_MTU"

    if ! ip -6 addr replace "$T64_TUNNEL_IPV6" dev "$T64_IFACE"; then
        echo "错误: Tunnel64 隧道 IPv6 设置失败"
        ip tunnel del "$T64_IFACE" 2>/dev/null || true
        return 1
    fi

    # 不修改主表默认路由
    ip -6 route replace "$T64_ROUTED_PREFIX" dev "$T64_IFACE"

    # Tunnel64 专用策略路由表
    ip -6 route replace default dev "$T64_IFACE" table "$T64_TABLE"

    # 删除我们自己的旧规则，避免重复
    while ip -6 rule del pref "$T64_RULE_PREF" 2>/dev/null; do :; done

    # 只让 Tunnel64 Routed Prefix 走 Tunnel64
    ip -6 rule add \
        pref "$T64_RULE_PREF" \
        from "$T64_ROUTED_PREFIX" \
        lookup "$T64_TABLE"

    if [ $? -ne 0 ]; then
        echo "错误: Tunnel64 IPv6 策略路由规则添加失败"
        ip tunnel del "$T64_IFACE" 2>/dev/null || true
        return 1
    fi

    echo
    echo "Tunnel64 运行状态:"
    ip link show "$T64_IFACE"
    echo
    echo "Tunnel IPv6:"
    ip -6 addr show dev "$T64_IFACE" | grep 'scope global' || true
    echo
    echo "Tunnel64 Routed Prefix:"
    ip -6 route show "$T64_ROUTED_PREFIX"
    echo
    echo "策略路由:"
    ip -6 rule show | grep -E "pref $T64_RULE_PREF|$T64_ROUTED_PREFIX"
    echo
    echo "策略路由表:"
    ip -6 route show table "$T64_TABLE"

    return 0
}

# ==========================================
# 添加 / 重置 Tunnel64
# ==========================================

add_tunnel64(){
    echo "========== 添加 / 重置 Tunnel64 =========="
    echo

    load_record

    local INPUT

    read -p "Tunnel64 本机 IPv4 [${T64_LOCAL_V4:-192.255.175.7}]: " INPUT
    T64_LOCAL_V4="${INPUT:-${T64_LOCAL_V4:-192.255.175.7}}"

    read -p "Tunnel64 服务端 IPv4 [${T64_REMOTE_V4:-171.25.158.4}]: " INPUT
    T64_REMOTE_V4="${INPUT:-${T64_REMOTE_V4:-171.25.158.4}}"

    read -p "Tunnel IPv6 地址 [${T64_TUNNEL_IPV6:-2a01:7900:200:44::2/64}]: " INPUT
    T64_TUNNEL_IPV6="${INPUT:-${T64_TUNNEL_IPV6:-2a01:7900:200:44::2/64}}"

    read -p "Routed IPv6 前缀 [${T64_ROUTED_PREFIX:-2a01:7900:201:44::/64}]: " INPUT
    T64_ROUTED_PREFIX="${INPUT:-${T64_ROUTED_PREFIX:-2a01:7900:201:44::/64}}"

    read -p "MTU [${T64_MTU:-1480}]: " INPUT
    T64_MTU="${INPUT:-${T64_MTU:-1480}}"

    if [[ ! "$T64_LOCAL_V4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误: 本机 IPv4 格式不正确"
        return 1
    fi

    if [[ ! "$T64_REMOTE_V4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误: 服务端 IPv4 格式不正确"
        return 1
    fi

    if [[ ! "$T64_TUNNEL_IPV6" =~ ^.*\/64$ ]]; then
        echo "错误: Tunnel IPv6 必须使用 /64"
        return 1
    fi

    if [[ ! "$T64_ROUTED_PREFIX" =~ ^.*\/64$ ]]; then
        echo "错误: Routed IPv6 前缀必须使用 /64"
        return 1
    fi

    echo
    echo "========== Tunnel64 配置总览 =========="
    echo "本机 IPv4      : $T64_LOCAL_V4"
    echo "服务端 IPv4    : $T64_REMOTE_V4"
    echo "Tunnel IPv6    : $T64_TUNNEL_IPV6"
    echo "Routed Prefix  : $T64_ROUTED_PREFIX"
    echo "接口           : $T64_IFACE"
    echo "策略路由表     : $T64_TABLE"
    echo "规则优先级     : $T64_RULE_PREF"
    echo "MTU            : $T64_MTU"
    echo "默认路由       : 不修改 main 表"
    echo "========================================"
    echo

    read -p "确认应用 Tunnel64 配置? [y/N]: " OK
    if [ "$OK" != "y" ] && [ "$OK" != "Y" ]; then
        echo "取消操作"
        return
    fi

    echo
    echo "正在配置 Tunnel64..."

    if ! setup_tunnel_runtime; then
        echo "Tunnel64 配置失败"
        return 1
    fi

    save_record
    setup_systemd_restore

    echo
    echo "========================================"
    echo "Tunnel64 配置成功并已立即生效！"
    echo
    echo "接口       : $T64_IFACE"
    echo "Routed IPv6: $T64_ROUTED_PREFIX"
    echo
    echo "不会修改系统主 IPv6 默认路由"
    echo "只有 $T64_ROUTED_PREFIX 来源地址会走 Tunnel64"
    echo "========================================"
}

# ==========================================
# 删除 Tunnel64
# ==========================================

delete_tunnel64(){
    NEED_RESTART_SINGBOX=0

    echo "========== 删除 Tunnel64 =========="
    echo

    load_record

    # 1. 删除 sing-box Tunnel64 出站
    delete_all_singbox

    # 2. 删除 lo 上的 Tunnel64 附加 IPv6
    if [ -f "$T64_LIST_FILE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            ip -6 addr del "$ip/128" dev lo 2>/dev/null || true
        done < "$T64_LIST_FILE"
    fi

    # 3. 删除 Tunnel64 策略路由
    while ip -6 rule del pref "$T64_RULE_PREF" 2>/dev/null; do :; done

    ip -6 route flush table "$T64_TABLE" 2>/dev/null || true

    if [ -n "$T64_ROUTED_PREFIX" ]; then
        ip -6 route del "$T64_ROUTED_PREFIX" dev "$T64_IFACE" 2>/dev/null || true
    fi

    # 4. 删除 Tunnel64 接口
    ip link set "$T64_IFACE" down 2>/dev/null || true
    ip tunnel del "$T64_IFACE" 2>/dev/null || true

    # 5. 删除持久化配置
    remove_systemd_restore

    rm -f "$T64_CONFIG_RECORD"
    rm -f "$T64_LIST_FILE"

    echo "Tunnel64 隧道、策略路由、附加 IPv6 已清除"

    # 6. 只有真正删除 sing-box route.json 规则时才重启
    restart_singbox_if_needed

    echo
    echo "========================================"
    echo "Tunnel64 已彻底删除"
    echo "========================================"
}

# ==========================================
# 添加附加 IPv6
# ==========================================

add_ipv6(){
    load_record

    if [ -z "$T64_ROUTED_PREFIX" ]; then
        echo "未检测到 Tunnel64 Routed IPv6 前缀"
        echo "请先通过选项 1 添加 Tunnel64"
        read -p "按回车键继续..."
        return
    fi

    if ! ip link show "$T64_IFACE" >/dev/null 2>&1; then
        echo "错误: Tunnel64 接口 $T64_IFACE 当前不存在"
        read -p "按回车键继续..."
        return
    fi

    local PREFIX
    PREFIX="${T64_ROUTED_PREFIX%/*}"

    local RETRY=0
    local MAX_RETRY=10
    local NEW_IPV6=""

    while [ "$RETRY" -lt "$MAX_RETRY" ]; do
        NEW_IPV6=$(generate_ipv6 "$PREFIX")

        if grep -qsxF "$NEW_IPV6" "$T64_LIST_FILE" 2>/dev/null \
        || ip -6 addr show dev lo | grep -qsF "$NEW_IPV6" \
        || ip -6 addr show dev "$T64_IFACE" | grep -qsF "$NEW_IPV6"; then

            RETRY=$((RETRY + 1))
        else
            break
        fi
    done

    if [ "$RETRY" -ge "$MAX_RETRY" ]; then
        echo "错误: 连续 $MAX_RETRY 次未能生成唯一 IPv6"
        read -p "按回车键继续..."
        return
    fi

    echo
    echo "准备添加 IPv6:"
    echo "$NEW_IPV6"
    echo

    # 先写 sing-box
    if ! add_singbox_outbound "$NEW_IPV6"; then
        echo "错误: 写入 sing-box 出站配置失败"
        read -p "按回车键继续..."
        return
    fi

    # 再绑定到 lo
    if ! ip -6 addr add "$NEW_IPV6/128" dev lo 2>/dev/null; then
        echo "错误: IPv6 绑定到 lo 失败"
        echo "正在自动回滚 sing-box 出站..."
        delete_singbox_outbound "$NEW_IPV6"
        read -p "按回车键继续..."
        return
    fi

    # 记录
    mkdir -p "$(dirname "$T64_LIST_FILE")"
    echo "$NEW_IPV6" >> "$T64_LIST_FILE"

    echo
    echo "========================================"
    echo "✓ Tunnel64 附加 IPv6 添加成功"
    echo "IPv6: $NEW_IPV6"
    echo "接口: lo"
    echo "sing-box 出站已写入"
    echo "未重启 sing-box"
    echo "========================================"

    read -p "按回车键继续..."
}

# ==========================================
# 删除附加 IPv6
# ==========================================

delete_ipv6(){
    NEED_RESTART_SINGBOX=0

    if [ ! -f "$T64_LIST_FILE" ] || [ ! -s "$T64_LIST_FILE" ]; then
        echo "没有可删除的 Tunnel64 附加 IPv6"
        read -p "按回车键继续..."
        return
    fi

    echo "========== 当前 Tunnel64 IPv6 =========="
    list_ipv6
    echo

    read -p "输入要删除的编号: " NUM

    if ! [[ "$NUM" =~ ^[1-9][0-9]*$ ]]; then
        echo "错误: 输入的编号无效"
        read -p "按回车键继续..."
        return
    fi

    local TOTAL_LINES
    TOTAL_LINES=$(wc -l < "$T64_LIST_FILE")

    if [ "$NUM" -gt "$TOTAL_LINES" ]; then
        echo "错误: 编号超出范围"
        read -p "按回车键继续..."
        return
    fi

    local DEL_IP
    DEL_IP=$(sed -n "${NUM}p" "$T64_LIST_FILE")

    echo
    echo "正在删除: $DEL_IP"

    # 删除系统地址
    ip -6 addr del "$DEL_IP/128" dev lo 2>/dev/null || true

    # 删除 sing-box 出站
    delete_singbox_outbound "$DEL_IP"

    # 删除记录
    sed -i "${NUM}d" "$T64_LIST_FILE"

    echo
    echo "IPv6 已删除: $DEL_IP"

    # 仅 route.json 真正发生删除时重启
    if [ "$NEED_RESTART_SINGBOX" -eq 1 ]; then
        echo "检测到删除了 sing-box 路由规则"
        if systemctl is-active sing-box >/dev/null 2>&1; then
            systemctl restart sing-box
            echo "sing-box 已重启"
        fi
    else
        echo "未删除 sing-box 路由规则"
        echo "sing-box 未重启"
    fi

    read -p "按回车键继续..."
}

# ==========================================
# 状态
# ==========================================

status(){
    clear

    load_record

    echo "========== Tunnel64 隧道设备状态 =========="
    ip link show "$T64_IFACE" 2>/dev/null || echo "隧道设备未启动"

    echo
    echo "========== Tunnel64 隧道 IPv6 =========="
    ip -6 addr show dev "$T64_IFACE" 2>/dev/null \
        | grep 'scope global' \
        | awk '{print $2}' \
        || echo "无"

    echo
    echo "========== Tunnel64 Routed Prefix =========="
    if [ -n "$T64_ROUTED_PREFIX" ]; then
        ip -6 route show "$T64_ROUTED_PREFIX" 2>/dev/null || echo "无精确路由"
    else
        echo "未配置"
    fi

    echo
    echo "========== Tunnel64 策略路由规则 =========="
    ip -6 rule show | grep -E "pref $T64_RULE_PREF|$T64_ROUTED_PREFIX" \
        || echo "无 Tunnel64 策略规则"

    echo
    echo "========== Tunnel64 路由表 $T64_TABLE =========="
    ip -6 route show table "$T64_TABLE" 2>/dev/null || echo "无"

    echo
    echo "========== lo 接口 Tunnel64 附加 IPv6 =========="

    if [ -f "$T64_LIST_FILE" ] && [ -s "$T64_LIST_FILE" ]; then
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue

            if ip -6 addr show dev lo | grep -qsF "$ip"; then
                echo "✓ $ip"
            else
                echo "✗ $ip (记录存在但系统未绑定)"
            fi
        done < "$T64_LIST_FILE"
    else
        echo "无附加记录"
    fi

    echo
    echo "========== Tunnel64 sing-box 出站 =========="

    if [ -f "$OUTBOUND_FILE" ]; then
        jq -r '
            .outbounds[]?
            | select(
                ((.tag // "") | startswith("tunnel64-ipv6-"))
            )
            | "tag=\(.tag)  ipv6=\(.inet6_bind_address)"
        ' "$OUTBOUND_FILE" 2>/dev/null \
        || echo "无"
    else
        echo "outbounds.json 不存在"
    fi

    echo
    echo "========== Tunnel64 配置 =========="
    echo "本机 IPv4   : ${T64_LOCAL_V4:-未配置}"
    echo "服务端 IPv4 : ${T64_REMOTE_V4:-未配置}"
    echo "Tunnel IPv6 : ${T64_TUNNEL_IPV6:-未配置}"
    echo "Routed Prefix: ${T64_ROUTED_PREFIX:-未配置}"
    echo "接口        : $T64_IFACE"
    echo "MTU         : ${T64_MTU:-1480}"

    echo
    read -p "按回车键返回主菜单..."
}

# ==========================================
# IPv6 测试
# ==========================================

test_ipv6(){
    echo
    echo "========== Tunnel64 IPv6 全部 IP 测试 =========="
    echo

    if [ ! -f "$T64_LIST_FILE" ] || [ ! -s "$T64_LIST_FILE" ]; then
        echo "未找到 Tunnel64 附加 IPv6 地址列表"
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

        local START_TIME
        local END_TIME
        local COST
        local RESULT
        local CURL_STATUS

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
            echo "✓ 连通成功"
            echo "出口 IPv6: $RESULT"
            echo "耗时: ${COST} ms"
        else
            failed=$((failed + 1))
            echo "✗ 连通失败"
            echo "耗时: ${COST} ms"
        fi

    done < "$T64_LIST_FILE"

    echo
    echo "========================================"
    echo "测试完成"
    echo "总数: $total"
    echo "成功: $success"
    echo "失败: $failed"
    echo "========================================"

    read -p "按回车键继续..."
}

# ==========================================
# Tunnel64 路由测试
# ==========================================

test_route(){
    load_record

    echo
    echo "========== Tunnel64 路由测试 =========="
    echo

    if [ -z "$T64_ROUTED_PREFIX" ]; then
        echo "未配置 Tunnel64 Routed Prefix"
        read -p "按回车键继续..."
        return
    fi

    local TEST_IP

    read -p "请输入 Tunnel64 IPv6 地址进行路由测试: " TEST_IP

    if [ -z "$TEST_IP" ]; then
        echo "未输入 IPv6"
        read -p "按回车键继续..."
        return
    fi

    echo
    echo "========== route get =========="

    ip -6 route get \
        2606:4700:4700::1111 \
        from "$TEST_IP"

    echo
    echo "========== ping Tunnel64 对端 =========="

    ping -6 \
        -I "$TEST_IP" \
        -c 3 \
        -W 3 \
        2a01:7900:200:44::1

    echo
    read -p "按回车键继续..."
}

# ==========================================
# 菜单
# ==========================================

menu(){
    while true
    do
        clear

        echo "========== Tunnel64 IPv6 隧道 =========="
        echo "1. 添加/重置 Tunnel64 隧道"
        echo "2. 删除 Tunnel64 隧道"
        echo "3. 随机添加附加 IPv6 地址"
        echo "4. 删除指定附加 IPv6 地址"
        echo "5. 查看网卡与 IPv6 状态"
        echo "6. 测试 IPv6 出口连通性"
        echo "7. 测试 Tunnel64 路由"
        echo "0. 退出"
        echo "========================================"

        read -p "选择 [0-7]: " CHOOSE

        case "$CHOOSE" in
            1)
                add_tunnel64
                read -p "按回车键继续..."
                ;;
            2)
                delete_tunnel64
                read -p "按回车键继续..."
                ;;
            3)
                add_ipv6
                ;;
            4)
                delete_ipv6
                ;;
            5)
                status
                ;;
            6)
                test_ipv6
                ;;
            7)
                test_route
                ;;
            0)
                exit 0
                ;;
            *)
                echo "输入错误，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

install_dep
menu

