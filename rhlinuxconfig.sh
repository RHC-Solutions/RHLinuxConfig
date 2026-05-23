#!/usr/bin/env bash
#===============================================================================
# RHLinuxConfig — Universal Linux Setup & Hardening Wizard
# Supports: AlmaLinux, Rocky, CentOS, Debian, Ubuntu, Arch, Mint
# - System info, updates, tools, Node/Git/Python, opencode, claude-code
# - Telegram alerts, Wasabi backup, UFW/Firewalld + Fail2Ban + AbuseIPDB
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

# ═════════════════════════════════════════════════════════════════════════════
# DISTRO DETECTION
# ═════════════════════════════════════════════════════════════════════════════
detect_distro() {
    [[ -f /etc/os-release ]] && . /etc/os-release || { err "Cannot detect OS."; exit 1; }
    OS_ID="${ID,,}"
    OS_VERSION_ID="${VERSION_ID:-0}"
    OS_FAMILY=""

    case "$OS_ID" in
        ubuntu|debian|mint|linuxmint)
            OS_FAMILY="debian" ;;
        almalinux|rocky|centos|rhel|ol|fedora)
            OS_FAMILY="rhel" ;;
        arch|manjaro|endeavouros|garuda)
            OS_FAMILY="arch" ;;
        opensuse*|suse)
            OS_FAMILY="suse" ;;
        *)
            # Try fallback via ID_LIKE
            case "${ID_LIKE,,}" in
                *debian*) OS_FAMILY="debian"; OS_ID="$OS_ID (deb-based)" ;;
                *rhel*|*fedora*) OS_FAMILY="rhel"; OS_ID="$OS_ID (rpm-based)" ;;
                *arch*) OS_FAMILY="arch"; OS_ID="$OS_ID (arch-based)" ;;
                *) err "Unsupported OS: $OS_ID (ID_LIKE=$ID_LIKE)"; exit 1 ;;
            esac ;;
    esac

    case "$OS_FAMILY" in
        debian)
            PKG_MGR="apt"
            PKG_INSTALL="apt-get install -y -qq"
            PKG_INSTALL_NQ="apt-get install -y"    # non-quiet for interactive
            PKG_UPDATE="apt-get update -qq"
            PKG_UPGRADE="apt-get full-upgrade -y -qq"
            PKG_AUTOREMOVE="apt-get autoremove -y -qq; apt-get autoclean -qq"
            PKG_CHECK="dpkg -s"
            PKG_SEARCH="apt-cache search"
            PKG_REPO_ADD="add-apt-repository -y"
            NETPLAN_BIN="netplan"
            FW_TOOL="ufw"
            FIREWALL_PKG="ufw"
            SENSORS_PKG="lm-sensors"
            DEV_GROUP="sudo"
            ;;
        rhel)
            PKG_MGR="dnf"
            PKG_INSTALL="dnf install -y -q"
            PKG_INSTALL_NQ="dnf install -y"
            PKG_UPDATE="dnf check-update -q || true"
            PKG_UPGRADE="dnf upgrade -y -q"
            PKG_AUTOREMOVE="dnf autoremove -y -q"
            PKG_CHECK="rpm -q"
            PKG_SEARCH="dnf search"
            # EPEL first
            PKG_REPO_ADD="dnf config-manager --set-enabled"
            NETPLAN_BIN=""
            FIREWALL_PKG="firewalld"
            FW_TOOL="firewalld"
            SENSORS_PKG="lm_sensors"
            DEV_GROUP="wheel"
            ;;
        arch)
            PKG_MGR="pacman"
            PKG_INSTALL="pacman -S --noconfirm --needed"
            PKG_INSTALL_NQ="pacman -S --noconfirm"
            PKG_UPDATE="pacman -Sy"
            PKG_UPGRADE="pacman -Syu --noconfirm"
            PKG_AUTOREMOVE="pacman -Rns --noconfirm \$(pacman -Qdtq 2>/dev/null) 2>/dev/null || true"
            PKG_CHECK="pacman -Q"
            PKG_SEARCH="pacman -Ss"
            PKG_REPO_ADD=""
            NETPLAN_BIN=""
            FW_TOOL="ufw"
            FIREWALL_PKG="ufw"
            SENSORS_PKG="lm_sensors"
            DEV_GROUP="wheel"
            ;;
        suse)
            PKG_MGR="zypper"
            PKG_INSTALL="zypper install -y"
            PKG_INSTALL_NQ="zypper install -y"
            PKG_UPDATE="zypper refresh"
            PKG_UPGRADE="zypper update -y"
            PKG_AUTOREMOVE="zypper rm -u"
            PKG_CHECK="rpm -q"
            PKG_SEARCH="zypper search"
            PKG_REPO_ADD="zypper addrepo"
            NETPLAN_BIN=""
            FW_TOOL="firewalld"
            FIREWALL_PKG="firewalld"
            SENSORS_PKG="lm_sensors"
            DEV_GROUP="wheel"
            ;;
    esac

    # Arch doesn't use version codenames
    OS_CODENAME="${VERSION_CODENAME:-}"
    ARCH=$(uname -m)

    header "Detected System"
    info "Distribution : $OS_ID $OS_VERSION_ID ($OS_FAMILY family)"
    info "Architecture : $ARCH"
    info "Package mgr  : $PKG_MGR"
    echo
}

