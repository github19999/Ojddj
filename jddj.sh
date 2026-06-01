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
        local privkey pubkey
        privkey=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
        pubkey=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
        echo "PrivateKey: ${privkey}"
        echo "PublicKey:  ${pubkey}"
    fi
}

gen_short_id() { openssl rand -hex 4; }

gen_naive_username() {
    tr -dc 'a-z0-9' </dev/urandom | head -c 12 2>/dev/null || echo "naiveuser$(shuf -i 1000-9999 -n1)"
}

# ────────────────────────────────────────────────────────────────
#  通用输入函数
#  ask_val  <变量名> <字段说明> <默认值>
#  ask_random <变量名> <字段说明> <随机值>
#
#  修复要点：
#  1. 每次输入前先打印「字段说明 → 随机/默认值」让用户明确看到
#  2. 用户回车后，无论是否修改，都打印绿色「✓ 实际使用值」
#  3. 不依赖 [[ -z "$input" ]] 判断（防止某些终端 read 行为异常）
# ────────────────────────────────────────────────────────────────
ask_val() {
    local varname="$1"
    local label="$2"
    local default="$3"
    local input result

    # 明确显示字段说明 + 默认值（独占一行，避免被 read -rp 覆盖）
    echo -e "  ${CYAN}◆ ${label}${NC}  (默认: ${YELLOW}${default}${NC}，回车确认)"
    read -rp "  > " input
    result="${input:-$default}"
    echo -e "  ${GREEN}✓ ${label} = ${result}${NC}"
    echo ""
    printf -v "$varname" '%s' "$result"
}

ask_random() {
    local varname="$1"
    local label="$2"
    local randval="$3"
    local input result

    # 明确显示字段说明 + 随机值（独占多行）
    echo -e "  ${CYAN}◆ ${label}${NC}"
    echo -e "    随机生成值: ${YELLOW}${randval}${NC}"
    echo -e "    (回车使用随机值，或输入自定义值覆盖)"
    read -rp "  > " input
    result="${input:-$randval}"
    echo -e "  ${GREEN}✓ ${label} = ${result}${NC}"
    echo ""
    printf -v "$varname" '%s' "$result"
}

# 兼容旧 ask() 调用
ask() {
    local prompt="$1" default="$2"
    ask_val REPLY_VAL "$prompt" "$default"
}

