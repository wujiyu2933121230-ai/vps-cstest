# ═══════════════════════════════════════════════════════════════════════════
# 模块 2: SSH 安全配置
# ═══════════════════════════════════════════════════════════════════════════

readonly SSHD_CFG="/etc/ssh/sshd_config"
readonly SSHD_CFG_D="/etc/ssh/sshd_config.d"
readonly SSH_BACKUP_DIR="/etc/ssh/backups"

ssh_backup_config() {
    mkdir -p "$SSH_BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local bak="$SSH_BACKUP_DIR/sshd_config_$ts"
    cp "$SSHD_CFG" "$bak"
    log_info "已备份 sshd_config -> $bak"
}

ssh_restart_service() {
    if sshd -t; then
        if systemctl restart ssh; then
            log_ok "ssh 服务已重启"
        else
            log_error "ssh 服务重启失败"
        fi
    else
        log_error "sshd 配置语法错误，不会重启服务。请手动检查 $SSHD_CFG"
    fi
}

ssh_check_include_directive() {
    grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf\s*$' "$SSHD_CFG"
}

ssh_list_users_with_keys() {
    local users=()
    while IFS=: read -r user _ uid _ _ home _; do
        if [[ $uid -ge 1000 || $uid -eq 0 ]] && [[ -d "$home" ]]; then
            local ak="$home/.ssh/authorized_keys"
            if [[ -f "$ak" && -s "$ak" ]]; then
                users+=("$user")
            fi
        fi
    done < /etc/passwd
    printf '%s\n' "${users[@]}"
}

ssh_list_all_users() {
    local users=()
    while IFS=: read -r user _ uid _ _ home shell; do
        if [[ $uid -eq 0 ]] || { [[ $uid -ge 1000 ]] && [[ "$shell" != "/usr/sbin/nologin" ]] && [[ "$shell" != "/bin/false" ]]; }; then
            users+=("$user")
        fi
    done < /etc/passwd
    printf '%s\n' "${users[@]}"
}

