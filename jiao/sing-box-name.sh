#!/bin/bash
export LANG=en_US.UTF-8
# --- 颜色和基础工具函数 ---
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

BASE_DIR="/etc/sing-box"
CONF_DIR="$BASE_DIR/conf"
DATA_DIR="$BASE_DIR/user_manager"
BACKUP_DIR="$DATA_DIR/backups"
LIMIT_DIR="$DATA_DIR/limits"
SINGBOX="$BASE_DIR/sing-box"
SERVICE="sing-box"
PYTHON="$(command -v python3 2>/dev/null || true)"

mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$LIMIT_DIR"

if [ ! -x "$SINGBOX" ]; then
    red "错误：未找到 $SINGBOX"
    exit 1
fi

if [ ! -d "$CONF_DIR" ]; then
    red "错误：未找到 $CONF_DIR"
    exit 1
fi

if [ -z "$PYTHON" ]; then
    red "错误：系统没有 python3"
    exit 1
fi

pause() {
    echo
    read -rp "$(yellow "按回车继续...")" _
}

title() {
    clear
    echo
    echo -e "${green}╔════════════════════════════════════════════╗${re}"
    printf "${green}║${re} %-42s ${green}║${re}\n" "$1"
    echo -e "${green}╚════════════════════════════════════════════╝${re}"
    echo
}

backup_file() {
    local file="$1"
    local name
    name="$(basename "$file")"
    cp -a "$file" "$BACKUP_DIR/${name}.$(date +%Y%m%d_%H%M%S).bak"
}

cleanup_backups() {
    find "$BACKUP_DIR" -type f -name '*.bak' -mtime +30 -delete 2>/dev/null
}

reload_singbox() {
    systemctl reload "$SERVICE" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        return 0
    fi
    systemctl restart "$SERVICE" >/dev/null 2>&1
    return $?
}

check_config() {
    "$SINGBOX" check -C "$CONF_DIR" >/dev/null 2>&1
    return $?
}

restore_file() {
    local file="$1"
    local backup="$2"
    cp -a "$backup" "$file"
}

find_backup() {
    local file="$1"
    local name
    name="$(basename "$file")"
    ls -1t "$BACKUP_DIR/${name}."*.bak 2>/dev/null | head -n1
}

list_nodes() {
    "$PYTHON" - "$CONF_DIR" <<'PY'
import sys
import json
import glob
import os

conf_dir = sys.argv[1]

for fn in sorted(glob.glob(os.path.join(conf_dir, "*.json"))):
    try:
        with open(fn, "r", encoding="utf-8") as f:
            data = json.load(f)
    except:
        continue

    for inbound in data.get("inbounds", []):
        if not isinstance(inbound, dict):
            continue

        tag = inbound.get("tag", "")
        typ = inbound.get("type", "")
        users = inbound.get("users", [])

        if tag and isinstance(users, list):
            print("{}\t{}\t{}\t{}\t{}".format(
                os.path.basename(fn),
                tag,
                typ,
                len(users),
                inbound.get("listen_port", "")
            ))
PY
}

get_node_info() {
    local file="$1"
    local tag="$2"

    "$PYTHON" - "$CONF_DIR/$file" "$tag" <<'PY'
import sys
import json

fn = sys.argv[1]
tag = sys.argv[2]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        print(json.dumps(inbound, ensure_ascii=False))
        break
PY
}

node_menu() {
    local file="$1"
    local tag="$2"
    local type="$3"
    local port="$4"

    while true; do
        title "$tag"

        echo -e "${skyblue}协议:${re} $type"
        echo -e "${skyblue}端口:${re} ${port:-未知}"
        echo

        mapfile -t USERS < <(
            "$PYTHON" - "$CONF_DIR/$file" "$tag" <<'PY'
import sys
import json

fn = sys.argv[1]
tag = sys.argv[2]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        for u in inbound.get("users", []):
            print(u.get("name", ""))
        break
PY
        )

        local i=1

        for user in "${USERS[@]}"; do
            [ -z "$user" ] && continue
            printf "  ${green}%2d)${re} %-32s\n" "$i" "$user"
            ((i++))
        done

        printf "  ${green}%2d)${re} %s\n" "$i" "+ 新增用户"
        local add_num="$i"

        echo
        echo -e "  ${yellow}0)${re} 返回"
        echo

        read -rp "$(green "请选择: ")" choice

        if [ "$choice" = "0" ]; then
            return
        fi

        if [ "$choice" = "$add_num" ]; then
            add_user "$file" "$tag" "$type"
            continue
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$add_num" ]; then
            local index=$((choice-1))
            user_menu "$file" "$tag" "$type" "$port" "${USERS[$index]}"
        else
            red "无效选择"
            sleep 1
        fi
    done
}

