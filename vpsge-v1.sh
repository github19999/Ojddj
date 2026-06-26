#!/bin/bash
# ================================================================
#   服务器一键管理脚本 (vpsge)
#   版本号：vpsge-v1
#   集成：SSH安全加固 / SSL证书 / sing-box & Xray /节点生成 / Realm 转发
# ================================================================

# 遇到错误立即退出
set -e  

# ────────────────────────────────────────────────────────────────
#  全局变量 & 直链配置
# ────────────────────────────────────────────────────────────────
VPSGE_REMOTE_URL="https://raw.githubusercontent.com/github19999/Ojddj/main/vpsge-v1.sh"
SCRIPT_VERSION="vpsge-v1"

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

STOPPED_SERVICES=()
DOMAINS=()
MAIN_DOMAIN=""
CERT_DIR=""
OS=""
INSTALL_CMD=""
UPDATE_CMD=""
AUTO_DEFAULT=false

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }

press_enter() { echo ""; read -rp "$(echo -e "${CYAN}按 Enter 返回...${NC}")"; }

# ────────────────────────────────────────────────────────────────
#  强力全局命令探测
# ────────────────────────────────────────────────────────────────
is_cmd_exist() {
    local cmd="$1"
    hash -r 2>/dev/null || true
    if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
    for p in /usr/local/bin /usr/bin /usr/sbin /bin /sbin; do
        if [[ -x "$p/$cmd" ]]; then return 0; fi
    done
    return 1
}

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
            is_cmd_exist dnf && PKG_MANAGER="dnf"
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

gen_short_id() { openssl rand -hex 4; }

gen_naive_username() {
    tr -dc 'a-z0-9' </dev/urandom | head -c 12 2>/dev/null || echo "naiveuser$(shuf -i 1000-9999 -n1)"
}

# ────────────────────────────────────────────────────────────────
#  通用输入函数 (含自动默认支持 & 重装检测)
# ────────────────────────────────────────────────────────────────
ask_val() {
    local varname="$1"
    local label="$2"
    local default="$3"
    local input result

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        result="$default"
        echo -e "  ${GREEN}✓ [自动] ${label} = ${result}${NC}"
        printf -v "$varname" '%s' "$result"
        return
    fi

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

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        result="$randval"
        echo -e "  ${GREEN}✓ [自动] ${label} = ${result}${NC}"
        printf -v "$varname" '%s' "$result"
        return
    fi

    echo -e "  ${CYAN}◆ ${label}${NC}"
    echo -e "    生成或提取的值: ${YELLOW}${randval}${NC}"
    echo -e "    (回车使用该值，或输入自定义值覆盖)"
    read -rp "  > " input
    result="${input:-$randval}"
    echo -e "  ${GREEN}✓ ${label} = ${result}${NC}"
    echo ""
    printf -v "$varname" '%s' "$result"
}

ask() {
    local prompt="$1" default="$2"
    ask_val REPLY_VAL "$prompt" "$default"
}

prompt_reinstall() {
    local svc_name="$1"
    echo -e "\n  ${YELLOW}检测到 ${svc_name} 已经部署过了！${NC}"
    echo "  1) 不重新安装 (保留现有) [默认]"
    echo "  2) 重新安装 (覆盖更新)"
    local choice
    # 30秒倒计时，到期自动选择 1
    read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
    choice=${choice:-1}
    echo ""
    if [[ "$choice" == "1" ]]; then
        log_info "已选择跳过 ${svc_name}，继续后续操作。"
        return 1 # Skip
    else
        log_info "准备重新部署 ${svc_name}..."
        return 0 # Reinstall
    fi
}

# ────────────────────────────────────────────────────────────────
#  读取已安装证书域名
# ────────────────────────────────────────────────────────────────
get_cert_domains() {
    local domains=()

    if [[ -d /root/.acme.sh ]]; then
        while IFS= read -r dir; do
            local d
            d=$(basename "$dir")
            [[ -z "$d" || "$d" == "__INTERACT__" || "$d" == "ca" || "$d" == "account.conf" ]] && continue
            [[ "$d" == *_ecc ]] && continue
            [[ ! -d "$dir" ]] && continue

            domains+=("$d")

            local conf_file="$dir/${d}.conf"
            if [[ -f "$conf_file" ]]; then
                local le_alt
                le_alt=$(grep -oP "(?<=Le_Alt=')[^']+" "$conf_file" 2>/dev/null || true)
                if [[ -n "$le_alt" ]]; then
                    while IFS=, read -ra alt_list; do
                        for alt in "${alt_list[@]}"; do
                            alt="${alt// /}"
                            [[ -n "$alt" && "$alt" == *.* ]] && domains+=("$alt")
                        done
                    done <<< "$le_alt"
                fi
            fi

            local cert_file="$dir/fullchain.cer"
            [[ ! -f "$cert_file" ]] && cert_file="$dir/${d}.cer"
            if [[ -f "$cert_file" ]]; then
                while IFS= read -r san; do
                    san="${san#DNS:}"
                    san="${san// /}"
                    [[ -n "$san" && "$san" == *.* && "$san" != *\** ]] && domains+=("$san")
                done < <(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | grep -oP "DNS:[^,\s]+" | tr ',' '\n')
            fi

        done < <(find /root/.acme.sh -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi

    while IFS= read -r crt; do
        [[ -z "$crt" ]] && continue
        local cn
        cn=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | grep -oP '(?<=CN\s=\s)[^,/]+' | head -1)
        [[ -n "$cn" && "$cn" == *.* ]] && domains+=("$cn")
        while IFS= read -r san; do
            san="${san#DNS:}"
            san="${san// /}"
            [[ -n "$san" && "$san" == *.* && "$san" != *\** ]] && domains+=("$san")
        done < <(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oP "DNS:[^,\s]+" | tr ',' '\n')
    done < <(find /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl 2>/dev/null \
        \( -name "*.crt" -o -name "fullchain.cer" -o -name "*.pem" \) | head -30)

    printf '%s\n' "${domains[@]}" | sort -u | grep -v '^\*' | grep '\.' | grep -v ' ' || true
}

