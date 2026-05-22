# RHLinuxConfig

Universal Linux server setup & hardening wizard — for any fresh Ubuntu/Debian box.

## Quick Start

```bash
sudo bash setup.sh                   # Full interactive wizard (recommended)
sudo bash setup.sh --quick           # Info + update + base tools only
sudo bash setup.sh --unattended      # Full setup with no prompts
```

## Wizard Mode

The script runs as an interactive wizard — each step explains what's needed and asks questions.

| Step | Description |
|------|-------------|
| **1. Info** | Displays OS, kernel, CPU, RAM, disk, network interfaces, public IP, DNS |
| **2. Update** | `apt update && apt full-upgrade && autoremove` |
| **3. Tools** | curl, wget, htop, mc, ncdu, btop, iftop, iotop, nethogs, sysstat, dstat, iperf3, smartmontools, screen, tmux, jq, rsync, build-essential |
| **4. Latest Runtimes** | **Node.js** (LTS via NodeSource), **Git** (latest PPA), **Python** (latest via deadsnakes) |
| **5. opencode** | Installs `@opencode-ai/opencode` globally via npm, configures PATH in `/etc/profile.d/` |
| **6. Claude Code** | Installs `@anthropic-ai/claude-code` globally via npm, configures PATH in `/etc/profile.d/` |
| **7. Static IP** | Guides you from DHCP to static — asks for IP, netmask, gateway, DNS; writes netplan or `/etc/network/interfaces` |
| **8. Root Account** | Generates & shows a random root password, optionally disables root SSH login (`PermitRootLogin no`) |
| **9. odin User** | Creates `odin` with passwordless sudo, copies root SSH keys, **generates & displays password on screen** |
| **10. Telegram** | Explains how to get a Bot Token from @BotFather and Chat ID, validates the token, sends a test message, installs `telegram-notify` |
| **11. Wasabi S3** | Explains how to get Wasabi keys, asks for credentials/bucket/region, validates connection, installs AWS CLI + `wasabi-backup` helper |
| **12. Wasabi Auto-Backup** | Creates daily cron backup of `/home`, `/etc`, `/root`, `/var/log`, `/var/www` to Wasabi using `aws s3 sync` (incremental + delete) |
| **13. UFW** | Default deny incoming, allow SSH + optionally HTTP/HTTPS |
| **14. Fail2Ban** | SSH, SSH-DDoS, UFW jails + optional AbuseIPDB (fetches action from official repo) |

## Auto-Backup Details

When configured, runs daily at 6:25 AM via `/etc/cron.daily/wasabi-autobackup`:

| Local Path | S3 Destination |
|-----------|---------------|
| `/home` | `s3://bucket/system/home/` |
| `/etc` | `s3://bucket/system/config/` |
| `/root` | `s3://bucket/system/root/` |
| `/var/log` | `s3://bucket/system/logs/` |
| `/var/www` | `s3://bucket/system/www/` |

Uses `aws s3 sync` for efficient incremental backups. Logs to `/var/log/wasabi-backup.log`.

## Post-Install Helpers

```bash
# Send a Telegram alert
telegram-notify info "Server is online"
telegram-notify alert "CPU > 90%"

# Manual backup to Wasabi
wasabi-backup /var/www         # timestamped copy
wasabi-backup /etc configs

# Run the auto-backup anytime
/usr/local/bin/wasabi-autobackup
```

## Run Modes

| Command | What it does |
|---------|-------------|
| `sudo bash setup.sh` | Full wizard — asks all questions interactively |
| `sudo bash setup.sh --quick` | Info + update + tools only, no prompts |
| `sudo bash setup.sh --unattended` | Full install, no prompts (skips wizard questions, Telegram, Wasabi, UFW/Fail2Ban) |

## Requirements

- Ubuntu 20.04+ / Debian 11+
- Run as `root` or with `sudo`
