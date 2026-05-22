#!/usr/bin/env bash
#===============================================================================
# RHLinuxConfig — Universal Linux Setup & Hardening Wizard
# - System info, updates, tools, Node/Git/Python, opencode, claude-code
# - Telegram alerts, Wasabi backup, UFW + Fail2Ban + AbuseIPDB
# - Static IP, root password/disable, odin user creation
#===============================================================================
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[!]${NC}  $*"; }
err()   { echo -e "${RED}[✗]${NC}  $*"; }
info()  { echo -e "${CYAN}[i]${NC}  $*"; }
header(){ echo -e "\n${MAG}══ $* ══${NC}"; }
prompt(){
    local msg="$1"; shift
    read -rp "$(echo -e "${CYAN}→${NC}  $msg")" "$@" || true
}

# ── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { err "Must run as root."; exit 1; }

# ── Helper: generate random password ────────────────────────────────────────
gen_pass() {
    tr -dc 'A-Za-z0-9_!@#%^&*()' < /dev/urandom 2>/dev/null | head -c 20
    echo
}

# ── 1. System & Network Info ────────────────────────────────────────────────
show_info() {
    echo; header "System Information"
    info "Hostname     : $(hostname -f 2>/dev/null || hostname)"
    info "OS           : $(grep ^PRETTY /etc/os-release | cut -d= -f2 | tr -d '"')"
    info "Kernel       : $(uname -r)"
    info "Uptime       : $(uptime -p | sed 's/up //')"
    info "CPU          : $(lscpu | awk '/Model name/{$1=$2=$3=""; print $0}' | xargs)"
    info "Cores        : $(nproc)"
    info "Memory       : $(free -h | awk '/^Mem/{print $3"/"$2}')"
    info "Swap         : $(free -h | awk '/^Swap/{print $3"/"$2}')"
    info "Disk Total   : $(df -h / | awk 'NR==2{print $2}')"
    info "Disk Used    : $(df -h / | awk 'NR==2{print $3}')"
    header "Network Information"
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet/{print $2}' | cut -d/ -f1)
        mac=$(ip link show "$iface" | awk '/ether/{print $2}')
        gw=$(ip route | awk "/default via.*$iface/"'{print $3}')
        info "$iface : IP=$ip  MAC=$mac  GW=$gw"
    done
    info "Public IP    : $(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null || echo 'unknown')"
    info "DNS          : $(grep ^nameserver /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')"
    echo
}

# ── 2. Full Update & Upgrade ────────────────────────────────────────────────
do_update() {
    header "System Update"
    apt-get update -qq
    apt-get full-upgrade -y -qq
    apt-get autoremove -y -qq
    apt-get autoclean -qq
    log "System is up to date."
}

# ── 3. Install Base Tools ───────────────────────────────────────────────────
PACKAGES=(
    curl wget htop mc ncdu
    btop iftop iotop nethogs net-tools
    lm-sensors smartmontools
    sysstat dstat
    iperf3 mtr-tiny
    screen tmux
    unzip zip gpg
    jq tree
    software-properties-common apt-transport-https ca-certificates
    rsync build-essential netplan.io
)

do_install() {
    header "Installing Base Tools"
    local missing=()
    for pkg in "${PACKAGES[@]}"; do
        dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        log "All packages already installed."
    else
        apt-get install -y -qq "${missing[@]}"
        log "Packages installed."
    fi
    if [[ -f /etc/default/sysstat ]]; then
        sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
        systemctl enable --now sysstat 2>/dev/null || true
    fi
}