get_next_user_name() {
    local file="$1"
    local tag="$2"

    "$PYTHON" - "$CONF_DIR/$file" "$tag" <<'PY'
import sys
import json
import re

fn = sys.argv[1]
tag = sys.argv[2]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

users = []

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        users = inbound.get("users", [])
        break

used = set()

for u in users:
    name = u.get("name", "")
    m = re.fullmatch(re.escape(tag) + r"-user(\d+)", name)
    if m:
        used.add(int(m.group(1)))

n = 1
while n in used:
    n += 1

print(f"{tag}-user{n}")
PY
}

generate_uuid() {
    "$PYTHON" - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
}

add_user() {
    local file="$1"
    local tag="$2"
    local type="$3"
    local full="$CONF_DIR/$file"

    title "新增用户"

    local name
    name="$(get_next_user_name "$file" "$tag")"

    echo -e "${skyblue}节点:${re} $tag"
    echo -e "${skyblue}协议:${re} $type"
    echo -e "${skyblue}用户名:${re} $name"
    echo

    local auth_type=""
    local value=""
    local username=""
    local password=""
    local uuid=""

    case "$type" in
        hysteria2|hysteria)
            auth_type="password"
            value="$(generate_uuid)"
            echo -e "${green}自动生成 UUID:${re}"
            echo "$value"
            ;;

        vmess|vless|tuic)
            auth_type="uuid"
            uuid="$(generate_uuid)"
            echo -e "${green}自动生成 UUID:${re}"
            echo "$uuid"

            if [ "$type" = "tuic" ]; then
                password="$(generate_uuid)"
            fi
            ;;

        trojan|anytls|shadowtls|shadowsocks)
            auth_type="password"
            read -rp "$(green "请输入密码，留空自动生成 UUID: ")" value
            [ -z "$value" ] && value="$(generate_uuid)"
            ;;

        socks|http|mixed|naive)
            auth_type="username_password"
            read -rp "$(green "用户名: ")" username
            while [ -z "$username" ]; do
                red "用户名不能为空"
                read -rp "$(green "用户名: ")" username
            done

            read -rp "$(green "密码，留空自动生成 UUID: ")" password
            [ -z "$password" ] && password="$(generate_uuid)"
            ;;

        *)
            auth_type="password"
            read -rp "$(green "请输入认证密码，留空自动生成 UUID: ")" value
            [ -z "$value" ] && value="$(generate_uuid)"
            ;;
    esac

    echo
    echo -e "${yellow}确认添加用户:${re}"
    echo "节点 : $tag"
    echo "用户 : $name"

    case "$type" in
        vmess|vless)
            echo "UUID  : $uuid"
            ;;
        tuic)
            echo "UUID  : $uuid"
            echo "密码  : $password"
            ;;
        socks|http|mixed|naive)
            echo "用户名: $username"
            echo "密码  : $password"
            ;;
        *)
            echo "认证  : ${value:-$password}"
            ;;
    esac

    echo
    read -rp "$(yellow "确认添加？[Y/n]: ")" confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return

    backup_file "$full"
    local backup
    backup="$(find_backup "$full")"

    "$PYTHON" - "$full" "$tag" "$type" "$name" "$value" "$uuid" "$password" "$username" <<'PY'
import sys
import json

fn, tag, typ, name, value, uuid_value, password, username = sys.argv[1:]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

target = None

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        target = inbound
        break

if target is None:
    raise SystemExit("找不到节点")

users = target.setdefault("users", [])

new_user = {"name": name}

if typ in ("vmess", "vless"):
    new_user["uuid"] = uuid_value
elif typ == "tuic":
    new_user["uuid"] = uuid_value
    new_user["password"] = password
elif typ in ("socks", "http", "mixed", "naive"):
    new_user["username"] = username
    new_user["password"] = password
else:
    new_user["password"] = value or password

users.append(new_user)

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

    if ! check_config; then
        red "配置检查失败，正在恢复..."
        restore_file "$full" "$backup"
        pause
        return
    fi

    if ! reload_singbox; then
        red "sing-box 重载失败，正在恢复..."
        restore_file "$full" "$backup"
        reload_singbox
        pause
        return
    fi

    green "用户添加成功"
    echo -e "${skyblue}用户名:${re} $name"
    echo
    pause
}

get_user_json() {
    local file="$1"
    local tag="$2"
    local user="$3"

    "$PYTHON" - "$CONF_DIR/$file" "$tag" "$user" <<'PY'
import sys
import json

fn, tag, name = sys.argv[1:]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        for u in inbound.get("users", []):
            if u.get("name") == name:
                print(json.dumps(u, ensure_ascii=False))
                raise SystemExit
PY
}

