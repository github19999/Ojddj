#!/bin/bash
# ================================================================
#   服务器一键管理脚本 (jddj)
#   集成：SSH安全加固 / SSL证书 / sing-box 安装配置 / 节点生成
# ================================================================

# ────────────────────────────────────────────────────────────────
#  颜色 & 日志
# ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }

press_enter() { echo ""; read -rp "$(echo -e "${CYAN}按 Enter 返回...${NC}")"; }

# ────────────────────────────────────────────────────────────────
#  Root 检查
# ────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行，请使用 sudo 或切换到 root 用户"
        exit 1
    fi
}

# ────────────────────────────────────────────────────────────────
#  发行版检测
# ────────────────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID%%.*}"
        PRETTY_NAME_CACHED="${PRETTY_NAME:-$DISTRO_ID}"
    else
        log_error "无法识别操作系统"
        exit 1
    fi

    case "$DISTRO_ID" in
        ubuntu|debian|raspbian) PKG_MANAGER="apt" ;;
        centos|rhel|almalinux|rocky|fedora)
            PKG_MANAGER="yum"
            command -v dnf &>/dev/null && PKG_MANAGER="dnf"
            ;;
        *) log_warn "未经测试的发行版: $DISTRO_ID，尝试使用 apt"; PKG_MANAGER="apt" ;;
    esac
}

# ────────────────────────────────────────────────────────────────
#  随机生成工具函数
# ────────────────────────────────────────────────────────────────
gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

gen_password() {
    local length="${1:-24}"
    tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c "$length" 2>/dev/null || \
    python3 -c "import secrets,string; print(secrets.token_urlsafe($length))"
}

gen_ss2022_key_256() { openssl rand -base64 32; }
gen_ss2022_key_128() { openssl rand -base64 16; }

gen_reality_keypair() {
    if command -v sing-box &>/dev/null; then
        sing-box generate reality-keypair 2>/dev/null
    else
        # 用 openssl 模拟生成（Ed25519 base64url）
        local privkey pubkey
        privkey=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
        pubkey=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
        echo "PrivateKey: ${privkey}"
        echo "PublicKey:  ${pubkey}"
    fi
}

gen_short_id() { openssl rand -hex 4; }

gen_naive_username() {
    # NaïveProxy 用户名：只含字母数字，8-16位
    tr -dc 'a-z0-9' </dev/urandom | head -c 12 2>/dev/null || echo "naiveuser$(shuf -i 1000-9999 -n1)"
}

# ────────────────────────────────────────────────────────────────
#  旧 ask() 保留给 ask_cert_paths 兼容调用（内部用 ask_val 实现）
# ────────────────────────────────────────────────────────────────
ask() {
    local prompt="$1" default="$2"
    ask_val REPLY_VAL "$prompt" "$default"
}

# ────────────────────────────────────────────────────────────────
#  读取已安装证书域名
# ────────────────────────────────────────────────────────────────
get_cert_domains() {
    local domains=()
    # acme.sh 证书：扫描 ~/.acme.sh/<domain>/<domain>.cer
    if [[ -d /root/.acme.sh ]]; then
        while IFS= read -r dir; do
            local d
            d=$(basename "$dir")
            [[ -z "$d" || "$d" == "__INTERACT__" || "$d" == "ca" || "$d" == "account.conf" ]] && continue
            [[ -d "$dir" ]] && domains+=("$d")
        done < <(find /root/.acme.sh -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi
    # /etc/ssl/private 和常见路径下的证书文件（读取 CN）
    while IFS= read -r crt; do
        [[ -z "$crt" ]] && continue
        local cn
        cn=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | grep -oP '(?<=CN\s=\s)[^,/]+' | head -1)
        [[ -n "$cn" ]] && domains+=("$cn")
    done < <(find /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl 2>/dev/null         \( -name "*.crt" -o -name "fullchain.cer" -o -name "*.pem" \) | head -20)
    # 去重并过滤系统自带的无效条目
    printf '%s
' "${domains[@]}" | sort -u | grep -v '^\*' | grep '\.' || true
}

# ────────────────────────────────────────────────────────────────
#  ══════════════════════════════════════════════════════════════
#  一、基础安全设置
#  ══════════════════════════════════════════════════════════════
# ────────────────────────────────────────────────────────────────

bootstrap_packages() {
    log_step "预装基础组件"
    if command -v apt &>/dev/null; then
        apt update -y && apt install -y curl sudo wget git unzip nano vim openssl
    elif command -v dnf &>/dev/null; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y curl sudo wget git unzip nano vim openssl
    elif command -v yum &>/dev/null; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl sudo wget git unzip nano vim openssl
    fi
    log_success "基础组件已就绪"
}

# 1. SSH 密钥登录
setup_ssh_key() {
    echo ""
    log_step "配置 SSH 密钥登录"
    echo "请输入你的 SSH 公钥（以 ssh-rsa / ssh-ed25519 / ecdsa-sha2 开头）:"
    read -r PUBLIC_KEY

    if [[ -z "$PUBLIC_KEY" ]]; then
        log_error "公钥不能为空"; return 1
    fi
    if [[ ! "$PUBLIC_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519) ]]; then
        log_warn "公钥格式可能不正确，但继续执行..."
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    chown root:root /root/.ssh

    if ! grep -qF "$PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
        log_success "公钥已添加"
    else
        log_info "公钥已存在，跳过"
    fi

    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh/authorized_keys

    command -v restorecon &>/dev/null && restorecon -Rv /root/.ssh/ >/dev/null 2>&1 && log_info "SELinux 上下文已修复"
    log_success "SSH 密钥登录配置完成"
}

# 2. 禁用密码登录
disable_password_login() {
    log_step "禁用 SSH 密码登录"
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"

    sshd_set() {
        local key="$1" val="$2"
        if grep -qE "^#?\s*${key}\s" "$SSHD_CONFIG"; then
            sed -i "s|^#\?\s*${key}\s.*|${key} ${val}|" "$SSHD_CONFIG"
        else
            echo "${key} ${val}" >> "$SSHD_CONFIG"
        fi
    }

    sshd_set "PasswordAuthentication" "no"
    sshd_set "ChallengeResponseAuthentication" "no"
    sshd_set "KbdInteractiveAuthentication" "no"
    sshd_set "PubkeyAuthentication" "yes"
    sshd_set "AuthorizedKeysFile" ".ssh/authorized_keys"
    sshd_set "PermitRootLogin" "prohibit-password"

    if sshd -t 2>&1; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        log_success "SSH 密码登录已禁用"
    else
        log_error "SSH 配置语法错误，请检查配置文件"
    fi
}

# 3. 修改 SSH 端口
change_ssh_port() {
    log_step "修改 SSH 端口"
    local current_port
    current_port=$(grep -E "^Port\s" /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    current_port="${current_port:-22}"
    echo "当前 SSH 端口: $current_port"
    echo -n "请输入新端口（1024-65535，默认 43916）: "
    read -r SSH_PORT
    [[ -z "$SSH_PORT" ]] && SSH_PORT=43916

    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ $SSH_PORT -lt 1024 || $SSH_PORT -gt 65535 ]]; then
        log_error "端口范围应在 1024-65535"; return 1
    fi

    local SSHD_CONFIG="/etc/ssh/sshd_config"
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    sed -i 's/^Port\s/#Port /' "$SSHD_CONFIG"
    grep -q "^Port $SSH_PORT" "$SSHD_CONFIG" || echo "Port $SSH_PORT" >> "$SSHD_CONFIG"

    if sshd -t 2>&1; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        log_success "SSH 端口已修改为: $SSH_PORT"
        log_warn "⚠  请确保防火墙已放行端口 $SSH_PORT"
    else
        log_error "SSH 配置语法错误，已还原备份"
    fi
}

# 4. 启用 BBR
enable_bbr() {
    log_step "启用 BBR 拥塞控制"
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        log_success "BBR 已启用，跳过"; return
    fi

    local kv
    kv=$(uname -r | cut -d. -f1-2 | tr -d '.')
    if [[ "$kv" -lt 49 ]] 2>/dev/null; then
        log_warn "内核版本低于 4.9，BBR 不受支持"; return
    fi

    grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    log_success "BBR 启用成功"
}

# 5. IP 协议优先级 & 禁用
configure_ip_protocol() {
    echo ""
    echo -e "${CYAN}── IP 协议优先级 ──${NC}"
    echo "1) IPv4 优先 [默认]"
    echo "2) IPv6 优先"
    echo "3) 保持不变"
    read -rp "请选择 (1-3): " c; c=${c:-1}
    case $c in
        1)
            if [[ -f /etc/gai.conf ]]; then
                cp /etc/gai.conf "/etc/gai.conf.backup.$(date +%Y%m%d_%H%M%S)"
                if grep -q "^#\s*precedence ::ffff:0:0/96" /etc/gai.conf; then
                    sed -i 's/^#\s*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
                elif ! grep -q "^precedence ::ffff:0:0/96" /etc/gai.conf; then
                    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
                fi
                log_success "IPv4 优先已设置"
            fi ;;
        2)
            [[ -f /etc/gai.conf ]] && sed -i 's/^precedence ::ffff:0:0\/96/#precedence ::ffff:0:0\/96/' /etc/gai.conf
            log_success "IPv6 优先已设置" ;;
        3) log_info "IP 协议优先级保持不变" ;;
    esac

    echo ""
    echo -e "${CYAN}── IP 协议禁用 ──${NC}"
    echo "1) 禁用 IPv6"
    echo "2) 禁用 IPv4（危险操作）"
    echo "3) 保持不变 [默认]"
    read -rp "请选择 (1-3): " d; d=${d:-3}
    local SYSCTL_D="/etc/sysctl.d"; mkdir -p "$SYSCTL_D"
    case $d in
        1)
            local f="$SYSCTL_D/99-disable-ipv6.conf"
            [[ ! -f "$f" ]] && cat > "$f" << 'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
            sysctl -p "$f" >/dev/null 2>&1
            log_success "IPv6 已禁用" ;;
        2)
            log_warn "警告：禁用 IPv4 可能导致服务器断联！"
            read -rp "确认禁用 IPv4？(y/N): " confirm
            if [[ "${confirm,,}" == "y" ]]; then
                cat > "$SYSCTL_D/99-disable-ipv4.conf" << 'EOF'
