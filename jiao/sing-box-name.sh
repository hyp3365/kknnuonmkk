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
TRAFFIC_SERVICE="singbox-traffic.service"
PYTHON="$(command -v python3 2>/dev/null || true)"
CONFIG_LOCK="$DATA_DIR/.config.lock"
TRAFFIC_SCRIPT_CHANGED=0

init_traffic() {
    TRAFFIC_SCRIPT_CHANGED=0
    mkdir -p "$TRAFFIC_DIR" "$LIMIT_DIR" "$BACKUP_DIR"
    chmod 700 "$TRAFFIC_DIR" "$LIMIT_DIR" "$BACKUP_DIR"
    if [ ! -f "$TRAFFIC_STATE" ]; then
        cat > "$TRAFFIC_STATE" <<'JSON'
{
  "users": {},
  "connections": {}
}
JSON
        chmod 600 "$TRAFFIC_STATE"
    fi
    local tmp_script
    tmp_script="$(mktemp)"
    cat > "$tmp_script" <<'PY'
#!/usr/bin/env python3
import json
import os
import subprocess
import time
import signal
import tempfile
import select
from pathlib import Path
from datetime import datetime, timedelta
BASE_DIR = Path("/etc/sing-box")
CONF_DIR = BASE_DIR / "conf"
DATA_DIR = BASE_DIR / "user_manager"
LIMIT_DIR = DATA_DIR / "limits"
TRAFFIC_DIR = DATA_DIR / "traffic"
STATE_FILE = TRAFFIC_DIR / "state.json"
LOG_FILE = TRAFFIC_DIR / "traffic.log"
BACKUP_DIR = DATA_DIR / "backups"
LOCK_FILE = DATA_DIR / ".config.lock"
SINGBOX = BASE_DIR / "sing-box"
SERVICE = "sing-box"
GRPC_HOST = "127.0.0.1"
GRPC_PORT = 9093
GRPCURL = "/tmp/grpcurl"
CONFIG_FILE = CONF_DIR / "config.json"
SAVE_INTERVAL = 5
RECONNECT_INTERVAL = 3
running = True
def log(msg):
    try:
        TRAFFIC_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(datetime.now().astimezone().isoformat() + " " + str(msg) + "\n")
    except Exception:
        pass
def atomic_write_json(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default
def save_state(state):
    atomic_write_json(STATE_FILE, state, 0o600)
def period_window(period, now=None):
    if now is None:
        now = datetime.now().astimezone()
    if period == "day":
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        end = start + timedelta(days=1)
        return start, end
    if period == "month":
        start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        if start.month == 12:
            end = start.replace(year=start.year + 1, month=1, day=1)
        else:
            end = start.replace(month=start.month + 1, day=1)
        return start, end
    return None, None
def period_name(meta):
    if not isinstance(meta, dict):
        return "month"
    period = meta.get("period")
    if period in ("day", "daily"):
        return "day"
    if period in ("month", "monthly"):
        return "month"
    return "month"
def limit_files():
    try:
        return sorted(LIMIT_DIR.glob("*.json"))
    except Exception:
        return []
def config_files():
    try:
        return sorted(CONF_DIR.glob("*.json"))
    except Exception:
        return []
def get_limit_meta_for_user(username):
    for path in limit_files():
        data = load_json(path, {})
        if not isinstance(data, dict):
            continue
        if data.get("user") == username:
            return path, data
    return None, None
def get_user_period(username):
    _, meta = get_limit_meta_for_user(username)
    if meta:
        return period_name(meta)
    return "month"
def find_user(tag, username):
    for fn in config_files():
        try:
            with open(fn, "r", encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception:
            continue
        for inbound in cfg.get("inbounds", []):
            if inbound.get("tag") != tag:
                continue
            for user in inbound.get("users", []):
                if user.get("name") == username:
                    return fn, user
    return None, None
def backup_config(fn, reason):
    try:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f")
        target = BACKUP_DIR / f"{fn.stem}__{reason}__{stamp}.json"
        with open(fn, "rb") as src, open(target, "wb") as dst:
            dst.write(src.read())
        os.chmod(target, 0o600)
        return target
    except Exception as e:
        log(f"备份配置失败 {fn}: {e}")
        return None
def check_config():
    try:
        r = subprocess.run(
            [str(SINGBOX), "check", "-C", str(CONF_DIR)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30
        )
        if r.returncode != 0:
            log("sing-box check失败: " + r.stdout[-3000:])
            return False
        return True
    except Exception as e:
        log(f"sing-box check异常: {e}")
        return False
def reload_singbox():
    try:
        r = subprocess.run(
            ["systemctl", "reload", SERVICE],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30
        )
        if r.returncode == 0:
            return True
        r = subprocess.run(
            ["systemctl", "restart", SERVICE],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60
        )
        if r.returncode != 0:
            log("sing-box restart失败: " + r.stdout[-3000:])
            return False
        return True
    except Exception as e:
        log(f"reload/restart异常: {e}")
        return False
def acquire_lock():
    try:
        import fcntl
        LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        fp = open(LOCK_FILE, "w")
        fcntl.flock(fp.fileno(), fcntl.LOCK_EX)
        return fp
    except Exception as e:
        log(f"获取配置锁失败: {e}")
        return None
def disable_user(limit_data):
    tag = limit_data.get("inbound_tag")
    username = limit_data.get("user")
    if not tag or not username:
        return False
    lock = acquire_lock()
    if lock is None:
        return False
    try:
        fn, user = find_user(tag, username)
        if fn is None:
            saved = limit_data.get("saved_user")
            if saved:
                return True
            log(f"达到流量限制，但找不到用户: {tag}/{username}")
            return False
        cfg = load_json(fn, None)
        if not isinstance(cfg, dict):
            return False
        target = None
        for inbound in cfg.get("inbounds", []):
            if inbound.get("tag") == tag:
                target = inbound
                break
        if target is None:
            return False
        saved_user = None
        new_users = []
        for u in target.get("users", []):
            if u.get("name") == username:
                saved_user = u
            else:
                new_users.append(u)
        if saved_user is None:
            return False
        backup = backup_config(fn, "quota-disable")
        if backup is None:
            return False
        target["users"] = new_users
        atomic_write_json(fn, cfg, 0o600)
        if not check_config():
            try:
                with open(backup, "rb") as src, open(fn, "wb") as dst:
                    dst.write(src.read())
            except Exception:
                pass
            log(f"达到流量限制后配置检查失败，已恢复: {tag}/{username}")
            return False
        if not reload_singbox():
            try:
                with open(backup, "rb") as src, open(fn, "wb") as dst:
                    dst.write(src.read())
            except Exception:
                pass
            reload_singbox()
            log(f"达到流量限制后sing-box重载失败: {tag}/{username}")
            return False
        limit_data["saved_user"] = saved_user
        limit_data["config_file"] = str(fn)
        limit_data["disabled_by_limit"] = True
        log(f"用户已因流量达到限制而停用: {tag}/{username}")
        return True
    finally:
        try:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
        lock.close()
def restore_user(limit_data):
    tag = limit_data.get("inbound_tag")
    username = limit_data.get("user")
    saved_user = limit_data.get("saved_user")
    if not tag or not username or not isinstance(saved_user, dict):
        return False
    lock = acquire_lock()
    if lock is None:
        return False
    try:
        fn = None
        config_file = limit_data.get("config_file")
        if config_file and Path(config_file).exists():
            fn = Path(config_file)
        if fn is None:
            fn, _ = find_user(tag, username)
        if fn is None:
            for candidate in config_files():
                cfg = load_json(candidate, {})
                for inbound in cfg.get("inbounds", []):
                    if inbound.get("tag") == tag:
                        fn = candidate
                        break
                if fn:
                    break
        if fn is None:
            log(f"周期重置需要恢复用户，但找不到inbound: {tag}/{username}")
            return False
        cfg = load_json(fn, None)
        if not isinstance(cfg, dict):
            return False
        target = None
        for inbound in cfg.get("inbounds", []):
            if inbound.get("tag") == tag:
                target = inbound
                break
        if target is None:
            return False
        for u in target.get("users", []):
            if u.get("name") == username:
                limit_data["config_file"] = str(fn)
                return True
        backup = backup_config(fn, "quota-restore")
        if backup is None:
            return False
        target.setdefault("users", []).append(saved_user)
        atomic_write_json(fn, cfg, 0o600)
        if not check_config():
            try:
                with open(backup, "rb") as src, open(fn, "wb") as dst:
                    dst.write(src.read())
            except Exception:
                pass
            log(f"恢复用户时配置检查失败: {tag}/{username}")
            return False
        if not reload_singbox():
            try:
                with open(backup, "rb") as src, open(fn, "wb") as dst:
                    dst.write(src.read())
            except Exception:
                pass
            reload_singbox()
            log(f"恢复用户时sing-box重载失败: {tag}/{username}")
            return False
        limit_data["config_file"] = str(fn)
        log(f"用户已恢复: {tag}/{username}")
        return True
    finally:
        try:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
        lock.close()
def update_limit_file(fn, data):
    atomic_write_json(fn, data, 0o600)
def ensure_user(state, username):
    if not username:
        return None
    users = state.setdefault("users", {})
    current_period = get_user_period(username)
    if username not in users:
        start, end = period_window(current_period)
        users[username] = {
            "uplink": 0,
            "downlink": 0,
            "total": 0,
            "connections": 0,
            "period": current_period,
            "period_uplink": 0,
            "period_downlink": 0,
            "period_total": 0,
            "period_start": start.isoformat() if start else None,
            "period_end": end.isoformat() if end else None
        }
    else:
        u = users[username]
        u.setdefault("uplink", 0)
        u.setdefault("downlink", 0)
        u.setdefault("total", 0)
        u.setdefault("connections", 0)
        u.setdefault("period", current_period)
        u.setdefault("period_uplink", 0)
        u.setdefault("period_downlink", 0)
        u.setdefault("period_total", 0)
        u.setdefault("period_start", None)
        u.setdefault("period_end", None)
    return users[username]
def add_traffic(state, username, uplink=0, downlink=0):
    if not username:
        return
    uplink = max(0, int(uplink or 0))
    downlink = max(0, int(downlink or 0))
    if uplink == 0 and downlink == 0:
        return
    u = ensure_user(state, username)
    u["uplink"] = int(u.get("uplink", 0)) + uplink
    u["downlink"] = int(u.get("downlink", 0)) + downlink
    u["total"] = int(u.get("uplink", 0)) + int(u.get("downlink", 0))
    u["period_uplink"] = int(u.get("period_uplink", 0)) + uplink
    u["period_downlink"] = int(u.get("period_downlink", 0)) + downlink
    u["period_total"] = int(u.get("period_uplink", 0)) + int(u.get("period_downlink", 0))
def process_new(state, event):
    connection = event.get("connection") or {}
    conn_id = event.get("id") or connection.get("id")
    if not conn_id:
        return False
    conn_id = str(conn_id)
    user = connection.get("user")
    if not user:
        return False
    connections = state.setdefault("connections", {})
    if conn_id in connections:
        return False
    uplink_total = int(connection.get("uplinkTotal") or 0)
    downlink_total = int(connection.get("downlinkTotal") or 0)
    connections[conn_id] = {
        "user": user,
        "uplink_total": uplink_total,
        "downlink_total": downlink_total,
        "created_at": connection.get("createdAt", "")
    }
    stats = ensure_user(state, user)
    stats["connections"] = int(stats.get("connections", 0)) + 1
    if uplink_total or downlink_total:
        add_traffic(state, user, uplink_total, downlink_total)
    return True
def process_update(state, event):
    conn_id = event.get("id")
    if not conn_id:
        return False
    conn_id = str(conn_id)
    connections = state.setdefault("connections", {})
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
        stats["connections"] = int(stats.get("connections", 0)) + 1
        initial_uplink = int(connection.get("uplinkTotal") or 0)
        initial_downlink = int(connection.get("downlinkTotal") or 0)
        if initial_uplink or initial_downlink:
            add_traffic(state, user, initial_uplink, initial_downlink)
        conn["uplink_total"] = initial_uplink
        conn["downlink_total"] = initial_downlink
    user = conn["user"]
    uplink_delta = int(event.get("uplinkDelta") or 0)
    downlink_delta = int(event.get("downlinkDelta") or 0)
    if uplink_delta or downlink_delta:
        add_traffic(state, user, uplink_delta, downlink_delta)
        conn["uplink_total"] += max(0, uplink_delta)
        conn["downlink_total"] += max(0, downlink_delta)
    final_uplink = connection.get("uplinkTotal")
    final_downlink = connection.get("downlinkTotal")
    if final_uplink is not None:
        final_uplink = int(final_uplink)
        if final_uplink > conn["uplink_total"]:
            delta = final_uplink - conn["uplink_total"]
            add_traffic(state, user, uplink=delta)
            conn["uplink_total"] = final_uplink
    if final_downlink is not None:
        final_downlink = int(final_downlink)
        if final_downlink > conn["downlink_total"]:
            delta = final_downlink - conn["downlink_total"]
            add_traffic(state, user, downlink=delta)
            conn["downlink_total"] = final_downlink
    return bool(uplink_delta or downlink_delta or connection)
def process_closed(state, event):
    conn_id = event.get("id")
    if not conn_id:
        return False
    conn_id = str(conn_id)
    connections = state.setdefault("connections", {})
    conn = connections.get(conn_id)
    if conn is None:
        return False
    connection = event.get("connection") or {}
    user = conn["user"]
    final_uplink = int(connection.get("uplinkTotal") or conn["uplink_total"])
    final_downlink = int(connection.get("downlinkTotal") or conn["downlink_total"])
    extra_uplink = max(0, final_uplink - conn["uplink_total"])
    extra_downlink = max(0, final_downlink - conn["downlink_total"])
    if extra_uplink or extra_downlink:
        add_traffic(state, user, extra_uplink, extra_downlink)
    stats = ensure_user(state, user)
    if int(stats.get("connections", 0)) > 0:
        stats["connections"] -= 1
    del connections[conn_id]
    return True
def process_event(state, event):
    if not isinstance(event, dict):
        return False
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
def sync_periods(state):
    changed = False
    now = datetime.now().astimezone()
    users = state.setdefault("users", {})
    for username, u in users.items():
        current_period = get_user_period(username)
        if current_period not in ("day", "month"):
            current_period = "month"
        start, end = period_window(current_period, now)
        start_iso = start.isoformat()
        end_iso = end.isoformat()
        stored_period = u.get("period")
        stored_start = u.get("period_start")
        stored_end = u.get("period_end")
        if stored_period != current_period:
            u["period"] = current_period
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            changed = True
            continue
        if not stored_start or not stored_end:
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            changed = True
            continue
        try:
            stored_end_dt = datetime.fromisoformat(stored_end)
        except Exception:
            stored_end_dt = None
        if stored_end_dt is None or now >= stored_end_dt:
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            changed = True
    for lf in limit_files():
        data = load_json(lf, {})
        if not isinstance(data, dict):
            continue
        username = data.get("user")
        if not username:
            continue
        period = period_name(data)
        start, end = period_window(period, now)
        start_iso = start.isoformat()
        end_iso = end.isoformat()
        if data.get("period_start") != start_iso:
            if data.get("disabled_by_limit"):
                if not restore_user(data):
                    log(f"周期已到但恢复用户失败: {data.get('inbound_tag')}/{username}")
                    continue
            data["period_start"] = start_iso
            data["period_end"] = end_iso
            data["disabled_by_limit"] = False
            update_limit_file(lf, data)
            changed = True
    return changed
def check_limits(state):
    for lf in limit_files():
        data = load_json(lf, {})
        if not isinstance(data, dict):
            continue
        username = data.get("user")
        if not username:
            continue
        if not data.get("enabled"):
            if data.get("disabled_by_limit"):
                if restore_user(data):
                    data["disabled_by_limit"] = False
                    update_limit_file(lf, data)
            continue
        try:
            limit_bytes = int(data.get("limit_bytes", 0) or 0)
        except Exception:
            limit_bytes = 0
        if limit_bytes <= 0:
            continue
        u = state.get("users", {}).get(username, {})
        period = period_name(data)
        if period in ("day", "month"):
            used = int(u.get("period_total", 0) or 0)
        else:
            used = int(u.get("total", 0) or 0)
        if data.get("disabled_by_limit"):
            continue
        if used >= limit_bytes:
            if disable_user(data):
                update_limit_file(lf, data)
def update_connection_count(state):
    counts = {}
    for conn in state.get("connections", {}).values():
        user = conn.get("user")
        if user:
            counts[user] = counts.get(user, 0) + 1
    for username, data in state.setdefault("users", {}).items():
        data["connections"] = counts.get(username, 0)
def initialize_periods(state):
    changed = False
    now = datetime.now().astimezone()
    users = state.setdefault("users", {})
    for username, u in users.items():
        period = get_user_period(username)
        if period not in ("day", "month"):
            period = "month"
        start, end = period_window(period, now)
        start_iso = start.isoformat()
        end_iso = end.isoformat()
        if u.get("period") != period:
            u["period"] = period
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            changed = True
            continue
        if not u.get("period_start") or not u.get("period_end"):
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            changed = True
            continue
        try:
            stored_end = datetime.fromisoformat(u["period_end"])
        except Exception:
            stored_end = None
        if stored_end is None or now >= stored_end:
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            changed = True
    for lf in limit_files():
        data = load_json(lf, {})
        if not isinstance(data, dict):
            continue
        username = data.get("user")
        if not username:
            continue
        period = period_name(data)
        start, end = period_window(period, now)
        start_iso = start.isoformat()
        end_iso = end.isoformat()
        if data.get("period_start") != start_iso:
            data["period_start"] = start_iso
            data["period_end"] = end_iso
            update_limit_file(lf, data)
    return changed
def get_api_secret():
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        for service in cfg.get("services", []):
            if not isinstance(service, dict):
                continue
            if service.get("type") != "api":
                continue
            if int(service.get("listen_port", 0) or 0) != GRPC_PORT:
                continue
            secret = service.get("secret")
            if secret:
                return str(secret)
        log(f"config.json中找不到API服务 secret: {CONFIG_FILE}")
    except Exception as e:
        log(f"读取API secret失败: {e}")
    return None
def grpc_stream():
    if not os.path.exists(GRPCURL):
        log(f"找不到grpcurl: {GRPCURL}")
        time.sleep(RECONNECT_INTERVAL)
        return
    api_secret = get_api_secret()
    if not api_secret:
        log("无法获取API secret")
        time.sleep(RECONNECT_INTERVAL)
        return
    url = f"{GRPC_HOST}:{GRPC_PORT}"
    cmd = [
        GRPCURL,
        "-plaintext",
        "-H",
        f"Authorization: Bearer {api_secret}",
        "-d",
        '{"interval":1000}',
        url,
        "daemon.StartedService/SubscribeConnections"
    ]
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0
        )
    except Exception as e:
        log(f"启动grpcurl失败: {e}")
        time.sleep(RECONNECT_INTERVAL)
        return
    try:
        decoder = json.JSONDecoder()
        buffer = ""
        fd = proc.stdout.fileno()
        while running:
            try:
                ready, _, _ = select.select([fd], [], [], 1)
            except Exception:
                ready = [fd]
            if not ready:
                if proc.poll() is not None:
                    break
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            buffer += chunk.decode("utf-8", errors="replace")
            while True:
                buffer = buffer.lstrip()
                if not buffer:
                    break
                try:
                    response, index = decoder.raw_decode(buffer)
                except json.JSONDecodeError:
                    break
                buffer = buffer[index:]
                if not isinstance(response, dict):
                    continue
                events = response.get("events")
                if not isinstance(events, list):
                    continue
                for event in events:
                    if isinstance(event, dict):
                        yield event
        try:
            err = proc.stderr.read()
            if err:
                err_text = err.decode("utf-8", errors="replace")
                if err_text.strip():
                    log("grpcurl stderr: " + err_text[-3000:])
        except Exception:
            pass
    finally:
        try:
            proc.terminate()
        except Exception:
            pass
        try:
            proc.wait(timeout=3)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
def signal_handler(signum, frame):
    global running
    running = False
signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)
def main():
    TRAFFIC_DIR.mkdir(parents=True, exist_ok=True)
    LIMIT_DIR.mkdir(parents=True, exist_ok=True)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    state = load_json(STATE_FILE, {"users": {}, "connections": {}})
    if not isinstance(state, dict):
        state = {"users": {}, "connections": {}}
    state.setdefault("users", {})
    state.setdefault("connections", {})
    initialize_periods(state)
    update_connection_count(state)
    save_state(state)
    log("singbox traffic collector started")
    last_save = time.monotonic()
    while running:
        try:
            sync_periods(state)
            check_limits(state)
            update_connection_count(state)
            save_state(state)
            last_save = time.monotonic()
            for event in grpc_stream():
                if not running:
                    break
                process_event(state, event)
                update_connection_count(state)
                now = time.monotonic()
                if now - last_save >= SAVE_INTERVAL:
                    sync_periods(state)
                    check_limits(state)
                    update_connection_count(state)
                    save_state(state)
                    last_save = now
            if running:
                sync_periods(state)
                check_limits(state)
                update_connection_count(state)
                save_state(state)
                time.sleep(RECONNECT_INTERVAL)
        except Exception as e:
            log(f"collector异常: {type(e).__name__}: {e}")
            try:
                save_state(state)
            except Exception:
                pass
            time.sleep(RECONNECT_INTERVAL)
    try:
        update_connection_count(state)
        save_state(state)
    except Exception:
        pass
    log("singbox traffic collector stopped")
if __name__ == "__main__":
    main()
PY
    chmod 700 "$tmp_script"
    if [ ! -f "$TRAFFIC_SCRIPT" ] || ! cmp -s "$tmp_script" "$TRAFFIC_SCRIPT"; then
        install -m 700 "$tmp_script" "$TRAFFIC_SCRIPT"
        TRAFFIC_SCRIPT_CHANGED=1
    fi
    rm -f "$tmp_script"
}

init_traffic_service() {
    local service_file="/etc/systemd/system/$TRAFFIC_SERVICE"
    local tmp_service
    tmp_service="$(mktemp)"
    cat > "$tmp_service" <<EOF
[Unit]
Description=sing-box Traffic Collector
After=network-online.target sing-box.service
Wants=network-online.target
Requires=sing-box.service
[Service]
Type=simple
ExecStart=$PYTHON $TRAFFIC_SCRIPT
Restart=always
RestartSec=3
User=root
Group=root
UMask=0077
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
    local service_changed=0
    if [ ! -f "$service_file" ] || ! cmp -s "$tmp_service" "$service_file"; then
        install -m 644 "$tmp_service" "$service_file"
        service_changed=1
    fi
    rm -f "$tmp_service"
    if [ "$service_changed" -eq 1 ]; then
        systemctl daemon-reload
    fi
    systemctl enable "$TRAFFIC_SERVICE" >/dev/null 2>&1
    if [ "$TRAFFIC_SCRIPT_CHANGED" -eq 1 ] || [ "$service_changed" -eq 1 ]; then
        systemctl restart "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    elif ! systemctl is-active --quiet "$TRAFFIC_SERVICE"; then
        systemctl start "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    fi
}

mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$LIMIT_DIR"

if [ -z "$PYTHON" ]; then
    red "错误：系统没有 python3"
    exit 1
fi

if [ ! -x "$SINGBOX" ]; then
    red "错误：未找到 $SINGBOX"
    exit 1
fi

if [ ! -d "$CONF_DIR" ]; then
    red "错误：未找到 $CONF_DIR"
    exit 1
fi

init_traffic
init_traffic_service

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
stop_traffic_service() {
    echo "正在停止流量统计服务..."
    systemctl stop "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    echo "流量统计服务已停止"
    pause
}
reset_traffic_script() {
    clear
    echo "========================================"
    echo "        重置流量统计脚本"
    echo "========================================"
    echo
    echo "此操作将删除流量统计模块创建的全部文件："
    echo
    echo "  $TRAFFIC_DIR"
    echo "  $LIMIT_DIR"
    echo "  $BACKUP_DIR"
    echo "  $TRAFFIC_SCRIPT"
    echo "  /etc/systemd/system/$TRAFFIC_SERVICE"
    echo
    echo "不会删除 sing-box 配置文件。"
    echo "不会删除 /etc/sing-box/conf/ 下的配置。"
    echo "不会删除 sing-box 程序。"
    echo
    read -r -p "确认重置并重新安装？输入 YES 确认: " confirm
    if [ "$confirm" != "YES" ]; then
        echo "已取消"
        pause
        return
    fi
    echo
    echo "正在停止流量统计服务..."
    systemctl stop "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    echo "正在删除流量统计模块..."
    rm -rf "$TRAFFIC_DIR"
    rm -rf "$LIMIT_DIR"
    rm -rf "$BACKUP_DIR"
    rm -f "$TRAFFIC_SCRIPT"
    rm -f "/etc/systemd/system/$TRAFFIC_SERVICE"
    systemctl daemon-reload
    rm -f "$CONFIG_LOCK"
    echo "正在重新创建流量统计模块..."
    init_traffic
    init_traffic_service
    echo
    if systemctl is-active --quiet "$TRAFFIC_SERVICE"; then
        echo "========================================"
        echo "重置并重新安装完成"
        echo "流量统计服务：运行中"
        echo "========================================"
    else
        echo "========================================"
        echo "重置完成，但流量统计服务启动失败"
        echo "========================================"
        echo
        systemctl status "$TRAFFIC_SERVICE" --no-pager -l 2>/dev/null || true
    fi
    pause
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
            "$PYTHON" - "$CONF_DIR/$file" "$tag" "$LIMIT_DIR" <<'PY'
import sys
import json
from pathlib import Path

fn = sys.argv[1]
tag = sys.argv[2]
limit_dir = Path(sys.argv[3])
result = []
normal_users = set()

try:
    with open(fn, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        for u in inbound.get("users", []):
            name = u.get("name", "")
            if name:
                result.append(("normal", name))
                normal_users.add(name)
        break

if limit_dir.exists():
    prefix = tag + "__"
    for lf in sorted(limit_dir.glob(prefix + "*.json")):
        try:
            with open(lf, "r", encoding="utf-8") as f:
                d = json.load(f)
        except Exception:
            continue
        if d.get("inbound_tag") != tag:
            continue
        if not d.get("disabled_by_limit"):
            continue
        name = d.get("user", "")
        if not name or name in normal_users:
            continue
        saved = d.get("saved_user")
        if not isinstance(saved, dict):
            continue
        if saved.get("name") != name:
            continue
        result.append(("limited", name))

for status, name in result:
    print(f"{status}\t{name}")
PY
        )
        local i=1
        for entry in "${USERS[@]}"; do
            [ -z "$entry" ] && continue
            local status="${entry%%$'\t'*}"
            local user="${entry#*$'\t'}"
            if [ "$status" = "limited" ]; then
                printf "  ${red}%2d) %-32s 流量已限制${re}\n" "$i" "$user"
            else
                printf "  ${green}%2d)${re} %-32s\n" "$i" "$user"
            fi
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
            local selected="${USERS[$index]}"
            local selected_user="${selected#*$'\t'}"
            user_menu "$file" "$tag" "$type" "$port" "$selected_user"
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
    if ! "$PYTHON" - "$full" "$tag" "$type" "$name" "$value" "$uuid" "$password" "$username" <<'PY'
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
    then
        red "用户写入配置失败，正在恢复..."
        restore_file "$full" "$backup"
        pause
        return
    fi
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
    "$PYTHON" - "$CONF_DIR/$file" "$tag" "$user" "$LIMIT_DIR" <<'PY'
import sys
import json
from pathlib import Path

fn, tag, name, limit_dir = sys.argv[1:]
try:
    with open(fn, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}

for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        for u in inbound.get("users", []):
            if u.get("name") == name:
                print(json.dumps(u, ensure_ascii=False))
                raise SystemExit

lf = Path(limit_dir) / f"{tag}__{name}.json"
if lf.exists():
    try:
        with open(lf, "r", encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        d = {}
    if d.get("disabled_by_limit"):
        saved = d.get("saved_user")
        if isinstance(saved, dict) and saved.get("name") == name:
            print(json.dumps(saved, ensure_ascii=False))
            raise SystemExit
PY
}
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
        echo "0 0 0 0 0 0 0"
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
except Exception:
    print("0 0 0 0 0 0 0")
    raise SystemExit
d = data.get("users", {}).get(user, {})
uplink = int(d.get("uplink", 0) or 0)
downlink = int(d.get("downlink", 0) or 0)
total = int(d.get("total", uplink + downlink) or 0)
connections = int(d.get("connections", 0) or 0)
period_uplink = int(d.get("period_uplink", 0) or 0)
period_downlink = int(d.get("period_downlink", 0) or 0)
period_total = int(d.get("period_total", period_uplink + period_downlink) or 0)
print(uplink, downlink, total, connections, period_uplink, period_downlink, period_total)
PY
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
    local period_uplink
    local period_downlink
    local period_total
    read -r uplink downlink total connections period_uplink period_downlink period_total <<< "$traffic"
    echo -e "上传 $(format_bytes "$uplink")"
    echo -e "下载 $(format_bytes "$downlink")"
    echo -e "总计 $(format_bytes "$total")"
    echo -e "本周期 $(format_bytes "$period_total")"
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
    "$PYTHON" - "$lf" "$TRAFFIC_STATE" <<'PY'
import sys
import json
from datetime import datetime
lf = sys.argv[1]
state_file = sys.argv[2]
try:
    with open(lf, "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print("未设置")
    raise SystemExit
if not d.get("enabled"):
    print("已关闭")
    raise SystemExit
value = d.get("limit_value")
unit = d.get("limit_unit")
if value is not None and unit:
    try:
        fv = float(value)
        limit_text = f"{int(fv)} {unit}" if fv.is_integer() else f"{value} {unit}"
    except Exception:
        limit_text = f"{value} {unit}"
else:
    limit_text = "未知"
period = d.get("period", "none")
period_text = {
    "day": "每天",
    "month": "每月",
    "none": "永久"
}.get(period, "永久")
user = d.get("user")
try:
    with open(state_file, "r", encoding="utf-8") as f:
        state = json.load(f)
except Exception:
    state = {}
u = state.get("users", {}).get(user, {})
if period in ("day", "month"):
    used = int(u.get("period_total", 0) or 0)
else:
    used = int(u.get("total", 0) or 0)
limit_bytes = int(d.get("limit_bytes", 0) or 0)
def fmt(n):
    n = float(n)
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    i = 0
    while n >= 1024 and i < len(units)-1:
        n /= 1024
        i += 1
    if i == 0:
        return f"{int(n)} {units[i]}"
    return f"{n:.2f} {units[i]}"
print(f"已设置：{limit_text}")
print(f"时间周期：{period_text}")
print(f"本周期使用：{fmt(used)} / {fmt(limit_bytes)}")
if limit_bytes > used:
    print(f"剩余流量：{fmt(limit_bytes-used)}")
else:
    print("剩余流量：0 B")
if period in ("day", "month") and d.get("period_end"):
    try:
        dt = datetime.fromisoformat(d["period_end"])
        print(f"下次重置：{dt.astimezone().strftime('%Y-%m-%d %H:%M:%S')}")
    except Exception:
        pass
if d.get("disabled_by_limit"):
    print("状态：已达到流量限制，用户已停用")
else:
    print("状态：正常")
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
    echo -e "${skyblue}支持:${re}"
    echo -e "  2       = 2GB"
    echo -e "  100MB   = 100MB"
    echo -e "  1GB     = 1GB"
    echo -e "  0       = 关闭流量限制"
    echo
    local input
    read -rp "$(green "请输入流量限制: ")" input
    input="$(echo "$input" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
    if [ "$input" = "0" ]; then
        disable_limit "$tag" "$user"
        return
    fi
    local number
    local unit
    if [[ "$input" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        number="$input"
        unit="GB"
    elif [[ "$input" =~ ^[0-9]+([.][0-9]+)?MB$ ]]; then
        number="${input%MB}"
        unit="MB"
    elif [[ "$input" =~ ^[0-9]+([.][0-9]+)?GB$ ]]; then
        number="${input%GB}"
        unit="GB"
    else
        red "格式错误"
        echo "例如：2、100MB、1GB、500MB"
        pause
        return
    fi
    if ! "$PYTHON" - "$number" "$unit" "$lf" "$tag" "$user" <<'PY'
import sys
import json
import os
number = float(sys.argv[1])
unit = sys.argv[2]
fn = sys.argv[3]
tag = sys.argv[4]
user = sys.argv[5]
if number <= 0:
    raise SystemExit("限制必须大于 0")
if unit == "GB":
    limit_bytes = int(number * 1024 * 1024 * 1024)
else:
    limit_bytes = int(number * 1024 * 1024)
old = {}
if os.path.exists(fn):
    try:
        with open(fn, "r", encoding="utf-8") as f:
            old = json.load(f)
    except Exception:
        pass
data = {
    "inbound_tag": tag,
    "user": user,
    "limit_value": number,
    "limit_unit": unit,
    "limit_bytes": limit_bytes,
    "period": old.get("period", "none"),
    "period_start": old.get("period_start"),
    "period_end": old.get("period_end"),
    "enabled": True,
    "disabled_by_limit": old.get("disabled_by_limit", False),
    "saved_user": old.get("saved_user"),
    "config_file": old.get("config_file")
}
with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(fn, 0o600)
PY
    then
        red "流量限制保存失败"
        pause
        return
    fi
    green "流量限制已设置：${number}${unit}"
    echo
    echo "当前时间周期："
    case "$( "$PYTHON" - "$lf" <<'PY'
import sys,json
try:
    with open(sys.argv[1],encoding="utf-8") as f:
        print(json.load(f).get("period","none"))
except:
    print("none")
PY
)" in
        day) echo "每天重置" ;;
        month) echo "每月重置" ;;
        *) echo "不重置" ;;
    esac
    pause
}

