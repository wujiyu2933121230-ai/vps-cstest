# ═══════════════════════════════════════════════════════════════════════════
# 模块 5: Hysteria2 代理管理
# ═══════════════════════════════════════════════════════════════════════════

readonly HY2_BIN="/usr/local/bin/hysteria"
readonly HY2_CONFIG="/etc/hysteria/config.yaml"
readonly HY2_CERT="/etc/hysteria/server.crt"
readonly HY2_KEY="/etc/hysteria/server.key"
readonly HY2_PORT_HOP_CONF="/etc/hysteria/port-hopping.conf"
readonly HY2_SERVICE="hysteria-server.service"
readonly HY2_START_PORT=25000
readonly HY2_END_PORT=26000

readonly HY2_MASQ_DOMAINS=(
    "www.cloudflare.com"
    "www.apple.com"
    "www.microsoft.com"
    "www.bing.com"
    "www.google.com"
    "aws.amazon.com"
    "cdn.jsdelivr.net"
    "www.mozilla.org"
    "www.wikipedia.org"
    "www.w3.org"
    "www.sony.com"
    "www.nytimes.com"
    "www.intel.com"
    "images.unsplash.com"
    "www.gstatic.com"
)

hy2_get_best_domain() {
    local best_domain="cdn.jsdelivr.net"
    local best_latency=9999

    for domain in "${HY2_MASQ_DOMAINS[@]}"; do
        local start end latency
        start=$(date +%s%3N)
        if timeout 3 openssl s_client -connect "$domain:443" -servername "$domain" </dev/null >/dev/null 2>&1; then
            end=$(date +%s%3N)
            latency=$((end - start))
            if [[ "$latency" -lt "$best_latency" ]]; then
                best_latency=$latency
                best_domain=$domain
            fi
        fi
    done
    echo "$best_domain"
}

hy2_get_listen_port() {
    if [[ -f "$HY2_CONFIG" ]]; then
        grep -E "^\s*listen:" "$HY2_CONFIG" | awk -F':' '{print $NF}' | tr -d ' ' | head -1
    else
        echo "443"
    fi
}

hy2_check_port_hopping() {
    local target_port
    target_port=$(hy2_get_listen_port)
    iptables -t nat -S PREROUTING 2>/dev/null | grep -q "REDIRECT.*--to-ports $target_port"
}

hy2_get_port_hopping_info() {
    if [[ -f "$HY2_PORT_HOP_CONF" ]]; then
        local sp ep tp
        sp=$(grep '^START_PORT=' "$HY2_PORT_HOP_CONF" 2>/dev/null | cut -d'=' -f2)
        ep=$(grep '^END_PORT=' "$HY2_PORT_HOP_CONF" 2>/dev/null | cut -d'=' -f2)
        tp=$(grep '^TARGET_PORT=' "$HY2_PORT_HOP_CONF" 2>/dev/null | cut -d'=' -f2)
        echo "${sp:-?}-${ep:-?} -> ${tp:-?}"
    else
        echo "未配置"
    fi
}

hy2_clear_port_hopping() {
    local target_port
    target_port=$(hy2_get_listen_port)
    local cleared=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^-A\ PREROUTING.*REDIRECT.*--to-ports\ $target_port ]]; then
            local del_rule="${line/-A/-D}"
            iptables -t nat $del_rule 2>/dev/null && cleared=true
        fi
    done < <(iptables -t nat -S PREROUTING 2>/dev/null)

    local nums
    nums=$(iptables -t nat -L PREROUTING --line-numbers 2>/dev/null | grep "REDIRECT.*--to-ports $target_port" | awk '{print $1}' | sort -rn)
    for n in $nums; do
        iptables -t nat -D PREROUTING "$n" 2>/dev/null && cleared=true
    done

    rm -f "$HY2_PORT_HOP_CONF"
    systemctl disable hysteria-port-hopping.service >/dev/null 2>&1
    systemctl stop hysteria-port-hopping.service >/dev/null 2>&1
    rm -f /etc/systemd/system/hysteria-port-hopping.service
    if $cleared; then
        log_ok "端口跳跃已清除"
    else
        log_info "没有需要清除的规则"
    fi
}