net.ipv4.conf.all.disable_ipv4=1
net.ipv4.conf.default.disable_ipv4=1
EOF
                log_warn "IPv4 禁用配置已写入，重启后生效"
            else
                log_info "已取消"
            fi ;;
        3) log_info "IP 协议状态保持不变" ;;
    esac
}

# 6. 安装配置 fail2ban
setup_fail2ban() {
    log_step "安装并配置 fail2ban"
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt install -y fail2ban || { log_warn "fail2ban 安装失败"; return; }
    else
        $PKG_MANAGER install -y fail2ban || { log_warn "fail2ban 安装失败"; return; }
    fi

    local SSH_PORT_CURRENT
    SSH_PORT_CURRENT=$(grep -E "^Port\s" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    SSH_PORT_CURRENT="${SSH_PORT_CURRENT:-22}"

    local BACKEND LOGPATH=""
    if systemctl is-active --quiet systemd-journald 2>/dev/null; then
        BACKEND="systemd"
    else
        BACKEND="auto"
        for lp in /var/log/auth.log /var/log/secure; do
            [[ -f "$lp" ]] && LOGPATH="logpath = $lp" && break
        done
        [[ -z "$LOGPATH" ]] && LOGPATH="logpath = /var/log/auth.log"
    fi

    systemctl stop fail2ban 2>/dev/null || true
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = -1
findtime = 300
maxretry = 1

[sshd]
enabled  = true
port     = $SSH_PORT_CURRENT
backend  = $BACKEND
${LOGPATH}
maxretry = 1
findtime = 300
bantime  = -1
EOF
    sleep 1
    systemctl enable fail2ban && systemctl start fail2ban
    systemctl is-active --quiet fail2ban && log_success "fail2ban 启动成功" || log_warn "fail2ban 启动失败，请检查日志"
}

# 基础设置菜单
menu_basic() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 一、基础安全设置 ══${NC}"
        echo ""
        echo "  1) SSH 密钥登录"
        echo "  2) 禁用密码登录"
        echo "  3) 修改 SSH 端口"
        echo "  4) 启用 BBR 拥塞控制"
        echo "  5) IP 协议优先级 & 禁用"
        echo "  6) 安装配置 fail2ban"
        echo "  7) 全部执行 (1→6)"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择: " opt
        case $opt in
            1) setup_ssh_key; press_enter ;;
            2) disable_password_login; press_enter ;;
            3) change_ssh_port; press_enter ;;
            4) enable_bbr; press_enter ;;
            5) configure_ip_protocol; press_enter ;;
            6) setup_fail2ban; press_enter ;;
            7)
                bootstrap_packages
                setup_ssh_key
                disable_password_login
                change_ssh_port
                enable_bbr
                configure_ip_protocol
                setup_fail2ban
                press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  ══════════════════════════════════════════════════════════════
#  二、SSL 证书
#  ══════════════════════════════════════════════════════════════
# ────────────────────────────────────────────────────────────────

STOPPED_SERVICES_SSL=()

manage_web_services_ssl() {
    local action="$1"
    if [[ "$action" == "stop" ]]; then
        local port_info=""
        command -v ss &>/dev/null && port_info=$(ss -tlnp | grep ":80 " 2>/dev/null) || true
        command -v netstat &>/dev/null && [[ -z "$port_info" ]] && port_info=$(netstat -tlnp | grep ":80 " 2>/dev/null) || true
        if [[ -n "$port_info" ]]; then
            for svc in nginx apache2 httpd lighttpd; do
                systemctl is-active --quiet "$svc" 2>/dev/null && {
                    systemctl stop "$svc" && STOPPED_SERVICES_SSL+=("$svc") && log_info "已停止: $svc"
                }
            done
        fi
    elif [[ "$action" == "start" ]]; then
        for svc in "${STOPPED_SERVICES_SSL[@]:-}"; do
            [[ -n "$svc" ]] && systemctl start "$svc" 2>/dev/null && log_info "已启动: $svc"
        done
        STOPPED_SERVICES_SSL=()
    fi
}