# ── Distro-specific package maps ────────────────────────────────────────────
PACKAGES_CORE="curl wget htop mc ncdu btop iftop iotop nethogs net-tools smartmontools sysstat dstat iperf3 mtr-tiny screen tmux unzip zip gpg jq tree rsync"

# Packages that differ by family (set after detect_distro)
PACKAGES_EXTRA=""
enable_epel() {
    [[ "$OS_FAMILY" != "rhel" ]] && return
    # Enable EPEL if not already
    if ! rpm -q epel-release &>/dev/null; then
        if [[ "$OS_ID" == "almalinux" ]]; then
            $PKG_INSTALL almalinux-release-epel 2>/dev/null || true
        elif [[ "$OS_ID" == "rocky" ]]; then
            $PKG_INSTALL epel-release 2>/dev/null || true
        elif [[ "$OS_ID" == "centos" ]]; then
            $PKG_INSTALL epel-release 2>/dev/null || true
        else
            $PKG_INSTALL epel-release 2>/dev/null || true
        fi
    fi
    # Enable CRB / PowerTools for additional packages
    dnf config-manager --set-enabled crb 2>/dev/null || \
        dnf config-manager --set-enabled powertools 2>/dev/null || true
}

resolve_pkg_list() {
    local pkgs="$PACKAGES_CORE"
    case "$OS_FAMILY" in
        debian)
            pkgs="$pkgs software-properties-common apt-transport-https ca-certificates build-essential"
            # netplan only on Ubuntu
            [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]] && pkgs="$pkgs netplan.io"
            pkgs="$pkgs $SENSORS_PKG $FIREWALL_PKG fail2ban"
            ;;
        rhel)
            enable_epel
            pkgs="$pkgs ca-certificates gcc gcc-c++ make epel-release"
            # NetworkManager ifcfg on older RHEL
            pkgs="$pkgs $SENSORS_PKG fail2ban"
            # firewalld is usually preinstalled
            rpm -q firewalld &>/dev/null || pkgs="$pkgs firewalld"
            # Add dnf-utils for config-manager
            pkgs="$pkgs dnf-plugins-core"
            # iftop/iotop/nethogs need epel
            ;;
        arch)
            pkgs="$pkgs ca-certificates base-devel $SENSORS_PKG $FIREWALL_PKG fail2ban"
            # mtr-tiny is just mtr on arch
            pkgs="${pkgs/mtr-tiny/mtr}"
            ;;
        suse)
            pkgs="$pkgs ca-certificates patterns-devel-base-devel $SENSORS_PKG $FIREWALL_PKG fail2ban"
            pkgs="${pkgs/mtr-tiny/mtr}"
            ;;
    esac
    PACKAGES_EXTRA="$pkgs"
}

# ═════════════════════════════════════════════════════════════════════════════
# DISTRO-ADAPTED FUNCTIONS
# ═════════════════════════════════════════════════════════════════════════════

# ── Helper: generate random password ────────────────────────────────────────
gen_pass() {
    tr -dc 'A-Za-z0-9_!@#%^&*()' < /dev/urandom 2>/dev/null | head -c 20
    echo
}

