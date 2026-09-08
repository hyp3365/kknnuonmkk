#!/bin/bash

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

[ "$(id -u)" != "0" ] && echo "错误: 请使用 root 权限运行此脚本！" && exit 1

install_dep(){
    if command -v apt-get >/dev/null 2>&1; then
        local PKGS=()
        command -v curl >/dev/null 2>&1 || PKGS+=(curl)
        command -v ip >/dev/null 2>&1 || PKGS+=(iproute2)
        command -v awk >/dev/null 2>&1 || PKGS+=(gawk)
        if [ "${#PKGS[@]}" -gt 0 ]; then
            apt-get update -y
            apt-get install -y "${PKGS[@]}"
        fi
    fi
    for cmd in curl ip awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "错误: 缺少核心依赖: $cmd"
            exit 1
        fi
    done
}

generate_ipv6(){
    local prefix="${1%/*}"
    prefix="${prefix%%::*}"
    local hex=$(tr -d '-' < /proc/sys/kernel/random/uuid)
    printf '%s:%s:%s:%s:%s\n' "$prefix" "${hex:0:4}" "${hex:4:4}" "${hex:8:4}" "${hex:12:4}"
}

load_record(){
    [ -f "$T64_CONFIG_RECORD" ] && source "$T64_CONFIG_RECORD"
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

ip tunnel del "$IFACE" 2>/dev/null || true
ip tunnel add "$IFACE" mode sit remote "$T64_REMOTE_V4" local "$T64_LOCAL_V4" ttl 255 2>/dev/null || exit 1
ip link set "$IFACE" up mtu "${T64_MTU:-1480}"
ip -6 addr replace "$T64_TUNNEL_IPV6" dev "$IFACE"

# 主表路由
ip -6 route replace "$T64_TUNNEL_IPV6" dev "$IFACE" 2>/dev/null || true
ip -6 route replace "$T64_ROUTED_PREFIX" dev "$IFACE"

# Table 201 路由表补全
ip -6 route replace "$T64_TUNNEL_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null || true
ip -6 route replace "$T64_ROUTED_PREFIX" dev "$IFACE" table "$TABLE"
ip -6 route replace default dev "$IFACE" table "$TABLE"

while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
ip -6 rule add pref "$RULE_PREF" from "$T64_ROUTED_PREFIX" lookup "$TABLE"

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
    rm -f "$T64_RESTORE_SERVICE" "$T64_RESTORE_BIN"
    systemctl daemon-reload
}

setup_tunnel_runtime(){
    if ip link show "$T64_IFACE" >/dev/null 2>&1; then
        ip link set "$T64_IFACE" down 2>/dev/null || true
        ip tunnel del "$T64_IFACE" 2>/dev/null || true
    fi

    ip tunnel add "$T64_IFACE" mode sit remote "$T64_REMOTE_V4" local "$T64_LOCAL_V4" ttl 255 || return 1
    ip link set "$T64_IFACE" up mtu "$T64_MTU"

    ip -6 addr replace "$T64_TUNNEL_IPV6" dev "$T64_IFACE" || { ip tunnel del "$T64_IFACE" 2>/dev/null; return 1; }

    # 主表路由
    ip -6 route replace "$T64_TUNNEL_IPV6" dev "$T64_IFACE" 2>/dev/null || true
    ip -6 route replace "$T64_ROUTED_PREFIX" dev "$T64_IFACE"

    # Table 201 专用路由表补全
    ip -6 route replace "$T64_TUNNEL_IPV6" dev "$T64_IFACE" table "$T64_TABLE" 2>/dev/null || true
    ip -6 route replace "$T64_ROUTED_PREFIX" dev "$T64_IFACE" table "$T64_TABLE"
    ip -6 route replace default dev "$T64_IFACE" table "$T64_TABLE"

    while ip -6 rule del pref "$T64_RULE_PREF" 2>/dev/null; do :; done
    ip -6 rule add pref "$T64_RULE_PREF" from "$T64_ROUTED_PREFIX" lookup "$T64_TABLE" || { ip tunnel del "$T64_IFACE" 2>/dev/null; return 1; }
    return 0
}