deploy_ssl() {
    log_step "SSL 证书申请与安装"

    # 安装依赖
    local packages=""
    [[ "$PKG_MANAGER" == "apt" ]] && packages="curl wget socat cron openssl ca-certificates" || packages="curl wget socat cronie openssl ca-certificates"
    $PKG_MANAGER install -y $packages >/dev/null 2>&1 || true

    # 启动 cron
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        systemctl enable cron >/dev/null 2>&1 && systemctl start cron >/dev/null 2>&1 || true
    else
        systemctl enable crond >/dev/null 2>&1 && systemctl start crond >/dev/null 2>&1 || true
    fi

    # 域名输入
    echo ""
    echo "请输入要申请 SSL 证书的域名（多个用空格分隔）:"
    echo "示例: example.com www.example.com"
    read -r DOMAINS_INPUT
    [[ -z "$DOMAINS_INPUT" ]] && { log_error "域名不能为空"; return 1; }
    read -ra SSL_DOMAINS <<< "$DOMAINS_INPUT"
    local MAIN_DOMAIN="${SSL_DOMAINS[0]}"

    echo ""
    echo "域名列表: ${SSL_DOMAINS[*]}"
    echo "主域名:   $MAIN_DOMAIN"
    echo ""

    # 证书路径
    echo "证书存储路径:"
    echo "  1) /etc/ssl/private/ [默认]"
    echo "  2) /etc/nginx/ssl/"
    echo "  3) /etc/apache2/ssl/"
    echo "  4) 自定义"
    read -rp "请选择 (1-4): " pc; pc=${pc:-1}
    local CERT_DIR
    case $pc in
        1) CERT_DIR="/etc/ssl/private" ;;
        2) CERT_DIR="/etc/nginx/ssl" ;;
        3) CERT_DIR="/etc/apache2/ssl" ;;
        4) read -rp "请输入路径: " CERT_DIR ;;
        *) CERT_DIR="/etc/ssl/private" ;;
    esac
    mkdir -p "$CERT_DIR" && chmod 755 "$CERT_DIR"

    # 安装 acme.sh
    if [[ ! -f /root/.acme.sh/acme.sh ]]; then
        log_step "安装 acme.sh..."
        # 下载 acme.sh 主程序（不是 get.acme.sh 包装脚本）
        local acme_installer="/tmp/acme_install_$$.sh"
        if ! curl -fsSL "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"                 -o "$acme_installer" 2>/dev/null; then
            wget -qO "$acme_installer"                 "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" 2>/dev/null || {
                rm -f "$acme_installer"
                log_error "acme.sh 下载失败"
                return 1
            }
        fi
        chmod +x "$acme_installer"
        # --install-online 让 acme.sh 自己下载完整包并安装
        # --nocron 跳过 crontab 检查（脚本后续单独配置）
        bash "$acme_installer" --install-online --nocron
        local acme_ret=$?
        rm -f "$acme_installer"
        if [[ $acme_ret -ne 0 ]] || [[ ! -f /root/.acme.sh/acme.sh ]]; then
            log_error "acme.sh 安装失败"
            return 1
        fi
    else
        log_info "acme.sh 已存在，检查更新..."
        /root/.acme.sh/acme.sh --upgrade >/dev/null 2>&1 || true
    fi
    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh 2>/dev/null || true
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    log_success "acme.sh 已就绪"

    # 停止 Web 服务
    manage_web_services_ssl "stop"

    # 申请证书
    log_step "申请证书..."
    local domain_args=""
    for d in "${SSL_DOMAINS[@]}"; do domain_args="$domain_args -d $d"; done

    if /root/.acme.sh/acme.sh --issue $domain_args --standalone --force; then
        log_success "证书申请成功"
    else
        log_error "证书申请失败"
        manage_web_services_ssl "start"
        return 1
    fi

    # 安装证书
    local KEY_FILE="$CERT_DIR/private.key"
    local CERT_FILE="$CERT_DIR/fullchain.cer"
    local CA_FILE="$CERT_DIR/ca.cer"

    # 检测运行中的 Web 服务用于 Hook
    local DETECTED_SVC="" PRE_HOOK="" POST_HOOK="" RELOAD_CMD="echo 'cert installed'"
    for svc in nginx apache2 httpd lighttpd; do
        systemctl is-active --quiet "$svc" 2>/dev/null && {
            DETECTED_SVC="$svc"
            PRE_HOOK="systemctl stop $svc"
            POST_HOOK="systemctl start $svc"
            RELOAD_CMD="systemctl reload $svc"
            break
        }
    done

    /root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" \
        --ca-file "$CA_FILE" \
        --reloadcmd "$RELOAD_CMD" || { log_error "证书安装失败"; return 1; }

    chmod 600 "$KEY_FILE" 2>/dev/null || true
    chmod 644 "$CERT_FILE" "$CA_FILE" 2>/dev/null || true

    # 写入 Pre/Post Hook
    if [[ -n "$PRE_HOOK" ]]; then
        local CONF_FILE="/root/.acme.sh/${MAIN_DOMAIN}/${MAIN_DOMAIN}.conf"
        if [[ -f "$CONF_FILE" ]] && ! grep -q "Le_PreHook" "$CONF_FILE"; then
            echo "Le_PreHook='$PRE_HOOK'" >> "$CONF_FILE"
            echo "Le_PostHook='$POST_HOOK'" >> "$CONF_FILE"
            log_success "续期 Hook 已配置（自动停启 $DETECTED_SVC）"
        fi
    fi

    # 自动续期
    if ! crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        (crontab -l 2>/dev/null; echo "0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> /var/log/acme-renew.log 2>&1") | crontab -
        log_success "自动续期任务已设置（每天 02:00）"
    fi

    manage_web_services_ssl "start"

    echo ""
    log_success "SSL 证书部署完成！"
    echo "  证书目录: $CERT_DIR"
    echo "  私钥:     $KEY_FILE"
    echo "  全链证书: $CERT_FILE"
    if [[ -f "$CERT_FILE" ]]; then
        local exp
        exp=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
        echo "  有效期至: $exp"
    fi
}

menu_ssl() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 二、SSL 证书 ══${NC}"
        echo ""
        echo "  1) 申请并安装 SSL 证书"
        echo "  2) 查看已安装证书"
        echo "  3) 手动续期证书"
        echo "  4) 查看续期日志"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择: " opt
        case $opt in
            1) deploy_ssl; press_enter ;;
            2) /root/.acme.sh/acme.sh --list 2>/dev/null || log_warn "acme.sh 未安装"; press_enter ;;
            3)
                echo "输入要续期的域名:"
                read -r rd
                /root/.acme.sh/acme.sh --renew -d "$rd" --force 2>/dev/null || log_warn "续期失败"
                press_enter ;;
            4) tail -f /var/log/acme-renew.log 2>/dev/null || log_warn "日志文件不存在"; press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  ══════════════════════════════════════════════════════════════
#  三、安装 sing-box
#  ══════════════════════════════════════════════════════════════
# ────────────────────────────────────────────────────────────────

install_singbox() {
    clear
    echo -e "${BOLD}${CYAN}══ 三、安装 sing-box ══${NC}"
    echo ""
    echo "  1) Latest 稳定版 [默认]"
    echo "  2) 指定版本号"
    echo "  3) Beta / 预发布版"
    echo ""
    read -rp "请选择 (1-3): " vc; vc=${vc:-1}

    case $vc in
        1)
            log_step "安装 sing-box 最新稳定版..."
            bash <(curl -fsSL https://sing-box.app/deb-install.sh) || \
            bash <(curl -fsSL https://sing-box.app/rpm-install.sh) || \
            { log_error "安装失败，请检查网络或手动安装"; press_enter; return; }
            ;;
        2)
            echo -n "请输入版本号（例如 1.9.0）: "
            read -r SB_VER
            [[ -z "$SB_VER" ]] && { log_error "版本号不能为空"; press_enter; return; }
            log_step "安装 sing-box v${SB_VER}..."
            # 通过 GitHub Releases 安装
            local ARCH
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64) ARCH_STR="amd64" ;;
                aarch64) ARCH_STR="arm64" ;;
                armv7l) ARCH_STR="armv7" ;;
                *) ARCH_STR="amd64" ;;
            esac
            local URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${ARCH_STR}.tar.gz"
            curl -fsSL "$URL" -o /tmp/sing-box.tar.gz || { log_error "下载失败"; press_enter; return; }
            tar -xzf /tmp/sing-box.tar.gz -C /tmp/
            install -m 755 "/tmp/sing-box-${SB_VER}-linux-${ARCH_STR}/sing-box" /usr/local/bin/sing-box
            rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SB_VER}-linux-${ARCH_STR}"
            ;;
        3)
            log_step "安装 sing-box Beta 版..."
            bash <(curl -fsSL https://sing-box.app/deb-install.sh) beta || \
            { log_error "Beta 安装失败"; press_enter; return; }
            ;;
    esac

    # 初始化目录
    mkdir -p /etc/sing-box /var/log/sing-box

    # 创建 systemd service（若不存在）
    if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
        cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    if command -v sing-box &>/dev/null; then
        local ver
        ver=$(sing-box version 2>/dev/null | head -1)
        log_success "sing-box 安装成功: $ver"
    else
        log_error "sing-box 安装失败"
    fi
    press_enter
}