# ── 0. Auto-set Location, Timezone, Date/Time (via ipinfo.io) ───────────────
auto_set_location() {
    header "Auto-Configure Location & Time (ipinfo.io)"

    # Ensure curl + jq exist (jq optional, fallback to python3)
    if ! command -v curl &>/dev/null; then
        info "Installing curl..."
        pkg_install curl || $PKG_INSTALL curl 2>/dev/null || true
    fi

    local geo public_ip city region country tz loc
    info "Querying ipinfo.io for geolocation..."
    geo=$(curl -fsS --max-time 8 "https://ipinfo.io/json" 2>/dev/null || echo "")
    if [[ -z "$geo" ]]; then
        warn "ipinfo.io unreachable — skipping auto-location."
        return
    fi

    # Parse field — prefer jq, then python3, then sed fallback
    parse_json() {
        local key="$1"
        if command -v jq &>/dev/null; then
            printf '%s' "$geo" | jq -r ".${key} // empty" 2>/dev/null
        elif command -v python3 &>/dev/null; then
            printf '%s' "$geo" | python3 -c "import sys,json
try:
    print(json.load(sys.stdin).get('$key',''))
except Exception:
    pass" 2>/dev/null
        else
            printf '%s' "$geo" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
        fi
    }
    public_ip=$(parse_json ip)
    city=$(parse_json city)
    region=$(parse_json region)
    country=$(parse_json country)
    tz=$(parse_json timezone)
    loc=$(parse_json loc)

    info "Public IP    : ${public_ip:-unknown}"
    info "Location     : ${city:-?}, ${region:-?}, ${country:-?}"
    info "Coordinates  : ${loc:-?}"
    info "Timezone     : ${tz:-?}"

    # ── Set timezone ────────────────────────────────────────────────────────
    if [[ -n "$tz" ]]; then
        if command -v timedatectl &>/dev/null; then
            if timedatectl set-timezone "$tz" 2>/dev/null; then
                log "Timezone set to $tz via timedatectl."
            else
                warn "timedatectl could not set $tz — installing tzdata."
                pkg_install tzdata 2>/dev/null || true
                timedatectl set-timezone "$tz" 2>/dev/null || \
                    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
                echo "$tz" > /etc/timezone 2>/dev/null || true
                log "Timezone set to $tz (fallback)."
            fi
        else
            ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
            echo "$tz" > /etc/timezone 2>/dev/null || true
            log "Timezone set to $tz via symlink."
        fi
    else
        warn "No timezone from ipinfo — keeping current."
    fi

    # ── Enable NTP / time sync ──────────────────────────────────────────────
    info "Enabling NTP time synchronization..."
    if command -v timedatectl &>/dev/null; then
        timedatectl set-ntp true 2>/dev/null || true
    fi

    # Install + start chrony (preferred) or systemd-timesyncd
    if ! systemctl is-active --quiet chrony 2>/dev/null && \
       ! systemctl is-active --quiet chronyd 2>/dev/null && \
       ! systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        case "$OS_FAMILY" in
            debian) pkg_install chrony 2>/dev/null || pkg_install systemd-timesyncd ;;
            rhel)   pkg_install chrony 2>/dev/null || true ;;
            arch)   pkg_install chrony 2>/dev/null || true ;;
            suse)   pkg_install chrony 2>/dev/null || true ;;
        esac
        systemctl enable --now chronyd 2>/dev/null || \
            systemctl enable --now chrony 2>/dev/null || \
            systemctl enable --now systemd-timesyncd 2>/dev/null || true
    fi

    # Force an immediate sync
    if command -v chronyc &>/dev/null; then
        chronyc -a makestep &>/dev/null || true
    elif command -v ntpdate &>/dev/null; then
        ntpdate -u pool.ntp.org &>/dev/null || true
    fi

    info "Current date : $(date '+%Y-%m-%d %H:%M:%S %Z')"

    # Export for downstream use (cloudflare/telegram messages etc.)
    export DETECTED_TZ="$tz"
    export DETECTED_CITY="$city"
    export DETECTED_COUNTRY="$country"
    export DETECTED_PUBLIC_IP="$public_ip"

    log "Location & time configured automatically."
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
    info "Using $PKG_MGR — updating package lists..."
    eval "$PKG_UPDATE"
    info "Upgrading packages..."
    eval "$PKG_UPGRADE"
    eval "$PKG_AUTOREMOVE" 2>/dev/null || true
    log "System is up to date."
}