disable_limit() {
    local tag="$1"
    local user="$2"
    local lf
    lf="$(get_limit_file "$tag" "$user")"

    if [ ! -f "$lf" ]; then
        yellow "当前没有设置流量限制"
        pause
        return
    fi

    "$PYTHON" - "$lf" <<'PY'
import sys
import json
import os

fn = sys.argv[1]

try:
    with open(fn, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}

data["enabled"] = False
data["limit_value"] = 0
data["limit_unit"] = "GB"
data["limit_bytes"] = 0

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

os.chmod(fn, 0o600)
PY

    if [ $? -ne 0 ]; then
        red "流量限制解除失败"
        pause
        return
    fi

    green "流量限制已解除"

    if "$PYTHON" - "$lf" <<'PY'
import sys
import json

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    raise SystemExit(0 if d.get("disabled_by_limit") else 1)
except Exception:
    raise SystemExit(1)
PY
    then
        echo "用户将在流量服务下一轮检查时自动恢复。"
    else
        echo "用户当前未因流量限制停用。"
    fi

    pause
}

set_limit_period() {
    local tag="$1"
    local user="$2"
    local lf
    lf="$(get_limit_file "$tag" "$user")"

    title "设置时间周期"

    if [ ! -f "$lf" ]; then
        red "请先设置流量限制"
        pause
        return
    fi

    echo "1) 每天重置"
    echo "2) 每月重置"
    echo "3) 不重置"
    echo "0) 返回"
    echo

    local choice
    read -rp "$(green "请选择: ")" choice

    local period=""

    case "$choice" in
        1) period="day" ;;
        2) period="month" ;;
        3) period="none" ;;
        0) return ;;
        *) red "无效选择"; pause; return ;;
    esac

    local result

    result="$("$PYTHON" - "$lf" "$period" "$TRAFFIC_STATE" "$CONF_DIR" <<'PY'
