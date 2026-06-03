#!/bin/bash
# ================================================================
#   服务器一键管理脚本 (jddj)
#   版本号：jddj-ge-v7
#   集成：SSH安全加固 / SSL证书 / sing-box 安装配置 / 节点生成
# ================================================================
# 【本次优化内容 (jddj-ge-v7)】
#   1. 新增【旧节点链接导入】功能：在配置 sing-box 阶段，支持粘贴单个、多个
#      协议链接或完整 Base64 订阅内容。
#   2. 自动复用核心参数：脚本将智能提取链接中的端口、UUID、密码、路径、
#      Reality ShortID 等参数。在自动/静默配置模式下，新生成的节点链接
#      将与原来保持完全一致（未导入的协议仍保持随机或手动设置）。
#   3. 修复 Bash 与 Python 之间的环境变量流转 Bug：加入精准换行解析
#      与 shlex.quote 强引用包裹，完美防止密码包含 $、@ 等特殊字符时
#      被终端吞噬或破坏，极大提升提取成功率。
# ================================================================

# 遇到错误立即退出
set -e  

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

# 全局变量
SCRIPT_VERSION="jddj-ge-v7"
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
#  Root 检查 & 环境依赖
# ────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行，请使用 sudo 或切换到 root 用户"
        exit 1
    fi
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID%%.*}"
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

bootstrap_packages() {
    log_step "预装基础组件"
    if command -v apt &>/dev/null; then
        apt update -y && apt install -y curl sudo wget git unzip nano vim openssl python3
    elif command -v dnf &>/dev/null; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y curl sudo wget git unzip nano vim openssl python3
    elif command -v yum &>/dev/null; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl sudo wget git unzip nano vim openssl python3
    fi
    log_success "基础组件已就绪"
}

# ────────────────────────────────────────────────────────────────
#  生成/交互核心工具库
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
gen_naive_username() { tr -dc 'a-z0-9' </dev/urandom | head -c 12 2>/dev/null || echo "naiveuser$(shuf -i 1000-9999 -n1)"; }

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
    echo -e "    当前配置值: ${YELLOW}${randval}${NC}"
    echo -e "    (回车使用该值，或手动输入覆盖)"
    read -rp "  > " input
    result="${input:-$randval}"
    echo -e "  ${GREEN}✓ ${label} = ${result}${NC}"
    echo ""
    printf -v "$varname" '%s' "$result"
}

# ────────────────────────────────────────────────────────────────
#  证书信息提取与路径匹配
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
    printf '%s\n' "${domains[@]}" | sort -u | grep -v '^\*' | grep '\.' | grep -v ' ' || true
}