# ── 3. Install Base Tools ───────────────────────────────────────────────────
pkg_install() {
    local pkgs=("$@")
    case "$OS_FAMILY" in
        debian)
            local missing=()
            for pkg in "${pkgs[@]}"; do
                $PKG_CHECK "$pkg" &>/dev/null || missing+=("$pkg")
            done
            [[ ${#missing[@]} -eq 0 ]] && return 0
            $PKG_INSTALL "${missing[@]}" ;;
        rhel)
            local missing=()
            for pkg in "${pkgs[@]}"; do
                $PKG_CHECK "$pkg" &>/dev/null 2>&1 || missing+=("$pkg")
            done
            [[ ${#missing[@]} -eq 0 ]] && return 0
            $PKG_INSTALL "${missing[@]}" 2>&1 | tail -3 || true
            # Retry once for EPEL packages that might need enabling
            local retry=()
            for pkg in "${missing[@]}"; do
                $PKG_CHECK "$pkg" &>/dev/null 2>&1 || retry+=("$pkg")
            done
            [[ ${#retry[@]} -gt 0 ]] && $PKG_INSTALL "${retry[@]}" 2>&1 | tail -3 || true
            ;;
        arch)
            $PKG_INSTALL "${pkgs[@]}" 2>&1 | tail -3 || true ;;
        suse)
            $PKG_INSTALL "${pkgs[@]}" 2>&1 | tail -3 || true ;;
    esac
}

do_install() {
    header "Installing Base Tools"
    resolve_pkg_list
    info "Packages: $PACKAGES_EXTRA"
    # shellcheck disable=SC2086
    pkg_install $PACKAGES_EXTRA
    log "Base tools installed."

    # Enable sysstat collection
    if [[ -f /etc/default/sysstat ]]; then
        sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true
        systemctl enable --now sysstat 2>/dev/null || true
    fi
    # RHEL: sysstat may use different config
    if [[ -f /etc/sysconfig/sysstat ]]; then
        systemctl enable --now sysstat 2>/dev/null || true
    fi
}

# ── 4. Install Latest Node.js, Git, Python ──────────────────────────────────
do_install_latest() {
    header "Installing Latest: Node.js, Git, Python"

    # Git — latest via package manager or PPA
    if ! command -v git &>/dev/null; then
        pkg_install git
        log "Git $(git --version 2>/dev/null) installed."
    elif [[ "$OS_FAMILY" == "debian" ]]; then
        local git_ver
        git_ver=$(git --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        if [[ -n "$git_ver" && $(echo "$git_ver" | cut -d. -f1) -lt 2 ]]; then
            info "Upgrading Git via PPA..."
            add-apt-repository -y ppa:git-core/ppa -u &>/dev/null || true
            $PKG_INSTALL git
            log "Git $(git --version 2>/dev/null) installed."
        fi
    fi

    # Node.js — latest LTS via NodeSource (works on all major distros)
    if ! command -v node &>/dev/null; then
        info "Installing latest Node.js LTS via NodeSource..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - 2>/dev/null || \
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - 2>/dev/null || {
            warn "NodeSource setup failed — trying distro package."
            pkg_install nodejs || true
        }
        case "$OS_FAMILY" in
            debian) $PKG_INSTALL nodejs 2>&1 | tail -1 ;;
            rhel)   $PKG_INSTALL nodejs 2>&1 | tail -1 ;;
            arch)   pkg_install nodejs npm ;;
            suse)   $PKG_INSTALL nodejs npm ;;
        esac
        command -v node &>/dev/null && log "Node.js $(node --version) / npm $(npm --version) installed."
    else
        log "Node.js already installed: $(node --version)"
    fi

    # Python — latest available
    local py_ver
    py_ver=$(python3 --version 2>/dev/null | grep -oP '\d+\.\d+')
    case "$OS_FAMILY" in
        debian)
            if [[ -z "$py_ver" || "$(echo "$py_ver" | cut -d. -f2)" -lt 12 ]]; then
                info "Installing latest Python from deadsnakes..."
                add-apt-repository -y ppa:deadsnakes/ppa -u &>/dev/null || true
                local latest_py
                latest_py=$(apt-cache search '^python3\.[0-9]+$' 2>/dev/null | sort -t. -k2 -rn | head -1 | awk '{print $1}')
                if [[ -n "$latest_py" ]]; then
                    $PKG_INSTALL "$latest_py" python3-pip
                    log "Python $("$latest_py" --version 2>/dev/null) installed as $latest_py"
                    update-alternatives --install /usr/bin/python3 python3 "$(command -v "$latest_py")" 1 2>/dev/null || true
                fi
            else
                log "Python $(python3 --version 2>/dev/null) — up to date."
            fi ;;
        rhel)
            if [[ -z "$py_ver" || "$(echo "$py_ver" | cut -d. -f2)" -lt 12 ]]; then
                info "Installing Python 3 from EPEL/CRB..."
                pkg_install python3 python3-pip python3-devel || true
                log "Python $(python3 --version 2>/dev/null) installed."
            fi ;;
        arch)
            # Arch always has latest Python
            pkg_install python python-pip || true
            log "Python $(python3 --version 2>/dev/null) — up to date." ;;
        suse)
            pkg_install python3 python3-pip python3-devel || true
            log "Python $(python3 --version 2>/dev/null) installed." ;;
    esac
}