ssh_select_user() {
    local users=()
    while IFS= read -r u; do
        [[ -n "$u" ]] && users+=("$u")
    done < <(ssh_list_all_users)

    if [[ ${#users[@]} -eq 0 ]]; then
        log_error "没有可用的系统用户"
        return 1
    fi

    echo "可用的系统用户:" >&2
    for i in "${!users[@]}"; do
        echo "  $((i+1)). ${users[$i]}" >&2
    done
    echo "  0. 返回" >&2
    echo "" >&2

    local choice
    read -rp "请选择用户 [0-${#users[@]}]: " choice

    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#users[@]} ]]; then
        echo "${users[$((choice-1))]}"
        return 0
    fi

    log_error "无效选项" >&2
    return 1
}

ssh_show_auth_status() {
    local users=()
    while IFS= read -r u; do
        [[ -n "$u" ]] && users+=("$u")
    done < <(ssh_list_all_users)

    for user in "${users[@]}"; do
        local pass_auth key_auth
        if sshd -T -C user="$user" &>/dev/null; then
            pass_auth=$(sshd -T -C user="$user" 2>/dev/null | grep -i "^passwordauthentication" | awk '{print $2}')
            key_auth=$(sshd -T -C user="$user" 2>/dev/null | grep -i "^pubkeyauthentication" | awk '{print $2}')
        fi

        local pass_str key_str pass_color key_color
        if [[ "$pass_auth" == "yes" ]]; then
            pass_str="开启"; pass_color="$GREEN"
        elif [[ "$pass_auth" == "no" ]]; then
            pass_str="关闭"; pass_color="$RED"
        else
            pass_str="未知"; pass_color="$YELLOW"
        fi
        if [[ "$key_auth" == "yes" ]]; then
            key_str="开启"; key_color="$GREEN"
        elif [[ "$key_auth" == "no" ]]; then
            key_str="关闭"; key_color="$RED"
        else
            key_str="未知"; key_color="$YELLOW"
        fi

        printf "${CYAN}║${NC}  %-8s 密码 ${pass_color}%s${NC} | 密钥 ${key_color}%s${NC}        ${CYAN}║${NC}\n" \
            "$user" "$pass_str" "$key_str"
    done
}

# ── 2.1 查看当前 SSH 状态 ──
ssh_show_status() {
    clear
    echo ""
    echo -e "${CYAN}========== SSH 当前状态 ==========${NC}"
    echo -n "PubkeyAuthentication:    "
    sshd -T 2>/dev/null | grep -i "^pubkeyauthentication" | awk '{print $2}'
    echo -n "PasswordAuthentication:  "
    sshd -T 2>/dev/null | grep -i "^passwordauthentication" | awk '{print $2}'
    echo -n "当前监听端口:            "
    get_current_ssh_port
    echo ""
    echo "拥有 authorized_keys 的用户:"
    local key_users
    key_users=$(ssh_list_users_with_keys)
    if [[ -z "$key_users" ]]; then
        echo "  (无)"
    else
        echo "$key_users" | while read -r u; do
            echo "  - $u"
        done
    fi
    echo -e "${CYAN}===================================${NC}"
    echo ""
    press_enter
}

# ── 2.2 修改 SSH 端口 ──
ssh_change_port() {
    clear
    echo ""
    echo -e "${CYAN}=== 修改 SSH 端口 ===${NC}"
    echo ""

    local old_port
    old_port=$(get_current_ssh_port)
    old_port=${old_port:-22}
    echo "当前 SSH 端口: $old_port"
    echo ""

    local port
    read -rp "输入新的 SSH 端口号 (留空取消): " port
    [[ -z "$port" ]] && { log_info "已取消"; press_enter; return; }

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        log_error "无效端口号: $port"
        press_enter
        return
    fi

    if [[ "$port" == "$old_port" ]]; then
        log_info "SSH 端口已是 $port，无需修改"
        press_enter
        return
    fi

    log_info "将 SSH 端口从 $old_port 修改为 $port"

    local use_socket=false
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        use_socket=true
    fi

    if [[ "$use_socket" == true ]]; then
        mkdir -p /etc/systemd/system/ssh.socket.d
        cat > /etc/systemd/system/ssh.socket.d/port.conf << EOF
[Socket]
ListenStream=
ListenStream=$port
EOF
        systemctl daemon-reload
        systemctl restart ssh.socket
        systemctl restart ssh.service 2>/dev/null || true
    else
        if grep -qE "^Port\s+" "$SSHD_CFG"; then
            sed -i "s/^Port\s\+.*/Port $port/" "$SSHD_CFG"
        else
            echo "Port $port" >> "$SSHD_CFG"
        fi
        local svc
        svc=$(systemctl list-units --type=service 2>/dev/null | grep -oE 'ssh(d)?\.service' | head -1)
        if [[ -n "$svc" ]]; then
            systemctl restart "$svc"
        else
            log_error "无法找到 SSH 服务"
        fi
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow "$old_port/tcp" 2>/dev/null || true
        ufw allow "$port/tcp" 2>/dev/null || true
    fi

    if [[ -f /etc/fail2ban/jail.local ]]; then
        sed -i "s/^port = .*/port = $port/" /etc/fail2ban/jail.local
        systemctl restart fail2ban 2>/dev/null || true
        log_info "fail2ban 端口已同步更新"
    fi

    log_ok "SSH 端口已修改为 $port"
    log_warn "请保持当前连接，另开窗口测试 $port 端口后再退出！"
    press_enter
}

# ── 密码/密钥设置 ──────────────────────────────────────────────────────────

ssh_change_password() {
    clear
    echo ""
    echo -e "${CYAN}=== 修改密码 ===${NC}"
    echo ""

    local user
    user=$(ssh_select_user) || return

    while true; do
        echo ""
        passwd "$user" && break
        log_warn "密码修改失败，请重试"
    done
    log_ok "用户 $user 密码已修改"
    press_enter
}

ssh_enable_password() {
    clear
    echo ""
    echo -e "${CYAN}=== 开启密码登录 ===${NC}"
    echo ""

    local user
    user=$(ssh_select_user) || return

    local rule_file="$SSHD_CFG_D/99-vps-password-disable-${user}.conf"
    if [[ -f "$rule_file" ]]; then
        rm -f "$rule_file"
        ssh_restart_service
        log_ok "用户 $user 密码登录已开启"
    else
        log_info "用户 $user 密码登录已是开启状态"
    fi
    press_enter
}

ssh_disable_password() {
    clear
    echo ""
    echo -e "${CYAN}=== 关闭密码登录 ===${NC}"
    echo ""

    local user
    user=$(ssh_select_user) || return

    local rule_file
    if ! ssh_check_include_directive; then
        log_warn "sshd_config 中未找到 Include 指令，将直接写入 $SSHD_CFG"
        rule_file="$SSHD_CFG"
    else
        rule_file="$SSHD_CFG_D/99-vps-password-disable-${user}.conf"
    fi
    if [[ -f "$rule_file" ]]; then
        log_info "用户 $user 密码登录已关闭"
        press_enter
        return
    fi

    local has_key=false
    local home
    home=$(getent passwd "$user" | cut -d: -f6)
    if [[ -f "$home/.ssh/authorized_keys" && -s "$home/.ssh/authorized_keys" ]]; then
        has_key=true
    fi

    if ! $has_key; then
        log_warn "用户 $user 未配置密钥，关闭密码登录后可能无法登录！"
        if ! confirm "确认继续？"; then
            log_info "已取消"
            press_enter
            return
        fi
    fi

    cat > "$rule_file" << EOF
# 由 vps-init.sh 于 $(date) 生成
Match User $user
    PasswordAuthentication no
EOF

    chmod 644 "$rule_file"
    ssh_restart_service
    log_ok "用户 $user 密码登录已关闭"
    press_enter
}

ssh_add_pubkey() {
    clear
    echo ""
    echo -e "${CYAN}=== 添加密钥（有公钥） ===${NC}"
    echo ""

    local user
    user=$(ssh_select_user) || return

    local home
    home=$(getent passwd "$user" | cut -d: -f6)

    local key
    read -rp "粘贴 SSH 公钥 (留空取消): " key
    [[ -z "$key" ]] && { log_info "已取消"; press_enter; return; }

    mkdir -p "$home/.ssh"
    chmod 700 "$home/.ssh"

    if grep -qF "$key" "$home/.ssh/authorized_keys" 2>/dev/null; then
        log_info "公钥已存在，无需重复添加"
    else
        echo "$key" >> "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
        if [[ "$user" != "root" ]]; then
            chown -R "$user:$user" "$home/.ssh"
        fi
        log_ok "公钥已添加到用户 $user"
    fi
    press_enter
}

ssh_generate_key() {
    clear
    echo ""
    echo -e "${CYAN}=== 生成密钥（无公钥） ===${NC}"
    echo ""

    local user
    user=$(ssh_select_user) || return

    local keyfile
    if [[ "$user" == "root" ]]; then
        keyfile="/root/.ssh/id_ed25519"
    else
        local h
        h=$(getent passwd "$user" | cut -d: -f6)
        keyfile="$h/.ssh/id_ed25519"
    fi

    if [[ -f "$keyfile" ]]; then
        log_warn "$keyfile 已存在，跳过生成"
        press_enter
        return
    fi

    mkdir -p "$(dirname "$keyfile")"
    ssh-keygen -t ed25519 -N "" -C "$user@$(hostname)" -f "$keyfile" -q
    log_ok "已生成密钥: $keyfile"
    echo ""

    echo -e "${YELLOW}========== 私钥内容 (请保存到本地!) ==========${NC}"
    cat "$keyfile"
    echo -e "${YELLOW}===============================================${NC}"
    echo ""
    echo -e "${YELLOW}========== 公钥内容 ==========${NC}"
    cat "${keyfile}.pub"
    echo -e "${YELLOW}===============================${NC}"
    echo ""
    log_warn "请将私钥保存到本地安全位置，服务器上的私钥建议删除！"

    local sshdir
    sshdir=$(dirname "$keyfile")
    cat "${keyfile}.pub" >> "$sshdir/authorized_keys"
    chmod 700 "$sshdir"
    chmod 600 "$sshdir/authorized_keys"
    if [[ "$user" != "root" ]]; then
        chown -R "$user:$user" "$sshdir"
    fi
    log_ok "已将公钥添加到 authorized_keys (用户 $user)"
    press_enter
}

ssh_enable_pubkey() {
    clear
    echo ""
    echo -e "${CYAN}=== 开启密钥认证 ===${NC}"
    echo ""

    local user
    user=$(ssh_select_user) || return

    local rule_file="$SSHD_CFG_D/99-vps-pubkey-disable-${user}.conf"
    if [[ -f "$rule_file" ]]; then
        rm -f "$rule_file"
        ssh_restart_service
        log_ok "用户 $user 密钥认证已开启"
    else
        log_info "用户 $user 密钥认证已是开启状态"
    fi
    press_enter
}

ssh_disable_pubkey() {
    clear
    echo ""
    echo -e "${CYAN}=== 关闭密钥认证 ===${NC}"
    echo ""

    local user
    user=$(ssh_select_user) || return

    local rule_file
    if ! ssh_check_include_directive; then
        log_warn "sshd_config 中未找到 Include 指令，将直接写入 $SSHD_CFG"
        rule_file="$SSHD_CFG"
    else
        rule_file="$SSHD_CFG_D/99-vps-pubkey-disable-${user}.conf"
    fi
    if [[ -f "$rule_file" ]]; then
        log_info "用户 $user 密钥认证已关闭"
        press_enter
        return
    fi

    cat > "$rule_file" << EOF
# 由 vps-init.sh 于 $(date) 生成
Match User $user
    PubkeyAuthentication no
EOF

    chmod 644 "$rule_file"
    ssh_restart_service
    log_ok "用户 $user 密钥认证已关闭"
    press_enter
}

ssh_passkey_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║        密码/密钥设置                  ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"

        ssh_show_auth_status

        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║  ── 密码设置 ──                      ║${NC}"
        echo -e "${CYAN}║  1. 修改密码                         ║${NC}"
        echo -e "${CYAN}║  2. 开启密码登录                     ║${NC}"
        echo -e "${CYAN}║  3. 关闭密码登录                     ║${NC}"
        echo -e "${CYAN}║  ── 密钥设置 ──                      ║${NC}"
        echo -e "${CYAN}║  4. 添加密钥（有公钥）               ║${NC}"
        echo -e "${CYAN}║  5. 生成密钥（无公钥）               ║${NC}"
        echo -e "${CYAN}║  6. 开启密钥认证                     ║${NC}"
        echo -e "${CYAN}║  7. 关闭密钥认证                     ║${NC}"
        echo -e "${CYAN}║  0. 返回上级                         ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        read -rp "请选择 [0-7]: " choice

        case "$choice" in
            1) ssh_change_password ;;
            2) ssh_enable_password ;;
            3) ssh_disable_password ;;
            4) ssh_add_pubkey ;;
            5) ssh_generate_key ;;
            6) ssh_enable_pubkey ;;
            7) ssh_disable_pubkey ;;
            0) break ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}