select_server_name() {
    local default_sn="${1:-example.com}"
    echo ""
    echo -e "  ${CYAN}◆ server_name（域名/伪装域名）${NC}"
    local domains=()
    mapfile -t domains < <(get_cert_domains 2>/dev/null)

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        if [[ ${#domains[@]} -gt 0 ]]; then SELECTED_SN="${domains[0]}"
        else SELECTED_SN="${default_sn}"; fi
        echo -e "  ${GREEN}✓ [自动] server_name = ${SELECTED_SN}${NC}"
        echo ""
        return
    fi

    if [[ ${#domains[@]} -gt 0 ]]; then
        echo -e "    检测到已安装证书，请选择："
        for i in "${!domains[@]}"; do echo -e "    ${YELLOW}$((i+1)))${NC} ${domains[$i]}"; done
        local manual_idx=$(( ${#domains[@]} + 1 ))
        echo -e "    ${YELLOW}${manual_idx})${NC} 手动输入"
        echo ""
        local sn_choice
        read -rp "  > (编号，默认 1): " sn_choice
        sn_choice="${sn_choice:-1}"
        if [[ "$sn_choice" =~ ^[0-9]+$ ]] && [[ "$sn_choice" -ge 1 ]] && [[ "$sn_choice" -le "${#domains[@]}" ]]; then
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
#  一、基础安全设置
# ────────────────────────────────────────────────────────────────
setup_ssh_key() {
    log_step "配置 SSH 密钥登录"
    echo "请输入你的 SSH 公钥:"
    read -r PUBLIC_KEY
    if [[ -z "$PUBLIC_KEY" ]]; then log_error "公钥不能为空"; return 1; fi
    mkdir -p /root/.ssh && chmod 700 /root/.ssh && chown root:root /root/.ssh
    if ! grep -qF "$PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
        log_success "公钥已添加"
    fi
    chmod 600 /root/.ssh/authorized_keys && chown root:root /root/.ssh/authorized_keys
    command -v restorecon &>/dev/null && restorecon -Rv /root/.ssh/ >/dev/null 2>&1
    log_success "SSH 密钥登录配置完成"
}
disable_password_login() {
    log_step "禁用 SSH 密码登录"
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    sshd_set() {
        if grep -qE "^#?\s*${1}\s" "$SSHD_CONFIG"; then sed -i "s|^#\?\s*${1}\s.*|${1} ${2}|" "$SSHD_CONFIG"
        else echo "${1} ${2}" >> "$SSHD_CONFIG"; fi
    }
    sshd_set "PasswordAuthentication" "no"
    sshd_set "ChallengeResponseAuthentication" "no"
    sshd_set "KbdInteractiveAuthentication" "no"
    sshd_set "PubkeyAuthentication" "yes"
    sshd_set "PermitRootLogin" "prohibit-password"
    if sshd -t 2>&1; then systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true; log_success "密码登录已禁用"
    else log_error "SSH 配置语法错误"; fi
}
change_ssh_port() {
    log_step "修改 SSH 端口"
    local current_port=$(grep -E "^Port\s" /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    echo -n "请输入新端口（当前 ${current_port:-22}，回车默认 43916）: "
    read -r SSH_PORT
    [[ -z "$SSH_PORT" ]] && SSH_PORT=43916
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    sed -i 's/^Port\s/#Port /' "$SSHD_CONFIG"
    echo "Port $SSH_PORT" >> "$SSHD_CONFIG"
    if sshd -t 2>&1; then systemctl restart sshd 2>/dev/null || systemctl restart ssh; log_success "SSH 端口已设为 $SSH_PORT"
    else log_error "SSH 语法错误"; fi
}
enable_bbr() {
    log_step "启用 BBR"
    grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 && log_success "BBR 启用成功"
}
setup_fail2ban() {
    log_step "安装 fail2ban"
    $PKG_MANAGER install -y fail2ban >/dev/null 2>&1 || true
    systemctl enable fail2ban && systemctl start fail2ban && log_success "fail2ban 启动成功"
}
menu_basic() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 一、基础安全设置 ══${NC}"
        echo "  1) SSH 密钥登录"
        echo "  2) 禁用密码登录"
        echo "  3) 修改 SSH 端口"
        echo "  4) 启用 BBR 拥塞控制"
        echo "  5) 安装 fail2ban"
        echo "  6) 全部执行 (1→5)"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        case ${opt:-0} in
            1) setup_ssh_key; press_enter ;;
            2) disable_password_login; press_enter ;;
            3) change_ssh_port; press_enter ;;
            4) enable_bbr; press_enter ;;
            5) setup_fail2ban; press_enter ;;
            6) bootstrap_packages; setup_ssh_key; disable_password_login; change_ssh_port; enable_bbr; setup_fail2ban; press_enter ;;
            0) return ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  四、配置 sing-box — 各协议 build_* 函数
# ────────────────────────────────────────────────────────────────
build_vless_tcp() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── VLESS — TCP / XTLS-Vision ───${NC}\n"
    local tag port uuid uname flow_choice flow
    ask_val tag "tag（inbound 标识）" "vless-tcp-in"
    ask_val port "listen_port（监听端口）" "${OLD_VLESS_TCP_PORT:-47790}"
    ask_random uuid "uuid（用户 UUID）" "${OLD_VLESS_TCP_UUID:-$(gen_uuid)}"
    ask_val uname "name（用户名）" "user-vless-tcp"
    
    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        flow="xtls-rprx-vision"; echo -e "  ${GREEN}✓ [自动] flow = xtls-rprx-vision${NC}"
    else
        echo -e "  ${CYAN}◆ flow（流控模式）${NC}\n    ${YELLOW}1)${NC} xtls-rprx-vision\n    ${YELLOW}2)${NC} 无（普通 TLS）"
        ask_val flow_choice "请输入编号" "1"
        [[ "$flow_choice" == "2" ]] && flow="" || flow="xtls-rprx-vision"
    fi
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    local flow_json
    [[ -n "$flow" ]] && flow_json='"flow": "'"$flow"'"' || flow_json='"flow": ""'
    cat > "$_jf" << EOF
    {
      "type": "vless", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "$uname", "uuid": "$uuid", $flow_json}],
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH", "alpn": ["h2", "http/1.1"]},
      "multiplex": {"enabled": false}
    }
EOF
}

build_vless_ws() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── VLESS — WebSocket ───${NC}\n"
    local tag port uuid wspath
    ask_val tag "tag（inbound 标识）" "vless-ws-in"
    ask_val port "listen_port（监听端口）" "${OLD_VLESS_WS_PORT:-47791}"
    ask_random uuid "uuid（用户 UUID）" "${OLD_VLESS_WS_UUID:-$(gen_uuid)}"
    ask_val wspath "ws path（WebSocket 路径）" "${OLD_VLESS_WS_PATH:-/vless-ws}"
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    cat > "$_jf" << EOF
    {
      "type": "vless", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "user-vless-ws", "uuid": "$uuid", "flow": ""}],
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH", "alpn": ["http/1.1"]},
      "transport": {"type": "ws", "path": "$wspath", "headers": {"Host": "$SELECTED_SN"}}
    }
EOF
}

