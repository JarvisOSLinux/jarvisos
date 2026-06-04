#!/bin/bash
# Step 3b: Build linux-jarvisos custom kernel packages (7.0.2)
#
# Builds the JARVIS-integrated Linux kernel from the linux-jarvisos/ submodule using
# the PKGBUILD at packages/linux-jarvisos/PKGBUILD, producing two packages:
#
#   linux-jarvisos         — kernel image + modules
#   linux-jarvisos-headers — build headers for out-of-tree modules
#
# Default mode: installs packages into the ISO rootfs (for the ISO pipeline).
# Host install mode: installs packages onto your running Arch system so you
#   can boot linux-jarvisos directly from your bootloader.
#
# Usage:
#   bash iso-build-scripts/03b-build-kernel.sh              # ISO pipeline (default)
#   bash iso-build-scripts/03b-build-kernel.sh --host-install  # build + install on host
#   SKIP_KERNEL_BUILD=1 bash iso-build-scripts/03b-build-kernel.sh --host-install
#     # reuse already-built packages, just install on host
#
# Prerequisites (ISO mode): step 2 (rootfs extracted) + step 3 (packages + mkinitcpio.conf)
# Prerequisites (host mode): running Arch-based system with pacman
#
# Host build tools required:
#   Arch:          sudo pacman -S base-devel bc flex bison openssl libelf pahole
#   Ubuntu/Debian: sudo apt-get install build-essential bc flex bison \
#                      libssl-dev libelf-dev dwarves

set -eo pipefail

# ── Parse arguments ────────────────────────────────────────────────────────────
HOST_INSTALL=0
DOWNLOAD_RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --host-install)      HOST_INSTALL=1 ;;
        --download-release)  DOWNLOAD_RELEASE=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# Source config file and shared utilities
source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

# Validate required variables
if [ -z "${PROJECT_ROOT}" ]; then
    echo "Error: PROJECT_ROOT not set in build.config" >&2
    exit 1
fi