import sys
import json
import os
from pathlib import Path
from datetime import datetime, timedelta

fn = sys.argv[1]
period = sys.argv[2]
state_file = sys.argv[3]
conf_dir = Path(sys.argv[4])

try:
    with open(fn, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}

user = data.get("user")
tag = data.get("inbound_tag")
saved_user = data.get("saved_user")
config_file = data.get("config_file")

now = datetime.now().astimezone()

if period == "day":
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=1)
elif period == "month":
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if start.month == 12:
        end = start.replace(year=start.year + 1, month=1, day=1)
    else:
        end = start.replace(month=start.month + 1, day=1)
else:
    start = None
    end = None

start_iso = start.isoformat() if start else None
end_iso = end.isoformat() if end else None

actual_exists = False
actual_file = None

candidates = []

if config_file:
    p = Path(config_file)
    if p.exists():
        candidates.append(p)

if not candidates:
    try:
        candidates = list(conf_dir.glob("*.json"))
    except Exception:
        candidates = []

for candidate in candidates:
    try:
        with open(candidate, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        continue

    for inbound in cfg.get("inbounds", []):
        if inbound.get("tag") != tag:
            continue

        for u in inbound.get("users", []):
            if u.get("name") == user:
                actual_exists = True
                actual_file = candidate
                break

        if actual_exists:
            break

    if actual_exists:
        break

restored = False

if not actual_exists and isinstance(saved_user, dict) and tag and user:
    restore_file = actual_file

    if restore_file is None and config_file:
        p = Path(config_file)
        if p.exists():
            restore_file = p

    if restore_file is None:
        for candidate in candidates:
            try:
                with open(candidate, "r", encoding="utf-8") as f:
                    cfg = json.load(f)
            except Exception:
                continue

            for inbound in cfg.get("inbounds", []):
                if inbound.get("tag") == tag:
                    restore_file = candidate
                    break

            if restore_file:
                break

    if restore_file is not None:
        try:
            with open(restore_file, "r", encoding="utf-8") as f:
                cfg = json.load(f)

            target = None

            for inbound in cfg.get("inbounds", []):
                if inbound.get("tag") == tag:
                    target = inbound
                    break

            if target is not None:
                exists = False

                for u in target.get("users", []):
                    if u.get("name") == user:
                        exists = True
                        break

                if not exists:
                    target.setdefault("users", []).append(saved_user)

                    with open(restore_file, "w", encoding="utf-8") as f:
                        json.dump(cfg, f, ensure_ascii=False, indent=2)
                        f.write("\n")

                    os.chmod(restore_file, 0o600)

                    data["config_file"] = str(restore_file)
                    restored = True

        except Exception as e:
            print(f"恢复用户失败: {e}", file=sys.stderr)
            raise SystemExit(1)

data["period"] = period
data["period_start"] = start_iso
data["period_end"] = end_iso
data["enabled"] = True

if restored:
    data["disabled_by_limit"] = False
    data.pop("saved_user", None)

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

os.chmod(fn, 0o600)

if user:
    try:
        with open(state_file, "r", encoding="utf-8") as f:
            state = json.load(f)
    except Exception:
        state = {"users": {}, "connections": {}}

    users = state.setdefault("users", {})
    u = users.setdefault(user, {})

    u["period"] = period
    u["period_uplink"] = 0
    u["period_downlink"] = 0
    u["period_total"] = 0
    u["period_start"] = start_iso
    u["period_end"] = end_iso

    tmp = state_file + ".tmp"

    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
        f.write("\n")

    os.chmod(tmp, 0o600)
    os.replace(tmp, state_file)

print("RESTORED" if restored else "NORMAL")
PY
)"

    if [ $? -ne 0 ]; then
        red "时间周期设置失败"
        pause
        return
    fi

    if [ "$result" = "RESTORED" ]; then
        if ! check_config; then
            red "用户恢复后配置检查失败"
            pause
            return
        fi

        if ! reload_singbox; then
            red "用户恢复后 sing-box 重载失败"
            pause
            return
        fi

        green "用户已恢复，时间周期同时重新设置"
    fi

    case "$period" in
        day)
            green "时间周期已设置：每天重置"
            ;;
        month)
            green "时间周期已设置：每月重置"
            ;;
        none)
            green "时间周期已设置：不重置"
            ;;
    esac

    echo
    echo "本次设置会从当前时间重新计算本周期流量。"

    pause
}
modify_auth() {
    local file="$1"
    local tag="$2"
    local type="$3"
    local user="$4"

    local lf
    lf="$(get_limit_file "$tag" "$user")"

    local user_json
    user_json="$(get_user_json "$file" "$tag" "$user" 2>/dev/null)"

    if [ -z "$user_json" ]; then
        red "找不到用户: $user"
        pause
        return
    fi

    local limited=0

    if [ -f "$lf" ]; then
        limited="$("$PYTHON" - "$lf" <<'PY'
import sys
import json

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    print(1 if d.get("disabled_by_limit") else 0)
except Exception:
    print(0)
PY
)"
    fi

    case "$type" in
        vmess|vless|tuic)
            local old_uuid
            old_uuid="$("$PYTHON" - "$user_json" <<'PY'
