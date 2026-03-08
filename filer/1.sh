#!/usr/bin/env bash
# suoha_fixed.sh
# 安全修复版：去除广告，修复架构/发行版识别，避免危险操作，稳健解析 argo 输出

set -o errexit
set -o pipefail
set -o nounset

# ---------- 配置 ----------
TMPDIR="/tmp/suoha_tmp_$$"
LOGFILE="${TMPDIR}/suoha.log"
ARGO_LOG="${TMPDIR}/argo.log"
CLEANUP_FILES=()
RETRY_LIMIT=15
SLEEP_INTERVAL=2

# TODO: 根据需要替换为你信任的下载地址
CLOUDFLARED_URL_PLACEHOLDER="https://example.com/cloudflared"
XRAY_URL_PLACEHOLDER="https://example.com/xray"

# ---------- 工具函数 ----------
log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"
}

cleanup() {
  log "清理临时文件和后台进程"
  # 优雅终止 cloudflared（如果有）
  if [ -n "${CLOUDFLARED_PID:-}" ] && kill -0 "$CLOUDFLARED_PID" 2>/dev/null; then
    log "尝试优雅终止 cloudflared (PID=$CLOUDFLARED_PID)"
    kill "$CLOUDFLARED_PID" || true
    sleep 1
    if kill -0 "$CLOUDFLARED_PID" 2>/dev/null; then
      log "cloudflared 未退出，发送 TERM 再等待"
      kill -TERM "$CLOUDFLARED_PID" || true
      sleep 1
    fi
  fi
  # 仅删除临时目录（不会删除 /opt 或其他系统目录）
  if [ -d "$TMPDIR" ]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT INT TERM

# ---------- 环境检测 ----------
mkdir -p "$TMPDIR"
touch "$LOGFILE"

log "开始环境检测"

# 发行版识别（使用 ID 或 ID_LIKE）
OS_ID=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-}${ID_LIKE:+ $ID_LIKE}"
fi
log "检测到发行版标识: $OS_ID"

# 架构识别（uname -m）
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l|armv7) ARCH="armv7" ;;
  armv6l) ARCH="armv6" ;;
  i386|i686) ARCH="386" ;;
  *) ARCH="$ARCH_RAW" ;;
esac
log "检测到架构: $ARCH_RAW -> 使用标识 $ARCH"

# 检查 systemctl 是否存在
if command -v systemctl >/dev/null 2>&1; then
  HAS_SYSTEMD=1
else
  HAS_SYSTEMD=0
fi
log "systemd 可用: $HAS_SYSTEMD"

# 检查端口是否被占用
is_port_free() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -q ":$port\$" && return 1 || return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn | awk '{print $4}' | grep -q ":$port\$" && return 1 || return 0
  else
    # 保守判断：假设端口被占用以避免冲突
    return 1
  fi
}

# 生成随机可用端口（10000-60000），最多尝试 50 次
choose_port() {
  local tries=0
  while [ $tries -lt 50 ]; do
    port=$((RANDOM % 50000 + 10000))
    if is_port_free "$port"; then
      echo "$port"
      return 0
    fi
    tries=$((tries+1))
  done
  return 1
}

PORT="$(choose_port)" || { log "未能找到可用端口"; exit 1; }
log "选定端口: $PORT"

# ---------- 下载二进制（示例占位） ----------
# 注意：实际使用时请替换为可信来源并校验 SHA256
download_if_missing() {
  local url="$1"
  local out="$2"
  if [ -f "$out" ]; then
    log "$out 已存在，跳过下载"
    return 0
  fi
  log "下载 $url -> $out"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    log "系统缺少 curl/wget，无法下载 $url"
    return 1
  fi
  chmod +x "$out" || true
  return 0
}

CLOUDFLARED_BIN="${TMPDIR}/cloudflared"
XRAY_BIN="${TMPDIR}/xray"

# 使用占位 URL，运行前请替换
download_if_missing "$CLOUDFLARED_URL_PLACEHOLDER" "$CLOUDFLARED_BIN"
download_if_missing "$XRAY_URL_PLACEHOLDER" "$XRAY_BIN"

# ---------- 生成最小 Xray 配置（示例） ----------
XRAY_CONFIG="${TMPDIR}/config.json"
cat > "$XRAY_CONFIG" <<EOF
{
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "00000000-0000-0000-0000-000000000000",
            "alterId": 0
          }
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
log "已生成 Xray 配置: $XRAY_CONFIG"

# ---------- 启动 Xray（示例） ----------
log "启动 Xray"
if [ -x "$XRAY_BIN" ]; then
  "$XRAY_BIN" -c "$XRAY_CONFIG" >/dev/null 2>&1 &
  XRAY_PID=$!
  log "Xray PID=$XRAY_PID"
  CLEANUP_FILES+=("$XRAY_PID")
else
  log "未找到可执行的 xray 二进制: $XRAY_BIN"
fi

# ---------- 启动 cloudflared Argo 隧道（示例） ----------
# 以后台方式启动并把日志写到 ARGO_LOG
log "启动 cloudflared（argo）并写日志到 $ARGO_LOG"
if [ -x "$CLOUDFLARED_BIN" ]; then
  # 示例命令：请根据 cloudflared 版本调整参数
  nohup "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate >"$ARGO_LOG" 2>&1 &
  CLOUDFLARED_PID=$!
  log "cloudflared PID=$CLOUDFLARED_PID"
else
  log "未找到可执行的 cloudflared: $CLOUDFLARED_BIN"
  exit 1
fi

# ---------- 解析 Argo 输出，等待域名或 UUID 出现 ----------
log "等待 cloudflared 输出可用的域名或隧道信息"
n=0
ARGO_HOST=""
while [ $n -lt $RETRY_LIMIT ]; do
  sleep "$SLEEP_INTERVAL"
  n=$((n+1))
  if [ -s "$ARGO_LOG" ]; then
    # 尝试提取包含 trycloudflare.com 的第一行
    ARGO_HOST="$(grep -m1 -Eo '([a-z0-9-]+\.)*trycloudflare\.com' "$ARGO_LOG" || true)"
    if [ -n "$ARGO_HOST" ]; then
      log "找到 Argo 域名: $ARGO_HOST"
      break
    fi
    # 备用：尝试提取 cloudflared 输出中的 tunnel id/hostname
    ARGO_HOST="$(grep -m1 -Eo 'https?://[^ ]+' "$ARGO_LOG" | sed -n '1p' | sed -E 's#https?://##' || true)"
    if [ -n "$ARGO_HOST" ]; then
      log "从日志提取到 host: $ARGO_HOST"
      break
    fi
  fi
  log "等待中... ($n/$RETRY_LIMIT)"
done

if [ -z "$ARGO_HOST" ]; then
  log "未能在日志中提取到 Argo 域名或 host，停止 cloudflared 并退出"
  cleanup
  exit 1
fi

# ---------- 输出最终信息 ----------
cat > "${TMPDIR}/result.txt" <<EOF
Xray 监听端口: $PORT
Argo 域名: $ARGO_HOST
Xray PID: ${XRAY_PID:-unknown}
cloudflared PID: ${CLOUDFLARED_PID:-unknown}
日志文件: $LOGFILE
EOF

log "完成。结果保存在 ${TMPDIR}/result.txt"
log "内容如下:"
cat "${TMPDIR}/result.txt" | tee -a "$LOGFILE"

# 脚本结束，trap 会在退出时清理
exit 0
