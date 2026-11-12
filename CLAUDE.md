# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

JARVIS OS — an AI-native Linux distribution built on an Arch/CachyOS base. The AI is a first-class kernel citizen via a custom character device (`/dev/jarvis`). Three layers:

1. **`linux-jarvisos/`** — kernel source (cloned, see `sources.conf`) with JARVIS drivers (`drivers/jarvis/`)
2. **`Project-JARVIS/`** — AI daemon repo (dispatch + dmcp + contextor)
3. **`iso-build-scripts/`** — ISO build pipeline that layers everything onto a base Arch ISO

## Design Principles

**Auto-install missing dependencies — never warn and bail.** Any package required by a build step, installer mode, or runtime must be installed automatically if not present. Do not warn the user that a tool is missing and exit — install it first, then proceed. This applies everywhere:
- `jarvis-install.sh --overlay` / `--install-packages` (repo-root script, doubles as live-ISO TUI and chroot dependency installer) — installs `dialog`, `base-devel`, `bc`, `flex`, `bison`, `openssl`, `libelf`, `pahole` at the top of `install_packages_mode()` before anything else runs
- `iso-build-scripts/00-install-prereq.sh` (`make prereq`) — installs all ISO build tools + kernel build tools for all supported distros (Arch, Fedora, Ubuntu, openSUSE)
- Any new feature that needs a host tool: add it to both `jarvis-install.sh`'s dep block and `00-install-prereq.sh`

## Build Config

`build.config` at the **project root** (not `iso-build-scripts/`) is sourced by all scripts and the Makefile:
- `PROJECT_ROOT` — auto-detected via `dirname`; override only if needed
- `ISO_FILE` — source ISO filename (currently `archlinux-x86_64.iso`); place file in `build-deps/`
- `BUILD_DIR`, `BUILD_DEPS_DIR` — relative to `PROJECT_ROOT`

**Arch-based host required** for the kernel build step — `makepkg` and `pacman` are mandatory.

## Build Commands

All ISO build commands run from `iso-build-scripts/`:

```bash
cd iso-build-scripts

make prereq          # Install host build tools (detects Arch/Fedora/Ubuntu/openSUSE)
make all             # Full build: steps 1–7 + 3b (prereq must be run first)
make rest            # Resume interrupted build (skips completed steps)
make status          # Show which steps are done
make clean           # Wipe build/iso-extract/ and build/iso-rootfs/

make step1           # Extract base ISO
make step2           # Unsquash rootfs
make step3           # Install KDE Plasma Wayland + all packages into rootfs
make step3b          # Build linux-jarvisos kernel (bottleneck: 20–60 min first run)
make step4           # Install Project-JARVIS daemon
make step5           # Install TUI installer (jarvis-install)
make step6           # Repack SquashFS
make step7           # Assemble final ISO

make JOBS=8 step3b   # Parallel kernel build (default: nproc)
```

Kernel-only build (host install or package-only):
```bash
bash iso-build-scripts/03b-build-kernel.sh --host-install   # Build + install on running system
bash iso-build-scripts/03b-build-kernel.sh                  # Build packages only → build/kernel-pkg/
SKIP_KERNEL_BUILD=1 bash iso-build-scripts/03b-build-kernel.sh --host-install  # Skip recompile
```

Test in QEMU:
```bash
./iso-build-scripts/booter.sh         # UEFI boot
./iso-build-scripts/booter.sh --bios  # BIOS boot
```

Standalone agent (no ISO needed):
```bash
./test-jarvis.sh                                  # Auto-setup + launch (starts llama-server)
JARVIS_MODEL=Qwen/Qwen3-8B-GGUF:Q4_K_M ./test-jarvis.sh   # Force model
LLM_URL=http://192.168.1.10:11445 ./test-jarvis.sh        # Use a running server
```

## Architecture

```
LLM (llama-server, run by the daemon) → dispatch (tool routing) → dmcp (MCP server registry)
                                        ↓
                          JARVIS Policy Gate (SAFE/ELEVATED/DANGEROUS/FORBIDDEN)
                                        ↓
                              Shell execution (PTY)
                                        ↓
                          linux-jarvisos kernel (/dev/jarvis)
                          /sys/class/misc/jarvis/sysmon/   ← hw metrics
                          /sys/class/misc/jarvis/policy/   ← policy table
```

### Kernel Drivers (`linux-jarvisos/drivers/jarvis/`)

| File | Purpose |
|------|---------|
| `jarvis_core.c` | `/dev/jarvis` misc device + query ring buffer |
| `jarvis_sysmon.c` | CPU/memory/thermal via ioctl and sysfs |
| `jarvis_policy.c` | 4-tier action policy engine with rate limiting |
| `jarvis_keys.c` | API key storage in Linux kernel keyring |
| `jarvis_dibs.c` | Zero-copy DIBS buffer for large inference payloads |
| `include/uapi/linux/jarvis.h` | Userspace API (ioctls, structs, enums) |

PKGBUILD at `packages/linux-jarvisos/PKGBUILD` — reads `KERNEL_SRC` env var pointing at the `linux-jarvisos/` checkout.

### Project-JARVIS (`Project-JARVIS/`)