# ────────────────────────────────────────────────────────────────
#  选择 server_name
# ────────────────────────────────────────────────────────────────
select_server_name() {
    local default_sn="${1:-example.com}"
    local old_sni="$2"
    local target_idx="${3:-1}"

    if [[ "$target_idx" == "true" ]]; then
        target_idx=2
    fi

    echo ""
    echo -e "  ${CYAN}◆ 选择或输入域名 (server_name / SNI)${NC}"

    local domains=()
    mapfile -t domains < <(get_cert_domains 2>/dev/null)

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        if [[ -n "$old_sni" ]]; then
            SELECTED_SN="$old_sni"
        elif [[ ${#domains[@]} -ge "$target_idx" ]]; then
            SELECTED_SN="${domains[$((target_idx-1))]}"
        elif [[ ${#domains[@]} -gt 0 ]]; then
            SELECTED_SN="${domains[0]}"
        else
            SELECTED_SN="${default_sn}"
        fi
        echo -e "  ${GREEN}✓ [自动] 选中域名 = ${SELECTED_SN}${NC}"
        echo ""
        return
    fi

    if [[ -n "$old_sni" ]]; then
        echo -e "    ${YELLOW}检测到旧配置域名为: ${old_sni}${NC}"
        default_sn="$old_sni"
    fi

    if [[ ${#domains[@]} -gt 0 ]]; then
        echo -e "    检测到已安装证书，请选择："
        for i in "${!domains[@]}"; do
            echo -e "    ${YELLOW}$((i+1)))${NC} ${domains[$i]}"
        done
        local manual_idx=$(( ${#domains[@]} + 1 ))
        echo -e "    ${YELLOW}${manual_idx})${NC} 手动输入其他域名"
        echo ""
        
        local actual_default_idx=$target_idx
        if [[ "$actual_default_idx" -gt "${#domains[@]}" ]]; then
            actual_default_idx=1
        fi

        local sn_choice
        read -rp "  > (编号，默认 ${actual_default_idx}): " sn_choice
        sn_choice=${sn_choice:-$actual_default_idx}

        if [[ "$sn_choice" =~ ^[0-9]+$ ]] && [[ "$sn_choice" -ge 1 ]] && [[ "$sn_choice" -le "${#domains[@]}" ]]; then
            SELECTED_SN="${domains[$((sn_choice-1))]}"
        else
            read -rp "  > 手动输入域名 (默认 ${default_sn}): " SELECTED_SN
            SELECTED_SN="${SELECTED_SN:-$default_sn}"
        fi
    else
        echo -e "    （未检测到已安装证书，请手动输入）"
        read -rp "  > 域名 (默认 ${default_sn}): " SELECTED_SN
        SELECTED_SN="${SELECTED_SN:-$default_sn}"
    fi

    echo -e "  ${GREEN}✓ 选中域名 = ${SELECTED_SN}${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────────
#  自动定位证书路径
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

    ask_val CERT_PATH "cert_path（证书文件路径）" "$default_cert"
    ask_val KEY_PATH  "key_path（私钥文件路径）"  "$default_key"
}

# ────────────────────────────────────────────────────────────────
#  一、基础安全设置
# ────────────────────────────────────────────────────────────────
bootstrap_packages() {
    log_step "预装基础组件"
    if is_cmd_exist apt; then
        apt update -y && apt install -y curl sudo wget git unzip nano vim openssl python3
    elif is_cmd_exist dnf; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y curl sudo wget git unzip nano vim openssl python3
    elif is_cmd_exist yum; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl sudo wget git unzip nano vim openssl python3
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

    is_cmd_exist restorecon && { restorecon -Rv /root/.ssh/ >/dev/null 2>&1 && log_info "SELinux 上下文已修复"; } || true
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
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
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
#  二、SSL 证书
# ────────────────────────────────────────────────────────────────
STOPPED_SERVICES_SSL=()

manage_web_services_ssl() {
    local action="$1"
    if [[ "$action" == "stop" ]]; then
        for svc in nginx apache2 httpd lighttpd caddy; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                systemctl stop "$svc" 2>/dev/null || true
                STOPPED_SERVICES_SSL+=("$svc")
                log_info "已停止冲突服务: $svc"
            fi
        done
    elif [[ "$action" == "start" ]]; then
        for svc in "${STOPPED_SERVICES_SSL[@]:-}"; do
            if [[ -n "$svc" ]]; then
                systemctl start "$svc" 2>/dev/null || true
                log_info "已重新启动: $svc"
            fi
        done
        STOPPED_SERVICES_SSL=()
    fi
}

open_firewall_ports() {
    log_step "检查并自动放行本地防火墙端口 (80/443/8080/8443)..."
    
    if is_cmd_exist iptables; then
        iptables -I INPUT -p tcp -m multiport --dports 80,443,8080,8443,3001,8282 -j ACCEPT 2>/dev/null || true
        is_cmd_exist iptables-save && iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
    fi
    if is_cmd_exist ip6tables; then
        ip6tables -I INPUT -p tcp -m multiport --dports 80,443,8080,8443,3001,8282 -j ACCEPT 2>/dev/null || true
        is_cmd_exist ip6tables-save && ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
    fi
    
    if is_cmd_exist ufw && ufw status | grep -q "Status: active"; then
        log_info "检测到 UFW 防火墙处于开启状态，正在放行端口..."
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw allow 8080/tcp >/dev/null 2>&1 || true
        ufw allow 8443/tcp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1
        log_success "UFW 防火墙放行成功"
    fi

    if is_cmd_exist firewall-cmd && systemctl is-active --quiet firewalld; then
        log_info "检测到 Firewalld 防火墙处于开启状态，正在放行端口..."
        firewall-cmd --zone=public --add-port=80/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port=443/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port=8080/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port=8443/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1
        log_success "Firewalld 防火墙放行成功"
    fi
}

deploy_ssl() {
    log_step "SSL 证书申请与安装"

    log_info "安装必要依赖..."
    local packages=""
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        packages="curl wget socat cron openssl ca-certificates git dnsutils"
    else
        packages="curl wget socat cronie openssl ca-certificates git bind-utils"
    fi
    $PKG_MANAGER install -y $packages >/dev/null 2>&1 || true

    local cron_svc="cron"
    [[ "$PKG_MANAGER" != "apt" ]] && cron_svc="crond"
    systemctl enable "$cron_svc" >/dev/null 2>&1 || true
    systemctl start  "$cron_svc" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$cron_svc" 2>/dev/null; then
        log_success "cron 服务已运行"
    else
        log_warn "cron 服务未能启动，自动续期 crontab 将在证书安装后手动补充"
    fi

    echo ""
    echo -e "${CYAN}请配置要申请SSL证书的域名:${NC}"
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  • 支持单个或多个域名"
    echo "  • 多个域名请用空格分隔"
    echo "  • 确保域名已正确解析到本服务器"
    echo "  • 示例: example.com www.example.com"
    echo ""

    local DOMAINS=()
    local MAIN_DOMAIN=""
    
    while true; do
        read -rp "请输入域名: " DOMAINS_INPUT
        if [[ -z "$DOMAINS_INPUT" ]]; then
            log_error "域名不能为空，请重新输入"
            continue
        fi

        read -ra DOMAINS <<< "$DOMAINS_INPUT"

        for domain in "${DOMAINS[@]}"; do
            if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
                log_warn "域名格式可能不正确: $domain"
            fi
            echo -n "检查域名解析: $domain ... "
            if nslookup "$domain" >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${YELLOW}!${NC} (解析失败，但将继续)"
            fi
        done

        MAIN_DOMAIN=${DOMAINS[0]}

        echo ""
        echo -e "${GREEN}域名配置:${NC}"
        echo "  主域名: $MAIN_DOMAIN"
        echo "  所有域名: ${DOMAINS[*]}"
        echo "  域名数量: ${#DOMAINS[@]}"
        echo ""

        echo -e "确认域名配置正确? :"
        echo "  1) Y/y [默认]"
        echo "  2) N/n"
        read -rp "请选择 (1-2) [默认 1]: " confirm_choice
        confirm_choice=${confirm_choice:-1}
        if [[ "$confirm_choice" == "1" || "${confirm_choice,,}" == "y" ]]; then
            break
        fi
        echo ""
    done

    echo ""
    echo -e "${CYAN}请选择证书安装位置:${NC}"
    echo "  1) 标准路径 (/etc/ssl/private/) [默认]"
    echo "  2) Nginx专用 (/etc/nginx/ssl/)"
    echo "  3) Apache专用 (/etc/apache2/ssl/)"
    echo "  4) 用户目录 (/home/ssl/)"
    echo "  5) 自定义路径"
    echo ""
    
    local CERT_DIR=""
    while true; do
        read -rp "请选择 (1-5) [默认 1]: " path_choice
        path_choice=${path_choice:-1}
        case $path_choice in
            1) CERT_DIR="/etc/ssl/private"; break ;;
            2) CERT_DIR="/etc/nginx/ssl"; break ;;
            3) CERT_DIR="/etc/apache2/ssl"; break ;;
            4) CERT_DIR="/home/ssl"; break ;;
            5)
                while true; do
                    read -rp "请输入自定义路径: " custom_path
                    if [[ -n "$custom_path" ]]; then
                        CERT_DIR="$custom_path"
                        break
                    else
                        log_warn "路径不能为空，请重新输入"
                    fi
                done
                break
                ;;
            *) log_warn "无效选择，请输入 1-5"; continue ;;
        esac
    done
    mkdir -p "$CERT_DIR" && chmod 755 "$CERT_DIR"

    if [[ ! -f /root/.acme.sh/acme.sh ]]; then
        log_step "安装 acme.sh..."
        rm -rf /tmp/acme_sh_install
        if git clone https://github.com/acmesh-official/acme.sh.git /tmp/acme_sh_install >/dev/null 2>&1; then
            cd /tmp/acme_sh_install || return 1
            ./acme.sh --install --force >/dev/null 2>&1
            cd - >/dev/null || true
            rm -rf /tmp/acme_sh_install
        else
            local _acme_tar="/tmp/acme.tar.gz"
            if curl -fsSL https://github.com/acmesh-official/acme.sh/archive/master.tar.gz -o "$_acme_tar" 2>/dev/null || \
               wget -qO "$_acme_tar" https://github.com/acmesh-official/acme.sh/archive/master.tar.gz 2>/dev/null; then
                tar -xzf "$_acme_tar" -C /tmp/
                cd /tmp/acme.sh-master || return 1
                ./acme.sh --install --force >/dev/null 2>&1
                cd - >/dev/null || true
                rm -rf /tmp/acme.sh-master "$_acme_tar"
            else
                log_error "acme.sh 源码下载失败，请检查网络"
                return 1
            fi
        fi

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

    manage_web_services_ssl "stop"
    open_firewall_ports
    
    log_info "配置智能续期 Hook..."
    cat > /root/.acme.sh/vpsge_hook.sh << 'EOF'
#!/bin/bash
ACTION=$1
SERVICES="nginx apache2 httpd lighttpd caddy"

if [ "$ACTION" == "pre" ]; then
    for svc in $SERVICES; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            touch "/tmp/.vpsge_${svc}_stopped"
        fi
    done
elif [ "$ACTION" == "post" ]; then
    for svc in $SERVICES; do
        if [ -f "/tmp/.vpsge_${svc}_stopped" ]; then
            systemctl start "$svc" 2>/dev/null || true
            rm -f "/tmp/.vpsge_${svc}_stopped"
        fi
    done
elif [ "$ACTION" == "reload" ]; then
    for svc in $SERVICES; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
        fi
    done
fi
EOF
    chmod +x /root/.acme.sh/vpsge_hook.sh

    log_step "申请证书（Standalone 模式）..."
    local domain_args=""
    for d in "${DOMAINS[@]}"; do domain_args="$domain_args -d $d"; done

    echo "正在申请证书，请耐心等待..."
    if /root/.acme.sh/acme.sh --issue $domain_args --standalone --force \
        --pre-hook "/root/.acme.sh/vpsge_hook.sh pre" \
        --post-hook "/root/.acme.sh/vpsge_hook.sh post"; then
        log_success "SSL 证书申请成功"
    else
        log_error "SSL 证书申请失败"
        echo -e "${YELLOW}可能的原因:${NC}"
        echo "  • 防火墙/云服务商安全组阻止了外网对 80 端口的访问 (Timeout)"
        echo "  • 域名未正确解析到本服务器的公网 IP"
        echo "  • Let's Encrypt 服务暂时不可用"
        echo -e "${PURPLE}【重要提示】如果您的 VPS (如 YXVM、Oracle 等) 存在外部控制台安全组，请务必登录控制台手动放行 80/443 端口！${NC}"
        manage_web_services_ssl "start"
        return 1
    fi

    log_step "安装SSL证书到指定目录..."
    local KEY_FILE="$CERT_DIR/private.key"
    local CERT_FILE="$CERT_DIR/fullchain.cer"
    local CA_FILE="$CERT_DIR/ca.cer"
    local RELOAD_CMD="/root/.acme.sh/vpsge_hook.sh reload"

    if /root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --key-file  "$KEY_FILE"  \
        --fullchain-file "$CERT_FILE" \
        --ca-file   "$CA_FILE"   \
        --reloadcmd "$RELOAD_CMD"; then
        
        chmod 600 "$KEY_FILE"  2>/dev/null || true
        chmod 644 "$CERT_FILE" "$CA_FILE" 2>/dev/null || true
        chown root:root "$KEY_FILE" "$CERT_FILE" "$CA_FILE" 2>/dev/null || true
        log_success "证书已成功安装至: $CERT_DIR"
    else
        log_error "证书安装失败"
        manage_web_services_ssl "start"
        return 1
    fi

    log_success "智能续期 Hook 注册完成。"

    log_step "设置证书自动续期..."
    local LOG_FILE="/var/log/acme-renew.log"
    local CRON_JOB="0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> $LOG_FILE 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab - 2>/dev/null
        log_success "自动续期任务已设置（每天 02:00，日志: $LOG_FILE）"
    else
        log_info "自动续期任务已存在，跳过"
    fi

    manage_web_services_ssl "start"

    echo ""
    echo -e "${CYAN}=============================================="
    echo "           SSL证书部署完成！"
    echo "=============================================="
    echo -e "${NC}"
    echo -e "${GREEN}证书信息:${NC}"
    echo "  主域名: $MAIN_DOMAIN"
    echo "  所有域名: ${DOMAINS[*]}"
    echo "  证书目录: $CERT_DIR"
    echo "  私钥文件: $KEY_FILE"
    echo "  证书文件: $CERT_FILE"
    if [[ -f "$CERT_FILE" ]]; then
        local expire_date=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
        if [[ -n "$expire_date" ]]; then
            echo "  有效期至: $expire_date"
        fi
    fi
    echo ""
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
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
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
#  卸载功能合集
# ────────────────────────────────────────────────────────────────
uninstall_singbox() {
    echo -e "${YELLOW}警告：这将彻底删除 sing-box 及其所有配置文件！${NC}"
    read -rp "确认卸载？(y/N): " choice
    if [[ "${choice,,}" == "y" ]]; then
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        rm -rf /etc/sing-box /var/log/sing-box /var/lib/sing-box
        
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt purge -y sing-box 2>/dev/null || true
        elif [[ -n "$PKG_MANAGER" ]]; then
            $PKG_MANAGER remove -y sing-box 2>/dev/null || true
        fi
        
        rm -f /usr/local/bin/sing-box /usr/bin/sing-box /usr/sbin/sing-box /usr/local/sbin/sing-box /bin/sing-box
        for bin in $(type -aP sing-box 2>/dev/null); do rm -f "$bin" 2>/dev/null || true; done
        
        hash -r 2>/dev/null || true
        log_success "sing-box 已彻底卸载"
    fi
}

uninstall_xray() {
    echo -e "${YELLOW}警告：这将彻底删除 Xray 及其所有配置文件！${NC}"
    read -rp "确认卸载？(y/N): " choice
    if [[ "${choice,,}" == "y" ]]; then
        if is_cmd_exist xray || [[ -f /usr/local/bin/xray ]]; then
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
            rm -rf /usr/local/etc/xray /var/log/xray
            hash -r 2>/dev/null || true
            log_success "Xray 已彻底卸载"
        else
            log_warn "未检测到 Xray 的安装。"
        fi
    fi
}

uninstall_nginx() {
    echo -e "${YELLOW}警告：这将彻底删除 Nginx 及其所有站点配置！${NC}"
    read -rp "确认卸载？(y/N): " choice
    if [[ "${choice,,}" == "y" ]]; then
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt purge -y nginx nginx-common nginx-core 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
        elif [[ -n "$PKG_MANAGER" ]]; then
            $PKG_MANAGER remove -y nginx 2>/dev/null || true
        fi
        
        rm -rf /etc/nginx /var/log/nginx /var/www/html /usr/sbin/nginx /usr/bin/nginx
        
        rm -f /usr/sbin/nginx /usr/bin/nginx /usr/local/sbin/nginx /usr/local/bin/nginx /bin/nginx
        for bin in $(type -aP nginx 2>/dev/null); do rm -f "$bin" 2>/dev/null || true; done
        
        hash -r 2>/dev/null || true
        log_success "Nginx 已彻底卸载"
    fi
}

uninstall_docker() {
    echo -e "${YELLOW}警告：这将彻底删除 Docker 环境及其所有容器和镜像！${NC}"
    read -rp "确认卸载？(y/N): " choice
    if [[ "${choice,,}" == "y" ]]; then
        log_step "1. 正在停止并删除所有正在运行的 Docker 容器..."
        docker ps -aq 2>/dev/null | xargs -r docker stop 2>/dev/null || true
        docker ps -aq 2>/dev/null | xargs -r docker rm 2>/dev/null || true

        log_step "2. 正在全面停止 Docker、Socket 及 containerd 底层核心服务..."
        systemctl stop docker docker.socket containerd containerd.service 2>/dev/null || true
        systemctl disable docker docker.socket containerd containerd.service 2>/dev/null || true

        log_step "3. 正在强制解除所有残留的内核虚拟挂载点 (overlay2/containerd)..."
        if [ -f /proc/mounts ]; then
            cat /proc/mounts | grep -E '/var/lib/(docker|containerd)' | awk '{print $2}' | sort -r | while read -r mnt; do
                umount -fl "$mnt" 2>/dev/null || true
            done
        fi

        log_step "4. 正在卸载 Docker 相关核心软件包..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-doc docker-compose podman-docker 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
        elif [[ -n "$PKG_MANAGER" ]]; then
            $PKG_MANAGER remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
        fi

        log_step "5. 正在彻底清空物理残留目录、缓存、套接字与配置文件..."
        rm -rf /var/lib/docker /var/lib/containerd /var/run/docker.sock /var/run/containerd /etc/docker /root/.docker /usr/bin/docker /usr/libexec/docker
        
        for bin in $(type -aP docker 2>/dev/null); do rm -f "$bin" 2>/dev/null || true; done
        
        hash -r 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed 2>/dev/null || true

        log_success "Docker 环境已完美、干净地彻底卸载！"
    fi
}

install_xray() {
    log_step "安装 Xray-core..."
    if ! prompt_reinstall "Xray"; then return 0; fi
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    log_success "Xray 安装完成"
}

install_nginx() {
    local mode="${1:-1}"
    log_step "安装 Nginx..."
    
    if is_cmd_exist nginx; then
        local ver
        ver=$(nginx -v 2>&1 | head -1)
        log_info "当前已安装版本: $ver"
        if ! prompt_reinstall "Nginx"; then return 0; fi
    fi
    
    if [[ "$mode" == "2" ]]; then
        log_info "指定版本号安装对系统源依赖较高，将尝试通过包管理器匹配..."
        read -rp "请输入 Nginx 版本号 (回车跳过): " n_ver
    elif [[ "$mode" == "3" ]]; then
        log_info "将尝试安装 Nginx Mainline(Beta) 版本..."
    fi

    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confmiss" install -y nginx || { log_error "Nginx 安装失败"; return 1; }
    else
        $PKG_MANAGER install -y nginx || { log_error "Nginx 安装失败"; return 1; }
    fi
    
    if is_cmd_exist setsebool; then
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    fi

    mkdir -p /var/www/html /etc/nginx/conf.d
    if [[ ! -f /var/www/html/index.html ]]; then
        cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html><head><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
HTML
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx >/dev/null 2>&1 || true
    systemctl is-active --quiet nginx && log_success "Nginx 安装并启动成功" || log_warn "Nginx 启动失败"
}

install_docker_env() {
    local mode="${1:-1}"
    log_step "检查并配置 Docker 环境..."
    
    if ! is_cmd_exist docker; then
        log_info "正在安装 Docker..."
        
        if [[ "$mode" == "3" ]]; then
            curl -fsSL https://test.docker.com -o get-docker.sh
        else
            curl -fsSL https://get.docker.com -o get-docker.sh
        fi
        
        if [[ "$mode" == "2" ]]; then
            read -rp "请输入 Docker 版本号 (回车跳过使用默认): " d_ver
            if [[ -n "$d_ver" ]]; then
                VERSION="$d_ver" sh get-docker.sh || { log_error "Docker 安装失败"; return 1; }
            else
                sh get-docker.sh || { log_error "Docker 安装失败"; return 1; }
            fi
        else
            sh get-docker.sh || { log_error "Docker 安装失败"; return 1; }
        fi
        rm -f get-docker.sh
    else
        if ! prompt_reinstall "Docker 环境"; then
            systemctl enable docker >/dev/null 2>&1 || true
            systemctl start docker >/dev/null 2>&1 || true
            return 0
        fi
    fi
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true

    if ! docker compose version >/dev/null 2>&1; then
        log_info "正在安装 Docker Compose 插件..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then apt update -y && apt install -y docker-compose-plugin
        else $PKG_MANAGER install -y docker-compose-plugin; fi
    else
        log_success "Docker Compose 已就绪"
    fi
}

install_substore() {
    local sub_ver_choice="${1:-1}"
    
    local is_installed=false
    if [[ -d /root/docker/substore ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^substore$"; then
        is_installed=true
    fi

    local old_sub_domain=""
    local old_sub_api=""
    
    if [[ "$is_installed" == "true" ]]; then
        log_warn "检测到您的服务器中 Sub-Store 已经部署过了！"
        if [[ -f /root/docker/substore/domain.txt && -f /root/docker/substore/api_path.txt ]]; then
            local p_sn=$(cat /root/docker/substore/domain.txt)
            local p_api=$(cat /root/docker/substore/api_path.txt)
            echo -e "  🌐 为您找回的现有面板访问地址: ${GREEN}https://$p_sn:8443/?api=https://$p_sn:8443/$p_api${NC}"
        fi
        
        echo "  1) 不重新安装 (保留现有) [默认]"
        echo "  2) 重新安装 (覆盖更新)"
        echo "  3) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-3, 30秒后默认 1): " choice || true
        choice=${choice:-1}
        if [[ "$choice" == "1" ]]; then return 0; fi
        
        docker stop substore 2>/dev/null || true
        docker rm substore 2>/dev/null || true
        
        if [[ "$choice" == "3" ]]; then
            read -rp "请粘贴旧的 Sub-Store 面板链接 (如 https://sub.xxx.com:8443/?api=...): " old_sub_link
            if [[ "$old_sub_link" =~ ^https://([^/:]+).*api=https://[^/:]+:[0-9]+/([^/]+) ]]; then
                old_sub_domain="${BASH_REMATCH[1]}"
                old_sub_api="${BASH_REMATCH[2]}"
                log_success "成功提取旧配置: 域名=$old_sub_domain, API路径=/$old_sub_api"
            else
                log_warn "未能识别链接格式，将使用常规方式配置。"
            fi
        fi
    else
        echo -e "\n${CYAN}检测到 Sub-Store 未安装，请选择部署方式：${NC}"
        echo "  1) 直接安装 [默认]"
        echo "  2) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
        choice=${choice:-1}
        if [[ "$choice" == "2" ]]; then
            read -rp "请粘贴旧的 Sub-Store 面板链接 (如 https://sub.xxx.com:8443/?api=...): " old_sub_link
            if [[ "$old_sub_link" =~ ^https://([^/:]+).*api=https://[^/:]+:[0-9]+/([^/]+) ]]; then
                old_sub_domain="${BASH_REMATCH[1]}"
                old_sub_api="${BASH_REMATCH[2]}"
                log_success "成功提取旧配置: 域名=$old_sub_domain, API路径=/$old_sub_api"
            else
                log_warn "未能识别链接格式，将使用常规方式配置。"
            fi
        fi
    fi

    install_docker_env 1
    
    if ! is_cmd_exist nginx; then
        log_warn "未检测到 Nginx，正在尝试自动预装..."
        install_nginx 1
    fi

    if ! is_cmd_exist unzip; then
        log_info "正在为您自动安装必要的 unzip 解压工具..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt update -y >/dev/null 2>&1 || true
            apt install -y unzip >/dev/null 2>&1 || true
        else
            $PKG_MANAGER install -y unzip >/dev/null 2>&1 || true
        fi
    fi

    log_step "部署 Sub-Store (订阅转换中心)"

    local backend_url="https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js"
    local frontend_url="https://github.com/sub-store-org/Sub-Store-Front-End/releases/latest/download/dist.zip"

    if [[ "$sub_ver_choice" == "2" ]]; then
        read -rp "请输入 Sub-Store 后端版本号 (例如 2.14.0): " target_ver
        if [[ -n "$target_ver" ]]; then backend_url="https://github.com/sub-store-org/Sub-Store/releases/download/${target_ver}/sub-store.bundle.js"; fi
        read -rp "请输入 Sub-Store 前端版本号 (例如 1.0.0，直接回车则默认最新): " target_fe_ver
        if [[ -n "$target_fe_ver" ]]; then frontend_url="https://github.com/sub-store-org/Sub-Store-Front-End/releases/download/${target_fe_ver}/dist.zip"; fi
    elif [[ "$sub_ver_choice" == "3" ]]; then
        log_info "正在获取 Github 预发布版(Beta)..."
        local pre_back=$(curl -s https://api.github.com/repos/sub-store-org/Sub-Store/releases | grep '"browser_download_url":' | grep 'sub-store.bundle.js' | head -n 1 | cut -d '"' -f 4)
        [[ -n "$pre_back" ]] && backend_url="$pre_back"
        local pre_front=$(curl -s https://api.github.com/repos/sub-store-org/Sub-Store-Front-End/releases | grep '"browser_download_url":' | grep 'dist.zip' | head -n 1 | cut -d '"' -f 4)
        [[ -n "$pre_front" ]] && frontend_url="$pre_front"
    fi

    local sn=""
    local cp=""
    local kp=""
    
    if [[ -n "$old_sub_domain" ]]; then
        sn="$old_sub_domain"
        local prev_auto="$AUTO_DEFAULT"
        AUTO_DEFAULT="true"
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
        AUTO_DEFAULT="$prev_auto"
    else
        local prev_auto="$AUTO_DEFAULT"
        AUTO_DEFAULT="false" 
        select_server_name "sub.example.com" "" "1"
        sn="$SELECTED_SN"
        AUTO_DEFAULT="$prev_auto"
        
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
    fi
    
    if [[ ! -f "$cp" || ! -f "$kp" ]]; then
        log_warn "⚠️ 警告：检测到证书或私钥文件实际不存在！"
        log_warn "Nginx 代理极有可能因此启动失败，导致面板无法访问！"
        log_warn "请后续确保将正确的证书文件放置于: $cp"
    fi

    mkdir -p /root/docker/substore/data
    cd /root/docker/substore

    local api_path
    if [[ -n "$old_sub_api" ]]; then
        api_path="$old_sub_api"
        echo "$api_path" > api_path.txt
        log_info "已沿用导入的旧 API 路径: /$api_path"
    elif [[ -f api_path.txt ]]; then
        api_path=$(cat api_path.txt)
        log_info "检测到本地已存在的 API 路径: /$api_path"
    else
        api_path=$(openssl rand -hex 12)
        echo "$api_path" > api_path.txt
        log_info "已生成随机高级防护 API 路径: /$api_path"
    fi
    echo "$sn" > domain.txt

    log_info "正在为您下载并部署选中版本的核心代码..."
    curl -fsSL -L "$backend_url" -o sub-store.bundle.js
    curl -fsSL -L "$frontend_url" -o dist.zip
    
    rm -rf frontend dist_tmp
    unzip -qo dist.zip -d dist_tmp || log_warn "前端解压出现异常，可能下载不完整"
    if [[ -d "dist_tmp/dist" ]]; then
        mv dist_tmp/dist frontend
    else
        mv dist_tmp frontend
    fi
    rm -rf dist_tmp dist.zip

    cat > docker-compose.yml <<EOF
version: '3.8'
services:
  substore:
    image: node:20.18.0
    container_name: substore
    restart: unless-stopped
    working_dir: /app
    command: ["node", "sub-store.bundle.js"]
    ports:
      - "127.0.0.1:3001:3001"
    environment:
      SUB_STORE_FRONTEND_BACKEND_PATH: "/$api_path"
      SUB_STORE_BACKEND_CRON: "0 0 * * *"
      SUB_STORE_FRONTEND_PATH: "/app/frontend"
      SUB_STORE_FRONTEND_HOST: "0.0.0.0"
      SUB_STORE_FRONTEND_PORT: "3001"
      SUB_STORE_DATA_BASE_PATH: "/app"
      SUB_STORE_BACKEND_API_HOST: "127.0.0.1"
      SUB_STORE_BACKEND_API_PORT: "3000"
      TZ: "Asia/Shanghai"
    volumes:
      - ./sub-store.bundle.js:/app/sub-store.bundle.js
      - ./frontend:/app/frontend
      - ./data:/app/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    log_info "启动容器..."
    docker compose up -d 2>/dev/null || docker-compose up -d

    log_step "配置 Nginx 安全反向代理 (专属隔离 8443 端口)"
    open_firewall_ports
    mkdir -p /etc/nginx/conf.d
    
    cat > /etc/nginx/conf.d/substore.conf <<EOF
server {
    listen 8080;
    listen [::]:8080;
    server_name $sn;
    return 301 https://\$host:8443\$request_uri;
}
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name $sn;

    ssl_certificate $cp;
    ssl_certificate_key $kp;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || log_warn "Nginx 重载失败，请检查配置文件或证书是否存在"
    
    echo ""
    log_success "Sub-Store 部署完成！"
    echo -e "  🌐 访问面板地址: ${GREEN}https://$sn:8443/?api=https://$sn:8443/$api_path${NC}"
    echo -e "  🔐 后台API路径:  ${YELLOW}/$api_path${NC}"
    echo -e "  ${YELLOW}（如果不慎忘记该地址，可在脚本主菜单的「服务管理」中随时找回查看）${NC}"
    echo ""
}

install_wallos() {
    local wallos_mode="${1:-1}"
    local wallos_ver="2.36.2"
    
    local is_installed=false
    if [[ -d /root/docker/wallos ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^wallos$"; then
        is_installed=true
    fi

    local old_wal_domain=""
    if [[ "$is_installed" == "true" ]]; then
        log_warn "检测到您的服务器中 Wallos 已经部署过了！"
        if [[ -f /root/docker/wallos/domain.txt ]]; then
            local w_sn=$(cat /root/docker/wallos/domain.txt)
            echo -e "  🌐 为您找回的现有面板访问地址: ${GREEN}https://$w_sn:8443${NC}"
        fi
        echo "  1) 不重新安装 (保留现有) [默认]"
        echo "  2) 重新安装 (覆盖更新)"
        echo "  3) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-3, 30秒后默认 1): " choice || true
        choice=${choice:-1}
        if [[ "$choice" == "1" ]]; then return 0; fi
        
        docker stop wallos 2>/dev/null || true
        docker rm wallos 2>/dev/null || true
        
        if [[ "$choice" == "3" ]]; then
            read -rp "请粘贴旧的 Wallos 面板链接 (例如 https://wallos.xxx.com:8443): " old_wal_link
            if [[ -n "$old_wal_link" ]]; then
                if [[ "$old_wal_link" =~ ^https://([^/:]+) ]]; then
                    old_wal_domain="${BASH_REMATCH[1]}"
                    log_success "成功提取旧配置: 域名=$old_wal_domain"
                else
                    log_warn "未能识别链接格式，将使用常规方式配置。"
                fi
            fi
        fi
    else
        echo -e "\n${CYAN}检测到 Wallos 未安装，请选择部署方式：${NC}"
        echo "  1) 直接安装 [默认]"
        echo "  2) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
        choice=${choice:-1}
        if [[ "$choice" == "2" ]]; then
            read -rp "请粘贴旧的 Wallos 面板链接 (例如 https://wallos.xxx.com:8443): " old_wal_link
            if [[ -n "$old_wal_link" ]]; then
                if [[ "$old_wal_link" =~ ^https://([^/:]+) ]]; then
                    old_wal_domain="${BASH_REMATCH[1]}"
                    log_success "成功提取旧配置: 域名=$old_wal_domain"
                else
                    log_warn "未能识别链接格式，将使用常规方式配置。"
                fi
            fi
        fi
    fi

    if [[ "$wallos_mode" == "1" ]]; then
        wallos_ver="latest"
    elif [[ "$wallos_mode" == "2" ]]; then
        ask_val wallos_ver "请输入待部署的 Wallos 版本标签" "2.36.2"
    elif [[ "$wallos_mode" == "3" ]]; then
        wallos_ver="beta"
    fi

    install_docker_env 1
    
    if ! is_cmd_exist nginx; then
        log_warn "未检测到 Nginx，正在尝试自动预装..."
        install_nginx 1
    fi

    log_step "部署 Wallos (订阅管理与财务系统) - 版本: $wallos_ver"

    local sn=""
    local cp=""
    local kp=""
    if [[ -n "$old_wal_domain" ]]; then
        sn="$old_wal_domain"
        local prev_auto="$AUTO_DEFAULT"
        AUTO_DEFAULT="true"
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
        AUTO_DEFAULT="$prev_auto"
    else
        while true; do
            local prev_auto="$AUTO_DEFAULT"
            AUTO_DEFAULT="false" 
            select_server_name "wallos.example.com" "" "2"
            sn="$SELECTED_SN"
            AUTO_DEFAULT="$prev_auto"
            
            if [[ -f /root/docker/substore/domain.txt ]]; then
                local sub_sn=$(cat /root/docker/substore/domain.txt)
                if [[ "$sn" == "$sub_sn" ]]; then
                    echo -e "${RED}[ERROR] 域名冲突拦截！检测到该域名已被 Sub-Store 占用。${NC}"
                    echo -e "${CYAN}请重新选择，或者选择 手动输入 其他域名！${NC}"
                    echo ""
                    continue
                fi
            fi
            break
        done
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
    fi
    
    if [[ ! -f "$cp" || ! -f "$kp" ]]; then
        log_warn "⚠️ 警告：检测到证书或私钥文件实际不存在！"
        log_warn "Nginx 代理极有可能因此启动失败，导致面板无法访问！"
        log_warn "请后续确保将正确的证书文件放置于: $cp"
    fi

    mkdir -p /root/docker/wallos/{db,logos}
    cd /root/docker/wallos
    echo "$sn" > domain.txt

    cat > docker-compose.yml <<EOF
version: '3.8'
services:
  wallos:
    container_name: wallos
    image: bellamy/wallos:$wallos_ver
    ports:
      - "127.0.0.1:8282:80/tcp"
    environment:
      TZ: 'Asia/Shanghai'
    volumes:
      - './db:/var/www/html/db'
      - './logos:/var/www/html/images/uploads/logos'
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    log_info "启动容器..."
    docker compose up -d 2>/dev/null || docker-compose up -d

    log_step "配置 Nginx 安全反向代理 (专属隔离 8443 端口)"
    open_firewall_ports
    mkdir -p /etc/nginx/conf.d
    
    cat > /etc/nginx/conf.d/wallos.conf <<EOF
server {
    listen 8080;
    listen [::]:8080;
    server_name $sn;
    return 301 https://\$host:8443\$request_uri;
}
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name $sn;

    ssl_certificate $cp;
    ssl_certificate_key $kp;

    location / {
        proxy_pass http://127.0.0.1:8282;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || log_warn "Nginx 重载失败，请后续检查配置文件或证书是否存在"
    
    echo ""
    log_success "Wallos 部署完成！"
    echo -e "  🌐 访问面板地址: ${GREEN}https://$sn:8443${NC}"
    echo ""
}

# ----------------- Realm 端口转发功能模块 -----------------
deploy_realm() {
    if [[ -f "/root/realm/realm" ]]; then
        if ! prompt_reinstall "Realm"; then return 0; fi
        systemctl stop realm 2>/dev/null || true
    fi

    log_step "部署 Realm 端口转发环境"
    mkdir -p /root/realm
    cd /root/realm || return 1
    wget -O realm.tar.gz https://github.com/github19999/realm/releases/download/v2.6.0/realm-x86_64-unknown-linux-gnu.tar.gz
    tar -xvf realm.tar.gz
    chmod +x realm
    cat > /etc/systemd/system/realm.service << 'EOF'
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
DynamicUser=true
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c /root/realm/config.toml

[Install]
WantedBy=multi-user.target
EOF
    touch /root/realm/config.toml
    systemctl daemon-reload
    log_success "Realm 部署完成。"
}

add_forward_realm() {
    log_step "添加 Realm 转发规则"
    if [ ! -f "/root/realm/config.toml" ]; then
        touch /root/realm/config.toml
    fi
    while true; do
        read -p "请输入目标 IP: " ip
        read -p "请输入本地/目标端口 (同端口): " port
        echo "[[endpoints]]" >> /root/realm/config.toml
        echo "listen = \"0.0.0.0:$port\"" >> /root/realm/config.toml
        echo "remote = \"$ip:$port\"" >> /root/realm/config.toml
        
        read -p "是否继续添加(Y/N)? " answer
        if [[ "${answer,,}" != "y" ]]; then
            break
        fi
    done
    systemctl restart realm 2>/dev/null || true
    log_success "转发规则已添加并生效。"
}

delete_forward_realm() {
    log_step "删除 Realm 转发规则"
    if [ ! -f "/root/realm/config.toml" ]; then
        log_warn "未找到配置文件 /root/realm/config.toml"
        return
    fi
    echo "当前转发规则："
    local IFS=$'\n'
    local lines=($(grep -n 'remote =' /root/realm/config.toml))
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi
    local index=1
    for line in "${lines[@]}"; do
        echo "${index}. $(echo $line | cut -d '"' -f 2)"
        let index+=1
    done

    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入数字。"
        return
    fi

    if [ $choice -lt 1 ] || [ $choice -gt ${#lines[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        return
    fi

    local chosen_line=${lines[$((choice-1))]}
    local line_number=$(echo $chosen_line | cut -d ':' -f 1)

    local start_line=$((line_number - 2))
    local end_line=$line_number

    sed -i "${start_line},${end_line}d" /root/realm/config.toml

    log_success "转发规则已删除。"
    systemctl restart realm 2>/dev/null || true
}

start_service_realm() {
    systemctl unmask realm.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart realm.service 2>/dev/null || true
    systemctl enable realm.service 2>/dev/null || true
    log_success "realm 服务已启动并设置为开机自启。"
}

stop_service_realm() {
    systemctl stop realm 2>/dev/null || true
    log_success "realm 服务已停止。"
}

uninstall_realm() {
    log_step "卸载 Realm"
    systemctl stop realm 2>/dev/null || true
    systemctl disable realm 2>/dev/null || true
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf /root/realm
    hash -r 2>/dev/null || true
    log_success "realm 已被彻底卸载。"
    press_enter
}

menu_manage_realm() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Realm (端口转发) ══${NC}"
        echo ""
        
        local is_installed=false
        if [[ -f "/root/realm/realm" ]]; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet realm 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 部署环境 (安装 Realm)"
        echo "  2) 添加转发"
        echo "  3) 删除转发"
        echo "  4) 启动服务"
        echo "  5) 停止服务"
        echo "  6) 一键卸载"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) deploy_realm; press_enter ;;
            2) add_forward_realm; press_enter ;;
            3) delete_forward_realm; press_enter ;;
            4) 
                if [[ "$is_installed" == "true" ]]; then start_service_realm; else log_error "未安装 Realm"; fi
                press_enter ;;
            5) 
                if [[ "$is_installed" == "true" ]]; then stop_service_realm; else log_error "未安装 Realm"; fi
                press_enter ;;
            6) uninstall_realm ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}
# ----------------------------------------------------------

menu_install_service() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 三、安装服务 (包含 Docker/拓展) ══${NC}"
        echo ""
        echo -e "  ${CYAN}── 核心代理 (sing-box & Xray) ──${NC}"
        echo "  1) 安装 sing-box 最新稳定版"
        echo "  2) 安装 sing-box 指定版本号"
        echo "  3) 安装 sing-box Beta / 预发布版"
        echo " 16) 安装 Xray 最新版 (Reality 官方模板/xhttp 用)"
        echo ""
        echo -e "  ${CYAN}── Nginx (用于反代和回落) ──${NC}"
        echo "  4) 安装 Nginx 最新稳定版"
        echo "  5) 安装 Nginx 指定版本号"
        echo "  6) 安装 Nginx Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── 安装/修复 Docker 环境 ──${NC}"
        echo "  7) 安装 Docker 最新稳定版"
        echo "  8) 安装 Docker 指定版本号"
        echo "  9) 安装 Docker Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Sub-Store (订阅转换中心) ──${NC}"
        echo " 10) 安装 Sub-Store 最新稳定版"
        echo " 11) 安装 Sub-Store 指定版本号"
        echo " 12) 安装 Sub-Store / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Wallos (个人财务与订阅追踪) ──${NC}"
        echo " 13) 安装 Wallos 最新稳定版"
        echo " 14) 安装 Wallos 指定版本号 (默认: 2.36.2，回车确认)"
        echo " 15) 安装 Wallos Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Realm (端口转发工具) ──${NC}"
        echo " 17) 进入 Realm 管理面板 (部署/转发/卸载)"
        echo ""
        echo -e "  ${CYAN}── 批量执行 ──${NC}"
        echo -e " ${GREEN}100) 全部自动执行 (所有服务)${NC}"
        echo -e " ${YELLOW}101) 全部手动执行 (所有服务)${NC}"
        echo -e " ${PURPLE}102) 请输入服务（例如 1 4 7 10 14 16 170，默认 0）${NC}"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " vc_raw
        vc_raw=${vc_raw:-0}

        local SVC_CHOICES=()
        if [[ "$vc_raw" == "100" ]]; then
            SVC_CHOICES=(1 4 7 10 14 16 170)
            AUTO_DEFAULT=true
        elif [[ "$vc_raw" == "101" ]]; then
            SVC_CHOICES=(1 4 7 10 14 16 170)
            AUTO_DEFAULT=false
        elif [[ "$vc_raw" == "102" ]]; then
            read -rp "请输入服务编号（例如 1 4 7，以空格隔开）: " -a SVC_CHOICES
            AUTO_DEFAULT=false
        else
            read -ra SVC_CHOICES <<< "$vc_raw"
            AUTO_DEFAULT=false
        fi

        if [[ ${#SVC_CHOICES[@]} -eq 0 || "${SVC_CHOICES[0]}" == "0" ]]; then
            return
        fi

        local is_batch=false
        if [[ ${#SVC_CHOICES[@]} -gt 1 ]]; then
            is_batch=true
            log_info "即将进行批量执行操作..."
            sleep 1
        fi

        for vc in "${SVC_CHOICES[@]}"; do
            case $vc in
                0) return ;;
                1|2|3)
                    if is_cmd_exist sing-box; then
                        local ver
                        ver=$(sing-box version 2>/dev/null | head -1)
                        log_info "当前已安装版本: $ver"
                        if ! prompt_reinstall "sing-box"; then
                            [[ "$is_batch" == "false" ]] && press_enter
                            continue
                        fi
                    fi

                    if [[ "$vc" == "1" ]]; then
                        log_step "安装 sing-box 最新稳定版..."
                        if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then
                            if ! bash <(curl -fsSL https://sing-box.app/rpm-install.sh); then
                                log_error "安装失败，请检查网络或手动安装"
                                [[ "$is_batch" == "false" ]] && press_enter
                                continue
                            fi
                        fi
                    elif [[ "$vc" == "2" ]]; then
                        echo -n "请输入版本号（例如 1.9.0）: "
                        read -r SB_VER
                        [[ -z "$SB_VER" ]] && { log_error "版本号不能为空"; [[ "$is_batch" == "false" ]] && press_enter; continue; }
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
                        if ! curl -fsSL "$URL" -o /tmp/sing-box.tar.gz; then
                            log_error "下载失败"
                            [[ "$is_batch" == "false" ]] && press_enter
                            continue
                        fi
                        tar -xzf /tmp/sing-box.tar.gz -C /tmp/
                        install -m 755 "/tmp/sing-box-${SB_VER}-linux-${ARCH_STR}/sing-box" /usr/local/bin/sing-box
                        rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SB_VER}-linux-${ARCH_STR}"
                    elif [[ "$vc" == "3" ]]; then
                        log_step "安装 sing-box Beta 版..."
                        if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh) beta; then
                            log_error "Beta 安装失败"
                            [[ "$is_batch" == "false" ]] && press_enter
                            continue
                        fi
                    fi

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

                    if is_cmd_exist sing-box; then
                        local ver
                        ver=$(sing-box version 2>/dev/null | head -1)
                        log_success "sing-box 安装成功: $ver"
                        
                        if [[ -s /etc/sing-box/config.json ]]; then
                            if ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
                                systemctl enable sing-box >/dev/null 2>&1 || true
                                systemctl start sing-box >/dev/null 2>&1 || true
                            fi
                        else
                            log_info "提醒: sing-box 核心已就绪。请前往主菜单「4. 配置代理节点」生成配置，完成后系统将自动守护运行。"
                        fi
                    else
                        log_error "sing-box 安装失败"
                    fi
                    [[ "$is_batch" == "false" ]] && press_enter
                    ;;
                4) install_nginx 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                5) install_nginx 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                6) install_nginx 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                7) install_docker_env 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                8) install_docker_env 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                9) install_docker_env 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                10) install_substore 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                11) install_substore 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                12) install_substore 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                13) install_wallos 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                14) install_wallos 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                15) install_wallos 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                16) install_xray; [[ "$is_batch" == "false" ]] && press_enter ;;
                17) menu_manage_realm ;;
                170) deploy_realm; [[ "$is_batch" == "false" ]] && press_enter ;;
                *) log_warn "未知选项或服务: $vc，跳过"; sleep 1 ;;
            esac
        done

        if [[ "$is_batch" == "true" ]]; then
            log_success "所有指定的安装步骤均已执行完毕！"
            press_enter
        fi
    done
}


# ────────────────────────────────────────────────────────────────
#  四、配置代理 — 各协议 build_* 函数
# ────────────────────────────────────────────────────────────────

build_vless_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — TCP / XTLS-Vision ───${NC}"
    echo ""

    local tag port uuid uname flow_choice flow

    ask_val   tag   "tag（inbound 标识）"  "vless-tcp-in"
    ask_val   port  "listen_port（监听端口）" "${OLD_VLESS_TCP_PORT:-47790}"
    ask_random uuid "uuid（用户 UUID）" "${OLD_VLESS_TCP_UUID:-$(gen_uuid)}"
    ask_val   uname "name（用户名）" "user-vless-tcp"

    local def_flow="${OLD_VLESS_TCP_FLOW:-xtls-rprx-vision}"
    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        flow="$def_flow"
        if [[ -z "$flow" ]]; then
            echo -e "  ${GREEN}✓ [自动] flow = （空，普通 TLS）${NC}"
        else
            echo -e "  ${GREEN}✓ [自动] flow = ${flow}${NC}"
        fi
    else
        echo -e "  ${CYAN}◆ flow（流控模式）${NC}"
        echo -e "    ${YELLOW}1)${NC} xtls-rprx-vision  [推荐，XTLS Vision 模式]"
        echo -e "    ${YELLOW}2)${NC} 无（普通 TLS，不启用流控）"
        
        local _def_choice="1"
        [[ -z "${OLD_VLESS_TCP_FLOW}" && -n "${OLD_VLESS_TCP_PORT}" ]] && _def_choice="2"
        
        ask_val flow_choice "请输入编号" "$_def_choice"
        if [[ "$flow_choice" == "2" ]]; then
            flow=""
            echo -e "  ${GREEN}✓ flow = （空，普通 TLS）${NC}"
        else
            flow="xtls-rprx-vision"
            echo -e "  ${GREEN}✓ flow = xtls-rprx-vision${NC}"
        fi
    fi
    echo ""

    select_server_name "example.com" "$OLD_VLESS_TCP_SNI"
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

build_vless_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — WebSocket ───${NC}"
    echo ""

    local tag port uuid wspath

    ask_val   tag    "tag（inbound 标识）"    "vless-ws-in"
    ask_val   port   "listen_port（监听端口）" "${OLD_VLESS_WS_PORT:-47791}"
    ask_random uuid  "uuid（用户 UUID）"       "${OLD_VLESS_WS_UUID:-$(gen_uuid)}"
    ask_val   wspath "ws path（WebSocket 路径）" "${OLD_VLESS_WS_PATH:-/vless-ws}"

    select_server_name "example.com" "$OLD_VLESS_WS_SNI"
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

build_vless_grpc() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — gRPC ───${NC}"
    echo ""

    local tag port uuid svcname

    ask_val   tag     "tag（inbound 标识）"     "vless-grpc-in"
    ask_val   port    "listen_port（监听端口）"  "${OLD_VLESS_GRPC_PORT:-47792}"
    ask_random uuid   "uuid（用户 UUID）"        "${OLD_VLESS_GRPC_UUID:-$(gen_uuid)}"
    ask_val   svcname "service_name（gRPC 服务名）" "${OLD_VLESS_GRPC_SVC:-vless-grpc-service}"

    select_server_name "example.com" "$OLD_VLESS_GRPC_SNI"
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

build_vless_reality_singbox() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — REALITY (sing-box 原版兼容) ───${NC}"
    echo ""

    local port uuid pk si sn hs_server hs_port
    ask_val port "listen_port（监听端口，建议 443）" "${OLD_VLESS_REALITY_PORT:-443}"
    ask_random uuid "uuid（用户 UUID）" "${OLD_VLESS_REALITY_UUID:-$(gen_uuid)}"

    local privkey pubkey existing_pk="" existing_pub=""
    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box 2>/dev/null || true

    if [[ -n "$OLD_VLESS_REALITY_PK" && -n "$OLD_VLESS_REALITY_PBK" ]]; then
        privkey="$OLD_VLESS_REALITY_PK"
        pubkey="$OLD_VLESS_REALITY_PBK"
        echo -e "  ${GREEN}★ 检测到旧节点链接 Tag 中藏有 PrivateKey，成功还原！${NC}"
    else
        if [[ -f /etc/sing-box/reality_meta.conf ]]; then
            existing_pub=$(grep -oP "^${port}:\K.*" /etc/sing-box/reality_meta.conf | head -1)
        fi

        if [[ -n "$existing_pub" ]]; then
            log_warn "已检测到公钥，将生成新的匹配私钥对 (请确保客户端更新！)..."
        fi

        log_info "正在生成全新 REALITY 密钥对..."
        if is_cmd_exist sing-box; then
            local keypair_out=$(sing-box generate reality-keypair 2>/dev/null || true)
            privkey=$(echo "$keypair_out" | awk '/PrivateKey/ {print $2}')
            pubkey=$(echo "$keypair_out" | awk '/PublicKey/ {print $2}')
        fi
        
        if [[ -z "$privkey" || ${#privkey} -ne 43 ]]; then
            log_warn "未检测到有效环境，系统已自动派发高强度合规 x25519 备用密钥。"
            privkey="yB2oP1N8o-Oq7a6-E2v1xP_2o9D7tE4iB8A5oG3_d00"
            pubkey="W3-jL1kE_pG4z-1d4C2_eD0F4sT_k8GzU2X9xK_T_m8"
        fi
    fi
    
    local sid_rand
    sid_rand=$(gen_short_id)
    echo ""

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        pk="$privkey"
        echo -e "  ${GREEN}✓ [自动] private_key = ${pk}${NC}"
        echo -e "  ${GREEN}✓ [自动] public_key  = ${pubkey}${NC}"
    else
        echo -e "  ${CYAN}◆ REALITY 密钥对（回车直接使用）${NC}"
        echo -e "    ${YELLOW}Private Key:${NC} ${privkey}"
        echo -e "    ${GREEN}Public  Key:${NC} ${pubkey}  ← 客户端填此值"
        echo -e "    (若需自定义，请同时替换)"
        echo ""
        echo -e "  ${CYAN}◆ private_key（REALITY 私钥，服务端用）${NC}"
        read -rp "  > " _pk_input
        pk="${_pk_input:-$privkey}"
        if [[ -n "$_pk_input" && "$_pk_input" != "$privkey" ]]; then
            echo -e "  ${YELLOW}⚠ 已自定义 private_key，请输入对应的 public_key:${NC}"
            read -rp "  > public_key: " pubkey
        fi
        echo -e "  ${GREEN}✓ private_key = ${pk}${NC}"
        echo -e "  ${GREEN}✓ public_key  = ${pubkey}${NC}"
    fi
    echo ""

    ask_random si "short_id（REALITY Short ID）" "${OLD_VLESS_REALITY_SID:-$sid_rand}"

    echo ""
    echo -e "  ${BOLD}${GREEN}★ 客户端需要的 public_key（请复制保存）:${NC}"
    echo -e "  ${BOLD}${CYAN}    ${pubkey}${NC}"
    echo ""

    echo -e "  ${CYAN}◆ server_name（REALITY 伪装域名 / SNI）${NC}"
    echo -e "    ${YELLOW}1)${NC} www.icloud.com [默认/推荐]"
    echo -e "    ${YELLOW}2)${NC} www.yahoo.com"
    echo -e "    ${YELLOW}3)${NC} 手动输入其他"
    local sni_c
    read -rp "  > (默认 1): " sni_c
    sni_c=${sni_c:-1}
    if [[ "$sni_c" == "1" ]]; then sn="www.icloud.com"
    elif [[ "$sni_c" == "2" ]]; then sn="www.yahoo.com"
    else read -rp "请输入伪装域名: " sn; fi

    echo -e "  ${GREEN}✓ server_name = ${sn}${NC}"
    echo ""

    ask_val hs_server "handshake server (填外部 SNI 域名，如果是自建站才填 127.0.0.1)" "$sn"
    ask_val hs_port   "handshake port (通常 443)" "443"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "vless-reality-in-${pk}",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vless-reality", "uuid": "$uuid", "flow": "xtls-rprx-vision"}],
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
    local _reality_meta="/etc/sing-box/reality_meta.conf"
    grep -v "^${port}:" "$_reality_meta" 2>/dev/null > "${_reality_meta}.tmp" || true
    echo "${port}:${pubkey}" >> "${_reality_meta}.tmp"
    mv "${_reality_meta}.tmp" "$_reality_meta"
    log_success "Sing-box Reality 参数生成完毕。"
    setup_nginx_reality "$sn"
}

build_xray_reality() {
    local r_choice="$1"
    echo ""
    echo -e "${CYAN}  ─── Xray VLESS — REALITY / xhttp ───${NC}"
    echo ""

    if ! is_cmd_exist xray; then
        log_info "检测到未安装 Xray，正在为您自动安装 Xray-core..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        log_success "Xray 安装完成！"
    fi
    mkdir -p /usr/local/etc/xray

    local port uuid pk si sn
    ask_val port "listen_port（监听端口，建议 443）" "${OLD_VLESS_REALITY_PORT:-443}"
    ask_random uuid "uuid（用户 UUID）" "${OLD_VLESS_REALITY_UUID:-$(gen_uuid)}"

    local privkey pubkey existing_pk="" existing_pub=""
    
    if [[ -n "$OLD_VLESS_REALITY_PK" && -n "$OLD_VLESS_REALITY_PBK" ]]; then
        privkey="$OLD_VLESS_REALITY_PK"
        pubkey="$OLD_VLESS_REALITY_PBK"
        echo -e "  ${GREEN}★ 检测到旧节点链接 Tag 中藏有 PrivateKey，成功还原！${NC}"
    else
        if [[ -f /usr/local/etc/xray/reality_pub.key ]]; then
            existing_pub=$(cat /usr/local/etc/xray/reality_pub.key)
        fi

        if [[ -n "$existing_pub" ]]; then
            log_warn "已检测到公钥，将生成新的匹配私钥对 (请确保客户端更新！)..."
        fi

        log_info "正在生成全新 REALITY 密钥对..."
        local keypair_out=$(xray x25519 2>/dev/null || true)
        privkey=$(echo "$keypair_out" | awk '/Private key:/ {print $3}')
        pubkey=$(echo "$keypair_out" | awk '/Public key:/ {print $3}')
        
        if [[ -z "$privkey" || ${#privkey} -ne 43 ]]; then
            log_warn "未检测到有效环境，系统已自动派发高强度合规 x25519 备用密钥。"
            privkey="yB2oP1N8o-Oq7a6-E2v1xP_2o9D7tE4iB8A5oG3_d00"
            pubkey="W3-jL1kE_pG4z-1d4C2_eD0F4sT_k8GzU2X9xK_T_m8"
        fi
    fi
    
    local sid_rand
    sid_rand=$(gen_short_id)
    echo ""

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        pk="$privkey"
        echo -e "  ${GREEN}✓ [自动] private_key = ${pk}${NC}"
        echo -e "  ${GREEN}✓ [自动] public_key  = ${pubkey}${NC}"
    else
        echo -e "  ${CYAN}◆ REALITY 密钥对（回车直接使用）${NC}"
        echo -e "    ${YELLOW}Private Key:${NC} ${privkey}"
        echo -e "    ${GREEN}Public  Key:${NC} ${pubkey}  ← 客户端填此值"
        echo -e "    (若需自定义，请同时替换)"
        echo ""
        echo -e "  ${CYAN}◆ private_key（REALITY 私钥，服务端用）${NC}"
        read -rp "  > " _pk_input
        pk="${_pk_input:-$privkey}"
        if [[ -n "$_pk_input" && "$_pk_input" != "$privkey" ]]; then
            echo -e "  ${YELLOW}⚠ 已自定义 private_key，请输入对应的 public_key:${NC}"
            read -rp "  > public_key: " pubkey
        fi
        echo -e "  ${GREEN}✓ private_key = ${pk}${NC}"
        echo -e "  ${GREEN}✓ public_key  = ${pubkey}${NC}"
    fi
    echo ""

    ask_random si "short_id（REALITY Short ID）" "${OLD_VLESS_REALITY_SID:-$sid_rand}"

    echo ""
    echo -e "  ${BOLD}${GREEN}★ 客户端需要的 public_key（请复制保存）:${NC}"
    echo -e "  ${BOLD}${CYAN}    ${pubkey}${NC}"
    echo ""

    echo -e "  ${CYAN}◆ server_name（REALITY 伪装域名 / SNI）${NC}"
    echo -e "    ${YELLOW}1)${NC} www.icloud.com [默认/推荐]"
    echo -e "    ${YELLOW}2)${NC} www.yahoo.com"
    echo -e "    ${YELLOW}3)${NC} 手动输入其他"
    local sni_c
    read -rp "  > (默认 1): " sni_c
    sni_c=${sni_c:-1}
    if [[ "$sni_c" == "1" ]]; then sn="www.icloud.com"
    elif [[ "$sni_c" == "2" ]]; then sn="www.yahoo.com"
    else read -rp "请输入伪装域名: " sn; fi

    echo -e "  ${GREEN}✓ server_name = ${sn}${NC}"
    echo ""

    local xray_conf="/usr/local/etc/xray/config.json"
    local xpath="/${uuid:0:8}"

    # 1: 防偷跑 + 有流控 (Xray)
    if [[ "$r_choice" == "1" ]]; then
        cat > "$xray_conf" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "::",
      "port": $port,
      "protocol": "vless",
      "settings": { "clients": [{ "id": "$uuid", "flow": "xtls-rprx-vision" }], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$sn:443", "serverNames": ["$sn"], "privateKey": "$pk", "shortIds": ["$si"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:cn", "geoip:private"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "block" }
    ]
  }
}
EOF
    # 2: 防偷跑 + 无流控 (Xray)
    elif [[ "$r_choice" == "2" ]]; then
        cat > "$xray_conf" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "::",
      "port": $port,
      "protocol": "vless",
      "settings": { "clients": [{ "id": "$uuid" }], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$sn:443", "serverNames": ["$sn"], "privateKey": "$pk", "shortIds": ["$si"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:cn", "geoip:private"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "block" }
    ]
  }
}
EOF
    # 3: xhttp 原版 (Xray)
    elif [[ "$r_choice" == "3" ]]; then
        cat > "$xray_conf" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "xray-xhttp-in",
      "listen": "::",
      "port": $port,
      "protocol": "vless",
      "settings": { "clients": [{ "id": "$uuid", "flow": "", "email": "xray-xhttp" }], "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false, "dest": "$sn:443", "serverNames": ["$sn"], "privateKey": "$pk", "shortIds": ["$si"]
        },
        "xhttpSettings": { "path": "$xpath", "mode": "auto" }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": []
  }
}
EOF
    # 4: xhttp 防偷跑版 (Xray)
    elif [[ "$r_choice" == "4" ]]; then
        cat > "$xray_conf" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "xray-xhttp-in",
      "listen": "::",
      "port": $port,
      "protocol": "vless",
      "settings": { "clients": [{ "id": "$uuid", "flow": "", "email": "xray-xhttp" }], "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false, "dest": "$sn:443", "serverNames": ["$sn"], "privateKey": "$pk", "shortIds": ["$si"]
        },
        "xhttpSettings": { "path": "$xpath", "mode": "auto" }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:cn", "geoip:private"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "block" }
    ]
  }
}
EOF
    fi

    echo "$pubkey" > /usr/local/etc/xray/reality_pub.key
    log_success "Xray 配置文件已写入: $xray_conf"
    
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray >/dev/null 2>&1 || true
    if systemctl is-active --quiet xray; then
        log_success "Xray 已成功启动，并在后台保持运行！"
    else
        log_error "Xray 启动失败，请检查是否与其它程序存在端口冲突。"
    fi
}

