#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

# --- 核心功能模块 ---

# 1. 环境初始化（静默安装）
install_env() {
    echo -e "${YELLOW}正在初始化环境...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent
    elif [ -f /etc/redhat-release ]; then
        yum install -y iptables-services
        systemctl enable iptables
        systemctl start iptables
    fi
    
    # 注册 dk 命令
    cp "$0" /usr/local/bin/dk
    chmod +x /usr/local/bin/dk
    echo -e "${GREEN}环境安装完成，dk 指令已激活！${PLAIN}"
    read -p "是否立即配置转发规则？(y/n): " confirm
    [[ "$confirm" == "y" ]] && modify_rules
}

# 2. 修改/配置转发规则
modify_rules() {
    echo -e "\n${YELLOW}--- 配置 UDP 端口跳跃规则 ---${PLAIN}"
    read -p "请输入起始端口 (默认 20000): " START_PORT
    START_PORT=${START_PORT:-20000}
    read -p "请输入结束端口 (默认 50000): " END_PORT
    END_PORT=${END_PORT:-50000}
    read -p "请输入 s-ui 里的 Hysteria2 监听端口 (默认 443): " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-443}

    # 先清理旧的 UDP 转发规则，不影响其他业务
    while iptables -t nat -D PREROUTING -p udp -j REDIRECT 2>/dev/null; do :; done
    while ip6tables -t nat -D PREROUTING -p udp -j REDIRECT 2>/dev/null; do :; done

    # 写入新规则 (严格限制为 UDP)
    iptables -t nat -A PREROUTING -p udp --dport $START_PORT:$END_PORT -j REDIRECT --to-ports $TARGET_PORT
    ip6tables -t nat -A PREROUTING -p udp --dport $START_PORT:$END_PORT -j REDIRECT --to-ports $TARGET_PORT

    # 保存到磁盘
    if [ -f /etc/debian_version ]; then
        netfilter-persistent save
    else
        service iptables save
    fi

    echo -e "\n${GREEN}规则修改成功！${PLAIN}"
    echo -e "协议: ${YELLOW}UDP${PLAIN}"
    echo -e "范围: ${YELLOW}$START_PORT - $END_PORT${PLAIN} ---> 目标: ${YELLOW}$TARGET_PORT${PLAIN}"
}

# 3. 卸载功能
uninstall() {
    while iptables -t nat -D PREROUTING -p udp -j REDIRECT 2>/dev/null; do :; done
    while ip6tables -t nat -D PREROUTING -p udp -j REDIRECT 2>/dev/null; do :; done
    rm -f /usr/local/bin/dk
    echo -e "${GREEN}所有规则已清除，dk 命令已注销。${PLAIN}"
    exit 0
}

# 4. 状态查看
show_status() {
    echo -e "\n${YELLOW}--- 当前 UDP 跳跃转发状态 ---${PLAIN}"
    # 打印表头增加可读性
    echo -e "数据包统计 | 目标端口 | 原始范围"
    iptables -t nat -L PREROUTING -n -v | grep "udp dpts:" || echo "没有检测到生效的规则"
    echo -e "${YELLOW}----------------------------${PLAIN}\n"
}

# --- 主菜单 ---
menu() {
    clear
    echo -e "${GREEN}Hysteria 2 端口跳跃管理工具 (支持 dk 命令)${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "  ${YELLOW}1.${PLAIN} 首次使用：安装环境并激活 dk"
    echo -e "  ${YELLOW}2.${PLAIN} 修改配置：更新转发端口范围"
    echo -e "  ${YELLOW}3.${PLAIN} 监控统计：查看流量数据包"
    echo -e "  ${YELLOW}4.${PLAIN} 彻底卸载：删除规则及快捷命令"
    echo -p "  ${YELLOW}0.${PLAIN} 退出"
    echo -e "------------------------------------------------"
    read -p "选择操作 [0-4]: " choice
    case $choice in
        1) install_env ;;
        2) modify_rules ;;
        3) show_status; read -p "按回车返回..." ;;
        4) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误！${PLAIN}"; sleep 1 ;;
    esac
}

while true; do menu; done