# ── 4. Install Latest Node.js, Git, Python ──────────────────────────────────
do_install_latest() {
    header "Installing Latest: Node.js, Git, Python"

    if ! command -v git &>/dev/null || [[ "$(git --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')" < "2.40" ]]; then
        info "Installing latest Git from PPA..."
        add-apt-repository -y ppa:git-core/ppa -u &>/dev/null || true
        apt-get install -y -qq git
        log "Git $(git --version 2>/dev/null) installed."
    else
        log "Git already up to date: $(git --version 2>/dev/null)"
    fi

    if ! command -v node &>/dev/null; then
        info "Installing latest Node.js LTS..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y -qq nodejs
        log "Node.js $(node --version) / npm $(npm --version) installed."
    else
        log "Node.js already installed: $(node --version)"
    fi

    local py_ver
    py_ver=$(python3 --version 2>/dev/null | grep -oP '\d+\.\d+')
    if [[ -z "$py_ver" || "$(echo "$py_ver" | cut -d. -f2)" -lt 12 ]]; then
        info "Installing latest Python from deadsnakes..."
        add-apt-repository -y ppa:deadsnakes/ppa -u &>/dev/null || true
        local latest_py
        latest_py=$(apt-cache search '^python3\.[0-9]+$' | sort -t. -k2 -rn | head -1 | awk '{print $1}')
        if [[ -n "$latest_py" ]]; then
            apt-get install -y -qq "$latest_py" python3-pip
            log "Python $("$latest_py" --version 2>/dev/null) installed as $latest_py"
            update-alternatives --install /usr/bin/python3 python3 "$(command -v "$latest_py")" 1 2>/dev/null || true
        fi
    else
        log "Python already up to date: $(python3 --version 2>/dev/null)"
    fi
}

# ── 5. Install opencode ─────────────────────────────────────────────────────
do_install_opencode() {
    header "Installing opencode"

    if command -v opencode &>/dev/null; then
        log "opencode already installed: $(opencode --version 2>/dev/null || echo 'present')"
        return
    fi

    if ! command -v npx &>/dev/null; then
        warn "npm/npx not found — skipping opencode."
        return
    fi

    info "Installing @opencode-ai/opencode globally via npm..."
    npm install -g @opencode-ai/opencode 2>&1 | tail -3 || {
        warn "opencode npm install failed — check network / npm permissions."
        return
    }
    log "opencode installed: $(opencode --version 2>/dev/null || echo 'ok')"

    # PATH config for all users
    cat > /etc/profile.d/opencode.sh <<'EOF'
if [[ ":$PATH:" != *":/usr/local/share/npm-global/bin:"* ]]; then
    export PATH="/usr/local/share/npm-global/bin:$PATH"
fi
if [[ ":$PATH:" != *":$HOME/.opencode/bin:"* ]]; then
    export PATH="$HOME/.opencode/bin:$PATH"
fi
EOF
    chmod +x /etc/profile.d/opencode.sh

    # Also add to root's bashrc
    if ! grep -q "opencode" /root/.bashrc 2>/dev/null; then
        echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> /root/.bashrc
    fi
    log "opencode PATH configured in /etc/profile.d/opencode.sh"
}

# ── 6. Install Claude Code ──────────────────────────────────────────────────
do_install_claude() {
    header "Installing Claude Code"

    if command -v claude &>/dev/null; then
        log "Claude Code already installed: $(claude --version 2>/dev/null || echo 'present')"
        return
    fi

    if ! command -v npx &>/dev/null; then
        warn "npm/npx not found — skipping Claude Code."
        return
    fi

    info "Installing @anthropic-ai/claude-code globally via npm..."
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -3 || {
        warn "Claude Code npm install failed — check network / npm permissions."
        return
    }

    # Verify installation
    if command -v claude &>/dev/null; then
        log "Claude Code installed: $(claude --version 2>/dev/null || echo 'ok')"
    else
        warn "claude binary not found after install; trying npx-based setup..."
        npx @anthropic-ai/claude-code --version 2>/dev/null && {
            log "Claude Code available via npx."
        } || warn "Claude Code not available."
    fi

    # PATH config
    cat > /etc/profile.d/claude-code.sh <<'EOF'
if [[ ":$PATH:" != *":$HOME/.claude/bin:"* ]]; then
    export PATH="$HOME/.claude/bin:$PATH"
fi
EOF
    chmod +x /etc/profile.d/claude-code.sh

    if ! grep -q "claude" /root/.bashrc 2>/dev/null; then
        echo 'export PATH="$HOME/.claude/bin:$PATH"' >> /root/.bashrc
    fi
    log "Claude Code PATH configured."
}