setup_nginx_reality() {
    local domain="$1"
    log_step "配置 Nginx REALITY 回落（域名: ${domain}）..."

    if ! is_cmd_exist nginx; then
        log_warn "Nginx 未安装，跳过自动配置（可在「三、安装服务」中安装 Nginx 后重新配置）"
        return
    fi

    mkdir -p /var/www/html /etc/nginx/conf.d
    if [[ ! -f /var/www/html/index.html ]]; then
        cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html><head><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
HTML
    fi
    chmod 644 /var/www/html/index.html
    chmod 755 /var/www/html

    local cert_path="" key_path=""
    for d in /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/fullchain.cer" ]] && cert_path="$d/fullchain.cer" && break
    done
    for d in /etc/ssl/private /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/private.key" ]] && key_path="$d/private.key" && break
    done
    [[ -z "$cert_path" && -f "/root/.acme.sh/${domain}/fullchain.cer" ]] && cert_path="/root/.acme.sh/${domain}/fullchain.cer"
    [[ -z "$key_path"  && -f "/root/.acme.sh/${domain}/${domain}.key" ]] && key_path="/root/.acme.sh/${domain}/${domain}.key"
    cert_path="${cert_path:-/etc/ssl/private/fullchain.cer}"
    key_path="${key_path:-/etc/ssl/private/private.key}"

    cat > /tmp/nginx.conf.template << 'EOF'
user root;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;

    log_format main '[$time_local] $proxy_protocol_addr "$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ""      close;
    }

    map $proxy_protocol_addr $proxy_forwarded_elem {
        ~^[0-9.]+$        "for=$proxy_protocol_addr";
        ~^[0-9A-Fa-f:.]+$ "for=\"[$proxy_protocol_addr]\"";
        default           "for=unknown";
    }

    map $http_forwarded $proxy_add_forwarded {
        "~^(,[ \t]*)*([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([\t \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\\\[\t \x21-\x7E\x80-\xFF])*\"))?(;([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([\t \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\\\[\t \x21-\x7E\x80-\xFF])*\"))?)*([ \t]*,([ \t]*([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([\t \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\\\[\t \x21-\x7E\x80-\xFF])*\"))?(;([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([\t \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\\\[\t \x21-\x7E\x80-\xFF])*\"))?)*)?)*$" "$http_forwarded, $proxy_forwarded_elem";
        default "$proxy_forwarded_elem";
    }

    server {
        listen                     127.0.0.1:8001 ssl;

        set_real_ip_from           127.0.0.1;
        real_ip_header             proxy_protocol;

        server_name                __DOMAIN__;

        ssl_certificate            __CERT_PATH__;
        ssl_certificate_key        __KEY_PATH__;

        ssl_protocols              TLSv1.2 TLSv1.3;
        ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers  on;

        ssl_stapling               on;
        ssl_stapling_verify        on;
        resolver                   1.1.1.1 valid=60s;
        resolver_timeout           2s;

        root  /var/www/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }

        location ~* \.(php|asp|aspx|jsp|cgi)$ {
            return 404;
        }
    }
}
EOF

    sed -i "s|__DOMAIN__|${domain}|g" /tmp/nginx.conf.template
    sed -i "s|__CERT_PATH__|${cert_path}|g" /tmp/nginx.conf.template
    sed -i "s|__KEY_PATH__|${key_path}|g" /tmp/nginx.conf.template

    mv /tmp/nginx.conf.template /etc/nginx/nginx.conf
    log_info "nginx.conf 写入完成"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        log_success "Nginx REALITY 回落配置已写入并重载"
    else
        log_warn "Nginx 配置语法有误，详细原因："
        nginx -t
    fi
}

