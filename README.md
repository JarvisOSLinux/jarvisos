# JARVIS OS — AI-Native Linux Distribution

**Website**: [www.jarvisoslinux.org](https://www.jarvisoslinux.org)

**Contact**:
- Toufic Majdalani — [toufic@touficmajdalani.com](mailto:toufic@touficmajdalani.com)
- Yakup Atahanov — [yakup.atahanov@wsu.edu](mailto:yakup.atahanov@wsu.edu)

---

## Cybersecurity Roadmap

JARVIS OS is a research platform studying what happens when a large language model is given full OS privileges. The [seven-threat taxonomy](https://jarvisoslinux.org/research#taxonomy) documented on the website drives the security work below. Items are ordered by severity.

### Threat Mitigations — 7-Threat Taxonomy

These map directly to the threats identified through live JARVIS OS operation:

- [ ] **#4 / #5 — Unauthorized sudo escalation & capability chaining (Critical)**
  Implement scoped sudo rules in `jarvis.service` that match the kernel policy tier exactly. DANGEROUS-tier actions must require explicit user confirmation before any `sudo` invocation; capabilities granted must not be reusable for chained operations beyond what was authorized.

- [ ] **#7 — Forgetful context constraint enforcement (Novel / Critical)**
  The LLM silently drops security constraints stated earlier in the session — the novel finding with no prior literature. Implement a persistent constraint register in the daemon that re-injects active security rules into every LLM prompt, independent of context window state.

- [ ] **#3 — MCP server integrity verification (High)**
  Third-party MCP servers registered via `dmcp` have no integrity checks. Add cryptographic signature verification (GPG or ed25519) for community MCP server manifests before `dmcp` allows registration. Maintain a signed allowlist of reviewed servers.

- [ ] **#2 — Misleading MCP server description guardrails (High)**
  Ambiguous server descriptions cause the LLM to invoke unintended tools. Add a `dmcp` validation step that flags servers whose tool descriptions are semantically ambiguous or overlap with system-critical tool names.

- [ ] **#6 — File operation guardrails (High)**
  Unintended file modification/deletion is currently only blocked at the FORBIDDEN tier for obvious patterns (`rm -rf /`, `dd`). Extend `jarvis_policy.c` with path-based rules — writes to `/etc`, `/usr`, `/boot`, and kernel module directories must be DANGEROUS-tier at minimum, requiring explicit user confirmation.

- [ ] **#1 — MCP keyword match accuracy improvement (Medium)**
  The AI selects wrong tools via superficial keyword matching. Evaluate embedding-based semantic tool selection in `dispatch` as an alternative to keyword routing, and add a confidence threshold below which the daemon asks for user clarification before invoking any tool.

### Kernel & Driver Hardening

- [ ] **seccomp-bpf filter for the JARVIS daemon**
  Profile the exact syscalls used by `jarvis-daemon` and apply a strict seccomp allowlist via the systemd `SystemCallFilter=` directive or a hand-written BPF filter.

- [ ] **Kernel keyring key TTL and auto-expiry**
  API keys stored via `jarvis_keys.c` currently persist indefinitely. Add per-key expiration timers and a session-based mode (keys expire on daemon restart or configurable timeout).

- [ ] **Policy pattern bounds checking**
  `jarvis_policy.c` `pattern_match()` does not validate the length of `server` and `tool` strings from userspace. Add explicit length checks before comparison.

- [ ] **LSM integration (SELinux / AppArmor)**
  The policy engine operates above the LSM layer. Write an AppArmor profile (or SELinux policy module) for `jarvis-daemon` that enforces mandatory access control independently of the userspace policy tier, providing defense-in-depth.

- [ ] **Pin linux-jarvisos submodule to commit hash, not branch**
  `linux-jarvisos/` tracks `jarvisos-7.0-stable` by branch ref. Change `.gitmodules` to pin a specific commit SHA to prevent supply-chain drift and ensure upstream CVE patches are applied deliberately.

### MCP Layer (dmcp / dispatch)

- [ ] **Permission enforcement audit in `dmcp`**
  Verify that `dmcp`'s tool registration and lifecycle management enforces the four-tier policy on every tool invocation, not just at registration time. Add integration tests that confirm a FORBIDDEN-tier tool cannot be executed regardless of which MCP server registers it.

- [ ] **Socket confirmation message integrity**
  The TLA confirmation gate sends JSON over a local socket. Add a nonce/HMAC to each confirmation message to prevent replay attacks if the socket path is accessible to other processes.

- [ ] **MCP server sandboxing**
  Community MCP servers loaded by `dmcp` run in the same process space as the daemon. Investigate running each MCP server in an isolated child process with a restricted seccomp profile and no ambient capabilities.

### Audit & Logging

- [ ] **Log rotation for `/var/log/jarvis/jarvis.log`**
  Add a `logrotate` configuration file (installed to `/etc/logrotate.d/jarvis`) with size limits, compression, and retention policy.

- [ ] **Credential redaction in log output**
  The daemon logger does not explicitly scrub API keys or tokens. Add a log filter that redacts strings matching known key patterns before any output to file or journal.

- [ ] **Append-only audit log**
  Integrate with `systemd-journal` or `auditd` so the JARVIS audit trail cannot be modified or deleted by a compromised userspace process. Set `/var/log/jarvis/` to mode `0750`, owned by `jarvis:jarvis`.

- [ ] **Secret scanning in build pipeline**
  Add a pre-commit hook (git-secrets or trufflehog) to the repo to block accidental credential commits. Wire it into the Makefile `check` target.

### Research Deliverables

- [ ] **Formal threat model document (`THREAT_MODEL.md`)**
  Document the full attack surface: kernel driver, daemon, MCP layer, LLM inference, and the novel forgetful-context threat. Include attacker assumptions, trust boundaries, and mitigations for each threat.

- [ ] **Vulnerability disclosure policy (`SECURITY.md`)**
  Add a `SECURITY.md` at repo root with a responsible disclosure process, contact method, and expected response time.

- [ ] **SURCA poster materials**
  Publish the SURCA poster (WSU Everett) and experimental data to `/research` or `docs/` once the presentation is complete.

- [ ] **Controlled experiment data for academic paper**
  Run the three privilege escalation tiers (sandboxed, sudo-elevated, web-enabled) against the full threat taxonomy and publish reproducible results. The paper is currently pending experimental data.

- [ ] **Security architecture diagram**
  Add a diagram showing the full trust boundary stack: LLM → dispatch → dmcp → TLA confirmation gate → kernel policy → CAP enforcement → LSM. Include where each of the 7 threats is intercepted (or not).

---

**The world's first operating system with a custom AI-integrated kernel.**

JARVIS OS is a custom Linux distribution built on a CachyOS/Arch base where an AI assistant handles system administration, file management, and hardware control through natural language — voice or text. The kernel itself speaks to the AI through a dedicated character device (`/dev/jarvis`), making the AI a first-class OS citizen rather than a userspace afterthought.

> **Status**: Work in progress. The custom kernel (`linux-jarvisos`), JARVIS driver, and agent runtime are functional. The full ISO build pipeline builds successfully; live-boot testing and the Calamares installer are still being refined.

---

## What Makes This Different

Most "AI-integrated" desktops are just a chatbot running on top of a stock kernel. JARVIS OS integrates the AI at the kernel level:

| Layer | What it does |
|-------|-------------|
| `jarvis.ko` | Character device `/dev/jarvis` — kernel posts structured queries, AI daemon reads and responds |
| `jarvis_sysmon` | Real-time CPU/memory/thermal metrics via ioctl and sysfs — AI uses these to pick the right LLM model size |
| `jarvis_policy` | Tiered action security engine (SAFE / ELEVATED / DANGEROUS / FORBIDDEN) with kernel-enforced rate limiting |
| `jarvis_keys` | Secure API-key storage in the Linux kernel keyring — cloud LLM keys never touch disk |
| `jarvis_dibs` | Zero-copy DIBS buffer sharing for large inference payloads |

---

## Project Structure

```
jarvisos/
├── linux-jarvisos/               # linux-jarvisos kernel source (submodule, branch jarvisos-7.0-stable)
│   ├── drivers/jarvis/           # JARVIS AI kernel drivers
│   │   ├── jarvis_core.c         # /dev/jarvis misc device + query ring buffer
│   │   ├── jarvis_sysmon.c       # CPU/memory/thermal metrics
│   │   ├── jarvis_policy.c       # AI action security policy engine
│   │   ├── jarvis_keys.c         # Kernel keyring for API key storage
│   │   └── jarvis_dibs.c         # Zero-copy DIBS buffer integration
│   ├── include/uapi/linux/jarvis.h  # Userspace API (ioctls, structs, enums)
│   └── arch/x86/configs/jarvisos.config  # JARVIS kernel config fragment
├── packages/
│   ├── linux-jarvisos/           # Arch PKGBUILD for the custom kernel
│   │   ├── PKGBUILD              # Produces linux-jarvisos + linux-jarvisos-headers
│   │   └── linux-jarvisos.install
│   └── calamares-config/         # Calamares installer branding + configuration
├── Project-JARVIS/               # JARVIS daemon + tooling (submodule)
├── scripts/                      # ISO build pipeline
│   ├── build.config              # Build paths and ISO filename
│   ├── Makefile                  # Orchestrates all build steps
│   ├── 00-install-prereq.sh      # Install host build tools (Arch/Fedora/Ubuntu/openSUSE)
│   ├── 01-extract-iso.sh         # Extract base CachyOS ISO
│   ├── 02-unsquash-fs.sh         # Extract SquashFS rootfs
│   ├── 03-bake-wayland.sh        # Install KDE Plasma Wayland + all system packages
│   ├── 03b-build-kernel.sh       # Build linux-jarvisos packages and install into rootfs
│   ├── 04-bake-jarvis.sh         # Install Project-JARVIS daemon
│   ├── 05-bake-calamares.sh      # Install Calamares installer
│   ├── 06-squash-fs.sh           # Repack SquashFS
│   ├── 07-rebuild-iso.sh         # Assemble final bootable ISO
│   └── booter.sh                 # QEMU launcher for local testing
├── jarvis_agent.py               # Standalone JARVIS agent runtime (voice + text → Ollama → shell)
├── test-jarvis-ollama.sh         # Bootstrap launcher for the standalone agent
├── build-deps/                   # Place your CachyOS source ISO here
└── build/                        # All build artifacts land here (gitignored)
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        JARVIS OS Architecture                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  🎤 Voice Input ──► Vosk STT ──► wake phrase "Hey JARVIS"          │
│  ⌨️  Text Input  ─────────────────────────────────┐                 │
│                                                   ▼                 │
│                              Ollama (local LLM) ◄─── sysmon picks  │
│                                   │                   model size    │
│                                   ▼                                 │
│                         Plan (JSON: commands + tiers)               │
│                                   │                                 │
│                    ┌──────────────▼──────────────────┐             │
│                    │   JARVIS Policy Gate             │             │
│                    │   SAFE ──────► run silently      │             │
│                    │   ELEVATED ──► run + audit log   │             │
│                    │   DANGEROUS ─► user confirm first│             │
│                    │   FORBIDDEN ─► hard block        │             │
│                    └──────────────┬──────────────────┘             │
│                                   │                                 │
│                          Shell execution (PTY)                      │
│                                   │                                 │
│               ┌───────────────────▼────────────────────┐           │
│               │            linux-jarvisos kernel        │           │
│               │  /dev/jarvis ◄──► jarvis.ko             │           │
│               │  /sys/class/misc/jarvis/sysmon/*        │           │
│               │  /sys/class/misc/jarvis/policy/*        │           │
│               └───────────────────────────────────────┘            │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Building the linux-jarvisos Kernel

> **Requirement: Arch-based host system.** The kernel build uses `makepkg`, which is Arch-specific. The `pacman -U` install step requires `pacman`. You cannot build and install this kernel on a Fedora or Debian host — use an Arch, Manjaro, EndeavourOS, or CachyOS machine.

### Prerequisites

```bash
# Install kernel build tools
sudo pacman -S base-devel bc flex bison openssl libelf pahole ccache

# Optional but strongly recommended — makes incremental rebuilds ~5–10× faster
sudo pacman -S ccache
```

### Initialize the kernel submodule

```bash
git clone --recursive https://github.com/YourUsername/jarvisos.git
cd jarvisos

# If already cloned without --recursive:
git submodule update --init linux-jarvisos
```

The `linux-jarvisos/` submodule tracks the `jarvisos-7.0-stable` branch, which is the upstream 7.0.2 kernel tree plus the JARVIS driver tree under `drivers/jarvis/`.

### Build modes

#### Option A — Build and install on your running system (for development / daily use)

This is the fastest way to run the JARVIS kernel on your own machine. The script builds the packages on the host and installs them with `pacman`:

```bash
cd scripts
bash 03b-build-kernel.sh --host-install
```

After install, reboot and select **linux-jarvisos** from your bootloader (GRUB or systemd-boot). The GRUB entry is added automatically by the `linux-jarvisos.install` hook.

**Build time**: 20–60 min on first run. Subsequent runs with ccache take 2–5 min.

#### Option B — Build packages only (ISO pipeline or manual inspection)

```bash
cd scripts
bash 03b-build-kernel.sh
# Packages land in build/kernel-pkg/
# linux-jarvisos-*.pkg.tar.zst
# linux-jarvisos-headers-*.pkg.tar.zst
```

#### Skip recompilation when packages are already built

```bash
SKIP_KERNEL_BUILD=1 bash 03b-build-kernel.sh --host-install
```

### What gets built

| Package | Contents |
|---------|----------|
| `linux-jarvisos` | `vmlinuz-linux-jarvisos`, kernel modules, mkinitcpio preset |
| `linux-jarvisos-headers` | Full build tree for out-of-tree modules, JARVIS UAPI header, JARVIS/DIBS driver headers |

### Verifying the kernel is active

```bash
uname -r
# Should output something like: 7.0.2-jarvisos-g5fffde5bcf9e

# Verify /dev/jarvis is available
ls -l /dev/jarvis

# Read live hardware metrics from the kernel sysfs interface
cat /sys/class/misc/jarvis/sysmon/cpu_load
cat /sys/class/misc/jarvis/sysmon/mem_avail
cat /sys/class/misc/jarvis/sysmon/thermal

# Inspect the AI security policy table loaded in the kernel
cat /sys/class/misc/jarvis/policy/policy_table
```

### JARVIS kernel config options

The `packages/linux-jarvisos/PKGBUILD` applies these config symbols on top of the host kernel config:

| Symbol | Purpose |
|--------|---------|
| `CONFIG_JARVIS=m` | Main JARVIS driver module |
| `CONFIG_JARVIS_SYSMON=y` | CPU/memory/thermal sysfs metrics |
| `CONFIG_JARVIS_POLICY=y` | AI action security policy engine |
| `CONFIG_JARVIS_KEYS=y` | Kernel keyring for API key storage |
| `CONFIG_JARVIS_SYSFS_METRICS=y` | Expose state/model/pending via sysfs |
| `CONFIG_JARVIS_DIBS=y` | Zero-copy DIBS buffer integration (if DIBS present) |
| `CONFIG_EFI_STUB=y` | Required for UEFI boot (PE/COFF image) |
| `CONFIG_SQUASHFS=y` | Required for archiso live boot |
| `CONFIG_OVERLAY_FS=y` | Required for archiso overlay mount |

---

## Running the JARVIS Agent (Standalone — No ISO needed)

The `jarvis_agent.py` runtime works on any Linux system with Ollama installed. It does not require the custom kernel, but if `linux-jarvisos` is running it can read from `/sys/class/misc/jarvis/sysmon/` for hardware-aware model selection.

### Quick start

```bash
# Ensure Ollama is running
systemctl start ollama

# Launch the agent (handles all setup automatically)
./test-jarvis-ollama.sh
```

The launcher will:
1. Install system dependencies (`portaudio`, `python-pip`)
2. Create a Python venv with `vosk`, `pyaudio`, `requests`
3. Download the Vosk small English model (~45 MB) for offline STT
4. Select an Ollama model based on available RAM
5. Open a dedicated terminal window with the JARVIS agent

### Selecting a model

```bash
# Force a specific model
JARVIS_MODEL=qwen3:8b ./test-jarvis-ollama.sh

# Point at a remote Ollama instance
OLLAMA_URL=http://192.168.1.10:11434 ./test-jarvis-ollama.sh
```

### Agent commands

| Input | What happens |
|-------|-------------|
| `sysmon` | Print current CPU%, RAM, temperature |
| `update my system` | Plan `pacman -Syu`, show DANGEROUS confirmation, run on approval |
| `Hey JARVIS <command>` | Voice wake phrase → transcribe → plan → execute |
| `quit` / `exit` / Ctrl-C | Graceful shutdown |

### Action security tiers

Every command the AI plans is classified before execution:

| Tier | Example | Behaviour |
|------|---------|-----------|
| SAFE | `df -h`, `systemctl status` | Runs silently |
| ELEVATED | `systemctl restart NetworkManager` | Runs, writes audit entry to `/tmp/jarvis.log` |
| DANGEROUS | `pacman -Syu`, `pacman -S htop` | Blocked until user types `y` |
| FORBIDDEN | `rm -rf /`, `dd if=/dev/zero` | Hard-blocked unconditionally |

---

## Developer Setup on an Installed JarvisOS System

If you are running JARVIS OS as your daily driver or a dev VM (not just booting a live ISO), this section covers how to get the full stack working correctly.

### Prerequisites

- JarvisOS installed from the live ISO (or kernel + daemon installed via `--host-install` + `--overlay`)
- Ollama running (`systemctl status ollama`)
- At least one model pulled: `ollama list`

### 1 — Verify the kernel module loads at boot

The `jarvis.ko` module must be loaded before any service starts. Check current state:

```bash
lsmod | grep jarvis        # Should show: jarvis, dibs
ls -l /dev/jarvis          # Should exist
```

If the module is not loading automatically at boot, create the modules-load config:

```bash
sudo tee /etc/modules-load.d/jarvis.conf << 'EOF'
# JARVIS kernel driver — provides /dev/jarvis
jarvis
EOF

# Apply immediately without rebooting
sudo systemctl restart systemd-modules-load.service
```

`modprobe` resolves the `dibs` dependency automatically — no separate entry needed.

Verify after reboot:

```bash
uname -r                                      # Should contain jarvisos
ls /dev/jarvis                                # Must exist
cat /sys/class/misc/jarvis/sysmon/cpu_load    # Live CPU metric from kernel
```

### 2 — Configure the LLM model

The JARVIS service and CLI both read `/etc/jarvis/jarvis.conf`. Edit it to set the model you have pulled:

```bash
ollama list                                   # Find installed models
sudo nano /etc/jarvis/jarvis.conf
```

Key fields:

```ini
LLM_MODEL=qwen3:14b          # Match an ollama list entry exactly
LLM_URL=http://localhost:11434
OUTPUT_MODE=text              # Use "text" if no working audio device
LLM_AUTO_PULL=false           # Set true to auto-pull missing models
```

Apply to the running service:

```bash
sudo systemctl restart jarvis.service
jarvis model                                  # Should echo the model name
```

### 3 — Run the TUI

The interactive terminal UI (`jarvis tui`) requires the `textual` package in the JARVIS Python environment:

```bash
# Check which jarvis binary is in PATH
which jarvis                                  # Should be /usr/local/bin/jarvis
# That script wraps /opt/jarvis-env/bin/jarvis

# Install textual if missing
sudo /opt/jarvis-env/bin/pip install textual

# Launch the TUI
jarvis tui
```

TUI keybindings:

| Key | Action |
|-----|--------|
| `Ctrl+N` | New session |
| `Ctrl+Q` | Quit |
| `Ctrl+L` | Focus chat log (scroll with arrows/PgUp) |
| `Ctrl+I` | Focus input |
| `F1` | Help / keybinding reference |
| `Enter` | Submit message |

### 4 — Send messages to the running daemon

The JARVIS systemd service listens on a Unix socket. From any terminal:

```bash
jarvis send "what is my CPU temperature"
```

Or use text chat mode directly (bypasses the socket, runs its own event loop):

```bash
jarvis chat
```

### 5 — Verify the full stack

```bash
# Kernel driver
ls /dev/jarvis && echo "kernel driver OK"

# Daemon service
systemctl is-active jarvis.service

# Ollama reachable
curl -s http://localhost:11434/api/tags | python3 -m json.tool | grep name

# Model configured
jarvis model

# Send a test query
jarvis ask "say hello"
```

### Runtime file layout on an installed system

| Path | Purpose |
|------|---------|
| `/usr/local/bin/jarvis` | Shell entry point (wraps `/opt/jarvis-env/bin/jarvis`) |
| `/opt/jarvis-env/` | Python venv with JARVIS and all dependencies |
| `/usr/lib/jarvis/` | JARVIS Python package source |
| `/etc/jarvis/jarvis.conf` | System-wide config (model, URLs, modes) |
| `/usr/lib/jarvis/.env` | Fallback config when `JARVIS_CONFIG_DIR` is unset |
| `/var/lib/jarvis/` | Runtime data (models dir, secondary venv) |
| `/run/jarvis/input.sock` | Unix socket — `jarvis send` writes here |
| `/run/jarvis/output.sock` | Unix socket — subscribe to receive JSON responses |
| `/var/log/jarvis/` | Logs (also in `journalctl -u jarvis`) |
| `/etc/modules-load.d/jarvis.conf` | Ensures `jarvis.ko` loads at boot |
| `/dev/jarvis` | JARVIS kernel character device |
| `/sys/class/misc/jarvis/sysmon/` | Live hardware metrics from kernel |

### Config precedence

```
JARVIS_CONFIG_DIR env var → /etc/jarvis/jarvis.conf   (system install, daemon)
                          ↓ fallback
                          /usr/lib/jarvis/.env         (dev fallback)
```

The systemd unit sets `JARVIS_CONFIG_DIR=/etc/jarvis` via `Environment=`. The `/usr/local/bin/jarvis` wrapper sets it the same way so CLI and daemon always agree.

---

## Building the JarvisOS ISO

> **Work in progress.** The build pipeline runs end-to-end, but live-boot reliability and the Calamares installer are still being stabilized. Expect rough edges.

### Requirements

- **Arch-based host** (Arch, Manjaro, EndeavourOS, CachyOS) — `makepkg` and `pacman` are required for the kernel build step
- 16 GB+ RAM
- 60 GB+ free disk space
- Internet connection (packages are downloaded during build)
- A CachyOS desktop ISO placed in `build-deps/`

### Step 0 — Get the source ISO

Download the CachyOS desktop ISO and place it in `build-deps/`:

```
build-deps/cachyos-desktop-linux-260308.iso
```

Update `scripts/build.config` if your filename differs:

```bash
ISO_FILE="cachyos-desktop-linux-260308.iso"
PROJECT_ROOT="/absolute/path/to/jarvisos"
```

### Step 1 — Install host build tools

```bash
cd scripts
sudo bash 00-install-prereq.sh
```

This detects your host distro (Arch/Fedora/Ubuntu/openSUSE) and installs `arch-install-scripts`, `squashfs-tools`, `xorriso`, `p7zip`, `dosfstools`, `fakeroot`, `git`, `curl`, and `python3`.

### Step 2 — Run the full build

```bash
cd scripts

# Build everything in sequence
make all
```

Or run steps individually when debugging:

```bash
make step1    # Extract CachyOS ISO
make step2    # Unsquash rootfs → build/iso-rootfs/
make step3    # Install KDE Plasma Wayland + all system packages into rootfs
make step3b   # Build linux-jarvisos kernel + install into rootfs
make step4    # Install Project-JARVIS daemon
make step5    # Install Calamares installer
make step6    # Repack rootfs into SquashFS
make step7    # Assemble final bootable ISO → build/jarvisos-YYYYMMDD-x86_64.iso

make status   # Show which steps are complete
make clean    # Remove all build artifacts
```

**Estimated total time**: 60–120 min depending on CPU and network (kernel compilation is the bottleneck).

### Step 3 — Test in QEMU

```bash
# Boot with UEFI (recommended)
./scripts/booter.sh

# Or boot with BIOS
./scripts/booter.sh --bios
```

### Step 4 — Write to USB

```bash
sudo dd if=build/jarvisos-*-x86_64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Boot from USB and use the Calamares installer on the desktop.

### What each script does

#### `00-install-prereq.sh`
Detects the host distro and installs all build tooling. Supports Arch, Fedora, Ubuntu, and openSUSE.

#### `01-extract-iso.sh`
Mounts the CachyOS source ISO and copies its contents into `build/iso-extract/`.

#### `02-unsquash-fs.sh`
Extracts the SquashFS rootfs into `build/iso-rootfs/` for modification via `arch-chroot`.

#### `03-bake-wayland.sh`
Heavy lifting: installs KDE Plasma Wayland, PipeWire audio, NetworkManager (wpa_supplicant backend), input drivers, comprehensive hardware firmware, creates the `liveuser` account with passwordless sudo, configures SDDM autologin, and sets up all systemd services needed for a working live desktop.

#### `03b-build-kernel.sh`
Builds the `linux-jarvisos` and `linux-jarvisos-headers` packages using `makepkg` on the host, then installs them into the rootfs via `pacman -U` in the chroot and regenerates the initramfs with the archiso/memdisk hooks. Backs up `vmlinuz-linux-jarvisos` and its initramfs to `build/kernel-files/` for step 7.

#### `04-bake-jarvis.sh`
Copies `Project-JARVIS` into the rootfs, creates the Python venv, installs Ollama, sets up the `jarvis.service` systemd unit, and places the CLI wrappers.

#### `05-bake-calamares.sh`
Installs Calamares and applies the JARVIS OS branding, partitioning, and post-install configuration.

#### `06-squash-fs.sh`
Repacks `build/iso-rootfs/` back into a SquashFS image with `zstd` compression. Removes the build-time `resolv.conf` and replaces it with a symlink to `systemd-resolved`'s stub.

#### `07-rebuild-iso.sh`
Assembles the final ISO using `xorriso`. Dynamically sizes `efiboot.img` to fit the UEFI files, copies `vmlinuz-linux-jarvisos` and its initramfs from `build/kernel-files/`, and updates the syslinux/GRUB bootloader entries. The EFI image is always deleted and recreated to prevent silent ENOSPC truncation.

---

## Known Issues & Status

| Area | Status | Notes |
|------|--------|-------|
| Kernel build (`linux-jarvisos`) | Working | Requires Arch host; ccache strongly recommended |
| `/dev/jarvis` driver | Working | Confirmed active when booted into linux-jarvisos |
| sysmon sysfs (`/sys/class/misc/jarvis/sysmon/`) | Working | Readable with `cat` |
| Policy sysfs (`/sys/class/misc/jarvis/policy/`) | Working | Shows all loaded rules |
| Standalone JARVIS agent (`test-jarvis-ollama.sh`) | Working | Voice + text, Ollama, full policy enforcement |
| ISO build pipeline | Working | Full build completes without errors |
| Live boot (BIOS) | Working | Boots to KDE Plasma desktop |
| Live boot (UEFI) | Working | efiboot.img dynamically sized; EFI stub enforced |
| WiFi on live boot | Working | NetworkManager + wpa_supplicant backend |
| Audio on live boot | Working | PipeWire with rtkit-daemon, per-user service symlinks |
| Touchpad on live boot | Working | libinput + psmouse/i2c_hid modules |
| JARVIS TUI (`jarvis tui`) | Working | Requires `textual` in `/opt/jarvis-env`; install with `sudo /opt/jarvis-env/bin/pip install textual` |
| Kernel module autoload at boot | Working | `/etc/modules-load.d/jarvis.conf` → `jarvis`; `dibs` dep resolved automatically |
| Calamares installer | In progress | Installs but post-install configuration needs work |
| JARVIS daemon on installed system | In progress | Service boots; model selection needs tuning |

---

## Troubleshooting

### Kernel build

**`makepkg: command not found`**
```bash
# You must be on an Arch-based system
sudo pacman -S base-devel
```

**`CONFIG_JARVIS=m missing from final .config`**
```bash
# Remove stale .config so PKGBUILD rebuilds from /proc/config.gz
rm linux-jarvisos/.config
bash scripts/03b-build-kernel.sh --host-install
```

**Kernel submodule is empty**
```bash
git submodule update --init --recursive linux-jarvisos
```

### ISO build

**`ISO file not found`**
```bash
ls build-deps/
# Ensure cachyos-desktop-linux-260308.iso is present, or update ISO_FILE in scripts/build.config
```

**`arch-chroot: command not found`**
```bash
sudo pacman -S arch-install-scripts
```

**`No space left on device` during squashfs**
```bash
df -h
make clean   # Clears build/ to reclaim space
```

**UEFI boots to black screen / "Unsupported"**
The `07-rebuild-iso.sh` script dynamically sizes efiboot.img and enforces `CONFIG_EFI_STUB=y` in the kernel config. If you are hitting this on an old build, rebuild from step 7: `make step7`.

### JARVIS agent

**`Ollama not reachable`**
```bash
systemctl start ollama
# or for user session:
ollama serve &
```

**No voice input (`vosk/pyaudio` missing)**
The agent falls back to text-only mode automatically. Install `portaudio` and rerun the launcher to enable voice.

**Audio in live boot is silent**
```bash
systemctl --user status pipewire
systemctl --user start pipewire pipewire-pulse wireplumber
```

### JARVIS TUI (`jarvis tui`)

**`Error: TUI dependencies are not installed. (missing: textual)`**

The `textual` package is not in the JARVIS Python environment. Install it:

```bash
sudo /opt/jarvis-env/bin/pip install textual
jarvis tui
```

Note: the active JARVIS environment is `/opt/jarvis-env`, not `/var/lib/jarvis/venv`. Always install extra packages into `/opt/jarvis-env`.

**`Error: LLM model not configured`**

No model is set in the config. Set it:

```bash
sudo nano /etc/jarvis/jarvis.conf
# Set: LLM_MODEL=qwen3:14b  (or whichever model you have pulled)
```

**`jarvis model` shows the wrong model (e.g. `qwen3:4b` when `qwen3:14b` is installed)**

The CLI is reading the fallback `/usr/lib/jarvis/.env` instead of `/etc/jarvis/jarvis.conf`. Check that `JARVIS_CONFIG_DIR` is exported by the wrapper:

```bash
head /usr/local/bin/jarvis
# Should contain: export JARVIS_CONFIG_DIR="${JARVIS_CONFIG_DIR:-/etc/jarvis}"
```

If missing, add it or re-run the jarvis-install overlay step.

### Kernel module (`/dev/jarvis`)

**`/dev/jarvis` missing after reboot**

Module is not loading at boot. Check:

```bash
lsmod | grep jarvis
cat /etc/modules-load.d/jarvis.conf    # Should contain: jarvis
journalctl -b -u systemd-modules-load | grep jarvis
```

If the config file is missing, create it:

```bash
echo "jarvis" | sudo tee /etc/modules-load.d/jarvis.conf
sudo modprobe jarvis                   # Load now without rebooting
ls /dev/jarvis                         # Verify
```

**`modprobe: FATAL: Module jarvis not found`**

The `linux-jarvisos` kernel is not running. Check:

```bash
uname -r    # Must contain "jarvisos"
```

If not, select `linux-jarvisos` from your bootloader and reboot. If it does not appear, rebuild and reinstall the kernel:

```bash
bash scripts/03b-build-kernel.sh --host-install
```

---

## File Locations (installed system)

See the full table in the [Developer Setup](#developer-setup-on-an-installed-jarvisos-system) section above. Quick reference:

```
/usr/local/bin/jarvis                   # CLI entry point → /opt/jarvis-env/bin/jarvis
/opt/jarvis-env/                        # JARVIS Python environment (pip install here)
/usr/lib/jarvis/                        # JARVIS Python package source
/etc/jarvis/jarvis.conf                 # Primary config (model, URL, output mode)
/etc/modules-load.d/jarvis.conf         # Auto-load jarvis.ko at boot
/dev/jarvis                             # JARVIS kernel character device
/sys/class/misc/jarvis/sysmon/          # Live hardware metrics from kernel
/sys/class/misc/jarvis/policy/          # Active AI security policy table
/usr/lib/modules/<kver>/kernel/drivers/jarvis/jarvis.ko.zst
/var/lib/jarvis/                        # Runtime data (models, secondary venv)
/run/jarvis/input.sock                  # Daemon input socket (jarvis send)
/run/jarvis/output.sock                 # Daemon output socket
/var/log/jarvis/                        # Audit log (also: journalctl -u jarvis)
/usr/bin/jarvis-daemon                  # Daemon launcher (used by systemd unit)
```

---

## Contributing

1. Fork the repo and create a feature branch
2. Test your changes with `make all` and boot the ISO in QEMU
3. For kernel changes: rebuild with `bash scripts/03b-build-kernel.sh --host-install` and verify `uname -r` and `/dev/jarvis`
4. Submit a PR with a description of what changed and how you tested it

Areas that need work:
- Calamares post-install script (sets up linux-jarvisos as the installed bootloader entry)
- JARVIS daemon auto-startup and model selection on first boot
- Kernel → daemon query path (the `jarvis_post_query` / `JARVIS_IOC_RESPOND` round-trip)
- Voice TTS output (Piper integration)

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).

The `linux-jarvisos/` submodule is GPL-2.0 (Linux kernel).

---

*JARVIS OS — where the AI lives in the kernel, not on top of it.*