# ── Resolve paths ─────────────────────────────────────────────────────────────
BUILD_DIR="${PROJECT_ROOT}${BUILD_DIR}"
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"
KERNEL_SRC="${PROJECT_ROOT}/linux-jarvisos"
KERNEL_BACKUP_DIR="${BUILD_DIR}/kernel-files"
PKGBUILD_DIR="${PROJECT_ROOT}/packages/linux-jarvisos"
PKG_DEST="${BUILD_DIR}/kernel-pkg"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Kernel build settings ─────────────────────────────────────────────────────
LOCALVERSION="-jarvisos"
NCPU=$(nproc)

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 3b: Building linux-jarvisos kernel packages${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Kernel source : ${KERNEL_SRC}${NC}"
echo -e "${BLUE}Rootfs        : ${SQUASHFS_ROOTFS}${NC}"
echo -e "${BLUE}PKGBUILD      : ${PKGBUILD_DIR}${NC}"
echo -e "${BLUE}Package dest  : ${PKG_DEST}${NC}"
echo -e "${BLUE}Build threads : ${NCPU}${NC}"
echo -e "${YELLOW}NOTE: Initial kernel compilation takes 20–60 minutes.${NC}"
echo -e "${YELLOW}      Install ccache for much faster incremental rebuilds.${NC}"
echo ""

# ── Prerequisite checks ───────────────────────────────────────────────────────
echo -e "${BLUE}Checking build prerequisites...${NC}"

# Kernel source must be present — skip check when downloading pre-built packages
if [[ "${DOWNLOAD_RELEASE:-0}" != "1" && "${DOWNLOAD_KERNEL_RELEASE:-0}" != "1" ]]; then
    if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
        echo -e "${RED}FATAL: linux-jarvisos/ kernel source not found at ${KERNEL_SRC}${NC}" >&2
        echo -e "${YELLOW}Use --download-release to fetch pre-built packages, or init the submodule:${NC}"
        echo -e "${YELLOW}  git submodule update --init linux-jarvisos${NC}"
        exit 1
    fi
fi

# PKGBUILD must be present
if [ ! -f "${PKGBUILD_DIR}/PKGBUILD" ]; then
    echo -e "${RED}FATAL: PKGBUILD not found at ${PKGBUILD_DIR}/PKGBUILD${NC}" >&2
    exit 1
fi

# Step 3 (rootfs) must be done first — unless we're only installing on the host
if [ "${HOST_INSTALL}" -eq 0 ]; then
    if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
        echo -e "${RED}FATAL: Rootfs not found. Run step 3 first.${NC}" >&2
        echo -e "${YELLOW}(To build and install on your host system instead, use --host-install)${NC}"
        exit 1
    fi

    if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" which mkinitcpio &>/dev/null; then
        echo -e "${RED}FATAL: mkinitcpio not found in rootfs. Run step 3 first.${NC}" >&2
        exit 1
    fi
fi

# makepkg must be installed on the host
if ! command -v makepkg &>/dev/null; then
    echo -e "${RED}FATAL: makepkg not found. Install base-devel:${NC}" >&2
    echo -e "${YELLOW}  sudo pacman -S base-devel${NC}" >&2
    exit 1
fi

# Check host build tools
MISSING_TOOLS=()
for tool in make gcc bc flex bison perl; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

# openssl headers (for kernel cert generation / module signing)
if ! pkg-config --exists openssl 2>/dev/null \
   && [ ! -f /usr/include/openssl/ssl.h ]; then
    MISSING_TOOLS+=("openssl-dev (libssl-dev / openssl)")
fi

# libelf headers (for BTF/BPF)
if ! pkg-config --exists libelf 2>/dev/null \
   && [ ! -f /usr/include/libelf.h ] \
   && [ ! -f /usr/include/gelf.h ]; then
    MISSING_TOOLS+=("libelf (libelf-dev / elfutils / libelf)")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo -e "${RED}FATAL: Missing host build tools:${NC}" >&2
    for t in "${MISSING_TOOLS[@]}"; do
        echo -e "${RED}  - $t${NC}" >&2
    done
    echo ""
    echo -e "${YELLOW}Arch Linux:    sudo pacman -S base-devel bc flex bison openssl libelf pahole${NC}"
    echo -e "${YELLOW}Ubuntu/Debian: sudo apt-get install build-essential bc flex bison libssl-dev libelf-dev dwarves${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Build prerequisites OK (${NCPU} CPU threads)${NC}"

# Enable ccache if available
if command -v ccache &>/dev/null; then
    export CC="ccache gcc"
    export HOSTCC="ccache gcc"
    echo -e "${GREEN}✓ ccache enabled for faster incremental builds${NC}"
fi

# ── Ensure clean kernel config ────────────────────────────────────────────────
# Always remove the stale .config from any previous build.
#
# Why: the previous build produced a .config that does not contain CONFIG_JARVIS
# or its dependency CONFIG_MISC_DEVICES (they were absent from /proc/config.gz
# on that build host too).  If we keep it, PKGBUILD's prepare() treats it as
# the base, `make olddefconfig` silently drops CONFIG_JARVIS because the
# dependency still isn't satisfied, and jarvis.ko is never compiled.
#
# Starting clean forces PKGBUILD to pull /proc/config.gz (the running
# linux-jarvisos config) as the base, onto which jarvisos.config is then
# merged — guaranteeing CONFIG_MISC_DEVICES and CONFIG_JARVIS are present
# before compilation begins.
cd "${KERNEL_SRC}"

if [ -f .config ]; then
    if ! grep -q "^CONFIG_JARVIS=" .config 2>/dev/null; then
        echo -e "${YELLOW}Stale .config detected — CONFIG_JARVIS is absent.${NC}"
        echo -e "${YELLOW}Removing it so PKGBUILD rebuilds from /proc/config.gz.${NC}"
        rm -f .config
    else
        echo -e "${GREEN}✓ .config already contains CONFIG_JARVIS — keeping it.${NC}"
    fi
else
    echo -e "${BLUE}No existing .config — PKGBUILD will use /proc/config.gz.${NC}"
fi

# ── Kernel version info ───────────────────────────────────────────────────────
# Parse base version from Makefile directly — make kernelrelease requires
# include/config/auto.conf which doesn't exist until after prepare() runs.
_KVER=$(awk '/^VERSION =/{v=$3}/^PATCHLEVEL =/{p=$3}/^SUBLEVEL =/{s=$3}END{print v"."p"."s}' \
    "${KERNEL_SRC}/Makefile")
echo -e "${BLUE}Kernel version: ${_KVER}${LOCALVERSION} (full release string resolved post-build)${NC}"
echo ""

# ── Determine how to invoke makepkg (refuses to run as root) ─────────────────
# Normal path: run `make step3b` as your regular user — makepkg runs directly.
# Fallback:    if accidentally run as root (sudo make), delegate to $SUDO_USER.
mkdir -p "${PKG_DEST}"

if [ "$(id -u)" -eq 0 ]; then
    # Running as root — find the real user and drop privileges for makepkg
    BUILD_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
    if [ -z "${BUILD_USER}" ] || [ "${BUILD_USER}" = "root" ]; then
        echo -e "${RED}FATAL: Running as root and cannot determine non-root user.${NC}" >&2
        echo -e "${YELLOW}Fix: run without sudo — make step3b${NC}" >&2
        exit 1
    fi
    # Ensure the non-root user can write to build dirs and kernel source
    chown "${BUILD_USER}" "${PKG_DEST}"
    chown -R "${BUILD_USER}" "${PKGBUILD_DIR}"
    chown -R "${BUILD_USER}" "${KERNEL_SRC}"
    MAKEPKG_PREFIX="sudo -u ${BUILD_USER}"
else
    BUILD_USER="$(id -un)"
    MAKEPKG_PREFIX=""
fi
echo -e "${BLUE}makepkg will run as: ${BUILD_USER}${NC}"

# Export env vars consumed by the PKGBUILD
export KERNEL_SRC
export MAKEFLAGS="-j${NCPU}"

# ── Download pre-built packages from GitHub Releases ─────────────────────────
# Use --download-release or DOWNLOAD_KERNEL_RELEASE=1 to skip local build and
# pull the latest .pkg.tar.zst artifacts from JarvisOSLinux/linux-jarvisos.
# Requires gh CLI authenticated with repo scope.
if [[ "${DOWNLOAD_RELEASE:-0}" == "1" || "${DOWNLOAD_KERNEL_RELEASE:-0}" == "1" ]]; then
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Downloading kernel packages from GitHub Releases...${NC}"

    if ! command -v gh &>/dev/null; then
        echo -e "${RED}FATAL: gh CLI not found. Install it or build locally.${NC}" >&2
        exit 1
    fi

    mkdir -p "${PKG_DEST}"
    gh release download --repo JarvisOSLinux/linux-jarvisos \
        --pattern "linux-jarvisos-*.pkg.tar.zst" \
        --dir "${PKG_DEST}" \
        --clobber

    echo -e "${GREEN}✓ Kernel packages downloaded to ${PKG_DEST}${NC}"
    echo ""
    SKIP_KERNEL_BUILD=1
fi

# Allow skipping the kernel compilation when packages are already built.
# Set SKIP_KERNEL_BUILD=1 to reuse existing packages in ${PKG_DEST} and jump
# straight to the install + initramfs steps.
EXISTING_PKG_LINUX=$(ls -t "${PKG_DEST}"/linux-jarvisos-[0-9]*.pkg.tar.zst 2>/dev/null | head -1) || true
EXISTING_PKG_HEADERS=$(ls -t "${PKG_DEST}"/linux-jarvisos-headers-*.pkg.tar.zst 2>/dev/null | head -1) || true

if [[ "${SKIP_KERNEL_BUILD:-0}" == "1" ]] \
   && [[ -n "${EXISTING_PKG_LINUX}" ]] \
   && [[ -n "${EXISTING_PKG_HEADERS}" ]]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}SKIP_KERNEL_BUILD=1: Reusing pre-built packages (skipping makepkg)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  linux-jarvisos         : $(basename "${EXISTING_PKG_LINUX}")${NC}"
    echo -e "${BLUE}  linux-jarvisos-headers : $(basename "${EXISTING_PKG_HEADERS}")${NC}"
    echo ""