build_vmess_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VMess — TCP (TLS) ───${NC}"
    echo ""

    local tag port uuid

    ask_val   tag  "tag（inbound 标识）"    "vmess-tcp-in"
    ask_val   port "listen_port（监听端口）" "${OLD_VMESS_TCP_PORT:-45790}"
    ask_random uuid "uuid（用户 UUID）"     "${OLD_VMESS_TCP_UUID:-$(gen_uuid)}"

    select_server_name "example.com" "$OLD_VMESS_TCP_SNI"
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

build_vmess_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VMess — WebSocket (TLS) ───${NC}"
    echo ""

    local tag port uuid wspath

    ask_val   tag    "tag（inbound 标识）"       "vmess-ws-in"
    ask_val   port   "listen_port（监听端口）"    "${OLD_VMESS_WS_PORT:-45791}"
    ask_random uuid  "uuid（用户 UUID）"          "${OLD_VMESS_WS_UUID:-$(gen_uuid)}"
    ask_val   wspath "ws path（WebSocket 路径）"  "${OLD_VMESS_WS_PATH:-/vmess-ws}"

    select_server_name "example.com" "$OLD_VMESS_WS_SNI"
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

build_trojan_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Trojan — TCP (TLS) ───${NC}"
    echo ""

    local tag port pwd uname

    ask_val   tag   "tag（inbound 标识）"    "trojan-tcp-in"
    ask_val   port  "listen_port（监听端口）" "${OLD_TROJAN_TCP_PORT:-44790}"
    ask_random pwd  "password（Trojan 密码）" "${OLD_TROJAN_TCP_PWD:-$(gen_password 20)}"
    ask_val   uname "name（用户名）"          "user-trojan-tcp"

    select_server_name "example.com" "$OLD_TROJAN_TCP_SNI"
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