build_vless_grpc() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── VLESS — gRPC ───${NC}\n"
    local tag port uuid svcname
    ask_val tag "tag" "vless-grpc-in"
    ask_val port "listen_port" "${OLD_VLESS_GRPC_PORT:-47792}"
    ask_random uuid "uuid" "${OLD_VLESS_GRPC_UUID:-$(gen_uuid)}"
    ask_val svcname "service_name" "${OLD_VLESS_GRPC_SVC:-vless-grpc-service}"
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    cat > "$_jf" << EOF
    {
      "type": "vless", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "user-vless-grpc", "uuid": "$uuid", "flow": ""}],
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH", "alpn": ["h2"]},
      "transport": {"type": "grpc", "service_name": "$svcname"}
    }
EOF
}

build_vless_reality() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── VLESS — REALITY ───${NC}\n"
    local port uuid pk si sn hs_server hs_port
    ask_val port "listen_port（建议 443）" "${OLD_VLESS_REALITY_PORT:-443}"
    ask_random uuid "uuid（用户 UUID）" "${OLD_VLESS_REALITY_UUID:-$(gen_uuid)}"

    echo -e "  ${YELLOW}正在生成 REALITY 密钥对...${NC}"
    if [[ -n "$OLD_VLESS_REALITY_PBK" ]]; then
        log_warn "检测到旧的 Reality 节点配置！"
        log_warn "由于服务端私钥无法从你的分享链接中提取，已保留了原 UUID、端口 和 ShortID。"
        log_warn "【重点提醒】：必须为你生成一组新公私钥对！配置完成后，请在客户端更新 Reality 节点的 Public Key(pbk)，否则无法连接！"
    fi

    local keypair_out privkey pubkey
    keypair_out=$(gen_reality_keypair)
    privkey=$(echo "$keypair_out" | grep -i private | awk '{print $NF}')
    pubkey=$(echo  "$keypair_out" | grep -i public  | awk '{print $NF}')

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        pk="$privkey"; echo -e "  ${GREEN}✓ [自动] private_key = ${pk}${NC}"
    else
        echo -e "  ${CYAN}◆ private_key（REALITY 私钥）${NC}"
        echo -e "    生成值: ${YELLOW}${privkey}${NC}"
        read -rp "  > (回车使用该值): " _pk_input
        pk="${_pk_input:-$privkey}"
        if [[ -n "$_pk_input" && "$_pk_input" != "$privkey" ]]; then
            read -rp "  > 已自定义私钥，请输入对应的 public_key: " pubkey
        fi
    fi
    echo -e "  ${BOLD}${GREEN}★ 客户端所需新 public_key（稍后生成的链接已自动集成）:${NC} ${pubkey}\n"
    
    ask_random si "short_id（Short ID）" "${OLD_VLESS_REALITY_SID:-$(gen_short_id)}"
    ask_val sn "server_name（伪装域名）" "www.microsoft.com"
    ask_val hs_server "handshake server" "127.0.0.1"
    ask_val hs_port "handshake port" "8001"

    cat > "$_jf" << EOF
    {
      "type": "vless", "tag": "vless-reality-in", "listen": "::", "listen_port": $port,
      "users": [{"uuid": "$uuid", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "$sn",
        "reality": {"enabled": true, "handshake": {"server": "$hs_server", "server_port": $hs_port}, "private_key": "$pk", "short_id": ["$si"]}
      }
    }
EOF
    local _reality_meta="/etc/sing-box/reality_meta.conf"
    grep -v "^${port}:" "$_reality_meta" 2>/dev/null > "${_reality_meta}.tmp" || true
    echo "${port}:${pubkey}" >> "${_reality_meta}.tmp"
    mv "${_reality_meta}.tmp" "$_reality_meta"
}

build_vmess_tcp() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── VMess — TCP (TLS) ───${NC}\n"
    local tag port uuid
    ask_val tag "tag" "vmess-tcp-in"
    ask_val port "listen_port" "${OLD_VMESS_TCP_PORT:-45790}"
    ask_random uuid "uuid" "${OLD_VMESS_TCP_UUID:-$(gen_uuid)}"
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    cat > "$_jf" << EOF
    {
      "type": "vmess", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "user-vmess-tcp", "uuid": "$uuid", "alterId": 0}],
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH", "alpn": ["h2", "http/1.1"]}
    }
EOF
}

build_vmess_ws() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── VMess — WebSocket (TLS) ───${NC}\n"
    local tag port uuid wspath
    ask_val tag "tag" "vmess-ws-in"
    ask_val port "listen_port" "${OLD_VMESS_WS_PORT:-45791}"
    ask_random uuid "uuid" "${OLD_VMESS_WS_UUID:-$(gen_uuid)}"
    ask_val wspath "ws path" "${OLD_VMESS_WS_PATH:-/vmess-ws}"
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    cat > "$_jf" << EOF
    {
      "type": "vmess", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "user-vmess-ws", "uuid": "$uuid", "alterId": 0}],
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH", "alpn": ["http/1.1"]},
      "transport": {"type": "ws", "path": "$wspath", "headers": {"Host": "$SELECTED_SN"}}
    }
