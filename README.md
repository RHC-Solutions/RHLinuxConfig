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

Prompts during the interactive wizard show a **live `[Ns]` countdown** next to each question. Safe `[Y/n]` confirmations auto-accept after 60 s; opt-in `[y/N]` prompts (cloud integrations, static IP, etc.) auto-decline after 60 s; text prompts fall back to the bracketed default after 60 s. Walk away and the install completes itself with sensible defaults. Override per-run with `AUTO_YES_TIMEOUT`, `AUTO_NO_TIMEOUT`, `AUTO_TEXT_TIMEOUT` env vars (`0` = wait forever).

A **global progress bar** prints after each step in every mode — `Progress [██████████░░░░░] 47% (7/15) Network test tools` — so you always know how far through the run you are. The total adapts to the mode (quick / unattended / full).

---

## Installation

**Two-step install** (recommended — handles sudo password and the script's interactive prompts cleanly):

```bash
curl -fsSL https://raw.githubusercontent.com/RHC-Solutions/RHLinuxConfig/main/rhlinuxconfig.sh -o /tmp/rhlinuxconfig.sh
sudo bash /tmp/rhlinuxconfig.sh
```

For non-interactive or quick mode add the flag to the second line:

```bash
sudo bash /tmp/rhlinuxconfig.sh --unattended   # or --quick
```

### Why not `curl … | sudo bash`?

That one-liner pattern is fragile here because `sudo` needs to prompt for a password while `curl` is still writing to the pipe. Symptoms include the password prompt appearing to hang, or `curl: (23) Failure writing output to destination` after Ctrl-C. Download first, then run — it's two short lines and works on every distro.

If you're root already, you can run it directly:

```bash
curl -fsSL https://raw.githubusercontent.com/RHC-Solutions/RHLinuxConfig/main/rhlinuxconfig.sh | bash
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

Detection falls back to `ID_LIKE` for unknown derivatives. All package names, network-config files, and firewall commands adapt automatically. The **Firewall** column is the default backend; the firewall step also supports **iptables** (auto-fallback when ufw/firewalld is absent) and honors a `FW_TOOL=ufw|firewalld|iptables` override.

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
| 3 | **Full upgrade** | `apt`, `dnf`, `pacman -Syu`, or `zypper` — with autoremove. On Debian, any leftover `deb cdrom:` source from a DVD install is auto-disabled; if no usable net repo exists, default `deb.debian.org` / `archive.ubuntu.com` mirrors are written for the detected suite. |
| 4 | **Base tools** | `curl wget htop glances mc ncdu btop iftop iotop nethogs net-tools smartmontools sysstat dstat iperf3 mtr screen tmux unzip zip gpg jq tree rsync` + build essentials + `lm-sensors` + `fail2ban` + firewall pkg. Packages not in the distro's index are warned + skipped, never abort the run. |
| 5 | **Midnight Commander** | Installs `mc`, sets `mcedit` as `$EDITOR` system-wide via `/etc/profile.d/mc.sh`, registers with `update-alternatives`. |
| 6 | **tmux defaults** | Lays down `/etc/tmux.conf` (mouse on, 256-colour, 50k scrollback, vi mode, base-index 1, `prefix \|` / `prefix -` splits, `prefix r` reload) and `/etc/profile.d/tmux.sh` (`t`, `ta`, `tls` aliases). Users override via `~/.tmux.conf`. |
| 7 | **Extended toolkit** | Best-effort install of `perl vim nano atop nmon traceroute telnet lynx plocate mlocate nload bmon tcptrack vnstat ifstat darkstat` and distro-specific extras (netcat, snmp, iptraf-ng, ntopng, …). |
| 8 | **Network test tools** | Dedicated step for `iperf3`, `netperf`, `speedtest-cli` (with `pip3` fallback), and Ookla's official `speedtest` CLI (static binary from `install.speedtest.net`). Each tool logs its own success/skip line. |
| 9 | **Latest Node / Git / Python** | Node LTS via NodeSource · Git via `ppa:git-core/ppa` on Debian · Python via deadsnakes/EPEL. |
| 10 | **opencode** | `npm i -g @opencode-ai/opencode` + PATH in `/etc/profile.d/opencode.sh`. |
| 11 | **Claude Code** | `npm i -g @anthropic-ai/claude-code` + PATH in `/etc/profile.d/claude-code.sh`. |
| 12 | **Codex CLI** | `npm i -g @openai/codex` (OpenAI Codex CLI, binary `codex`). |
| 13 | **Gemini CLI** | `npm i -g @google/gemini-cli` (Google Gemini CLI, binary `gemini`). |
| 14 | **Node + global modules refresh** | Bumps `npm` itself, then runs `npm update -g` so every globally installed package (opencode, claude-code, codex, gemini-cli, anything else) is at its latest semver. Prints the before/after `npm list -g --depth=0` so you can see what moved. |

### Interactive wizards (full mode only)
| # | Step | Detail |
|---|------|--------|
| 15 | **Static IP** | netplan / `/etc/network/interfaces` / ifcfg / systemd-networkd depending on distro. If a static IP is **already configured** (NetworkManager `manual`, netplan `dhcp4: false`, `inet static`, `BOOTPROTO=static/none`, or a systemd-networkd `Address=`), the wizard skips the prompt and leaves the network untouched — the active address and method are shown in the final status block. |
| 16 | **Root lockdown** | Generates new root password, sets `PermitRootLogin no`, restarts sshd |
| 17 | **`odin` user** | Sudo-enabled admin (`NOPASSWD`), generated password, copies root's `authorized_keys` |
| 18 | **Telegram** | Bot token + chat ID → `/usr/local/bin/telegram-notify` |
| 19 | **Wasabi S3** | Creds in `~/.aws/credentials`, validates bucket, installs `wasabi-backup` |
| 20 | **Daily auto-backup** | `cron.daily` sync of `/home /etc /root /var/log /var/www` to Wasabi |
| 21 | **Cloudflare DDNS** | API token + zone + record → `cloudflare-dns` script + hourly cron |
| 22 | **Disable IPv6** | Writes `/etc/sysctl.d/99-rhlc-disable-ipv6.conf` (all/default/lo `disable_ipv6 = 1`), applies immediately via `sysctl --system`, and sets `ip6tables` to DROP. IPv4-only, no reboot, reversible by deleting the drop-in. |
| 23 | **Firewall** | **ufw / firewalld / iptables** (auto-detected per distro; falls back to iptables and installs it if neither is present; override with `FW_TOOL=…`). Default-deny inbound. **Prompts for admin IP(s)** (pre-filled with your current SSH client) and allows **SSH only from those** sources. **443/tcp** is opened **only from [Cloudflare's published IPv4 ranges](https://www.cloudflare.com/ips-v4)** plus the admin IPs. **Port 80 is never opened.** iptables rules are persisted per-distro. |
| 24 | **Fail2Ban** | SSH + SSH-DDoS + firewall jails, optional AbuseIPDB reporting. Ban action matches the backend (`ufw` / `firewallcmd-rich-rules` / `iptables-multiport`). |

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

# tmux (system defaults from /etc/tmux.conf — users override via ~/.tmux.conf)
t                                               # alias for tmux
ta                                              # attach if a session exists, otherwise new
tls                                             # list sessions
# Inside tmux: prefix |/-  split panes; prefix r  reload /etc/tmux.conf

# System monitor
glances                                         # top alternative, also exposes a REST API
```

---

## File Layout (where things land)

```
/usr/local/bin/telegram-notify        # Telegram helper
/usr/local/bin/wasabi-backup          # Manual S3 upload
/usr/local/bin/wasabi-autobackup      # Daily backup runner
/usr/local/bin/cloudflare-dns         # DDNS updater

/etc/tmux.conf                        # System-wide tmux defaults (mouse, 256-colour, vi mode, base-1)
/etc/profile.d/tmux.sh                # t / ta / tls aliases
/etc/profile.d/mc.sh                  # EDITOR=mcedit, mc aliases
/etc/profile.d/opencode.sh            # opencode PATH
/etc/profile.d/claude-code.sh         # claude PATH
/etc/profile.d/wasabi.sh              # WASABI_BUCKET / WASABI_REGION
/etc/profile.d/cloudflare.sh          # CF_TOKEN / CF_ZONE / CF_NAME / CF_TTL / CF_PROXIED

/etc/cron.daily/wasabi-autobackup     # Backup cron
/etc/cron.hourly/cloudflare-dns       # DDNS cron

/etc/fail2ban/jail.local              # SSH + firewall jails
/etc/fail2ban/action.d/abuseipdb.conf # (if AbuseIPDB key given)

/etc/sysctl.d/99-rhlc-disable-ipv6.conf  # IPv6 off (delete to restore)
/etc/rhlc/cloudflare-ips-v4.txt          # cached Cloudflare IPv4 ranges (443 allow-list)
/etc/iptables/rules.v4 · /etc/sysconfig/iptables  # persisted iptables rules (when FW_TOOL=iptables)

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
- **Change the firewall policy** (ports, allowed sources, backends) → edit `setup_firewall()` and the `_fw_*` helpers
- **Refresh the Cloudflare IP allow-list** → re-run the firewall step; ranges are fetched from `cloudflare.com/ips-v4` and cached at `/etc/rhlc/cloudflare-ips-v4.txt`
- **Re-enable IPv6** → delete `/etc/sysctl.d/99-rhlc-disable-ipv6.conf` and run `sysctl --system` (reboot to be safe)
- **Skip a wizard step** → comment out the corresponding line in the `# Wizard: Interactive Setup` block at the bottom
- **Add a custom step** → write a `setup_foo()` function and call it from the main flow

Distro-specific behavior lives in `case "$OS_FAMILY"` blocks — add a new arm (e.g. `gentoo`) and the rest of the script picks it up.

---

## Troubleshooting

| Symptom | Try |
|---------|-----|
| `cdrom:[...] does not have a Release file` | Auto-handled on Debian: the wizard comments out the cdrom source and writes default `deb.debian.org` mirrors if none exist. To fix manually: `sed -i '/cdrom:/s/^/# /' /etc/apt/sources.list`. |
| `Unable to locate package <name>` | The wizard now warns and skips (`[!] Not in <pkg_mgr> index, skipping: …`) instead of aborting. If you're running an older copy: re-curl with `curl -fsSL ".../rhlinuxconfig.sh?v=$(date +%s)" -o /tmp/rhlinuxconfig.sh`. |
| ipinfo.io step warns "unreachable" | Check outbound HTTPS / DNS. Script continues; set timezone manually with `timedatectl set-timezone Europe/Berlin` |
| `claude` not in `$PATH` after install | `source /etc/profile.d/claude-code.sh` or open a new shell |
| Locked out after firewall step (wrong admin IP) | Use the provider's web/serial console. ufw: `ufw allow ssh`. firewalld: `firewall-cmd --add-service=ssh`. iptables: `iptables -I INPUT -p tcp --dport 22 -j ACCEPT`. The firewall pre-fills your current SSH client as the admin IP to avoid this. |
| Origin server unreachable over HTTPS | Port 443 is allowed **only from Cloudflare ranges + admin IPs** — direct access from elsewhere is blocked by design. Add a source rule or proxy through Cloudflare. |
| Need IPv6 back | Delete `/etc/sysctl.d/99-rhlc-disable-ipv6.conf`, run `sudo sysctl --system`, then reboot. |
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
- **The firewall step can lock you out.** SSH is restricted to the admin IP(s) you enter (pre-filled with your current SSH client). If you supply a wrong IP — or none while connected via a NATed/changing address — you may lose access. Keep a provider console open until you've confirmed a fresh SSH session works. If no admin IP is given, SSH is left open to all to avoid a hard lockout.
- The firewall **disables IPv6** and **closes port 80**, and opens **443 only to Cloudflare ranges + your admin IPs**. If your service must be reachable directly (not via Cloudflare) or over IPv6, adjust `setup_firewall()` / re-enable IPv6 first.
- `--unattended` skips the interactive wizards but **does** run disable-IPv6, firewall, and fail2ban. The firewall prompt auto-resolves to your detected SSH client (or, if none, leaves SSH open).
- Generated passwords are printed once to the terminal and not stored anywhere. Capture them at the time.

---

## License

MIT.