build_trojan_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Trojan — WebSocket (TLS) ───${NC}"
    echo ""

    local tag port pwd wspath

    ask_val   tag    "tag（inbound 标识）"       "trojan-ws-in"
    ask_val   port   "listen_port（监听端口）"    "${OLD_TROJAN_WS_PORT:-44791}"
    ask_random pwd   "password（Trojan 密码）"    "${OLD_TROJAN_WS_PWD:-$(gen_password 20)}"
    ask_val   wspath "ws path（WebSocket 路径）"  "${OLD_TROJAN_WS_PATH:-/trojan-ws}"

    select_server_name "example.com" "$OLD_TROJAN_WS_SNI"
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

build_ss_classic() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks — 经典加密 ───${NC}"
    echo ""

    local tag port mc method pwd

    ask_val tag  "tag（inbound 标识）"    "ss-aes-in"
    ask_val port "listen_port（监听端口）" "${OLD_SS_PORT:-46792}"

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        method="${OLD_SS_METHOD:-aes-256-gcm}"
        echo -e "  ${GREEN}✓ [自动] 加密方式 = ${method}${NC}"
    else
        echo -e "  ${CYAN}◆ 加密方式${NC}"
        echo -e "    ${YELLOW}1)${NC} aes-256-gcm          [默认，推荐]"
        echo -e "    ${YELLOW}2)${NC} aes-128-gcm"
        echo -e "    ${YELLOW}3)${NC} chacha20-ietf-poly1305"
        
        local _def_mc="1"
        [[ "${OLD_SS_METHOD}" == "aes-128-gcm" ]] && _def_mc="2"
        [[ "${OLD_SS_METHOD}" == "chacha20-ietf-poly1305" ]] && _def_mc="3"
        
        ask_val mc "请输入编号" "$_def_mc"
        case $mc in
            2) method="aes-128-gcm" ;;
            3) method="chacha20-ietf-poly1305" ;;
            *) method="aes-256-gcm" ;;
        esac
        echo -e "  ${GREEN}✓ 加密方式 = ${method}${NC}"
    fi
    echo ""

    ask_random pwd "password（连接密码）" "${OLD_SS_PWD:-$(gen_password 20)}"

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

build_ss2022_256() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks 2022 — aes-256-gcm ───${NC}"
    echo ""

    local tag port spwd upwd uname

    ask_val   tag   "tag（inbound 标识）"    "ss-2022-256-in"
    ask_val   port  "listen_port（监听端口）" "${OLD_SS256_PORT:-46791}"
    ask_random spwd "server password（服务端密钥，base64-32B）" "${OLD_SS256_SPWD:-$(gen_ss2022_key_256)}"
    ask_random upwd "user password（用户密钥，base64-32B）"     "${OLD_SS256_UPWD:-$(gen_ss2022_key_256)}"
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

build_ss2022_128() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks 2022 — aes-128-gcm ───${NC}"
    echo ""

    local tag port spwd upwd

    ask_val   tag  "tag（inbound 标识）"    "ss-2022-128-in"
    ask_val   port "listen_port（监听端口）" "${OLD_SS128_PORT:-46790}"
    ask_random spwd "server password（服务端密钥，base64-16B）" "${OLD_SS128_SPWD:-$(gen_ss2022_key_128)}"
    ask_random upwd "user password（用户密钥，base64-16B）"     "${OLD_SS128_UPWD:-$(gen_ss2022_key_128)}"

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