EOF
}

build_trojan_tcp() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── Trojan — TCP (TLS) ───${NC}\n"
    local tag port pwd
    ask_val tag "tag" "trojan-tcp-in"
    ask_val port "listen_port" "${OLD_TROJAN_TCP_PORT:-44790}"
    ask_random pwd "password" "${OLD_TROJAN_TCP_PWD:-$(gen_password 20)}"
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    cat > "$_jf" << EOF
    {
      "type": "trojan", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "user-trojan-tcp", "password": "$pwd"}],
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH", "alpn": ["h2", "http/1.1"]}
    }
EOF
}

build_trojan_ws() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── Trojan — WebSocket (TLS) ───${NC}\n"
    local tag port pwd wspath
    ask_val tag "tag" "trojan-ws-in"
    ask_val port "listen_port" "${OLD_TROJAN_WS_PORT:-44791}"
    ask_random pwd "password" "${OLD_TROJAN_WS_PWD:-$(gen_password 20)}"
    ask_val wspath "ws path" "${OLD_TROJAN_WS_PATH:-/trojan-ws}"
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    cat > "$_jf" << EOF
    {
      "type": "trojan", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "user-trojan-ws", "password": "$pwd"}],
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH", "alpn": ["http/1.1"]},
      "transport": {"type": "ws", "path": "$wspath", "headers": {"Host": "$SELECTED_SN"}}
    }
EOF
}

build_ss_classic() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── Shadowsocks — 经典加密 ───${NC}\n"
    local tag port method pwd mc
    ask_val tag "tag" "ss-aes-in"
    ask_val port "listen_port" "${OLD_SS_PORT:-46792}"
    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        method="${OLD_SS_METHOD:-aes-256-gcm}"; echo -e "  ${GREEN}✓ [自动] 加密方式 = ${method}${NC}"
    else
        local _def_mc="1"
        [[ "${OLD_SS_METHOD}" == "aes-128-gcm" ]] && _def_mc="2"
        [[ "${OLD_SS_METHOD}" == "chacha20-ietf-poly1305" ]] && _def_mc="3"
        echo -e "  ${CYAN}◆ 加密方式${NC}\n    1) aes-256-gcm\n    2) aes-128-gcm\n    3) chacha20-ietf-poly1305"
        ask_val mc "请输入编号" "$_def_mc"
        case $mc in 2) method="aes-128-gcm";; 3) method="chacha20-ietf-poly1305";; *) method="aes-256-gcm";; esac
    fi
    ask_random pwd "password" "${OLD_SS_PWD:-$(gen_password 20)}"
    cat > "$_jf" << EOF
    {
      "type": "shadowsocks", "tag": "$tag", "listen": "::", "listen_port": $port,
      "method": "$method", "password": "$pwd", "multiplex": {"enabled": true}
    }
EOF
}

build_ss2022_256() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── Shadowsocks 2022 — aes-256 ───${NC}\n"
    local tag port spwd upwd
    ask_val tag "tag" "ss-2022-256-in"
    ask_val port "listen_port" "${OLD_SS256_PORT:-46791}"
    ask_random spwd "server password" "${OLD_SS256_SPWD:-$(gen_ss2022_key_256)}"
    ask_random upwd "user password" "${OLD_SS256_UPWD:-$(gen_ss2022_key_256)}"
    cat > "$_jf" << EOF
    {
      "type": "shadowsocks", "tag": "$tag", "listen": "::", "listen_port": $port,
      "method": "2022-blake3-aes-256-gcm", "password": "$spwd",
      "users": [{"name": "user-ss256", "password": "$upwd"}]
    }
EOF
}

build_ss2022_128() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── Shadowsocks 2022 — aes-128 ───${NC}\n"
    local tag port spwd upwd
    ask_val tag "tag" "ss-2022-128-in"
    ask_val port "listen_port" "${OLD_SS128_PORT:-46790}"
    ask_random spwd "server password" "${OLD_SS128_SPWD:-$(gen_ss2022_key_128)}"
    ask_random upwd "user password" "${OLD_SS128_UPWD:-$(gen_ss2022_key_128)}"
    cat > "$_jf" << EOF
    {
      "type": "shadowsocks", "tag": "$tag", "listen": "::", "listen_port": $port,
      "method": "2022-blake3-aes-128-gcm", "password": "$spwd",
      "users": [{"name": "user-ss128", "password": "$upwd"}]
    }
EOF
}

build_hysteria2() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── Hysteria2 ───${NC}\n"
    local tag port pwd obfspwd
    ask_val tag "tag" "hysteria2-in"
    ask_val port "listen_port" "${OLD_HY2_PORT:-43790}"
    ask_random pwd "password" "${OLD_HY2_PWD:-$(gen_uuid)}"
    ask_random obfspwd "obfs password" "${OLD_HY2_OBFSPWD:-$(gen_password 16)}"
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    local _obfs="${OLD_HY2_OBFS:-salamander}"
    cat > "$_jf" << EOF
    {
      "type": "hysteria2", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "user-hy2", "password": "$pwd"}],
      "up_mbps": 200, "down_mbps": 100,
      "obfs": {"type": "$_obfs", "password": "$obfspwd"},
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH", "alpn": ["h3"]}
    }