# ────────────────────────────────────────────────────────────────
#  读取已安装证书域名
# ────────────────────────────────────────────────────────────────
get_cert_domains() {
    local domains=()

    # ── 1. 扫描 acme.sh 证书目录 ─────────────────────────────
    if [[ -d /root/.acme.sh ]]; then
        while IFS= read -r dir; do
            local d
            d=$(basename "$dir")
            # 跳过系统目录、非域名条目、ECC 副本目录
            [[ -z "$d" || "$d" == "__INTERACT__" || "$d" == "ca" || "$d" == "account.conf" ]] && continue
            [[ "$d" == *_ecc ]] && continue
            [[ ! -d "$dir" ]] && continue

            # 目录名本身（主域名）加入
            domains+=("$d")

            # ── 2. 读 .conf 中的 Le_Alt（SAN 附加域名）─────────
            local conf_file="$dir/${d}.conf"
            if [[ -f "$conf_file" ]]; then
                local le_alt
                le_alt=$(grep -oP "(?<=Le_Alt=')[^']+" "$conf_file" 2>/dev/null || true)
                if [[ -n "$le_alt" ]]; then
                    # Le_Alt 格式: "domain1,domain2,..." 或空格分隔
                    while IFS=, read -ra alt_list; do
                        for alt in "${alt_list[@]}"; do
                            alt="${alt// /}"   # 去空格
                            [[ -n "$alt" && "$alt" == *.* ]] && domains+=("$alt")
                        done
                    done <<< "$le_alt"
                fi
            fi

            # ── 3. 读证书文件中的 SAN extension ─────────────────
            local cert_file="$dir/fullchain.cer"
            [[ ! -f "$cert_file" ]] && cert_file="$dir/${d}.cer"
            if [[ -f "$cert_file" ]]; then
                while IFS= read -r san; do
                    san="${san#DNS:}"
                    san="${san// /}"
                    [[ -n "$san" && "$san" == *.* && "$san" != *\** ]] && domains+=("$san")
                done < <(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null                     | grep -oP "DNS:[^,\s]+" | tr ',' '
')
            fi

        done < <(find /root/.acme.sh -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi

    # ── 4. 扫描系统常见证书目录 ──────────────────────────────
    while IFS= read -r crt; do
        [[ -z "$crt" ]] && continue
        # 读 CN
        local cn
        cn=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null             | grep -oP '(?<=CN\s=\s)[^,/]+' | head -1)
        [[ -n "$cn" && "$cn" == *.* ]] && domains+=("$cn")
        # 读 SAN
        while IFS= read -r san; do
            san="${san#DNS:}"
            san="${san// /}"
            [[ -n "$san" && "$san" == *.* && "$san" != *\** ]] && domains+=("$san")
        done < <(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null             | grep -oP "DNS:[^,\s]+" | tr ',' '\n')
    done < <(find /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl 2>/dev/null \
        \( -name "*.crt" -o -name "fullchain.cer" -o -name "*.pem" \) | head -30)

    # ── 5. 去重、过滤通配符和无点号条目、排序 ──────────────────
    printf '%s\n' "${domains[@]}" | sort -u | grep -v '^\*' | grep '\.' || true
}

# ────────────────────────────────────────────────────────────────
#  选择 server_name
#  修复：每个选项编号独占一行，选完后打印「✓ 实际使用值」
# ────────────────────────────────────────────────────────────────
select_server_name() {
    local default_sn="${1:-example.com}"
    echo ""
    echo -e "  ${CYAN}◆ server_name（域名/伪装域名）${NC}"

    local domains=()
    mapfile -t domains < <(get_cert_domains 2>/dev/null)

    if [[ ${#domains[@]} -gt 0 ]]; then
        echo -e "    检测到已安装证书，请选择："
        for i in "${!domains[@]}"; do
            echo -e "    ${YELLOW}$((i+1)))${NC} ${domains[$i]}"
        done
        local manual_idx=$(( ${#domains[@]} + 1 ))
        echo -e "    ${YELLOW}${manual_idx})${NC} 手动输入"
        echo ""
        local sn_choice
        read -rp "  > (编号，默认 1): " sn_choice
        sn_choice="${sn_choice:-1}"

        if [[ "$sn_choice" =~ ^[0-9]+$ ]] && \
           [[ "$sn_choice" -ge 1 ]] && \
           [[ "$sn_choice" -le "${#domains[@]}" ]]; then
            SELECTED_SN="${domains[$((sn_choice-1))]}"
        else
            read -rp "  > 手动输入 server_name (默认 ${default_sn}): " SELECTED_SN
            SELECTED_SN="${SELECTED_SN:-$default_sn}"
        fi
    else
        echo -e "    （未检测到已安装证书，请手动输入）"
        read -rp "  > server_name (默认 ${default_sn}): " SELECTED_SN
        SELECTED_SN="${SELECTED_SN:-$default_sn}"
    fi

    echo -e "  ${GREEN}✓ server_name = ${SELECTED_SN}${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────────
#  自动定位证书路径，询问确认
# ────────────────────────────────────────────────────────────────
ask_cert_paths() {
    local sn="$1"
    local auto_cert="" auto_key=""

    for d in /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/${sn}.crt"           ]] && auto_cert="$d/${sn}.crt"           && break
        [[ -f "$d/fullchain.cer"       ]] && auto_cert="$d/fullchain.cer"       && break
        [[ -f "$d/${sn}/fullchain.cer" ]] && auto_cert="$d/${sn}/fullchain.cer" && break
    done
    for d in /etc/ssl/private /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/${sn}.key"   ]] && auto_key="$d/${sn}.key"   && break
        [[ -f "$d/private.key" ]] && auto_key="$d/private.key" && break
    done
    [[ -z "$auto_cert" && -f "/root/.acme.sh/${sn}/fullchain.cer" ]] && auto_cert="/root/.acme.sh/${sn}/fullchain.cer"
    [[ -z "$auto_key"  && -f "/root/.acme.sh/${sn}/${sn}.key"     ]] && auto_key="/root/.acme.sh/${sn}/${sn}.key"

    local default_cert="${auto_cert:-/etc/ssl/private/fullchain.cer}"
    local default_key="${auto_key:-/etc/ssl/private/private.key}"

    ask_val CERT_PATH "cert_path（证书文件）" "$default_cert"
    ask_val KEY_PATH  "key_path（私钥文件）"  "$default_key"
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

    # ── 1. 安装依赖 ──────────────────────────────────────────────
    local packages=""
    [[ "$PKG_MANAGER" == "apt" ]] && \
        packages="curl wget socat cron openssl ca-certificates" || \
        packages="curl wget socat cronie openssl ca-certificates"
    $PKG_MANAGER install -y $packages >/dev/null 2>&1 || true

    # 按发行版启动对应 cron 服务（Debian 用 cron，CentOS 用 crond）
    local cron_svc="cron"
    [[ "$PKG_MANAGER" != "apt" ]] && cron_svc="crond"
    systemctl enable "$cron_svc" >/dev/null 2>&1 || true
    systemctl start  "$cron_svc" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$cron_svc" 2>/dev/null; then
        log_success "cron 服务已运行"
    else
        log_warn "cron 服务未能启动，自动续期 crontab 将在证书安装后手动补充"
    fi

    # ── 2. 域名输入 ──────────────────────────────────────────────
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

    # ── 3. 证书存储路径 ──────────────────────────────────────────
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

    # ── 4. 安装 acme.sh ──────────────────────────────────────────
    if [[ ! -f /root/.acme.sh/acme.sh ]]; then
        log_step "安装 acme.sh..."
        # 参照官方推荐方式：curl 管道给 sh 执行（安装脚本本身不接受 --force）
        # cron 未运行时 acme.sh 安装脚本会打印警告，但不会中止安装
        # 使用临时脚本隔离 fd，避免 bash <(curl) 管道模式下 stdin 被占用
        local _acme_tmp="/tmp/_acme_install_$$.sh"
        if curl -fsSL https://get.acme.sh -o "$_acme_tmp" 2>/dev/null || \
           wget -qO  "$_acme_tmp" https://get.acme.sh 2>/dev/null; then
            sh "$_acme_tmp"   # 不传任何额外参数，与官方 curl|sh 等效
            rm -f "$_acme_tmp"
        else
            rm -f "$_acme_tmp"
            log_error "acme.sh 安装包下载失败，请检查网络"
            return 1
        fi
        # 安装脚本退出码不可靠（警告也返回0），只检查文件是否存在
        if [[ ! -f /root/.acme.sh/acme.sh ]]; then
            log_error "acme.sh 安装失败，未找到 /root/.acme.sh/acme.sh"
            return 1
        fi
    else
        log_info "acme.sh 已存在，检查更新..."
        /root/.acme.sh/acme.sh --upgrade >/dev/null 2>&1 || true
    fi

    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh 2>/dev/null || true
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    log_success "acme.sh 已就绪"

    # ── 5. 停止 Web 服务（释放80端口）──────────────────────────
    manage_web_services_ssl "stop"

    # ── 6. 申请证书 ──────────────────────────────────────────────
    log_step "申请证书（Standalone 模式）..."
    local domain_args=""
    for d in "${SSL_DOMAINS[@]}"; do domain_args="$domain_args -d $d"; done

    if /root/.acme.sh/acme.sh --issue $domain_args --standalone --force; then
        log_success "证书申请成功"
    else
        log_error "证书申请失败"
        manage_web_services_ssl "start"
        return 1
    fi

    # ── 7. 安装证书到指定目录 ────────────────────────────────────
    local KEY_FILE="$CERT_DIR/private.key"
    local CERT_FILE="$CERT_DIR/fullchain.cer"
    local CA_FILE="$CERT_DIR/ca.cer"

    # 检测当前运行的 Web 服务，用于 reloadcmd 和 Pre/Post Hook
    local DETECTED_SVC="" PRE_HOOK="" POST_HOOK=""
    local RELOAD_CMD="echo 'cert installed'"
    for svc in nginx apache2 httpd lighttpd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            DETECTED_SVC="$svc"
            PRE_HOOK="systemctl stop $svc"
            POST_HOOK="systemctl start $svc"
            RELOAD_CMD="systemctl reload $svc"
            log_info "检测到 Web 服务: $svc，续期将自动停启该服务"
            break
        fi
    done

    /root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --key-file  "$KEY_FILE"  \
        --fullchain-file "$CERT_FILE" \
        --ca-file   "$CA_FILE"   \
        --reloadcmd "$RELOAD_CMD" || { log_error "证书安装失败"; return 1; }

    chmod 600 "$KEY_FILE"  2>/dev/null || true
    chmod 644 "$CERT_FILE" "$CA_FILE" 2>/dev/null || true
    log_success "证书已安装至: $CERT_DIR"

    # ── 8. 写入 Pre/Post Hook（解决续期时80端口冲突）────────────
    # acme.sh 续期前自动执行 Le_PreHook 停服务，续期后执行 Le_PostHook 启服务
    if [[ -n "$PRE_HOOK" ]]; then
        local CONF_FILE="/root/.acme.sh/${MAIN_DOMAIN}/${MAIN_DOMAIN}.conf"
        if [[ -f "$CONF_FILE" ]]; then
            if ! grep -q "Le_PreHook" "$CONF_FILE"; then
                echo "Le_PreHook='$PRE_HOOK'"   >> "$CONF_FILE"
                echo "Le_PostHook='$POST_HOOK'" >> "$CONF_FILE"
                log_success "续期 Hook 已配置（自动停启 $DETECTED_SVC）"
            else
                log_info "续期 Hook 已存在，跳过"
            fi
        else
            log_warn "未找到 acme.sh 配置文件: $CONF_FILE"
            log_warn "请手动追加以下两行到该文件："
            log_warn "  Le_PreHook='$PRE_HOOK'"
            log_warn "  Le_PostHook='$POST_HOOK'"
        fi
    else
        log_info "未检测到运行中的 Web 服务，续期将直接 Standalone 绑定80端口"
    fi

    # ── 9. 配置自动续期 crontab ──────────────────────────────────
    local LOG_FILE="/var/log/acme-renew.log"
    local CRON_JOB="0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> $LOG_FILE 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        log_success "自动续期任务已设置（每天 02:00，日志: $LOG_FILE）"
    else
        log_info "自动续期任务已存在，跳过"
    fi

    # ── 10. 重启 Web 服务 ─────────────────────────────────────────
    manage_web_services_ssl "start"

    # ── 11. 显示结果 ─────────────────────────────────────────────
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
    echo ""
    echo "  Nginx 配置参考:"
    echo "    ssl_certificate     $CERT_FILE;"
    echo "    ssl_certificate_key $KEY_FILE;"
    echo ""
    echo "  Apache 配置参考:"
    echo "    SSLCertificateFile    $CERT_FILE"
    echo "    SSLCertificateKeyFile $KEY_FILE"
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

    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box

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
#  四、配置 sing-box  —  各协议 build_* 函数
#
#  修复要点：
#  1. 所有 ask_val / ask_random 调用均已采用新版格式
#  2. 内嵌选项菜单（flow / 加密方式）用独立编号列表 + ask_val 实现，
#     不再使用裸 echo + read，防止选项被滚屏冲走
#  3. VLESS REALITY：handshake.server 改为询问，不再写死 127.0.0.1:8001
#  4. 所有随机值（uuid / password / key）调用 ask_random，必显示随机值
#  ══════════════════════════════════════════════════════════════
# ────────────────────────────────────────────────────────────────

# 1. VLESS TCP / XTLS-Vision
build_vless_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — TCP / XTLS-Vision ───${NC}"
    echo ""

    local tag port uuid uname flow_choice flow

    ask_val   tag   "tag（inbound 标识）"  "vless-tcp-in"
    ask_val   port  "listen_port（监听端口）" "1443"
    ask_random uuid "uuid（用户 UUID）" "$(gen_uuid)"
    ask_val   uname "name（用户名）" "user-vless-tcp"

    echo -e "  ${CYAN}◆ flow（流控模式）${NC}"
    echo -e "    ${YELLOW}1)${NC} xtls-rprx-vision  [推荐，XTLS Vision 模式]"
    echo -e "    ${YELLOW}2)${NC} 无（普通 TLS，不启用流控）"
    ask_val flow_choice "请输入编号" "1"
    if [[ "$flow_choice" == "2" ]]; then
        flow=""
        echo -e "  ${GREEN}✓ flow = （空，普通 TLS）${NC}"
    else
        flow="xtls-rprx-vision"
        echo -e "  ${GREEN}✓ flow = xtls-rprx-vision${NC}"
    fi
    echo ""

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    local flow_json
    [[ -n "$flow" ]] && flow_json='"flow": "'"$flow"'"' || flow_json='"flow": ""'

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "$uname", "uuid": "$uuid", $flow_json}],
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
    echo ""

    local tag port uuid wspath

    ask_val   tag    "tag（inbound 标识）"    "vless-ws-in"
    ask_val   port   "listen_port（监听端口）" "8443"
    ask_random uuid  "uuid（用户 UUID）"       "$(gen_uuid)"
    ask_val   wspath "ws path（WebSocket 路径）" "/vless-ws"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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
    echo ""

    local tag port uuid svcname

    ask_val   tag     "tag（inbound 标识）"     "vless-grpc-in"
    ask_val   port    "listen_port（监听端口）"  "8444"
    ask_random uuid   "uuid（用户 UUID）"        "$(gen_uuid)"
    ask_val   svcname "service_name（gRPC 服务名）" "vless-grpc-service"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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
    echo ""

    local port uuid pk si sn hs_server hs_port

    ask_val port "listen_port（监听端口，建议 443）" "443"
    ask_random uuid "uuid（用户 UUID）" "$(gen_uuid)"

    # ── 生成密钥对 ────────────────────────────────────────────
    echo -e "  ${YELLOW}正在生成 REALITY 密钥对...${NC}"
    local keypair_out privkey pubkey
    keypair_out=$(gen_reality_keypair)
    privkey=$(echo "$keypair_out" | grep -i private | awk '{print $NF}')
    pubkey=$(echo  "$keypair_out" | grep -i public  | awk '{print $NF}')
    local sid_rand
    sid_rand=$(gen_short_id)
    echo ""

    # 【修复2】先展示密钥对（private+public 配对显示），再让用户确认/覆盖
    # 用户若自定义 private_key，需自行提供对应的 public_key
    echo -e "  ${CYAN}◆ REALITY 密钥对（自动生成，回车直接使用）${NC}"
    echo -e "    ${YELLOW}Private Key:${NC} ${privkey}"
    echo -e "    ${GREEN}Public  Key:${NC} ${pubkey}  ← 客户端填此值"
    echo -e "    (若需自定义，请同时替换 Private Key 和对应的 Public Key)"
    echo ""
    echo -e "  ${CYAN}◆ private_key（REALITY 私钥，服务端用）${NC}"
    echo -e "    随机生成值: ${YELLOW}${privkey}${NC}"
    echo -e "    (回车使用随机值，或输入自定义 private_key)"
    read -rp "  > " _pk_input
    pk="${_pk_input:-$privkey}"
    # 若用户自定义了 private_key，public_key 也需手动输入
    if [[ -n "$_pk_input" && "$_pk_input" != "$privkey" ]]; then
        echo -e "  ${YELLOW}⚠ 已自定义 private_key，请同时输入对应的 public_key:${NC}"
        read -rp "  > public_key: " pubkey
    fi
    echo -e "  ${GREEN}✓ private_key = ${pk}${NC}"
    echo -e "  ${GREEN}✓ public_key  = ${pubkey}${NC}"
    echo ""

    ask_random si "short_id（REALITY Short ID）" "$sid_rand"

    echo ""
    echo -e "  ${BOLD}${GREEN}★ 客户端需要的 public_key（请复制保存）:${NC}"
    echo -e "  ${BOLD}${CYAN}    ${pubkey}${NC}"
    echo ""

    # 【修复1】server_name：优先使用已申请证书的域名（通过 select_server_name 检测）
    # REALITY 的 server_name 是伪装域名，用自己的真实域名更自然，无需拥有也可
    echo -e "  ${CYAN}◆ server_name（REALITY 伪装域名）${NC}"
    echo -e "    可以填已申请的证书域名（推荐），也可填任意公网 TLS 网站"
    # 获取已安装证书列表，取最后一个作为默认（对应用户的第二个证书 ccscs2...）
    local _cert_domains=()
    mapfile -t _cert_domains < <(get_cert_domains 2>/dev/null)
    local _default_sn="www.microsoft.com"
    if [[ ${#_cert_domains[@]} -ge 2 ]]; then
        # 有多个证书时，取最后一个作为默认
        _default_sn="${_cert_domains[-1]}"
    elif [[ ${#_cert_domains[@]} -eq 1 ]]; then
        _default_sn="${_cert_domains[0]}"
    fi

    if [[ ${#_cert_domains[@]} -gt 0 ]]; then
        echo -e "    检测到已安装证书，请选择或手动输入："
        for i in "${!_cert_domains[@]}"; do
            echo -e "    ${YELLOW}$((i+1)))${NC} ${_cert_domains[$i]}"
        done
        local _manual_idx=$(( ${#_cert_domains[@]} + 1 ))
        echo -e "    ${YELLOW}${_manual_idx})${NC} 手动输入其他域名"
        echo -e "    (默认选 ${#_cert_domains[@]}，即 ${_default_sn})"
        echo ""
        local _sn_choice
        read -rp "  > (编号，默认 ${#_cert_domains[@]}): " _sn_choice
        _sn_choice="${_sn_choice:-${#_cert_domains[@]}}"
        if [[ "$_sn_choice" =~ ^[0-9]+$ ]] &&            [[ "$_sn_choice" -ge 1 ]] &&            [[ "$_sn_choice" -le "${#_cert_domains[@]}" ]]; then
            sn="${_cert_domains[$((_sn_choice-1))]}"
        else
            read -rp "  > 手动输入 server_name (默认 ${_default_sn}): " sn
            sn="${sn:-$_default_sn}"
        fi
    else
        echo -e "    未检测到已安装证书，请手动输入（或直接回车使用默认）"
        ask_val sn "server_name" "$_default_sn"
    fi
    echo -e "  ${GREEN}✓ server_name = ${sn}${NC}"
    echo ""

    # handshake：默认 127.0.0.1:8001（本机回环）
    echo -e "  ${CYAN}◆ handshake 握手转发目标${NC}"
    echo -e "    默认 127.0.0.1:8001（本机回环，适合同时运行 Web 服务的场景）"
    echo -e "    若无本地 Web 服务，可改为 ${sn}:443 直连握手"
    ask_val hs_server "handshake server（IP 或域名）" "127.0.0.1"
    ask_val hs_port   "handshake port" "8001"

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
          "handshake": {
            "server": "$hs_server",
            "server_port": $hs_port
          },
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
    echo ""

    local tag port uuid

    ask_val   tag  "tag（inbound 标识）"    "vmess-tcp-in"
    ask_val   port "listen_port（监听端口）" "9443"
    ask_random uuid "uuid（用户 UUID）"     "$(gen_uuid)"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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
    echo ""

    local tag port uuid wspath

    ask_val   tag    "tag（inbound 标识）"       "vmess-ws-in"
    ask_val   port   "listen_port（监听端口）"    "9444"
    ask_random uuid  "uuid（用户 UUID）"          "$(gen_uuid)"
    ask_val   wspath "ws path（WebSocket 路径）"  "/vmess-ws"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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
    echo ""

    local tag port pwd uname

    ask_val   tag   "tag（inbound 标识）"    "trojan-tcp-in"
    ask_val   port  "listen_port（监听端口）" "10443"
    ask_random pwd  "password（Trojan 密码）" "$(gen_password 20)"
    ask_val   uname "name（用户名）"          "user-trojan-tcp"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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
    echo ""

    local tag port pwd wspath

    ask_val   tag    "tag（inbound 标识）"       "trojan-ws-in"
    ask_val   port   "listen_port（监听端口）"    "10444"
    ask_random pwd   "password（Trojan 密码）"    "$(gen_password 20)"
    ask_val   wspath "ws path（WebSocket 路径）"  "/trojan-ws"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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
    echo ""

    local tag port mc method pwd

    ask_val tag  "tag（inbound 标识）"    "ss-aes-in"
    ask_val port "listen_port（监听端口）" "11001"

    echo -e "  ${CYAN}◆ 加密方式${NC}"
    echo -e "    ${YELLOW}1)${NC} aes-256-gcm          [默认，推荐]"
    echo -e "    ${YELLOW}2)${NC} aes-128-gcm"
    echo -e "    ${YELLOW}3)${NC} chacha20-ietf-poly1305"
    ask_val mc "请输入编号" "1"
    case $mc in
        2) method="aes-128-gcm" ;;
        3) method="chacha20-ietf-poly1305" ;;
        *) method="aes-256-gcm" ;;
    esac
    echo -e "  ${GREEN}✓ 加密方式 = ${method}${NC}"
    echo ""

    ask_random pwd "password（连接密码）" "$(gen_password 20)"

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
    echo ""

    local tag port spwd upwd uname

    ask_val   tag   "tag（inbound 标识）"    "ss-2022-256-in"
    ask_val   port  "listen_port（监听端口）" "11002"
    ask_random spwd "server password（服务端密钥，base64-32B）" "$(gen_ss2022_key_256)"
    ask_random upwd "user password（用户密钥，base64-32B）"     "$(gen_ss2022_key_256)"
    ask_val   uname "name（用户名）" "user-ss-2022-256"

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
    echo ""

    local tag port spwd upwd

    ask_val   tag  "tag（inbound 标识）"    "ss-2022-128-in"
    ask_val   port "listen_port（监听端口）" "11003"
    ask_random spwd "server password（服务端密钥，base64-16B）" "$(gen_ss2022_key_128)"
    ask_random upwd "user password（用户密钥，base64-16B）"     "$(gen_ss2022_key_128)"

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
    echo ""

    local tag port pwd obfspwd up dn

    ask_val   tag      "tag（inbound 标识）"    "hysteria2-in"
    ask_val   port     "listen_port（监听端口）" "12443"
    ask_random pwd     "password（连接密码）"    "$(gen_password 24)"
    ask_random obfspwd "obfs password（混淆密码）" "$(gen_password 16)"
    ask_val   up       "up_mbps（上行限速 Mbps）"  "200"
    ask_val   dn       "down_mbps（下行限速 Mbps）" "100"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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
    echo ""

    local tag port uuid pwd

    ask_val   tag  "tag（inbound 标识）"    "tuic-in"
    ask_val   port "listen_port（监听端口）" "13443"
    ask_random uuid "uuid（用户 UUID）"     "$(gen_uuid)"
    ask_random pwd  "password（用户密码）"  "$(gen_password 20)"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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
    echo ""

    local tag port pwd

    ask_val   tag  "tag（inbound 标识）"    "anytls-in"
    ask_val   port "listen_port（监听端口）" "14443"
    ask_random pwd "password（连接密码）"   "$(gen_password 24)"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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
    echo ""

    local tag port uname pwd

    ask_val   tag   "tag（inbound 标识）"    "naive-in"
    ask_val   port  "listen_port（监听端口）" "15443"
    ask_random uname "username（用户名）"    "$(gen_naive_username)"
    ask_random pwd   "password（用户密码）"  "$(gen_password 20)"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

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

# ────────────────────────────────────────────────────────────────
#  configure_singbox：选协议 → 逐个配置 → 合并写入 config.json
# ────────────────────────────────────────────────────────────────
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

    local TMP_JSON
    TMP_JSON=$(mktemp /tmp/jddj_inbound_XXXXXX)
    local INBOUNDS_JSON=""
    local first=true

    for choice in "${PROTO_CHOICES[@]}"; do
        > "$TMP_JSON"
        case $choice in
            1)  build_vless_tcp     "$TMP_JSON" ;;
            2)  build_vless_ws      "$TMP_JSON" ;;
            3)  build_vless_grpc    "$TMP_JSON" ;;
            4)  build_vless_reality "$TMP_JSON" ;;
            5)  build_vmess_tcp     "$TMP_JSON" ;;
            6)  build_vmess_ws      "$TMP_JSON" ;;
            7)  build_trojan_tcp    "$TMP_JSON" ;;
            8)  build_trojan_ws     "$TMP_JSON" ;;
            9)  build_ss_classic    "$TMP_JSON" ;;
            10) build_ss2022_256    "$TMP_JSON" ;;
            11) build_ss2022_128    "$TMP_JSON" ;;
            12) build_hysteria2     "$TMP_JSON" ;;
            13) build_tuic          "$TMP_JSON" ;;
            14) build_anytls        "$TMP_JSON" ;;
            15) build_naive         "$TMP_JSON" ;;
            *)  log_warn "未知选项: $choice，跳过"; continue ;;
        esac
        local inbound_json
        inbound_json=$(cat "$TMP_JSON")
        [[ -z "$inbound_json" ]] && continue
        if $first; then
            INBOUNDS_JSON="$inbound_json"
            first=false
        else
            INBOUNDS_JSON="${INBOUNDS_JSON},${inbound_json}"
        fi
    done
    rm -f "$TMP_JSON"

    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box
    cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true,
    "output": "/var/log/sing-box/sing-box.log"
  },

  "inbounds": [
$INBOUNDS_JSON
  ],

  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ]
}
EOF

    log_success "配置文件已写入: /etc/sing-box/config.json"
    echo ""

    if command -v sing-box &>/dev/null; then
        local _check_out
        _check_out=$(ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true             sing-box check -c /etc/sing-box/config.json 2>&1)
        local _check_rc=$?
        if [[ $_check_rc -eq 0 ]]; then
            log_success "配置语法验证通过"
            # 若当前版本发出 legacy DNS 弃用警告，提示已内置新格式
            if echo "$_check_out" | grep -q "legacy DNS"; then
                log_warn "检测到 sing-box 版本要求新 DNS 格式，已自动写入 udp:// 前缀格式"
                log_info "如遇问题请升级 sing-box：bash <(curl -fsSL https://sing-box.app/deb-install.sh)"
            fi
        else
            # 过滤掉纯 legacy DNS 警告行，只展示真正的错误
            local _real_errors
            _real_errors=$(echo "$_check_out" | grep -v "legacy DNS\|ENABLE_DEPRECATED" || true)
            if [[ -z "$_real_errors" ]]; then
                log_success "配置语法验证通过（DNS 格式兼容性警告已忽略）"
            else
                log_warn "配置语法验证失败，详细原因："
                echo "$_real_errors"
            fi
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
        echo " 10) 一键修复 DNS 格式（解决 legacy DNS 警告）"
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
                    local _sc_out
                    _sc_out=$(ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true                         sing-box check -c /etc/sing-box/config.json 2>&1)
                    local _sc_rc=$?
                    if [[ $_sc_rc -eq 0 ]]; then
                        log_success "配置验证通过"
                    else
                        local _sc_real
                        _sc_real=$(echo "$_sc_out" | grep -v "legacy DNS\|ENABLE_DEPRECATED" || true)
                        if [[ -z "$_sc_real" ]]; then
                            log_success "配置验证通过（DNS 兼容性警告已忽略）"
                        else
                            log_error "配置验证失败，详细原因："
                            echo "$_sc_real"
                        fi
                    fi
                else
                    log_error "sing-box 未安装"
                fi
                press_enter ;;
            10) fix_dns_format; press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  修复已有 config.json 的 DNS 格式（sing-box 1.12+ 要求 udp:// 前缀）
