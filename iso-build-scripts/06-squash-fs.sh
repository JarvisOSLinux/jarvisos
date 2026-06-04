#!/bin/bash
# Step 6: Rebuild SquashFS
# Compresses the modified rootfs back into a SquashFS file

set -eo pipefail

# Source config file and shared utilities
source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

require_tool "mksquashfs" "squashfs-tools" "squashfs-tools" "squashfs-tools" "squashfs"

# Validate required variables
if [ -z "${SCRIPTS_DIR}" ]; then
    echo "Error: SCRIPTS_DIR not set in build.config" >&2
    exit 1
fi

if [ -z "${PROJECT_ROOT}" ]; then
    echo "Error: PROJECT_ROOT not set in build.config" >&2
    exit 1
fi

# Construct paths from build.config (paths starting with / are relative to PROJECT_ROOT)
SCRIPTS_DIR="${PROJECT_ROOT}${SCRIPTS_DIR}"
BUILD_DIR="${PROJECT_ROOT}${BUILD_DIR}"
ISO_EXTRACT_DIR="${BUILD_DIR}${ISO_EXTRACT_DIR}"
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if step 2 was completed (rootfs extracted)
if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Rootfs not extracted. Please run step 2 first${NC}" >&2
    exit 1
fi

# Check if step 1 was completed (ISO extracted)
if [ ! -d "${ISO_EXTRACT_DIR}" ] || [ -z "$(ls -A "${ISO_EXTRACT_DIR}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: ISO not extracted. Please run step 1 first${NC}" >&2
    exit 1
fi

# Find original SquashFS file
SQUASHFS_FILE=$(find "${ISO_EXTRACT_DIR}" -type f -iname "airootfs.sfs" | head -1)

if [ -z "${SQUASHFS_FILE}" ] || [ ! -f "${SQUASHFS_FILE}" ]; then
    echo -e "${RED}Error: Could not find airootfs.sfs in extracted ISO${NC}" >&2
    echo -e "${YELLOW}Looking for SquashFS files:${NC}"
    find "${ISO_EXTRACT_DIR}" -type f -iname "*.sfs" | head -5 || echo "  None found"
    exit 1
fi

# Check if mksquashfs is available
if ! command -v mksquashfs &> /dev/null; then
    echo -e "${RED}Error: mksquashfs not found. Please install squashfs-tools${NC}" >&2
    echo -e "${YELLOW}Install: $(pkg_install_hint squashfs-tools)${NC}"
    exit 1
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 6: Rebuilding SquashFS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Rootfs: ${SQUASHFS_ROOTFS}${NC}"
echo -e "${BLUE}Output: ${SQUASHFS_FILE}${NC}"

# Unmount all filesystems before rebuilding
echo -e "${BLUE}Unmounting virtual filesystems...${NC}"
sudo umount -l "${SQUASHFS_ROOTFS}/var/lib/pacman/sync" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/tmp" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/dev/shm" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/dev" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/run" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/sys" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/proc" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}" 2>/dev/null || true

# Wait a moment for lazy unmounts to complete
sleep 1

# Verify nothing is still mounted
if mount | grep -q "${SQUASHFS_ROOTFS}"; then
    echo -e "${YELLOW}Warning: Some filesystems may still be mounted:${NC}"
    mount | grep "${SQUASHFS_ROOTFS}"
    echo -e "${YELLOW}Attempting force unmount...${NC}"
    mount | grep "${SQUASHFS_ROOTFS}" | awk '{print $3}' | xargs -r sudo umount -f 2>/dev/null || true
fi