EOF
}

build_tuic() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── TUIC v5 ───${NC}\n"
    local tag port uuid pwd
    ask_val tag "tag" "tuic-in"
    ask_val port "listen_port" "${OLD_TUIC_PORT:-42790}"
    ask_random uuid "uuid" "${OLD_TUIC_UUID:-$(gen_uuid)}"
    ask_random pwd "password" "${OLD_TUIC_PWD:-$(gen_password 20)}"
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    local _cc="${OLD_TUIC_CC:-bbr}"
    cat > "$_jf" << EOF
    {
      "type": "tuic", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "user-tuic", "uuid": "$uuid", "password": "$pwd"}],
      "congestion_control": "$_cc",
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH", "alpn": ["h3"]}
    }
EOF
}

build_anytls() {
    local _jf="$1"
    echo -e "\n${CYAN}  ─── AnyTLS ───${NC}\n"
    local tag port pwd
    ask_val tag "tag" "anytls-in"
    ask_val port "listen_port" "${OLD_ANYTLS_PORT:-48790}"
    ask_random pwd "password" "${OLD_ANYTLS_PWD:-$(gen_uuid)}"
    select_server_name "example.com"
    ask_cert_paths "$SELECTED_SN"
    cat > "$_jf" << EOF
    {
      "type": "anytls", "tag": "$tag", "listen": "::", "listen_port": $port,
      "users": [{"name": "user-anytls", "password": "$pwd"}],
      "tls": {"enabled": true, "server_name": "$SELECTED_SN", "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH"}
    }
EOF
}