hy2_add_port_hopping() {
    local iface start_port end_port target_port
    iface=$(get_network_interface)
    start_port=${1:-$HY2_START_PORT}
    end_port=${2:-$HY2_END_PORT}
    target_port=${3:-$(hy2_get_listen_port)}

    if iptables -t nat -C PREROUTING -i "$iface" -p udp --dport "$start_port:$end_port" -j REDIRECT --to-ports "$target_port" 2>/dev/null; then
        log_warn "端口跳跃规则已存在"
        return 0
    fi

    if iptables -t nat -A PREROUTING -i "$iface" -p udp --dport "$start_port:$end_port" -j REDIRECT --to-ports "$target_port" 2>&1; then
        cat > "$HY2_PORT_HOP_CONF" << EOF
INTERFACE=$iface
START_PORT=$start_port
END_PORT=$end_port
TARGET_PORT=$target_port
EOF
        log_ok "端口跳跃已启用: ${start_port}-${end_port} -> ${target_port}"
        hy2_persist_port_hopping
        return 0
    else
        log_error "添加规则失败"
        return 1
    fi
}

hy2_persist_port_hopping() {
    local service_file="/etc/systemd/system/hysteria-port-hopping.service"
    cat > "$service_file" << 'UNITEOF'
[Unit]
Description=Hysteria2 Port Hopping iptables Rules
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '
    conf=/etc/hysteria/port-hopping.conf
    if [[ -f "$conf" ]]; then
        source "$conf"
        iptables -t nat -C PREROUTING -i "$INTERFACE" -p udp --dport "$START_PORT:$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$INTERFACE" -p udp --dport "$START_PORT:$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT"
    fi
'
ExecStop=/bin/bash -c '
    conf=/etc/hysteria/port-hopping.conf
    if [[ -f "$conf" ]]; then
        source "$conf"
        iptables -t nat -D PREROUTING -i "$INTERFACE" -p udp --dport "$START_PORT:$END_PORT" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null || true
    fi
'

[Install]
WantedBy=multi-user.target
UNITEOF
    systemctl daemon-reload || true
    systemctl enable hysteria-port-hopping.service >/dev/null 2>&1 || true
    systemctl start hysteria-port-hopping.service >/dev/null 2>&1 || true
    log_ok "端口跳跃规则已持久化"
}

hy2_parse_config() {
    if [[ ! -f "$HY2_CONFIG" ]]; then
        echo "|||"
        return
    fi

    local port auth_pass obfs_pass sni cert_type
    port=$(grep -E "^\s*listen:" "$HY2_CONFIG" | awk -F':' '{print $NF}' | tr -d ' ')
    port=${port:-443}

    auth_pass=$(grep -A 2 "^auth:" "$HY2_CONFIG" | grep "password:" | sed 's/.*password:[[:space:]]*//' | tr -d '"')

    if grep -q "^obfs:" "$HY2_CONFIG"; then
        obfs_pass=$(grep -A 3 "^obfs:" "$HY2_CONFIG" | grep "password:" | sed 's/.*password:[[:space:]]*//' | tr -d '"')
    fi

    local masq_url
    masq_url=$(grep -A 3 "masquerade:" "$HY2_CONFIG" | grep "url:" | awk '{print $2}')
    if [[ -n "$masq_url" ]]; then
        sni=$(echo "$masq_url" | sed 's|https\?://||' | sed 's|/.*||')
    fi

    if grep -q "^tls:" "$HY2_CONFIG"; then
        cert_type="self"
    else
        cert_type="acme"
    fi

    echo "$port|$auth_pass|$obfs_pass|$sni|$cert_type"
}

hy2_get_cert_fingerprint() {
    if [[ -f "$HY2_CERT" ]]; then
        openssl x509 -noout -fingerprint -sha256 -in "$HY2_CERT" 2>/dev/null | sed 's/.*=//' | tr -d ':'
    fi
}