get_limit_file() {
    local tag="$1"
    local user="$2"
    echo "$LIMIT_DIR/${tag}__${user}.json"
}

show_limit() {
    local tag="$1"
    local user="$2"
    local lf
    lf="$(get_limit_file "$tag" "$user")"

    if [ ! -f "$lf" ]; then
        echo -e "${skyblue}流量限制:${re} 未设置"
        return
    fi

    "$PYTHON" - "$lf" <<'PY'
import sys
import json

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)

    if d.get("enabled"):
        print("已设置：{} GB".format(d.get("limit_gb", 0)))
    else:
        print("已关闭")
except:
    print("未设置")
PY
}

set_limit() {
    local tag="$1"
    local user="$2"
    local lf
    lf="$(get_limit_file "$tag" "$user")"

    title "流量限制"

    show_limit "$tag" "$user"
    echo

    read -rp "$(green "请输入流量限制 GB，输入 0 表示取消: ")" gb

    if ! [[ "$gb" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        red "请输入正确的数字"
        pause
        return
    fi

    "$PYTHON" - "$lf" "$tag" "$user" "$gb" <<'PY'
import sys
import json
import os

fn, tag, user, gb = sys.argv[1:]

gb = float(gb)

data = {
    "inbound_tag": tag,
    "user": user,
    "limit_gb": gb,
    "enabled": gb > 0
}

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

    if [ "$gb" = "0" ]; then
        green "流量限制已取消"
    else
        green "流量限制已设置为 ${gb} GB"
        yellow "注意：当前版本只保存限制值，自动统计/达到额度后停用将在下一阶段接入。"
    fi

    pause
}

modify_auth() {
    local file="$1"
    local tag="$2"
    local type="$3"
    local user="$4"
    local full="$CONF_DIR/$file"

    title "修改认证"

    case "$type" in
        vmess|vless|tuic)
            local new_uuid
            read -rp "$(green "请输入新的 UUID，留空自动生成: ")" new_uuid
            [ -z "$new_uuid" ] && new_uuid="$(generate_uuid)"

            if ! "$PYTHON" - "$full" "$tag" "$user" "$new_uuid" <<'PY'
import sys
import json
import uuid

fn, tag, name, value = sys.argv[1:]

try:
    uuid.UUID(value)
except:
    raise SystemExit("UUID格式错误")

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

found = False

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        for u in inbound.get("users", []):
            if u.get("name") == name:
                u["uuid"] = value
                found = True

if not found:
    raise SystemExit("用户不存在")

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
            then
                red "UUID格式错误"
                pause
                return
            fi
            ;;

        *)
            local new_password
            read -rp "$(green "请输入新的密码，留空自动生成 UUID: ")" new_password
            [ -z "$new_password" ] && new_password="$(generate_uuid)"

            "$PYTHON" - "$full" "$tag" "$user" "$new_password" <<'PY'
import sys
import json

fn, tag, name, value = sys.argv[1:]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

found = False

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        for u in inbound.get("users", []):
            if u.get("name") == name:
                u["password"] = value
                found = True

if not found:
    raise SystemExit("用户不存在")

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
            ;;
    esac

    backup_file "$full"

    local backup
    backup="$(find_backup "$full")"

    if ! check_config; then
        red "配置检查失败，正在恢复..."
        restore_file "$full" "$backup"
        pause
        return
    fi

    if ! reload_singbox; then
        red "sing-box 重载失败，正在恢复..."
        restore_file "$full" "$backup"
        reload_singbox
        pause
        return
    fi

    green "认证修改成功"
    pause
}

delete_user() {
    local file="$1"
    local tag="$2"
    local user="$3"
    local full="$CONF_DIR/$file"

    title "删除用户"

    echo -e "${yellow}节点:${re} $tag"
    echo -e "${yellow}用户:${re} $user"
    echo

    red "删除后该用户将立即失效。"
    read -rp "$(yellow "确认删除？[y/N]: ")" confirm

    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    backup_file "$full"

    local backup
    backup="$(find_backup "$full")"

    "$PYTHON" - "$full" "$tag" "$user" <<'PY'
import sys
import json

fn, tag, name = sys.argv[1:]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

found = False

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        old = inbound.get("users", [])
        new = [u for u in old if u.get("name") != name]

        if len(new) != len(old):
            found = True

        inbound["users"] = new

if not found:
    raise SystemExit("用户不存在")

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

    if ! check_config; then
        red "配置检查失败，正在恢复..."
        restore_file "$full" "$backup"
        pause
        return
    fi

    if ! reload_singbox; then
        red "sing-box 重载失败，正在恢复..."
        restore_file "$full" "$backup"
        reload_singbox
        pause
        return
    fi

    rm -f "$(get_limit_file "$tag" "$user")"

    green "用户删除成功"
    pause
}