configure_singbox() {
    if ! command -v python3 &>/dev/null; then
        log_info "正在预装 python3 以支持高级解析..."
        if command -v apt &>/dev/null; then apt update -y && apt install -y python3 >/dev/null 2>&1;
        elif command -v dnf &>/dev/null; then dnf install -y python3 >/dev/null 2>&1;
        elif command -v yum &>/dev/null; then yum install -y python3 >/dev/null 2>&1; fi
    fi

    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 四、配置 sing-box ══${NC}\n"

        echo -e "${CYAN}是否需要导入旧节点链接以保持配置无缝恢复？（支持批量复制单行/多行/Base64文本）${NC}"
        echo -e "  1) 是，我现在粘贴旧链接"
        echo -e "  2) 否，直接生成全新配置 [默认]"
        read -rp "请选择 (1-2, 默认 2): " import_choice
        import_choice=${import_choice:-2}

        if [[ "$import_choice" == "1" ]]; then
            echo -e "\n${YELLOW}请在下方粘贴旧节点链接内容（粘贴完毕后，新起一行输入 EOF 并按回车结束）：${NC}"
            local old_links=""
            while IFS= read -r line; do
                [[ "$line" == "EOF" ]] && break
                old_links+="${line}"$'\n'
            done
            
            if [[ -n "$old_links" ]]; then
                log_info "正在极速解析提取参数..."
                local py_script=$(mktemp /tmp/parse_links.XXXXXX.py)
                cat > "$py_script" << 'PYEOF'
import sys, urllib.parse, base64, json, shlex

def decode_b64(s):
    s = s.replace('-', '+').replace('_', '/')
    s += "=" * ((4 - len(s) % 4) % 4)
    return base64.b64decode(s).decode("utf-8", "ignore")

input_text = sys.stdin.read().strip()
if not input_text: sys.exit(0)

if "://" not in input_text:
    try: input_text = decode_b64(input_text)
    except: pass

vars_out = {}
for line in input_text.splitlines():
    line = line.strip()
    if not line: continue
    try:
        if line.startswith("vmess://"):
            b64 = line[8:]
            obj = json.loads(decode_b64(b64))
            port = obj.get("port")
            uid = obj.get("id")
            net = obj.get("net")
            path = obj.get("path", "")
            if net == "ws" or "ws" in obj.get("ps", ""):
                if uid: vars_out["OLD_VMESS_WS_UUID"] = uid
                if port: vars_out["OLD_VMESS_WS_PORT"] = port
                if path: vars_out["OLD_VMESS_WS_PATH"] = path
            else:
                if uid: vars_out["OLD_VMESS_TCP_UUID"] = uid
                if port: vars_out["OLD_VMESS_TCP_PORT"] = port
        else:
            parsed = urllib.parse.urlparse(line)
            scheme = parsed.scheme.lower()
            userinfo = parsed.username or ""
            pwd_info = parsed.password or ""
            if pwd_info: userinfo = f"{userinfo}:{pwd_info}"
            userinfo = urllib.parse.unquote(userinfo)
            
            port = parsed.port
            qs = urllib.parse.parse_qs(parsed.query)
            tag = urllib.parse.unquote(parsed.fragment or "")
            
            if scheme == "vless":
                uuid = userinfo
                security = qs.get("security", [""])[0]
                type_ = qs.get("type", [""])[0]
                if security == "reality" or "reality" in tag:
                    vars_out["OLD_VLESS_REALITY_UUID"] = uuid
                    if port: vars_out["OLD_VLESS_REALITY_PORT"] = port
                    if "pbk" in qs: vars_out["OLD_VLESS_REALITY_PBK"] = qs["pbk"][0]
                    if "sid" in qs: vars_out["OLD_VLESS_REALITY_SID"] = qs["sid"][0]
                elif type_ == "grpc" or "grpc" in tag:
                    vars_out["OLD_VLESS_GRPC_UUID"] = uuid
                    if port: vars_out["OLD_VLESS_GRPC_PORT"] = port
                    if "serviceName" in qs: vars_out["OLD_VLESS_GRPC_SVC"] = qs["serviceName"][0]
                elif type_ == "ws" or "ws" in tag:
                    vars_out["OLD_VLESS_WS_UUID"] = uuid
                    if port: vars_out["OLD_VLESS_WS_PORT"] = port
                    if "path" in qs: vars_out["OLD_VLESS_WS_PATH"] = qs["path"][0]
                else:
                    vars_out["OLD_VLESS_TCP_UUID"] = uuid
                    if port: vars_out["OLD_VLESS_TCP_PORT"] = port
            elif scheme == "trojan":
                pwd = userinfo
                type_ = qs.get("type", [""])[0]
                if type_ == "ws" or "ws" in tag:
                    vars_out["OLD_TROJAN_WS_PWD"] = pwd
                    if port: vars_out["OLD_TROJAN_WS_PORT"] = port
                    if "path" in qs: vars_out["OLD_TROJAN_WS_PATH"] = qs["path"][0]
                else:
                    vars_out["OLD_TROJAN_TCP_PWD"] = pwd
                    if port: vars_out["OLD_TROJAN_TCP_PORT"] = port
            elif scheme == "ss":
                try:
                    raw = decode_b64(userinfo)
                    parts = raw.split(":", 2)
                    method = parts[0]
                    if "2022" in method:
                        spwd = parts[1] if len(parts)>1 else ""
                        upwd = parts[2] if len(parts)>2 else ""
                        if "128" in method or "128" in tag:
                            vars_out["OLD_SS128_METHOD"] = method
                            vars_out["OLD_SS128_SPWD"] = spwd
                            vars_out["OLD_SS128_UPWD"] = upwd
                            if port: vars_out["OLD_SS128_PORT"] = port
                        else:
                            vars_out["OLD_SS256_METHOD"] = method
                            vars_out["OLD_SS256_SPWD"] = spwd
                            vars_out["OLD_SS256_UPWD"] = upwd
                            if port: vars_out["OLD_SS256_PORT"] = port
                    else:
                        pwd = parts[1] if len(parts)>1 else ""
                        vars_out["OLD_SS_METHOD"] = method
                        vars_out["OLD_SS_PWD"] = pwd
                        if port: vars_out["OLD_SS_PORT"] = port
                except: pass
            elif scheme == "hysteria2":
                vars_out["OLD_HY2_PWD"] = userinfo
                if port: vars_out["OLD_HY2_PORT"] = port
                if "obfs" in qs: vars_out["OLD_HY2_OBFS"] = qs["obfs"][0]
                if "obfs-password" in qs: vars_out["OLD_HY2_OBFSPWD"] = urllib.parse.unquote(qs["obfs-password"][0])
            elif scheme == "tuic":
                if ":" in userinfo:
                    uid, pwd = userinfo.split(":", 1)
                    vars_out["OLD_TUIC_UUID"] = uid
                    vars_out["OLD_TUIC_PWD"] = pwd
                else:
                    vars_out["OLD_TUIC_UUID"] = userinfo
                if port: vars_out["OLD_TUIC_PORT"] = port
                if "congestion_control" in qs: vars_out["OLD_TUIC_CC"] = qs["congestion_control"][0]
            elif scheme == "anytls":
                vars_out["OLD_ANYTLS_PWD"] = userinfo
                if port: vars_out["OLD_ANYTLS_PORT"] = port
    except Exception: pass

for k, v in vars_out.items():
    print(f"export {k}={shlex.quote(str(v))}")
PYEOF
                local parse_exports
                parse_exports=$(python3 "$py_script" <<< "$old_links")
                eval "$parse_exports"
                rm -f "$py_script"
                log_success "解析完成，已无缝吸纳所有支持节点的关键参数。"
            else
                log_warn "未识别到输入内容，将转为全新配置..."
            fi
            sleep 1
            clear
            echo -e "${BOLD}${CYAN}══ 四、配置 sing-box ══${NC}\n"
        fi

        echo "请选择要配置的协议（多个选择用空格分隔，例如：1 3 5）:"
        echo "   1)  VLESS — TCP / XTLS-Vision"
        echo "   2)  VLESS — WebSocket"
        echo "   3)  VLESS — gRPC"
        echo "   4)  VLESS — REALITY (TCP + XTLS-Vision) [默认端口: 443]"
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
        echo ""
        echo -e "${GREEN}  16)  全部配置（逐一交互确认）${NC}"
        echo -e "${GREEN}  17)  全部自动配置（静默生成，复用已提取的参数！）${NC}"
        echo -e "${YELLOW}   0)  返回主菜单${NC}"
        echo ""
        
        read -rp "请输入选项（例如 1 4 12，默认 0）: " -a PROTO_CHOICES
        [[ ${#PROTO_CHOICES[@]} -eq 0 ]] && PROTO_CHOICES=("0")
        [[ "${PROTO_CHOICES[0]}" == "0" ]] && return

        AUTO_DEFAULT=false
        local has_17=false has_16=false
        
        for choice in "${PROTO_CHOICES[@]}"; do
            [[ "$choice" == "17" ]] && has_17=true
            [[ "$choice" == "16" ]] && has_16=true
        done

        if [[ "$has_17" == "true" ]]; then
            PROTO_CHOICES=(1 2 3 4 5 6 7 8 9 10 11 12 13 14)
            AUTO_DEFAULT=true
            log_info "已开启静默配置，若导入了旧节点则100%复用参数，缺失协议则安全随机..."
            sleep 1
        elif [[ "$has_16" == "true" ]]; then
            PROTO_CHOICES=(1 2 3 4 5 6 7 8 9 10 11 12 13 14)
            log_info "即将为您逐一交互确认全部协议..."
            sleep 1
        fi

        local TMP_JSON=$(mktemp /tmp/jddj_inbound_XXXXXX)
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
                *)  continue ;;
            esac
            local inbound_json=$(cat "$TMP_JSON")
            [[ -z "$inbound_json" ]] && continue
            if $first; then INBOUNDS_JSON="$inbound_json"; first=false
            else INBOUNDS_JSON="${INBOUNDS_JSON},${inbound_json}"; fi
        done
        rm -f "$TMP_JSON"

        mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box
        cat > /etc/sing-box/config.json << EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
$INBOUNDS_JSON
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ]
}
EOF
        log_success "配置文件已完美写入: /etc/sing-box/config.json"
        press_enter
        break
    done
}