# ── 5.1 安装 ──
hy2_install() {
    clear
    echo ""
    echo -e "${CYAN}=== 安装 Hysteria2 ===${NC}"
    echo ""

    if [[ -x "$HY2_BIN" ]]; then
        local ver
        ver=$("$HY2_BIN" version 2>/dev/null | head -1 || echo "未知")
        log_warn "检测到已安装: $ver"
        if ! confirm "是否重新安装？"; then
            log_info "已取消"
            press_enter
            return
        fi
        [[ -f "$HY2_CONFIG" ]] && cp "$HY2_CONFIG" "${HY2_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)_${RANDOM}"
    fi

    echo "正在安装 Hysteria2..."

    local download_url
    if grep -q avx /proc/cpuinfo 2>/dev/null; then
        download_url="https://download.hysteria.network/app/latest/hysteria-linux-amd64-avx"
        echo "检测到 AVX 支持，使用 AVX 版本"
    else
        download_url="https://download.hysteria.network/app/latest/hysteria-linux-amd64"
        echo "未检测到 AVX，使用标准版本"
    fi

    mkdir -p /etc/hysteria
    if wget -q --show-progress -O "$HY2_BIN" "$download_url"; then
        chmod +x "$HY2_BIN"
        local ver
        ver=$("$HY2_BIN" version 2>/dev/null | head -1 || echo "")
        log_ok "安装完成: ${ver:-OK}"
    else
        log_error "下载失败，请检查网络"
    fi
    press_enter
}

# ── 5.2 一键快速配置 ──
hy2_quick_config() {
    clear
    echo ""
    echo -e "${CYAN}=== 一键快速配置 ===${NC}"
    echo ""

    if [[ ! -x "$HY2_BIN" ]]; then
        log_error "Hysteria2 未安装，请先安装"
        press_enter
        return
    fi

    if [[ -f "$HY2_CONFIG" ]]; then
        if ! confirm "检测到现有配置，是否覆盖？"; then
            log_info "已取消"
            press_enter
            return
        fi
        cp "$HY2_CONFIG" "${HY2_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)_${RANDOM}"
    fi

    echo -e "${BLUE}[1/6] 获取服务器信息...${NC}"
    local server_ip iface
    server_ip=$(public_ip)
    iface=$(get_network_interface)
    echo "  IP: $server_ip, 网卡: $iface"

    echo -e "${BLUE}[2/6] 测试最优伪装域名...${NC}"
    local best_domain
    best_domain=$(hy2_get_best_domain)
    echo "  最优域名: $best_domain"

    echo -e "${BLUE}[3/6] 生成密码...${NC}"
    local auth_pass obfs_pass
    auth_pass=$(gen_password)
    obfs_pass=$(gen_password)
    echo "  认证密码: $auth_pass"
    echo "  混淆密码: $obfs_pass"

    echo -e "${BLUE}[4/6] 生成自签名证书...${NC}"
    mkdir -p /etc/hysteria
    if ! openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$HY2_KEY" -out "$HY2_CERT" \
        -subj "/CN=$best_domain" -days 3650 >/dev/null 2>&1; then
        log_error "证书生成失败，请检查 openssl 版本"
        press_enter
        return
    fi
    chmod 600 "$HY2_KEY"
    chmod 644 "$HY2_CERT"
    echo "  证书生成完成"

    echo -e "${BLUE}[5/6] 生成配置文件...${NC}"
    cat > "$HY2_CONFIG" << EOF
# Hysteria2 配置 - $(date '+%Y-%m-%d %H:%M:%S')
listen: :443

tls:
  cert: $HY2_CERT
  key: $HY2_KEY

auth:
  type: password
  password: $auth_pass

masquerade:
  type: proxy
  proxy:
    url: https://$best_domain/
    rewriteHost: true

obfs:
  type: salamander
  salamander:
    password: $obfs_pass
EOF
    chmod 600 "$HY2_CONFIG"
    echo "  配置生成完成"

    echo -e "${BLUE}[5.5/6] 验证配置文件...${NC}"
    if ! "$HY2_BIN" check -c "$HY2_CONFIG" >/dev/null 2>&1; then
        log_error "配置文件验证失败"
        press_enter
        return
    fi
    log_ok "配置文件验证通过"

    echo -e "${BLUE}[6/6] 配置端口跳跃并启动服务...${NC}"
    hy2_add_port_hopping "$HY2_START_PORT" "$HY2_END_PORT" "443" || true

    cat > "/etc/systemd/system/$HY2_SERVICE" << EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=${HY2_BIN} server -c ${HY2_CONFIG}
Restart=always
RestartSec=5
User=root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$HY2_SERVICE" >/dev/null 2>&1
    systemctl restart "$HY2_SERVICE" 2>/dev/null

    local retries=10
    while [[ $retries -gt 0 ]]; do
        if systemctl is-active --quiet "$HY2_SERVICE" 2>/dev/null; then
            break
        fi
        sleep 1
        retries=$((retries - 1))
    done

    if systemctl is-active --quiet "$HY2_SERVICE" 2>/dev/null; then
        log_ok "服务启动成功"
    else
        log_error "服务启动失败，请检查: journalctl -u $HY2_SERVICE"
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo ""
        log_warn "检测到 UFW 防火墙已启用，请确保以下端口已开放:"
        echo "  - TCP/UDP 443"
        echo "  - UDP ${HY2_START_PORT}:${HY2_END_PORT}"
        echo ""
        echo "可使用以下命令:"
        echo "  ufw allow 443/tcp"
        echo "  ufw allow 443/udp"
        echo "  ufw allow ${HY2_START_PORT}:${HY2_END_PORT}/udp"
    fi

    echo ""
    echo -e "${CYAN}========== 配置完成 ==========${NC}"
    echo -e "服务器地址: ${GREEN}$server_ip:443${NC}"
    echo -e "认证密码:   ${GREEN}$auth_pass${NC}"
    echo -e "混淆密码:   ${GREEN}$obfs_pass${NC}"
    echo -e "伪装域名:   ${GREEN}$best_domain${NC}"
    echo -e "端口跳跃:   ${GREEN}${HY2_START_PORT}-${HY2_END_PORT}${NC}"
    echo -e "证书类型:   ${GREEN}自签名${NC}"
    echo ""
    press_enter
}