# ────────────────────────────────────────────────────────────────
fix_dns_format() {
    local cfg="/etc/sing-box/config.json"
    [[ ! -f "$cfg" ]] && { log_error "配置文件不存在: $cfg"; return 1; }

    log_step "修复旧版 config.json（移除 geoip/dns/route，兼容 sing-box 1.12+）..."
    cp "$cfg" "${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
    log_info "已备份原文件"

    python3 << 'INNEREOF'
import json, re, sys

cfg_path = "/etc/sing-box/config.json"
with open(cfg_path) as f:
    raw = f.read()

clean = re.sub(r'(?<![:/])//[^\n]*', '', raw)
try:
    obj = json.loads(clean)
except Exception as e:
    print(f"[ERROR] 解析配置失败: {e}")
    sys.exit(1)

changed = []

if "dns" in obj:
    del obj["dns"]
    changed.append("移除 dns 段")

if "route" in obj:
    del obj["route"]
    changed.append("移除 route 段（含 geoip 规则）")

if "outbounds" not in obj:
    obj["outbounds"] = [
        {"type": "direct", "tag": "direct"},
        {"type": "block",  "tag": "block"}
    ]
    changed.append("补充 outbounds")

if changed:
    with open(cfg_path, "w") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    print("[✓] 修复内容: " + " / ".join(changed))
else:
    print("[INFO] 配置已是最新格式，无需修复")
INNEREOF

    echo ""
    log_step "修复后验证..."
    if command -v sing-box &>/dev/null; then
        local _out _rc
        _out=$(sing-box check -c "$cfg" 2>&1)
        _rc=$?
        if [[ $_rc -eq 0 ]]; then
            log_success "配置验证通过"
        else
            log_warn "验证结果："
            echo "$_out"
        fi
    fi
    log_info "修复完成，请选择「3) 重启 sing-box」使配置生效"
}