# ── 4.5 Install Midnight Commander (mc) ─────────────────────────────────────
do_install_mc() {
    header "Installing Midnight Commander (mc)"
    if command -v mc &>/dev/null; then
        log "mc already installed: $(mc --version 2>/dev/null | head -1)"
    else
        pkg_install mc
        command -v mc &>/dev/null && log "mc installed: $(mc --version 2>/dev/null | head -1)" \
            || { warn "mc install failed."; return; }
    fi

    # Set mcedit as the system default editor where supported
    if command -v update-alternatives &>/dev/null && command -v mcedit &>/dev/null; then
        update-alternatives --install /usr/bin/editor editor "$(command -v mcedit)" 30 2>/dev/null || true
    fi

    # Drop-in profile: alias + nice defaults for root and odin (if present)
    cat > /etc/profile.d/mc.sh <<'EOF'
# Midnight Commander defaults
export EDITOR="${EDITOR:-mcedit}"
export VISUAL="${VISUAL:-mcedit}"
alias mc='mc -x'      # enable mouse + xterm features
alias mcc='mc -c'     # force color
EOF
    chmod +x /etc/profile.d/mc.sh
    log "mc defaults installed at /etc/profile.d/mc.sh (EDITOR=mcedit, mouse on)"
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

    cat > /etc/profile.d/opencode.sh <<'EOF'
if [[ ":$PATH:" != *":/usr/local/share/npm-global/bin:"* ]]; then
    export PATH="/usr/local/share/npm-global/bin:$PATH"
fi
if [[ ":$PATH:" != *":$HOME/.opencode/bin:"* ]]; then
    export PATH="$HOME/.opencode/bin:$PATH"
fi
EOF
    chmod +x /etc/profile.d/opencode.sh
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
    if command -v claude &>/dev/null; then
        log "Claude Code installed: $(claude --version 2>/dev/null || echo 'ok')"
    else
        warn "claude binary not found after install; trying npx-based setup..."
        npx @anthropic-ai/claude-code --version 2>/dev/null && {
            log "Claude Code available via npx."
        } || warn "Claude Code not available."
    fi

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
    local iface current_ip current_gw
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

    local mask_full
    mask_full=$(python3 -c "import socket,struct; print(socket.inet_ntoa(struct.pack('!I', (0xffffffff << (32-$netmask)) & 0xffffffff)))" 2>/dev/null || echo "255.255.255.0")

    case "$OS_FAMILY" in
        debian)
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
                netplan apply 2>/dev/null || warn "netplan apply failed — review $np_file"
                log "Static IP configured via netplan."
            elif [[ -f /etc/network/interfaces ]]; then
                cat > /etc/network/interfaces <<IFACES
auto lo
iface lo inet loopback

auto $iface
iface $iface inet static
    address $static_ip
    netmask $mask_full
    gateway $gateway
    dns-nameservers $dns1 $dns2
IFACES
                systemctl restart networking 2>/dev/null || true
                log "Static IP via /etc/network/interfaces."
            else
                warn "No netplan or interfaces — configure IP manually."
            fi ;;
        rhel)
            local cfg_file="/etc/sysconfig/network-scripts/ifcfg-$iface"
            cat > "$cfg_file" <<IFCFG
DEVICE=$iface
BOOTPROTO=static
ONBOOT=yes
IPADDR=$static_ip
PREFIX=$netmask
GATEWAY=$gateway
DNS1=$dns1
DNS2=$dns2
IFCFG
            if command -v nmcli &>/dev/null; then
                nmcli connection reload 2>/dev/null || true
                nmcli connection up "$iface" 2>/dev/null || nmcli connection up "System $iface" 2>/dev/null || true
            fi
            log "Static IP configured via ifcfg ($cfg_file)." ;;
        arch)
            # systemd-networkd configuration
            local netdev_file="/etc/systemd/network/20-$iface.network"
            cat > "$netdev_file" <<SYSDNET
[Match]
Name=$iface

[Network]
Address=${static_ip}/${netmask}
Gateway=$gateway
DNS=$dns1
DNS=$dns2
SYSDNET
            systemctl enable --now systemd-networkd 2>/dev/null || true
            systemctl restart systemd-networkd 2>/dev/null || true
            log "Static IP configured via systemd-networkd ($netdev_file)." ;;
        suse)
            local cfg_file="/etc/sysconfig/network/ifcfg-$iface"
            cat > "$cfg_file" <<IFCFG