- **`dispatch/`** — Rust crate; routes user intent to MCP tools (keyword fallback, embedding-first when available)
- **`dmcp/`** — Rust crate; MCP server registry and lifecycle manager
- **`contextor/`** — Rust crate; context/memory layer

The repos are cloned side by side by `iso-build-scripts/fetch-sources.sh` from `sources.conf` (name, URL, branch); an existing checkout is never touched. Each repo is checked out at the commit recorded in `versions.lock` (updated by `.github/workflows/track-subsystems.yml` when a repo pushes, or by `fetch-sources.sh --update-lock`). `JARVIS_SOURCES_FLOAT=1` takes branch heads instead. The workflow is triggered by each subsystem's `notify-parent.yml`, which needs a valid `ORG_PAT` secret.

### ISO Pipeline (`iso-build-scripts/`)

Steps are idempotent and can be resumed with `make rest`. Each numbered script (`01`–`07`) performs one phase; `03b-build-kernel.sh` runs between steps 3 and 4 and is the only step that requires `makepkg` on the host.

- Step 4 (`04-bake-jarvis.sh`) — copies `Project-JARVIS` into the rootfs chroot, creates Python venv, installs llama.cpp (`llama-cpp` + Vulkan backend), installs `jarvis.service`
- Step 5 (`05-bake-installer.sh`) — installs the TUI installer (repo-root `jarvis-install.sh`) which auto-launches on TTY1 in the live environment

`05-bake-calamares.sh` no longer exists (removed); the Makefile uses `05-bake-installer.sh`. `cachyos-calamares` is fully removed.

### Standalone Agent Root Files

- `jarvis_agent.py` — full agent runtime (voice + text → llama-server → policy-gated shell)
- `jarvis-wake.py` — wake-word / lightweight listener front-end
- `test-jarvis.sh` — bootstrapper: installs deps (incl. `llama-cpp`), creates venv, starts `llama-server` with a model chosen by RAM, launches agent

## TUI Installer (`jarvis-install.sh`, repo root)

Bash + `dialog` TUI that runs as root. Installer flow: welcome → disk select → partition mode (auto/manual) → bootloader → filesystem → swap → timezone → locale → hostname → user/passwords → summary → partition/format → pacstrap → chroot config → bootloader install → JARVIS stack install → reboot.

The same script is invoked a second time inside the target chroot as `jarvis-install --overlay` (aliased `--install-packages`) to run `install_packages_mode()` — the dependency-install + JARVIS-stack step. Don't assume it only runs once per install.

Currently in progress: post-install JARVIS service configuration and model selection on first boot.

## Standalone Kernel Build Scripts (outside the ISO pipeline)

Two root/iso-build-scripts scripts build `linux-jarvisos` without the full ISO pipeline:
- `build-kernel.sh` (repo root) — build (and optionally `pacman -U` install) the kernel on the local Arch host; supports `--clean`, `--force`, `SKIP_BUILD=1`
- `iso-build-scripts/vps-kernel-build.sh` — provisions a throwaway Linode VPS (48-core, needs `JARVIS_LINODE_TOKEN`) to build the kernel package remotely when local hardware is too slow, fetches the built `.pkg.tar.zst`s, then destroys the VPS (`--keep-vps` to skip teardown). Mirrors `.github/workflows/kernel-build.yml`, which does the same thing in CI on pushes touching `packages/linux-jarvisos/**`.

## Sibling Repos (no submodules)

Declared in `sources.conf`, all under `github.com/JarvisOSLinux`:

```
linux-jarvisos/    (branch: stable)
Project-JARVIS/    (branch: main)
dmcp/              (branch: main)
dispatch/          (branch: main)
```

`cachyos-calamares` is gone, not just discontinued. Ignore any stale references to it elsewhere (e.g. README.md still describes a Calamares install flow; the actual installer is `jarvis-install.sh`, see below).

### Why dispatch/ and dmcp/ appear twice

`Project-JARVIS` keeps its own submodules under `deps/rust/`; those stay.
The top-level `dispatch/` and `dmcp/` here are plain clones for the ISO build
(`04-bake-jarvis.sh` builds the Rust crates directly). They follow the lock
and can differ from the commits `Project-JARVIS` pins.

Fetch the sibling repos (the build scripts also do this on demand):
```bash
bash iso-build-scripts/fetch-sources.sh   # or: fetch-sources.sh dmcp
```

## Security Research Context

This repo is a cybersecurity research platform. The README lists a 7-threat taxonomy discovered during live operation — including a novel "forgetful context" threat (#7) where the LLM silently drops security constraints mid-session. Active open work items: scoped sudo rules, persistent constraint register in the daemon, GPG verification for `dmcp` server manifests, and path-based rules in `jarvis_policy.c` for writes to `/etc`, `/usr`, `/boot`.

## Current Status

| Area | Status |
|------|--------|
| Kernel, `/dev/jarvis`, sysmon sysfs, standalone agent | Working |
| Full ISO build + live boot (BIOS + UEFI) | Working |
| TUI installer (`jarvis-install`) | In progress — installs; post-install JARVIS config incomplete |
| JARVIS daemon on installed system | In progress — boots; model selection needs tuning |
| Calamares graphical installer | Discontinued |