# ────────────────────────────────────────────────────────────────
#  ══════════════════════════════════════════════════════════════
#  四、配置 sing-box
#  ══════════════════════════════════════════════════════════════
# ────────────────────────────────────────────────────────────────

# 选择 server_name（优先读取已装证书，未找到则手动输入）
select_server_name() {
    local default_sn="${1:-example.com}"
    echo ""
    local domains=()
    mapfile -t domains < <(get_cert_domains 2>/dev/null)

    if [[ ${#domains[@]} -gt 0 ]]; then
        echo -e "  \033[0;36m已检测到以下证书域名：\033[0m"
        for i in "${!domains[@]}"; do
            echo "    $((i+1))) ${domains[$i]}"
        done
        local manual_idx=$(( ${#domains[@]} + 1 ))
        echo "    ${manual_idx}) 手动输入"
        echo ""
        local sn_choice
        read -rp "  请选择 server_name（输入编号）: " sn_choice
        sn_choice="${sn_choice:-1}"
        if [[ "$sn_choice" =~ ^[0-9]+$ ]] && [[ "$sn_choice" -ge 1 ]] && [[ "$sn_choice" -le "${#domains[@]}" ]]; then
            SELECTED_SN="${domains[$((sn_choice-1))]}"
            echo -e "  \033[0;32m→ 使用证书域名: ${SELECTED_SN}\033[0m"
        else
            read -rp "  请手动输入 server_name（默认 ${default_sn}）: " SELECTED_SN
            SELECTED_SN="${SELECTED_SN:-$default_sn}"
            echo -e "  \033[0;32m→ server_name: ${SELECTED_SN}\033[0m"
        fi
    else
        echo "  （未检测到已安装证书，请手动输入）"
        read -rp "  请输入 server_name（默认 ${default_sn}）: " SELECTED_SN
        SELECTED_SN="${SELECTED_SN:-$default_sn}"
        echo -e "  \033[0;32m→ server_name: ${SELECTED_SN}\033[0m"
    fi
}

# ────────────────────────────────────────────────────────────────
#  通用输入函数：打印提示、显示默认值、回车后回显实际使用值
#  用法: ask_val <变量名> <提示文字> <默认值>
#  结果存入变量名中
# ────────────────────────────────────────────────────────────────
ask_val() {
    local varname="$1"
    local prompt="$2"
    local default="$3"
    local input
    read -rp "  ${prompt} [${default}]: " input
    local result="${input:-$default}"
    # 回车使用默认时，绿色回显实际值
    if [[ -z "$input" ]]; then
        echo -e "  ${GREEN}→ ${result}${NC}"
    fi
    # 将结果写入调用方指定的变量
    printf -v "$varname" '%s' "$result"
}

# 随机值输入：先显示随机值供参考，回车使用，或手动覆盖
# 用法: ask_random <变量名> <提示文字> <随机值>
ask_random() {
    local varname="$1"
    local prompt="$2"
    local randval="$3"
    local input
    echo -e "  ${YELLOW}${prompt}${NC}"
    echo -e "  随机生成: ${CYAN}${randval}${NC}"
    read -rp "  直接回车使用随机值，或输入自定义值: " input
    local result="${input:-$randval}"
    echo -e "  ${GREEN}→ ${result}${NC}"
    printf -v "$varname" '%s' "$result"
}

# 询问证书路径（server_name 已选定后调用，结果存入 CERT_PATH / KEY_PATH）
ask_cert_paths() {
    local sn="$1"
    # 尝试自动定位证书文件
    local auto_cert="" auto_key=""
    for d in /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/${sn}.crt"       ]] && auto_cert="$d/${sn}.crt"       && break
        [[ -f "$d/fullchain.cer"   ]] && auto_cert="$d/fullchain.cer"   && break
        [[ -f "$d/${sn}/fullchain.cer" ]] && auto_cert="$d/${sn}/fullchain.cer" && break
    done
    for d in /etc/ssl/private /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/${sn}.key"   ]] && auto_key="$d/${sn}.key"   && break
        [[ -f "$d/private.key" ]] && auto_key="$d/private.key" && break
    done
    # acme.sh 路径
    [[ -z "$auto_cert" && -f "/root/.acme.sh/${sn}/fullchain.cer" ]] && auto_cert="/root/.acme.sh/${sn}/fullchain.cer"
    [[ -z "$auto_key"  && -f "/root/.acme.sh/${sn}/${sn}.key"     ]] && auto_key="/root/.acme.sh/${sn}/${sn}.key"

    local default_cert="${auto_cert:-/etc/ssl/private/${sn}.crt}"
    local default_key="${auto_key:-/etc/ssl/private/${sn}.key}"

    ask_val CERT_PATH "cert_path" "$default_cert"
    ask_val KEY_PATH  "key_path"  "$default_key"
}

# ────────────────────────────────────────────────────────────────
#  构建 inbound JSON 片段
# ────────────────────────────────────────────────────────────────

# 1. VLESS TCP / XTLS-Vision
build_vless_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — TCP / XTLS-Vision ───${NC}"
    local tag port uuid uname fc
    ask_val   tag   "tag"       "vless-tcp-in"
    ask_val   port  "listen_port" "1443"
    ask_random uuid "uuid" "$(gen_uuid)"
    ask_val   uname "用户名 name" "user-vless-tcp"
    echo -e "  flow:"
    echo    "    1) xtls-rprx-vision [默认]"
    echo    "    2) 无（普通 TCP）"
    ask_val fc "请选择" "1"
    local flow; [[ "$fc" == "2" ]] && flow='"flow": ""' || flow='"flow": "xtls-rprx-vision"'
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "$uname", "uuid": "$uuid", $flow}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      },
      "multiplex": {"enabled": false}
    }
EOF
}

# 2. VLESS WebSocket
build_vless_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — WebSocket ───${NC}"
    local tag port uuid wspath
    ask_val   tag    "tag"         "vless-ws-in"
    ask_val   port   "listen_port" "8443"
    ask_random uuid  "uuid"        "$(gen_uuid)"
    ask_val   wspath "ws path"     "/vless-ws"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vless-ws", "uuid": "$uuid", "flow": ""}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "ws",
        "path": "$wspath",
        "headers": {"Host": "$sn"},
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
EOF
}

# 3. VLESS gRPC
build_vless_grpc() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — gRPC ───${NC}"
    local tag port uuid svcname
    ask_val   tag     "tag"          "vless-grpc-in"
    ask_val   port    "listen_port"  "8444"
    ask_random uuid   "uuid"         "$(gen_uuid)"
    ask_val   svcname "service_name" "vless-grpc-service"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vless-grpc", "uuid": "$uuid", "flow": ""}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2"]
      },
      "transport": {
        "type": "grpc",
        "service_name": "$svcname",
        "idle_timeout": "15s",
        "ping_timeout": "15s"
      }
    }
EOF
}