# ── 5.3 服务管理 ──
hy2_service_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}=== Hysteria2 服务管理 ===${NC}"
        echo ""

        if systemctl is-active --quiet "$HY2_SERVICE"; then
            echo -e "状态: ${GREEN}运行中${NC}"
        else
            echo -e "状态: ${RED}已停止${NC}"
        fi
        if systemctl is-enabled --quiet "$HY2_SERVICE" 2>/dev/null; then
            echo -e "自启: ${GREEN}已启用${NC}"
        else
            echo -e "自启: ${YELLOW}已禁用${NC}"
        fi
        echo ""
        echo "1. 启动服务"
        echo "2. 停止服务"
        echo "3. 重启服务"
        echo "4. 查看状态"
        echo "5. 查看日志"
        echo "6. 启用开机自启"
        echo "7. 禁用开机自启"
        echo "0. 返回"
        echo ""
        read -rp "请选择 [0-7]: " choice

        case "$choice" in
            1) systemctl start "$HY2_SERVICE" && log_ok "已启动" || log_error "启动失败" ;;
            2) systemctl stop "$HY2_SERVICE" && log_ok "已停止" || log_error "停止失败" ;;
            3) systemctl restart "$HY2_SERVICE" && log_ok "已重启" || log_error "重启失败" ;;
            4) systemctl status "$HY2_SERVICE" --no-pager -l ;;
            5) journalctl -u "$HY2_SERVICE" --no-pager -n 50 ;;
            6) systemctl enable "$HY2_SERVICE" && log_ok "已启用开机自启" ;;
            7) systemctl disable "$HY2_SERVICE" && log_ok "已禁用开机自启" ;;
            0) break ;;
            *) log_error "无效选项" ;;
        esac
        [[ "$choice" != "0" ]] && press_enter
    done
}

