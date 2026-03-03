#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！"
    exit 1
  fi
}

# 获取脚本真实路径（支持被 symlink 或通过 source 执行）
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

# 检测发行版类型
is_debian() { [[ -f /etc/debian_version ]]; }
is_redhat() { [[ -f /etc/redhat-release ]]; }

# 保存规则：兼容常见发行版
save_rules() {
  if is_debian; then
    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save
    else
      # fallback: write to /etc/iptables/rules.v4 and rules.v6 if possible
      iptables-save > /etc/iptables/rules.v4 || true
      ip6tables-save > /etc/iptables/rules.v6 || true
    fi
  elif is_redhat; then
    if command -v service >/dev/null 2>&1; then
      service iptables save || iptables-save > /etc/sysconfig/iptables || true
      # ip6tables persistence on some systems:
      ip6tables-save > /etc/sysconfig/ip6tables || true
    fi
  else
    iptables-save > /etc/iptables/rules.v4 || true
    ip6tables-save > /etc/iptables/rules.v6 || true
  fi
}

# 清除已有匹配的 UDP REDIRECT 规则（仅删除与本脚本添加的规则）
clear_rules() {
  # 删除 nat PREROUTING 中所有 UDP REDIRECT 规则
  while iptables -t nat -C PREROUTING -p udp -j REDIRECT >/dev/null 2>&1; do
    # list rules and delete first matching one
    RULE_SPEC=$(iptables -t nat -S PREROUTING | grep -- '-p udp' | grep -- '-j REDIRECT' | head -n1)
    if [[ -z "$RULE_SPEC" ]]; then break; fi
    # convert -S line to -D form by replacing -A with -D
    iptables -t nat $(echo "$RULE_SPEC" | sed 's/^-A /-D /') || break
  done 2>/dev/null || true

  # IPv6: some systems don't have nat table for ip6tables; guard it
  if ip6tables -t nat -S >/dev/null 2>&1; then
    while ip6tables -t nat -C PREROUTING -p udp -j REDIRECT >/dev/null 2>&1; do
      RULE_SPEC6=$(ip6tables -t nat -S PREROUTING | grep -- '-p udp' | grep -- '-j REDIRECT' | head -n1)
      if [[ -z "$RULE_SPEC6" ]]; then break; fi
      ip6tables -t nat $(echo "$RULE_SPEC6" | sed 's/^-A /-D /') || break
    done 2>/dev/null || true
  fi
}

# 添加规则（严格限制 UDP）
add_rules() {
  local start_port="$1"
  local end_port="$2"
  local target_port="$3"

  # ensure nat table exists for ip6tables before adding
  iptables -t nat -A PREROUTING -p udp --dport "${start_port}:${end_port}" -j REDIRECT --to-ports "${target_port}"
  if ip6tables -t nat -S >/dev/null 2>&1; then
    ip6tables -t nat -A PREROUTING -p udp --dport "${start_port}:${end_port}" -j REDIRECT --to-ports "${target_port}"
  fi

  save_rules
}

install_env() {
  require_root
  echo -e "${YELLOW}正在初始化环境...${PLAIN}"
  if is_debian; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent || true
  elif is_redhat; then
    yum install -y iptables-services || true
    systemctl enable iptables || true
    systemctl start iptables || true
  fi

  # 将脚本安装到 /usr/local/bin/dk（原子操作）
  install -m 755 "$SCRIPT_PATH" /usr/local/bin/dk
  echo -e "${GREEN}环境安装完成，dk 指令已激活：/usr/local/bin/dk${PLAIN}"
}

modify_rules_interactive() {
  read -p "请输入起始端口 (默认 20000): " START_PORT
  START_PORT=${START_PORT:-20000}
  read -p "请输入结束端口 (默认 50000): " END_PORT
  END_PORT=${END_PORT:-50000}
  read -p "请输入 s-ui 里的 Hysteria2 监听端口 (默认 443): " TARGET_PORT
  TARGET_PORT=${TARGET_PORT:-443}

  echo -e "${YELLOW}正在应用规则：UDP ${START_PORT}-${END_PORT} -> ${TARGET_PORT}${PLAIN}"
  clear_rules
  add_rules "$START_PORT" "$END_PORT" "$TARGET_PORT"
  echo -e "${GREEN}规则修改成功！${PLAIN}"
}

modify_rules_noninteractive() {
  # 参数顺序： start end target
  local s="${1:-20000}"
  local e="${2:-50000}"
  local t="${3:-443}"
  clear_rules
  add_rules "$s" "$e" "$t"
  echo -e "${GREEN}规则已更新：UDP ${s}-${e} -> ${t}${PLAIN}"
}

uninstall() {
  require_root
  clear_rules
  rm -f /usr/local/bin/dk || true
  echo -e "${GREEN}所有规则已清除，dk 命令已注销。${PLAIN}"
}

show_status() {
  echo -e "\n${YELLOW}--- 当前 UDP 跳跃转发状态 ---${PLAIN}"
  echo -e "数据包统计 | 目标端口 | 原始范围"
  iptables -t nat -L PREROUTING -n -v | grep "udp dpts:" || iptables -t nat -L PREROUTING -n -v | grep udp || echo "没有检测到生效的规则"
  if ip6tables -t nat -S >/dev/null 2>&1; then
    ip6tables -t nat -L PREROUTING -n -v | grep "udp dpts:" || ip6tables -t nat -L PREROUTING -n -v | grep udp || true
  fi
  echo -e "${YELLOW}----------------------------${PLAIN}\n"
}

usage() {
  cat <<EOF
用法: dk [命令] [参数]

命令:
  install                安装环境并把脚本复制到 /usr/local/bin/dk
  modify                 交互式修改转发规则
  modify <s> <e> <t>     非交互：设置 start end target（例如: dk modify 20000 50000 443）
  status                 查看当前规则与流量统计
  uninstall              删除规则并移除 /usr/local/bin/dk
  help                   显示本帮助
EOF
}

# 主入口：支持作为脚本或已安装的 /usr/local/bin/dk 被调用
main() {
  if [[ "${1:-}" == "install" ]]; then
    install_env
    exit 0
  fi

  case "${1:-help}" in
    install) install_env ;;
    modify)
      if [[ $# -eq 4 ]]; then
        require_root
        modify_rules_noninteractive "$2" "$3" "$4"
      else
        require_root
        modify_rules_interactive
      fi
      ;;
    status) show_status ;;
    uninstall) require_root; uninstall ;;
    help|*) usage ;;
  esac
}

main "$@"