else
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Building linux-jarvisos + linux-jarvisos-headers with makepkg...${NC}"
    echo -e "${BLUE}(PKGBUILD handles configure, compile, and packaging)${NC}"
    echo ""

    cd "${PKGBUILD_DIR}"
    ${MAKEPKG_PREFIX} env \
        KERNEL_SRC="${KERNEL_SRC}" \
        PKGDEST="${PKG_DEST}" \
        MAKEFLAGS="-j${NCPU}" \
        makepkg --nodeps --nocheck --skipinteg --force

    echo ""
    echo -e "${GREEN}✓ Packages built successfully${NC}"
fi

# Kernel is now configured — resolve the full release string.
KERNELRELEASE=$(cd "${KERNEL_SRC}" && make -s kernelrelease LOCALVERSION="${LOCALVERSION}" 2>/dev/null \
    || echo "${_KVER}${LOCALVERSION}")

# Locate the produced packages
PKG_LINUX=$(ls -t "${PKG_DEST}"/linux-jarvisos-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)
PKG_HEADERS=$(ls -t "${PKG_DEST}"/linux-jarvisos-headers-*.pkg.tar.zst 2>/dev/null | head -1)

if [[ -z "${PKG_LINUX}" || -z "${PKG_HEADERS}" ]]; then
    echo -e "${RED}FATAL: Expected package files not found in ${PKG_DEST}${NC}" >&2
    ls -la "${PKG_DEST}/" || true
    exit 1