show_connections() {
    local tag="$1"
    local type="$2"
    local port="$3"

    title "节点连接"

    echo -e "${skyblue}节点:${re} $tag"
    echo -e "${skyblue}协议:${re} $type"
    echo -e "${skyblue}端口:${re} ${port:-未知}"
    echo

    if [ -z "$port" ]; then
        red "该节点没有监听端口信息"
        pause
        return
    fi

    echo -e "${green}TCP 连接:${re}"
    echo

    if command -v ss >/dev/null 2>&1; then
        ss -ntp 2>/dev/null | awk -v p=":$port" '
        NR==1 || $4 ~ p || $5 ~ p
        ' | head -n 50

        echo
        echo -e "${green}UDP 连接:${re}"
        echo

        ss -nuap 2>/dev/null | awk -v p=":$port" '
        NR==1 || $4 ~ p || $5 ~ p
        ' | head -n 50
    else
        red "系统没有 ss 命令"
    fi

    echo
    yellow "说明：这里显示的是该节点端口的活动连接。"
    yellow "对于 Hysteria2 / QUIC 等加密协议，系统层面无法可靠地把每条连接对应到具体用户。"

    pause
}

user_menu() {
    local file="$1"
    local tag="$2"
    local type="$3"
    local port="$4"
    local user="$5"

    while true; do
        title "$user"

        local user_json
        user_json="$(get_user_json "$file" "$tag" "$user")"

        echo -e "${skyblue}节点:${re} $tag"
        echo -e "${skyblue}协议:${re} $type"

        case "$type" in
            vmess|vless|tuic)
                local uuid
                uuid="$("$PYTHON" - "$user_json" <<'PY'
import sys
import json
d=json.loads(sys.argv[1])
print(d.get("uuid",""))
PY
)"
                echo -e "${skyblue}UUID :${re} $uuid"
                ;;
            *)
                local password
                password="$("$PYTHON" - "$user_json" <<'PY'
import sys
import json
d=json.loads(sys.argv[1])
print(d.get("password",""))
PY
)"
                echo -e "${skyblue}密码 :${re} $password"
                ;;
        esac

        echo -e "${skyblue}流量限制:${re} "
        show_limit "$tag" "$user"

        echo
        echo -e "  ${green}1)${re} 修改 $(
            case "$type" in
                vmess|vless|tuic) echo "UUID";;
                *) echo "密码";;
            esac
        )"

        echo -e "  ${green}2)${re} 流量限制"
        echo -e "  ${green}3)${re} 查看节点连接"
        echo -e "  ${red}4)${re} 删除用户"
        echo
        echo -e "  ${yellow}0)${re} 返回"
        echo

        read -rp "$(green "请选择: ")" choice

        case "$choice" in
            1)
                backup_file "$CONF_DIR/$file"
                modify_auth "$file" "$tag" "$type" "$user"
                ;;
            2)
                set_limit "$tag" "$user"
                ;;
            3)
                show_connections "$tag" "$type" "$port"
                ;;
            4)
                delete_user "$file" "$tag" "$user"
                return
                ;;
            0)
                return
                ;;
            *)
                red "无效选择"
                sleep 1
                ;;
        esac
    done
}

main_menu() {
    cleanup_backups

    while true; do
        title "sing-box 用户管理"

        mapfile -t NODES < <(list_nodes)

        if [ "${#NODES[@]}" -eq 0 ]; then
            yellow "没有找到包含 users[] 的入站节点。"
            echo
            echo "配置目录：$CONF_DIR"
            echo
            pause
            exit 0
        fi

        local i=1

        for line in "${NODES[@]}"; do
            IFS=$'\t' read -r file tag type count port <<< "$line"

            printf "  ${green}%2d)${re} %-30s ${skyblue}用户:${re}%s\n" \
                "$i" "$tag" "$count"

            ((i++))
        done

        echo
        echo -e "  ${yellow}0)${re} 退出"
        echo

        read -rp "$(green "请选择节点: ")" choice

        if [ "$choice" = "0" ]; then
            clear
            exit 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#NODES[@]}" ]; then
            local index=$((choice-1))
            IFS=$'\t' read -r file tag type count port <<< "${NODES[$index]}"
            node_menu "$file" "$tag" "$type" "$port"
        else
            red "无效选择"
            sleep 1
        fi
    done
}

main_menu