import sys
import json
d = json.loads(sys.argv[1])
print(d.get("uuid", ""))
PY
)"

            echo -e "${skyblue}当前 UUID:${re} $old_uuid"
            read -rp "输入新的 UUID（直接回车保持不变）: " new_uuid

            [ -z "$new_uuid" ] && new_uuid="$old_uuid"

            if [ "$limited" = "1" ]; then
                "$PYTHON" - "$lf" "$new_uuid" <<'PY'
import sys
import json
import os

fn = sys.argv[1]
new_uuid = sys.argv[2]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

saved = data.get("saved_user")

if not isinstance(saved, dict):
    raise SystemExit("saved_user 不存在")

saved["uuid"] = new_uuid
data["saved_user"] = saved

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

os.chmod(fn, 0o600)
PY

                if [ $? -eq 0 ]; then
                    green "UUID 修改成功"
                else
                    red "UUID 修改失败"
                fi

                pause
                return
            fi

            "$PYTHON" - "$CONF_DIR/$file" "$tag" "$user" "$new_uuid" <<'PY'
import sys
import json

fn, tag, name, new_uuid = sys.argv[1:]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

found = False

for inbound in data.get("inbounds", []):
    if inbound.get("tag") != tag:
        continue

    for u in inbound.get("users", []):
        if u.get("name") == name:
            u["uuid"] = new_uuid
            found = True
            break