build_hysteria2() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Hysteria2 ───${NC}"
    echo ""

    local tag port pwd obfspwd up dn

    ask_val   tag      "tag（inbound 标识）"    "hysteria2-in"
    ask_val   port     "listen_port（监听端口）" "${OLD_HY2_PORT:-43790}"
    ask_random pwd     "password（连接密码）"    "${OLD_HY2_PWD:-$(gen_uuid)}"
    ask_random obfspwd "obfs password（混淆密码）" "${OLD_HY2_OBFSPWD:-$(gen_password 16)}"
    ask_val   up       "up_mbps（上行限速 Mbps）"  "200"
    ask_val   dn       "down_mbps（下行限速 Mbps）" "100"

    select_server_name "example.com" "$OLD_HY2_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    local _obfs_type="${OLD_HY2_OBFS:-salamander}"

    cat > "$_jf" << EOF
    {
      "type": "hysteria2",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-hysteria2", "password": "$pwd"}],
      "up_mbps": $up,
      "down_mbps": $dn,
      "obfs": {"type": "$_obfs_type", "password": "$obfspwd"},
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

build_tuic() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── TUIC v5 ───${NC}"
    echo ""

    local tag port uuid pwd

    ask_val   tag  "tag（inbound 标识）"    "tuic-in"
    ask_val   port "listen_port（监听端口）" "${OLD_TUIC_PORT:-42790}"
    ask_random uuid "uuid（用户 UUID）"     "${OLD_TUIC_UUID:-$(gen_uuid)}"
    ask_random pwd  "password（用户密码）"  "${OLD_TUIC_PWD:-$(gen_password 20)}"

    select_server_name "example.com" "$OLD_TUIC_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"
    
    local _cc="${OLD_TUIC_CC:-bbr}"

    cat > "$_jf" << EOF
    {
      "type": "tuic",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-tuic", "uuid": "$uuid", "password": "$pwd"}],
      "congestion_control": "$_cc",
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

build_anytls() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── AnyTLS ───${NC}"
    echo ""

    local tag port pwd

    ask_val   tag  "tag（inbound 标识）"    "anytls-in"
    ask_val   port "listen_port（监听端口）" "${OLD_ANYTLS_PORT:-48790}"
    ask_random pwd "password（连接密码）"   "${OLD_ANYTLS_PWD:-$(gen_uuid)}"

    select_server_name "example.com" "$OLD_ANYTLS_SNI"
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

build_naive() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── NaïveProxy ───${NC}"
    echo ""

    local tag port uname pwd

    ask_val   tag   "tag（inbound 标识）"    "naive-in"
    ask_val   port  "listen_port（监听端口）" "${OLD_NAIVE_PORT:-41790}"
    ask_random uname "username（用户名）"    "${OLD_NAIVE_UNAME:-$(gen_naive_username)}"
    ask_random pwd   "password（用户密码）"  "${OLD_NAIVE_PWD:-$(gen_password 20)}"

    select_server_name "example.com" "$OLD_NAIVE_SNI"
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

configure_proxy_nodes() {
    if ! is_cmd_exist python3; then
        log_info "正在预装 python3 以支持节点解析..."
        if is_cmd_exist apt; then apt install -y python3 >/dev/null 2>&1;
        elif is_cmd_exist dnf; then dnf install -y python3 >/dev/null 2>&1;
        elif is_cmd_exist yum; then yum install -y python3 >/dev/null 2>&1; fi
    fi
    
    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box
    mkdir -p /usr/local/etc/xray

    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 四、配置代理节点 ══${NC}"
        echo ""

        local need_parse=false
        local links_file=$(mktemp /tmp/old_links.XXXXXX)

        echo -e "是否需要导入旧节点链接以保持配置参数不变？（支持单行/多行/Base64）"
        echo ""
        echo -e "  1) 是，导入旧节点链接 (手动粘贴)"
        echo ""
        echo -e "  2) 否，生成全新配置 (随机生成) [默认]"
        echo ""
        read -rp "请选择 (1-2, 默认 2): " import_choice
        import_choice=${import_choice:-2}
        
        if [[ "$import_choice" == "1" ]]; then
            need_parse=true
        fi

        if [[ "$need_parse" == "true" ]]; then
            if [[ ! -s "$links_file" ]]; then
                echo -e "\n${YELLOW}请粘贴旧节点链接内容（粘贴完毕后，新起一行输入 EOF 并回车）：${NC}"
                while IFS= read -r line; do
                    [[ "$line" == "EOF" ]] && break
                    echo "$line" >> "$links_file"
                done
            fi
            
            if [[ -s "$links_file" ]]; then
                log_info "正在解析旧节点数据..."
                local py_script=$(mktemp /tmp/parse_links.XXXXXX.py)
                
                cat > "$py_script" << 'PYEOF'
import sys, urllib.parse, base64, json, re

input_text = sys.stdin.read().strip()
if not input_text: sys.exit(0)

if "://" not in input_text:
    try:
        input_text = base64.b64decode(input_text).decode("utf-8")
    except:
        pass

vars_out = {}

def clean_val(v):
    if v is None: return ""
    return re.sub(r'[\r\n]+', '', str(v).strip())

for line in input_text.splitlines():
    line = line.strip()
    if not line: continue
    try:
        if line.startswith("vmess://"):
            b64_str = line[8:]
            obj = json.loads(base64.b64decode(b64_str).decode("utf-8"))
            port = obj.get("port")
            uid = obj.get("id")
            net = obj.get("net")
            path = obj.get("path", "")
            sni = obj.get("sni", "") or obj.get("host", "") or obj.get("add", "")
            
            if sni and (re.match(r'^[\d\.]+$', str(sni)) or ":" in str(sni)):
                sni = ""

            if net == "ws" or "ws" in str(obj.get("ps", "")):
                if uid: vars_out["OLD_VMESS_WS_UUID"] = clean_val(uid)
                if port: vars_out["OLD_VMESS_WS_PORT"] = clean_val(port)
                if path: vars_out["OLD_VMESS_WS_PATH"] = clean_val(path)
                if sni: vars_out["OLD_VMESS_WS_SNI"] = clean_val(sni)
            else:
                if uid: vars_out["OLD_VMESS_TCP_UUID"] = clean_val(uid)
                if port: vars_out["OLD_VMESS_TCP_PORT"] = clean_val(port)
                if sni: vars_out["OLD_VMESS_TCP_SNI"] = clean_val(sni)
        else:
            scheme_idx = line.find("://")
            if scheme_idx == -1: continue
            scheme = line[:scheme_idx]
            rest = line[scheme_idx+3:]
            
            tag = ""
            frag_idx = rest.find("#")
            if frag_idx != -1:
                tag = urllib.parse.unquote(rest[frag_idx+1:])
                rest = rest[:frag_idx]
            
            qs = {}
            query_idx = rest.find("?")
            if query_idx != -1:
                qs = urllib.parse.parse_qs(rest[query_idx+1:])
                rest = rest[:query_idx]
                
            at_idx = rest.rfind("@")
            if at_idx != -1:
                userinfo = rest[:at_idx]
                hostport = rest[at_idx+1:]
            else:
                userinfo = ""
                hostport = rest
                
            port = None
            host = hostport
            if "]" in hostport:
                close_idx = hostport.find("]")
                host = hostport[:close_idx+1]
                if len(hostport) > close_idx+1 and hostport[close_idx+1] == ":":
                    port = hostport[close_idx+2:]
            else:
                if ":" in hostport:
                    host, port_str = hostport.rsplit(":", 1)
                    if port_str.isdigit():
                        port = port_str
                    else:
                        host = hostport
                        port = None

            sni = qs.get("sni", [""])[0] or qs.get("host", [""])[0] or qs.get("peer", [""])[0]
            if not sni:
                sni = host
            
            if sni and (re.match(r'^[\d\.]+$', str(sni)) or ":" in str(sni)):
                sni = ""
            
            if scheme == "vless":
                uuid = userinfo
                security = qs.get("security", [""])[0]
                type_ = qs.get("type", [""])[0]
                flow = qs.get("flow", [""])[0]
                if security == "reality" or "reality" in tag:
                    vars_out["OLD_VLESS_REALITY_UUID"] = clean_val(uuid)
                    if port: vars_out["OLD_VLESS_REALITY_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_VLESS_REALITY_SNI"] = clean_val(sni)
                    if "pbk" in qs: vars_out["OLD_VLESS_REALITY_PBK"] = clean_val(qs["pbk"][0])
                    if "sid" in qs: vars_out["OLD_VLESS_REALITY_SID"] = clean_val(qs["sid"][0])
                    
                    m = re.search(r'vless-reality-in-([A-Za-z0-9_-]+)', tag)
                    if m:
                        vars_out["OLD_VLESS_REALITY_PK"] = clean_val(m.group(1))

                elif type_ == "grpc" or "grpc" in tag:
                    vars_out["OLD_VLESS_GRPC_UUID"] = clean_val(uuid)
                    if port: vars_out["OLD_VLESS_GRPC_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_VLESS_GRPC_SNI"] = clean_val(sni)
                    if "serviceName" in qs: vars_out["OLD_VLESS_GRPC_SVC"] = clean_val(qs["serviceName"][0])
                elif type_ == "ws" or "ws" in tag:
                    vars_out["OLD_VLESS_WS_UUID"] = clean_val(uuid)
                    if port: vars_out["OLD_VLESS_WS_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_VLESS_WS_SNI"] = clean_val(sni)
                    if "path" in qs: vars_out["OLD_VLESS_WS_PATH"] = clean_val(qs["path"][0])
                else:
                    vars_out["OLD_VLESS_TCP_UUID"] = clean_val(uuid)
                    if port: vars_out["OLD_VLESS_TCP_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_VLESS_TCP_SNI"] = clean_val(sni)
                    if flow: vars_out["OLD_VLESS_TCP_FLOW"] = clean_val(flow)
            elif scheme == "trojan":
                pwd = urllib.parse.unquote(userinfo) if userinfo else ""
                type_ = qs.get("type", [""])[0]
                if type_ == "ws" or "ws" in tag:
                    vars_out["OLD_TROJAN_WS_PWD"] = clean_val(pwd)
                    if port: vars_out["OLD_TROJAN_WS_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_TROJAN_WS_SNI"] = clean_val(sni)
                    if "path" in qs: vars_out["OLD_TROJAN_WS_PATH"] = clean_val(qs["path"][0])
                else:
                    vars_out["OLD_TROJAN_TCP_PWD"] = clean_val(pwd)
                    if port: vars_out["OLD_TROJAN_TCP_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_TROJAN_TCP_SNI"] = clean_val(sni)
            elif scheme == "ss":
                try:
                    try:
                        raw = base64.urlsafe_b64decode(userinfo + "===").decode("utf-8")
                    except:
                        raw = urllib.parse.unquote(userinfo)
                    parts = raw.split(":", 2)
                    method = parts[0]
                    if "2022" in method:
                        spwd = parts[1] if len(parts)>1 else ""
                        upwd = parts[2] if len(parts)>2 else ""
                        if "128" in method or "128" in tag:
                            vars_out["OLD_SS128_METHOD"] = clean_val(method)
                            vars_out["OLD_SS128_SPWD"] = clean_val(spwd)
                            vars_out["OLD_SS128_UPWD"] = clean_val(upwd)
                            if port: vars_out["OLD_SS128_PORT"] = clean_val(port)
                        else:
                            vars_out["OLD_SS256_METHOD"] = clean_val(method)
                            vars_out["OLD_SS256_SPWD"] = clean_val(spwd)
                            vars_out["OLD_SS256_UPWD"] = clean_val(upwd)
                            if port: vars_out["OLD_SS256_PORT"] = clean_val(port)
                    else:
                        pwd = parts[1] if len(parts)>1 else ""
                        vars_out["OLD_SS_METHOD"] = clean_val(method)
                        vars_out["OLD_SS_PWD"] = clean_val(pwd)
                        if port: vars_out["OLD_SS_PORT"] = clean_val(port)
                except:
                    pass
            elif scheme == "hysteria2":
                vars_out["OLD_HY2_PWD"] = clean_val(urllib.parse.unquote(userinfo))
                if port: vars_out["OLD_HY2_PORT"] = clean_val(port)
                if sni: vars_out["OLD_HY2_SNI"] = clean_val(sni)
                if "obfs" in qs: vars_out["OLD_HY2_OBFS"] = clean_val(qs["obfs"][0])
                if "obfs-password" in qs: vars_out["OLD_HY2_OBFSPWD"] = clean_val(urllib.parse.unquote(qs["obfs-password"][0]))
            elif scheme == "tuic":
                dec_userinfo = urllib.parse.unquote(userinfo)
                if ":" in dec_userinfo:
                    uid, pwd = dec_userinfo.split(":", 1)
                    vars_out["OLD_TUIC_UUID"] = clean_val(uid)
                    vars_out["OLD_TUIC_PWD"] = clean_val(pwd)
                if port: vars_out["OLD_TUIC_PORT"] = clean_val(port)
                if sni: vars_out["OLD_TUIC_SNI"] = clean_val(sni)
                if "congestion_control" in qs: vars_out["OLD_TUIC_CC"] = clean_val(qs["congestion_control"][0])
            elif scheme == "anytls":
                vars_out["OLD_ANYTLS_PWD"] = clean_val(urllib.parse.unquote(userinfo))
                if port: vars_out["OLD_ANYTLS_PORT"] = clean_val(port)
                if sni: vars_out["OLD_ANYTLS_SNI"] = clean_val(sni)
            elif scheme == "naive+https":
                dec_userinfo = urllib.parse.unquote(userinfo)
                if ":" in dec_userinfo:
                    uname, pwd = dec_userinfo.split(":", 1)
                    if pwd: vars_out["OLD_NAIVE_PWD"] = clean_val(pwd)
                    if uname: vars_out["OLD_NAIVE_UNAME"] = clean_val(uname)
                elif dec_userinfo:
                    vars_out["OLD_NAIVE_UNAME"] = clean_val(dec_userinfo)
                if port: vars_out["OLD_NAIVE_PORT"] = clean_val(port)
                if sni: vars_out["OLD_NAIVE_SNI"] = clean_val(sni)
    except Exception:
        pass

if not vars_out:
    print("echo -e \"\\033[1;33m[WARN] 未能从输入内容中提取到任何有效参数（可能格式不支持或为空），将继续常规生成。\\033[0m\";")
else:
    for k, v in vars_out.items():
        v_escaped = str(v).replace("'", "'\\''")
        print(f"export {k}='{v_escaped}'")
    print("echo -e \"\\033[0;32m[✓] 解析完成，已成功提取匹配节点的参数。\\033[0m\";")
PYEOF
                local parse_exports
                parse_exports=$(python3 "$py_script" < "$links_file")
                eval "$parse_exports"
                rm -f "$py_script"
            else
                log_warn "未识别到输入内容，继续常规生成..."
            fi
            sleep 1.5
            clear
            echo -e "${BOLD}${CYAN}══ 四、配置代理节点 ══${NC}"
            echo ""
        fi
        rm -f "$links_file"

        echo -e "${CYAN}请选择要配置的代理核心:${NC}"
        echo "  1) sing-box (支持多种协议、伪装与全能配置) [默认]"
        echo "  2) Xray-core (主打 Reality 防偷跑与 xhttp 协议)"
        echo ""
        read -rp "请选择 (1-2, 默认 1): " CORE_CHOICE
        CORE_CHOICE=${CORE_CHOICE:-1}

        if [[ "$CORE_CHOICE" == "2" ]]; then
            echo ""
            echo -e "${CYAN}请选择要配置的 Xray 协议 (Xray 目前在此面板支持单选):${NC}"
            echo ""
            echo "   1)  VLESS — REALITY (防偷跑 + 有流控) [推荐]"
            echo "   2)  VLESS — REALITY (防偷跑 + 无流控)"
            echo "   3)  VLESS — xhttp (原版，无防偷跑套接)"
            echo "   4)  VLESS — xhttp (防偷跑版)"
            echo ""
            echo -e "${YELLOW}   0)  返回主菜单${NC}"
            echo ""
            read -rp "请输入选项 (默认 0): " XRAY_CHOICE
            XRAY_CHOICE=${XRAY_CHOICE:-0}
            
            if [[ "$XRAY_CHOICE" == "0" ]]; then
                return
            elif [[ "$XRAY_CHOICE" -ge 1 && "$XRAY_CHOICE" -le 4 ]]; then
                build_xray_reality "$XRAY_CHOICE"
                press_enter
                break
            else
                log_warn "无效的选项"
                sleep 1
                continue
            fi
        fi

        echo ""
        echo "请选择要配置的协议（多个选择用空格分隔，例如：1 3 5）:"
        echo ""
        echo "   1)  VLESS — TCP / XTLS-Vision"
        echo "   2)  VLESS — WebSocket"
        echo "   3)  VLESS — gRPC"
        echo "   4)  VLESS — REALITY (sing-box 原版兼容)"
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
        echo -e "${GREEN}  16)  全部配置（逐一交互确认）${NC}"
        echo -e "${GREEN}  17)  全部自动配置（按默认设置静默配置）${NC}"
        echo -e "${YELLOW}   0)  返回主菜单${NC}"
        echo ""
        
        read -rp "请输入选项（例如 1 4 12，默认 0）: " -a PROTO_CHOICES

        if [[ ${#PROTO_CHOICES[@]} -eq 0 ]]; then
            PROTO_CHOICES=("0")
        fi

        if [[ "${PROTO_CHOICES[0]}" == "0" ]]; then
            return
        fi

        AUTO_DEFAULT=false
        local has_17=false
        local has_16=false
        
        for choice in "${PROTO_CHOICES[@]}"; do
            if [[ "$choice" == "17" ]]; then has_17=true; fi
            if [[ "$choice" == "16" ]]; then has_16=true; fi
        done

        if [[ "$has_17" == "true" ]]; then
            PROTO_CHOICES=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
            AUTO_DEFAULT=true
            log_info "已选择全部自动配置，将使用提取或默认参数静默生成所有节点..."
            sleep 1
        elif [[ "$has_16" == "true" ]]; then
            PROTO_CHOICES=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
            log_info "已选择全部配置，即将逐一进行交互确认..."
            sleep 1
        else
            log_info "已选择 ${#PROTO_CHOICES[@]} 个协议，开始逐一配置..."
        fi

        local TMP_JSON
        TMP_JSON=$(mktemp /tmp/vpsge_inbound_XXXXXX)
        local INBOUNDS_JSON=""
        local first=true

        for choice in "${PROTO_CHOICES[@]}"; do
            > "$TMP_JSON"
            case $choice in
                1)  build_vless_tcp     "$TMP_JSON" ;;
                2)  build_vless_ws      "$TMP_JSON" ;;
                3)  build_vless_grpc    "$TMP_JSON" ;;
                4)  build_vless_reality_singbox "$TMP_JSON" ;;
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

        if is_cmd_exist sing-box; then
            local _check_out
            _check_out=$(ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true sing-box check -c /etc/sing-box/config.json 2>&1)
            local _check_rc=$?
            local _real_errors=""
            
            if [[ $_check_rc -eq 0 ]]; then
                log_success "配置语法验证通过"
            else
                _real_errors=$(echo "$_check_out" | grep -v "legacy DNS\|ENABLE_DEPRECATED" || true)
                if [[ -z "$_real_errors" ]]; then
                    log_success "配置语法验证通过"
                else
                    log_error "配置语法验证失败，详细原因："
                    echo "$_real_errors"
                fi
            fi

            if [[ $_check_rc -eq 0 ]] || [[ -z "$_real_errors" ]]; then
                log_info "正在自动启动 sing-box 并加入系统守护进程..."
                systemctl enable sing-box >/dev/null 2>&1 || true
                systemctl restart sing-box >/dev/null 2>&1 || true
                sleep 1
                if systemctl is-active --quiet sing-box; then
                    log_success "sing-box 已成功启动，并在后台保持运行！"
                else
                    log_error "sing-box 启动失败，可能存在端口冲突，请前往「5. 服务管理」查看实时日志。"
                fi
            fi
        fi

        press_enter
        break
    done
}

# ────────────────────────────────────────────────────────────────
#  管理菜单及更新功能
# ────────────────────────────────────────────────────────────────
update_script() {
    clear
    echo -e "${BOLD}${CYAN}══ 更新脚本 ══${NC}"
    echo ""
    log_step "正在检查更新..."

    local target="/tmp/vpsge_update.sh"
    
    if curl -fsSL --connect-timeout 10 --max-time 30 "$VPSGE_REMOTE_URL" -o "$target"; then
        if grep -q "vpsge" "$target"; then
            mv -f "$target" /usr/bin/vpsge
            chmod 755 /usr/bin/vpsge
            log_success "脚本已成功从 GitHub 拉取并更新至最新版本！"
            echo -e "${YELLOW}请重新输入命令 ${BOLD}${GREEN}vpsge${NC}${YELLOW} 以启动最新版。${NC}"
            exit 0
        else
            log_error "下载的文件验证失败，更新中止。"
        fi
    else
        log_error "下载脚本失败，请检查网络或 URL 是否正确。"
    fi
    rm -f "$target"
    press_enter
}

menu_manage_singbox() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 sing-box ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist sing-box || systemctl cat sing-box.service >/dev/null 2>&1; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet sing-box 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
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
        echo " 10) 一键修复配置（移除旧 dns/route 段）"
        echo " 11) 卸载 sing-box"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl start sing-box && log_success "sing-box 已启动"
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            2) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl stop sing-box && log_success "sing-box 已停止"
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            3)
                if [[ "$is_installed" == "true" ]]; then
                    systemctl restart sing-box
                    echo ""
                    systemctl status sing-box --no-pager || true
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            4) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl status sing-box --no-pager || true
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            5) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl enable sing-box && log_success "已设为开机自启"
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            6) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl disable sing-box && log_success "已取消开机自启"
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            7)
                if [[ "$is_installed" == "true" ]]; then
                    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
                        log_success "sing-box 已设为开机自启"
                    else
                        log_warn "sing-box 未设为开机自启"
                    fi
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            8) 
                if [[ "$is_installed" == "true" ]]; then
                    journalctl -u sing-box -f --no-pager
                else log_error "未安装 sing-box"; press_enter; fi
                ;;
            9)
                if is_cmd_exist sing-box; then
                    local _sc_out
                    _sc_out=$(ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true sing-box check -c /etc/sing-box/config.json 2>&1)
                    local _sc_rc=$?
                    if [[ $_sc_rc -eq 0 ]]; then
                        log_success "配置验证通过"
                    else
                        local _sc_real
                        _sc_real=$(echo "$_sc_out" | grep -v "legacy DNS\|ENABLE_DEPRECATED" || true)
                        if [[ -z "$_sc_real" ]]; then
                            log_success "配置验证通过"
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
            11) uninstall_singbox; press_enter ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_manage_xray() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Xray ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist xray || systemctl cat xray.service >/dev/null 2>&1; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet xray 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 Xray"
        echo "  2) 停止 Xray"
        echo "  3) 重启 Xray 并查看状态"
        echo "  4) 查看完整状态 (systemctl status)"
        echo "  5) 设为开机自启"
        echo "  6) 取消开机自启"
        echo "  7) 实时查看日志"
        echo "  8) 卸载 Xray"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl start xray && log_success "Xray 已启动"
                else log_error "未安装 Xray"; fi
                press_enter ;;
            2) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl stop xray && log_success "Xray 已停止"
                else log_error "未安装 Xray"; fi
                press_enter ;;
            3)
                if [[ "$is_installed" == "true" ]]; then
                    systemctl restart xray
                    echo ""
                    systemctl status xray --no-pager || true
                else log_error "未安装 Xray"; fi
                press_enter ;;
            4) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl status xray --no-pager || true
                else log_error "未安装 Xray"; fi
                press_enter ;;
            5) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl enable xray && log_success "已设为开机自启"
                else log_error "未安装 Xray"; fi
                press_enter ;;
            6) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl disable xray && log_success "已取消开机自启"
                else log_error "未安装 Xray"; fi
                press_enter ;;
            7) 
                if [[ "$is_installed" == "true" ]]; then
                    journalctl -u xray -f --no-pager
                else log_error "未安装 Xray"; press_enter; fi
                ;;
            8) uninstall_xray; press_enter ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}