# ── 7. WIZARD: Static IP ───────────────────────────────────────────────────
wizard_static_ip() {
    header "Network Configuration (DHCP → Static IP)"
    local iface current_ip current_gw dns
    iface=$(ip route | awk '/default/{print $5; exit}')
    current_ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet/{print $2}' | cut -d/ -f1)
    current_gw=$(ip route | awk "/default via.*$iface/"'{print $3}')

    echo "Current interface: $iface  IP: ${current_ip:-DHCP}  GW: ${current_gw:-unknown}"
    echo
    local ans
    prompt "Switch to static IP? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy] ]] && { log "Keeping DHCP."; return; }

    local static_ip netmask gateway dns1 dns2
    prompt "IP Address       [${current_ip:-192.168.1.100}]: " static_ip
    static_ip="${static_ip:-${current_ip:-192.168.1.100}}"
    prompt "Netmask (CIDR)   [24]: " netmask
    netmask="${netmask:-24}"
    prompt "Gateway          [${current_gw:-192.168.1.1}]: " gateway
    gateway="${gateway:-${current_gw:-192.168.1.1}}"
    prompt "DNS Primary      [1.1.1.1]: " dns1
    dns1="${dns1:-1.1.1.1}"
    prompt "DNS Secondary    [1.0.0.1]: " dns2
    dns2="${dns2:-1.0.0.1}"

    # Detect netplan vs interfaces
    if ls /etc/netplan/*.yaml &>/dev/null 2>&1; then
        local np_file
        np_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
        cat > "$np_file" <<NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    $iface:
      dhcp4: false
      addresses:
        - ${static_ip}/${netmask}
      gateway4: $gateway
      nameservers:
        addresses: [$dns1, $dns2]
NETPLAN
        netplan apply 2>/dev/null || {
            warn "netplan apply failed — manual review needed at $np_file"
        }
        log "Static IP configured via netplan."
    elif [[ -f /etc/network/interfaces ]]; then
        cat > /etc/network/interfaces <<IFACES
auto lo
iface lo inet loopback

auto $iface
iface $iface inet static
    address $static_ip
    netmask $(python3 -c "import socket,struct; print(socket.inet_ntoa(struct.pack('!I', (0xffffffff << (32-$netmask)) & 0xffffffff)))" 2>/dev/null || echo "255.255.255.0")
    gateway $gateway
    dns-nameservers $dns1 $dns2
IFACES
        if systemctl is-active networking &>/dev/null; then
            systemctl restart networking 2>/dev/null || true
        fi
        log "Static IP configured via /etc/network/interfaces."
    else
        warn "No netplan or interfaces file found — configure IP manually."
    fi
}

# ── 8. WIZARD: Root password + disable root ────────────────────────────────
wizard_root() {
    header "Root Account Configuration"
    echo "Current root status: $(passwd -S root 2>/dev/null | awk '{print $2}' | sed 's/L/locked/; s/P/password set/; s/N/no password/')"

    local ans root_pass
    prompt "Change root password? [Y/n]: " ans
    if [[ "${ans:-y}" =~ ^[Yy] ]]; then
        while true; do
            root_pass=$(gen_pass)
            echo "Generated root password: ${RED}$root_pass${NC}"
            prompt "Accept this password? [Y/n]: " ans
            [[ "${ans:-y}" =~ ^[Yy] ]] && break
        done
        echo "root:$root_pass" | chpasswd
        log "Root password updated."
    fi

    echo
    prompt "Disable root SSH login (PermitRootLogin no)? [Y/n]: " ans
    if [[ "${ans:-y}" =~ ^[Yy] ]]; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        grep -q '^PermitRootLogin' /etc/ssh/sshd_config || \
            echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
        systemctl restart sshd || systemctl restart ssh 2>/dev/null || true
        log "Root SSH login disabled."
    fi
}

# ── 9. WIZARD: Create odin user ────────────────────────────────────────────
wizard_odin_user() {
    header "User Setup: odin"
    local odin_pass

    if id odin &>/dev/null; then
        warn "User 'odin' already exists."
        prompt "Reset odin password? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy] ]]; then
            odin_pass=$(gen_pass)
            echo "odin:$odin_pass" | chpasswd
            log "odin password reset."
            echo
            log "══════════════════════════════════════════════"
            log "  ${GREEN}odin${NC} user password: ${RED}$odin_pass${NC}"
            log "══════════════════════════════════════════════"
        fi
        return
    fi

    info "Creating user 'odin' with root privileges..."
    odin_pass=$(gen_pass)

    useradd -m -s /bin/bash -G sudo,adm odin 2>/dev/null || \
        useradd -m -s /bin/bash odin && usermod -aG sudo,adm odin

    echo "odin:$odin_pass" | chpasswd

    # Passwordless sudo for odin
    echo "odin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/odin
    chmod 440 /etc/sudoers.d/odin

    # Copy SSH authorized_keys if root has any
    if [[ -f /root/.ssh/authorized_keys ]]; then
        mkdir -p /home/odin/.ssh
        cp /root/.ssh/authorized_keys /home/odin/.ssh/
        chown -R odin:odin /home/odin/.ssh
        chmod 700 /home/odin/.ssh
        chmod 600 /home/odin/.ssh/authorized_keys
        log "Root SSH keys copied to odin."
    fi

    log "User 'odin' created with sudo (NOPASSWD) access."

    echo
    log "══════════════════════════════════════════════════"
    log "  ${GREEN}Username${NC}: odin"
    log "  ${GREEN}Password${NC}: ${RED}$odin_pass${NC}"
    log "  ${GREEN}Groups ${NC}: sudo, adm"
    log "  ${GREEN}SSH   ${NC}: keys copied from root if present"
    log "══════════════════════════════════════════════════"
    echo
}

# ── 10. Telegram Integration (Wizard) ─────────────────────────────────────
setup_telegram() {
    header "Telegram Bot Integration"
    echo "Send server notifications to your phone via Telegram."
    echo "You need:"
    echo "  1. A Bot Token from @BotFather (https://t.me/BotFather)"
    echo "     → Create a bot with /newbot, copy the API token"
    echo "  2. A Chat ID (your user or group ID)"
    echo "     → Message your bot, then visit:"
    echo "       https://api.telegram.org/bot<TOKEN>/getUpdates"
    echo

    local ans
    prompt "Set up Telegram notifications? [Y/n]: " ans
    [[ ! "${ans:-y}" =~ ^[Yy] ]] && { log "Skipping Telegram."; return; }

    local tg_token tg_chat script
    while true; do
        prompt "Telegram Bot Token (e.g. 123456:ABC-DEF...): " tg_token
        [[ -n "$tg_token" ]] && break
        warn "Token cannot be empty."
    done
    while true; do
        prompt "Telegram Chat ID (numeric, e.g. 123456789): " tg_chat
        [[ -n "$tg_chat" ]] && break
        warn "Chat ID cannot be empty."
    done

    # Verify token works
    info "Testing Telegram connection..."
    local test_ok
    test_ok=$(curl -s "https://api.telegram.org/bot${tg_token}/getMe" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ok',''))" 2>/dev/null || echo "")
    if [[ "$test_ok" != "True" ]]; then
        warn "Bot token seems invalid (getMe failed). Check and re-enter."
        prompt "Continue anyway? [y/N]: " ans
        [[ ! "$ans" =~ ^[Yy] ]] && { warn "Skipping Telegram."; return; }
    fi

    script="/usr/local/bin/telegram-notify"
    cat > "$script" <<'SCRIPT'
#!/usr/bin/env bash
TOKEN="__TG_TOKEN__"
CHAT="__TG_CHAT__"
LEVEL="${1:-info}"
shift 2>/dev/null || true
MSG="${*:-$(cat)}"
[[ -z "$MSG" ]] && exit 0
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d chat_id="${CHAT}" \
    -d parse_mode="Markdown" \
    -d text="*${HOSTNAME}* [${LEVEL}]%0A\`$(date '+%Y-%m-%d %H:%M:%S')\`%0A${MSG}" \
    -o /dev/null
SCRIPT
    sed -i "s|__TG_TOKEN__|$tg_token|; s|__TG_CHAT__|$tg_chat|" "$script"
    chmod +x "$script"

    # Send a test message
    telegram-notify info "Telegram notifications configured successfully on $(hostname)" || \
        warn "Test message failed — check CHAT_ID."

    log "telegram-notify installed at $script"
    echo "  Usage: telegram-notify info \"Server is running\""
    echo "         telegram-notify alert \"CPU > 90%\""
}

# ── 11. Wasabi (S3) Integration (Wizard) ───────────────────────────────────
setup_wasabi() {
    header "Wasabi (S3) Cloud Backup Setup"
    echo "Wasabi is S3-compatible hot cloud storage for backups."
    echo "You need:"
    echo "  1. A Wasabi account (https://wasabi.com)"
    echo "  2. An Access Key & Secret Key (created in Wasabi Console)"
    echo "  3. A pre-created bucket for your backups"
    echo

    local ans
    prompt "Set up Wasabi S3 backup? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy] ]] && { log "Skipping Wasabi."; return; }

    local wasabi_key wasabi_secret wasabi_bucket wasabi_region
    while true; do
        prompt "Wasabi Access Key      : " wasabi_key
        [[ -n "$wasabi_key" ]] && break
        warn "Access Key cannot be empty."
    done
    while true; do
        prompt "Wasabi Secret Key      : " wasabi_secret
        [[ -n "$wasabi_secret" ]] && break
        warn "Secret Key cannot be empty."
    done
    while true; do
        prompt "Wasabi Bucket Name     : " wasabi_bucket
        [[ -n "$wasabi_bucket" ]] && break
        warn "Bucket name cannot be empty."
    done
    prompt "Wasabi Region [us-east-1]: " wasabi_region
    wasabi_region="${wasabi_region:-us-east-1}"

    echo
    info "Wasabi endpoint: https://s3.${wasabi_region}.wasabisys.com"
    echo

    if ! command -v aws &>/dev/null; then
        info "Installing AWS CLI..."
        apt-get install -y -qq awscli 2>/dev/null || {
            curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
            unzip -qq /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
        }
    fi

    mkdir -p /root/.aws
    cat > /root/.aws/config <<EOF
[default]
region = $wasabi_region
output = json
EOF
    cat > /root/.aws/credentials <<EOF
[default]
aws_access_key_id = $wasabi_key
aws_secret_access_key = $wasabi_secret
EOF
    chmod 600 /root/.aws/credentials

    # Export for use in helper scripts
    cat > /etc/profile.d/wasabi.sh <<EOF
export WASABI_BUCKET=$wasabi_bucket
export WASABI_REGION=$wasabi_region
EOF
    chmod +x /etc/profile.d/wasabi.sh

    # Test connection
    if aws s3 --endpoint-url "https://s3.${wasabi_region}.wasabisys.com" ls "s3://${wasabi_bucket}" &>/dev/null; then
        log "Wasabi connection OK — bucket '$wasabi_bucket' is accessible."
    else
        warn "Could not list bucket '$wasabi_bucket'. Check:"
        warn "  - Credentials are correct"
        warn "  - Bucket exists in region '$wasabi_region'"
        prompt "Continue anyway? [y/N]: " ans
        [[ ! "$ans" =~ ^[Yy] ]] && { warn "Skipping Wasabi."; return; }
    fi

    # Timestamped backup helper
    cat > /usr/local/bin/wasabi-backup <<'BACKUP'
#!/usr/bin/env bash
# Usage: wasabi-backup <source_path> [remote_prefix]
# Backs up a directory to Wasabi with timestamp
set -euo pipefail
SRC="$1"
PREFIX="${2:-backup}"
[[ -z "$SRC" ]] && { echo "Usage: wasabi-backup <source> [prefix]"; exit 1; }
[[ ! -d "$SRC" && ! -f "$SRC" ]] && { echo "Error: $SRC not found"; exit 1; }
BASENAME="$(basename "$SRC")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DEST="s3://${WASABI_BUCKET}/${PREFIX}/${BASENAME}-${TIMESTAMP}"
echo "Backing up $SRC → $DEST"
aws s3 --endpoint-url "https://s3.${WASABI_REGION}.wasabisys.com" \
    cp --recursive "$SRC" "$DEST"
echo "Done: $DEST"
BACKUP
    chmod +x /usr/local/bin/wasabi-backup
    log "wasabi-backup helper installed."
    echo "  Usage: wasabi-backup /path/to/data [prefix]"
}

# ── 12. Wasabi Auto-Backup (cron) ───────────────────────────────────────────
setup_wasabi_autobackup() {
    header "Automated Backups to Wasabi"

    if ! command -v aws &>/dev/null || [[ ! -f /root/.aws/credentials ]]; then
        warn "Wasabi not configured. Run Wasabi setup first."
        return
    fi

    local ans
    prompt "Set up daily auto-backup of /home + system configs to Wasabi? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy] ]] && { log "Skipping auto-backup."; return; }

    # Source Wasabi env vars
    [[ -f /etc/profile.d/wasabi.sh ]] && source /etc/profile.d/wasabi.sh
    local bucket="${WASABI_BUCKET:-backup}"
    local region="${WASABI_REGION:-us-east-1}"

    local backup_script="/usr/local/bin/wasabi-autobackup"
    cat > "$backup_script" <<'AUTOBACKUP'
#!/usr/bin/env bash
#===============================================================================
# Wasabi Auto-Backup — runs daily via cron
# Backs up: /home, /etc, /var/log, /var/www, /root
# Uses aws s3 sync for efficient incremental backups
#===============================================================================
set -euo pipefail

BUCKET="${WASABI_BUCKET:?WASABI_BUCKET not set}"
REGION="${WASABI_REGION:?WASABI_REGION not set}"
ENDPOINT="https://s3.${REGION}.wasabisys.com"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/var/log/wasabi-backup.log"

echo "===== Wasabi Auto-Backup $TIMESTAMP =====" | tee -a "$LOG"

# Rotate log
if [[ -f "$LOG" && $(stat -c%s "$LOG") -gt 10485760 ]]; then
    mv "$LOG" "${LOG}.old"
fi

aws_base() {
    aws s3 --endpoint-url "$ENDPOINT" "$@"
}

# Backup targets: <source> <s3_prefix>
backup_dir() {
    local src="$1"
    local prefix="$2"
    local name
    name=$(basename "$src")
    local dest="s3://${BUCKET}/system/${prefix}/${name}"
    echo "[$(date '+%H:%M:%S')] Syncing $src → $dest" | tee -a "$LOG"
    aws_base sync "$src" "$dest" --delete 2>&1 | tee -a "$LOG" | tail -3
}

backup_dir /home         home
backup_dir /etc          config
backup_dir /root         root
backup_dir /var/log      logs
backup_dir /var/www      www

echo "===== Complete =====" | tee -a "$LOG"
echo
AUTOBACKUP
    chmod +x "$backup_script"
    log "Auto-backup script created at $backup_script"

    # Install daily cron job
    cat > /etc/cron.daily/wasabi-autobackup <<'CRON'
#!/bin/bash
source /etc/profile.d/wasabi.sh 2>/dev/null || true
exec /usr/local/bin/wasabi-autobackup
CRON
    chmod +x /etc/cron.daily/wasabi-autobackup
    log "Daily cron job installed at /etc/cron.daily/wasabi-autobackup"

    echo
    echo "  What gets backed up:"
    echo "    /home       → s3://${bucket}/system/home/"
    echo "    /etc        → s3://${bucket}/system/config/"
    echo "    /root       → s3://${bucket}/system/root/"
    echo "    /var/log    → s3://${bucket}/system/logs/"
    echo "    /var/www    → s3://${bucket}/system/www/"
    echo "  Runs daily at 6:25 AM (via /etc/cron.daily)"
    echo

    # Ask for a test run
    prompt "Run a test backup now? [Y/n]: " ans
    if [[ "${ans:-y}" =~ ^[Yy] ]]; then
        info "Running test backup..."
        "$backup_script" || warn "Test backup completed with errors (check /var/log/wasabi-backup.log)."
        log "Test backup finished."
    fi
}

# ── 13. UFW + Fail2Ban + AbuseIPDB ─────────────────────────────────────────
setup_firewall() {
    header "UFW Firewall Setup"
    ufw --force reset 2>/dev/null || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    for port in "80/tcp" "443/tcp"; do
        local ans
        prompt "Allow $port? [y/N]: " ans
        [[ "$ans" =~ ^[Yy] ]] && ufw allow "$port"
    done
    ufw --force enable
    ufw status verbose
    log "UFW configured."
}

setup_fail2ban() {
    header "Fail2Ban + AbuseIPDB Setup"
    if ! command -v fail2ban-server &>/dev/null; then
        apt-get install -y -qq fail2ban
    fi

    local abuse_key
    prompt "AbuseIPDB API Key (leave blank to skip): " abuse_key

    mkdir -p /etc/fail2ban/action.d

    if [[ -n "$abuse_key" ]]; then
        local abuse_url="https://raw.githubusercontent.com/abuseipdb/abuseipdb-fail2ban/master/action.d/abuseipdb.conf"
        if curl -sfL "$abuse_url" -o /etc/fail2ban/action.d/abuseipdb.conf; then
            sed -i "s/abuseipdb_apikey =.*/abuseipdb_apikey = $abuse_key/" /etc/fail2ban/action.d/abuseipdb.conf 2>/dev/null || true
            log "AbuseIPDB action installed."
        else
            warn "Could not fetch AbuseIPDB action; skipping."
        fi
    fi

    cat > /etc/fail2ban/jail.local <<'JAIL'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5
banaction = ufw
action = %(action_)s
destemail = root@localhost
sender = root@localhost
mta = sendmail

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 86400

[sshd-ddos]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 2
findtime = 60
bantime = 3600

[ufw]
enabled = true
logpath = /var/log/ufw.log
maxretry = 5
bantime = 3600
JAIL

    if [[ -n "${abuse_key:-}" ]]; then
        cat >> /etc/fail2ban/jail.local <<'JAIL_ABUSE'

[abuseipdb]
enabled = true
action = abuseipdb
JAIL_ABUSE
    fi

    systemctl enable --now fail2ban
    log "Fail2Ban configured."
}