if not found:
    raise SystemExit(1)

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

            if [ $? -ne 0 ]; then
                red "UUID 修改失败"
                pause
                return
            fi
            ;;

        *)
            local old_password
            old_password="$("$PYTHON" - "$user_json" <<'PY'
import sys
import json
d = json.loads(sys.argv[1])
print(d.get("password", ""))
PY
)"

            echo -e "${skyblue}当前密码:${re} $old_password"
            read -rp "输入新的密码（直接回车保持不变）: " new_password

            [ -z "$new_password" ] && new_password="$old_password"

            if [ "$limited" = "1" ]; then
                "$PYTHON" - "$lf" "$new_password" <<'PY'
import sys
import json
import os

fn = sys.argv[1]
new_password = sys.argv[2]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

saved = data.get("saved_user")

if not isinstance(saved, dict):
    raise SystemExit("saved_user 不存在")

saved["password"] = new_password
data["saved_user"] = saved

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

os.chmod(fn, 0o600)
PY

                if [ $? -eq 0 ]; then
                    green "密码修改成功"
                else
                    red "密码修改失败"
                fi

                pause
                return
            fi

            "$PYTHON" - "$CONF_DIR/$file" "$tag" "$user" "$new_password" <<'PY'
import sys
import json

fn, tag, name, new_password = sys.argv[1:]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