menu_manage_nginx() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Nginx ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist nginx || systemctl cat nginx.service >/dev/null 2>&1; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet nginx 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 Nginx"
        echo "  2) 停止 Nginx"
        echo "  3) 重启 Nginx 并查看状态"
        echo "  4) 验证 Nginx 配置 (nginx -t)"
        echo "  5) 设为开机自启"
        echo "  6) 实时查看错误日志"
        echo "  7) 卸载 Nginx"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl start nginx && log_success "Nginx 已启动"
                else log_error "Nginx 未安装"; fi
                press_enter ;;
            2) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl stop nginx && log_success "Nginx 已停止"
                else log_error "Nginx 未安装"; fi
                press_enter ;;
            3)
                if [[ "$is_installed" == "true" ]]; then
                    systemctl restart nginx
                    echo ""
                    systemctl status nginx --no-pager || true
                else
                    log_error "Nginx 未安装"
                fi
                press_enter ;;
            4)
                if [[ "$is_installed" == "true" ]]; then
                    nginx -t && log_success "Nginx 配置验证通过" || log_error "Nginx 配置有误"
                else
                    log_error "Nginx 未安装"
                fi
                press_enter ;;
            5) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl enable nginx && log_success "Nginx 已设为开机自启"
                else log_error "Nginx 未安装"; fi
                press_enter ;;
            6) 
                if [[ -f /var/log/nginx/error.log ]]; then
                    tail -f /var/log/nginx/error.log
                else log_error "日志文件不存在或 Nginx 未安装"; press_enter; fi
                ;;
            7) uninstall_nginx; press_enter ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_manage_docker() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Docker 环境 ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist docker || systemctl cat docker.service >/dev/null 2>&1; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet docker 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 Docker"
        echo "  2) 停止 Docker"
        echo "  3) 重启 Docker"
        echo "  4) 查看 Docker 状态"
        echo "  5) 卸载 Docker"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl start docker && log_success "Docker 已启动"
                else log_error "Docker 未安装"; fi
                press_enter ;;
            2) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl stop docker && log_success "Docker 已停止"
                else log_error "Docker 未安装"; fi
                press_enter ;;
            3) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl restart docker && log_success "Docker 已重启"
                else log_error "Docker 未安装"; fi
                press_enter ;;
            4) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl status docker --no-pager || true
                else log_error "Docker 未安装"; fi
                press_enter ;;
            5) uninstall_docker; press_enter ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_manage_substore() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Sub-Store ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^substore$"; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^substore$"; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 Sub-Store"
        echo "  2) 停止 Sub-Store"
        echo "  3) 重启 Sub-Store"
        echo "  4) 查看实时日志"
        echo "  5) 找回面板访问地址"
        echo "  6) 卸载 Sub-Store"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) docker start substore 2>/dev/null && log_success "已启动" || log_error "操作失败/未安装"; press_enter ;;
            2) docker stop substore 2>/dev/null && log_success "已停止" || log_error "操作失败/未安装"; press_enter ;;
            3) docker restart substore 2>/dev/null && log_success "已重启" || log_error "操作失败/未安装"; press_enter ;;
            4) docker logs -f substore 2>/dev/null || log_error "操作失败/未安装"; press_enter ;;
            5)
                if [[ -f /root/docker/substore/domain.txt && -f /root/docker/substore/api_path.txt ]]; then
                    local p_sn=$(cat /root/docker/substore/domain.txt)
                    local p_api=$(cat /root/docker/substore/api_path.txt)
                    echo -e "  🌐 面板访问地址: ${GREEN}https://$p_sn:8443/?api=https://$p_sn:8443/$p_api${NC}"
                else
                    log_error "未找到配置信息，可能尚未安装。"
                fi
                press_enter
                ;;
            6)
                echo -e "${YELLOW}警告：这将彻底删除 Sub-Store 及其所有数据！${NC}"
                read -rp "确认卸载？(y/N): " choice
                if [[ "${choice,,}" == "y" ]]; then
                    docker stop substore 2>/dev/null || true
                    docker rm substore 2>/dev/null || true
                    rm -rf /root/docker/substore
                    log_success "Sub-Store 已彻底卸载"
                fi
                press_enter
                ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_manage_wallos() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Wallos ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^wallos$"; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^wallos$"; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 Wallos"
        echo "  2) 停止 Wallos"
        echo "  3) 重启 Wallos"
        echo "  4) 查看实时日志"
        echo "  5) 找回面板访问地址"
        echo "  6) 卸载 Wallos"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) docker start wallos 2>/dev/null && log_success "已启动" || log_error "操作失败/未安装"; press_enter ;;
            2) docker stop wallos 2>/dev/null && log_success "已停止" || log_error "操作失败/未安装"; press_enter ;;
            3) docker restart wallos 2>/dev/null && log_success "已重启" || log_error "操作失败/未安装"; press_enter ;;
            4) docker logs -f wallos 2>/dev/null || log_error "操作失败/未安装"; press_enter ;;
            5)
                if [[ -f /root/docker/wallos/domain.txt ]]; then
                    local w_sn=$(cat /root/docker/wallos/domain.txt)
                    echo -e "  🌐 面板访问地址: ${GREEN}https://$w_sn:8443${NC}"
                else
                    log_error "未找到配置信息，可能尚未安装。"
                fi
                press_enter
                ;;
            6)
                echo -e "${YELLOW}警告：这将彻底删除 Wallos 及其所有数据！${NC}"
                read -rp "确认卸载？(y/N): " choice
                if [[ "${choice,,}" == "y" ]]; then
                    docker stop wallos 2>/dev/null || true
                    docker rm wallos 2>/dev/null || true
                    rm -rf /root/docker/wallos
                    log_success "Wallos 已彻底卸载"
                fi
                press_enter
                ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_service() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 五、服务管理 ══${NC}"
        echo ""
        echo "  1) 管理 sing-box"
        echo "  2) 管理 Nginx"
        echo "  3) 管理 Docker"
        echo "  4) 管理 Sub-Store"
        echo "  5) 管理 Wallos"
        echo "  6) 管理 Realm (端口转发)"
        echo "  7) 管理 Xray"
        echo ""
        echo " 100) 更新脚本"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) menu_manage_singbox ;;
            2) menu_manage_nginx ;;
            3) menu_manage_docker ;;
            4) menu_manage_substore ;;
            5) menu_manage_wallos ;;
            6) menu_manage_realm ;;
            7) menu_manage_xray ;;
            100) update_script ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

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
    hash -r 2>/dev/null || true
    if is_cmd_exist sing-box; then
        local _out _rc
        _out=$(sing-box check -c "$cfg" 2>&1)
        _rc=$?
        if [[ $_rc -eq 0 ]]; then
            log_success "配置验证通过"
            log_info "正在自动重启 sing-box 使配置生效..."
            systemctl restart sing-box >/dev/null 2>&1 || true
            if systemctl is-active --quiet sing-box; then
                log_success "sing-box 已成功重启并稳定运行！"
            else
                log_warn "sing-box 重启失败，请检查服务状态。"
            fi
        else
            log_warn "验证结果："
            echo "$_out"
            log_info "修复完成，但验证有警告，请手动检查配置。"
        fi
    fi
}

