# RHC Solutions

```text
 ____  _   _  ____    ____        _       _   _
|  _ \| | | |/ ___|  / ___|  ___ | |_   _| |_(_) ___  _ __  ___
| |_) | |_| | |      \___ \ / _ \| | | | | __| |/ _ \| '_ \/ __|
|  _ <|  _  | |___    ___) | (_) | | |_| | |_| | (_) | | | \__ \
|_| \_\_| |_|\____|  |____/ \___/|_|\__,_|\__|_|\___/|_| |_|___/
```

**Website:** [rhcsolutions.com](https://rhcsolutions.com) &nbsp;·&nbsp; **Telegram:** [t.me/rhcsolutions](https://t.me/rhcsolutions)

---

## RHLinuxConfig

Universal Linux server setup & hardening wizard. One script, every major distro — automatically detects your OS, sets timezone from your public IP, installs a curated toolchain, hardens the system, and wires up optional cloud integrations (Telegram, Wasabi, Cloudflare).

Supports **AlmaLinux, Rocky, CentOS, RHEL, Debian, Ubuntu, Linux Mint, Arch, Manjaro, openSUSE, SLES**.

Prompts during the interactive wizard **auto-accept "yes" after 5 seconds** of inactivity — walk away and the install completes itself with sensible defaults.

---

## Installation

One command. Run as root on a fresh server:

```bash
curl -fsSL https://raw.githubusercontent.com/RHC-Solutions/RHLinuxConfig/main/rhlinuxconfig.sh | sudo bash
```

Add `--quick` or `--unattended` (see [Run Modes](#run-modes)):

```bash
curl -fsSL https://raw.githubusercontent.com/RHC-Solutions/RHLinuxConfig/main/rhlinuxconfig.sh | sudo bash -s -- --unattended
```

---

## Run Modes

| Command | What it runs |
|---------|--------------|
| `sudo ./rhlinuxconfig.sh` | **Full interactive wizard** — everything, with prompts for cloud integrations |
| `sudo ./rhlinuxconfig.sh --quick` | Info + update + base tools + `mc` + Node/Git/Python only (no prompts) |
| `sudo ./rhlinuxconfig.sh --unattended` | Everything **except** wizards (no static IP, no users, no cloud) |

`--unattended` is safe for CI / image-baking. `--quick` is the fastest "fresh box → usable shell" path.

---

## Supported Distros

| Family | Distros | Package mgr | Firewall | Sudo group |
| ------ | ------- | :---------: | :------: | :--------: |
| **Debian** | Ubuntu, Debian, Linux Mint | `apt` | UFW | `sudo` |
| **RHEL** | AlmaLinux, Rocky, CentOS, RHEL, Fedora, Oracle | `dnf` + EPEL | firewalld | `wheel` |
| **Arch** | Arch, Manjaro, EndeavourOS, Garuda | `pacman` | UFW | `wheel` |
| **SUSE** | openSUSE, SLES | `zypper` | firewalld | `wheel` |

Detection falls back to `ID_LIKE` for unknown derivatives. All package names, network-config files, and firewall commands adapt automatically.

---

## What the Script Does

### Automatic (every mode)
| # | Step | Detail |
|---|------|--------|
| 0 | **Detect distro** | Family, version, package manager, firewall tool, sudo group |
| 1 | **Auto-locate** | Queries `ipinfo.io` → sets timezone via `timedatectl`, enables chrony / systemd-timesyncd, immediate `chronyc makestep` |
| 2 | **System info** | Hostname, OS, kernel, CPU, RAM, disks, NICs, public IP, DNS |

### Install phase
| # | Step | Detail |
|---|------|--------|
| 3 | **Full upgrade** | `apt`, `dnf`, `pacman -Syu`, or `zypper` — with autoremove |
| 4 | **Base tools** | `curl wget htop ncdu btop iftop iotop nethogs net-tools smartmontools sysstat dstat iperf3 mtr screen tmux unzip zip gpg jq tree rsync` + build essentials + `lm-sensors` + `fail2ban` + firewall pkg |
| 5 | **Midnight Commander** | Installs `mc`, sets `mcedit` as `$EDITOR` system-wide via `/etc/profile.d/mc.sh`, registers with `update-alternatives` |
| 6 | **Latest Node / Git / Python** | Node LTS via NodeSource · Git via `ppa:git-core/ppa` on Debian · Python via deadsnakes/EPEL |
| 7 | **opencode** | `npm i -g @opencode-ai/opencode` + PATH in `/etc/profile.d/opencode.sh` |
| 8 | **Claude Code** | `npm i -g @anthropic-ai/claude-code` + PATH in `/etc/profile.d/claude-code.sh` |

### Interactive wizards (full mode only)
| # | Step | Detail |
|---|------|--------|
| 9 | **Static IP** | netplan / `/etc/network/interfaces` / ifcfg / systemd-networkd depending on distro |
| 10 | **Root lockdown** | Generates new root password, sets `PermitRootLogin no`, restarts sshd |
| 11 | **`odin` user** | Sudo-enabled admin (`NOPASSWD`), generated password, copies root's `authorized_keys` |
| 12 | **Telegram** | Bot token + chat ID → `/usr/local/bin/telegram-notify` |
| 13 | **Wasabi S3** | Creds in `~/.aws/credentials`, validates bucket, installs `wasabi-backup` |
| 14 | **Daily auto-backup** | `cron.daily` sync of `/home /etc /root /var/log /var/www` to Wasabi |
| 15 | **Cloudflare DDNS** | API token + zone + record → `cloudflare-dns` script + hourly cron |
| 16 | **Firewall** | UFW or firewalld — deny incoming, allow SSH, prompts for 80/443 |
| 17 | **Fail2Ban** | SSH + SSH-DDoS + firewall jails, optional AbuseIPDB reporting |

---

## Post-Install Commands

After the script finishes, these helpers are on `$PATH`:

```bash
# Telegram alerts
telegram-notify info  "Server online"
telegram-notify alert "Disk > 90%"
echo "$something" | telegram-notify warn       # stdin works too

# Wasabi S3 backups
wasabi-backup /var/www                          # one-shot
wasabi-backup /etc configs                      # with prefix
/usr/local/bin/wasabi-autobackup                # run the daily job manually

# Cloudflare DDNS
cloudflare-dns                                  # auto-detect public IP
cloudflare-dns --ip 203.0.113.10                # specify IP

# Midnight Commander
mc                                              # mouse + xterm enabled via alias
mcedit /etc/hosts                               # default $EDITOR after install
```

---

## File Layout (where things land)

```
/usr/local/bin/telegram-notify        # Telegram helper
/usr/local/bin/wasabi-backup          # Manual S3 upload
/usr/local/bin/wasabi-autobackup      # Daily backup runner
/usr/local/bin/cloudflare-dns         # DDNS updater

/etc/profile.d/mc.sh                  # EDITOR=mcedit, mc aliases
/etc/profile.d/opencode.sh            # opencode PATH
/etc/profile.d/claude-code.sh         # claude PATH
/etc/profile.d/wasabi.sh              # WASABI_BUCKET / WASABI_REGION
/etc/profile.d/cloudflare.sh          # CF_TOKEN / CF_ZONE / CF_NAME / CF_TTL / CF_PROXIED

/etc/cron.daily/wasabi-autobackup     # Backup cron
/etc/cron.hourly/cloudflare-dns       # DDNS cron

/etc/fail2ban/jail.local              # SSH + firewall jails
/etc/fail2ban/action.d/abuseipdb.conf # (if AbuseIPDB key given)

/etc/sudoers.d/odin                   # odin = passwordless sudo
/root/.aws/credentials                # Wasabi keys (chmod 600)
/var/log/wasabi-backup.log            # Daily backup log
```

---

## Requirements

- **OS**: AlmaLinux 8+, Rocky 8+, CentOS 7+, RHEL 7+, Debian 11+, Ubuntu 20.04+, Mint 21+, openSUSE 15+, Arch (any current)
- **Privileges**: must run as `root` (or via `sudo`)
- **Network**: internet access for package mirrors, ipinfo.io, NodeSource, npm, NTP
- **Optional accounts**: Telegram bot, Wasabi S3, Cloudflare API token, AbuseIPDB API key

---

## Customizing / Extending

The script is a single Bash file — read top-to-bottom, all functions are commented. Key extension points:

- **Add a package to the base install** → append to `PACKAGES_CORE` near the top of the script
- **Change firewall ports prompted** → edit the loop in `setup_firewall()`
- **Skip a wizard step** → comment out the corresponding line in the `# Wizard: Interactive Setup` block at the bottom
- **Add a custom step** → write a `setup_foo()` function and call it from the main flow

Distro-specific behavior lives in `case "$OS_FAMILY"` blocks — add a new arm (e.g. `gentoo`) and the rest of the script picks it up.

---

## Troubleshooting

| Symptom | Try |
|---------|-----|
| ipinfo.io step warns "unreachable" | Check outbound HTTPS / DNS. Script continues; set timezone manually with `timedatectl set-timezone Europe/Berlin` |
| `claude` not in `$PATH` after install | `source /etc/profile.d/claude-code.sh` or open a new shell |
| Locked out via UFW after enabling | Boot single-user, `ufw allow ssh && ufw reload` |
| Telegram test message fails | Token from `@BotFather` correct? Did you `/start` the bot in a DM first to get the chat ID? |
| Wasabi backup says bucket inaccessible | Check region — endpoint is `s3.<region>.wasabisys.com`, default is `us-east-1` |
| Cloudflare DDNS "Update failed" | Token needs **DNS:Edit** for the specific zone, not just account-level |

Logs:
- Wasabi daily backup → `/var/log/wasabi-backup.log`
- Fail2Ban → `journalctl -u fail2ban`
- Cloudflare cron → `journalctl -t CRON | grep cloudflare`

---

## Safety Notes

- The script **changes the root password** if you accept the prompt — write it down (or copy the generated `odin` password) before logging out.
- `wizard_static_ip` rewrites network config files; you can lose connectivity if the IP/gateway is wrong. Have console access ready.
- `--unattended` skips wizards but **does** enable firewall + fail2ban. SSH stays open; nothing else.
- Generated passwords are printed once to the terminal and not stored anywhere. Capture them at the time.

---

## License

MIT.