BOOTPROTO=static
IPADDR=$static_ip/$netmask
GATEWAY=$gateway
DNS1=$dns1
DNS2=$dns2
IFCFG
            systemctl restart network 2>/dev/null || true
            log "Static IP configured via ifcfg ($cfg_file)." ;;
    esac
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
            echo
            log "══════════════════════════════════════════════"
            log "  ${GREEN}odin${NC} user password: ${RED}$odin_pass${NC}"
            log "══════════════════════════════════════════════"
        fi
        return
    fi

    info "Creating user 'odin' with root privileges..."
    odin_pass=$(gen_pass)

    useradd -m -s /bin/bash -G "$DEV_GROUP,adm" odin 2>/dev/null || \
        useradd -m -s /bin/bash odin && usermod -aG "$DEV_GROUP,adm" odin

    echo "odin:$odin_pass" | chpasswd
    echo "odin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/odin
    chmod 440 /etc/sudoers.d/odin

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
    log "  ${GREEN}Groups ${NC}: $DEV_GROUP, adm"
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

    info "Testing Telegram connection..."
    local test_ok
    test_ok=$(curl -s "https://api.telegram.org/bot${tg_token}/getMe" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ok',''))" 2>/dev/null || echo "")
    if [[ "$test_ok" != "True" ]]; then
        warn "Bot token seems invalid (getMe failed)."
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

    telegram-notify info "Telegram notifications configured on $(hostname)" || \
        warn "Test message failed — check CHAT_ID."

    log "telegram-notify installed at $script"
    echo "  Usage: telegram-notify info \"Server is running\""
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
        case "$OS_FAMILY" in
            debian) $PKG_INSTALL awscli 2>/dev/null || install_awscli_v2 ;;
            rhel)   $PKG_INSTALL awscli2 2>/dev/null || $PKG_INSTALL awscli 2>/dev/null || install_awscli_v2 ;;
            arch)   pkg_install aws-cli || install_awscli_v2 ;;
            suse)   $PKG_INSTALL aws-cli 2>/dev/null || install_awscli_v2 ;;
        esac
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

    cat > /etc/profile.d/wasabi.sh <<EOF
export WASABI_BUCKET=$wasabi_bucket
export WASABI_REGION=$wasabi_region
EOF
    chmod +x /etc/profile.d/wasabi.sh

    if aws s3 --endpoint-url "https://s3.${wasabi_region}.wasabisys.com" ls "s3://${wasabi_bucket}" &>/dev/null; then
        log "Wasabi connection OK — bucket '$wasabi_bucket' is accessible."
    else
        warn "Could not list bucket '$wasabi_bucket'."
        prompt "Continue anyway? [y/N]: " ans
        [[ ! "$ans" =~ ^[Yy] ]] && { warn "Skipping Wasabi."; return; }
    fi

    cat > /usr/local/bin/wasabi-backup <<'BACKUP'
#!/usr/bin/env bash
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

install_awscli_v2() {
    info "Downloading AWS CLI v2..."
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -qq /tmp/awscliv2.zip -d /tmp && /tmp/aws/install 2>&1 | tail -1 || true
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

    [[ -f /etc/profile.d/wasabi.sh ]] && source /etc/profile.d/wasabi.sh
    local bucket="${WASABI_BUCKET:-backup}"
    local region="${WASABI_REGION:-us-east-1}"

    local backup_script="/usr/local/bin/wasabi-autobackup"
    cat > "$backup_script" <<'AUTOBACKUP'
#!/usr/bin/env bash
set -euo pipefail
BUCKET="${WASABI_BUCKET:?WASABI_BUCKET not set}"
REGION="${WASABI_REGION:?WASABI_REGION not set}"
ENDPOINT="https://s3.${REGION}.wasabisys.com"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/var/log/wasabi-backup.log"

echo "===== Wasabi Auto-Backup $TIMESTAMP =====" | tee -a "$LOG"

if [[ -f "$LOG" && $(stat -c%s "$LOG" 2>/dev/null || stat -f%z "$LOG" 2>/dev/null) -gt 10485760 ]]; then
    mv "$LOG" "${LOG}.old"
fi

aws_base() { aws s3 --endpoint-url "$ENDPOINT" "$@"; }

backup_dir() {
    local src="$1" prefix="$2"
    local name; name=$(basename "$src")
    local dest="s3://${BUCKET}/system/${prefix}/${name}"
    echo "[$(date '+%H:%M:%S')] Syncing $src → $dest" | tee -a "$LOG"
    aws_base sync "$src" "$dest" --delete 2>&1 | tee -a "$LOG" | tail -3
}

backup_dir /home    home
backup_dir /etc     config
backup_dir /root    root
backup_dir /var/log logs
[[ -d /var/www ]] && backup_dir /var/www www

echo "===== Complete =====" | tee -a "$LOG"
AUTOBACKUP
    chmod +x "$backup_script"
    log "Auto-backup script created at $backup_script"

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
    echo "    /var/www    → s3://${bucket}/system/www/ (if exists)"
    echo "  Runs daily via /etc/cron.daily"
    echo

    prompt "Run a test backup now? [Y/n]: " ans
    if [[ "${ans:-y}" =~ ^[Yy] ]]; then
        info "Running test backup..."
        "$backup_script" || warn "Test backup had errors (check /var/log/wasabi-backup.log)."
        log "Test backup finished."
    fi
}