# CRITICAL: Clean virtual filesystem directories that cause mksquashfs to hang
# These directories shouldn't be in the SquashFS anyway (created at runtime)
echo -e "${BLUE}Cleaning virtual filesystem directories...${NC}"
sudo rm -rf "${SQUASHFS_ROOTFS}/proc"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/sys"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/dev"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/run"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/tmp"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/var/lib/pacman/sync"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/var/tmp"/* 2>/dev/null || true

# Keep directory structure but ensure they're empty
sudo mkdir -p "${SQUASHFS_ROOTFS}/proc" "${SQUASHFS_ROOTFS}/sys" "${SQUASHFS_ROOTFS}/dev" \
    "${SQUASHFS_ROOTFS}/run" "${SQUASHFS_ROOTFS}/tmp" \
    "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg" \
    "${SQUASHFS_ROOTFS}/var/lib/pacman/sync" \
    "${SQUASHFS_ROOTFS}/var/tmp" 2>/dev/null || true

# Remove build-time DNS resolution file (copied from host for package installation)
sudo rm -f "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true

# Create proper live-boot DNS symlink pointing to systemd-resolved's stub resolver.
# systemd-resolved creates /run/systemd/resolve/stub-resolv.conf at runtime.
# NetworkManager (with dns=systemd-resolved) will push DNS servers into resolved.
sudo ln -sf /run/systemd/resolve/stub-resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf"
echo -e "${BLUE}Set /etc/resolv.conf → systemd-resolved stub (live-boot DNS)${NC}"

# Create new SquashFS file
SQUASHFS_DIR=$(dirname "${SQUASHFS_FILE}")
NEW_SQUASHFS="${SQUASHFS_DIR}/airootfs.sfs.new"

# Remove leftover .new from prior aborted runs
sudo rm -f "${NEW_SQUASHFS}" 2>/dev/null || true

# Use xz compression (most common for Arch ISOs)
echo -e "${BLUE}Compressing SquashFS (this may take a while)...${NC}"
echo -e "${BLUE}This can take 5-15 minutes depending on rootfs size...${NC}"

# Show rootfs size before compression
ROOTFS_SIZE=$(sudo du -sh "${SQUASHFS_ROOTFS}" 2>/dev/null | cut -f1)
echo -e "${BLUE}Rootfs size: ${ROOTFS_SIZE}${NC}"

# ============================================================================
# ISO SIZE REDUCTION: strip unneeded data before compression
# ============================================================================
echo -e "${BLUE}Stripping non-essential locale data (keeping en / en_US / locale.alias)...${NC}"
sudo find "${SQUASHFS_ROOTFS}/usr/share/locale" -mindepth 1 -maxdepth 1 \
    ! -name 'en' ! -name 'en_US' ! -name 'en_US.*' ! -name 'locale.alias' \
    -exec rm -rf {} + 2>/dev/null || true

echo -e "${BLUE}Removing development headers (not needed on live ISO)...${NC}"
sudo rm -rf "${SQUASHFS_ROOTFS}/usr/include" 2>/dev/null || true

echo -e "${BLUE}Removing package documentation...${NC}"
sudo rm -rf "${SQUASHFS_ROOTFS}/usr/share/doc" 2>/dev/null || true

echo -e "${BLUE}Removing static libraries and cmake/pkgconfig files...${NC}"
sudo find "${SQUASHFS_ROOTFS}/usr/lib" \
    \( -name '*.a' -o -name '*.la' \) -delete 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/usr/lib/cmake" 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/usr/lib/pkgconfig" 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/usr/share/pkgconfig" 2>/dev/null || true

echo -e "${BLUE}Removing unused KDE wallpapers (keeping only JarvisOS defaults)...${NC}"
sudo find "${SQUASHFS_ROOTFS}/usr/share/wallpapers" -mindepth 1 -maxdepth 1 \
    ! -name 'JarvisOS*' ! -name 'Next' \
    -exec rm -rf {} + 2>/dev/null || true

# NOTE: /usr/lib/girepository-1.0 (GI typelibs) are RUNTIME data — nm-applet and
# other GI-dependent tools load them at startup. Do NOT strip these.

echo -e "${BLUE}Size after stripping:${NC}"
sudo du -sh "${SQUASHFS_ROOTFS}" 2>/dev/null | cut -f1

# Build SquashFS with xz compression
# CRITICAL: Do NOT pipe through tee — with pipefail off the tee mask mksquashfs failures.
# Instead, redirect stderr+stdout to the log and stream it with tail -f in the background.
SQUASHFS_LOG="${BUILD_DIR}/squashfs-build.log"
SQUASHFS_JOBS="${JOBS:-$(nproc)}"
sudo mksquashfs "${SQUASHFS_ROOTFS}" "${NEW_SQUASHFS}" \
    -comp xz \
    -b 1M \
    -processors "${SQUASHFS_JOBS}" \
    -noappend \
    -e boot/grub/grubenv \
    -e proc \
    -e sys \
    -e dev \
    -e run \
    -e tmp \
    -e var/cache/pacman/pkg \
    -e var/lib/pacman/sync \
    -e var/tmp \
    -e .snapshots \
    -e lost+found \
    2>&1 | tee "${SQUASHFS_LOG}"
# pipefail is on, so if mksquashfs fails the pipeline exits non-zero → set -e aborts

echo -e "${GREEN}✓ SquashFS compression complete${NC}"

# Verify the new SquashFS was created and is non-trivially sized
if [ ! -f "${NEW_SQUASHFS}" ]; then
    echo -e "${RED}Error: mksquashfs did not produce output file${NC}" >&2
    exit 1
fi
NEW_SIZE_BYTES=$(stat -c%s "${NEW_SQUASHFS}" 2>/dev/null || echo 0)
if [ "${NEW_SIZE_BYTES}" -lt 100000000 ]; then
    echo -e "${RED}Error: New SquashFS is suspiciously small (${NEW_SIZE_BYTES} bytes). Build likely failed.${NC}" >&2
    exit 1
fi

# Show new SquashFS size
NEW_SIZE=$(du -h "${NEW_SQUASHFS}" 2>/dev/null | cut -f1)
ORIGINAL_SIZE=$(du -h "${SQUASHFS_FILE}" 2>/dev/null | cut -f1)
echo -e "${BLUE}Original SquashFS: ${ORIGINAL_SIZE}${NC}"
echo -e "${BLUE}New SquashFS: ${NEW_SIZE}${NC}"

# ============================================================================
# CRITICAL: Replace original SquashFS and clean up signatures/checksums
# ============================================================================
# 1. Remove CMS signature — the Arch ISO ships with a .cms.sig that validates
#    the ORIGINAL squashfs. After we replace the squashfs the signature no
#    longer matches. The archiso initramfs hook checks for .cms.sig and if it
#    exists but verification fails, boot drops to an emergency shell.
echo -e "${BLUE}Removing CMS signature (no longer valid for rebuilt squashfs)...${NC}"
sudo rm -f "${SQUASHFS_DIR}/airootfs.sfs.cms.sig" 2>/dev/null || true
echo -e "${GREEN}✓ Removed .cms.sig${NC}"

# 2. Remove backup file — it was included in the ISO by mistake previously,
#    bloating the ISO by ~1GB with the unmodified squashfs.
echo -e "${BLUE}Removing backup squashfs (not needed in ISO)...${NC}"
sudo rm -f "${SQUASHFS_DIR}/airootfs.sfs.backup" 2>/dev/null || true

# 3. Replace the original squashfs with our modified version
echo -e "${BLUE}Replacing original SquashFS...${NC}"
sudo mv -f "${NEW_SQUASHFS}" "${SQUASHFS_FILE}"
sudo chmod 644 "${SQUASHFS_FILE}"

# 4. Verify the replacement actually happened
REPLACED_SIZE_BYTES=$(stat -c%s "${SQUASHFS_FILE}" 2>/dev/null || echo 0)
if [ "${REPLACED_SIZE_BYTES}" != "${NEW_SIZE_BYTES}" ]; then
    echo -e "${RED}FATAL: SquashFS replacement failed! Size mismatch.${NC}" >&2
    echo -e "${RED}  Expected: ${NEW_SIZE_BYTES} bytes${NC}" >&2
    echo -e "${RED}  Got:      ${REPLACED_SIZE_BYTES} bytes${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ SquashFS replaced successfully (${NEW_SIZE})${NC}"

# 5. Verify no stale files remain that would bloat the ISO or confuse boot
for stale in "${SQUASHFS_DIR}/airootfs.sfs.new" "${SQUASHFS_DIR}/airootfs.sfs.backup" "${SQUASHFS_DIR}/airootfs.sfs.cms.sig"; do
    if [ -f "${stale}" ]; then
        echo -e "${YELLOW}Warning: Removing stale file: $(basename "${stale}")${NC}"
        sudo rm -f "${stale}"
    fi
done

# 6. Regenerate SHA-512 checksum with RELATIVE path (not absolute build path)
#    The archiso hook does: cd <squashfs_dir> && sha512sum -c airootfs.sha512
#    so the checksum file must reference "airootfs.sfs" (relative), not the
#    full build path.
echo -e "${BLUE}Regenerating SHA-512 checksum...${NC}"
SHA512_FILE="${SQUASHFS_DIR}/airootfs.sha512"
# Generate checksum from the directory itself to get a relative path
(cd "${SQUASHFS_DIR}" && sha512sum airootfs.sfs) | sudo tee "${SHA512_FILE}" > /dev/null
echo -e "${GREEN}✓ SHA-512 checksum regenerated${NC}"

# 7. Final verification: list what's in the squashfs directory
echo -e "${BLUE}SquashFS directory contents:${NC}"
ls -lh "${SQUASHFS_DIR}/"

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 6 complete: SquashFS rebuilt${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}SquashFS: ${SQUASHFS_FILE}${NC}"
echo -e "${BLUE}Size: ${NEW_SIZE}${NC}"
