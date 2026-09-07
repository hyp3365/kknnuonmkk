#!/bin/bash
# ==========================================
# Route64 IPv6 隧道管理脚本
# ==========================================
IFACE="route64"
WG_DIR="/etc/wireguard"
WG_FILE="$WG_DIR/route64.conf"
CONFIG_FILE="/etc/route64.conf"
LIST_FILE="/etc/route64-ips.list"
OUTBOUND_FILE="/etc/sing-box/conf/outbounds.json"
ROUTE_FILE="/etc/sing-box/conf/route.json"
SERVICE_FILE="/etc/systemd/system/route64-ipv6.service"
[ "$(id -u)" != "0" ] && {
    echo "请使用 root 运行"
    exit 1
}
install_dep(){
    local NEED=""
    command -v wg >/dev/null || NEED="$NEED wireguard-tools"
    command -v ip >/dev/null || NEED="$NEED iproute2"
    command -v curl >/dev/null || NEED="$NEED curl"
    command -v jq >/dev/null || NEED="$NEED jq"
    if [ -n "$NEED" ]; then
        echo "安装依赖:$NEED"
        if command -v apt >/dev/null; then
            apt update
            apt install -y $NEED
        elif command -v apk >/dev/null; then
            apk add $NEED
        elif command -v yum >/dev/null; then
            yum install -y $NEED
        else
            echo "无法自动安装依赖"
            exit 1
        fi
    fi
}
save_config(){
cat > "$CONFIG_FILE" <<EOF
IFACE="$IFACE"
PREFIX56="$PREFIX56"
TUN_IPV6="$TUN_IPV6"
EOF
}
load_config(){
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}
generate_random_ipv6() {
    local prefix="$1"
    prefix="${prefix%/56}"
    prefix="${prefix%::}"
    prefix="${prefix%:}"
    IFS=':' read -r -a parts <<< "$prefix"
    local p1="${parts[0]}"
    local p2="${parts[1]}"
    local p3="${parts[2]}"
    local p4="${parts[3]}"
    p1=$(printf '%04x' "$((16#$p1))")
    p2=$(printf '%04x' "$((16#$p2))")
    p3=$(printf '%04x' "$((16#$p3))")
    p4=$(printf '%04x' "$((16#$p4))")
    local subnet
    local h1 h2 h3 h4
    subnet=$(printf '%02x' $((RANDOM % 256)))
    h1=$(printf '%04x' $((RANDOM % 65536)))
    h2=$(printf '%04x' $((RANDOM % 65536)))
    h3=$(printf '%04x' $((RANDOM % 65536)))
    h4=$(printf '%04x' $((RANDOM % 65536)))
    echo "${p1}:${p2}:${p3}:${p4:0:2}${subnet}:${h1}:${h2}:${h3}:${h4}"
}
add_ipv6() {
    clear
    echo "========================================"
    echo "          添加 Route64 IPv6"
    echo "========================================"
    echo
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Route64 尚未配置。"
        read -r -p "按回车返回..."
        return 1
    fi
    source "$CONFIG_FILE"
    if [ -z "$PREFIX56" ]; then
        echo "未找到 Route64 /56。"
        read -r -p "按回车返回..."
        return 1
    fi
    if [ ! -f "$LIST_FILE" ]; then
        touch "$LIST_FILE"
        chmod 600 "$LIST_FILE"
    fi
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
        echo "生成随机 IPv6 失败。"
        read -r -p "按回车返回..."
        return 1
    fi
    echo "随机 IPv6："
    echo "$NEW_IPV6"
    if ! ip -6 addr add "$NEW_IPV6/128" dev lo 2>/dev/null; then
        echo "IPv6 添加失败。"
        read -r -p "按回车返回..."
        return 1
    fi
    echo "$NEW_IPV6" >> "$LIST_FILE"
    add_singbox_outbound "$NEW_IPV6"
    echo "========================================"
    echo "IPv6 添加成功"
    echo "========================================"
    echo "IPv6：$NEW_IPV6"
    echo "已绑定：route64"
    echo "无需重启 sing-box"
    read -r -p "按回车返回..."
}
add_route64() {
    clear
    echo "========================================"
    echo "        添加 / 重置 Route64 隧道"
    echo "========================================"
    echo "请粘贴 ROUTE64 WireGuard 配置。"
    echo "粘贴完成后，单独输入 END 并回车。"
    local tmp_conf="/tmp/route64.conf.$$"
    rm -f "$tmp_conf"
    while IFS= read -r line; do
        [ "$line" = "END" ] && break
        printf '%s\n' "$line" >> "$tmp_conf"
    done
    if [ ! -s "$tmp_conf" ]; then
        echo "未读取到 WireGuard 配置。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    if ! grep -q '^\[Interface\]' "$tmp_conf"; then
        echo "配置中没有 [Interface]。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    if ! grep -q '^\[Peer\]' "$tmp_conf"; then
        echo "配置中没有 [Peer]。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    if ! grep -q '^PrivateKey[[:space:]]*=' "$tmp_conf"; then
        echo "缺少 PrivateKey。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    if ! grep -q '^PublicKey[[:space:]]*=' "$tmp_conf"; then
        echo "缺少 Peer PublicKey。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    echo "请输入 ROUTE64 分配给你的 IPv6 /56 区段。"
    echo "例如：2a11:6c7:2001:c400::/56"
    local prefix56
    read -r -p "IPv6 /56： " prefix56
    prefix56="${prefix56//[[:space:]]/}"
    if [ -z "$prefix56" ]; then
        echo "未输入 /56 区段。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    if [[ "$prefix56" != */56 ]]; then
        echo "错误：必须输入 /56 区段。"
        echo "例如：2a11:6c7:2001:c400::/56"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    prefix56="${prefix56%/56}"
    prefix56="${prefix56%::}"
    prefix56="${prefix56%:}"
    local p1 p2 p3 p4
    IFS=':' read -r p1 p2 p3 p4 _ <<< "$prefix56"
    if [ -z "$p1" ] || [ -z "$p2" ] || [ -z "$p3" ] || [ -z "$p4" ]; then
        echo "错误：/56 格式不正确。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    p1=$(printf '%x' "$((16#$p1))" 2>/dev/null) || true
    p2=$(printf '%x' "$((16#$p2))" 2>/dev/null) || true
    p3=$(printf '%x' "$((16#$p3))" 2>/dev/null) || true
    p4=$(printf '%04x' "$((16#$p4))" 2>/dev/null) || true
    if [ -z "$p1" ] || [ -z "$p2" ] || [ -z "$p3" ] || [ -z "$p4" ]; then
        echo "错误：无法解析 /56。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 1
    fi
    local prefix56_canonical="${p1}:${p2}:${p3}:${p4}::/56"
    echo "----------------------------------------"
    echo "WireGuard 配置："
    cat "$tmp_conf"
    echo "Route64 /56："
    echo "$prefix56_canonical"
    echo "----------------------------------------"
    read -r -p "回车确认继续，输入其他内容取消： " confirm
    if [ -n "$confirm" ]; then
        echo "已取消。"
        rm -f "$tmp_conf"
        read -r -p "按回车返回..."
        return 0
    fi
    echo "正在配置 Route64..."
    systemctl stop wg-quick@route64.service 2>/dev/null || true
    mkdir -p /etc/wireguard
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
    ' "$tmp_conf" > /etc/wireguard/route64.conf
    chmod 600 /etc/wireguard/route64.conf
    rm -f "$tmp_conf"
    cat > /etc/route64.conf <<EOF
PREFIX56=$prefix56_canonical
TABLE=200
INTERFACE=route64
EOF
    chmod 600 /etc/route64.conf
    if ! grep -qE '^[[:space:]]*200[[:space:]]+route64[[:space:]]*$' /etc/iproute2/rt_tables; then
        echo "200 route64" >> /etc/iproute2/rt_tables
    fi
    ip -6 rule del from "$prefix56_canonical" table 200 2>/dev/null || true
    ip -6 rule del from "$prefix56_canonical" lookup 200 2>/dev/null || true
    ip -6 route flush table 200 2>/dev/null || true
    if ! wg-quick up route64; then
        echo "Route64 WireGuard 启动失败。"
        read -r -p "按回车返回..."
        return 1
    fi
    systemctl enable wg-quick@route64.service >/dev/null 2>&1
    ip -6 route replace default dev route64 table 200
    ip -6 rule add pref 100 from "$prefix56_canonical" table 200 2>/dev/null || true
    touch /etc/route64-ips.list
    chmod 600 /etc/route64-ips.list
    cat > /etc/systemd/system/route64-ipv6.service <<EOF
[Unit]
Description=Route64 IPv6 Policy Routing
After=wg-quick@route64.service
Requires=wg-quick@route64.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip -6 rule del from "$prefix56_canonical" table 200 2>/dev/null || true; ip -6 rule add pref 100 from "$prefix56_canonical" table 200; ip -6 route replace default dev route64 table 200'
ExecStop=/bin/sh -c 'ip -6 rule del from "$prefix56_canonical" table 200 2>/dev/null || true; ip -6 route flush table 200 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable route64-ipv6.service >/dev/null 2>&1
    systemctl restart route64-ipv6.service
    echo "========================================"
    echo "        Route64 配置完成"
    echo "========================================"
    echo "WireGuard 配置："
    echo "/etc/wireguard/route64.conf"
    echo "IPv6 /56："
    echo "$prefix56_canonical"
    echo "路由表："
    echo "200 route64"
    echo "策略："
    echo "from $prefix56_canonical -> table 200"
    echo "主路由表不会被 Route64 修改。"
    echo "eth0 / HE IPv6 可以继续共存。"
    wg show route64
    read -r -p "按回车返回..."
}
create_service(){
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Route64 IPv6 address restore
After=wg-quick@route64.service
Requires=wg-quick@route64.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '
source $CONFIG_FILE
ip -6 route replace \${PREFIX56} dev route64
if [ -f $LIST_FILE ]; then
while read ip
do
[ -n "\$ip" ] && ip -6 addr add \$ip/128 dev lo 2>/dev/null || true
done < $LIST_FILE
fi
'
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable route64-ipv6.service
}
delete_route64(){
echo "删除 Route64"
systemctl disable wg-quick@route64 2>/dev/null
wg-quick down route64 2>/dev/null
rm -f "$WG_FILE"
systemctl disable route64-ipv6.service 2>/dev/null
rm -f "$SERVICE_FILE"
rm -f "$CONFIG_FILE"
ip link delete "$IFACE" 2>/dev/null
echo "Route64 已删除"
}
add_singbox_outbound(){
[ ! -f "$OUTBOUND_FILE" ] && return
local IP="$1"
local NUM
NUM=$(jq -r '
.outbounds[]?
| select(.tag|startswith("route64-ipv6-"))
| .tag
| sub("route64-ipv6-";"")
' "$OUTBOUND_FILE" 2>/dev/null | sort -n | tail -1)
if [ -z "$NUM" ]; then
    NUM=1
else
    NUM=$((NUM+1))
fi
TAG="route64-ipv6-$NUM"
TMP=$(mktemp)
jq \
--arg tag "$TAG" \
--arg ip "$IP" \
'
.outbounds += [{
"type":"direct",
"tag":$tag,
"bind_interface":"route64",
"inet6_bind_address":$ip
}]
' "$OUTBOUND_FILE" > "$TMP" &&
mv "$TMP" "$OUTBOUND_FILE"
echo "sing-box 出站添加:"
echo "tag: $TAG"
echo "ip : $IP"
}
delete_singbox_outbound(){
[ ! -f "$OUTBOUND_FILE" ] && return
local IP="$1"
TAG=$(jq -r \
--arg ip "$IP" '
.outbounds[]?
|select(.inet6_bind_address==$ip)
|.tag
' "$OUTBOUND_FILE")
[ -z "$TAG" ] && return
TMP=$(mktemp)
jq \
--arg ip "$IP" \
'
.outbounds |= map(
select(.inet6_bind_address != $ip)
)
' "$OUTBOUND_FILE" > "$TMP" &&
mv "$TMP" "$OUTBOUND_FILE"
if [ -f "$ROUTE_FILE" ]; then
TMP=$(mktemp)
jq \
--arg tag "$TAG" \
'
.route.rules |= map(
select(.outbound != $tag)
)
' "$ROUTE_FILE" > "$TMP" &&
mv "$TMP" "$ROUTE_FILE"
fi
echo "删除 sing-box:"
echo "$TAG"
}
list_ipv6(){
if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
echo "暂无 IPv6"
return
fi
nl -w2 -s ". " "$LIST_FILE"
}
delete_ipv6(){
if [ ! -f "$LIST_FILE" ]; then
echo "暂无 IPv6"
return
fi
echo "========== IPv6列表 =========="
list_ipv6
read -p "输入编号: " NUM
IP=$(sed -n "${NUM}p" "$LIST_FILE")
if [ -z "$IP" ]; then
echo "编号错误"
return
fi
echo "删除:"
echo "$IP"
ip -6 addr del \
"$IP/128" \
dev lo 2>/dev/null || true
sed -i "${NUM}d" "$LIST_FILE"
delete_singbox_outbound "$IP"
echo "删除完成"
}
status(){
clear
echo "========== Route64 状态 =========="
ip link show "$IFACE" 2>/dev/null || echo "route64 未启动"
echo "========== Route64 IPv6 =========="
ip -6 addr show dev "$IFACE" 2>/dev/null | grep global
echo "========== /56 路由 =========="
ip -6 route | grep "$PREFIX56" || echo "无"
echo "========== 已分配 IPv6 =========="
list_ipv6
read -p "回车返回..."
}
test_ipv6(){
if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
echo "没有 IPv6 地址"
read -p "回车返回..."
return
fi
echo "========== IPv6 测试 =========="
local TOTAL=0
local OK=0
local FAIL=0
while read IP
do
[ -z "$IP" ] && continue
TOTAL=$((TOTAL+1))
echo "[$TOTAL] $IP"
START=$(date +%s%3N)
RESULT=$(curl -6 \
--interface "$IP" \
--connect-timeout 8 \
--max-time 15 \
-s https://ip.sb 2>/dev/null)
END=$(date +%s%3N)
TIME=$((END-START))
if [ -n "$RESULT" ]; then
echo "✓ 成功"
echo "出口:"
echo "$RESULT"
echo "耗时:"
echo "${TIME} ms"
OK=$((OK+1))
else
echo "✗ 失败"
FAIL=$((FAIL+1))
fi
done < "$LIST_FILE"
echo "=============================="
echo "总数:$TOTAL"
echo "成功:$OK"
echo "失败:$FAIL"
read -p "回车返回..."
}
menu(){
while true
do
clear
echo "========== Route64 IPv6 =========="
echo "1. 添加 Route64 隧道"
echo "2. 删除 Route64"
echo "3. 随机添加 IPv6"
echo "4. 删除 IPv6"
echo "5. 查看状态"
echo "6. 测试 IPv6"
echo "0. 退出"
read -p "选择 [0-6]: " CHOOSE
case "$CHOOSE" in
1)
add_route64
read -p "回车继续..."
;;
2)
delete_route64
read -p "回车继续..."
;;
3)
add_ipv6
;;
4)
delete_ipv6
read -p "回车继续..."
;;
5)
status
;;
6)
test_ipv6
;;
0)
exit 0
;;
*)
echo "错误"
sleep 1
;;
esac
done
}
install_dep
load_config
menu