# 4. VLESS REALITY
build_vless_reality() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — REALITY ───${NC}"
    local port uuid pk si sn

    ask_val port "listen_port" "443"
    ask_random uuid "uuid" "$(gen_uuid)"

    echo ""
    echo -e "  ${YELLOW}正在生成 REALITY 密钥对...${NC}"
    local keypair_out privkey pubkey sid_rand
    keypair_out=$(gen_reality_keypair)
    privkey=$(echo "$keypair_out" | grep -i private | awk '{print $NF}')
    pubkey=$(echo  "$keypair_out" | grep -i public  | awk '{print $NF}')
    sid_rand=$(gen_short_id)

    ask_random pk  "private_key" "$privkey"
    ask_random si  "short_id"    "$sid_rand"

    echo ""
    echo -e "  ${GREEN}★ 客户端需要的 public_key（请复制保存）:${NC}"
    echo -e "  ${BOLD}${CYAN}  $pubkey${NC}"
    echo ""

    echo -e "  server_name（REALITY 伪装域名，无需拥有，使用公网可访问的域名即可）:"
    ask_val sn "server_name" "www.microsoft.com"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": $port,
      "users": [{"uuid": "$uuid", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "reality": {
          "enabled": true,
          "handshake": {"server": "127.0.0.1", "server_port": 8001},
          "private_key": "$pk",
          "short_id": ["$si"]
        }
      }
    }
EOF
}

# 5. VMess TCP
build_vmess_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VMess — TCP (TLS) ───${NC}"
    local tag port uuid
    ask_val   tag  "tag"         "vmess-tcp-in"
    ask_val   port "listen_port" "9443"
    ask_random uuid "uuid"       "$(gen_uuid)"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vmess",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vmess-tcp", "uuid": "$uuid", "alterId": 0}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      }
    }
EOF
}

# 6. VMess WebSocket
build_vmess_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VMess — WebSocket (TLS) ───${NC}"
    local tag port uuid wspath
    ask_val   tag    "tag"         "vmess-ws-in"
    ask_val   port   "listen_port" "9444"
    ask_random uuid  "uuid"        "$(gen_uuid)"
    ask_val   wspath "ws path"     "/vmess-ws"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vmess",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vmess-ws", "uuid": "$uuid", "alterId": 0}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "ws",
        "path": "$wspath",
        "headers": {"Host": "$sn"}
      }
    }
EOF
}

# 7. Trojan TCP
build_trojan_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Trojan — TCP (TLS) ───${NC}"
    local tag port pwd uname
    ask_val   tag   "tag"          "trojan-tcp-in"
    ask_val   port  "listen_port"  "10443"
    ask_random pwd  "password"     "$(gen_password 20)"
    ask_val   uname "用户名 name"  "user-trojan-tcp"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "$uname", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      },
      "fallback": {"server": "127.0.0.1", "server_port": 80}
    }
EOF
}

# 8. Trojan WebSocket
build_trojan_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Trojan — WebSocket (TLS) ───${NC}"
    local tag port pwd wspath
    ask_val   tag    "tag"         "trojan-ws-in"
    ask_val   port   "listen_port" "10444"
    ask_random pwd   "password"    "$(gen_password 20)"
    ask_val   wspath "ws path"     "/trojan-ws"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-trojan-ws", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "ws",
        "path": "$wspath",
        "headers": {"Host": "$sn"}
      }
    }
EOF
}

# 9. Shadowsocks 经典
build_ss_classic() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks — 经典加密 ───${NC}"
    local tag port mc pwd
    ask_val tag  "tag"         "ss-aes-in"
    ask_val port "listen_port" "11001"
    echo -e "  加密方式:"
    echo    "    1) aes-256-gcm [默认]"
    echo    "    2) aes-128-gcm"
    echo    "    3) chacha20-ietf-poly1305"
    ask_val mc "请选择" "1"
    local method
    case $mc in 2) method="aes-128-gcm" ;; 3) method="chacha20-ietf-poly1305" ;; *) method="aes-256-gcm" ;; esac
    echo -e "  ${GREEN}→ 加密方式: ${method}${NC}"
    ask_random pwd "password" "$(gen_password 20)"

    cat > "$_jf" << EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "method": "$method",
      "password": "$pwd",
      "multiplex": {"enabled": true, "padding": false}
    }
EOF
}

# 10. Shadowsocks 2022-256
build_ss2022_256() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks 2022 — aes-256-gcm ───${NC}"
    local tag port spwd upwd uname
    ask_val   tag   "tag"         "ss-2022-256-in"
    ask_val   port  "listen_port" "11002"
    ask_random spwd "server password (base64-32B)" "$(gen_ss2022_key_256)"
    ask_random upwd "user password (base64-32B)"   "$(gen_ss2022_key_256)"
    ask_val   uname "用户名 name" "user-ss-2022-256"

    cat > "$_jf" << EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "method": "2022-blake3-aes-256-gcm",
      "password": "$spwd",
      "users": [{"name": "$uname", "password": "$upwd"}],
      "multiplex": {"enabled": true, "padding": true}
    }
EOF
}

# 11. Shadowsocks 2022-128
build_ss2022_128() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks 2022 — aes-128-gcm ───${NC}"
    local tag port spwd upwd
    ask_val   tag  "tag"         "ss-2022-128-in"
    ask_val   port "listen_port" "11003"
    ask_random spwd "server password (base64-16B)" "$(gen_ss2022_key_128)"
    ask_random upwd "user password (base64-16B)"   "$(gen_ss2022_key_128)"

    cat > "$_jf" << EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$spwd",
      "users": [{"name": "user-ss-2022-128", "password": "$upwd"}],
      "multiplex": {"enabled": true, "padding": true}
    }
EOF
}

# 12. Hysteria2
build_hysteria2() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Hysteria2 ───${NC}"
    local tag port pwd obfspwd up dn
    ask_val   tag     "tag"          "hysteria2-in"
    ask_val   port    "listen_port"  "12443"
    ask_random pwd    "password"     "$(gen_password 24)"
    ask_random obfspwd "obfs password" "$(gen_password 16)"
    ask_val   up      "up_mbps"      "200"
    ask_val   dn      "down_mbps"    "100"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "hysteria2",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-hysteria2", "password": "$pwd"}],
      "up_mbps": $up,
      "down_mbps": $dn,
      "obfs": {"type": "salamander", "password": "$obfspwd"},
      "masquerade": "https://www.bing.com",
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "alpn": ["h3"],
        "certificate_path": "$cp",
        "key_path": "$kp"
      }
    }
EOF
}

# 13. TUIC v5
build_tuic() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── TUIC v5 ───${NC}"
    local tag port uuid pwd
    ask_val   tag  "tag"         "tuic-in"
    ask_val   port "listen_port" "13443"
    ask_random uuid "uuid"       "$(gen_uuid)"
    ask_random pwd  "password"   "$(gen_password 20)"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "tuic",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-tuic", "uuid": "$uuid", "password": "$pwd"}],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "alpn": ["h3"],
        "certificate_path": "$cp",
        "key_path": "$kp"
      }
    }
EOF
}

# 14. AnyTLS
build_anytls() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── AnyTLS ───${NC}"
    local tag port pwd
    ask_val   tag  "tag"         "anytls-in"
    ask_val   port "listen_port" "14443"
    ask_random pwd "password"    "$(gen_password 24)"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "anytls",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-anytls", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      }
    }
EOF
}

# 15. NaïveProxy
build_naive() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── NaïveProxy ───${NC}"
    local tag port uname pwd
    ask_val   tag   "tag"         "naive-in"
    ask_val   port  "listen_port" "15443"
    ask_random uname "username"   "$(gen_naive_username)"
    ask_random pwd   "password"   "$(gen_password 20)"
    select_server_name "example.com"; local sn="$SELECTED_SN"
    ask_cert_paths "$sn"; local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "naive",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"username": "$uname", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2"]
      }
    }