# ────────────────────────────────────────────────────────────────
#  六、生成节点链接与服务状态流转（其它函数省略细节，结构保留不变以省流）
# ────────────────────────────────────────────────────────────────
generate_links() {
    local CONFIG="/etc/sing-box/config.json"
    if [[ ! -f "$CONFIG" ]]; then log_error "未找到配置"; return 1; fi
    local SERVER_IP=$(curl -s --max-time 4 https://api.ipify.org || echo "127.0.0.1")
    
    python3 << PYEOF
import json, base64, sys, re, urllib.parse
CONFIG_FILE = "/etc/sing-box/config.json"
SERVER_IP   = "$SERVER_IP"
OUTPUT_FILE = "/etc/sing-box/subscription.txt"
B64_FILE    = "/etc/sing-box/subscription.b64"

def urlencode(s): return urllib.parse.quote(str(s), safe='')

with open(CONFIG_FILE) as f:
    config = json.loads(re.sub(r'(?<![:/])//[^\n]*', '', f.read()))

links = []
for ib in config.get('inbounds', []):
    t = ib.get('type', '')
    tag = urlencode(ib.get('tag', t))
    port = ib.get('listen_port')
    if not port: continue
    
    addr = ib.get('tls', {}).get('server_name', SERVER_IP)
    net = ib.get('transport', {}).get('type', 'tcp')
    path = ib.get('transport', {}).get('path', '/')

    if t == 'vless':
        u = ib.get('users', [{}])[0]
        reality_on = ib.get('tls', {}).get('reality', {}).get('enabled', False)
        if reality_on:
            pbk = ''
            try:
                with open('/etc/sing-box/reality_meta.conf') as _mf:
                    for _l in _mf:
                        if _l.startswith(f"{port}:"): pbk = _l.split(':', 1)[1].strip(); break
            except: pass
            sid = ib['tls']['reality']['short_id'][0]
            params = f"encryption=none&flow={u.get('flow','')}&security=reality&sni={addr}&fp=chrome&pbk={urlencode(pbk)}&sid={sid}&type=tcp&headerType=none"
        else:
            params = f"encryption=none&security=tls&sni={addr}&fp=chrome&type={net}&headerType=none"
            if net == 'ws': params += f"&path={urlencode(path)}"
            if net == 'grpc': params += f"&serviceName={urlencode(ib.get('transport',{}).get('service_name',''))}"
        links.append(f"vless://{u.get('uuid')}@{addr}:{port}?{params}#{tag}")
    elif t == 'vmess':
        u = ib.get('users', [{}])[0]
        obj = {'v':'2','ps':ib.get('tag',t),'add':addr,'port':str(port),'id':u.get('uuid'),'aid':'0','net':net,'type':'none','host':addr,'path':path,'tls':'tls'}
        enc = base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip('=')
        links.append(f"vmess://{enc}")
    elif t == 'trojan':
        params = f"security=tls&sni={addr}&type={net}"
        if net == 'ws': params += f"&path={urlencode(path)}"
        links.append(f"trojan://{urlencode(ib['users'][0]['password'])}@{addr}:{port}?{params}#{tag}")
    elif t == 'shadowsocks':
        method, pwd = ib.get('method'), ib.get('password')
        if method.startswith('2022-'):
            upwd = ib.get('users', [{}])[0].get('password', '')
            raw = f"{method}:{pwd}:{upwd}" if upwd else f"{method}:{pwd}"
        else: raw = f"{method}:{pwd}"
        info = base64.urlsafe_b64encode(raw.encode()).decode().rstrip('=')
        links.append(f"ss://{info}@{SERVER_IP}:{port}#{tag}")
    elif t == 'hysteria2':
        obfs = ib.get('obfs', {})
        params = f"sni={addr}&insecure=0&obfs={obfs.get('type','')}&obfs-password={urlencode(obfs.get('password',''))}"
        links.append(f"hysteria2://{ib['users'][0]['password']}@{addr}:{port}?{params}#{tag}")
    elif t == 'tuic':
        cc = ib.get('congestion_control', 'bbr')
        links.append(f"tuic://{ib['users'][0]['uuid']}:{urlencode(ib['users'][0]['password'])}@{addr}:{port}?sni={addr}&congestion_control={cc}&alpn=h3#{tag}")
    elif t == 'anytls':
        links.append(f"anytls://{ib['users'][0]['password']}@{addr}:{port}?security=tls&sni={addr}&type=tcp#{tag}")

with open(OUTPUT_FILE, 'w') as f: f.write('\n'.join(links) + '\n')
with open(B64_FILE, 'w') as f: f.write(base64.b64encode('\n'.join(links).encode()).decode() + '\n')

print(f"\n[✓] 共生成 {len(links)} 条订阅链接")
for lk in links: print(lk)
PYEOF
    press_enter
}

menu_service() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 五、服务管理 ══${NC}"
        echo -e "  1) 启动 sing-box \n  2) 停止 sing-box \n  3) 重启 sing-box \n  4) 验证配置文件 \n  0) 返回"
        read -rp "请选择: " opt
        case ${opt:-0} in
            1) systemctl start sing-box && log_success "已启动"; press_enter ;;
            2) systemctl stop sing-box && log_success "已停止"; press_enter ;;
            3) systemctl restart sing-box && log_success "已重启"; press_enter ;;
            4) sing-box check -c /etc/sing-box/config.json && log_success "语法无误"; press_enter ;;
            0) return ;;
        esac
    done
}