# ── 5.4 端口跳跃管理 ──
hy2_port_hopping_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}=== 端口跳跃管理 ===${NC}"
        echo ""

        local listen_port
        listen_port=$(hy2_get_listen_port)
        echo -e "监听端口: ${GREEN}$listen_port${NC}"

        if hy2_check_port_hopping; then
            echo -e "端口跳跃: ${GREEN}已启用 ($(hy2_get_port_hopping_info))${NC}"
        else
            echo -e "端口跳跃: ${YELLOW}未启用${NC}"
        fi
        echo ""
        echo "1. 启用端口跳跃"
        echo "2. 修改端口范围"
        echo "3. 禁用端口跳跃"
        echo "0. 返回"
        echo ""
        read -rp "请选择 [0-3]: " choice

        case "$choice" in
            1)
                if hy2_check_port_hopping; then
                    log_warn "端口跳跃已启用"
                else
                    local sp ep
                    read -rp "起始端口 [25000]: " sp
                    sp=${sp:-25000}
                    read -rp "结束端口 [26000]: " ep
                    ep=${ep:-26000}
                    if [[ "$sp" =~ ^[0-9]+$ ]] && [[ "$ep" =~ ^[0-9]+$ ]] && [[ "$sp" -lt "$ep" ]]; then
                        hy2_add_port_hopping "$sp" "$ep"
                    else
                        log_error "端口范围无效"
                    fi
                fi
                press_enter
                ;;
            2)
                if ! hy2_check_port_hopping; then
                    log_warn "端口跳跃未启用，请先启用"
                else
                    local sp ep
                    read -rp "新起始端口 [25000]: " sp
                    sp=${sp:-25000}
                    read -rp "新结束端口 [26000]: " ep
                    ep=${ep:-26000}
                    if [[ "$sp" =~ ^[0-9]+$ ]] && [[ "$ep" =~ ^[0-9]+$ ]] && [[ "$sp" -lt "$ep" ]]; then
                        hy2_clear_port_hopping
                        hy2_add_port_hopping "$sp" "$ep"
                    else
                        log_error "端口范围无效"
                    fi
                fi
                press_enter
                ;;
            3)
                if hy2_check_port_hopping; then
                    hy2_clear_port_hopping
                else
                    log_warn "端口跳跃未启用"
                fi
                press_enter
                ;;
            0) break ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}

# ── 5.5 查看配置 ──
hy2_view_config() {
    clear
    echo ""
    echo -e "${CYAN}=== 当前配置 ===${NC}"
    echo ""
    if [[ -f "$HY2_CONFIG" ]]; then
        cat "$HY2_CONFIG"
    else
        log_warn "配置文件不存在"
    fi
    press_enter
}

# ── 5.6 订阅链接 ──
hy2_subscription() {
    clear
    echo ""
    echo -e "${CYAN}=== 订阅链接 ===${NC}"
    echo ""

    if [[ ! -f "$HY2_CONFIG" ]]; then
        log_error "配置文件不存在"
        press_enter
        return
    fi

    local server_ip
    server_ip=$(public_ip)
    local config_info
    config_info=$(hy2_parse_config)
    IFS='|' read -r port auth_pass obfs_pass sni cert_type <<< "$config_info"

    local port_hopping=""
    if hy2_check_port_hopping; then
        port_hopping=$(hy2_get_port_hopping_info | grep -oE '[0-9]+-[0-9]+' | head -1)
    fi

    local fingerprint=""
    if [[ "$cert_type" == "self" ]] && [[ -f "$HY2_CERT" ]]; then
        fingerprint=$(hy2_get_cert_fingerprint)
    fi

    echo -e "服务器: ${GREEN}$server_ip:$port${NC}"
    echo -e "SNI:    ${GREEN}${sni:-未设置}${NC}"
    echo -e "跳跃:   ${GREEN}${port_hopping:-未配置}${NC}"
    [[ -n "$fingerprint" ]] && echo -e "指纹:   ${GREEN}$fingerprint${NC}"
    echo ""

    echo -e "${YELLOW}--- hysteria2:// 节点链接 ---${NC}"
    local enc_auth enc_obfs
    enc_auth=$(url_encode "$auth_pass")
    local link="hysteria2://${enc_auth}@${server_ip}:${port}"
    [[ -n "$port_hopping" ]] && link="hysteria2://${enc_auth}@${server_ip}:${port},${port_hopping}"
    local params=""
    [[ -n "$sni" ]] && params="${params}&sni=${sni}"
    [[ -n "$fingerprint" ]] && params="${params}&pinSHA256=${fingerprint}"
    if [[ -n "$obfs_pass" ]]; then
        enc_obfs=$(url_encode "$obfs_pass")
        params="${params}&obfs=salamander&obfs-password=${enc_obfs}"
    fi
    params="${params}&alpn=h3"
    params="${params#&}"
    [[ -n "$params" ]] && link="${link}?${params}"
    link="${link}#Hysteria2"
    echo "$link"
    echo ""

    echo -e "${YELLOW}--- Mihomo 配置 ---${NC}"
    cat << EOF
proxies:
  - name: "Hysteria2"
    type: hysteria2
    server: $server_ip
    port: $port
EOF
    [[ -n "$port_hopping" ]] && echo "    ports: $port_hopping" && echo '    hop-interval: "30s"'
    echo "    password: \"$auth_pass\""
    [[ -n "$obfs_pass" ]] && cat << EOF
    obfs: salamander
    obfs-password: "$obfs_pass"
EOF
    [[ -n "$sni" ]] && echo "    sni: $sni"
    echo "    skip-cert-verify: false"
    [[ -n "$fingerprint" ]] && echo "    fingerprint: $fingerprint"
    echo "    alpn:"
    echo "      - h3"
    echo ""

    press_enter
}