# ── Post-install notification ───────────────────────────────────────────────
post_notify() {
    if command -v telegram-notify &>/dev/null; then
        telegram-notify info "Setup complete on $(hostname)"
    fi
}

# ── Final summary ───────────────────────────────────────────────────────────
show_summary() {
    echo
    header "Setup Complete"
    info "Hostname     : $(hostname -f 2>/dev/null || hostname)"
    info "Public IP    : $(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null || echo 'unknown')"
    info "Local IP     : $(ip -4 addr show | awk '/inet/{print $2}' | grep -v 127.0.0.1 | cut -d/ -f1 | head -1)"
    echo
    info "Installed: curl wget htop mc ncdu btop iftop iotop nethogs sysstat dstat"
    info "          iperf3 smartmontools screen tmux jq rsync git nodejs python3"
    info "          opencode claude-code ufw fail2ban"
    echo
    log "Reboot recommended to apply all updates."
    echo
}

# ═══════════════════════════ M A I N ═════════════════════════════════════════

echo -e "${CYAN}"
cat << "EOF"
    ____  __    _     __     _     __
   / _ \/ /   / /    / /    (_)___/ /__  ___
  / , _/ /__ / _ \  / _ \  / / __/ / _ \/ _ \
 /_/|_/____//_.__/ /_.__/ /_/\__/_/\___/ .__/
                                       /_/
