#!/bin/bash
set -u
BASE_DIR="/etc/sing-box"
CONF_DIR="$BASE_DIR/conf"
DATA_DIR="$BASE_DIR/user_manager"
BACKUP_DIR="$DATA_DIR/backups"
SINGBOX="$BASE_DIR/sing-box"
SERVICE="sing-box"
PYTHON="$(command -v python3 2>/dev/null || true)"
mkdir -p "$DATA_DIR" "$BACKUP_DIR"
chmod 700 "$DATA_DIR" "$BACKUP_DIR"
clear
echo "========================================"
echo "        sing-box 用户管理"
echo "========================================"
if [ ! -d "$CONF_DIR" ]; then
    echo
    echo "错误：找不到 sing-box 配置目录："
    echo "$CONF_DIR"
    exit 1
fi
if [ ! -x "$SINGBOX" ]; then
    echo
    echo "错误：找不到 sing-box："
    echo "$SINGBOX"
    exit 1
fi
if [ -z "$PYTHON" ]; then
    echo
    echo "错误：VPS 没有安装 python3。"
    exit 1
fi
pause() {
    echo
    read -rp "按回车继续..." _
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
    echo
    echo "========================================"
    echo "              选择节点"
    echo "========================================"
    local n=1
    while IFS=$'\t' read -r file index tag type count; do
        [ -z "${file:-}" ] && continue
        NODE_LINES[$n]="$file"$'\t'"$index"$'\t'"$tag"$'\t'"$type"$'\t'"$count"
        printf "%2d. %-25s %-15s 用户:%s\n" "$n" "$tag" "$type" "$count"
        ((n++))
    done < <(scan_nodes)
    if [ "$n" -eq 1 ]; then
        echo
        echo "没有找到带 users[] 的入站节点。"
        return 1
    fi
    echo
    read -rp "请输入节点编号: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$n" ]; then
        echo "选择无效。"
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
generate_ss_password() {
    "$PYTHON" - <<'PY'
import secrets
import base64
print(base64.b64encode(secrets.token_bytes(24)).decode())
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
    if "max_realms" in existing:
        user["max_realms"] = existing.get("max_realms", 0)
else:
    raise SystemExit("不支持的协议")
users.append(user)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}
show_user_result() {
    echo
    echo "========================================"
    echo "              用户信息"
    echo "========================================"
    echo "节点     : $SELECT_TAG"
    echo "协议     : $SELECT_TYPE"
    echo "用户名   : $NEW_NAME"
    if [ -n "${AUTH1:-}" ]; then
        echo "认证信息 : $AUTH1"
    fi
    if [ -n "${AUTH2:-}" ]; then
        echo "密码     : $AUTH2"
    fi
    echo "配置文件 : $SELECT_FILE"
    echo "========================================"
}
reload_after_check() {
    echo
    echo "正在检查 sing-box 配置..."
    if ! "$SINGBOX" check -C "$CONF_DIR"; then
        return 1
    fi
    echo "配置检查通过。"
    echo
    echo "正在重新加载 sing-box..."
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
    echo
    echo "正在恢复原配置..."
    cp -a "$backup" "$target"
    echo "原配置已恢复。"
}
add_user() {
    if ! select_node; then
        pause
        return
    fi
    NEW_NAME="$(next_username)"
    AUTH1=""
    AUTH2=""
    echo
    echo "========================================"
    echo "              新增用户"
    echo "========================================"
    echo "节点：$SELECT_TAG"
    echo "协议：$SELECT_TYPE"
    echo "用户名：$NEW_NAME"
    echo
    case "$SELECT_TYPE" in
        hysteria2|trojan|anytls|shadowtls|shadowsocks|naive|socks|http|mixed)
            read -rp "密码（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_password)"
            ;;
        vmess|vless)
            read -rp "UUID（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_uuid)"
            ;;
        tuic)
            read -rp "UUID（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_uuid)"
            read -rp "密码（直接回车自动生成）: " AUTH2
            [ -n "$AUTH2" ] || AUTH2="$(generate_password)"
            ;;
        hysteria)
            read -rp "认证密码（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_password)"
            ;;
        hysteria-realm)
            read -rp "Token（直接回车自动生成）: " AUTH1
            [ -n "$AUTH1" ] || AUTH1="$(generate_password)"
            ;;
        *)
            echo
            echo "当前协议暂未支持新增用户：$SELECT_TYPE"
            pause
            return
            ;;
    esac
    echo
    echo "========================================"
    echo "即将添加"
    echo "========================================"
    echo "节点     : $SELECT_TAG"
    echo "协议     : $SELECT_TYPE"
    echo "用户名   : $NEW_NAME"
    echo "认证信息 : $AUTH1"
    [ -n "$AUTH2" ] && echo "密码     : $AUTH2"
    echo "========================================"
    echo
    read -rp "确认添加？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || {
        echo "已取消。"
        pause
        return
    }
    local backup
    backup="$(backup_file "$SELECT_FILE")"
    echo
    echo "备份：$backup"
    if ! add_user_json; then
        echo
        echo "修改失败。"
        restore_backup "$backup" "$SELECT_FILE"
        pause
        return
    fi
    if ! reload_after_check; then
        echo
        echo "sing-box 检查或 reload 失败。"
        restore_backup "$backup" "$SELECT_FILE"
        "$SINGBOX" check -C "$CONF_DIR" >/dev/null 2>&1 || true
        systemctl reload "$SERVICE" >/dev/null 2>&1 || true
        echo "已恢复原配置。"
        pause
        return
    fi
    echo
    echo "========================================"
    echo "          用户添加成功"
    echo "========================================"
    show_user_result
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
print("========================================")
print("              用户列表")
print("========================================")
if not users:
    print("暂无用户")
