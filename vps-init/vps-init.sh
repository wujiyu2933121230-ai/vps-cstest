#!/bin/bash
set -euo pipefail

# ============================================================
# vps-init.sh — VPS 综合管理脚本 (Debian/Ubuntu)
#
# 功能模块:
#   1. VPS 初始化 (系统更新/工具/swap/fail2ban/BBR/DNS...)
#   2. SSH 安全配置 (端口/密钥/密码登录/用户管理)
#   3. 防火墙管理 (UFW)
#   4. anytls-go 代理管理
#   5. Hysteria2 代理管理
#   6. 卸载 vps-init
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/system.sh"
source "${SCRIPT_DIR}/ssh.sh"
source "${SCRIPT_DIR}/ufw.sh"
source "${SCRIPT_DIR}/anytls.sh"
source "${SCRIPT_DIR}/hy2.sh"

# ═══════════════════════════════════════════════════════════════════════════
# 卸载自身
# ═══════════════════════════════════════════════════════════════════════════

uninstall_self() {
    clear
    echo ""
    echo -e "${RED}╔══════════════════════════════════════╗${NC}"
    echo -e "${RED}║        卸载 vps-init                  ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo "将删除以下内容:"
    echo "  - $SCRIPT_DIR"
    echo "  - /usr/local/bin/vps"
    echo ""

    if ! confirm "确定要卸载 vps-init？"; then
        log_info "已取消"
        press_enter
        return
    fi

    log_info "正在停止服务..."
    systemctl stop anytls 2>/dev/null || true
    systemctl disable anytls 2>/dev/null || true
    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true

    log_info "正在删除文件..."
    rm -rf "$SCRIPT_DIR"
    rm -f /usr/local/bin/vps
    systemctl daemon-reload 2>/dev/null || true

    echo ""
    log_ok "卸载完成"
    echo ""
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# 主菜单
# ═══════════════════════════════════════════════════════════════════════════

print_main_menu() {
    clear
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        VPS 综合管理脚本 v2.0         ║${NC}"
    echo -e "${CYAN}║        Debian / Ubuntu              ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  1. VPS 初始化                       ║${NC}"
    echo -e "${CYAN}║  2. SSH 安全配置                     ║${NC}"
    echo -e "${CYAN}║  3. 防火墙管理 (UFW)                 ║${NC}"
    echo -e "${CYAN}║  4. anytls-go 代理管理               ║${NC}"
    echo -e "${CYAN}║  5. Hysteria2 代理管理               ║${NC}"
    echo -e "${CYAN}║  6. 卸载 vps-init                     ║${NC}"
    echo -e "${CYAN}║  0. 退出                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
}

main() {
    check_root
    check_os

    while true; do
        print_main_menu
        read -rp "请选择 [0-6]: " choice

        case "$choice" in
            1) vps_init_menu ;;
            2) ssh_menu ;;
            3) ufw_menu ;;
            4) anytls_menu ;;
            5) hy2_menu ;;
            6) uninstall_self ;;
            0)
                echo ""
                log_info "再见!"
                exit 0
                ;;
            *)
                log_error "无效选项"
                sleep 1
                ;;
        esac
    done
}

[[ "$0" == "${BASH_SOURCE[0]}" ]] && main
