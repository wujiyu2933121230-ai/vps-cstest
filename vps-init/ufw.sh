# ═══════════════════════════════════════════════════════════════════════════
# 模块 3: 防火墙管理 (UFW)
# ═══════════════════════════════════════════════════════════════════════════

ufw_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║        防火墙管理 (UFW)              ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"

        if command -v ufw &>/dev/null; then
            local ufw_status
            ufw_status=$(ufw status 2>/dev/null | head -1)
            echo -e "${CYAN}║  状态: ${GREEN}$ufw_status${NC}"
        else
            echo -e "${CYAN}║  状态: ${RED}未安装${NC}"
        fi

        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║  1. 安装 ufw                         ║${NC}"
        echo -e "${CYAN}║  2. 查看 ufw 状态和规则              ║${NC}"
        echo -e "${CYAN}║  3. 开放端口                         ║${NC}"
        echo -e "${CYAN}║  4. 关闭端口                         ║${NC}"
        echo -e "${CYAN}║  5. 启用 ufw                         ║${NC}"
        echo -e "${CYAN}║  0. 返回主菜单                       ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        read -rp "请选择 [0-5]: " choice

        case "$choice" in
            1)
                if command -v ufw &>/dev/null; then
                    log_info "ufw 已安装"
                else
                    apt update && apt install -y ufw
                    log_ok "ufw 安装完成"
                fi
                press_enter
                ;;
            2)
                if command -v ufw &>/dev/null; then
                    ufw status verbose 2>/dev/null
                else
                    log_warn "ufw 未安装"
                fi
                press_enter
                ;;
            3)
                if ! command -v ufw &>/dev/null; then
                    log_error "ufw 未安装，请先安装"
                    press_enter
                    continue
                fi
                local port
                read -rp "输入要开放的端口号: " port
                if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]; then
                    ufw allow "$port" 2>/dev/null
                    log_ok "已开放端口 $port"
                else
                    log_error "无效端口号"
                fi
                press_enter
                ;;
            4)
                if ! command -v ufw &>/dev/null; then
                    log_error "ufw 未安装，请先安装"
                    press_enter
                    continue
                fi
                local port
                read -rp "输入要关闭的端口号: " port
                if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]; then
                    ufw delete allow "$port" 2>/dev/null
                    log_ok "已关闭端口 $port"
                else
                    log_error "无效端口号"
                fi
                press_enter
                ;;
            5)
                if ! command -v ufw &>/dev/null; then
                    log_error "ufw 未安装，请先安装"
                    press_enter
                    continue
                fi
                local ssh_port
                ssh_port=$(get_current_ssh_port)
                ufw allow "$ssh_port/tcp" 2>/dev/null
                ufw --force enable 2>/dev/null
                log_ok "ufw 已启用 (SSH 端口 $ssh_port 已放行)"
                press_enter
                ;;
            0) break ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}
