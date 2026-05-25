#!/usr/bin/env bash
#===============================================================================
# RHLinuxConfig — Universal Linux Setup & Hardening Wizard
# Supports: AlmaLinux, Rocky, CentOS, RHEL, Debian, Ubuntu, Mint,
#           Arch, Manjaro, openSUSE, SLES
# - System info, updates, base + extended toolkit, network test tools
# - Latest Node / Git / Python, opencode, Claude Code
# - Telegram alerts, Wasabi backup, Cloudflare DDNS
# - UFW / firewalld + Fail2Ban + AbuseIPDB
# - Static IP, root password/disable, odin user creation
# Behaviors worth knowing:
# - Prompts show a live "[Ns]" countdown; safe [Y/n] → 5s default-yes,
#   opt-in [y/N] → 30s default-no, text → 5s default-empty.
# - Debian: leftover `deb cdrom:` sources are auto-disabled; default
#   net mirrors are written if none are configured.
# - pkg_install warns + skips packages missing from the distro index
#   instead of aborting under `set -e`.
#===============================================================================
set -euo pipefail

# ── Reattach to the terminal when piped (curl | bash, wget | bash, etc.) ────
# Without this, every `read` returns EOF instantly: prompts flash by, the
# 5s countdown becomes microseconds, and auto_reboot would fire with no
# chance to cancel.
NO_TTY=0
if [[ ! -t 0 ]]; then
    if [[ -r /dev/tty ]]; then
        exec < /dev/tty
    else
        # Truly headless (no controlling terminal at all)
        NO_TTY=1
    fi
fi

# ── Non-interactive package installers ──────────────────────────────────────
# Prevents apt/dpkg from prompting for service config (iperf3 daemon, etc.)
# and stops needrestart from interrupting on Ubuntu 22.04+.
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'

# ── Logging to file ────────────────────────────────────────────────────────
# Live event log (every log/warn/err/info/header line); a separate detailed
# summary is written at the end by write_detailed_summary().
RUN_TS="$(date +%Y%m%d-%H%M%S)"
LOGFILE="/var/log/rhlinuxconfig-${RUN_TS}.log"
SUMMARY_FILE="/var/log/rhlinuxconfig-summary-${RUN_TS}.txt"
mkdir -p /var/log 2>/dev/null || true
if ! touch "$LOGFILE" 2>/dev/null; then
    LOGFILE="/tmp/rhlinuxconfig-${RUN_TS}.log"
    SUMMARY_FILE="/tmp/rhlinuxconfig-summary-${RUN_TS}.txt"
    touch "$LOGFILE"