# ── 13. Cloudflare DNS Integration ─────────────────────────────────────────
setup_cloudflare() {
    header "Cloudflare DNS (Dynamic DNS) Setup"
    echo "Keep your DNS A record pointed at this server's IP address."
    echo "You need:"
    echo "  1. An API Token with DNS:Edit permission for the zone"
    echo "     → Create at https://dash.cloudflare.com/profile/api-tokens"
    echo "  2. The Zone ID (found in Cloudflare Dashboard → zone → Overview)"
    echo "  3. The DNS record name to update (e.g. server.example.com)"
    echo

    local ans
    prompt "Set up Cloudflare DNS updates? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy] ]] && { log "Skipping Cloudflare."; return; }

    local cf_token cf_zone cf_name cf_ttl cf_proxied
    while true; do
        prompt "Cloudflare API Token : " cf_token
        [[ -n "$cf_token" ]] && break
        warn "API Token cannot be empty."
    done
    while true; do
        prompt "Zone ID             : " cf_zone
        [[ -n "$cf_zone" ]] && break
        warn "Zone ID cannot be empty."
    done
    while true; do
        prompt "DNS Record Name     : " cf_name
        local fqdn="${cf_name:-}"
        # If just a hostname, append zone-derived domain
        [[ -n "$fqdn" ]] && break
        warn "Record name cannot be empty."
    done
    prompt "TTL (120-86400s)    [120]: " cf_ttl
    cf_ttl="${cf_ttl:-120}"
    prompt "Proxied (CDN)       [Y/n]: " ans
    cf_proxied=true
    [[ "$ans" =~ ^[Nn] ]] && cf_proxied=false

    echo
    info "Testing Cloudflare API token..."
    local test_ok
    test_ok=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success',''))" 2>/dev/null || echo "")
    if [[ "$test_ok" != "True" ]]; then
        warn "API token verification failed. Check token permissions."
        prompt "Continue anyway? [y/N]: " ans
        [[ ! "$ans" =~ ^[Yy] ]] && { warn "Skipping Cloudflare."; return; }
    fi

    # Save credentials
    cat > /etc/profile.d/cloudflare.sh <<EOF
export CF_TOKEN=$cf_token
export CF_ZONE=$cf_zone
export CF_NAME=$cf_name
export CF_TTL=$cf_ttl
export CF_PROXIED=$cf_proxied
EOF
    chmod +x /etc/profile.d/cloudflare.sh

    # Create DNS update script
    local cf_script="/usr/local/bin/cloudflare-dns"
    cat > "$cf_script" <<'CFSCRIPT'
#!/usr/bin/env bash
#===============================================================================
# Cloudflare DNS Update — sets DNS A record to current public IP
# Usage: cloudflare-dns [--ip <address>]
#===============================================================================
set -euo pipefail

TOKEN="${CF_TOKEN:?CF_TOKEN not set}"
ZONE="${CF_ZONE:?CF_ZONE not set}"
NAME="${CF_NAME:?CF_NAME not set}"
TTL="${CF_TTL:-120}"
PROXIED="${CF_PROXIED:-true}"
API="https://api.cloudflare.com/client/v4"

cf_api() {
    curl -s -X "$1" "$2" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" "${@:3}"
}

# Get current public IP
if [[ "${1:-}" == "--ip" && -n "${2:-}" ]]; then
    IP="$2"
else
    IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null)
fi
[[ -z "$IP" ]] && { echo "Could not determine public IP."; exit 1; }

echo "Updating $NAME → $IP (TTL=$TTL, proxied=$PROXIED)"

