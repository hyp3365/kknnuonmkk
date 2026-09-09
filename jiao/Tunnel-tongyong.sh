#!/bin/bash

CONFIG_DIR="/etc/tunnel64"
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
    for cmd in curl ip awk sed tr; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "错误: 缺少核心依赖: $cmd"
            exit 1
        fi
    done
    mkdir -p "$CONFIG_DIR"
}

generate_ipv6(){
    local prefix_str="$1"
    local network="${prefix_str%/*}"  # 提取前缀部分，例如 2001:470:1234::
    local cidr="${prefix_str#*/}"     # 提取掩码部分，例如 48 或 64
    
    # 移除末尾的 :: 和 :
    network=$(echo "$network" | sed 's/:*$//')

    local hex=$(tr -d '-' < /proc/sys/kernel/random/uuid)
    if [ "$cidr" = "48" ]; then
        # /48 需要补齐 5 个段 (16位 x 5)
        printf '%s:%s:%s:%s:%s:%s\n' "$network" "${hex:0:4}" "${hex:4:4}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}"
    else
        # 默认当做 /64 处理，补齐 4 个段 (16位 x 4)
        printf '%s:%s:%s:%s:%s\n' "$network" "${hex:0:4}" "${hex:4:4}" "${hex:8:4}" "${hex:12:4}"
    fi
}