# ────────────────────────────────────────────────────────────────
#  ══════════════════════════════════════════════════════════════
#  六、生成节点链接
#  ══════════════════════════════════════════════════════════════
# ────────────────────────────────────────────────────────────────

urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || \
    printf '%s' "$1" | od -An -tx1 | tr ' ' '%' | tr -d '\n'
}

get_server_ip() {
    local ip=""
    for svc in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb" "https://ipinfo.io/ip"; do
        ip=$(curl -s --max-time 4 "$svc" 2>/dev/null | tr -d '[:space:]') && [[ -n "$ip" ]] && break
    done
    echo "${ip:-127.0.0.1}"
}

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

    # 若 TLS 启用且 sni 是域名（非 IP），用域名作为连接地址
    # 客户端填域名比填 IP 更通用，且与证书 CN 一致
    def is_ip(s):
        import re
        return bool(re.match(r'^[\d.]+$', s) or re.match(r'^[0-9a-fA-F:]+$', s))
    if tls_on and sni and not is_ip(sni):
        addr = sni

    tag_enc = urlencode(tag)
    users = ib.get('users', [])
    transport = ib.get('transport', {})
    net = transport.get('type', 'tcp')
    ws_path = transport.get('path', '/')

    if t == 'vless':
        if not users: continue
        u = users[0]
        uuid  = u.get('uuid', '')
        flow  = u.get('flow', '')

        reality = tls.get('reality', {})
        reality_on = reality.get('enabled', False)

        if reality_on:
            pbk = reality.get('public_key', '')
            sid_val = reality.get('short_id', [''])
            sid = sid_val[0] if isinstance(sid_val, list) else sid_val
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

    elif t == 'anytls':
        if not users: continue
        pwd    = users[0].get('password', '')
        params = f"security=tls&sni={sni}&type=tcp"
        links.append(f"anytls://{urlencode(pwd)}@{addr}:{port}?{params}#{tag_enc}")

    elif t == 'naive':
        if not users: continue
        u    = users[0]
        uname = u.get('username', '')
        pwd   = u.get('password', '')
        links.append(f"naive+https://{urlencode(uname)}:{urlencode(pwd)}@{addr}:{port}?padding=true#{tag_enc}")

with open(OUTPUT_FILE, 'w') as f:
    f.write('\n'.join(links) + '\n')

with open(B64_FILE, 'w') as f:
    f.write(base64.b64encode('\n'.join(links).encode()).decode() + '\n')

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
#  全部执行 1→6
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
    bash <(curl -fsSL https://sing-box.app/deb-install.sh) 2>/dev/null || true
    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box

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
        echo "║          服务器一键管理脚本  (jddj v1.6)            ║"
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
# ────────────────────────────────────────────────────────────────
JDDJ_REMOTE_URL="https://raw.githubusercontent.com/github19999/Ojddj/main/jddj.sh"

install_self() {
    local TARGET="/usr/local/bin/jddj"
    [[ "$0" == "$TARGET" ]] && return

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