found = False

for inbound in data.get("inbounds", []):
    if inbound.get("tag") != tag:
        continue

    for u in inbound.get("users", []):
        if u.get("name") == name:
            u["password"] = new_password
            found = True
            break

if not found:
    raise SystemExit(1)

with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

            if [ $? -ne 0 ]; then
                red "密码修改失败"
                pause
                return
            fi
            ;;
    esac

    if [ "$limited" = "1" ]; then
        green "修改成功"
        pause
        return
    fi

    if ! check_config; then
        red "sing-box 配置检查失败"
        pause
        return
    fi

    if ! reload_singbox; then
        red "sing-box 重载失败"
        pause
        return
    fi

    green "修改成功"
    pause
}

delete_user() {
    local file="$1"
    local tag="$2"
    local user="$3"
    local full="$CONF_DIR/$file"
    local lf
    lf="$(get_limit_file "$tag" "$user")"

    title "删除用户"
    echo -e "${yellow}节点:${re} $tag"
    echo -e "${yellow}用户:${re} $user"
    echo

    red "删除后该用户将立即失效。"
    read -rp "$(yellow "确认删除？[y/N]: ")" confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    # 先判断用户是否还存在于实际 sing-box 配置
    local actual_exists
    actual_exists="$("$PYTHON" - "$full" "$tag" "$user" <<'PY'
import sys
import json

fn, tag, name = sys.argv[1:]

try:
    with open(fn, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print(0)
    raise SystemExit

for inbound in data.get("inbounds", []):
    if inbound.get("tag") != tag:
        continue

    for u in inbound.get("users", []):
        if u.get("name") == name:
            print(1)
            raise SystemExit

print(0)
PY
)"

    # 实际配置不存在，再检查是否存在被限额保存的用户
    if [ "$actual_exists" != "1" ]; then
        local saved_exists=0

        if [ -f "$lf" ]; then
            saved_exists="$("$PYTHON" - "$lf" <<'PY'
import sys
import json

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)

    saved = data.get("saved_user")

    if isinstance(saved, dict) and saved.get("name"):
        print(1)
    else:
        print(0)
