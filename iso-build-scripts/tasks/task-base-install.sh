#!/bin/bash
# Bootstrap base Arch system via pacstrap, pre-seed JARVIS source and kernel packages.
#
# Required env vars:
#   MOUNT_ROOT      — e.g. /mnt/jarvis-install
#   JARVIS_MODEL    — e.g. qwen3:4b
#   INSTALLER_PATH  — absolute path to jarvis-install.sh (copied into chroot)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need_root
require_env MOUNT_ROOT JARVIS_MODEL INSTALLER_PATH

MOUNT_ROOT="${MOUNT_ROOT}"
JARVIS_MODEL="${JARVIS_MODEL:-qwen3:4b}"

# ── Internet check ─────────────────────────────────────────────────────────
info "Checking internet connectivity..."
if ! ping -c1 -W5 archlinux.org >/dev/null 2>&1 && \
   ! ping -c1 -W5 8.8.8.8 >/dev/null 2>&1; then
    die "No internet connection. Connect to network before installing."
fi
ok "Internet connected"

# ── Sync clock ─────────────────────────────────────────────────────────────
info "Syncing system clock..."
timedatectl set-ntp true 2>/dev/null || true

# ── Detect CPU microcode ───────────────────────────────────────────────────
_ucode=""
if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
    _ucode="intel-ucode"
elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
    _ucode="amd-ucode"
fi
[ -n "${_ucode}" ] && info "CPU microcode: ${_ucode}"

# ── Bootstrap ─────────────────────────────────────────────────────────────
info "Bootstrapping base system via pacstrap (needs internet)..."
echo ""
pacstrap -K "${MOUNT_ROOT}" \
    base base-devel linux linux-firmware \
    sudo nano vim wget curl git openssh \
    networkmanager wpa_supplicant wireless-regdb \
    arch-install-scripts dialog \
    ${_ucode:+"${_ucode}"} \
    || die "pacstrap failed — check network and /etc/pacman.d/mirrorlist"
echo ""
ok "Base system installed"

# ── Copy mirrorlist ────────────────────────────────────────────────────────
cp /etc/pacman.d/mirrorlist "${MOUNT_ROOT}/etc/pacman.d/mirrorlist" 2>/dev/null || true

# ── Copy installer + task scripts into chroot ─────────────────────────────
cp "${INSTALLER_PATH}" "${MOUNT_ROOT}/tmp/jarvis-install"
chmod +x "${MOUNT_ROOT}/tmp/jarvis-install"

# Copy tasks/ so --overlay inside chroot can dispatch to task-overlay-detect.sh
mkdir -p "${MOUNT_ROOT}/tmp/jarvis-tasks"
cp "${SCRIPT_DIR}/"*.sh "${MOUNT_ROOT}/tmp/jarvis-tasks/"

# ── Pre-seed JARVIS source from live ISO ──────────────────────────────────
if [ -d /usr/lib/jarvis ] && [ -n "$(ls -A /usr/lib/jarvis 2>/dev/null)" ]; then
    info "Copying JARVIS source from live ISO into target..."
    mkdir -p "${MOUNT_ROOT}/usr/lib/jarvis"
    cp -r /usr/lib/jarvis/. "${MOUNT_ROOT}/usr/lib/jarvis/"
fi

# ── Pre-seed linux-jarvisos kernel packages ───────────────────────────────
if [ -d /opt/jarvis-kernel-pkg ] && \
   find /opt/jarvis-kernel-pkg -name 'linux-jarvisos-*.pkg.tar.zst' -quit 2>/dev/null | grep -q .; then
    info "Staging linux-jarvisos packages into target for overlay phase..."
    mkdir -p "${MOUNT_ROOT}/opt/jarvis-kernel-pkg"
    cp /opt/jarvis-kernel-pkg/linux-jarvisos-*.pkg.tar.zst "${MOUNT_ROOT}/opt/jarvis-kernel-pkg/"
fi

# ── Ensure DNS in chroot ──────────────────────────────────────────────────
cp --dereference /etc/resolv.conf "${MOUNT_ROOT}/etc/resolv.conf" 2>/dev/null || true

# ── Pass model choice into chroot ─────────────────────────────────────────
printf '%s\n' "${JARVIS_MODEL}" > "${MOUNT_ROOT}/tmp/.jarvis-model-choice"

# ── Install JARVIS components via overlay in chroot ───────────────────────
info "Installing JARVIS OS components (KDE, Ollama, JARVIS stack)..."
echo ""
arch-chroot "${MOUNT_ROOT}" bash /tmp/jarvis-install --overlay \
    || die "JARVIS component install failed (arch-chroot --overlay)"

rm -f "${MOUNT_ROOT}/tmp/jarvis-install" "${MOUNT_ROOT}/tmp/.jarvis-model-choice"
rm -rf "${MOUNT_ROOT}/opt/jarvis-kernel-pkg" 2>/dev/null || true
ok "JARVIS OS components installed"