# Get existing record ID
RECORD_ID=$(cf_api GET "$API/zones/$ZONE/dns_records?type=A&name=$NAME" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
records = d.get('result', [])
if records:
    print(records[0]['id'])
else:
    print('')
" 2>/dev/null)

if [[ -n "$RECORD_ID" ]]; then
    # Update existing
    RESULT=$(cf_api PUT "$API/zones/$ZONE/dns_records/$RECORD_ID" \
        -d "{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$IP\",\"ttl\":$TTL,\"proxied\":$PROXIED}")
else
    # Create new
    RESULT=$(cf_api POST "$API/zones/$ZONE/dns_records" \
        -d "{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$IP\",\"ttl\":$TTL,\"proxied\":$PROXIED}")
fi

SUCCESS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
if [[ "$SUCCESS" == "True" ]]; then
    echo "✓ DNS record updated: $NAME → $IP"
else
    echo "✗ Update failed:"
    echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
    exit 1
fi
CFSCRIPT
    chmod +x "$cf_script"
    log "cloudflare-dns script installed at $cf_script"

    # Initial run
    info "Running initial DNS update..."
    "$cf_script" && {
        log "Cloudflare DNS record updated to current IP."
    } || warn "Initial DNS update failed — check credentials."

    # Cron for periodic updates
    echo
    prompt "Set up hourly cron job to keep DNS record updated? [Y/n]: " ans
    if [[ "${ans:-y}" =~ ^[Yy] ]]; then
        cat > /etc/cron.hourly/cloudflare-dns <<'CRON'
#!/bin/bash
source /etc/profile.d/cloudflare.sh 2>/dev/null || true
exec /usr/local/bin/cloudflare-dns 2>/dev/null
CRON
        chmod +x /etc/cron.hourly/cloudflare-dns
        log "Hourly cron job installed at /etc/cron.hourly/cloudflare-dns"
    fi

    echo "  Usage: cloudflare-dns                  # auto-detect IP"
    echo "         cloudflare-dns --ip 1.2.3.4      # specify IP manually"
}

# ── 14. Firewall + Fail2Ban + AbuseIPDB ────────────────────────────────────
setup_firewall() {
    header "Firewall Setup ($FW_TOOL)"

    case "$FW_TOOL" in
        ufw)
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
            ufw status verbose ;;
        firewalld)
            systemctl enable --now firewalld 2>/dev/null || true
            firewall-cmd --set-default-zone=drop 2>/dev/null || true
            firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
            for port in "80/tcp" "443/tcp"; do
                local ans
                prompt "Allow $port? [y/N]: " ans
                [[ "$ans" =~ ^[Yy] ]] && firewall-cmd --permanent --add-port="$port" 2>/dev/null || true
            done
            firewall-cmd --reload 2>/dev/null || true
            firewall-cmd --list-all ;;
    esac
    log "Firewall ($FW_TOOL) configured."
}

setup_fail2ban() {
    header "Fail2Ban + AbuseIPDB Setup"
    if ! command -v fail2ban-server &>/dev/null; then
        pkg_install fail2ban
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
            warn "Could not fetch AbuseIPDB action."
        fi
    fi

    local banaction="ufw"
    [[ "$FW_TOOL" == "firewalld" ]] && banaction="firewallcmd-rich-rules"

    cat > /etc/fail2ban/jail.local <<JAIL
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5
banaction = $banaction
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

[$FW_TOOL]
enabled = true
logpath = /var/log/${FW_TOOL}.log
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

    systemctl enable --now fail2ban 2>/dev/null || true
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
    info "OS           : $OS_ID $OS_VERSION_ID ($OS_FAMILY)"
    echo
    info "Installed: base tools + latest Node/Git/Python + opencode + claude-code"
    info "Security : firewall ($FW_TOOL) + fail2ban + root lockdown + odin user"
    info "Cloud    : telegram + wasabi + cloudflare-dns (if configured)"
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

detect_distro
auto_set_location
show_info

# ── Run modes ────────────────────────────────────────────────────────────────
if [[ $# -eq 1 && "$1" == "--quick" ]]; then
    header "QUICK MODE"
    do_update
    do_install
    do_install_mc
    do_install_latest
    log "Quick mode done."
    exit 0
fi

if [[ $# -eq 1 && "$1" == "--unattended" ]]; then
    header "UNATTENDED MODE"
    do_update
    do_install
    do_install_mc
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
echo -e "${YELLOW}  Detected: $OS_ID $OS_VERSION_ID ($OS_FAMILY)          ${NC}"
echo -e "${YELLOW}  Press Enter to accept defaults shown in [brackets].     ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo

do_update
do_install
do_install_mc
do_install_latest
do_install_opencode
do_install_claude

wizard_static_ip
wizard_root
wizard_odin_user
setup_telegram
setup_wasabi
setup_wasabi_autobackup
setup_cloudflare
setup_firewall
setup_fail2ban
post_notify
show_summary
