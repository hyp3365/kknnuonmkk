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
TRAFFIC_DIR="$DATA_DIR/traffic"
TRAFFIC_SCRIPT="$TRAFFIC_DIR/singbox_traffic.py"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"
TRAFFIC_LOG="$TRAFFIC_DIR/traffic.log"
SINGBOX="$BASE_DIR/sing-box"
SERVICE="sing-box"
PYTHON="$(command -v python3 2>/dev/null || true)"

TRAFFIC_DIR="$DATA_DIR/traffic"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"


init_traffic() {
    mkdir -p "$TRAFFIC_DIR"
    if [ ! -f "$TRAFFIC_STATE" ]; then
        cat > "$TRAFFIC_STATE" <<'EOF'
{
  "users": {},
  "connections": {}
}
EOF
        chmod 600 "$TRAFFIC_STATE"
    fi
    if [ ! -f "$TRAFFIC_SCRIPT" ]; then
        cat > "$TRAFFIC_SCRIPT" <<'PY'
#!/usr/bin/env python3
import json
import os
import subprocess
import time
from pathlib import Path

BASE_DIR = Path("/etc/sing-box")
TRAFFIC_DIR = BASE_DIR / "user_manager" / "traffic"
STATE_FILE = TRAFFIC_DIR / "state.json"
LOG_FILE = TRAFFIC_DIR / "traffic.log"
GRPCURL = "/tmp/grpcurl"
API_ADDR = "127.0.0.1:9093"
API_SECRET = "Wiy5ULBThVo6cbHyd8JyghSW"
SAVE_INTERVAL = 15
RECONNECT_INTERVAL = 3

TRAFFIC_DIR.mkdir(parents=True, exist_ok=True)

def log_error(message):
    try:
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n")
    except Exception:
        pass

def load_state():
    if not STATE_FILE.exists():
        return {"users": {}, "connections": {}}
    try:
        with STATE_FILE.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("invalid state")
        if not isinstance(data.get("users"), dict):
            data["users"] = {}
        if not isinstance(data.get("connections"), dict):
            data["connections"] = {}
        return data
    except Exception as e:
        log_error(f"load_state error: {e}")
        return {"users": {}, "connections": {}}

def save_state(state):
    tmp_file = STATE_FILE.with_suffix(".tmp")
    try:
        with tmp_file.open("w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_file, STATE_FILE)
    except Exception as e:
        try:
            tmp_file.unlink(missing_ok=True)
        except Exception:
            pass
        log_error(f"save_state error: {e}")

def ensure_user(state, user):
    if not user:
        return None
    stats = state["users"].get(user)
    if stats is None:
        stats = {
            "uplink": 0,
            "downlink": 0,
            "total": 0,
            "connections": 0
        }
        state["users"][user] = stats
    return stats

def add_traffic(state, user, uplink=0, downlink=0):
    if not user:
        return
    uplink = int(uplink or 0)
    downlink = int(downlink or 0)
    if uplink <= 0 and downlink <= 0:
        return
    stats = ensure_user(state, user)
    if uplink > 0:
        stats["uplink"] += uplink
    if downlink > 0:
        stats["downlink"] += downlink
    stats["total"] += uplink + downlink

def get_totals(connection):
    return (
        int(connection.get("uplinkTotal") or 0),
        int(connection.get("downlinkTotal") or 0)
    )

def process_new(state, event):
    connection = event.get("connection") or {}
    conn_id = event.get("id") or connection.get("id")
    user = connection.get("user")
    if not conn_id or not user:
        return False
    connections = state["connections"]
    if conn_id in connections:
        return False
    uplink, downlink = get_totals(connection)
    connections[conn_id] = {
        "user": user,
        "uplink_total": uplink,
        "downlink_total": downlink,
        "created_at": connection.get("createdAt", "")
    }
    stats = ensure_user(state, user)
    stats["connections"] += 1
    if uplink or downlink:
        add_traffic(state, user, uplink, downlink)
    return True

def process_update(state, event):
    conn_id = event.get("id")
    if not conn_id:
        return False
    connections = state["connections"]
    conn = connections.get(conn_id)
    connection = event.get("connection") or {}
    if conn is None:
        user = connection.get("user")
        if not user:
            return False
        conn = {
            "user": user,
            "uplink_total": 0,
            "downlink_total": 0,
            "created_at": connection.get("createdAt", "")
        }
        connections[conn_id] = conn
        stats = ensure_user(state, user)
        stats["connections"] += 1
        initial_uplink, initial_downlink = get_totals(connection)
        if initial_uplink or initial_downlink:
            add_traffic(state, user, initial_uplink, initial_downlink)
            conn["uplink_total"] = initial_uplink
            conn["downlink_total"] = initial_downlink
    user = conn["user"]
    changed = False
    uplink_delta = int(event.get("uplinkDelta") or 0)
    downlink_delta = int(event.get("downlinkDelta") or 0)
    if uplink_delta > 0 or downlink_delta > 0:
        add_traffic(state, user, uplink_delta, downlink_delta)
        conn["uplink_total"] += max(uplink_delta, 0)
        conn["downlink_total"] += max(downlink_delta, 0)
        changed = True
    final_uplink = connection.get("uplinkTotal")
    if final_uplink is not None:
        final_uplink = int(final_uplink)
        if final_uplink > conn["uplink_total"]:
            delta = final_uplink - conn["uplink_total"]
            add_traffic(state, user, uplink=delta)
            conn["uplink_total"] = final_uplink
            changed = True
    final_downlink = connection.get("downlinkTotal")
    if final_downlink is not None:
        final_downlink = int(final_downlink)
        if final_downlink > conn["downlink_total"]:
            delta = final_downlink - conn["downlink_total"]
            add_traffic(state, user, downlink=delta)
            conn["downlink_total"] = final_downlink
            changed = True
    return changed

def process_closed(state, event):
    conn_id = event.get("id")
    if not conn_id:
        return False
    connections = state["connections"]
    conn = connections.get(conn_id)
    if conn is None:
        return False
    connection = event.get("connection") or {}
    user = conn["user"]
    final_uplink = connection.get("uplinkTotal")
    final_downlink = connection.get("downlinkTotal")
    if final_uplink is None:
        final_uplink = conn["uplink_total"]
    else:
        final_uplink = int(final_uplink)
    if final_downlink is None:
        final_downlink = conn["downlink_total"]
    else:
        final_downlink = int(final_downlink)
    extra_uplink = max(final_uplink - conn["uplink_total"], 0)
    extra_downlink = max(final_downlink - conn["downlink_total"], 0)
    if extra_uplink or extra_downlink:
        add_traffic(state, user, extra_uplink, extra_downlink)
    stats = ensure_user(state, user)
    if stats["connections"] > 0:
        stats["connections"] -= 1
    del connections[conn_id]
    return True

def process_event(state, event):
    event_type = event.get("type", "")
    if event_type == "CONNECTION_EVENT_NEW":
        return process_new(state, event)
    if event_type == "CONNECTION_EVENT_UPDATE":
        return process_update(state, event)
    if event_type == "CONNECTION_EVENT_CLOSED":
        return process_closed(state, event)
    if "connection" in event and event.get("id"):
        return process_new(state, event)
    return False

def extract_json_objects(buffer):
    decoder = json.JSONDecoder()
    position = 0
    objects = []
    length = len(buffer)
    while position < length:
        while position < length and buffer[position].isspace():
            position += 1
        if position >= length:
            break
        try:
            obj, end = decoder.raw_decode(buffer, position)
        except json.JSONDecodeError:
            break
        objects.append(obj)
        position = end
    return buffer[position:], objects

def run_stream(state):
    command = [
        GRPCURL,
        "-plaintext",
        "-H",
        f"Authorization: Bearer {API_SECRET}",
        "-d",
        '{"interval":0}',
        API_ADDR,
        "daemon.StartedService/SubscribeConnections"
    ]
    buffer = ""
    dirty = False
    last_save = time.monotonic()
    process = None
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1
        )
        while True:
            line = process.stdout.readline()
            if not line:
                break
            buffer += line
            buffer, objects = extract_json_objects(buffer)
            for obj in objects:
                events = obj.get("events")
                if not events:
                    continue
                for event in events:
                    if process_event(state, event):
                        dirty = True
            now = time.monotonic()
            if dirty and now - last_save >= SAVE_INTERVAL:
                save_state(state)
                dirty = False
                last_save = now
        if dirty:
            save_state(state)
    except Exception as e:
        log_error(f"stream error: {e}")
    finally:
        if process is not None:
            try:
                process.kill()
            except Exception:
                pass
            try:
                process.wait(timeout=2)
            except Exception:
                pass

def main():
    state = load_state()
    while True:
        try:
            run_stream(state)
        except KeyboardInterrupt:
            save_state(state)
            break
        except Exception as e:
            log_error(f"main error: {e}")
        time.sleep(RECONNECT_INTERVAL)

if __name__ == "__main__":
    main()
PY
        chmod +x "$TRAFFIC_SCRIPT"
    fi
}


mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$LIMIT_DIR"
init_traffic

if [ ! -f "$TRAFFIC_STATE" ]; then
    cat > "$TRAFFIC_STATE" <<'EOF'
{
  "users": {},
  "connections": {}
}
EOF
fi

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

TRAFFIC_DIR="$DATA_DIR/traffic"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"

format_bytes() {
    local bytes="${1:-0}"

    "$PYTHON" - "$bytes" <<'PY'
import sys

try:
    n = int(float(sys.argv[1]))
except:
    n = 0

units = ["B", "KB", "MB", "GB", "TB", "PB"]

i = 0
v = float(n)

while v >= 1024 and i < len(units) - 1:
    v /= 1024
    i += 1

if i == 0:
    print(f"{int(v)} {units[i]}")
elif v >= 100:
    print(f"{v:.0f} {units[i]}")
elif v >= 10:
    print(f"{v:.1f} {units[i]}")
else:
    print(f"{v:.2f} {units[i]}")
PY
}

get_user_traffic() {
    local user="$1"

    if [ ! -f "$TRAFFIC_STATE" ]; then
        echo "0 0 0 0"
        return
    fi

    "$PYTHON" - "$TRAFFIC_STATE" "$user" <<'PY'
import sys
import json

fn = sys.argv[1]
user = sys.argv[2]

try:
    with open(fn, "r", encoding="utf-8") as f:
        data = json.load(f)
except:
    print("0 0 0 0")
    raise SystemExit

d = data.get("users", {}).get(user, {})

uplink = int(d.get("uplink", 0) or 0)
downlink = int(d.get("downlink", 0) or 0)
total = int(d.get("total", uplink + downlink) or 0)
connections = int(d.get("connections", 0) or 0)

print(uplink, downlink, total, connections)
PY
}