EOF
}

configure_singbox() {
    clear
    echo -e "${BOLD}${CYAN}══ 四、配置 sing-box ══${NC}"
    echo ""
    echo "请选择要配置的协议（多个选择用空格分隔，例如：1 3 5）:"
    echo ""
    echo "   1)  VLESS — TCP / XTLS-Vision"
    echo "   2)  VLESS — WebSocket"
    echo "   3)  VLESS — gRPC"
    echo "   4)  VLESS — REALITY (TCP + XTLS-Vision)"
    echo "   5)  VMess — TCP (TLS)"
    echo "   6)  VMess — WebSocket (TLS)"
    echo "   7)  Trojan — TCP (TLS)"
    echo "   8)  Trojan — WebSocket (TLS)"
    echo "   9)  Shadowsocks — 经典加密 (aes-256-gcm)"
    echo "  10)  Shadowsocks 2022 — aes-256-gcm"
    echo "  11)  Shadowsocks 2022 — aes-128-gcm"
    echo "  12)  Hysteria2"
    echo "  13)  TUIC v5"
    echo "  14)  AnyTLS"
    echo "  15)  NaïveProxy"
    echo ""
    read -rp "请输入选项（例如 1 4 12）: " -a PROTO_CHOICES

    if [[ ${#PROTO_CHOICES[@]} -eq 0 ]]; then
        log_warn "未选择任何协议"; press_enter; return
    fi

    echo ""
    log_info "已选择 ${#PROTO_CHOICES[@]} 个协议，开始逐一配置..."
    echo ""

    # 用临时文件收集 JSON，build_* 函数直接写终端（不被子shell捕获）
    local TMP_JSON
    TMP_JSON=$(mktemp /tmp/jddj_inbound_XXXXXX)
    local INBOUNDS_JSON=""
    local first=true

    for choice in "${PROTO_CHOICES[@]}"; do
        # 清空临时文件
        > "$TMP_JSON"
        case $choice in
            1)  build_vless_tcp    "$TMP_JSON" ;;
            2)  build_vless_ws     "$TMP_JSON" ;;
            3)  build_vless_grpc   "$TMP_JSON" ;;
            4)  build_vless_reality "$TMP_JSON" ;;
            5)  build_vmess_tcp    "$TMP_JSON" ;;
            6)  build_vmess_ws     "$TMP_JSON" ;;
            7)  build_trojan_tcp   "$TMP_JSON" ;;
            8)  build_trojan_ws    "$TMP_JSON" ;;
            9)  build_ss_classic   "$TMP_JSON" ;;
            10) build_ss2022_256   "$TMP_JSON" ;;
            11) build_ss2022_128   "$TMP_JSON" ;;
            12) build_hysteria2    "$TMP_JSON" ;;
            13) build_tuic         "$TMP_JSON" ;;
            14) build_anytls       "$TMP_JSON" ;;
            15) build_naive        "$TMP_JSON" ;;
            *)  log_warn "未知选项: $choice，跳过"; continue ;;
        esac
        local inbound_json
        inbound_json=$(cat "$TMP_JSON")
        if [[ -z "$inbound_json" ]]; then continue; fi
        if $first; then
            INBOUNDS_JSON="$inbound_json"
            first=false
        else
            INBOUNDS_JSON="$INBOUNDS_JSON,$inbound_json"
        fi
    done
    rm -f "$TMP_JSON"

    # 生成完整 config.json
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true,
    "output": "/var/log/sing-box/sing-box.log"
  },

  "dns": {
    "servers": [
      {
        "tag": "dns-local",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "final": "dns-local"
  },

  "inbounds": [
$INBOUNDS_JSON
  ],

  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ],

  "route": {
    "rules": [
      {"geoip": ["private"], "outbound": "block"}
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF

    log_success "配置文件已写入: /etc/sing-box/config.json"
    echo ""

    # 验证配置
    if command -v sing-box &>/dev/null; then
        if sing-box check -c /etc/sing-box/config.json 2>/dev/null; then
            log_success "配置语法验证通过"
        else
            log_warn "配置语法验证失败，请手动检查 /etc/sing-box/config.json"
        fi
    fi

    press_enter
}

# ────────────────────────────────────────────────────────────────
#  ══════════════════════════════════════════════════════════════
#  五、sing-box 服务管理
#  ══════════════════════════════════════════════════════════════
# ────────────────────────────────────────────────────────────────

menu_service() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 五、sing-box 服务管理 ══${NC}"
        echo ""
        local status_str
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            status_str="${GREEN}● 运行中${NC}"
        else
            status_str="${RED}○ 已停止${NC}"
        fi
        echo -e "  当前状态: $status_str"
        echo ""
        echo "  1) 启动 sing-box"
        echo "  2) 停止 sing-box"
        echo "  3) 重启 sing-box 并查看状态"
        echo "  4) 查看完整状态 (systemctl status)"
        echo "  5) 设为开机自启"
        echo "  6) 取消开机自启"
        echo "  7) 查看是否开机自启"
        echo "  8) 实时查看日志"
        echo "  9) 验证配置文件"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择: " opt
        case $opt in
            1) systemctl start sing-box && log_success "sing-box 已启动"; press_enter ;;
            2) systemctl stop sing-box && log_success "sing-box 已停止"; press_enter ;;
            3)
                systemctl restart sing-box
                echo ""
                systemctl status sing-box --no-pager
                press_enter ;;
            4) systemctl status sing-box; press_enter ;;
            5) systemctl enable sing-box && log_success "已设为开机自启"; press_enter ;;
            6) systemctl disable sing-box && log_success "已取消开机自启"; press_enter ;;
            7)
                if systemctl is-enabled --quiet sing-box 2>/dev/null; then
                    log_success "sing-box 已设为开机自启"
                else
                    log_warn "sing-box 未设为开机自启"
                fi
                press_enter ;;
            8) journalctl -u sing-box -f --no-pager ;;
            9)
                if command -v sing-box &>/dev/null; then
                    sing-box check -c /etc/sing-box/config.json && log_success "配置验证通过" || log_error "配置验证失败"
                else
                    log_error "sing-box 未安装"
                fi
                press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  ══════════════════════════════════════════════════════════════
#  六、生成节点链接
#  ══════════════════════════════════════════════════════════════
# ────────────────────────────────────────────────────────────────

# URL 编码
urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || \
    printf '%s' "$1" | od -An -tx1 | tr ' ' '%' | tr -d '\n'
}

# 获取服务器公网 IP
get_server_ip() {
    local ip=""
    for svc in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb" "https://ipinfo.io/ip"; do
        ip=$(curl -s --max-time 4 "$svc" 2>/dev/null | tr -d '[:space:]') && [[ -n "$ip" ]] && break
    done
    echo "${ip:-127.0.0.1}"
}

get_sni_from_tls() {
    local tls_json="$1" fallback="$2"
    python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1])
    print(d.get('server_name') or sys.argv[2])
except:
    print(sys.argv[2])
" "$tls_json" "$fallback" 2>/dev/null || echo "$fallback"
}