except Exception:
    print(0)
PY
)"
        fi

        if [ "$saved_exists" = "1" ]; then
            rm -f "$lf"

            if [ -f "$lf" ]; then
                red "删除限额记录失败"
                pause
                return
            fi

            green "用户删除成功"
            pause
            return
        fi

        red "用户不存在"
        pause
        return
    fi

    # 正常用户删除
    backup_file "$full"

    local backup
    backup="$(find_backup "$full")"

    if ! "$PYTHON" - "$full" "$tag" "$user" <<'PY'
import sys
import json

fn, tag, name = sys.argv[1:]

with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)

found = False

for inbound in data.get("inbounds", []):
    if inbound.get("tag") != tag:
        continue

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
    then
        red "删除失败，正在恢复..."
        restore_file "$full" "$backup"
        pause
        return
    fi

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

    # 正常用户如果有历史限额记录，一并删除
    rm -f "$lf"

    if [ -f "$lf" ]; then
        red "用户已经从 sing-box 删除，但流量限制记录删除失败"
        pause
        return
    fi

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
    local period_uplink
    local period_downlink
    local period_total
    read -r uplink downlink total connections period_uplink period_downlink period_total <<< "$traffic"
    echo "  上传:   $(format_bytes "$uplink")"
    echo "  下载:   $(format_bytes "$downlink")"
    echo "  总流量: $(format_bytes "$total")"
    echo "  本周期: $(format_bytes "$period_total")"
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
                modify_auth "$file" "$tag" "$type" "$user"
                ;;
            2)
    while true; do
        title "流量限制"
        show_limit "$tag" "$user"
        echo
        echo "1) 设置流量"
        echo "2) 设置时间"
        echo "3) 查看限制状态"
        echo "4) 关闭流量限制"
        echo "0) 返回"
        echo
        read -rp "$(green "请选择: ")" limit_choice
        case "$limit_choice" in
            1)
                set_limit "$tag" "$user"
                ;;
            2)
                set_limit_period "$tag" "$user"
                ;;
            3)
                show_limit "$tag" "$user"
                pause
                ;;
            4)
                disable_limit "$tag" "$user"
                ;;
            0)
                break
                ;;
            *)
                red "无效选择"
                pause
                ;;
        esac
    done
    ;;
            3)
    show_user_traffic_inline "$user"
    pause
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
        echo -e "  ${cyan}a)${re} 停止流量统计"
        echo -e "  ${cyan}b)${re} 重置流量统计脚本"
        echo
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
        case "$choice" in
            a|A)
                systemctl stop "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
                green "流量统计服务已停止"
                pause
                continue
                ;;
            b|B)
                reset_traffic_script
                continue
                ;;
            0)
                clear
                exit 0
                ;;
        esac
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