EOF
echo -e "${NC}"
echo "  RHLinuxConfig — Universal Linux Setup & Hardening Wizard"
echo "  $(date)"
echo

show_info

# ── Wizard mode (default) ────────────────────────────────────────────────────
if [[ $# -eq 1 && "$1" == "--quick" ]]; then
    header "QUICK MODE"
    do_update
    do_install
    do_install_latest
    log "Quick mode done. Run without --quick for full wizard."
    exit 0
fi

if [[ $# -eq 1 && "$1" == "--unattended" ]]; then
    header "UNATTENDED MODE"
    do_update
    do_install
    do_install_latest
    do_install_opencode
    do_install_claude
    setup_firewall
    setup_fail2ban
    show_summary
    exit 0
fi

# ── Wizard: Interactive Setup ────────────────────────────────────────────────
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Welcome to the RHLinuxConfig Setup Wizard!              ${NC}"
echo -e "${YELLOW}  You will be guided through all configuration steps.     ${NC}"
echo -e "${YELLOW}  Press Enter to accept defaults shown in [brackets].     ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo

do_update
do_install
do_install_latest
do_install_opencode
do_install_claude

wizard_static_ip
wizard_root
wizard_odin_user
setup_telegram
setup_wasabi
setup_wasabi_autobackup
setup_firewall
setup_fail2ban
post_notify
show_summary