update_systemd_restore(){
    cat > "$T64_RESTORE_BIN" << 'EOF'
#!/bin/bash
CONFIG_DIR="/etc/tunnel64"
[ -d "$CONFIG_DIR" ] || exit 0

for conf in "$CONFIG_DIR"/*.conf; do
    [ -f "$conf" ] || continue
    source "$conf"
    [ -n "$IFACE" ] || continue
    [ -n "$LOCAL_V4" ] && [ -n "$REMOTE_V4" ] && [ -n "$TUNNEL_IPV6" ] && [ -n "$ROUTED_PREFIX" ] || continue

    ip tunnel del "$IFACE" 2>/dev/null || true
    ip tunnel add "$IFACE" mode sit remote "$REMOTE_V4" local "$LOCAL_V4" ttl 255 2>/dev/null || continue
    ip link set "$IFACE" up mtu "${MTU:-1480}"
    ip -6 addr replace "$TUNNEL_IPV6" dev "$IFACE"

    # 主表路由 (绝不添加 default 路由到主表)
    ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" 2>/dev/null || true
    ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true

    # 策略路由表
    TABLE="${TABLE:-201}"
    RULE_PREF="${RULE_PREF:-32764}"
    ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null || true
    ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null || true
    ip -6 route replace default dev "$IFACE" table "$TABLE"

    while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
    ip -6 rule add pref "$RULE_PREF" from "$ROUTED_PREFIX" lookup "$TABLE"

    LIST_FILE="${CONFIG_DIR}/${IFACE}-ips.list"
    if [ -f "$LIST_FILE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            ip -6 addr replace "$ip/128" dev lo 2>/dev/null || true
        done < "$LIST_FILE"
    fi
done
exit 0
EOF
    chmod +x "$T64_RESTORE_BIN"

    cat > "$T64_RESTORE_SERVICE" << EOF
[Unit]
Description=Tunnel64 Multi-Tunnel Restore
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

remove_systemd_restore_if_empty(){
    if [ -z "$(ls -A "$CONFIG_DIR"/*.conf 2>/dev/null)" ]; then
        systemctl disable tunnel64-restore.service >/dev/null 2>&1 || true
        systemctl stop tunnel64-restore.service >/dev/null 2>&1 || true
        rm -f "$T64_RESTORE_SERVICE" "$T64_RESTORE_BIN"
        systemctl daemon-reload
    fi
}

setup_tunnel_runtime(){
    if ip link show "$IFACE" >/dev/null 2>&1; then
        ip link set "$IFACE" down 2>/dev/null || true
        ip tunnel del "$IFACE" 2>/dev/null || true
    fi

    ip tunnel add "$IFACE" mode sit remote "$REMOTE_V4" local "$LOCAL_V4" ttl 255 || return 1
    ip link set "$IFACE" up mtu "$MTU"

    ip -6 addr replace "$TUNNEL_IPV6" dev "$IFACE" || { ip tunnel del "$IFACE" 2>/dev/null; return 1; }

    # 主表路由 (禁止添加 default，保证不污染主路由)
    ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" 2>/dev/null || true
    ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true

    # 专用路由表补全
    ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null || true
    ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null || true
    ip -6 route replace default dev "$IFACE" table "$TABLE"

    while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
    ip -6 rule add pref "$RULE_PREF" from "$ROUTED_PREFIX" lookup "$TABLE" || { ip tunnel del "$IFACE" 2>/dev/null; return 1; }
    return 0
}

add_tunnel64(){
    echo "========== 添加新 Tunnel64 隧道 =========="
    
    # 1. 隧道名称
    read -p "请输入隧道名称 (直接回车随机生成): " IFACE
    if [ -z "$IFACE" ]; then
        # 随机生成类似 tunA1B2 格式
        IFACE="tun$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
        echo "已自动生成隧道名: $IFACE"
    fi

    if [ -f "$CONFIG_DIR/$IFACE.conf" ]; then
        echo "错误: 接口 $IFACE 配置文件已存在！请先删除。"
        return 1
    fi

    echo
    # 2. 服务端 IPv4
    read -p "请输入服务端 IPv4 地址: " REMOTE_V4

    # 3. 客户端 IPv4 (尝试自动获取本机IP)
    local default_local_v4=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+')
    [ -z "$default_local_v4" ] && default_local_v4=$(curl -4 -s ifconfig.me 2>/dev/null)
    read -p "请输入客户端 IPv4 地址 (本机) [$default_local_v4]: " LOCAL_V4
    [ -z "$LOCAL_V4" ] && LOCAL_V4="$default_local_v4"

    echo
    # 4. 服务端 IPv6
    read -p "请输入服务端 IPv6 地址 (如 2001:470:1f10:xxx::1/64): " SERVER_IPV6

    # 5. 客户端 IPv6
    read -p "请输入客户端 IPv6 地址 (如 2001:470:1f10:xxx::2/64): " TUNNEL_IPV6

    echo
    # 6. Routed Prefix
    read -p "请输入 IPv6 路由前缀 (支持 /48 或 /64，如 2001:470:abcd::/48): " ROUTED_PREFIX

    local MTU="1480"

    if [ -z "$LOCAL_V4" ] || [ -z "$REMOTE_V4" ] || [ -z "$TUNNEL_IPV6" ] || [ -z "$SERVER_IPV6" ] || [ -z "$ROUTED_PREFIX" ]; then
        echo "错误: 所有 IP 参数均不能为空！"
        return 1
    fi

    # 自动分配路由表号与策略优先级 (保证不同隧道互不冲突)
    local max_table=200
    local min_pref=32765
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        local t_table=$(awk -F'"' '/^TABLE=/{print $2}' "$f")
        local t_pref=$(awk -F'"' '/^RULE_PREF=/{print $2}' "$f")
        [[ "$t_table" =~ ^[0-9]+$ ]] && [ "$t_table" -gt "$max_table" ] && max_table="$t_table"
        [[ "$t_pref" =~ ^[0-9]+$ ]] && [ "$t_pref" -lt "$min_pref" ] && min_pref="$t_pref"
    done
    local TABLE=$((max_table + 1))
    local RULE_PREF=$((min_pref - 1))

    echo
    echo "========== Tunnel64 配置确认 =========="
    echo "接口名称    : $IFACE"
    echo "本机 IPv4   : $LOCAL_V4"
    echo "服务端 IPv4 : $REMOTE_V4"
    echo "服务端 IPv6 : $SERVER_IPV6"
    echo "客户端 IPv6 : $TUNNEL_IPV6"
    echo "Routed Prefix: $ROUTED_PREFIX"
    echo "路由表编号  : $TABLE"
    echo "策略优先级  : $RULE_PREF"
    echo "说明        : 默认路由已安全隔离至独立 Table，绝不影响主网络"
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

    # 保存至独立配置文件
    cat > "$CONFIG_DIR/$IFACE.conf" <<EOF
IFACE="$IFACE"
LOCAL_V4="$LOCAL_V4"
REMOTE_V4="$REMOTE_V4"
SERVER_IPV6="$SERVER_IPV6"
TUNNEL_IPV6="$TUNNEL_IPV6"
ROUTED_PREFIX="$ROUTED_PREFIX"
MTU="$MTU"
TABLE="$TABLE"
RULE_PREF="$RULE_PREF"
EOF

    update_systemd_restore
    echo "✓ 隧道 $IFACE 添加成功并已生效！"
}

delete_tunnel(){
    local config_file="$1"
    local list_file="$2"
    source "$config_file"

    echo "========== 删除隧道: $IFACE =========="
    read -p "确认删除该隧道及其所有附加 IPv6 吗? [y/N]: " OK
    if [[ "$OK" != "y" && "$OK" != "Y" ]]; then
        return
    fi

    # 1. 清理 lo 网卡上绑定的附加 IPv6
    if [ -f "$list_file" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            ip -6 addr del "$ip/128" dev lo 2>/dev/null || true
        done < "$list_file"
    fi

    # 2. 清理策略路由规则
    while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
    ip -6 route flush table "$TABLE" 2>/dev/null || true

    # 3. 显式清理主表中的路由 (补上你提到的 TUNNEL_IPV6)
    [ -n "$ROUTED_PREFIX" ] && ip -6 route del "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true
    [ -n "$TUNNEL_IPV6" ] && ip -6 route del "$TUNNEL_IPV6" dev "$IFACE" 2>/dev/null || true

    # 4. 关闭并删除隧道网卡
    ip link set "$IFACE" down 2>/dev/null || true
    ip tunnel del "$IFACE" 2>/dev/null || true

    # 5. 清理配置文件并检查是否需要关闭自启服务
    rm -f "$config_file" "$list_file"
    remove_systemd_restore_if_empty
    
    echo "✓ 隧道 $IFACE 已彻底删除"
    read -p "按回车键返回..."
}


add_ipv6(){
    local config_file="$1"
    local list_file="$2"
    source "$config_file"

    if [ -z "$ROUTED_PREFIX" ] || ! ip link show "$IFACE" >/dev/null 2>&1; then
        echo "错误: 隧道未正确设置或接口不存在"
        read -p "按回车键继续..."
        return
    fi

    local RETRY=0
    local MAX_RETRY=10
    local NEW_IPV6=""

    while [ "$RETRY" -lt "$MAX_RETRY" ]; do
        NEW_IPV6=$(generate_ipv6 "$ROUTED_PREFIX")
        if grep -qsxF "$NEW_IPV6" "$list_file" 2>/dev/null \
        || ip -6 addr show dev lo | grep -qsF "$NEW_IPV6" \
        || ip -6 addr show dev "$IFACE" | grep -qsF "$NEW_IPV6"; then
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

    mkdir -p "$(dirname "$list_file")"
    echo "$NEW_IPV6" >> "$list_file"
    echo "✓ 附加 IPv6 添加成功: $NEW_IPV6"

    # 简单测试路由方向
    if ip -6 route get 2606:4700:4700::1111 from "$NEW_IPV6" 2>/dev/null | grep -qs "$IFACE"; then
        echo "✓ 路由校验通过: $NEW_IPV6 成功匹配策略路由表 $TABLE"
    else
        echo "⚠️ 警告: 策略路由匹配异常，该 IP 流量可能未走隧道"
    fi

    read -p "按回车键继续..."
}

delete_ipv6(){
    local config_file="$1"
    local list_file="$2"
    source "$config_file"

    if [ ! -f "$list_file" ] || [ ! -s "$list_file" ]; then
        echo "没有可删除的附加 IPv6"
        read -p "按回车键继续..."
        return
    fi

    echo "========== 附加 IPv6 列表 ($IFACE) =========="
    awk '{print NR". "$0}' "$list_file"
    echo "============================================="
    read -p "输入要删除的编号: " NUM
    if ! [[ "$NUM" =~ ^[1-9][0-9]*$ ]]; then
        echo "错误: 输入无效"
        read -p "按回车键继续..."
        return
    fi

    local DEL_IP=$(sed -n "${NUM}p" "$list_file")
    if [ -z "$DEL_IP" ]; then
        echo "错误: 编号不存在"
        read -p "按回车键继续..."
        return
    fi

    ip -6 addr del "$DEL_IP/128" dev lo 2>/dev/null || true
    sed -i "${NUM}d" "$list_file"
    echo "✓ IPv6 已删除: $DEL_IP"
    read -p "按回车键继续..."
}

status_tunnel(){
    local config_file="$1"
    local list_file="$2"
    source "$config_file"

    clear
    echo "========== 隧道状态: $IFACE =========="
    ip link show "$IFACE" 2>/dev/null || echo "隧道设备未启动"
    echo "Client IPv6   : $(ip -6 addr show dev "$IFACE" 2>/dev/null | grep 'scope global' | awk '{print $2}' || echo '无')"
    echo "Server IPv6   : ${SERVER_IPV6:-未配置}"
    echo "Routed Prefix : ${ROUTED_PREFIX:-未配置}"
    echo "策略路由表 $TABLE : $(ip -6 route show table "$TABLE" 2>/dev/null | tr '\n' ' ; ' || echo '无')"
    echo
    echo "========== lo 附加 IPv6 =========="
    if [ -f "$list_file" ] && [ -s "$list_file" ]; then
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            ip -6 addr show dev lo | grep -qsF "$ip" && echo "✓ $ip" || echo "✗ $ip (未绑定)"
        done < "$list_file"
    else
        echo "无附加记录"
    fi
    echo
    read -p "按回车键返回..."
}

test_ipv6(){
    local list_file="$1"
    if [ ! -f "$list_file" ] || [ ! -s "$list_file" ]; then
        echo "未找到附加 IPv6 列表"
        read -p "按回车键继续..."
        return
    fi

    echo "========== IPv6 出口测试 =========="
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
    done < "$list_file"

    echo "测试完成: 总计 $total | 成功 $success | 失败 $failed"
    read -p "按回车键继续..."
}

test_route(){
    local config_file="$1"
    source "$config_file"
    [ -z "$ROUTED_PREFIX" ] && echo "未配置 Routed Prefix" && return
    
    read -p "请输入测试用的 IPv6 地址(源IP): " TEST_IP
    [ -z "$TEST_IP" ] && return
    
    echo "========== route get (检查出口策略) =========="
    ip -6 route get 2606:4700:4700::1111 from "$TEST_IP"
    
    echo "========== ping 对端 (测试隧道连通性) =========="
    # 使用用户输入的 SERVER_IPV6 作为 Ping 目标 (去除 /64 等掩码)
    local target_ip="${SERVER_IPV6%%/*}"
    if [ -n "$target_ip" ]; then
        ping -6 -I "$TEST_IP" -c 3 -W 3 "$target_ip"
    else
        echo "无法获取 Server IPv6，跳过 Ping 测试。"
    fi
    
    read -p "按回车键继续..."
}

get_tunnel_file_by_index() {
    local target_idx=$1
    local i=1
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        if [ "$i" -eq "$target_idx" ]; then
            echo "$f"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

tunnel_submenu(){
    local config_file="$1"
    while true; do
        [ -f "$config_file" ] || return
        source "$config_file"
        local list_file="$CONFIG_DIR/$IFACE-ips.list"

        clear
        echo "========== 隧道管理: $IFACE (表: $TABLE) =========="
        echo "1. 随机添加附加 IPv6 地址 (在 $ROUTED_PREFIX 内)"
        echo "2. 删除指定附加 IPv6 地址"
        echo "3. 查看当前隧道与 IPv6 状态"
        echo "4. 测试该隧道 IPv6 出口连通性"
        echo "5. 测试该隧道路由与连通性"
        echo "6. 删除该隧道"
        echo "0. 返回上级菜单"
        echo "=================================================="
        read -p "选择 [0-6]: " SUB_CHOOSE
        case "$SUB_CHOOSE" in
            1) add_ipv6 "$config_file" "$list_file" ;;
            2) delete_ipv6 "$config_file" "$list_file" ;;
            3) status_tunnel "$config_file" "$list_file" ;;
            4) test_ipv6 "$list_file" ;;
            5) test_route "$config_file" ;;
            6) delete_tunnel "$config_file" "$list_file"; return ;;
            0) return ;;
            *) echo "输入错误！"; sleep 1 ;;
        esac
    done
}

menu(){
    while true; do
        clear
        echo "========== 隧道管理 =========="
        echo "1. 添加新隧道"
        echo "已添加的隧道列表："
        
        local i=1
        local has_tunnel=0
        for f in "$CONFIG_DIR"/*.conf; do
            [ -f "$f" ] || continue
            has_tunnel=1
            local IFACE TABLE REMOTE_V4 ROUTED_PREFIX
            source "$f"
            echo "   [$i] 接口: $IFACE | 远端IPv4: $REMOTE_V4 | 路由前缀: $ROUTED_PREFIX"
            i=$((i + 1))
        done
        [ "$has_tunnel" -eq 0 ] && echo "   (暂无隧道，请先添加)"

        echo "----------------------------------------"
        echo "请输入要操作的隧道编号 (或输入 1 添加新隧道, 0 退出):"
        read -p "选择: " CHOOSE

        case "$CHOOSE" in
            0) exit 0 ;;
            1) add_tunnel64; read -p "按回车键继续..." ;;
            *)
                if [[ "$CHOOSE" =~ ^[1-9][0-9]*$ ]]; then
                    local selected_file=$(get_tunnel_file_by_index "$CHOOSE")
                    if [ -n "$selected_file" ] && [ -f "$selected_file" ]; then
                        tunnel_submenu "$selected_file"
                    else
                        echo "错误: 无效的隧道编号！"
                        sleep 1
                    fi
                else
                    echo "输入错误！"
                    sleep 1
                fi
                ;;
        esac
    done
}

install_dep
menu