fi

echo -e "${BLUE}  linux-jarvisos         : $(basename "${PKG_LINUX}")${NC}"
echo -e "${BLUE}  linux-jarvisos-headers : $(basename "${PKG_HEADERS}")${NC}"

# ── Install packages ──────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ "${HOST_INSTALL}" -eq 1 ]; then
    # ── Host install mode: install onto the running system ────────────────────
    echo -e "${BLUE}Installing linux-jarvisos onto host system...${NC}"
    sudo pacman -U --noconfirm "${PKG_LINUX}" "${PKG_HEADERS}"
    # pacman runs post_install: depmod + mkinitcpio automatically

    echo -e "${GREEN}✓ linux-jarvisos installed on host${NC}"
    echo -e "${GREEN}✓ linux-jarvisos-headers installed on host${NC}"

    KERNEL_SIZE=$(du -h /boot/vmlinuz-linux-jarvisos 2>/dev/null | cut -f1 || echo "?")
    INITRAMFS_SIZE=$(du -h /boot/initramfs-linux-jarvisos.img 2>/dev/null | cut -f1 || echo "?")
else
    # ── ISO pipeline mode: install into rootfs ────────────────────────────────
    echo -e "${BLUE}Installing packages into rootfs...${NC}"

    # Stage packages in rootfs /root (NOT /tmp — arch-chroot mounts a tmpfs on /tmp
    # which hides any files copied there from the host side).
    sudo cp "${PKG_LINUX}" "${PKG_HEADERS}" "${SQUASHFS_ROOTFS}/root/"

    # Temporarily disable CheckSpace — pacman can't determine the root mount point
    # inside a chroot that isn't a real mountpoint, causing a spurious "not enough
    # free disk space" error.
    if grep -q '^CheckSpace' "${SQUASHFS_ROOTFS}/etc/pacman.conf"; then
        sudo sed -i 's/^CheckSpace/#CheckSpace/' "${SQUASHFS_ROOTFS}/etc/pacman.conf"
        RESTORE_CHECKSPACE=1
    fi

    # Reinitialize the pacman keyring before installing packages.
    # Running step 3b standalone (or after a partial build) may leave the chroot
    # without a valid keyring, causing "keyring is not writable" on pacman -U.
    echo -e "${BLUE}Reinitializing pacman keyring in chroot...${NC}"
    sudo rm -rf "${SQUASHFS_ROOTFS}/etc/pacman.d/gnupg"
    sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --init
    sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --populate archlinux
    sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --populate cachyos 2>/dev/null || true
    echo -e "${GREEN}✓ Keyring initialized and populated${NC}"

    # Install via pacman in the chroot.
    # --noscriptlet: skip the .install hooks here; we run mkinitcpio explicitly
    #   below so it uses the live-boot mkinitcpio.conf (archiso/memdisk hooks).
    # -dd (--nodeps twice): fully skip ALL dependency checks and installation.
    #   linux-jarvisos-headers depends=(pahole) for end-user module building, but
    #   pahole is not needed in the live squashfs. A single --nodeps still installs
    #   missing deps; -dd suppresses that entirely. The installed system satisfies
    #   deps via its own pacman + internet access.
    sudo arch-chroot "${SQUASHFS_ROOTFS}" \
        pacman -U --noconfirm --noscriptlet -dd \
        "/root/$(basename "${PKG_LINUX}")" \
        "/root/$(basename "${PKG_HEADERS}")"

    # Restore CheckSpace
    if [ "${RESTORE_CHECKSPACE:-0}" = "1" ]; then
        sudo sed -i 's/^#CheckSpace/CheckSpace/' "${SQUASHFS_ROOTFS}/etc/pacman.conf"
    fi

    # Clean up staged packages from rootfs
    sudo rm -f "${SQUASHFS_ROOTFS}/root/linux-jarvisos"*.pkg.tar.zst

    echo -e "${GREEN}✓ linux-jarvisos installed into rootfs via pacman${NC}"
    echo -e "${GREEN}✓ linux-jarvisos-headers installed into rootfs via pacman${NC}"

    # ── Generate initramfs ────────────────────────────────────────────────────
    echo ""
    echo -e "${BLUE}Generating initramfs for linux-jarvisos...${NC}"
    echo -e "${BLUE}(Uses live-boot mkinitcpio.conf — includes archiso/memdisk hooks)${NC}"

    # mkinitcpio may exit non-zero for missing-firmware warnings even though the
    # images are generated successfully. Run it, show output, then verify by
    # checking that the output files actually exist.
    sudo arch-chroot "${SQUASHFS_ROOTFS}" mkinitcpio -p linux-jarvisos 2>&1 \
        | tee /dev/stderr | tail -5 || true

    # Verify generated images (the real success criterion)
    INITRAMFS_MAIN="${SQUASHFS_ROOTFS}/boot/initramfs-linux-jarvisos.img"

    if ! sudo test -f "${INITRAMFS_MAIN}"; then
        echo -e "${RED}FATAL: initramfs-linux-jarvisos.img was not created${NC}" >&2
        sudo ls -lah "${SQUASHFS_ROOTFS}/boot/" || true
        exit 1
    fi

    echo -e "${GREEN}✓ Initramfs generated${NC}"

    # ── Backup kernel files for step 7 ───────────────────────────────────────
    echo -e "${BLUE}Preserving linux-jarvisos kernel files for ISO build (step 7)...${NC}"
    mkdir -p "${KERNEL_BACKUP_DIR}"

    sudo cp "${SQUASHFS_ROOTFS}/boot/vmlinuz-linux-jarvisos" \
            "${KERNEL_BACKUP_DIR}/"
    sudo cp "${SQUASHFS_ROOTFS}/boot/initramfs-linux-jarvisos.img" \
            "${KERNEL_BACKUP_DIR}/"

    if sudo test -f "${SQUASHFS_ROOTFS}/boot/initramfs-linux-jarvisos-fallback.img"; then
        sudo cp "${SQUASHFS_ROOTFS}/boot/initramfs-linux-jarvisos-fallback.img" \
                "${KERNEL_BACKUP_DIR}/"
    fi

    # Fix ownership so step 7 can read without sudo
    sudo chmod 644 "${KERNEL_BACKUP_DIR}"/vmlinuz-linux-jarvisos \
                   "${KERNEL_BACKUP_DIR}"/initramfs-linux-jarvisos*.img 2>/dev/null || true
    sudo chown -R "$(id -u):$(id -g)" "${KERNEL_BACKUP_DIR}"

    KERNEL_SIZE=$(du -h "${KERNEL_BACKUP_DIR}/vmlinuz-linux-jarvisos" | cut -f1)
    INITRAMFS_SIZE=$(du -h "${KERNEL_BACKUP_DIR}/initramfs-linux-jarvisos.img" | cut -f1)
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 3b complete: linux-jarvisos built and installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Kernel release : ${KERNELRELEASE}${NC}"
echo -e "${BLUE}Packages       : linux-jarvisos, linux-jarvisos-headers${NC}"
echo -e "${BLUE}Kernel image   : vmlinuz-linux-jarvisos (${KERNEL_SIZE})${NC}"
echo -e "${BLUE}Initramfs      : initramfs-linux-jarvisos.img (${INITRAMFS_SIZE})${NC}"
echo -e "${BLUE}Modules dir    : /usr/lib/modules/${KERNELRELEASE}${NC}"
echo ""
if [ "${HOST_INSTALL}" -eq 1 ]; then
    echo -e "${GREEN}✓ Packages installed on host system via pacman${NC}"
    echo -e "${GREEN}✓ Reboot and select linux-jarvisos from your bootloader${NC}"
else
    echo -e "${GREEN}✓ Packages installed in rootfs via pacman${NC}"
    echo -e "${GREEN}✓ Calamares will install linux-jarvisos onto the target system${NC}"
    echo -e "${GREEN}✓ Stock linux kernel remains for live boot hardware compatibility${NC}"
fi
echo ""
echo -e "${BLUE}JARVIS kernel drivers included:${NC}"
echo -e "${BLUE}  jarvis.ko        — /dev/jarvis AI query/response channel${NC}"
echo -e "${BLUE}  jarvis_sysmon    — CPU/memory/thermal metrics for model selection${NC}"
echo -e "${BLUE}  jarvis_policy    — AI action security policy (SAFE/ELEVATED/DANGEROUS)${NC}"
echo -e "${BLUE}  jarvis_keys      — Kernel keyring for API-key secure storage${NC}"
