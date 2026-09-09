#!/bin/bash

CONFIG_DIR="/etc/tunnel64"
T64_RESTORE_BIN="/usr/local/bin/tunnel64-restore"
T64_RESTORE_SERVICE="/etc/systemd/system/tunnel64-restore.service"

[ "$(id -u)" != "0" ] && echo "错误: 请使用 root 权限运行此脚本！" && exit 1

install_dep(){
    local missing=0
    for cmd in curl ip awk sed tr wg; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done

    if [ "$missing" -eq 1 ]; then
        echo "检测到缺少必要依赖，正在根据服务器环境自动安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y
            apt-get install -y curl iproute2 gawk wireguard-tools
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl iproute gawk wireguard-tools
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl iproute gawk wireguard-tools
        fi
    fi

    for cmd in curl ip awk sed tr wg; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "错误: 核心依赖 $cmd 安装失败或环境不支持，请手动安装 wireguard-tools 后重试。"
            exit 1
        fi
    done
    mkdir -p "$CONFIG_DIR"
}

generate_ipv6(){
    local prefix_str="$1"
    local network="${prefix_str%/*}"
    local cidr="${prefix_str#*/}"
    
    # 清理并规范化网络前缀
    network=$(echo "$network" | sed 's/:*$//')
    local hex=$(tr -d '-' < /proc/sys/kernel/random/uuid)
    
    if [ "$cidr" = "48" ]; then
        # /48 前缀：后面还剩 80 位 (5组 hex)
        printf '%s:%s:%s:%s:%s:%s\n' "$network" "${hex:0:4}" "${hex:4:4}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}"
    elif [ "$cidr" = "64" ]; then
        # /64 前缀：后面还剩 64 位 (4组 hex)
        printf '%s:%s:%s:%s:%s\n' "$network" "${hex:0:4}" "${hex:4:4}" "${hex:8:4}" "${hex:12:4}"
    else
        # 默认兜底 /64 逻辑
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
    TYPE="sit"
    source "$conf"
    [ -n "$IFACE" ] || continue

    if [ "$TYPE" = "wg" ]; then
        ip link del "$IFACE" 2>/dev/null || true
        ip link add dev "$IFACE" type wireguard 2>/dev/null || continue
        wg setconf "$IFACE" "$CONFIG_DIR/$IFACE.wg" 2>/dev/null || continue
        ip link set mtu "${MTU:-1420}" up dev "$IFACE"

        TABLE="${TABLE:-201}"
        RULE_PREF="${RULE_PREF:-32764}"
        RULE_PREF_V4="${RULE_PREF_V4:-32763}"

        # IPv6 配置恢复
        if [ -n "$WG_IPV6" ]; then
            ip -6 addr replace "$WG_IPV6" dev "$IFACE"
            ip -6 route replace "$WG_IPV6" dev "$IFACE" 2>/dev/null || true
            [ -n "$ROUTED_PREFIX" ] && ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true

            ip -6 route replace "$WG_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null || true
            [ -n "$ROUTED_PREFIX" ] && ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null || true
            ip -6 route replace default dev "$IFACE" table "$TABLE"

            while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
            tun_ip6="${WG_IPV6%%/*}"
            ip -6 rule add pref "$RULE_PREF" from "$tun_ip6" lookup "$TABLE" 2>/dev/null || true
            [ -n "$ROUTED_PREFIX" ] && ip -6 rule add pref "$RULE_PREF" from "$ROUTED_PREFIX" lookup "$TABLE"
        fi

        # IPv4 配置恢复
        if [ -n "$WG_IPV4" ]; then
            ip -4 addr replace "$WG_IPV4" dev "$IFACE"
            ip -4 route replace "$WG_IPV4" dev "$IFACE" 2>/dev/null || true

            ip -4 route replace "$WG_IPV4" dev "$IFACE" table "$TABLE" 2>/dev/null || true
            ip -4 route replace default dev "$IFACE" table "$TABLE"

            while ip -4 rule del pref "$RULE_PREF_V4" 2>/dev/null; do :; done
            tun_ip4="${WG_IPV4%%/*}"
            ip -4 rule add pref "$RULE_PREF_V4" from "$tun_ip4" lookup "$TABLE" 2>/dev/null || true
        fi

        # 恢复 lo 绑定的附加 IPv6
        LIST_FILE="${CONFIG_DIR}/${IFACE}-ips.list"
        if [ -f "$LIST_FILE" ]; then
            while IFS= read -r ip; do
                [ -n "$ip" ] || continue
                ip -6 addr replace "$ip/128" dev lo 2>/dev/null || true
            done < "$LIST_FILE"
        fi

    else
        [ -n "$LOCAL_V4" ] && [ -n "$REMOTE_V4" ] && [ -n "$TUNNEL_IPV6" ] || continue
        ip tunnel del "$IFACE" 2>/dev/null || true
        ip tunnel add "$IFACE" mode sit remote "$REMOTE_V4" local "$LOCAL_V4" ttl 255 2>/dev/null || continue
        ip link set "$IFACE" up mtu "${MTU:-1480}"

        TABLE="${TABLE:-201}"
        RULE_PREF="${RULE_PREF:-32764}"

        ip -6 addr replace "$TUNNEL_IPV6" dev "$IFACE"
        ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" 2>/dev/null || true
        [ -n "$ROUTED_PREFIX" ] && ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true

        ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null || true
        [ -n "$ROUTED_PREFIX" ] && ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null || true
        ip -6 route replace default dev "$IFACE" table "$TABLE"

        while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
        tun_ip="${TUNNEL_IPV6%%/*}"
        ip -6 rule add pref "$RULE_PREF" from "$tun_ip" lookup "$TABLE" 2>/dev/null || true
        [ -n "$ROUTED_PREFIX" ] && ip -6 rule add pref "$RULE_PREF" from "$ROUTED_PREFIX" lookup "$TABLE"

        LIST_FILE="${CONFIG_DIR}/${IFACE}-ips.list"
        if [ -f "$LIST_FILE" ]; then
            while IFS= read -r ip; do
                [ -n "$ip" ] || continue
                ip -6 addr replace "$ip/128" dev lo 2>/dev/null || true
            done < "$LIST_FILE"
        fi
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
        if [ "$TYPE" = "wg" ]; then
            ip link del "$IFACE" 2>/dev/null || true
        else
            ip tunnel del "$IFACE" 2>/dev/null || true
        fi
    fi

    if [ "$TYPE" = "wg" ]; then
        ip link add dev "$IFACE" type wireguard || return 1
        wg setconf "$IFACE" "$CONFIG_DIR/$IFACE.wg" || { ip link del "$IFACE"; return 1; }
        ip link set mtu "${MTU:-1420}" up dev "$IFACE"

        # 配置 IPv6 运行时与策略路由
        if [ -n "$WG_IPV6" ]; then
            ip -6 addr replace "$WG_IPV6" dev "$IFACE" || { ip link del "$IFACE"; return 1; }
            ip -6 route replace "$WG_IPV6" dev "$IFACE" 2>/dev/null || true
            [ -n "$ROUTED_PREFIX" ] && ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true

            ip -6 route replace "$WG_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null || true
            [ -n "$ROUTED_PREFIX" ] && ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null || true
            ip -6 route replace default dev "$IFACE" table "$TABLE"

            while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
            local tun_ip6="${WG_IPV6%%/*}"
            ip -6 rule add pref "$RULE_PREF" from "$tun_ip6" lookup "$TABLE" || return 1
            [ -n "$ROUTED_PREFIX" ] && ip -6 rule add pref "$RULE_PREF" from "$ROUTED_PREFIX" lookup "$TABLE"
        fi

        # 配置 IPv4 运行时与策略路由
        if [ -n "$WG_IPV4" ]; then
            ip -4 addr replace "$WG_IPV4" dev "$IFACE" || { ip link del "$IFACE"; return 1; }
            ip -4 route replace "$WG_IPV4" dev "$IFACE" 2>/dev/null || true

            ip -4 route replace "$WG_IPV4" dev "$IFACE" table "$TABLE" 2>/dev/null || true
            ip -4 route replace default dev "$IFACE" table "$TABLE"

            while ip -4 rule del pref "$RULE_PREF_V4" 2>/dev/null; do :; done
            local tun_ip4="${WG_IPV4%%/*}"
            ip -4 rule add pref "$RULE_PREF_V4" from "$tun_ip4" lookup "$TABLE" || return 1
        fi

    else
        ip tunnel add "$IFACE" mode sit remote "$REMOTE_V4" local "$LOCAL_V4" ttl 255 || return 1
        ip link set "$IFACE" up mtu "${MTU:-1480}"

        ip -6 addr replace "$TUNNEL_IPV6" dev "$IFACE" || { ip tunnel del "$IFACE"; return 1; }

        ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" 2>/dev/null || true
        [ -n "$ROUTED_PREFIX" ] && ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true

        ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null || true
        [ -n "$ROUTED_PREFIX" ] && ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null || true
        ip -6 route replace default dev "$IFACE" table "$TABLE"

        while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
        local tun_ip="${TUNNEL_IPV6%%/*}"
        ip -6 rule add pref "$RULE_PREF" from "$tun_ip" lookup "$TABLE" || return 1
        [ -n "$ROUTED_PREFIX" ] && ip -6 rule add pref "$RULE_PREF" from "$ROUTED_PREFIX" lookup "$TABLE"
    fi
    
    return 0
}