# ── 5.7 卸载 ──
hy2_uninstall() {
    clear
    echo ""
    echo -e "${RED}=== 卸载 Hysteria2 ===${NC}"
    echo ""

    if ! confirm "确定要卸载？这将删除所有配置和数据"; then
        log_info "已取消"
        press_enter
        return
    fi

    systemctl stop "$HY2_SERVICE" 2>/dev/null
    systemctl disable "$HY2_SERVICE" 2>/dev/null
    hy2_clear_port_hopping 2>/dev/null || true
    rm -f /etc/systemd/system/hysteria-port-hopping.service
    rm -rf /etc/hysteria
    rm -f "$HY2_BIN"
    rm -f /etc/systemd/system/hysteria-server.service
    rm -f /etc/systemd/system/hysteria-server@.service
    rm -f /lib/systemd/system/hysteria-server.service
    rm -f /lib/systemd/system/hysteria-server@.service
    rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service
    rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service
    rm -f /var/log/hysteria*.log
    systemctl daemon-reload 2>/dev/null
    log_ok "卸载完成"
    press_enter
}

hy2_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║        Hysteria2 代理管理            ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"

        if [[ -x "$HY2_BIN" ]]; then
            echo -e "${CYAN}║  程序: ${GREEN}已安装${NC}                        ${CYAN}║${NC}"
        else
            echo -e "${CYAN}║  程序: ${RED}未安装${NC}                        ${CYAN}║${NC}"
        fi

        if systemctl is-active --quiet "$HY2_SERVICE" 2>/dev/null; then
            echo -e "${CYAN}║  服务: ${GREEN}运行中${NC}                        ${CYAN}║${NC}"
        else
            echo -e "${CYAN}║  服务: ${RED}未运行${NC}                        ${CYAN}║${NC}"
        fi

        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║  1. 安装                             ║${NC}"
        echo -e "${CYAN}║  2. 一键快速配置                     ║${NC}"
        echo -e "${CYAN}║  3. 服务管理                         ║${NC}"
        echo -e "${CYAN}║  4. 端口跳跃管理                     ║${NC}"
        echo -e "${CYAN}║  5. 查看配置                         ║${NC}"
        echo -e "${CYAN}║  6. 订阅链接                         ║${NC}"
        echo -e "${CYAN}║  7. 卸载                             ║${NC}"
        echo -e "${CYAN}║  0. 返回主菜单                       ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        read -rp "请选择 [0-7]: " choice

        case "$choice" in
            1) hy2_install ;;
            2) hy2_quick_config ;;
            3) hy2_service_menu ;;
            4) hy2_port_hopping_menu ;;
            5) hy2_view_config ;;
            6) hy2_subscription ;;
            7) hy2_uninstall ;;
            0) break ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}
