#!/bin/bash
export LANG=en_US.UTF-8
BASE_DIR="/etc/sing-box"
CONF_DIR="$BASE_DIR/conf"
DATA_DIR="$BASE_DIR/user_manager"
BACKUP_DIR="$DATA_DIR/backups"
SINGBOX="$BASE_DIR/sing-box"
SERVICE="sing-box"
PYTHON="$(command -v python3 2>/dev/null || true)"
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
mkdir -p "$DATA_DIR" "$BACKUP_DIR"
chmod 700 "$DATA_DIR" "$BACKUP_DIR"
if [ ! -d "$CONF_DIR" ]; then
    red "错误：找不到 sing-box 配置目录：$CONF_DIR"
    exit 1
fi
if [ ! -x "$SINGBOX" ]; then
    red "错误：找不到 sing-box：$SINGBOX"
    exit 1
fi
if [ -z "$PYTHON" ]; then
    red "错误：VPS 没有安装 python3。"
    exit 1
fi
pause() {
    echo
    read -rp "按回车继续..." _
}
title() {
    clear
    echo -e "${green}╔════════════════════════════════════════╗${re}"
    echo -e "${green}║${re}          ${skyblue}sing-box 用户管理${re}          ${green}║${re}"
    echo -e "${green}╚════════════════════════════════════════╝${re}"
    echo
}
scan_nodes() {
    "$PYTHON" - "$CONF_DIR" <<'PY'
import json
import glob
import os
import sys
conf_dir = sys.argv[1]
for path in sorted(glob.glob(os.path.join(conf_dir, "*.json"))):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        continue
    inbounds = data.get("inbounds", [])
    if not isinstance(inbounds, list):
        continue
    for index, inbound in enumerate(inbounds):
        if not isinstance(inbound, dict):
            continue
        users = inbound.get("users")
        if not isinstance(users, list):
            continue
        tag = str(inbound.get("tag") or "untagged-" + str(index + 1))
        typ = str(inbound.get("type") or "unknown")
        print(f"{path}\t{index}\t{tag}\t{typ}\t{len(users)}")
PY
}
select_node() {
    NODE_LINES=()
    echo -e "${green}┌────────────────────────────────────────┐${re}"
    echo -e "${green}│${re}              ${skyblue}选择节点${re}              ${green}│${re}"
    echo -e "${green}└────────────────────────────────────────┘${re}"
    echo
    local n=1
    while IFS=$'\t' read -r file index tag type count; do
        [ -z "${file:-}" ] && continue
        NODE_LINES[$n]="$file"$'\t'"$index"$'\t'"$tag"$'\t'"$type"$'\t'"$count"
        printf " ${yellow}%2d${re}) ${skyblue}%-25s${re} ${purple}%-15s${re} ${green}用户:%s${re}\n" "$n" "$tag" "$type" "$count"
        ((n++))
    done < <(scan_nodes)
    if [ "$n" -eq 1 ]; then
        echo
        red "没有找到带 users[] 的入站节点。"
        return 1
    fi
    echo
    reading "请输入节点编号: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$n" ]; then
        red "选择无效。"
        return 1
    fi
    IFS=$'\t' read -r SELECT_FILE SELECT_INDEX SELECT_TAG SELECT_TYPE SELECT_COUNT <<< "${NODE_LINES[$choice]}"
    return 0
}
next_username() {
    "$PYTHON" - "$SELECT_FILE" "$SELECT_INDEX" "$SELECT_TAG" <<'PY'
import json
import re
import sys
path = sys.argv[1]
index = int(sys.argv[2])
tag = sys.argv[3]
prefix = tag + "-user"
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
users = data["inbounds"][index].get("users", [])
used = set()
for user in users:
    if not isinstance(user, dict):
        continue
    name = str(user.get("name", ""))
    m = re.fullmatch(re.escape(prefix) + r"(\d+)", name)
    if m:
        used.add(int(m.group(1)))
n = 1
while n in used:
    n += 1
print(prefix + str(n))
PY
}
generate_uuid() {
    "$PYTHON" - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
}
generate_password() {
    "$PYTHON" - <<'PY'
import secrets
import string
chars = string.ascii_letters + string.digits
print("".join(secrets.choice(chars) for _ in range(32)))
PY
}
backup_file() {
    local file="$1"
    local stamp
    local base
    local backup
    stamp="$(date '+%Y%m%d-%H%M%S')"
    base="$(basename "$file")"
    backup="$BACKUP_DIR/${base}.${stamp}.bak"
    cp -a "$file" "$backup"
    echo "$backup"
}
add_user_json() {
    "$PYTHON" - "$SELECT_FILE" "$SELECT_INDEX" "$SELECT_TYPE" "$NEW_NAME" "$AUTH1" "$AUTH2" <<'PY'
import json
import sys
path = sys.argv[1]
index = int(sys.argv[2])
typ = sys.argv[3]
name = sys.argv[4]
auth1 = sys.argv[5]
auth2 = sys.argv[6]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
inbounds = data.get("inbounds")
if not isinstance(inbounds, list) or index >= len(inbounds):
    raise SystemExit("入站不存在")
inbound = inbounds[index]
users = inbound.get("users")
if not isinstance(users, list):
    raise SystemExit("users[] 不存在")
existing = users[0] if users and isinstance(users[0], dict) else {}
user = {"name": name}
if typ == "hysteria2":
    user["password"] = auth1
elif typ == "vmess":
    user["uuid"] = auth1
    user["alterId"] = existing.get("alterId", 0)
elif typ == "vless":
    user["uuid"] = auth1
    if "flow" in existing:
        user["flow"] = existing.get("flow", "")
elif typ == "trojan":
    user["password"] = auth1
elif typ == "shadowsocks":
    user["password"] = auth1
elif typ in ("socks", "http", "mixed", "naive"):
    user = {
        "username": name,
        "password": auth1
    }
elif typ == "tuic":
    user["uuid"] = auth1
    user["password"] = auth2
elif typ == "anytls":
    user["password"] = auth1
elif typ == "shadowtls":
    user["password"] = auth1
elif typ == "hysteria":
    if "auth_str" in existing:
        user["auth_str"] = auth1
    else:
        user["auth"] = auth1
elif typ == "hysteria-realm":
    user["token"] = auth1
else:
    raise SystemExit("不支持的协议")
users.append(user)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}
reload_after_check() {
    echo
    echo -e "${skyblue}正在检查 sing-box 配置...${re}"
    if ! "$SINGBOX" check -C "$CONF_DIR"; then
        return 1
    fi
    green "配置检查通过。"
    echo
    echo -e "${skyblue}正在重新加载 sing-box...${re}"
    if ! systemctl reload "$SERVICE"; then
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet "$SERVICE"; then
        return 1
    fi
    return 0
}
restore_backup() {
    local backup="$1"
    local target="$2"
    yellow "正在恢复原配置..."
    cp -a "$backup" "$target"
    green "原配置已恢复。"
}
add_user() {
    title
    if ! select_node; then
        pause
        return
    fi
    NEW_NAME="$(next_username)"
    AUTH1=""
    AUTH2=""
    echo
    echo -e "${green}┌────────────────────────────────────────┐${re}"
    echo -e "${green}│${re}              ${skyblue}新增用户${re}              ${green}│${re}"
    echo -e "${green}└────────────────────────────────────────┘${re}"
    echo
    echo -e " ${yellow}节点${re}   : ${skyblue}$SELECT_TAG${re}"
    echo -e " ${yellow}协议${re}   : ${purple}$SELECT_TYPE${re}"
    echo -e " ${yellow}用户名${re} : ${green}$NEW_NAME${re}"
    echo
    case "$SELECT_TYPE" in
        hysteria2)
            echo -e "${skyblue}Hysteria2 用户密码使用 UUID 格式。${re}"
            read -rp "UUID（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_uuid)"
            ;;
        trojan|anytls|shadowtls|shadowsocks|naive|socks|http|mixed)
            reading "密码（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_password)"
            ;;
        vmess|vless)
            reading "UUID（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_uuid)"
            ;;
        tuic)
            reading "UUID（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_uuid)"
            reading "密码（直接回车自动生成）: " AUTH2
            [ -n "$AUTH2" ] || AUTH2="$(generate_password)"
            ;;
        hysteria)
            reading "认证密码（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_password)"
            ;;
        hysteria-realm)
            reading "Token（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_password)"
            ;;
        *)
            red "当前协议暂未支持新增用户：$SELECT_TYPE"
            pause
            return
            ;;
    esac
    echo
    echo -e "${green}┌────────────────────────────────────────┐${re}"
    echo -e "${green}│${re}              ${skyblue}用户信息${re}              ${green}│${re}"
    echo -e "${green}└────────────────────────────────────────┘${re}"
    echo
    echo -e " ${yellow}节点${re}     : $SELECT_TAG"
    echo -e " ${yellow}协议${re}     : $SELECT_TYPE"
    echo -e " ${yellow}用户名${re}   : ${green}$NEW_NAME${re}"
    echo -e " ${yellow}认证信息${re} : ${green}$AUTH1${re}"
    [ -n "$AUTH2" ] && echo -e " ${yellow}密码${re}     : ${green}$AUTH2${re}"
    echo
    reading "确认添加？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || {
        yellow "已取消。"
        pause
        return
    }
    local backup
    backup="$(backup_file "$SELECT_FILE")"
    echo
    echo -e "${skyblue}备份：${re}$backup"
    if ! add_user_json; then
        red "修改失败。"
        restore_backup "$backup" "$SELECT_FILE"
        pause
        return
    fi
    if ! reload_after_check; then
        red "sing-box 检查或 reload 失败。"
        restore_backup "$backup" "$SELECT_FILE"
        "$SINGBOX" check -C "$CONF_DIR" >/dev/null 2>&1 || true
        systemctl reload "$SERVICE" >/dev/null 2>&1 || true
        pause
        return
    fi
    echo
    echo -e "${green}╔════════════════════════════════════════╗${re}"
    echo -e "${green}║${re}          ${green}✓ 用户添加成功${re}          ${green}║${re}"
    echo -e "${green}╚════════════════════════════════════════╝${re}"
    echo
    echo -e " ${yellow}节点${re}     : $SELECT_TAG"
    echo -e " ${yellow}协议${re}     : $SELECT_TYPE"
    echo -e " ${yellow}用户名${re}   : ${green}$NEW_NAME${re}"
    echo -e " ${yellow}认证信息${re} : ${green}$AUTH1${re}"
    [ -n "$AUTH2" ] && echo -e " ${yellow}密码${re}     : ${green}$AUTH2${re}"
    echo
    pause
}
list_users() {
    "$PYTHON" - "$SELECT_FILE" "$SELECT_INDEX" <<'PY'
import json
import sys
path = sys.argv[1]
index = int(sys.argv[2])
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
inbound = data["inbounds"][index]
users = inbound.get("users", [])
print()
if not users:
    print("暂无用户")
else:
    for i, user in enumerate(users, 1):
        name = user.get("name") or user.get("username") or "(无用户名)"
        print(f"{i}. {name}")
        if "uuid" in user:
            print(f"   UUID      : {user['uuid']}")
        if "username" in user:
            print(f"   Username  : {user['username']}")
        if "password" in user:
            print(f"   Password  : {user['password']}")
        if "auth_str" in user:
            print(f"   Auth      : {user['auth_str']}")
        if "auth" in user:
            print(f"   Auth      : {user['auth']}")
        if "token" in user:
            print(f"   Token     : {user['token']}")
        if "flow" in user:
            print(f"   Flow      : {user['flow']}")
PY
}
view_users() {
    title
    if ! select_node; then
        pause
        return
    fi
    echo
    echo -e "${green}┌────────────────────────────────────────┐${re}"
    echo -e "${green}│${re}              ${skyblue}用户列表${re}              ${green}│${re}"
    echo -e "${green}└────────────────────────────────────────┘${re}"
    echo
    echo -e " ${yellow}节点${re} : ${skyblue}$SELECT_TAG${re}"
    echo -e " ${yellow}协议${re} : ${purple}$SELECT_TYPE${re}"
    echo
    list_users
    pause
}
delete_user() {
    title
    if ! select_node; then
        pause
        return
    fi
    USER_LINES=()
    echo
    echo -e "${green}┌────────────────────────────────────────┐${re}"
    echo -e "${green}│${re}              ${red}删除用户${re}              ${green}│${re}"
    echo -e "${green}└────────────────────────────────────────┘${re}"
    echo
    local n=1
    while IFS=$'\t' read -r index name; do
        [ -z "${index:-}" ] && continue
        USER_LINES[$n]="$index"$'\t'"$name"
        printf " ${yellow}%2d${re}) ${skyblue}%s${re}\n" "$n" "$name"
        ((n++))
    done < <("$PYTHON" - "$SELECT_FILE" "$SELECT_INDEX" <<'PY'
import json
import sys
path = sys.argv[1]
index = int(sys.argv[2])
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
users = data["inbounds"][index].get("users", [])
for i, user in enumerate(users):
    name = user.get("name") or user.get("username") or "(无用户名)"
    print(f"{i}\t{name}")
PY
)
    if [ "$n" -eq 1 ]; then
        yellow "该节点没有用户。"
        pause
        return
    fi
    echo
    reading "请输入用户编号: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$n" ]; then
        red "选择无效。"
        pause
        return
    fi
    IFS=$'\t' read -r USER_INDEX USER_NAME <<< "${USER_LINES[$choice]}"
    echo
    echo -e " ${yellow}节点${re} : $SELECT_TAG"
    echo -e " ${yellow}用户${re} : ${red}$USER_NAME${re}"
    echo
    echo -e "${red}警告：删除后该用户将立即失效。${re}"
    reading "输入 DELETE 确认删除: " confirm
    if [ "$confirm" != "DELETE" ]; then
        yellow "已取消。"
        pause
        return
    fi
    local backup
    backup="$(backup_file "$SELECT_FILE")"
    echo
    echo -e "${skyblue}备份：${re}$backup"
    if ! "$PYTHON" - "$SELECT_FILE" "$SELECT_INDEX" "$USER_INDEX" <<'PY'