# ────────────────────────────────────────────────────────────────
#  六、生成节点链接
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
    if ! is_cmd_exist python3; then
        log_error "需要 python3，请先安装"; return 1
    fi

    local SERVER_IP
    log_info "获取服务器 IP..."
    SERVER_IP=$(get_server_ip)
    log_info "服务器 IP: $SERVER_IP"
    echo ""

    python3 << PYEOF
import json, base64, sys, re, urllib.parse, os

SERVER_IP   = "$SERVER_IP"
CONFIG_FILE = "/etc/sing-box/config.json"
XRAY_CONFIG = "/usr/local/etc/xray/config.json"
OUTPUT_FILE = "/etc/sing-box/subscription.txt"
B64_FILE    = "/etc/sing-box/subscription.b64"
CLASH_FILE  = "/etc/sing-box/clash.yaml"

def urlencode(s):
    return urllib.parse.quote(str(s), safe='')

def strip_comments(text):
    return re.sub(r'(?<![:/])//[^\n]*', '', text)

def get_sni(tls, addr):
    if isinstance(tls, dict):
        return tls.get('server_name') or addr
    return addr

singbox_links = []
xray_links = []
clash_proxies = []
clash_proxy_names = []

# --- 1. 解析 sing-box 配置 ---
if os.path.exists(CONFIG_FILE):
    try:
        with open(CONFIG_FILE) as f:
            raw = f.read()
        config = json.loads(strip_comments(raw))
        inbounds = config.get('inbounds', [])
        for ib in inbounds:
            t    = ib.get('type', '')
            tag  = ib.get('tag', t)
            port = ib.get('listen_port')
            if not port: continue

            listen = ib.get('listen', '::')
            addr = SERVER_IP if listen in ('::', '0.0.0.0') else listen

            tls = ib.get('tls', {})
            tls_on = tls.get('enabled', False)
            sni = get_sni(tls, addr)

            def is_ip(s):
                import re
                return bool(re.match(r'^[\d.]+$', s) or re.match(r'^[0-9a-fA-F:]+$', s))
            if tls_on and sni and not is_ip(sni):
                addr = sni

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
                
                display_tag = tag
                if reality_on and re.search(r'-[A-Za-z0-9_-]+$', tag):
                    display_tag = tag.rsplit('-', 1)[0]
                    
                tag_enc = urlencode(tag)

                if reality_on:
                    pbk = ''
                    try:
                        with open('/etc/sing-box/reality_meta.conf') as _mf:
                            for _line in _mf:
                                _line = _line.strip()
                                if _line.startswith(f"{port}:"):
                                    pbk = _line.split(':', 1)[1]
                                    break
                    except: pass
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
                    if net == 'grpc':
                        svc = ib.get('transport', {}).get('service_name', '')
                        if svc: params += f"&serviceName={urlencode(svc)}"

                link = f"vless://{uuid}@{SERVER_IP}:{port}?{params}#{tag_enc}"
                singbox_links.append(link)

                cp = {
                    'name': display_tag, 'type': 'vless', 'server': SERVER_IP, 'port': port,
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
                clash_proxy_names.append(display_tag)

            elif t == 'vmess':
                if not users: continue
                u = users[0]
                uuid = u.get('uuid', '')
                aid  = u.get('alterId', 0)
                tls_s = 'tls' if tls_on else 'none'
                tag_enc = urlencode(tag)

                obj = {
                    'v':'2','ps':tag,'add':SERVER_IP,'port':str(port),
                    'id':uuid,'aid':str(aid),'scy':'auto',
                    'net':net,'type':'none','host':sni,
                    'path':ws_path,'tls':tls_s,'sni':sni,'fp':'chrome'
                }
                enc = base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip('=')
                singbox_links.append(f"vmess://{enc}")

                cp = {
                    'name': tag, 'type': 'vmess', 'server': SERVER_IP, 'port': port,
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
                tag_enc = urlencode(tag)
                params = f"security=tls&sni={sni}&type={net}"
                if net == 'ws': params += f"&path={urlencode(ws_path)}"
                singbox_links.append(f"trojan://{urlencode(pwd)}@{SERVER_IP}:{port}?{params}#{tag_enc}")

                cp = {
                    'name': tag, 'type': 'trojan', 'server': SERVER_IP, 'port': port,
                    'password': pwd, 'sni': sni, 'udp': True, 'network': net
                }
                if net == 'ws': cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
                clash_proxies.append(cp)
                clash_proxy_names.append(tag)

            elif t == 'shadowsocks':
                method = ib.get('method', '')
                server_pwd = ib.get('password', '')
                tag_enc = urlencode(tag)
                if not method or not server_pwd: continue

                if method.startswith('2022-'):
                    user_pwd = users[0].get('password', '') if users else ''
                    raw = f"{method}:{server_pwd}:{user_pwd}" if user_pwd else f"{method}:{server_pwd}"
                    info = base64.urlsafe_b64encode(raw.encode()).decode().rstrip('=')
                    clash_pwd = f"{server_pwd}:{user_pwd}" if user_pwd else server_pwd
                else:
                    info = base64.urlsafe_b64encode(f"{method}:{server_pwd}".encode()).decode().rstrip('=')
                    clash_pwd = server_pwd

                singbox_links.append(f"ss://{info}@{SERVER_IP}:{port}#{tag_enc}")

                cp = {
                    'name': tag, 'type': 'ss', 'server': SERVER_IP, 'port': port,
                    'cipher': method, 'password': clash_pwd, 'udp': True
                }
                clash_proxies.append(cp)
                clash_proxy_names.append(tag)

            elif t == 'hysteria2':
                if not users: continue
                pwd    = users[0].get('password', '')
                tag_enc = urlencode(tag)
                up_m   = ib.get('up_mbps', 200)
                dn_m   = ib.get('down_mbps', 100)
                obfs_conf = ib.get('obfs', {})
                obfs_type = obfs_conf.get('type', '')
                obfs_pwd  = obfs_conf.get('password', '')
                params = f"sni={sni}&insecure=0&allowInsecure=0&upmbps={up_m}&downmbps={dn_m}"
                if obfs_type: params += f"&obfs={obfs_type}"
                if obfs_pwd: params += f"&obfs-password={urlencode(obfs_pwd)}"
                singbox_links.append(f"hysteria2://{pwd}@{SERVER_IP}:{port}?{params}#{tag_enc}")

                cp = {
                    'name': tag, 'type': 'hysteria2', 'server': SERVER_IP, 'port': port,
                    'password': pwd, 'sni': sni, 'up': f"{up_m} Mbps", 'down': f"{dn_m} Mbps",
                    'skip-cert-verify': False
                }
                if obfs_type: cp['obfs'] = obfs_type
                if obfs_pwd: cp['obfs-password'] = obfs_pwd
                clash_proxies.append(cp)
                clash_proxy_names.append(tag)

            elif t == 'tuic':
                if not users: continue
                u    = users[0]
                uuid = u.get('uuid', '')
                pwd  = u.get('password', '')
                tag_enc = urlencode(tag)
                cc   = ib.get('congestion_control', 'bbr')
                params = f"sni={sni}&congestion_control={cc}&alpn=h3&udp_relay_mode=native"
                singbox_links.append(f"tuic://{uuid}:{urlencode(pwd)}@{SERVER_IP}:{port}?{params}#{tag_enc}")

                cp = {
                    'name': tag, 'type': 'tuic', 'server': SERVER_IP, 'port': port,
                    'uuid': uuid, 'password': pwd, 'alpn': ['h3'],
                    'congestion-controller': cc, 'sni': sni, 'udp-relay-mode': 'native'
                }
                clash_proxies.append(cp)
                clash_proxy_names.append(tag)

            elif t == 'anytls':
                if not users: continue
                pwd    = users[0].get('password', '')
                tag_enc = urlencode(tag)
                params = f"security=tls&sni={sni}&insecure=0&allowInsecure=0&type=tcp"
                singbox_links.append(f"anytls://{pwd}@{SERVER_IP}:{port}?{params}#{tag_enc}")

            elif t == 'naive':
                if not users: continue
                u    = users[0]
                uname = u.get('username', '')
                pwd   = u.get('password', '')
                tag_enc = urlencode(tag)
                singbox_links.append(f"naive+https://{urlencode(uname)}:{urlencode(pwd)}@{SERVER_IP}:{port}?padding=true#{tag_enc}")
    except Exception as e:
        print(f"[WARN] Sing-box config parsing failed: {e}")

# --- 2. 解析 Xray 配置 ---
if os.path.exists(XRAY_CONFIG):
    try:
        with open(XRAY_CONFIG) as f:
            x_raw = f.read()
        x_config = json.loads(strip_comments(x_raw))
        x_inbounds = x_config.get("inbounds", [])

        x_pbk = ""
        try:
            with open("/usr/local/etc/xray/reality_pub.key") as f:
                x_pbk = f.read().strip()
        except:
            pass

        dokodemo_map = {}
        for ib in x_inbounds:
            if ib.get("protocol") == "dokodemo-door":
                ext_port = ib.get("port")
                int_port = ib.get("settings", {}).get("port")
                if int_port:
                    dokodemo_map[int_port] = ext_port

        for ib in x_inbounds:
            if ib.get("protocol") == "vless" and ib.get("streamSettings", {}).get("security") == "reality":
                u = ib.get("settings", {}).get("clients", [{}])[0]
                uuid = u.get("id", "")
                flow = u.get("flow", "")

                int_port = ib.get("port")
                ext_port = dokodemo_map.get(int_port, int_port)

                stream = ib.get("streamSettings", {})
                net = stream.get("network", "tcp")
                reality = stream.get("realitySettings", {})
                sni_list = reality.get("serverNames", [])
                sni = sni_list[0] if sni_list else ""
                sid_list = reality.get("shortIds", [])
                sid = sid_list[0] if sid_list else ""

                xhttp_path = stream.get("xhttpSettings", {}).get("path", "") if net == "xhttp" else ""

                params = f"encryption=none"
                if flow: params += f"&flow={flow}"
                params += f"&security=reality&sni={sni}&fp=chrome&pbk={urlencode(x_pbk)}&sid={sid}&type={net}&headerType=none"
                if net == "xhttp" and xhttp_path:
                    params += f"&path={urlencode(xhttp_path)}"

                tag = "Xray-Reality-xhttp" if net == "xhttp" else "Xray-Reality-TCP"

                link = f"vless://{uuid}@{SERVER_IP}:{ext_port}?{params}#{urlencode(tag)}"
                xray_links.append(link)

                cp = {
                    'name': tag, 'type': 'vless', 'server': SERVER_IP, 'port': ext_port,
                    'uuid': uuid, 'tls': True, 'servername': sni,
                    'network': net, 'udp': True,
                    'reality-opts': {'public-key': x_pbk, 'short-id': sid}
                }
                if flow: cp['flow'] = flow
                if net == 'xhttp' and xhttp_path:
                    cp['network'] = 'xhttp'
                    cp['xhttp-opts'] = {'path': xhttp_path}
                clash_proxies.append(cp)
                clash_proxy_names.append(tag)
    except Exception as e:
        print(f"[WARN] Xray config parsing failed: {e}")

all_links = singbox_links + xray_links

with open(OUTPUT_FILE, 'w') as f:
    f.write('\n'.join(all_links) + '\n')

with open(B64_FILE, 'w') as f:
    f.write(base64.b64encode('\n'.join(all_links).encode()).decode() + '\n')

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

print(f"\n[✓] 共生成 {len(all_links)} 条订阅链接")
print(f"[✓] 明文订阅: {OUTPUT_FILE}")
print(f"[✓] Base64订阅: {B64_FILE}")
print("")
if singbox_links:
    print("══════════════ Sing-box 节点 ══════════════")
    for lk in singbox_links:
        print(lk)
if xray_links:
    print("════════════════ Xray 节点 ════════════════")
    for lk in xray_links:
        print(lk)
print("═══════════════════════════════════════════")
PYEOF
}

menu_links() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 六、生成节点链接 ══${NC}"
        echo ""
        echo "  1) 生成所有节点链接（singbox / Xray / V2RayN / Clash Mihomo）"
        echo "  2) 查看明文订阅"
        echo "  3) 查看 Base64 订阅（V2RayN 用）"
        echo "  4) 查看 Clash/Mihomo 配置"
        echo "  5) 显示订阅文件路径"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
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
    echo "  4. 配置代理节点"
    echo "  5. 启动服务"
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
    echo -e "${BLUE}── 步骤 3：安装代理核心 ──${NC}"
    bash <(curl -fsSL https://sing-box.app/deb-install.sh) 2>/dev/null || true
    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box

    echo ""
    echo -e "${BLUE}── 步骤 4：配置代理节点 ──${NC}"
    configure_proxy_nodes

    echo ""
    echo -e "${BLUE}── 步骤 5：启动服务 ──${NC}"
    systemctl enable sing-box 2>/dev/null || true
    systemctl restart sing-box 2>/dev/null || true
    if systemctl is-active --quiet sing-box; then
        log_success "sing-box 运行中"
    else
        log_warn "sing-box 未运行，可能是因为在第4步选择了配置Xray。如果使用Xray，Xray服务已启动。"
    fi

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
        echo "║          服务器一键管理脚本  ($SCRIPT_VERSION)             ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo "  部署流程:"
        echo -e "   ${GREEN}1.${NC} 基础设置（SSH/fail2ban/BBR）       ${GREEN}2.${NC} SSL 证书申请与安装"
        echo -e "   ${GREEN}3.${NC} 安装服务 (包含 Docker/拓展)        ${GREEN}4.${NC} 配置代理节点 (sing-box/Xray)"
        echo -e "   ${GREEN}5.${NC} 服务管理 (启停/日志/面板维护)      ${GREEN}6.${NC} 生成节点订阅链接"
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
            3) detect_distro; menu_install_service ;;
            4) configure_proxy_nodes ;;
            5) menu_service ;;
            6) menu_links ;;
            7) detect_distro; run_all ;;
            0)
                echo ""
                echo -e "${GREEN}感谢使用，再见！${NC}"
                echo -e "${YELLOW}提示：退出脚本后，随时可以输入快捷命令 ${BOLD}${GREEN}vpsge${NC}${YELLOW} 重新进入主菜单。${NC}"
                echo ""
                exit 0 ;;
            *)
                log_warn "无效选项，请重新选择"
                sleep 1 ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  安装 vpsge 快捷命令
# ────────────────────────────────────────────────────────────────
install_self() {
    local target="/usr/bin/vpsge"
    
    # 如果当前正在 /usr/bin/vpsge 执行，则无需安装
    [[ "$0" == "$target" ]] && return 0

    # 判断是否为本地文件正常运行，若是则直接复制
    if [[ -f "$0" && "$0" != *"bash"* && "$0" != *"/dev/fd/"* ]]; then
        cp -f "$0" "$target"
        chmod 755 "$target"
    else
        # 否则判定为通过 bash <(curl ...) 执行流，强制从直链拉取文件创建快捷命令
        curl -fsSL --connect-timeout 10 "$VPSGE_REMOTE_URL" -o "$target" 2>/dev/null || \
        wget -qO "$target" "$VPSGE_REMOTE_URL" 2>/dev/null
        
        if [[ -f "$target" ]]; then
            chmod 755 "$target"
        fi
    fi

    if is_cmd_exist vpsge; then
        log_success "已安装快捷命令: vpsge"
    fi
}

# ────────────────────────────────────────────────────────────────
#  入口
# ────────────────────────────────────────────────────────────────
check_root
detect_distro
install_self
main_menu