# ── 2.3 创建普通用户 ──
ssh_create_user() {
    clear
    echo ""
    echo -e "${CYAN}=== 创建普通用户 ===${NC}"
    echo ""

    local username
    read -rp "输入新用户名 (留空取消): " username
    [[ -z "$username" ]] && { log_info "已取消"; press_enter; return; }

    if id "$username" &>/dev/null; then
        log_info "用户 $username 已存在"
        usermod -aG sudo "$username" 2>/dev/null || true
    else
        useradd -m -s /bin/bash "$username"
        log_ok "用户 $username 已创建"

        echo ""
        while true; do
            passwd "$username" && break
            log_warn "密码设置失败，请重试"
        done

        usermod -aG sudo "$username"
        log_ok "$username 已加入 sudo 组"
    fi

    if [[ -f ~/.ssh/authorized_keys ]]; then
        local user_home
        user_home=$(getent passwd "$username" | cut -d: -f6)
        mkdir -p "$user_home/.ssh"
        cp ~/.ssh/authorized_keys "$user_home/.ssh/authorized_keys"
        chown -R "$username:$username" "$user_home/.ssh"
        chmod 700 "$user_home/.ssh"
        chmod 600 "$user_home/.ssh/authorized_keys"
        log_ok "SSH 公钥已复制到 $username"
    fi
    press_enter
}

ssh_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║        SSH 安全配置                  ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║  1. 查看当前 SSH 状态                ║${NC}"
        echo -e "${CYAN}║  2. 修改 SSH 端口                    ║${NC}"
        echo -e "${CYAN}║  3. 密码/密钥设置                    ║${NC}"
        echo -e "${CYAN}║  4. 创建普通用户                     ║${NC}"
        echo -e "${CYAN}║  0. 返回主菜单                       ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        read -rp "请选择 [0-4]: " choice

        case "$choice" in
            1) ssh_show_status ;;
            2) ssh_change_port ;;
            3) ssh_passkey_menu ;;
            4) ssh_create_user ;;
            0) break ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}