add_tunnel64(){
    echo "========== 添加 / 重置 Tunnel64 =========="
    echo "请直接粘贴隧道配置/命令文本（连续按两次回车结束）："
    local PASTE_DATA=""
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && break
        PASTE_DATA="$PASTE_DATA
$line"
    done

    # 精准抽取 Remote IPv4 (兼容 Server IPv4 文本 与 ip tunnel 命令)
    T64_REMOTE_V4=$(echo "$PASTE_DATA" | grep -i 'Server IPv4' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
    [ -z "$T64_REMOTE_V4" ] && T64_REMOTE_V4=$(echo "$PASTE_DATA" | awk -F'remote' '{print $2}' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)

    # 精准抽取 Local IPv4 (兼容 Client IPv4 文本 与 ip tunnel 命令)
    T64_LOCAL_V4=$(echo "$PASTE_DATA" | grep -i 'Client IPv4' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
    [ -z "$T64_LOCAL_V4" ] && T64_LOCAL_V4=$(echo "$PASTE_DATA" | awk -F'local' '{print $2}' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)

    # 精准抽取 Tunnel IPv6
    T64_TUNNEL_IPV6=$(echo "$PASTE_DATA" | grep -iE 'Client IPv6|ip addr add' | grep -oE '([0-9a-fA-F:]+)/64' | head -n1)
    [ -z "$T64_TUNNEL_IPV6" ] && T64_TUNNEL_IPV6=$(echo "$PASTE_DATA" | grep -oE '([0-9a-fA-F:]+)/64' | head -n1)

    T64_MTU="1480"

    echo
    read -p "请输入 Routed IPv6 前缀 (例如 2a01:7900:201:44::/64): " T64_ROUTED_PREFIX

    if [ -z "$T64_LOCAL_V4" ] || [ -z "$T64_REMOTE_V4" ] || [ -z "$T64_TUNNEL_IPV6" ] || [ -z "$T64_ROUTED_PREFIX" ]; then
        echo "错误: 解析配置失败或 Routed IPv6 不能为空！"
        return 1
    fi

    echo
    echo "========== Tunnel64 配置确认 =========="
    echo "本机 IPv4   : $T64_LOCAL_V4"
    echo "服务端 IPv4 : $T64_REMOTE_V4"
    echo "Tunnel IPv6 : $T64_TUNNEL_IPV6"
    echo "Routed Prefix: $T64_ROUTED_PREFIX"
    echo "MTU         : $T64_MTU"
    echo "提示        : 已安全隔离主表默认路由，流量仅在 Table 201 内走隧道"
    echo "========================================"

    read -p "确认应用并保存配置? [y/N]: " OK
    if [[ "$OK" != "y" && "$OK" != "Y" ]]; then
        echo "取消操作"
        return
    fi

    if ! setup_tunnel_runtime; then
        echo "Tunnel64 配置失败"
        return 1
    fi

    save_record
    setup_systemd_restore
    echo "Tunnel64 配置成功并已立即生效！"
}

delete_tunnel64(){
    echo "========== 删除 Tunnel64 =========="
    load_record

    if [ -f "$T64_LIST_FILE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            ip -6 addr del "$ip/128" dev lo 2>/dev/null || true
        done < "$T64_LIST_FILE"
    fi

    while ip -6 rule del pref "$T64_RULE_PREF" 2>/dev/null; do :; done
    ip -6 route flush table "$T64_TABLE" 2>/dev/null || true
    [ -n "$T64_ROUTED_PREFIX" ] && ip -6 route del "$T64_ROUTED_PREFIX" dev "$T64_IFACE" 2>/dev/null || true

    ip link set "$T64_IFACE" down 2>/dev/null || true
    ip tunnel del "$T64_IFACE" 2>/dev/null || true

    remove_systemd_restore
    rm -f "$T64_CONFIG_RECORD" "$T64_LIST_FILE"
    echo "Tunnel64 已彻底删除"
}

add_ipv6(){
    load_record
    if [ -z "$T64_ROUTED_PREFIX" ] || ! ip link show "$T64_IFACE" >/dev/null 2>&1; then
        echo "错误: 隧道未正确设置或接口不存在"
        read -p "按回车键继续..."
        return
    fi

    local PREFIX="$T64_ROUTED_PREFIX"
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
        echo "错误: 未能生成唯一 IPv6"
        read -p "按回车键继续..."
        return
    fi

    if ! ip -6 addr add "$NEW_IPV6/128" dev lo 2>/dev/null; then
        echo "错误: IPv6 绑定到 lo 失败"
        read -p "按回车键继续..."
        return
    fi

    mkdir -p "$(dirname "$T64_LIST_FILE")"
    echo "$NEW_IPV6" >> "$T64_LIST_FILE"
    echo "✓ 附加 IPv6 添加成功: $NEW_IPV6"

    if ip -6 route get 2606:4700:4700::1111 from "$NEW_IPV6" 2>/dev/null | grep -qs "$T64_IFACE"; then
        echo "✓ 路由校验通过: $NEW_IPV6 已成功匹配表 $T64_TABLE ($T64_IFACE 出口)"
    else
        echo "⚠️ 警告: 策略路由匹配异常，请检查策略路由表 $T64_TABLE"
    fi

    read -p "按回车键继续..."
}

delete_ipv6(){
    if [ ! -f "$T64_LIST_FILE" ] || [ ! -s "$T64_LIST_FILE" ]; then
        echo "没有可删除的附加 IPv6"
        read -p "按回车键继续..."
        return
    fi

    list_ipv6
    read -p "输入要删除的编号: " NUM
    if ! [[ "$NUM" =~ ^[1-9][0-9]*$ ]]; then
        echo "错误: 输入无效"
        read -p "按回车键继续..."
        return
    fi

    local DEL_IP=$(sed -n "${NUM}p" "$T64_LIST_FILE")
    ip -6 addr del "$DEL_IP/128" dev lo 2>/dev/null || true
    sed -i "${NUM}d" "$T64_LIST_FILE"
    echo "IPv6 已删除: $DEL_IP"
    read -p "按回车键继续..."
}

status(){
    clear
    load_record
    echo "========== Tunnel64 状态 =========="
    ip link show "$T64_IFACE" 2>/dev/null || echo "隧道设备未启动"
    echo "Tunnel IPv6: $(ip -6 addr show dev "$T64_IFACE" 2>/dev/null | grep 'scope global' | awk '{print $2}' || echo '无')"
    echo "Routed Prefix: ${T64_ROUTED_PREFIX:-未配置}"
    echo "策略路由表 $T64_TABLE: $(ip -6 route show table "$T64_TABLE" 2>/dev/null || echo '无')"
    echo
    echo "========== lo 附加 IPv6 =========="
    if [ -f "$T64_LIST_FILE" ] && [ -s "$T64_LIST_FILE" ]; then
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            ip -6 addr show dev lo | grep -qsF "$ip" && echo "✓ $ip" || echo "✗ $ip (未绑定)"
        done < "$T64_LIST_FILE"
    else
        echo "无附加记录"
    fi
    echo
    read -p "按回车键返回..."
}

test_ipv6(){
    echo "========== IPv6 出口测试 =========="
    if [ ! -f "$T64_LIST_FILE" ] || [ ! -s "$T64_LIST_FILE" ]; then
        echo "未找到 IPv6 列表"
        read -p "按回车键继续..."
        return
    fi

    local total=0 success=0 failed=0
    while IFS= read -r TEST_IP; do
        [ -z "$TEST_IP" ] && continue
        total=$((total + 1))
        local RESULT=$(curl -6 --interface "$TEST_IP" --connect-timeout 5 --max-time 8 -sS https://ip.sb 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$RESULT" ]; then
            success=$((success + 1))
            echo "✓ [$TEST_IP] 成功 -> 出口: $RESULT"
        else
            failed=$((failed + 1))
            echo "✗ [$TEST_IP] 失败"
        fi
    done < "$T64_LIST_FILE"

    echo "测试完成: 总计 $total | 成功 $success | 失败 $failed"
    read -p "按回车键继续..."
}

test_route(){
    load_record
    [ -z "$T64_ROUTED_PREFIX" ] && echo "未配置 Routed Prefix" && return
    read -p "请输入测试用的 IPv6 地址: " TEST_IP
    [ -z "$TEST_IP" ] && return
    echo "========== route get =========="
    ip -6 route get 2606:4700:4700::1111 from "$TEST_IP"
    echo "========== ping 对端 =========="
    ping -6 -I "$TEST_IP" -c 3 -W 3 2a01:7900:200:44::1
    read -p "按回车键继续..."
}

menu(){
    while true; do
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
            1) add_tunnel64; read -p "按回车键继续..." ;;
            2) delete_tunnel64; read -p "按回车键继续..." ;;
            3) add_ipv6 ;;
            4) delete_ipv6 ;;
            5) status ;;
            6) test_ipv6 ;;
            7) test_route ;;
            0) exit 0 ;;
            *) echo "输入错误！"; sleep 1 ;;
        esac
    done
}

install_dep
menu