get_new_table_pref(){
    local max_table=200
    local min_pref=32765
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        local t_table=$(awk -F'"' '/^TABLE=/{print $2}' "$f")
        local t_pref=$(awk -F'"' '/^RULE_PREF=/{print $2}' "$f")
        [[ "$t_table" =~ ^[0-9]+$ ]] && [ "$t_table" -gt "$max_table" ] && max_table="$t_table"
        [[ "$t_pref" =~ ^[0-9]+$ ]] && [ "$t_pref" -lt "$min_pref" ] && min_pref="$t_pref"
    done
    NEW_TABLE=$((max_table + 1))
    NEW_PREF=$((min_pref - 1))
    NEW_PREF_V4=$((NEW_PREF - 1))
}

add_sit_tunnel(){
    echo "========== 添加 SIT 隧道 =========="
    read -p "请输入隧道名称 (直接回车随机生成): " IFACE
    if [ -z "$IFACE" ]; then
        IFACE="sit$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
        echo "已自动生成隧道名: $IFACE"
    fi
    if [ -f "$CONFIG_DIR/$IFACE.conf" ]; then
        echo "错误: 接口 $IFACE 配置文件已存在！" && return 1
    fi

    echo
    read -p "请输入服务端 IPv4 地址: " REMOTE_V4
    local default_local_v4=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+')
    [ -z "$default_local_v4" ] && default_local_v4=$(curl -4 -s ifconfig.me 2>/dev/null)
    read -p "请输入客户端 IPv4 地址 (本机) [$default_local_v4]: " LOCAL_V4
    [ -z "$LOCAL_V4" ] && LOCAL_V4="$default_local_v4"

    echo
    read -p "请输入服务端 IPv6 地址 (如 2001:470::1/64): " SERVER_IPV6
    read -p "请输入客户端 IPv6 地址 (如 2001:470::2/64): " TUNNEL_IPV6

    echo
    read -p "请输入 IPv6 路由前缀 (如 2001:470:abcd::/48 或 /64，直接回车跳过): " ROUTED_PREFIX

    if [ -z "$LOCAL_V4" ] || [ -z "$REMOTE_V4" ] || [ -z "$TUNNEL_IPV6" ]; then
        echo "错误: 核心 IP 参数均不能为空！" && return 1
    fi

    local TYPE="sit"
    local MTU="1480"
    get_new_table_pref
    local TABLE="$NEW_TABLE"
    local RULE_PREF="$NEW_PREF"

    echo
    echo "===== 确认配置 ====="
    echo "接口: $IFACE | 模式: SIT | 客户端IPv6: $TUNNEL_IPV6"
    read -p "确认应用并保存配置? [y/N]: " OK
    [[ "$OK" != "y" && "$OK" != "Y" ]] && echo "取消操作" && return

    if ! setup_tunnel_runtime; then
        echo "隧道配置失败" && return 1
    fi

    cat > "$CONFIG_DIR/$IFACE.conf" <<EOF
TYPE="sit"
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

add_wg_tunnel(){
    echo "========== 添加 WireGuard 隧道 =========="
    read -p "请输入隧道名称 (直接回车随机生成): " IFACE
    if [ -z "$IFACE" ]; then
        IFACE="wg$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
        echo "已自动生成隧道名: $IFACE"
    fi
    if [ -f "$CONFIG_DIR/$IFACE.conf" ]; then
        echo "错误: 接口 $IFACE 配置文件已存在！" && return 1
    fi

    echo
    echo "请粘贴 WireGuard 客户端配置内容 (粘贴完成后 连续按两次回车 确认):"
    local wg_raw=""
    local empty_count=0
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            empty_count=$((empty_count + 1))
            [ "$empty_count" -ge 2 ] && break
        else
            empty_count=0
        fi
        wg_raw="$wg_raw$line\n"
    done
    
    local tmp_conf=$(mktemp)
    echo -e "$wg_raw" > "$tmp_conf"

    local WG_PRIVKEY=$(awk -F'=' 'tolower($1)~/[ \t]*privatekey[ \t]*/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$tmp_conf" | tr -d '\r')
    local WG_ADDRESS=$(awk -F'=' 'tolower($1)~/[ \t]*address[ \t]*/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$tmp_conf" | tr '\n' ',' | sed 's/,$//' | tr -d '\r')
    local WG_PUBKEY=$(awk -F'=' 'tolower($1)~/[ \t]*publickey[ \t]*/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$tmp_conf" | tr -d '\r')
    local WG_ENDPOINT=$(awk -F'=' 'tolower($1)~/[ \t]*endpoint[ \t]*/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$tmp_conf" | tr -d '\r')
    local WG_MTU=$(awk -F'=' 'tolower($1)~/[ \t]*mtu[ \t]*/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$tmp_conf" | tr -d '\r')
    local WG_PSK=$(awk -F'=' 'tolower($1)~/[ \t]*presharedkey[ \t]*/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$tmp_conf" | tr -d '\r')
    local WG_ALLOWEDIPS=$(awk -F'=' 'tolower($1)~/[ \t]*allowedips[ \t]*/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$tmp_conf" | tr '\n' ',' | sed 's/,$//' | tr -d '\r')
    local WG_KEEPALIVE=$(awk -F'=' 'tolower($1)~/[ \t]*persistentkeepalive[ \t]*/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$tmp_conf" | tr -d '\r')
    rm -f "$tmp_conf"

    # 提取 IPv4 和 IPv6 地址支持双栈
    local WG_IPV4=$(echo "$WG_ADDRESS" | awk -F',' '{for(i=1;i<=NF;i++) if($i~/\./ && $i!~/:/) {gsub(/^[ \t]+|[ \t]+$/,"",$i); print $i; exit}}')
    local WG_IPV6=$(echo "$WG_ADDRESS" | awk -F',' '{for(i=1;i<=NF;i++) if($i~/:/) {gsub(/^[ \t]+|[ \t]+$/,"",$i); print $i; exit}}')
    
    if [ -z "$WG_PRIVKEY" ] || { [ -z "$WG_IPV4" ] && [ -z "$WG_IPV6" ]; } || [ -z "$WG_PUBKEY" ] || [ -z "$WG_ENDPOINT" ]; then
        echo "错误: 无法解析配置，请确保 PrivateKey, Address (包含IPv4或IPv6), PublicKey, Endpoint 配置完整。"
        return 1
    fi

    echo
    read -p "请输入该隧道附带的 IPv6 路由前缀 (如 /48 或 /64，无附带前缀请直接回车跳过): " ROUTED_PREFIX

    local TYPE="wg"
    local MTU="${WG_MTU:-1420}"
    get_new_table_pref
    local TABLE="$NEW_TABLE"
    local RULE_PREF="$NEW_PREF"
    local RULE_PREF_V4="$NEW_PREF_V4"

    # 修复 AllowedIPs 格式问题，去除多余空格以防 wg 工具报错
    [ -z "$WG_ALLOWEDIPS" ] && WG_ALLOWEDIPS="::/0,0.0.0.0/0"
    WG_ALLOWEDIPS=$(echo "$WG_ALLOWEDIPS" | tr -d ' ')

    # 生成安全的 WG 配置文件
    cat > "$CONFIG_DIR/$IFACE.wg" <<EOF
[Interface]
PrivateKey = $WG_PRIVKEY
[Peer]
PublicKey = $WG_PUBKEY
Endpoint = $WG_ENDPOINT
AllowedIPs = $WG_ALLOWEDIPS
EOF
    [ -n "$WG_PSK" ] && echo "PresharedKey = $WG_PSK" >> "$CONFIG_DIR/$IFACE.wg"
    [ -n "$WG_KEEPALIVE" ] && echo "PersistentKeepalive = $WG_KEEPALIVE" >> "$CONFIG_DIR/$IFACE.wg"

    echo "===== 确认配置 ====="
    echo "接口: $IFACE | 模式: WG | 节点: $WG_ENDPOINT"
    [ -n "$WG_IPV4" ] && echo "IPv4 地址: $WG_IPV4"
    [ -n "$WG_IPV6" ] && echo "IPv6 地址: $WG_IPV6"
    read -p "确认应用并建立隧道? [y/N]: " OK
    if [[ "$OK" != "y" && "$OK" != "Y" ]]; then
        rm -f "$CONFIG_DIR/$IFACE.wg"
        echo "取消操作" && return
    fi

    if ! setup_tunnel_runtime; then
        echo "WireGuard 隧道配置失败"
        rm -f "$CONFIG_DIR/$IFACE.wg"
        return 1
    fi

    cat > "$CONFIG_DIR/$IFACE.conf" <<EOF
TYPE="wg"
IFACE="$IFACE"
WG_IPV4="$WG_IPV4"
WG_IPV6="$WG_IPV6"
WG_ENDPOINT="$WG_ENDPOINT"
WG_ALLOWEDIPS="$WG_ALLOWEDIPS"
WG_PSK="$WG_PSK"
WG_KEEPALIVE="$WG_KEEPALIVE"
ROUTED_PREFIX="$ROUTED_PREFIX"
MTU="$MTU"
TABLE="$TABLE"
RULE_PREF="$RULE_PREF"
RULE_PREF_V4="$RULE_PREF_V4"
EOF

    update_systemd_restore
    echo "✓ WG隧道 $IFACE 添加成功并已生效！"
}

delete_tunnel(){
    local config_file="$1"
    local list_file="$2"
    source "$config_file"
    local TUN_TYPE="${TYPE:-sit}"

    echo "========== 删除隧道: $IFACE =========="
    read -p "确认删除该隧道及其所有附加 IPv6 吗? [y/N]: " OK
    [[ "$OK" != "y" && "$OK" != "Y" ]] && return

    if [ -f "$list_file" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            ip -6 addr del "$ip/128" dev lo 2>/dev/null || true
        done < "$list_file"
    fi

    while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
    [ -n "$RULE_PREF_V4" ] && while ip -4 rule del pref "$RULE_PREF_V4" 2>/dev/null; do :; done
    ip -6 route flush table "$TABLE" 2>/dev/null || true
    ip -4 route flush table "$TABLE" 2>/dev/null || true

    [ -n "$ROUTED_PREFIX" ] && ip -6 route del "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true
    [ -n "$WG_IPV6" ] && ip -6 route del "$WG_IPV6" dev "$IFACE" 2>/dev/null || true
    [ -n "$WG_IPV4" ] && ip -4 route del "$WG_IPV4" dev "$IFACE" 2>/dev/null || true
    [ -n "$TUNNEL_IPV6" ] && ip -6 route del "$TUNNEL_IPV6" dev "$IFACE" 2>/dev/null || true

    ip link set "$IFACE" down 2>/dev/null || true
    if [ "$TUN_TYPE" = "wg" ]; then
        ip link del "$IFACE" 2>/dev/null || true
    else
        ip tunnel del "$IFACE" 2>/dev/null || true
    fi

    rm -f "$config_file" "$list_file" "$CONFIG_DIR/$IFACE.wg"
    remove_systemd_restore_if_empty
    
    echo "✓ 隧道 $IFACE 已彻底删除"
    read -p "按回车键返回..."
}

add_ipv6(){
    local config_file="$1"
    local list_file="$2"
    source "$config_file"

    if [ -z "$ROUTED_PREFIX" ]; then
        echo "错误: 该隧道未配置路由前缀，无法生成附加 IPv6。"
        read -p "按回车键继续..." && return
    fi

    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        echo "错误: 接口不存在"
        read -p "按回车键继续..." && return
    fi

    local RETRY=0 MAX_RETRY=10 NEW_IPV6=""
    while [ "$RETRY" -lt "$MAX_RETRY" ]; do
        NEW_IPV6=$(generate_ipv6 "$ROUTED_PREFIX")
        if grep -qsxF "$NEW_IPV6" "$list_file" 2>/dev/null || \
           ip -6 addr show dev lo | grep -qsF "$NEW_IPV6" || \
           ip -6 addr show dev "$IFACE" | grep -qsF "$NEW_IPV6"; then
            RETRY=$((RETRY + 1))
        else
            break
        fi
    done

    if [ "$RETRY" -ge "$MAX_RETRY" ]; then
        echo "错误: 未能生成唯一 IPv6" && read -p "按回车键继续..." && return
    fi

    if ! ip -6 addr add "$NEW_IPV6/128" dev lo 2>/dev/null; then
        echo "错误: IPv6 绑定到 lo 失败" && read -p "按回车键继续..." && return
    fi

    mkdir -p "$(dirname "$list_file")"
    echo "$NEW_IPV6" >> "$list_file"
    echo "✓ 附加 IPv6 添加成功: $NEW_IPV6"

    if ip -6 route get 2606:4700:4700::1111 from "$NEW_IPV6" 2>/dev/null | grep -qs "$IFACE"; then
        echo "✓ 路由校验通过: 成功匹配策略路由表 $TABLE"
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
        echo "没有可删除的附加 IPv6" && read -p "按回车键继续..." && return
    fi

    echo "========== 附加 IPv6 列表 ($IFACE) =========="
    awk '{print NR". "$0}' "$list_file"
    echo "============================================="
    read -p "输入要删除的编号: " NUM
    if ! [[ "$NUM" =~ ^[1-9][0-9]*$ ]]; then
        echo "错误: 输入无效" && read -p "按回车键继续..." && return
    fi

    local DEL_IP=$(sed -n "${NUM}p" "$list_file")
    if [ -z "$DEL_IP" ]; then
        echo "错误: 编号不存在" && read -p "按回车键继续..." && return
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
    local TUN_TYPE="${TYPE:-sit}"

    clear
    echo "========== 隧道状态: $IFACE =========="
    echo "类型          : ${TUN_TYPE^^}"
    ip link show "$IFACE" >/dev/null 2>&1 || echo "⚠️ 隧道设备未启动"
    if [ "$TUN_TYPE" = "wg" ]; then
        [ -n "$WG_IPV4" ] && echo "Client IPv4   : $WG_IPV4"
        [ -n "$WG_IPV6" ] && echo "Client IPv6   : $WG_IPV6"
        echo "Endpoint      : ${WG_ENDPOINT:-未配置}"
    else
        echo "Client IPv6   : $(ip -6 addr show dev "$IFACE" 2>/dev/null | grep 'scope global' | awk '{print $2}' || echo '无')"
        echo "Server IPv6   : ${SERVER_IPV6:-未配置}"
    fi
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
        echo "未找到附加 IPv6 列表" && read -p "按回车键继续..." && return
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
    
    read -p "请输入测试用的源 IP 地址 (IPv4 或 IPv6): " TEST_IP
    [ -z "$TEST_IP" ] && return
    
    if [[ "$TEST_IP" =~ : ]]; then
        echo "========== route get (检查 IPv6 策略) =========="
        ip -6 route get 2606:4700:4700::1111 from "$TEST_IP"
        ping -6 -I "$TEST_IP" -c 3 -W 3 2606:4700:4700::1111
    else
        echo "========== route get (检查 IPv4 策略) =========="
        ip -4 route get 1.1.1.1 from "$TEST_IP"
        ping -4 -I "$TEST_IP" -c 3 -W 3 1.1.1.1
    fi
    
    read -p "按回车键继续..."
}

get_tunnel_file_by_index() {
    local target_idx=$1
    local i=1
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        if [ "$i" -eq "$target_idx" ]; then
            echo "$f" && return 0
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
        local TUN_TYPE="${TYPE:-sit}"

        clear
        echo "========== 隧道管理: $IFACE [${TUN_TYPE^^}] (表: $TABLE) =========="
        echo "1. 随机添加附加 IPv6 地址 (需配置了 Prefix)"
        echo "2. 删除指定附加 IPv6 地址"
        echo "3. 查看当前隧道与 IP 状态"
        echo "4. 批量测试所有附加 IPv6 的出口"
        echo "5. 测试单 IP 路由与外网连通性"
        echo "6. 删除该隧道"
        echo "0. 返回上级菜单"
        echo "==========================================================="
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
        echo "========== 通用隧道管理 =========="
        echo "0. 退出脚本"
        echo "a. 添加SIT隧道"
        echo "b. WireGuard隧道"
        echo "----------------------------------------"
        echo "已添加的隧道列表："
        
        local i=1
        local has_tunnel=0
        for f in "$CONFIG_DIR"/*.conf; do
            [ -f "$f" ] || continue
            has_tunnel=1
            local IFACE TABLE TYPE REMOTE_V4 ROUTED_PREFIX WG_ENDPOINT
            TYPE="sit"
            source "$f"
            if [ "$TYPE" = "wg" ]; then
                echo "   [$i] [WG]  接口: $IFACE | 节点: $WG_ENDPOINT | 路由前缀: ${ROUTED_PREFIX:-无}"
            else
                echo "   [$i] [SIT] 接口: $IFACE | 远端IPv4: $REMOTE_V4 | 路由前缀: ${ROUTED_PREFIX:-无}"
            fi
            i=$((i + 1))
        done
        [ "$has_tunnel" -eq 0 ] && echo "   (暂无隧道，请选择 a 或 b 添加)"

        echo "----------------------------------------"
        read -p "请输入选项 (a/b 添加, 0 退出, 或输入编号进入管理): " CHOOSE

        case "$CHOOSE" in
            0) exit 0 ;;
            a|A) add_sit_tunnel; read -p "按回车键继续..." ;;
            b|B) add_wg_tunnel; read -p "按回车键继续..." ;;
            *)
                if [[ "$CHOOSE" =~ ^[1-9][0-9]*$ ]]; then
                    local selected_file=$(get_tunnel_file_by_index "$CHOOSE")
                    if [ -n "$selected_file" ] && [ -f "$selected_file" ]; then
                        tunnel_submenu "$selected_file"
                    else
                        echo "错误: 无效的隧道编号！"; sleep 1
                    fi
                else
                    echo "输入错误！"; sleep 1
                fi
                ;;
        esac
    done
}

install_dep
menu