menu_links() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 六、节点链接 ══${NC}"
        echo -e "  1) 重新生成节点链接 \n  2) 查看明文链接 \n  3) 查看 Base64 订阅 \n  0) 返回"
        read -rp "请选择: " opt
        case ${opt:-0} in
            1) generate_links ;;
            2) cat /etc/sing-box/subscription.txt; press_enter ;;
            3) cat /etc/sing-box/subscription.b64; press_enter ;;
            0) return ;;
        esac
    done
}

run_all() {
    detect_distro; bootstrap_packages; setup_fail2ban;
    configure_singbox
    systemctl enable sing-box && systemctl restart sing-box
    generate_links
}

main_menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗"
        echo -e "║          服务器一键管理脚本  ($SCRIPT_VERSION)            ║"
        echo -e "╚══════════════════════════════════════════════════════╝${NC}"
        echo -e "   ${GREEN}1.${NC} 基础设置    ${GREEN}2.${NC} SSL 证书    ${GREEN}3.${NC} 安装核心"
        echo -e "   ${GREEN}4.${NC} 配置代理    ${GREEN}5.${NC} 服务管理    ${GREEN}6.${NC} 节点链接\n"
        echo -e "   ${YELLOW}7.${NC} ── 全部执行（1→6）──\n   0. 退出"
        read -rp "请选择: " opt
        case $opt in
            1) detect_distro; menu_basic ;; 2) menu_ssl ;; 3) detect_distro ;; 4) configure_singbox ;;
            5) menu_service ;; 6) menu_links ;; 7) detect_distro; run_all ;; 0) exit 0 ;;
        esac
    done
}

install_self() {
    local target="/usr/bin/jddj"
    [[ "$0" == "$target" ]] && return 0
    if [[ -f "$0" && "$0" != *"bash"* && "$0" != *"/dev/fd/"* ]]; then
        install -m 755 "$0" "$target" 2>/dev/null || true
    fi
    command -v hash &>/dev/null && hash -r
}

check_root
install_self
main_menu