fi
# Strip ANSI escapes before writing to the file
_to_log() { local lvl="$1"; shift; printf '[%s] %s %s\n' "$lvl" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE"; }

log()   { echo -e "${GREEN}[✓]${NC}  $*"; _to_log "OK  " "$*"; }
warn()  { echo -e "${YELLOW}[!]${NC}  $*"; _to_log "WARN" "$*"; }
err()   { echo -e "${RED}[✗]${NC}  $*"; _to_log "ERR " "$*"; }
info()  { echo -e "${CYAN}[i]${NC}  $*"; _to_log "INFO" "$*"; }
header(){ echo -e "\n${MAG}══ $* ══${NC}"; printf '\n══ %s ══\n' "$*" >> "$LOGFILE"; }
# Prompt timeouts (set any to 0 to wait forever):
#   AUTO_YES_TIMEOUT   — safe [Y/n] prompts (default already yes, e.g. "change
#                        root password?"). Short: hands-off completion.
#   AUTO_NO_TIMEOUT    — opt-in [y/N] prompts (cloud setup, static IP, etc.).
#                        Long: give the operator time to read the multi-line
#                        intro and type 'y' if they actually want it.
#   AUTO_TEXT_TIMEOUT  — text input prompts (IP address, gateway, etc.).
#                        Short: fall through to the bracketed default.
AUTO_YES_TIMEOUT="${AUTO_YES_TIMEOUT:-5}"
AUTO_NO_TIMEOUT="${AUTO_NO_TIMEOUT:-30}"
AUTO_TEXT_TIMEOUT="${AUTO_TEXT_TIMEOUT:-5}"

prompt(){
    local msg="$1"; shift
    local varname="${1:-}"

    # Detect prompt type, default answer, and timeout:
    #   "[Y/n]" → confirmation, default YES → auto-answer "y" after 5s
    #   "[y/N]" → confirmation, default NO  → auto-answer "n" after 30s
    #     (long window so the operator can read a multi-line wizard intro
    #     and opt in by typing 'y'; the previous 5s was too tight)
    #   "[y/n]" or "[Y/N]" → no explicit default → "n" after 30s
    #   anything else → text input, "" after 5s so "${var:-default}" wins
    local is_confirm="" timeout_default="" timeout_secs="$AUTO_TEXT_TIMEOUT"
    if   [[ "$msg" =~ \[Y/n\] ]]; then is_confirm=1; timeout_default="y"; timeout_secs="$AUTO_YES_TIMEOUT"
    elif [[ "$msg" =~ \[y/N\] ]]; then is_confirm=1; timeout_default="n"; timeout_secs="$AUTO_NO_TIMEOUT"
    elif [[ "$msg" =~ \[[YyNn]/[YyNn]\] ]]; then is_confirm=1; timeout_default="n"; timeout_secs="$AUTO_NO_TIMEOUT"
    fi

    # No terminal at all (piped + /dev/tty unavailable) → take defaults
    if [[ "${NO_TTY:-0}" -eq 1 ]]; then
        [[ -n "$varname" ]] && printf -v "$varname" '%s' "$timeout_default"
        echo -e "${CYAN}→${NC}  $msg ${YELLOW}${timeout_default:-<default>}${NC} (no-tty)"
        return 0
    fi

    if [[ "$timeout_secs" -gt 0 ]]; then
        # Char-by-char read loop so we can redraw a visible "[Ns]" countdown
        # next to the prompt each second. `read -s` suppresses terminal echo;
        # we redraw the buffer ourselves so typed input still appears.
        local prompt_text buf="" ch elapsed=0 remaining=$timeout_secs
        prompt_text="$(echo -e "${CYAN}→${NC}  $msg")"
        # \r returns to column 0; \033[K clears to end-of-line, so old
        # countdown digits don't bleed through when remaining shrinks.
        printf '\r\033[K%s%b[%2ds]%b %s' "$prompt_text" "$YELLOW" "$remaining" "$NC" "$buf" >&2
        while (( elapsed < timeout_secs )); do
            if IFS= read -rs -n1 -t1 ch 2>/dev/null; then
                if [[ -z "$ch" ]]; then
                    # Enter (with -n1, $ch is empty on newline)
                    printf '\n' >&2
                    [[ -n "$varname" ]] && printf -v "$varname" '%s' "$buf"
                    return 0
                elif [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                    buf="${buf%?}"
                else
                    buf+="$ch"
                fi
            else
                elapsed=$((elapsed + 1))
                remaining=$((timeout_secs - elapsed))
            fi
            printf '\r\033[K%s%b[%2ds]%b %s' "$prompt_text" "$YELLOW" "$remaining" "$NC" "$buf" >&2
        done
        # Timed out — finalize line and apply per-type default
        printf '\n' >&2
        if [[ -n "$buf" ]]; then
            # User was typing but never hit Enter; accept what they had
            [[ -n "$varname" ]] && printf -v "$varname" '%s' "$buf"
            return 0
        fi
        [[ -n "$varname" ]] && printf -v "$varname" '%s' "$timeout_default"
        if [[ -n "$is_confirm" ]]; then
            echo -e "${CYAN}→${NC}  $msg ${YELLOW}${timeout_default}${NC} (auto after ${timeout_secs}s)"
        else
            echo -e "${CYAN}→${NC}  $msg ${YELLOW}<default>${NC} (auto after ${timeout_secs}s)"
        fi
        return 0
    else
        read -rp "$(echo -e "${CYAN}→${NC}  $msg")" "$@" || true
    fi
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
            local APT_OPTS='-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o APT::Get::Assume-Yes=true'
            PKG_INSTALL="apt-get install $APT_OPTS"
            PKG_INSTALL_NQ="apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
            PKG_UPDATE="apt-get update -qq"
            PKG_UPGRADE="apt-get full-upgrade $APT_OPTS"
            PKG_AUTOREMOVE="apt-get autoremove $APT_OPTS; apt-get autoclean -qq"
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
            # makecache only refreshes metadata (and pre-imports repo GPG keys
            # under -y); check-update would dump the entire upgradable-package
            # list to stdout, which is just noise during the wizard.
            PKG_UPDATE="dnf makecache -y -q --refresh"
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
            pkgs="$pkgs apt-transport-https ca-certificates build-essential"
            # software-properties-common provides `add-apt-repository`, used
            # later for git-core and deadsnakes PPAs — both Ubuntu-only. Debian
            # 13 also dropped the package from main, so don't ask for it there.
            [[ "$OS_ID" == "ubuntu" ]] && pkgs="$pkgs software-properties-common"
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

# ── Helper: wait for apt/dpkg locks (Ubuntu unattended-upgrades) ────────────
wait_for_apt_lock() {
    [[ "$OS_FAMILY" != "debian" ]] && return 0
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
    local waited=0 max_wait=600  # 10 minutes
    local pid holder=""

    while :; do
        local busy=0
        for lock in "${locks[@]}"; do
            [[ -e "$lock" ]] || continue
            if pid=$(fuser "$lock" 2>/dev/null | tr -d ' '); then
                [[ -n "$pid" ]] && { busy=1; holder="$(ps -p "$pid" -o comm= 2>/dev/null || echo pid=$pid)"; break; }
            fi
        done
        [[ $busy -eq 0 ]] && return 0

        if [[ $waited -eq 0 ]]; then
            warn "apt/dpkg is locked by '$holder' — waiting (Ctrl-C to abort)..."
        elif (( waited % 20 == 0 )); then
            info "Still waiting on '$holder' (${waited}s elapsed)..."
        fi

        if (( waited >= max_wait )); then
            err "apt lock held for ${max_wait}s by '$holder'. Aborting."
            err "Stop it manually: sudo systemctl stop unattended-upgrades; sudo kill $pid"
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
}

# ── Helper: disable `deb cdrom:` sources left over from a DVD/ISO install ──
# A fresh Debian install from the official DVD leaves a `cdrom:[...]` source
# in apt's config. Once the disc is unmounted, `apt-get update` errors on it
# ("does not have a Release file") and — under `set -e` — kills the wizard
# before any net repo is even contacted. Debian 13 stores sources in two
# formats: classic single-line `deb cdrom:...` in .list files, and deb822
# multi-line stanzas (`URIs: cdrom:...`) in .sources files. Handle both.
disable_cdrom_sources() {
    [[ "$OS_FAMILY" != "debian" ]] && return 0
    shopt -s nullglob
    local f

    # Classic format: /etc/apt/sources.list + /etc/apt/sources.list.d/*.list
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        if grep -qE '^[[:space:]]*deb([[:space:]]+\[[^]]*\])?[[:space:]]+cdrom:' "$f" 2>/dev/null; then
            cp -a "$f" "${f}.rhlc.bak" 2>/dev/null || true
            sed -i -E 's|^([[:space:]]*deb([[:space:]]+\[[^]]*\])?[[:space:]]+cdrom:)|# \1|' "$f"
            warn "Disabled cdrom: source in $f (backup: ${f}.rhlc.bak)"
        fi
    done

    # deb822 format: any stanza with a `URIs:` field referencing cdrom: gets
    # `Enabled: no` appended, which is apt's native way of disabling a stanza
    # without removing it.
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        grep -qE '^[[:space:]]*URIs:[[:space:]]*.*cdrom:' "$f" 2>/dev/null || continue
        cp -a "$f" "${f}.rhlc.bak" 2>/dev/null || true
        awk '
            BEGIN { RS = ""; ORS = "\n\n" }
            {
                if ($0 ~ /(^|\n)[[:space:]]*URIs:[[:space:]]*[^\n]*cdrom:/ \
                    && $0 !~ /(^|\n)[[:space:]]*Enabled:[[:space:]]*no/) {
                    $0 = $0 "\nEnabled: no"
                }
                print
            }
        ' "$f" > "${f}.rhlc.tmp" && mv "${f}.rhlc.tmp" "$f"
        warn "Disabled cdrom: stanza in $f (backup: ${f}.rhlc.bak)"
    done

    # If nothing else remains (DVD-only installs sometimes never configure a
    # net mirror), apt-get update would now pass vacuously and apt-get install
    # would fail with "Unable to locate package". Write default mirrors.
    _ensure_debian_net_repo

    shopt -u nullglob
    return 0
}

# ── Helper: write default Debian/Ubuntu net repos if none are configured ───
_ensure_debian_net_repo() {
    [[ "$OS_FAMILY" != "debian" ]] && return 0
    shopt -s nullglob

    local f found=0
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        if grep -qE '^[[:space:]]*deb([[:space:]]+\[[^]]*\])?[[:space:]]+https?://' "$f" 2>/dev/null; then
            found=1; break
        fi
    done
    if [[ $found -eq 0 ]]; then
        for f in /etc/apt/sources.list.d/*.sources; do
            [[ -f "$f" ]] || continue
            # active = stanza has URIs: http(s):// AND does not have Enabled: no
            if awk '
                BEGIN { RS = ""; rc = 1 }
                /(^|\n)[[:space:]]*URIs:[[:space:]]*[^\n]*https?:\/\// \
                    && $0 !~ /(^|\n)[[:space:]]*Enabled:[[:space:]]*no/ { rc = 0 }
                END { exit rc }
            ' "$f"; then
                found=1; break
            fi
        done
    fi

    if [[ $found -eq 1 ]]; then
        shopt -u nullglob
        return 0
    fi

    local suite="${OS_CODENAME:-}"
    [[ -z "$suite" ]] && suite=$(lsb_release -cs 2>/dev/null || echo trixie)

    warn "No usable apt net repo found — writing default $OS_ID mirrors for '$suite'."
    if [[ "$OS_ID" == "ubuntu" ]]; then
        cat > /etc/apt/sources.list.d/rhlc-defaults.list <<EOF
deb http://archive.ubuntu.com/ubuntu $suite main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $suite-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $suite-security main restricted universe multiverse
EOF
    else
        # Debian 12+ ships firmware in its own component (`non-free-firmware`);
        # 11 and earlier put it in `non-free`. Detect by codename.
        local comps="main contrib non-free non-free-firmware"
        case "$suite" in
            buster|bullseye) comps="main contrib non-free" ;;
        esac
        cat > /etc/apt/sources.list.d/rhlc-defaults.list <<EOF
deb http://deb.debian.org/debian $suite $comps
deb http://deb.debian.org/debian $suite-updates $comps
deb http://security.debian.org/debian-security $suite-security $comps
EOF
    fi
    info "Wrote /etc/apt/sources.list.d/rhlc-defaults.list."
    shopt -u nullglob
}

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
    wait_for_apt_lock
    disable_cdrom_sources
    info "Using $PKG_MGR — updating package lists..."
    eval "$PKG_UPDATE"
    wait_for_apt_lock
    info "Upgrading packages..."
    eval "$PKG_UPGRADE"
    wait_for_apt_lock
    eval "$PKG_AUTOREMOVE" 2>/dev/null || true
    log "System is up to date."
}

# ── 3. Install Base Tools ───────────────────────────────────────────────────
# Per-distro check: does the package manager's index know about this package?
# Returns 0 if available, non-zero otherwise. Lets pkg_install warn and skip
# instead of failing hard on a name that differs between releases.
_pkg_available() {
    local pkg="$1"
    case "$OS_FAMILY" in
        debian) apt-cache show "$pkg" &>/dev/null ;;
        rhel)   dnf info "$pkg" &>/dev/null ;;
        arch)   pacman -Si "$pkg" &>/dev/null ;;
        suse)   zypper --non-interactive info "$pkg" 2>/dev/null \
                    | grep -qE "^Name *: *${pkg}$" ;;
        *)      return 0 ;;
    esac
}

pkg_install() {
    local pkgs=("$@")
    local missing=() unavailable=() to_install=() pkg

    # 1. Skip anything already installed.
    for pkg in "${pkgs[@]}"; do
        $PKG_CHECK "$pkg" &>/dev/null && continue
        missing+=("$pkg")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    # 2. Filter by index — same UX on every distro: skip-and-warn beats
    # aborting the wizard on a name that doesn't exist in this release.
    for pkg in "${missing[@]}"; do
        if _pkg_available "$pkg"; then
            to_install+=("$pkg")
        else
            unavailable+=("$pkg")
        fi
    done
    [[ ${#unavailable[@]} -gt 0 ]] \
        && warn "Not in $PKG_MGR index, skipping: ${unavailable[*]}"
    [[ ${#to_install[@]} -eq 0 ]] && return 0

    # 3. Install. `|| true` keeps the wizard alive even if one package's
    # dependency resolution explodes — caller can re-check $PKG_CHECK later.
    [[ "$OS_FAMILY" == "debian" ]] && wait_for_apt_lock
    $PKG_INSTALL "${to_install[@]}" 2>&1 | tail -3 || true
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

# ── 4.6 Install Extended Sysadmin / Network Toolkit (best-effort) ───────────
# Packages requested: man perl vim nano atop nmon traceroute telnet lynx mlocate
# iptraf-ng nload bmon tcptrack vnstat cbm speedometer pktstat ifstat ntopng
# darkstat slurm  + cross-distro names for nc, snmp, man.
# Missing packages on a given distro are silently skipped (logged), so this
# step never aborts the run on obscure tools.
EXTRAS_OK=0; EXTRAS_FAIL=0
EXTRAS_FAILED_LIST=""

_install_one_best_effort() {
    local pkg="$1"
    case "$OS_FAMILY" in
        debian)
            # Pre-check that the package exists in the index
            if apt-cache show "$pkg" &>/dev/null; then
                wait_for_apt_lock
                if $PKG_INSTALL "$pkg" &>/dev/null; then
                    EXTRAS_OK=$((EXTRAS_OK + 1))
                else
                    EXTRAS_FAIL=$((EXTRAS_FAIL + 1)); EXTRAS_FAILED_LIST+=" $pkg"
                fi
            else
                EXTRAS_FAIL=$((EXTRAS_FAIL + 1)); EXTRAS_FAILED_LIST+=" $pkg(unavailable)"
            fi
            ;;
        rhel|arch|suse)
            if $PKG_INSTALL "$pkg" &>/dev/null; then
                EXTRAS_OK=$((EXTRAS_OK + 1))
            else
                EXTRAS_FAIL=$((EXTRAS_FAIL + 1)); EXTRAS_FAILED_LIST+=" $pkg"
            fi
            ;;
    esac
}

do_install_extras() {
    header "Installing Extended Toolkit"

    # Common — names that are identical across all four families.
    # mlocate is deprecated on Ubuntu 22.04+ (replaced by plocate) — list both
    # so the best-effort installer picks whichever the distro ships.
    # Network-test tools (iperf3, netperf, speedtest-cli, Ookla speedtest) are
    # handled separately by do_install_nettest with stricter retries/fallbacks.
    local extras="perl vim nano atop nmon traceroute telnet lynx plocate mlocate nload bmon tcptrack vnstat ifstat darkstat"

    # Per-family additions / name remaps. slurm bandwidth tool moved around in
    # Debian: list both 'slurm' and 'slurm-tools' so whichever exists installs.
    case "$OS_FAMILY" in
        debian)
            extras="$extras man-db netcat-openbsd iptraf-ng snmp ntopng pktstat cbm speedometer slurm slurm-tools gzip"
            ;;
        rhel)
            extras="$extras man nmap-ncat iptraf-ng net-snmp net-snmp-utils ntopng pktstat cbm gzip"
            # EPEL provides most of the niche tools — already enabled earlier
            ;;
        arch)
            extras="$extras man-db gnu-netcat iptraf-ng net-snmp ntopng pktstat cbm slurm gzip"
            ;;
        suse)
            extras="$extras man netcat-openbsd iptraf-ng net-snmp ntopng gzip"
            ;;
    esac

    EXTRAS_OK=0; EXTRAS_FAIL=0; EXTRAS_FAILED_LIST=""
    info "Trying $(echo "$extras" | wc -w) packages (missing ones will be skipped)..."

    local pkg
    for pkg in $extras; do
        # Skip if already installed
        if $PKG_CHECK "$pkg" &>/dev/null 2>&1; then
            EXTRAS_OK=$((EXTRAS_OK + 1))
            continue
        fi
        _install_one_best_effort "$pkg"
    done

    log "Extended toolkit: ${GREEN}${EXTRAS_OK} installed${NC}, ${YELLOW}${EXTRAS_FAIL} unavailable/failed${NC}."
    [[ -n "$EXTRAS_FAILED_LIST" ]] && info "Not installed:$EXTRAS_FAILED_LIST"

    # mlocate ships /etc/cron.daily/mlocate; trigger an initial DB build
    command -v updatedb &>/dev/null && updatedb &>/dev/null &
}

# ── 4.7 Install Network Test Tools (iperf3, netperf, speedtest-cli, Ookla) ──
# Installed unconditionally on every run — these are "configure by default"
# regardless of mode. Each tool gets its own pkg-manager attempt plus a
# fallback (pip for speedtest-cli, static binary for Ookla) so a missing repo
# package doesn't leave the user with an empty network-test toolkit.
_install_ookla_speedtest() {
    if command -v speedtest &>/dev/null \
        && speedtest --version 2>/dev/null | grep -qi "Speedtest by Ookla"; then
        log "Ookla speedtest already installed: $(speedtest --version 2>/dev/null | head -1)"
        return 0
    fi

    local st_arch tarball url tmpdir
    case "$ARCH" in
        x86_64|amd64)   st_arch="x86_64" ;;
        aarch64|arm64)  st_arch="aarch64" ;;
        armv7l|armhf)   st_arch="armhf" ;;
        i686|i386)      st_arch="i386" ;;
        *) warn "No Ookla speedtest binary for arch: $ARCH"; return 1 ;;
    esac

    tarball="ookla-speedtest-1.2.0-linux-${st_arch}.tgz"
    url="https://install.speedtest.net/app/cli/${tarball}"
    tmpdir=$(mktemp -d)

    info "Downloading Ookla speedtest ($tarball)..."
    if ! curl -fsSL --max-time 30 "$url" -o "$tmpdir/$tarball"; then
        warn "Could not download Ookla speedtest from $url"
        rm -rf "$tmpdir"
        return 1
    fi

    if tar -xzf "$tmpdir/$tarball" -C "$tmpdir" 2>/dev/null \
        && install -m 0755 "$tmpdir/speedtest" /usr/local/bin/speedtest; then
        rm -rf "$tmpdir"
        # Pre-accept license/GDPR so future runs (incl. cron) don't prompt
        mkdir -p /root/.config/ookla
        /usr/local/bin/speedtest --accept-license --accept-gdpr --progress=no &>/dev/null || true
        log "Ookla speedtest installed: $(speedtest --version 2>/dev/null | head -1)"
    else
        warn "Ookla speedtest extraction/install failed."
        rm -rf "$tmpdir"
        return 1
    fi
}

do_install_nettest() {
    header "Installing Network Test Tools"

    # iperf3 — usually already in via PACKAGES_CORE, but make sure.
    if ! command -v iperf3 &>/dev/null; then
        info "Installing iperf3..."
        [[ "$OS_FAMILY" == "debian" ]] && wait_for_apt_lock
        $PKG_INSTALL iperf3 &>/dev/null || true
    fi
    command -v iperf3 &>/dev/null \
        && log "iperf3: $(iperf3 --version 2>/dev/null | head -1)" \
        || warn "iperf3: install failed (not in $OS_FAMILY repos?)"

    # netperf — on RHEL needs EPEL (enabled earlier); on Arch it lives in AUR
    # (not handled here, hence the soft warn).
    if ! command -v netperf &>/dev/null; then
        info "Installing netperf..."
        [[ "$OS_FAMILY" == "debian" ]] && wait_for_apt_lock
        $PKG_INSTALL netperf &>/dev/null || true
    fi
    command -v netperf &>/dev/null \
        && log "netperf: installed" \
        || warn "netperf: not available in $OS_FAMILY repos (skip or build from source)"

    # speedtest-cli (Python) — try pkg first, pip3 as a fallback (newer distros
    # sometimes drop the deb/rpm package).
    if ! command -v speedtest-cli &>/dev/null; then
        info "Installing speedtest-cli..."
        [[ "$OS_FAMILY" == "debian" ]] && wait_for_apt_lock
        if ! $PKG_INSTALL speedtest-cli &>/dev/null; then
            if command -v pip3 &>/dev/null; then
                info "  pkg manager didn't provide it — trying pip3..."
                pip3 install --quiet --break-system-packages speedtest-cli 2>/dev/null \
                    || pip3 install --quiet speedtest-cli 2>/dev/null || true
            fi
        fi
    fi
    command -v speedtest-cli &>/dev/null \
        && log "speedtest-cli: $(speedtest-cli --version 2>/dev/null | head -1)" \
        || warn "speedtest-cli: install failed (pkg + pip3 both unavailable)"

    # Ookla speedtest — static binary from speedtest.net (separate from the
    # Python speedtest-cli; both can coexist).
    _install_ookla_speedtest
}

# ── 5. Install opencode ─────────────────────────────────────────────────────
_opencode_present() {
    command -v opencode &>/dev/null || [[ -x /root/.opencode/bin/opencode ]]
}
_opencode_version() {
    /root/.opencode/bin/opencode --version 2>/dev/null \
        || opencode --version 2>/dev/null \
        || echo "ok"
}

do_install_opencode() {
    header "Installing opencode"
    if _opencode_present; then
        log "opencode already installed: $(_opencode_version)"
        return 0
    fi

    # Write the PATH profile up-front so the post-install binary is discoverable
    cat > /etc/profile.d/opencode.sh <<'EOF'
if [[ -d /root/.opencode/bin && ":$PATH:" != *":/root/.opencode/bin:"* ]]; then
    export PATH="/root/.opencode/bin:$PATH"
fi
if [[ -d "$HOME/.opencode/bin" && ":$PATH:" != *":$HOME/.opencode/bin:"* ]]; then
    export PATH="$HOME/.opencode/bin:$PATH"
fi
if [[ -d /usr/local/share/npm-global/bin && ":$PATH:" != *":/usr/local/share/npm-global/bin:"* ]]; then
    export PATH="/usr/local/share/npm-global/bin:$PATH"
fi
EOF
    chmod +x /etc/profile.d/opencode.sh
    export PATH="/root/.opencode/bin:/usr/local/share/npm-global/bin:$PATH"

    # ── Method 1: official installer ────────────────────────────────────────
    info "Method 1/3: official installer (opencode.ai/install)..."
    if curl -fsSL https://opencode.ai/install 2>/dev/null | bash 2>&1 | tail -3; then
        if _opencode_present; then
            log "opencode installed via official script: $(_opencode_version)"
            return 0
        fi
    fi
    warn "Official installer did not produce a binary — trying npm..."

    # ── Method 2: npm (correct package name is 'opencode-ai', unscoped) ─────
    if command -v npm &>/dev/null; then
        info "Method 2/3: npm install -g opencode-ai ..."
        mkdir -p /usr/local/share/npm-global
        npm config set prefix /usr/local/share/npm-global 2>/dev/null || true
        if npm install -g --unsafe-perm=true opencode-ai 2>&1 | tail -3; then
            if _opencode_present; then
                log "opencode installed via npm: $(_opencode_version)"
                return 0
            fi
        fi
        warn "npm install failed — falling back to GitHub release..."
    fi

    # ── Method 3: GitHub release binary ─────────────────────────────────────
    local rel_asset rel_url
    case "$ARCH" in
        x86_64|amd64)  rel_asset="opencode-linux-x64.zip" ;;
        aarch64|arm64) rel_asset="opencode-linux-arm64.zip" ;;
        *) warn "No prebuilt opencode binary for $ARCH."; return 1 ;;
    esac
    info "Method 3/3: GitHub releases ($rel_asset)..."
    rel_url=$(curl -fsSL "https://api.github.com/repos/sst/opencode/releases/latest" 2>/dev/null \
        | grep -oE "https://github.com/sst/opencode/releases/download/[^\"]+${rel_asset}" | head -1)
    if [[ -n "$rel_url" ]]; then
        mkdir -p /root/.opencode/bin
        if curl -fsSL "$rel_url" -o /tmp/opencode.zip \
            && unzip -qo /tmp/opencode.zip -d /root/.opencode/bin \
            && chmod +x /root/.opencode/bin/opencode \
            && rm -f /tmp/opencode.zip; then
            if _opencode_present; then
                log "opencode installed from GitHub release: $(_opencode_version)"
                return 0
            fi
        fi
    fi

    warn "All three opencode install methods failed."
    warn "Install manually later:  curl -fsSL https://opencode.ai/install | bash"
    return 1
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
    prompt "Set up Telegram notifications? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy] ]] && { log "Skipping Telegram."; return; }

    local tg_token tg_chat script tries
    tries=0
    while true; do
        prompt "Telegram Bot Token (e.g. 123456:ABC-DEF...): " tg_token
        [[ -n "$tg_token" ]] && break
        tries=$((tries + 1))
        warn "Token cannot be empty (attempt $tries/3)."
        (( tries >= 3 )) && { warn "Aborting Telegram setup — no token given."; return; }
    done
    tries=0
    while true; do
        prompt "Telegram Chat ID (numeric, e.g. 123456789): " tg_chat
        [[ -n "$tg_chat" ]] && break
        tries=$((tries + 1))
        warn "Chat ID cannot be empty (attempt $tries/3)."
        (( tries >= 3 )) && { warn "Aborting Telegram setup — no chat ID given."; return; }
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

    local wasabi_key wasabi_secret wasabi_bucket wasabi_region tries
    tries=0
    while true; do
        prompt "Wasabi Access Key      : " wasabi_key
        [[ -n "$wasabi_key" ]] && break
        tries=$((tries + 1))
        warn "Access Key cannot be empty (attempt $tries/3)."
        (( tries >= 3 )) && { warn "Aborting Wasabi setup — no access key."; return; }
    done
    tries=0
    while true; do
        prompt "Wasabi Secret Key      : " wasabi_secret
        [[ -n "$wasabi_secret" ]] && break
        tries=$((tries + 1))
        warn "Secret Key cannot be empty (attempt $tries/3)."
        (( tries >= 3 )) && { warn "Aborting Wasabi setup — no secret key."; return; }
    done
    tries=0
    while true; do
        prompt "Wasabi Bucket Name     : " wasabi_bucket
        [[ -n "$wasabi_bucket" ]] && break
        tries=$((tries + 1))
        warn "Bucket name cannot be empty (attempt $tries/3)."
        (( tries >= 3 )) && { warn "Aborting Wasabi setup — no bucket."; return; }
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

    local cf_token cf_zone cf_name cf_ttl cf_proxied tries
    tries=0
    while true; do
        prompt "Cloudflare API Token : " cf_token
        [[ -n "$cf_token" ]] && break
        tries=$((tries + 1))
        warn "API Token cannot be empty (attempt $tries/3)."
        (( tries >= 3 )) && { warn "Aborting Cloudflare setup — no token."; return; }
    done
    tries=0
    while true; do
        prompt "Zone ID             : " cf_zone
        [[ -n "$cf_zone" ]] && break
        tries=$((tries + 1))
        warn "Zone ID cannot be empty (attempt $tries/3)."
        (( tries >= 3 )) && { warn "Aborting Cloudflare setup — no zone ID."; return; }
    done
    tries=0
    while true; do
        prompt "DNS Record Name     : " cf_name
        local fqdn="${cf_name:-}"
        [[ -n "$fqdn" ]] && break
        tries=$((tries + 1))
        warn "Record name cannot be empty (attempt $tries/3)."
        (( tries >= 3 )) && { warn "Aborting Cloudflare setup — no record name."; return; }
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
        # Write AbuseIPDB action inline — no external dependency.
        # Category 18 = brute-force, 22 = SSH (default scope for sshd jail).
        cat > /etc/fail2ban/action.d/abuseipdb.conf <<'ABUSE'
# Fail2Ban action: report banned IPs to AbuseIPDB (https://www.abuseipdb.com)
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = curl --fail --silent --tlsv1.2 \
            --data-urlencode "ip=<ip>" \
            --data "categories=<abuseipdb_category>" \
            --data-urlencode "comment=<matches>" \
            --url "https://api.abuseipdb.com/api/v2/report" \
            -H "Key: <abuseipdb_apikey>" \
            -H "Accept: application/json" \
            -o /dev/null
actionunban =

[Init]
abuseipdb_apikey =
abuseipdb_category = 18,22
ABUSE
        sed -i "s|^abuseipdb_apikey =.*|abuseipdb_apikey = $abuse_key|" /etc/fail2ban/action.d/abuseipdb.conf
        log "AbuseIPDB action installed (inline template, no external fetch)."
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

# ── Auto-reboot with countdown ──────────────────────────────────────────────
auto_reboot() {
    header "Reboot Required"
    info "Setup finished successfully — a reboot is recommended to apply"
    info "kernel updates, group memberships, and PATH changes."

    # If we have no terminal, do NOT auto-reboot — the operator may be running
    # this from a script and would have no chance to cancel.
    if [[ "${NO_TTY:-0}" -eq 1 ]]; then
        warn "No TTY detected — skipping auto-reboot."
        warn "Run 'sudo reboot' manually to finalize the setup."
        return 0
    fi

    echo
    echo "  [Y] or [Enter]  →  reboot now"
    echo "  [N]             →  skip and reboot later (sudo reboot)"
    echo

    local countdown=30 key=""
    while (( countdown > 0 )); do
        printf "\r  ${YELLOW}Auto-reboot in %2ds${NC}  ·  press [Y/n]: " "$countdown"
        if read -rsn1 -t 1 key 2>/dev/null; then
            echo
            case "$key" in
                ""|y|Y)
                    log "Rebooting now..."
                    sleep 1
                    systemctl reboot 2>/dev/null || reboot
                    exit 0 ;;
                n|N)
                    log "Reboot skipped. Run 'sudo reboot' when ready."
                    return 0 ;;
                *)
                    # Unknown key — keep counting down
                    ;;
            esac
        fi
        countdown=$((countdown - 1))
    done

    echo
    log "No input — rebooting now..."
    if command -v telegram-notify &>/dev/null; then
        telegram-notify info "Auto-reboot triggered on $(hostname)" || true
    fi
    sleep 1
    systemctl reboot 2>/dev/null || reboot
}

# ── Final summary (detection-based: pass / fail / skipped) ──────────────────
SUM_OK=0; SUM_FAIL=0; SUM_SKIP=0

# Status line — green check / red cross / dim dash with a version/detail column
sum_pass() {
    local label="$1" detail="${2:-}"
    printf "  ${GREEN}✓${NC} %-32s ${CYAN}%s${NC}\n" "$label" "$detail"
    SUM_OK=$((SUM_OK + 1))
}
sum_fail() {
    local label="$1" detail="${2:-failed}"
    printf "  ${RED}✗${NC} %-32s ${RED}%s${NC}\n" "$label" "$detail"
    SUM_FAIL=$((SUM_FAIL + 1))
}
sum_skip() {
    local label="$1" detail="${2:-not configured}"
    printf "  ${YELLOW}-${NC} %-32s ${YELLOW}%s${NC}\n" "$label" "$detail"
    SUM_SKIP=$((SUM_SKIP + 1))
}

# Returns 0 if any firewall is active
_fw_active() {
    case "$FW_TOOL" in
        ufw)       ufw status 2>/dev/null | head -1 | grep -qi "active" ;;
        firewalld) systemctl is-active --quiet firewalld ;;
        *) return 1 ;;
    esac
}
_ntp_active() {
    systemctl is-active --quiet chronyd 2>/dev/null \
     || systemctl is-active --quiet chrony 2>/dev/null \
     || systemctl is-active --quiet systemd-timesyncd 2>/dev/null
}

show_summary() {
    echo
    header "Setup Complete"
    info "Hostname     : $(hostname -f 2>/dev/null || hostname)"
    info "Public IP    : $(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null || echo 'unknown')"
    info "Local IP     : $(ip -4 addr show | awk '/inet/{print $2}' | grep -v 127.0.0.1 | cut -d/ -f1 | head -1)"
    info "OS           : $OS_ID $OS_VERSION_ID ($OS_FAMILY)"
    info "Timezone     : $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'unknown')"

    SUM_OK=0; SUM_FAIL=0; SUM_SKIP=0

    echo
    echo -e "${MAG}── Core toolchain ──${NC}"
    command -v mc       &>/dev/null && sum_pass "Midnight Commander"  "$(mc --version 2>/dev/null | head -1 | awk '{print $NF}')" || sum_fail "Midnight Commander"
    command -v node     &>/dev/null && sum_pass "Node.js"             "$(node --version 2>/dev/null)" || sum_fail "Node.js"
    command -v npm      &>/dev/null && sum_pass "npm"                 "$(npm --version 2>/dev/null)" || sum_fail "npm"
    command -v git      &>/dev/null && sum_pass "Git"                 "$(git --version 2>/dev/null | awk '{print $3}')" || sum_fail "Git"
    command -v python3  &>/dev/null && sum_pass "Python 3"            "$(python3 --version 2>/dev/null | awk '{print $2}')" || sum_fail "Python 3"
    if command -v opencode &>/dev/null || [[ -x /root/.opencode/bin/opencode ]]; then
        sum_pass "opencode" "$(/root/.opencode/bin/opencode --version 2>/dev/null || opencode --version 2>/dev/null || echo installed)"
    else
        sum_fail "opencode" "install failed"
    fi
    if command -v claude &>/dev/null; then
        sum_pass "Claude Code" "$(claude --version 2>/dev/null | head -1)"
    else
        sum_fail "Claude Code" "install failed"
    fi

    echo
    echo -e "${MAG}── Network test tools ──${NC}"
    if command -v speedtest &>/dev/null && speedtest --version 2>/dev/null | grep -qi "Speedtest by Ookla"; then
        sum_pass "Ookla speedtest" "$(speedtest --version 2>/dev/null | head -1 | awk '{print $4}')"
    else
        sum_skip "Ookla speedtest"
    fi
    command -v netperf &>/dev/null      && sum_pass "netperf"        "installed" || sum_skip "netperf"
    command -v speedtest-cli &>/dev/null \
        || command -v speedtest &>/dev/null \
        && sum_pass "speedtest (any)"   "available"                              || sum_skip "speedtest CLI"
    command -v iperf3 &>/dev/null       && sum_pass "iperf3"         "installed" || sum_skip "iperf3"

    echo
    echo -e "${MAG}── Security ──${NC}"
    _fw_active                                    && sum_pass "Firewall ($FW_TOOL)"  "active" || sum_fail "Firewall ($FW_TOOL)"  "inactive"
    systemctl is-active --quiet fail2ban 2>/dev/null && sum_pass "Fail2Ban"          "running" || sum_fail "Fail2Ban"             "not running"
    _ntp_active                                   && sum_pass "NTP / chrony"         "synced"  || sum_fail "NTP / chrony"         "inactive"
    grep -q '^PermitRootLogin no' /etc/ssh/sshd_config 2>/dev/null \
        && sum_pass "Root SSH"  "disabled" || sum_skip "Root SSH" "still enabled"

    echo
    echo -e "${MAG}── Optional integrations ──${NC}"
    id odin &>/dev/null                           && sum_pass "User 'odin'"          "exists"  || sum_skip "User 'odin'"
    [[ -x /usr/local/bin/telegram-notify ]]       && sum_pass "Telegram notifier"    "installed" || sum_skip "Telegram notifier"
    [[ -f /root/.aws/credentials ]]               && sum_pass "Wasabi S3 credentials" "configured" || sum_skip "Wasabi S3 credentials"
    [[ -f /etc/cron.daily/wasabi-autobackup ]]    && sum_pass "Wasabi daily backup"  "cron installed" || sum_skip "Wasabi daily backup"
    [[ -x /usr/local/bin/cloudflare-dns ]]        && sum_pass "Cloudflare DDNS"      "installed" || sum_skip "Cloudflare DDNS"
    [[ -f /etc/fail2ban/action.d/abuseipdb.conf ]] && sum_pass "AbuseIPDB reporting" "active" || sum_skip "AbuseIPDB reporting"

    echo
    echo -e "${MAG}── Summary ──${NC}"
    echo -e "  ${GREEN}✓ ${SUM_OK} OK${NC}   ${RED}✗ ${SUM_FAIL} failed${NC}   ${YELLOW}- ${SUM_SKIP} skipped${NC}"
    echo

    if [[ $SUM_FAIL -gt 0 ]]; then
        warn "Some required components failed. Review the log above before reboot."
    else
        log "All required components installed successfully."
    fi

    write_detailed_summary

    info "Live log     : $LOGFILE"
    info "Full summary : $SUMMARY_FILE"
    echo
}

# ── Detailed plain-text summary file ────────────────────────────────────────
_st()    { command "$@" 2>/dev/null || echo "n/a"; }   # safe try
_v_or()  { local val; val="$(_st "$@")"; [[ -n "$val" ]] && echo "$val" || echo "n/a"; }
_check() {
    # _check "Label" cmd args... -> "Label .......... yes|no"
    local label="$1"; shift
    if "$@" &>/dev/null; then echo "$label: yes"; else echo "$label: no"; fi
}

write_detailed_summary() {
    local pub_ip local_ip tz fw_state fail2ban_state ntp_state
    pub_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo unknown)
    local_ip=$(ip -4 addr show | awk '/inet/ && $2!~/^127/{print $2; exit}' | cut -d/ -f1)
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)
    case "$FW_TOOL" in
        ufw)       fw_state=$(ufw status 2>/dev/null | head -1 | awk -F: '{print $2}' | xargs || echo unknown) ;;
        firewalld) systemctl is-active --quiet firewalld && fw_state=active || fw_state=inactive ;;
        *)         fw_state=unknown ;;
    esac
    systemctl is-active --quiet fail2ban 2>/dev/null && fail2ban_state=running || fail2ban_state="not running"
    if systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
        ntp_state="chrony active"
    elif systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        ntp_state="systemd-timesyncd active"
    else
        ntp_state="inactive"
    fi

    {
    cat <<HEADER
================================================================================
RHLinuxConfig — Detailed Setup Summary
RHC Solutions  ·  rhcsolutions.com  ·  t.me/rhcsolutions
================================================================================
Run timestamp     : $(date '+%Y-%m-%d %H:%M:%S %Z')
Run mode          : ${RUN_MODE:-interactive}
Live log file     : $LOGFILE
Summary file      : $SUMMARY_FILE

──────────────────────────────────────────────────────────────────────────────
SYSTEM
──────────────────────────────────────────────────────────────────────────────
Hostname          : $(hostname -f 2>/dev/null || hostname)
Distribution      : $OS_ID $OS_VERSION_ID ($OS_FAMILY family)
Kernel            : $(uname -r)
Architecture      : $ARCH
CPU               : $(lscpu 2>/dev/null | awk -F: '/Model name/{print $2}' | xargs)
Cores             : $(nproc 2>/dev/null)
Memory total      : $(free -h 2>/dev/null | awk '/^Mem/{print $2}')
Disk root total   : $(df -h / 2>/dev/null | awk 'NR==2{print $2}')
Public IP         : $pub_ip
Local IP          : $local_ip
Timezone          : $tz   ${DETECTED_CITY:+(detected via ipinfo.io: $DETECTED_CITY, $DETECTED_COUNTRY)}
Date/time         : $(date '+%Y-%m-%d %H:%M:%S %Z')

──────────────────────────────────────────────────────────────────────────────
CORE TOOLCHAIN
──────────────────────────────────────────────────────────────────────────────
Midnight Commander: $(_v_or mc --version 2>/dev/null | head -1)
Node.js           : $(_v_or node --version)
npm               : $(_v_or npm --version)
Git               : $(_v_or git --version | awk '{print $3}')
Python 3          : $(_v_or python3 --version | awk '{print $2}')
opencode          : $(if command -v opencode &>/dev/null; then opencode --version 2>/dev/null | head -1; elif [[ -x /root/.opencode/bin/opencode ]]; then /root/.opencode/bin/opencode --version 2>/dev/null | head -1; else echo "not installed"; fi)
Claude Code       : $(_v_or claude --version | head -1)
Ookla speedtest   : $(if command -v speedtest &>/dev/null && speedtest --version 2>/dev/null | grep -qi 'Speedtest by Ookla'; then speedtest --version | head -1; else echo "not installed"; fi)
netperf           : $(_check "" command -v netperf | sed 's/.* /  /;s/^  /installed: /;s/installed: yes/yes/;s/installed: no/no/')
iperf3            : $(_check "" command -v iperf3 | sed 's/.* /  /;s/^  /installed: /;s/installed: yes/yes/;s/installed: no/no/')

──────────────────────────────────────────────────────────────────────────────
SECURITY
──────────────────────────────────────────────────────────────────────────────
Firewall          : $FW_TOOL ($fw_state)
Fail2Ban          : $fail2ban_state
NTP / time sync   : $ntp_state
Root SSH login    : $(grep -E '^[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo unset)
AbuseIPDB action  : $([[ -f /etc/fail2ban/action.d/abuseipdb.conf ]] && echo "installed" || echo "not configured")

──────────────────────────────────────────────────────────────────────────────
USERS
──────────────────────────────────────────────────────────────────────────────
odin user         : $(id odin &>/dev/null && echo "exists (groups: $(id -nG odin 2>/dev/null | tr ' ' ','))" || echo "not created")
odin sudoers      : $([[ -f /etc/sudoers.d/odin ]] && echo "/etc/sudoers.d/odin (NOPASSWD)" || echo "not configured")
SSH keys (odin)   : $([[ -f /home/odin/.ssh/authorized_keys ]] && wc -l < /home/odin/.ssh/authorized_keys | awk '{print $1" key(s)"}' || echo "none")

──────────────────────────────────────────────────────────────────────────────
NETWORK
──────────────────────────────────────────────────────────────────────────────
Default interface : $(ip route 2>/dev/null | awk '/default/{print $5; exit}')
Default gateway   : $(ip route 2>/dev/null | awk '/default/{print $3; exit}')
DNS servers       : $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
IP config method  : $(if grep -lq 'BOOTPROTO=static' /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null \
                          || grep -lq 'dhcp4: false' /etc/netplan/*.yaml 2>/dev/null; then
                      echo "static"
                    else echo "DHCP"; fi)

──────────────────────────────────────────────────────────────────────────────
CLOUD INTEGRATIONS
──────────────────────────────────────────────────────────────────────────────
Telegram notifier : $([[ -x /usr/local/bin/telegram-notify ]] && echo "installed at /usr/local/bin/telegram-notify" || echo "not configured")
Wasabi S3 creds   : $([[ -f /root/.aws/credentials ]] && echo "/root/.aws/credentials" || echo "not configured")
Wasabi bucket     : $({ [[ -f /etc/profile.d/wasabi.sh ]] && grep WASABI_BUCKET /etc/profile.d/wasabi.sh | cut -d= -f2; } || echo "n/a")
Wasabi auto-backup: $([[ -f /etc/cron.daily/wasabi-autobackup ]] && echo "daily (/etc/cron.daily/wasabi-autobackup)" || echo "not configured")
Cloudflare DDNS   : $([[ -x /usr/local/bin/cloudflare-dns ]] && echo "installed (hourly cron: $([[ -f /etc/cron.hourly/cloudflare-dns ]] && echo yes || echo no))" || echo "not configured")
Cloudflare record : $({ [[ -f /etc/profile.d/cloudflare.sh ]] && grep CF_NAME /etc/profile.d/cloudflare.sh | cut -d= -f2; } || echo "n/a")

──────────────────────────────────────────────────────────────────────────────
INSTALLED HELPER COMMANDS
──────────────────────────────────────────────────────────────────────────────
$([[ -x /usr/local/bin/telegram-notify ]] && echo "  /usr/local/bin/telegram-notify  — send Telegram alerts")
$([[ -x /usr/local/bin/wasabi-backup ]]   && echo "  /usr/local/bin/wasabi-backup    — manual S3 upload")
$([[ -x /usr/local/bin/wasabi-autobackup ]] && echo "  /usr/local/bin/wasabi-autobackup — daily backup runner")
$([[ -x /usr/local/bin/cloudflare-dns ]]  && echo "  /usr/local/bin/cloudflare-dns   — DDNS updater")
$([[ -x /usr/local/bin/speedtest ]]       && echo "  /usr/local/bin/speedtest        — Ookla speedtest CLI")

──────────────────────────────────────────────────────────────────────────────
RESULTS
──────────────────────────────────────────────────────────────────────────────
OK (passed checks): ${SUM_OK}
Failed checks     : ${SUM_FAIL}
Skipped/optional  : ${SUM_SKIP}
Extras installed  : ${EXTRAS_OK:-0}
Extras unavailable: ${EXTRAS_FAIL:-0}${EXTRAS_FAILED_LIST:+
Extras skipped    :${EXTRAS_FAILED_LIST}}

──────────────────────────────────────────────────────────────────────────────
NEXT STEPS
──────────────────────────────────────────────────────────────────────────────
1. Reboot to apply kernel updates and group memberships (sudo reboot).
2. Open a new shell so updated PATH (/etc/profile.d/*.sh) is loaded.
3. Verify the firewall accepts SSH before logging out:  sudo ${FW_TOOL} status
4. Confirm Fail2Ban is active:  sudo fail2ban-client status
$([[ -x /usr/local/bin/telegram-notify ]] && echo "5. Test Telegram:  telegram-notify info \"hello\"")
$([[ -x /usr/local/bin/wasabi-backup ]]   && echo "6. Test Wasabi:    wasabi-backup /etc test")
$([[ -x /usr/local/bin/cloudflare-dns ]]  && echo "7. Test DDNS:      cloudflare-dns")
$(command -v speedtest &>/dev/null         && echo "8. Test bandwidth: speedtest")

================================================================================
Generated by rhlinuxconfig.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')
================================================================================
HEADER
    } > "$SUMMARY_FILE"

    chmod 644 "$SUMMARY_FILE" "$LOGFILE" 2>/dev/null || true
}

# ═══════════════════════════ M A I N ═════════════════════════════════════════

echo -e "${CYAN}"
cat << "EOF"
 ____  _   _  ____    ____        _       _   _
|  _ \| | | |/ ___|  / ___|  ___ | |_   _| |_(_) ___  _ __  ___
| |_) | |_| | |      \___ \ / _ \| | | | | __| |/ _ \| '_ \/ __|
|  _ <|  _  | |___    ___) | (_) | | |_| | |_| | (_) | | | \__ \
|_| \_\_| |_|\____|  |____/ \___/|_|\__,_|\__|_|\___/|_| |_|___/
EOF
echo -e "${NC}"
echo "  RHC Solutions  ·  rhcsolutions.com  ·  t.me/rhcsolutions"
echo "  RHLinuxConfig — Universal Linux Setup & Hardening Wizard"
echo "  $(date)"
echo

detect_distro
auto_set_location
show_info

# ── Run modes ────────────────────────────────────────────────────────────────
if [[ $# -eq 1 && "$1" == "--quick" ]]; then
    RUN_MODE="quick"
    header "QUICK MODE"
    do_update
    do_install
    do_install_mc
    do_install_extras
    do_install_nettest
    do_install_latest
    show_summary
    log "Quick mode done."
    exit 0
fi

if [[ $# -eq 1 && "$1" == "--unattended" ]]; then
    RUN_MODE="unattended"
    header "UNATTENDED MODE"
    do_update
    do_install
    do_install_mc
    do_install_extras
    do_install_nettest
    do_install_latest
    do_install_opencode
    do_install_claude
    setup_firewall
    setup_fail2ban
    show_summary
    auto_reboot
    exit 0
fi

# ── Wizard: Interactive Setup ────────────────────────────────────────────────
RUN_MODE="interactive"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Welcome to the RHLinuxConfig Setup Wizard!              ${NC}"
echo -e "${YELLOW}  Detected: $OS_ID $OS_VERSION_ID ($OS_FAMILY)          ${NC}"
echo -e "${YELLOW}  Press Enter to accept defaults shown in [brackets].     ${NC}"
echo -e "${YELLOW}  Timeouts: [Y/n] → ${AUTO_YES_TIMEOUT}s · [y/N] → ${AUTO_NO_TIMEOUT}s · text → ${AUTO_TEXT_TIMEOUT}s  ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo

do_update
do_install
do_install_mc
do_install_extras
do_install_nettest
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
auto_reboot