import json
import sys
path = sys.argv[1]
inbound_index = int(sys.argv[2])
user_index = int(sys.argv[3])
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
inbound = data["inbounds"][inbound_index]
users = inbound.get("users")
if not isinstance(users, list):
    raise SystemExit("users[] 不存在")
if user_index < 0 or user_index >= len(users):
    raise SystemExit("用户不存在")
users.pop(user_index)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    then
        red "删除失败。"
        restore_backup "$backup" "$SELECT_FILE"
        pause
        return
    fi
    if ! reload_after_check; then
        red "sing-box 检查或 reload 失败。"
        restore_backup "$backup" "$SELECT_FILE"
        "$SINGBOX" check -C "$CONF_DIR" >/dev/null 2>&1 || true
        systemctl reload "$SERVICE" >/dev/null 2>&1 || true
        pause
        return
    fi
    echo
    echo -e "${green}╔════════════════════════════════════════╗${re}"
    echo -e "${green}║${re}          ${green}✓ 用户删除成功${re}          ${green}║${re}"
    echo -e "${green}╚════════════════════════════════════════╝${re}"
    echo
    echo -e " ${yellow}节点${re} : $SELECT_TAG"
    echo -e " ${yellow}用户${re} : ${red}$USER_NAME${re}"
    echo
    pause
}
main_menu() {
    while true; do
        title
        echo -e "${green}  1${re}) ${skyblue}新增用户${re}"
        echo -e "${green}  2${re}) ${red}删除用户${re}"
        echo -e "${green}  3${re}) ${yellow}查看用户${re}"
        echo -e "${green}  0${re}) 退出"
        echo
        reading "请选择: " choice
        case "$choice" in
            1)
                add_user
                ;;
            2)
                delete_user
                ;;
            3)
                view_users
                ;;
            0)
                clear
                exit 0
                ;;
            *)
                red "无效选择。"
                sleep 1
                ;;
        esac
    done
}
main_menu