# 解析 config.json 生成所有链接
generate_links() {
    local CONFIG="/etc/sing-box/config.json"
    if [[ ! -f "$CONFIG" ]]; then
        log_error "配置文件不存在: $CONFIG"
        return 1
    fi

    if ! command -v python3 &>/dev/null; then
        log_error "需要 python3，请先安装"; return 1
    fi

    local SERVER_IP
    log_info "获取服务器 IP..."
    SERVER_IP=$(get_server_ip)
    log_info "服务器 IP: $SERVER_IP"
    echo ""

    python3 << PYEOF
import json, base64, sys, re, urllib.parse

CONFIG_FILE = "/etc/sing-box/config.json"
SERVER_IP   = "$SERVER_IP"
OUTPUT_FILE = "/etc/sing-box/subscription.txt"
B64_FILE    = "/etc/sing-box/subscription.b64"
CLASH_FILE  = "/etc/sing-box/clash.yaml"

def urlencode(s):
    return urllib.parse.quote(str(s), safe='')

def b64(s):
    return base64.urlsafe_b64encode(s.encode()).decode().rstrip('=')

def get_sni(tls, addr):
    if isinstance(tls, dict):
        return tls.get('server_name') or addr
    return addr

def strip_comments(text):
    return re.sub(r'(?<![:/])//[^\n]*', '', text)

with open(CONFIG_FILE) as f:
    raw = f.read()

try:
    config = json.loads(raw)
except:
    try:
        config = json.loads(strip_comments(raw))
    except Exception as e:
        print(f"[ERROR] 解析配置失败: {e}")
        sys.exit(1)

links = []
clash_proxies = []
clash_proxy_names = []

inbounds = config.get('inbounds', [])
for ib in inbounds:
    t    = ib.get('type', '')
    tag  = ib.get('tag', t)
    port = ib.get('listen_port')
    if not port:
        continue

    listen = ib.get('listen', '::')
    addr = SERVER_IP if listen in ('::', '0.0.0.0') else listen

    tls = ib.get('tls', {})
    tls_on = tls.get('enabled', False)
    sni = get_sni(tls, addr)

    tag_enc = urlencode(tag)
    users = ib.get('users', [])
    transport = ib.get('transport', {})
    net = transport.get('type', 'tcp')
    ws_path = transport.get('path', '/')

    # ─── VLESS ───
    if t == 'vless':
        if not users: continue
        u = users[0]
        uuid  = u.get('uuid', '')
        flow  = u.get('flow', '')

        reality = tls.get('reality', {})
        reality_on = reality.get('enabled', False)

        if reality_on:
            pbk = reality.get('public_key', '')
            sid = reality.get('short_id', [''])[0] if isinstance(reality.get('short_id'), list) else reality.get('short_id', '')
            params = f"encryption=none&flow={flow}&security=reality&sni={sni}&fp=chrome&pbk={urlencode(pbk)}&sid={sid}&type=tcp&headerType=none"
        else:
            sec = 'tls' if tls_on else 'none'
            params = f"encryption=none"
            if flow: params += f"&flow={flow}"
            params += f"&security={sec}&sni={sni}&fp=chrome&type={net}&headerType=none"
            if net in ('ws', 'http'):
                params += f"&path={urlencode(ws_path)}"

        link = f"vless://{uuid}@{addr}:{port}?{params}#{tag_enc}"
        links.append(link)

        # Clash VLESS
        cp = {
            'name': tag, 'type': 'vless', 'server': addr, 'port': port,
            'uuid': uuid, 'tls': tls_on, 'servername': sni,
            'network': net, 'udp': True
        }
        if flow: cp['flow'] = flow
        if reality_on:
            cp['reality-opts'] = {'public-key': pbk, 'short-id': sid}
            cp['tls'] = True
        if net == 'ws':
            cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    # ─── VMESS ───
    elif t == 'vmess':
        if not users: continue
        u = users[0]
        uuid = u.get('uuid', '')
        aid  = u.get('alterId', 0)
        tls_s = 'tls' if tls_on else 'none'

        obj = {
            'v':'2','ps':tag,'add':addr,'port':str(port),
            'id':uuid,'aid':str(aid),'scy':'auto',
            'net':net,'type':'none','host':sni,
            'path':ws_path,'tls':tls_s,'sni':sni,'fp':'chrome'
        }
        enc = base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip('=')
        links.append(f"vmess://{enc}")

        cp = {
            'name': tag, 'type': 'vmess', 'server': addr, 'port': port,
            'uuid': uuid, 'alterId': aid, 'cipher': 'auto',
            'tls': tls_on, 'servername': sni, 'network': net, 'udp': True
        }
        if net == 'ws':
            cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    # ─── TROJAN ───
    elif t == 'trojan':
        if not users: continue
        pwd = users[0].get('password', '')
        params = f"security=tls&sni={sni}&type={net}"
        if net == 'ws':
            params += f"&path={urlencode(ws_path)}"
        links.append(f"trojan://{urlencode(pwd)}@{addr}:{port}?{params}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'trojan', 'server': addr, 'port': port,
            'password': pwd, 'sni': sni, 'udp': True, 'network': net
        }
        if net == 'ws':
            cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    # ─── SHADOWSOCKS ───
    elif t == 'shadowsocks':
        method = ib.get('method', '')
        pwd    = ib.get('password', '')
        if not method or not pwd: continue
        info = base64.urlsafe_b64encode(f"{method}:{pwd}".encode()).decode().rstrip('=')
        links.append(f"ss://{info}@{addr}:{port}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'ss', 'server': addr, 'port': port,
            'cipher': method, 'password': pwd, 'udp': True
        }
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    # ─── HYSTERIA2 ───
    elif t == 'hysteria2':
        if not users: continue
        pwd    = users[0].get('password', '')
        up_m   = ib.get('up_mbps', 200)
        dn_m   = ib.get('down_mbps', 100)
        params = f"sni={sni}&insecure=0&upmbps={up_m}&downmbps={dn_m}"
        links.append(f"hysteria2://{urlencode(pwd)}@{addr}:{port}?{params}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'hysteria2', 'server': addr, 'port': port,
            'password': pwd, 'sni': sni, 'up': f"{up_m} Mbps", 'down': f"{dn_m} Mbps",
            'skip-cert-verify': False
        }
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    # ─── TUIC ───
    elif t == 'tuic':
        if not users: continue
        u    = users[0]
        uuid = u.get('uuid', '')
        pwd  = u.get('password', '')
        cc   = ib.get('congestion_control', 'bbr')
        params = f"sni={sni}&congestion_control={cc}&alpn=h3&udp_relay_mode=native"
        links.append(f"tuic://{uuid}:{urlencode(pwd)}@{addr}:{port}?{params}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'tuic', 'server': addr, 'port': port,
            'uuid': uuid, 'password': pwd, 'alpn': ['h3'],
            'congestion-controller': cc, 'sni': sni, 'udp-relay-mode': 'native'
        }
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    # ─── ANYTLS ───
    elif t == 'anytls':
        if not users: continue
        pwd    = users[0].get('password', '')
        params = f"security=tls&sni={sni}&type=tcp"
        links.append(f"anytls://{urlencode(pwd)}@{addr}:{port}?{params}#{tag_enc}")
        # Clash 暂无原生支持，跳过

    # ─── NAIVE ───
    elif t == 'naive':
        if not users: continue
        u    = users[0]
        uname = u.get('username', '')
        pwd   = u.get('password', '')
        links.append(f"naive+https://{urlencode(uname)}:{urlencode(pwd)}@{addr}:{port}?padding=true#{tag_enc}")

# ──────────────────────────────────────────────
# 写入明文订阅
# ──────────────────────────────────────────────
with open(OUTPUT_FILE, 'w') as f:
    f.write('\n'.join(links) + '\n')

# 写入 Base64 订阅 (V2RayN/通用)
with open(B64_FILE, 'w') as f:
    f.write(base64.b64encode('\n'.join(links).encode()).decode() + '\n')

# ──────────────────────────────────────────────
# Clash / Mihomo YAML
# ──────────────────────────────────────────────
import yaml if True else None
try:
    import yaml
    clash_doc = {
        'mixed-port': 7890,
        'allow-lan': False,
        'mode': 'rule',
        'log-level': 'info',
        'proxies': clash_proxies,
        'proxy-groups': [{
            'name': 'Proxy',
            'type': 'select',
            'proxies': clash_proxy_names + ['DIRECT']
        }],
        'rules': ['MATCH,Proxy']
    }
    with open(CLASH_FILE, 'w') as f:
        yaml.dump(clash_doc, f, allow_unicode=True, default_flow_style=False)
    print(f"Clash/Mihomo 配置已写入: {CLASH_FILE}")
except ImportError:
    # 手动生成 YAML
    with open(CLASH_FILE, 'w') as f:
        f.write("mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\n\nproxies:\n")
        for p in clash_proxies:
            f.write(f"  - name: {json.dumps(p['name'], ensure_ascii=False)}\n")
            f.write(f"    type: {p['type']}\n")
            f.write(f"    server: {p['server']}\n")
            f.write(f"    port: {p['port']}\n")
            for k, v in p.items():
                if k not in ('name','type','server','port'):
                    f.write(f"    {k}: {json.dumps(v, ensure_ascii=False) if isinstance(v,(dict,list)) else v}\n")
        f.write("\nproxy-groups:\n  - name: Proxy\n    type: select\n    proxies:\n")
        for n in clash_proxy_names:
            f.write(f"      - {json.dumps(n, ensure_ascii=False)}\n")
        f.write("      - DIRECT\n\nrules:\n  - MATCH,Proxy\n")

print(f"\n[✓] 共生成 {len(links)} 条订阅链接")
print(f"[✓] 明文订阅: {OUTPUT_FILE}")
print(f"[✓] Base64订阅 (V2RayN): {B64_FILE}")
print(f"[✓] Clash/Mihomo: {CLASH_FILE}")
print("")
print("══════════════ 所有节点链接 ══════════════")
for lk in links:
    print(lk)
print("══════════════════════════════════════════")
PYEOF
}