else:
    for i, user in enumerate(users, 1):
        print(f"{i}. {user.get('name', user.get('username', '(无用户名)'))}")
        if "uuid" in user:
            print(f"   UUID     : {user['uuid']}")
        if "username" in user:
            print(f"   Username : {user['username']}")
        if "password" in user:
            print(f"   Password : {user['password']}")
        if "auth_str" in user:
            print(f"   Auth     : {user['auth_str']}")
        if "auth" in user:
            print(f"   Auth     : {user['auth']}")
        if "token" in user:
            print(f"   Token    : {user['token']}")
        if "flow" in user:
            print(f"   Flow     : {user['flow']}")
print("========================================")
PY
}
view_users() {
    if ! select_node; then
        pause
        return
    fi
    echo
    echo "节点：$SELECT_TAG"
    echo "协议：$SELECT_TYPE"
    echo "配置：$SELECT_FILE"
    list_users
    pause
}
delete_user() {
    if ! select_node; then
        pause
        return
    fi
    USER_LINES=()
    echo
    echo "========================================"
    echo "              删除用户"
    echo "========================================"
    local n=1
    while IFS=$'\t' read -r index name; do
        [ -z "${index:-}" ] && continue
        USER_LINES[$n]="$index"$'\t'"$name"
        printf "%2d. %s\n" "$n" "$name"
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
        echo
        echo "该节点没有用户。"
        pause
        return
    fi
    echo
    read -rp "请输入用户编号: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$n" ]; then
        echo "选择无效。"
        pause
        return
    fi
    IFS=$'\t' read -r USER_INDEX USER_NAME <<< "${USER_LINES[$choice]}"
    echo
    echo "节点：$SELECT_TAG"
    echo "用户：$USER_NAME"
    echo
    read -rp "确认删除？输入 DELETE 确认: " confirm
    if [ "$confirm" != "DELETE" ]; then
        echo "已取消。"
        pause
        return
    fi
    local backup
    backup="$(backup_file "$SELECT_FILE")"
    echo
    echo "备份：$backup"
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
        echo "删除失败。"
        restore_backup "$backup" "$SELECT_FILE"
        pause
        return
    fi
    if ! reload_after_check; then
        echo
        echo "sing-box 检查或 reload 失败。"
        restore_backup "$backup" "$SELECT_FILE"
        "$SINGBOX" check -C "$CONF_DIR" >/dev/null 2>&1 || true
        systemctl reload "$SERVICE" >/dev/null 2>&1 || true
        echo "已恢复原配置。"
        pause
        return
    fi
    echo
    echo "========================================"
    echo "用户删除成功：$USER_NAME"
    echo "========================================"
    pause
}
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo "          sing-box 用户管理"
        echo "========================================"
        echo
        echo "1. 新增用户"
        echo "2. 删除用户"
        echo "3. 查看用户"
        echo "0. 退出"
        echo
        read -rp "请选择: " choice
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
                echo "无效选择。"
                sleep 1
                ;;
        esac
    done
}
main_menu