show_user_traffic() {
    local user="$1"

    title "流量统计"

    echo -e "${skyblue}用户:${re} $user"
    echo

    if [ ! -f "$TRAFFIC_STATE" ]; then
        red "未找到流量统计文件："
        echo "$TRAFFIC_STATE"
        pause
        return
    fi

    local traffic
    traffic="$(get_user_traffic "$user")"

    local uplink
    local downlink
    local total
    local connections

    read -r uplink downlink total connections <<< "$traffic"

    echo -e "${skyblue}上传:${re}   $(format_bytes "$uplink")"
    echo -e "${skyblue}下载:${re}   $(format_bytes "$downlink")"
    echo -e "${skyblue}总流量:${re} $(format_bytes "$total")"
    echo -e "${skyblue}连接数:${re} $connections"

    echo
    echo -e "${skyblue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${re}"

    echo -e "${skyblue}原始数据:${re}"
    echo "上传     : $uplink B"
    echo "下载     : $downlink B"
    echo "总流量   : $total B"
    echo "连接数   : $connections"

    echo
    pause
}

show_user_traffic_inline() {
    local user="$1"

    if [ ! -f "$TRAFFIC_STATE" ]; then
        echo -e "${yellow}未统计${re}"
        return
    fi

    local traffic
    traffic="$(get_user_traffic "$user")"

    local uplink
    local downlink
    local total
    local connections

    read -r uplink downlink total connections <<< "$traffic"

    echo -e "上传 $(format_bytes "$uplink")"
    echo -e "下载 $(format_bytes "$downlink")"
    echo -e "总计 $(format_bytes "$total")"
    echo -e "连接 $connections"
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
    local file="$1"
    local tag="$2"
    local type="$3"
    local port="$4"
    local user="$5"
    local user_json=""
    local auth=""
    local password=""
    if [[ -z "$file" || -z "$tag" || -z "$type" || -z "$user" ]]; then
        red "参数错误"
        read -rp "按回车继续..."
        return
    fi
    user_json="$(get_user_json "$file" "$tag" "$user")"
    if [[ -z "$user_json" || "$user_json" == "null" ]]; then
        red "无法找到用户：$user"
        read -rp "按回车继续..."
        return
    fi
    case "$type" in
        hysteria2|hy2|hysteria)
            auth="$(printf '%s' "$user_json" | "$PYTHON" -c 'import sys,json; d=json.load(sys.stdin); print(d.get("password",""))')"
            ;;
        vless|vmess)
            auth="$(printf '%s' "$user_json" | "$PYTHON" -c 'import sys,json; d=json.load(sys.stdin); print(d.get("uuid",""))')"
            ;;
        tuic)
            auth="$(printf '%s' "$user_json" | "$PYTHON" -c 'import sys,json; d=json.load(sys.stdin); print(d.get("uuid",""))')"
            password="$(printf '%s' "$user_json" | "$PYTHON" -c 'import sys,json; d=json.load(sys.stdin); print(d.get("password",""))')"
            ;;
        trojan)
            auth="$(printf '%s' "$user_json" | "$PYTHON" -c 'import sys,json; d=json.load(sys.stdin); print(d.get("password",""))')"
            ;;
        *)
            red "暂不支持协议：$type"
            read -rp "按回车继续..."
            return
            ;;
    esac
    if [[ -z "$auth" ]]; then
        red "无法获取用户认证信息"
        read -rp "按回车继续..."
        return
    fi
    if [[ "$type" == "tuic" && -z "$password" ]]; then
        red "无法获取 TUIC 用户密码"
        read -rp "按回车继续..."
        return
    fi
    if [[ ! -f "/etc/sing-box/url.txt" ]]; then
        red "未找到 /etc/sing-box/url.txt"
        read -rp "按回车继续..."
        return
    fi
    echo
    skyblue "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    green "用户连接信息"
    echo "用户: $user"
    echo "节点: $tag"
    echo "协议: $type"
    echo "端口: $port"
    skyblue "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    "$PYTHON" - "$type" "$auth" "$password" "/etc/sing-box/url.txt" <<'PY'
