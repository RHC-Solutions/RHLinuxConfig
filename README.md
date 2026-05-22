# RHLinuxConfig

Universal Linux server setup & hardening wizard supporting **AlmaLinux, Rocky, CentOS, Debian, Ubuntu, Arch Linux, Linux Mint, and SUSE**.

## Quick Start

```bash
sudo bash setup.sh                   # Full interactive wizard
sudo bash setup.sh --quick           # Info + update + base tools only
sudo bash setup.sh --unattended      # Full setup with no prompts
```

## Supported Distros

| Family | Distros |
|--------|---------|
| **Debian** | Ubuntu, Debian, Linux Mint (uses `apt`) |
| **RHEL** | AlmaLinux, Rocky Linux, CentOS, RHEL (uses `dnf` + EPEL) |
| **Arch** | Arch Linux, Manjaro, EndeavourOS (uses `pacman`) |
| **SUSE** | openSUSE, SLES (uses `zypper`) |

Auto-detects your OS and adapts package names, firewall, network config, and defaults.

## Wizard Steps

| Step | Description |
|------|-------------|
| **1. Detect** | Identifies OS family, sets package manager & distro-specific variables |
| **2. Info** | Displays OS, kernel, CPU, RAM, disk, network interfaces, public IP |
| **3. Update** | Distro-native update (`apt`, `dnf`, `pacman -Syu`, or `zypper`) |
| **4. Tools** | curl, wget, htop, mc, ncdu, btop, iftop, iotop, nethogs, sysstat, dstat, iperf3, smartmontools, screen, tmux, jq, rsync, git, build tools, firewall, fail2ban |
| **5. Latest** | **Node.js** (NodeSource — works on all distros), **Git** (PPA on Debian, otherwise distro), **Python** (deadsnakes on Debian, EPEL on RHEL, distro on Arch/SUSE) |
| **6. opencode** | Installs `@opencode-ai/opencode` globally via npm, PATH in `/etc/profile.d/` |
| **7. Claude Code** | Installs `@anthropic-ai/claude-code` via npm, PATH config |
| **8. Static IP** | **Debian**: netplan or `/etc/network/interfaces` · **RHEL**: `/etc/sysconfig/network-scripts/ifcfg-*` · **Arch**: systemd-networkd · **SUSE**: `/etc/sysconfig/network/ifcfg-*` |
| **9. Root** | Change root password, disable root SSH login |
| **10. odin User** | Creates `odin` with passwordless sudo + `$DEV_GROUP`, generates & shows password |
| **11. Telegram** | Bot token + Chat ID, validates token, sends test message |
| **12. Wasabi S3** | Credentials + bucket, validates connection, `wasabi-backup` helper |
| **13. Auto-Backup** | Daily `cron.daily` backup of `/home`, `/etc`, `/root`, `/var/log`, `/var/www` to Wasabi via `aws s3 sync` |
| **14. Cloudflare DNS** | API token + zone + record name, validates token, creates `cloudflare-dns` updater, optional hourly cron |
| **15. Firewall** | **Debian/Arch**: UFW · **RHEL/SUSE**: firewalld |
| **16. Fail2Ban** | SSH, SSH-DDoS, firewall jails + optional AbuseIPDB |

## Post-Install Helpers

```bash
# Send a Telegram alert
telegram-notify info "Server is online"
telegram-notify alert "CPU > 90%"

# Manual backup to Wasabi
wasabi-backup /var/www
wasabi-backup /etc configs

# Run the auto-backup
/usr/local/bin/wasabi-autobackup

# Update Cloudflare DNS A record to current IP
cloudflare-dns
cloudflare-dns --ip 203.0.113.10    # specify IP manually
```

## Requirements

- **Any**: AlmaLinux 8+, Rocky 8+, CentOS 7+, Debian 11+, Ubuntu 20.04+, Arch, Mint 21+, openSUSE 15+
- Run as `root` or with `sudo`