menu_links() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 六、生成节点链接 ══${NC}"
        echo ""
        echo "  1) 生成所有节点链接（singbox / V2RayN / Clash Mihomo）"
        echo "  2) 查看明文订阅"
        echo "  3) 查看 Base64 订阅（V2RayN 用）"
        echo "  4) 查看 Clash/Mihomo 配置"
        echo "  5) 显示订阅文件路径"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择: " opt
        case $opt in
            1) generate_links; press_enter ;;
            2) cat /etc/sing-box/subscription.txt 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            3) cat /etc/sing-box/subscription.b64 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            4) cat /etc/sing-box/clash.yaml 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            5)
                echo "  明文订阅:       /etc/sing-box/subscription.txt"
                echo "  Base64 订阅:    /etc/sing-box/subscription.b64"
                echo "  Clash/Mihomo:   /etc/sing-box/clash.yaml"
                press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  ══════════════════════════════════════════════════════════════
#  全部执行 (1→6)
#  ══════════════════════════════════════════════════════════════
# ────────────────────────────────────────────────────────────────

run_all() {
    clear
    echo -e "${BOLD}${YELLOW}══ 全部执行 1→6 ══${NC}"
    echo ""
    echo "将依次执行："
    echo "  1. 基础安全设置（SSH/BBR/fail2ban）"
    echo "  2. SSL 证书申请"
    echo "  3. 安装 sing-box"
    echo "  4. 配置 sing-box 协议"
    echo "  5. 启动 sing-box 服务"
    echo "  6. 生成节点链接"
    echo ""
    read -rp "确认继续？(y/N): " c
    [[ "${c,,}" != "y" ]] && return

    detect_distro
    bootstrap_packages

    echo ""
    echo -e "${BLUE}── 步骤 1：基础安全设置 ──${NC}"
    setup_ssh_key
    disable_password_login
    change_ssh_port
    enable_bbr
    configure_ip_protocol
    setup_fail2ban

    echo ""
    echo -e "${BLUE}── 步骤 2：SSL 证书 ──${NC}"
    deploy_ssl

    echo ""
    echo -e "${BLUE}── 步骤 3：安装 sing-box ──${NC}"
    # 默认 Latest
    bash <(curl -fsSL https://sing-box.app/deb-install.sh) 2>/dev/null || true
    mkdir -p /etc/sing-box /var/log/sing-box

    echo ""
    echo -e "${BLUE}── 步骤 4：配置 sing-box ──${NC}"
    configure_singbox

    echo ""
    echo -e "${BLUE}── 步骤 5：sing-box 服务 ──${NC}"
    systemctl enable sing-box
    systemctl restart sing-box
    systemctl is-active --quiet sing-box && log_success "sing-box 运行中" || log_warn "sing-box 启动失败，请检查配置"

    echo ""
    echo -e "${BLUE}── 步骤 6：生成节点链接 ──${NC}"
    generate_links

    press_enter
}

# ────────────────────────────────────────────────────────────────
#  主菜单
# ────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}"
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║          服务器一键管理脚本  (jddj v1.0)            ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo "  部署流程:"
        echo -e "   ${GREEN}1.${NC} 基础设置（SSH/fail2ban/BBR）       ${GREEN}2.${NC} SSL 证书申请与安装"
        echo -e "   ${GREEN}3.${NC} 安装 sing-box                      ${GREEN}4.${NC} 配置 sing-box"
        echo -e "   ${GREEN}5.${NC} sing-box 服务管理                  ${GREEN}6.${NC} 生成节点链接"
        echo ""
        echo -e "   ${YELLOW}7.${NC} ── 全部执行（1→6）──"
        echo ""
        echo "══════════════════════════════════════════════════════"
        echo "   0. 退出"
        echo ""
        read -rp "请选择: " opt
        case $opt in
            1) detect_distro; menu_basic ;;
            2) menu_ssl ;;
            3) detect_distro; install_singbox ;;
            4) configure_singbox ;;
            5) menu_service ;;
            6) menu_links ;;
            7) detect_distro; run_all ;;
            0)
                echo ""
                echo "感谢使用，再见！"
                echo "下次可使用命令 jddj 重新进入管理界面"
                exit 0 ;;
            *)
                log_warn "无效选项，请重新选择"
                sleep 1 ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  安装 jddj 快捷命令
#  兼容 bash <(curl ...) 管道方式运行（$0 为 /proc/xxx/fd/pipe:...）
# ────────────────────────────────────────────────────────────────
JDDJ_REMOTE_URL="https://raw.githubusercontent.com/github19999/Ojddj/main/jddj.sh"

install_self() {
    local TARGET="/usr/local/bin/jddj"

    # 已经是从 TARGET 运行，无需重装
    [[ "$0" == "$TARGET" ]] && return

    # 统一从远端下载保存，避免 bash <(curl...) 管道方式下 $0 不是真实文件的问题
    if curl -fsSL "$JDDJ_REMOTE_URL" -o "$TARGET" 2>/dev/null; then
        chmod +x "$TARGET"
        log_success "已安装快捷命令 jddj，下次直接输入 jddj 进入管理界面"
    elif wget -qO "$TARGET" "$JDDJ_REMOTE_URL" 2>/dev/null; then
        chmod +x "$TARGET"
        log_success "已安装快捷命令 jddj，下次直接输入 jddj 进入管理界面"
    else
        log_warn "快捷命令安装失败（网络问题），不影响当前使用"
    fi
}

# ────────────────────────────────────────────────────────────────
#  入口
# ────────────────────────────────────────────────────────────────
check_root
install_self
main_menu