import sys
import json
import base64
import urllib.parse
typ = sys.argv[1].lower()
auth = sys.argv[2]
password = sys.argv[3]
url_file = sys.argv[4]
def b64decode_urlsafe(s):
    s = s.strip()
    s += "=" * (-len(s) % 4)
    s = s.replace("-", "+").replace("_", "/")
    return base64.b64decode(s).decode("utf-8")
def b64encode_urlsafe(s):
    return base64.b64encode(s.encode("utf-8")).decode("ascii").rstrip("=")
try:
    with open(url_file, "r", encoding="utf-8") as f:
        lines = f.readlines()
except Exception as e:
    print("读取 url.txt 失败:", e)
    sys.exit(1)
found = False
for raw in lines:
    line = raw.strip()
    if not line:
        continue
    try:
        low = line.lower()
        if typ in ("hysteria2", "hy2"):
            if not low.startswith("hysteria2://") and not low.startswith("hy2://"):
                continue
            scheme_end = line.find("://")
            scheme = line[:scheme_end]
            rest = line[scheme_end + 3:]
            if "@" not in rest:
                continue
            _, suffix = rest.split("@", 1)
            print(scheme + "://" + urllib.parse.quote(auth, safe="") + "@" + suffix)
            found = True
            continue
        if typ == "hysteria":
            if not low.startswith("hysteria://"):
                continue
            rest = line[len("hysteria://"):]
            if "@" not in rest:
                continue
            _, suffix = rest.split("@", 1)
            print("hysteria://" + urllib.parse.quote(auth, safe="") + "@" + suffix)
            found = True
            continue
        if typ == "vless":
            if not low.startswith("vless://"):
                continue
            rest = line[len("vless://"):]
            if "@" not in rest:
                continue
            _, suffix = rest.split("@", 1)
            print("vless://" + urllib.parse.quote(auth, safe="") + "@" + suffix)
            found = True
            continue
        if typ == "trojan":
            if not low.startswith("trojan://"):
                continue
            rest = line[len("trojan://"):]
            if "@" not in rest:
                continue
            _, suffix = rest.split("@", 1)
            print("trojan://" + urllib.parse.quote(auth, safe="") + "@" + suffix)
            found = True
            continue
        if typ == "tuic":
            if not low.startswith("tuic://"):
                continue
            rest = line[len("tuic://"):]
            if "@" not in rest:
                continue
            _, suffix = rest.split("@", 1)
            new_auth = (
                urllib.parse.quote(auth, safe="") +
                ":" +
                urllib.parse.quote(password, safe="")
            )
            print("tuic://" + new_auth + "@" + suffix)
            found = True
            continue
        if typ == "vmess":
            if not low.startswith("vmess://"):
                continue
            encoded = line[len("vmess://"):].strip()
            decoded = b64decode_urlsafe(encoded)
            obj = json.loads(decoded)
            obj["id"] = auth
            new_json = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
            print("vmess://" + b64encode_urlsafe(new_json))
            found = True
            continue
    except Exception as e:
        print("处理连接失败:", e)
if not found:
    print("url.txt 中没有找到对应协议的连接链接。")
PY
    echo
    skyblue "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -rp "按回车继续..."
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
        echo -e "${skyblue}流量统计:${re}"
if [ -f "$TRAFFIC_STATE" ]; then
    local traffic
    traffic="$(get_user_traffic "$user")"

    local uplink
    local downlink
    local total
    local connections

    read -r uplink downlink total connections <<< "$traffic"

    echo "  上传:   $(format_bytes "$uplink")"
    echo "  下载:   $(format_bytes "$downlink")"
    echo "  总流量: $(format_bytes "$total")"
    echo "  连接数: $connections"
else
    echo "  未统计"
fi

        echo
        echo -e "  ${green}1)${re} 修改 $(
    case "$type" in
        vmess|vless|tuic) echo "UUID";;
        *) echo "密码";;
    esac
)"

echo -e "  ${green}2)${re} 流量限制"
echo -e "  ${green}3)${re} 流量统计"
echo -e "  ${green}4)${re} 查看节点连接"
echo -e "  ${red}5)${re} 删除用户"
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
        show_user_traffic "$user"
        ;;
    4)
        show_connections "$file" "$tag" "$type" "$port" "$user"
        ;;
    5)
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
