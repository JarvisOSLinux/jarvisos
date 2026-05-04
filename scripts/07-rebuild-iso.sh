#!/bin/bash
# Step 7: Rebuild ISO
# Creates the final bootable ISO from the modified files

set -eo pipefail

# Source config file and shared utilities
source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

require_tool_simple "xorriso"
require_tool "mkfs.fat" "dosfstools" "dosfstools" "dosfstools" "dosfstools"

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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Dynamic volume ID based on build date (ISO 9660 volume IDs max 32 chars)
JARVISOS_VOLID="JARVISOS_$(date +%Y%m)"

# Detect the source ISO's archisosearchuuid so we can find-and-replace it
# reliably in ALL boot configs (syslinux, systemd-boot, grub, efiboot.img)
SOURCE_UUID=""
if [ -f "${BUILD_DIR}/.source-iso-uuid" ]; then
    SOURCE_UUID=$(cat "${BUILD_DIR}/.source-iso-uuid")
    echo -e "${BLUE}Source ISO UUID: ${SOURCE_UUID}${NC}"
fi

# Check if step 1 was completed (ISO extracted)
if [ ! -d "${ISO_EXTRACT_DIR}" ] || [ -z "$(ls -A "${ISO_EXTRACT_DIR}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: ISO not extracted. Please run step 1 first${NC}" >&2
    exit 1
fi

# Check if step 6 was completed (SquashFS rebuilt)
SQUASHFS_FILE=$(find "${ISO_EXTRACT_DIR}" -type f -iname "airootfs.sfs" | head -1)
if [ -z "${SQUASHFS_FILE}" ] || [ ! -f "${SQUASHFS_FILE}" ]; then
    echo -e "${RED}Error: Could not find airootfs.sfs. Please run step 6 first${NC}" >&2
    exit 1
fi

# ============================================================================
# CRITICAL: Clean up stale files that would bloat the ISO
# ============================================================================
echo -e "${BLUE}Cleaning up stale build artifacts from ISO tree...${NC}"
# Remove any leftover .new, .backup, .cms.sig files from the squashfs directory
SQUASHFS_DIR=$(dirname "${SQUASHFS_FILE}")
for stale in "${SQUASHFS_DIR}/airootfs.sfs.new" "${SQUASHFS_DIR}/airootfs.sfs.backup" "${SQUASHFS_DIR}/airootfs.sfs.cms.sig"; do
    if [ -f "${stale}" ]; then
        echo -e "${YELLOW}Removing stale file: $(basename "${stale}")${NC}"
        sudo rm -f "${stale}"
    fi
done
# Remove the [BOOT] directory created by 7z (El Torito boot images extracted separately)
# These are NOT part of the ISO filesystem and should not be re-included
if [ -d "${ISO_EXTRACT_DIR}/[BOOT]" ]; then
    echo -e "${BLUE}Removing [BOOT]/ directory (7z extraction artifact)...${NC}"
    rm -rf "${ISO_EXTRACT_DIR}/[BOOT]"
fi
echo -e "${GREEN}✓ Cleaned up stale files${NC}"

# ============================================================================
# CRITICAL: Ensure EFI boot image exists at EFI/archiso/efiboot.img
# ============================================================================
# Newer Arch ISOs embed the EFI boot image as an El Torito entry, not as a
# regular file in the ISO filesystem. 7z extracts it to [BOOT]/2-Boot-NoEmul.img
# but we already cleaned that up above. If EFI/archiso/efiboot.img doesn't exist,
# we must create one from scratch for UEFI boot to work.

# ============================================================================
# CRITICAL: Copy kernel and initramfs to ISO structure
# ============================================================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Copying kernel and initramfs to ISO...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Define paths - try multiple sources for kernel files
KERNEL_BACKUP_DIR="${BUILD_DIR}/kernel-files"
ROOTFS_BOOT="${BUILD_DIR}/iso-rootfs/boot"
ISO_BOOT_DIR="${ISO_EXTRACT_DIR}/arch/boot/x86_64"

# ── Helper: copy one kernel file into the ISO boot dir ───────────────────────
copy_kernel_file_to_iso() {
    local filename="$1"
    local source_dir="$2"
    local is_backup="$3"    # "backup" or "rootfs"

    if [ "${is_backup}" = "backup" ]; then
        if [ -f "${source_dir}/${filename}" ]; then
            cp "${source_dir}/${filename}" "${ISO_BOOT_DIR}/"
            return 0
        fi
    else
        if sudo test -f "${source_dir}/${filename}"; then
            sudo cp "${source_dir}/${filename}" "${ISO_BOOT_DIR}/"
            return 0
        fi
    fi
    return 1
}

# Determine source directory for the stock linux kernel files
# (prefer backup dir, fall back to rootfs/boot)
KERNEL_SOURCE=""
KERNEL_SOURCE_TYPE=""
if [ -d "${KERNEL_BACKUP_DIR}" ] && [ -f "${KERNEL_BACKUP_DIR}/vmlinuz-linux" ]; then
    KERNEL_SOURCE="${KERNEL_BACKUP_DIR}"
    KERNEL_SOURCE_TYPE="backup"
    echo -e "${BLUE}Using kernel files from backup directory${NC}"
elif sudo test -d "${ROOTFS_BOOT}" && sudo test -f "${ROOTFS_BOOT}/vmlinuz-linux"; then
    KERNEL_SOURCE="${ROOTFS_BOOT}"
    KERNEL_SOURCE_TYPE="rootfs"
    echo -e "${BLUE}Using kernel files from rootfs boot directory${NC}"
else
    echo -e "${RED}FATAL ERROR: Cannot find stock linux kernel files!${NC}" >&2
    echo -e "${YELLOW}Searched locations:${NC}"
    echo -e "${YELLOW}  1. ${KERNEL_BACKUP_DIR}${NC}"
    echo -e "${YELLOW}  2. ${ROOTFS_BOOT}${NC}"
    echo -e "${RED}Please run: make step3${NC}"
    exit 1
fi

# Ensure ISO boot directory exists
mkdir -p "${ISO_BOOT_DIR}"

# ── Copy stock linux kernel (for live boot) ───────────────────────────────────
echo -e "${BLUE}Copying stock linux kernel (live boot)...${NC}"
copy_kernel_file_to_iso "vmlinuz-linux" "${KERNEL_SOURCE}" "${KERNEL_SOURCE_TYPE}"
KERNEL_SIZE=$(du -h "${ISO_BOOT_DIR}/vmlinuz-linux" | cut -f1)
echo -e "${GREEN}✓ Copied vmlinuz-linux (${KERNEL_SIZE})${NC}"

# Copy main initramfs
echo -e "${BLUE}Copying initramfs...${NC}"
copy_kernel_file_to_iso "initramfs-linux.img" "${KERNEL_SOURCE}" "${KERNEL_SOURCE_TYPE}"
INITRAMFS_SIZE=$(du -h "${ISO_BOOT_DIR}/initramfs-linux.img" | cut -f1)
echo -e "${GREEN}✓ Copied initramfs-linux.img (${INITRAMFS_SIZE}) — all hardware modules${NC}"

# Copy fallback initramfs if present
if copy_kernel_file_to_iso "initramfs-linux-fallback.img" "${KERNEL_SOURCE}" "${KERNEL_SOURCE_TYPE}" 2>/dev/null; then
    FALLBACK_SIZE=$(du -h "${ISO_BOOT_DIR}/initramfs-linux-fallback.img" | cut -f1)
    echo -e "${GREEN}✓ Copied initramfs-linux-fallback.img (${FALLBACK_SIZE})${NC}"
fi

# Copy microcode images
echo -e "${BLUE}Copying microcode images...${NC}"
MICROCODE_COPIED=0
for ucode in amd-ucode.img intel-ucode.img; do
    if copy_kernel_file_to_iso "${ucode}" "${KERNEL_SOURCE}" "${KERNEL_SOURCE_TYPE}" 2>/dev/null; then
        UCODE_SIZE=$(du -h "${ISO_BOOT_DIR}/${ucode}" | cut -f1)
        echo -e "${GREEN}✓ Copied ${ucode} (${UCODE_SIZE})${NC}"
        MICROCODE_COPIED=1
    fi
done
[ ${MICROCODE_COPIED} -eq 0 ] && echo -e "${YELLOW}⚠ No microcode images found (optional)${NC}"

# ── Copy linux-jarvisos kernel (for TUI installer installation) ──────────────
echo -e "${BLUE}Copying linux-jarvisos kernel (TUI installer target)...${NC}"

JARVISOS_KERNEL_AVAILABLE=false
if [ -f "${KERNEL_BACKUP_DIR}/vmlinuz-linux-jarvisos" ]; then
    cp "${KERNEL_BACKUP_DIR}/vmlinuz-linux-jarvisos" "${ISO_BOOT_DIR}/"
    JARVISOS_KERNEL_SIZE=$(du -h "${ISO_BOOT_DIR}/vmlinuz-linux-jarvisos" | cut -f1)
    echo -e "${GREEN}✓ Copied vmlinuz-linux-jarvisos (${JARVISOS_KERNEL_SIZE})${NC}"
    JARVISOS_KERNEL_AVAILABLE=true

    if [ -f "${KERNEL_BACKUP_DIR}/initramfs-linux-jarvisos.img" ]; then
        cp "${KERNEL_BACKUP_DIR}/initramfs-linux-jarvisos.img" "${ISO_BOOT_DIR}/"
        JJ_SIZE=$(du -h "${ISO_BOOT_DIR}/initramfs-linux-jarvisos.img" | cut -f1)
        echo -e "${GREEN}✓ Copied initramfs-linux-jarvisos.img (${JJ_SIZE})${NC}"
    fi
    if [ -f "${KERNEL_BACKUP_DIR}/initramfs-linux-jarvisos-fallback.img" ]; then
        cp "${KERNEL_BACKUP_DIR}/initramfs-linux-jarvisos-fallback.img" "${ISO_BOOT_DIR}/"
        JF_SIZE=$(du -h "${ISO_BOOT_DIR}/initramfs-linux-jarvisos-fallback.img" | cut -f1)
        echo -e "${GREEN}✓ Copied initramfs-linux-jarvisos-fallback.img (${JF_SIZE})${NC}"
    fi
elif sudo test -f "${ROOTFS_BOOT}/vmlinuz-linux-jarvisos"; then
    sudo cp "${ROOTFS_BOOT}/vmlinuz-linux-jarvisos" "${ISO_BOOT_DIR}/"
    JARVISOS_KERNEL_SIZE=$(du -h "${ISO_BOOT_DIR}/vmlinuz-linux-jarvisos" | cut -f1)
    echo -e "${GREEN}✓ Copied vmlinuz-linux-jarvisos from rootfs (${JARVISOS_KERNEL_SIZE})${NC}"
    JARVISOS_KERNEL_AVAILABLE=true

    for f in initramfs-linux-jarvisos.img initramfs-linux-jarvisos-fallback.img; do
        if sudo test -f "${ROOTFS_BOOT}/${f}"; then
            sudo cp "${ROOTFS_BOOT}/${f}" "${ISO_BOOT_DIR}/"
            echo -e "${GREEN}✓ Copied ${f}${NC}"
        fi
    done
else
    echo -e "${YELLOW}⚠ linux-jarvisos kernel not found in kernel-files/ or rootfs/boot/${NC}"
    echo -e "${YELLOW}  Calamares will fall back to the stock linux kernel for installation.${NC}"
    echo -e "${YELLOW}  Run 'make step3b' to build linux-jarvisos.${NC}"
fi

# ── CRITICAL: Make linux-jarvisos the primary boot kernel ──────────────────
# The boot entries (syslinux, systemd-boot, efiboot.img) all reference the
# standard names: vmlinuz-linux, initramfs-linux.img.  Rather than rewriting
# every boot config, we overwrite the stock files with linux-jarvisos content.
# The originals under their -jarvisos names remain for Calamares unpackfs.
if [ "${JARVISOS_KERNEL_AVAILABLE}" = true ]; then
    echo -e "${BLUE}Setting linux-jarvisos as PRIMARY boot kernel...${NC}"
    cp -f "${ISO_BOOT_DIR}/vmlinuz-linux-jarvisos" "${ISO_BOOT_DIR}/vmlinuz-linux"
    echo -e "${GREEN}✓ vmlinuz-linux overwritten with linux-jarvisos${NC}"

    if [ -f "${ISO_BOOT_DIR}/initramfs-linux-jarvisos.img" ]; then
        cp -f "${ISO_BOOT_DIR}/initramfs-linux-jarvisos.img" "${ISO_BOOT_DIR}/initramfs-linux.img"
        echo -e "${GREEN}✓ initramfs-linux.img overwritten with linux-jarvisos${NC}"
    fi

    if [ -f "${ISO_BOOT_DIR}/initramfs-linux-jarvisos-fallback.img" ]; then
        cp -f "${ISO_BOOT_DIR}/initramfs-linux-jarvisos-fallback.img" "${ISO_BOOT_DIR}/initramfs-linux-fallback.img"
        echo -e "${GREEN}✓ initramfs-linux-fallback.img overwritten with linux-jarvisos${NC}"
    fi
else
    echo -e "${YELLOW}⚠ linux-jarvisos not available — falling back to stock linux kernel${NC}"
    echo -e "${YELLOW}  Run 'make step3b' to build linux-jarvisos before step 7.${NC}"
fi

# No CachyOS fallback kernel — using Arch Linux base ISO
CACHYOS_FALLBACK_IN_ISO=false

# Verify kernel files are present (stock or jarvisos-overwritten)
echo -e "${BLUE}Verifying boot kernel files...${NC}"
if [ ! -f "${ISO_BOOT_DIR}/vmlinuz-linux" ] || [ ! -f "${ISO_BOOT_DIR}/initramfs-linux.img" ]; then
    echo -e "${RED}FATAL: Failed to copy kernel/initramfs to ISO structure${NC}" >&2
    ls -lah "${ISO_BOOT_DIR}/" || true
    exit 1
fi

# Show file info
echo ""
echo -e "${BLUE}Kernel files in ISO structure:${NC}"
ls -lh "${ISO_BOOT_DIR}"/vmlinuz-linux* "${ISO_BOOT_DIR}"/initramfs-linux* 2>/dev/null \
    | awk '{print "  " $5, $9}'

echo ""
if [ "${JARVISOS_KERNEL_AVAILABLE}" = true ]; then
    echo -e "${GREEN}✓ linux-jarvisos is the live boot kernel${NC}"
    echo -e "${GREEN}✓ linux-jarvisos available for TUI installer${NC}"
else
    echo -e "${GREEN}✓ Stock linux kernel copied (live boot fallback)${NC}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if xorriso is available
if ! command -v xorriso &> /dev/null; then
    echo -e "${RED}Error: xorriso not found.${NC}" >&2
    echo -e "${YELLOW}Install: $(pkg_install_hint_multi "xorriso" "xorriso" "xorriso" "xorriso")${NC}"
    exit 1
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 7: Rebuilding ISO${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Source: ${ISO_EXTRACT_DIR}${NC}"

# Create output ISO filename
OUTPUT_ISO="${BUILD_DIR}/jarvisos-$(date +%Y%m%d)-x86_64.iso"
OUTPUT_ISO_ABS=$(cd "${BUILD_DIR}" && pwd)/jarvisos-$(date +%Y%m%d)-x86_64.iso

echo -e "${BLUE}Output: ${OUTPUT_ISO_ABS}${NC}"

# Change to ISO extract directory
cd "${ISO_EXTRACT_DIR}" || exit 1

# Remove existing ISO if it exists (might be locked or corrupted)
if [ -f "${OUTPUT_ISO_ABS}" ]; then
    echo -e "${YELLOW}Removing existing ISO file...${NC}"
    rm -f "${OUTPUT_ISO_ABS}" || {
        echo -e "${RED}Error: Cannot remove existing ISO file. It may be in use.${NC}" >&2
        exit 1
    }
fi

# Find boot files (Arch ISO uses boot/syslinux/ structure)
ISOLINUX_BIN=""
ISOHDPFX_BIN=""
BOOT_CAT=""
EFI_IMG=""

echo -e "${BLUE}Searching for boot files...${NC}"

# Check for isolinux.bin in various locations
for path in "boot/syslinux/isolinux.bin" "isolinux/isolinux.bin" "syslinux/isolinux.bin"; do
    if [ -f "${path}" ]; then
        ISOLINUX_BIN="${path}"
        echo -e "${GREEN}✓ Found isolinux.bin: ${path}${NC}"
        break
    fi
done

# Find isohdpfx.bin (MBR boot sector)
for path in "boot/syslinux/isohdpfx.bin" "isolinux/isohdpfx.bin" "syslinux/isohdpfx.bin"; do
    if [ -f "${path}" ]; then
        ISOHDPFX_BIN="${path}"
        echo -e "${GREEN}✓ Found isohdpfx.bin: ${path}${NC}"
        break
    fi
done

# Find boot.cat
for path in "boot/syslinux/boot.cat" "isolinux/boot.cat" "syslinux/boot.cat"; do
    if [ -f "${path}" ]; then
        BOOT_CAT="${path}"
        echo -e "${GREEN}✓ Found boot.cat: ${path}${NC}"
        break
    fi
done

# Check for EFI boot image - use original if it exists, otherwise create from EFI/BOOT/
# Arch Linux ISO includes efiboot.img with full boot menu configuration
# Boot menu files are in loader/ directory in ISO root and need to be in EFI/archiso/loader/ inside efiboot.img
EFI_BOOT_DIR="EFI/BOOT"
EFI_ARCHISO_DIR="EFI/archiso"
EFI_IMG_PATH="${EFI_ARCHISO_DIR}/efiboot.img"
LOADER_DIR="loader"
LOADER_ENTRIES_DIR="${LOADER_DIR}/entries"

# Function to mount EFI boot image
mount_efi_image() {
    local efi_img_path="$1"
    local efi_mount=$(mktemp -d)
    
    if sudo mount -o loop "${efi_img_path}" "${efi_mount}" 2>/dev/null; then
        echo "${efi_mount}"
        return 0
    else
        rmdir "${efi_mount}" 2>/dev/null || true
        return 1
    fi
}

# Function to unmount EFI boot image
unmount_efi_image() {
    local efi_mount="$1"
    
    if [ -z "${efi_mount}" ] || [ ! -d "${efi_mount}" ]; then
        return 1
    fi
    
    sudo umount "${efi_mount}" 2>/dev/null || sudo umount -l "${efi_mount}" 2>/dev/null || true
    rmdir "${efi_mount}" 2>/dev/null || true
}

# Function to verify EFI boot image contents
verify_efi_image() {
    local efi_img_path="$1"
    local efi_mount="$2"
    local has_loader=false
    local has_kernel=false
    
    if [ -z "${efi_mount}" ] || [ ! -d "${efi_mount}" ]; then
        echo "false false"
        return 1
    fi
    
    # Check for loader entries
    if [ -d "${efi_mount}/EFI/archiso/loader/entries" ] && [ -n "$(ls -A "${efi_mount}/EFI/archiso/loader/entries" 2>/dev/null)" ]; then
        has_loader=true
    fi
    
    # Check for kernel/initramfs files
    if [ -f "${efi_mount}/EFI/archiso/boot/x86_64/vmlinuz-linux" ] && [ -f "${efi_mount}/EFI/archiso/boot/x86_64/initramfs-linux.img" ]; then
        has_kernel=true
    fi
    
    echo "${has_loader} ${has_kernel}"
}

# Function to copy loader configuration to EFI image
copy_loader_config() {
    local efi_mount="$1"
    local loader_dir="$2"
    local loader_entries_dir="$3"
    
    if [ -z "${efi_mount}" ] || [ ! -d "${efi_mount}" ]; then
        return 1
    fi
    
    if [ ! -d "${loader_entries_dir}" ] || [ ! -f "${loader_dir}/loader.conf" ]; then
        return 1
    fi
    
    echo -e "${BLUE}Copying boot menu configuration into EFI boot image...${NC}"
    sudo mkdir -p "${efi_mount}/loader/entries"
    
    # Copy loader.conf
    if [ -f "${loader_dir}/loader.conf" ]; then
        sudo cp "${loader_dir}/loader.conf" "${efi_mount}/loader/" || true
        echo -e "${GREEN}✓ Copied loader.conf${NC}"
    fi
    
    # Copy all boot menu entries
    if [ -d "${loader_entries_dir}" ]; then
        sudo cp -r "${loader_entries_dir}"/* "${efi_mount}/loader/entries/" 2>/dev/null || true
        local entry_count=$(ls -1 "${loader_entries_dir}"/*.conf 2>/dev/null | wc -l)
        if [ "${entry_count}" -gt 0 ]; then
            echo -e "${GREEN}✓ Copied ${entry_count} boot menu entries${NC}"
        fi
    fi
}

# Function to copy kernel files to EFI image
copy_kernel_files() {
    local efi_mount="$1"
    local kernel_src="$2"
    
    if [ -z "${efi_mount}" ] || [ ! -d "${efi_mount}" ]; then
        return 1
    fi
    
    if [ ! -d "${kernel_src}" ]; then
        echo -e "${YELLOW}⚠ Kernel source directory not found: ${kernel_src}${NC}"
        return 1
    fi
    
    local kernel_dst="${efi_mount}/EFI/archiso/boot/x86_64"
    echo -e "${BLUE}Copying kernel/initramfs files into EFI boot image...${NC}"
    sudo mkdir -p "${kernel_dst}"

    # Copy kernel — REQUIRED, fail hard if this fails (truncated vmlinuz → "Unsupported")
    if [ ! -f "${kernel_src}/vmlinuz-linux" ]; then
        echo -e "${RED}FATAL: vmlinuz-linux not found at ${kernel_src}${NC}" >&2
        return 1
    fi
    if ! sudo cp "${kernel_src}/vmlinuz-linux" "${kernel_dst}/"; then
        echo -e "${RED}FATAL: Failed to copy vmlinuz-linux into EFI image (out of space?)${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}✓ Copied vmlinuz-linux ($(du -h "${kernel_src}/vmlinuz-linux" | cut -f1))${NC}"

    # Copy initramfs — REQUIRED, fail hard if this fails
    if [ ! -f "${kernel_src}/initramfs-linux.img" ]; then
        echo -e "${RED}FATAL: initramfs-linux.img not found at ${kernel_src}${NC}" >&2
        return 1
    fi
    if ! sudo cp "${kernel_src}/initramfs-linux.img" "${kernel_dst}/"; then
        echo -e "${RED}FATAL: Failed to copy initramfs-linux.img into EFI image (out of space?)${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}✓ Copied initramfs-linux.img ($(du -h "${kernel_src}/initramfs-linux.img" | cut -f1))${NC}"

    # NOTE: fallback initramfs intentionally NOT copied into efiboot.img.
    # No boot entry references it, and at ~240MB it would require a much larger image.
    # The fallback is available in arch/boot/x86_64/ on the ISO filesystem for recovery.

    # Copy linux-cachyos fallback kernel into EFI image (if present in ISO boot dir)
    if [ -f "${kernel_src}/vmlinuz-linux-cachyos" ]; then
        if sudo cp "${kernel_src}/vmlinuz-linux-cachyos" "${kernel_dst}/"; then
            echo -e "${GREEN}✓ Copied vmlinuz-linux-cachyos into EFI image (fallback)${NC}"
        fi
        if [ -f "${kernel_src}/initramfs-linux-cachyos.img" ]; then
            sudo cp "${kernel_src}/initramfs-linux-cachyos.img" "${kernel_dst}/" 2>/dev/null && \
                echo -e "${GREEN}  ✓ initramfs-linux-cachyos.img into EFI image${NC}" || true
        fi
    fi

    # Copy microcode updates (optional)
    for ucode in amd-ucode.img intel-ucode.img; do
        if [ -f "${kernel_src}/${ucode}" ]; then
            if ! sudo cp "${kernel_src}/${ucode}" "${kernel_dst}/"; then
                echo -e "${YELLOW}⚠ Could not copy ${ucode} into EFI image (non-fatal)${NC}"
            else
                echo -e "${GREEN}✓ Copied ${ucode}${NC}"
            fi
        fi
    done
}

# Function to fix EFI boot structure for systemd-boot
# systemd-boot expects loader configuration at /loader/ (root of EFI partition), not /EFI/archiso/loader/
fix_efi_boot_structure() {
    local EFI_MOUNT="$1"
    
    if [ -z "${EFI_MOUNT}" ] || [ ! -d "${EFI_MOUNT}" ]; then
        echo -e "${RED}Error: Invalid EFI mount point${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}Fixing EFI boot structure for systemd-boot...${NC}"
    
    # 1. Copy loader configuration to root level
    # Only copy if not already at root level (to avoid unnecessary operations)
    if [ -f "${EFI_MOUNT}/EFI/archiso/loader/loader.conf" ] && [ ! -f "${EFI_MOUNT}/loader/loader.conf" ]; then
        sudo mkdir -p "${EFI_MOUNT}/loader/entries"
        sudo cp "${EFI_MOUNT}/EFI/archiso/loader/loader.conf" "${EFI_MOUNT}/loader/loader.conf" || true
        echo -e "${GREEN}✓ Copied loader.conf to root level${NC}"
    elif [ -f "${EFI_MOUNT}/loader/loader.conf" ]; then
        echo -e "${BLUE}Loader.conf already at root level${NC}"
    fi
    
    # Copy boot menu entries to root level
    if [ -d "${EFI_MOUNT}/EFI/archiso/loader/entries" ]; then
        sudo mkdir -p "${EFI_MOUNT}/loader/entries"
        sudo cp -r "${EFI_MOUNT}/EFI/archiso/loader/entries"/* "${EFI_MOUNT}/loader/entries/" 2>/dev/null || true
        ENTRY_COUNT=$(ls -1 "${EFI_MOUNT}/loader/entries"/*.conf 2>/dev/null | wc -l)
        if [ "${ENTRY_COUNT}" -gt 0 ]; then
            echo -e "${GREEN}✓ Copied ${ENTRY_COUNT} boot entries to root level${NC}"
        fi
    elif [ -d "${EFI_MOUNT}/loader/entries" ]; then
        ENTRY_COUNT=$(ls -1 "${EFI_MOUNT}/loader/entries"/*.conf 2>/dev/null | wc -l)
        if [ "${ENTRY_COUNT}" -gt 0 ]; then
            echo -e "${BLUE}Boot entries already at root level (${ENTRY_COUNT} entries)${NC}"
        fi
    fi
    
    # 2. Detect kernel file location
    KERNEL_PATH=""
    INITRD_PATH=""
    
    # Check inside efiboot.img first
    if [ -f "${EFI_MOUNT}/EFI/archiso/boot/x86_64/vmlinuz-linux" ]; then
        KERNEL_PATH="/EFI/archiso/boot/x86_64/vmlinuz-linux"
        INITRD_PATH="/EFI/archiso/boot/x86_64/initramfs-linux.img"
        echo -e "${BLUE}Found kernel inside efiboot.img at ${KERNEL_PATH}${NC}"
    # Check ISO root paths (these won't work from efiboot.img, but we'll try to update paths anyway)
    elif [ -f "arch/boot/x86_64/vmlinuz-linux" ]; then
        KERNEL_PATH="/arch/boot/x86_64/vmlinuz-linux"
        INITRD_PATH="/arch/boot/x86_64/initramfs-linux.img"
        echo -e "${BLUE}Found kernel in ISO root at ${KERNEL_PATH}${NC}"
    # Check EFI/BOOT as fallback
    elif [ -f "${EFI_MOUNT}/EFI/BOOT/vmlinuz-linux" ]; then
        KERNEL_PATH="/EFI/BOOT/vmlinuz-linux"
        INITRD_PATH="/EFI/BOOT/initramfs-linux.img"
        echo -e "${BLUE}Found kernel in EFI/BOOT at ${KERNEL_PATH}${NC}"
    else
        echo -e "${YELLOW}⚠ Could not detect kernel location, boot entries may need manual path updates${NC}"
    fi
    
    # 3. Fix boot entry paths to match actual file locations (/arch/boot/x86_64/)
    if [ -d "${EFI_MOUNT}/loader/entries" ]; then
        echo -e "${BLUE}Fixing boot entry paths in efiboot.img...${NC}"
        for ENTRY_FILE in "${EFI_MOUNT}/loader/entries"/*.conf; do
            if [ -f "${ENTRY_FILE}" ]; then
                # Fix linux path to /arch/boot/x86_64/
                sudo sed -i 's|^linux[[:space:]]*/.*/boot/|linux    /arch/boot/|' "${ENTRY_FILE}" 2>/dev/null || true
                # Fix initrd path to /arch/boot/x86_64/
                sudo sed -i 's|^initrd[[:space:]]*/.*/boot/|initrd   /arch/boot/|' "${ENTRY_FILE}" 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}✓ Fixed boot entry paths${NC}"
    fi
    
    # 3.5. Fix volume ID in boot entries (use archisolabel with volume label)
    if [ -d "${EFI_MOUNT}/loader/entries" ]; then
        echo -e "${BLUE}Updating boot entry volume ID...${NC}"
        for ENTRY_FILE in "${EFI_MOUNT}/loader/entries"/*.conf; do
            if [ -f "${ENTRY_FILE}" ]; then
                # Replace archisosearchuuid with archisolabel using our volume label
                sudo sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${ENTRY_FILE}" 2>/dev/null || true
                # Ensure archisolabel uses our volume label
                sudo sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${ENTRY_FILE}" 2>/dev/null || true
                # Fix options line to use archisolabel
                sudo sed -i "s|^options .*|options archisobasedir=arch archisolabel=${JARVISOS_VOLID}|g" "${ENTRY_FILE}" 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}✓ Updated boot entry volume IDs${NC}"
    fi
    
    # 3.6. Rebrand boot entries inside efiboot.img
    if [ -d "${EFI_MOUNT}/loader/entries" ]; then
        for ENTRY_FILE in "${EFI_MOUNT}/loader/entries"/*.conf; do
            if [ -f "${ENTRY_FILE}" ]; then
                sudo sed -i 's/Arch Linux install medium/JarvisOS/g' "${ENTRY_FILE}" 2>/dev/null || true
                sudo sed -i 's/Arch Linux/JarvisOS/g' "${ENTRY_FILE}" 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}✓ Rebranded boot entries in efiboot.img${NC}"
    fi

    # 4. Ensure BOOTx64.EFI exists
    if [ ! -f "${EFI_MOUNT}/EFI/BOOT/BOOTx64.EFI" ]; then
        # Try to copy from systemd-boot location
        if [ -f "${EFI_MOUNT}/EFI/systemd/systemd-bootx64.efi" ]; then
            sudo mkdir -p "${EFI_MOUNT}/EFI/BOOT"
            sudo cp "${EFI_MOUNT}/EFI/systemd/systemd-bootx64.efi" "${EFI_MOUNT}/EFI/BOOT/BOOTx64.EFI" || true
            echo -e "${GREEN}✓ Copied systemd-bootx64.efi to BOOTx64.EFI${NC}"
        elif [ -f "${EFI_MOUNT}/EFI/archiso/loader/loader.conf" ]; then
            # If loader.conf exists but BOOTx64.EFI doesn't, this is a problem
            echo -e "${YELLOW}⚠ BOOTx64.EFI not found and cannot be created from systemd-boot${NC}"
        fi
    else
        echo -e "${GREEN}✓ BOOTx64.EFI exists${NC}"
    fi
    
    echo -e "${GREEN}✓ EFI boot structure fixed${NC}"
}

# Function to create new EFI boot image from EFI/BOOT directory
create_efi_image() {
    local efi_img_path="$1"
    local efi_boot_dir="$2"
    local loader_dir="$3"
    local loader_entries_dir="$4"
    local efi_archiso_dir="$5"
    
    echo -e "${BLUE}Creating EFI boot image from EFI/BOOT directory...${NC}"
    
    # Check if required tools are available, auto-install if missing
    if ! command -v mkfs.fat &> /dev/null && ! command -v mkfs.vfat &> /dev/null; then
        echo -e "${YELLOW}Warning: mkfs.fat/mkfs.vfat not found. Attempting to install dosfstools...${NC}"
        # install_host_package detects the running distro automatically
        install_host_package "dosfstools" "dosfstools" "dosfstools" "dosfstools" 2>/dev/null || \
            echo -e "${YELLOW}Could not install dosfstools automatically${NC}"
    fi

    # Determine mkfs command
    local mkfs_cmd=""
    if command -v mkfs.fat &> /dev/null; then
        mkfs_cmd="mkfs.fat"
    elif command -v mkfs.vfat &> /dev/null; then
        mkfs_cmd="mkfs.vfat"
    else
        echo -e "${RED}Error: mkfs.fat or mkfs.vfat not found. Please install dosfstools${NC}" >&2
        echo -e "${YELLOW}Install: $(pkg_install_hint dosfstools)${NC}"
        return 1
    fi
    
    # Create archiso directory if it doesn't exist
    mkdir -p "${efi_archiso_dir}"

    # Create a temporary mount point
    local efi_mount=$(mktemp -d)

    # Calculate required image size from actual file sizes + 30% FAT32 overhead.
    # This prevents the silent truncation bug: the original Arch efiboot.img is
    # sized for the stock Arch kernel/initramfs (~100MB). Our initramfs is ~240MB.
    # Trying to update the old image in-place causes ENOSPC → truncated files →
    # "Error loading EFI binary: Unsupported" from the EFI firmware.
    local _content_bytes=0
    for _f in "${efi_boot_dir}/BOOTx64.EFI" "${efi_boot_dir}/BOOTIA32.EFI" \
               "arch/boot/x86_64/vmlinuz-linux" \
               "arch/boot/x86_64/initramfs-linux.img" \
               "arch/boot/x86_64/amd-ucode.img" \
               "arch/boot/x86_64/intel-ucode.img" \
               "arch/boot/x86_64/vmlinuz-linux-cachyos" \
               "arch/boot/x86_64/initramfs-linux-cachyos.img"; do
        [ -f "${_f}" ] && _content_bytes=$((_content_bytes + $(stat -c%s "${_f}")))
    done
    # Add 32MB for EFI shells, loader config, FAT metadata; then 30% overhead buffer
    local _efi_size_mb=$(((_content_bytes / 1048576) + 32))
    _efi_size_mb=$((_efi_size_mb + _efi_size_mb / 3))
    [ "${_efi_size_mb}" -lt 64 ] && _efi_size_mb=64
    echo -e "${BLUE}Creating FAT32 filesystem image (${_efi_size_mb}MB for $((_content_bytes / 1048576))MB content)...${NC}"
    dd if=/dev/zero of="${efi_img_path}" bs=1M count="${_efi_size_mb}" status=progress
    
    # Format as FAT32 with label
    ${mkfs_cmd} -F 32 -n "ARCHISO_EFI" "${efi_img_path}" >/dev/null 2>&1 || {
        echo -e "${RED}Error: Failed to format EFI boot image${NC}" >&2
        rm -f "${efi_img_path}"
        rmdir "${efi_mount}" 2>/dev/null || true
        return 1
    }
    
    # Mount the image
    if ! sudo mount -o loop "${efi_img_path}" "${efi_mount}" 2>/dev/null; then
        echo -e "${RED}Error: Failed to mount EFI boot image${NC}" >&2
        rm -f "${efi_img_path}"
        rmdir "${efi_mount}" 2>/dev/null || true
        return 1
    fi
    
    # Create EFI/BOOT directory structure in the image
    sudo mkdir -p "${efi_mount}/EFI/BOOT"
    
    # Copy EFI boot files
    echo -e "${BLUE}Copying EFI boot files...${NC}"
    if [ -f "${efi_boot_dir}/BOOTx64.EFI" ]; then
        sudo cp "${efi_boot_dir}/BOOTx64.EFI" "${efi_mount}/EFI/BOOT/" || true
        echo -e "${GREEN}✓ Copied BOOTx64.EFI${NC}"
    fi
    if [ -f "${efi_boot_dir}/BOOTIA32.EFI" ]; then
        sudo cp "${efi_boot_dir}/BOOTIA32.EFI" "${efi_mount}/EFI/BOOT/" || true
        echo -e "${GREEN}✓ Copied BOOTIA32.EFI${NC}"
    fi
    
    # Copy loader configuration
    copy_loader_config "${efi_mount}" "${loader_dir}" "${loader_entries_dir}"
    
    # Copy kernel/initramfs files (REQUIRED — fail loudly if this fails)
    if ! copy_kernel_files "${efi_mount}" "arch/boot/x86_64"; then
        echo -e "${RED}FATAL: Failed to copy kernel files into EFI image${NC}" >&2
        unmount_efi_image "${efi_mount}"
        rm -f "${efi_img_path}"
        return 1
    fi

    # Fix EFI boot structure for systemd-boot
    fix_efi_boot_structure "${efi_mount}"

    # Unmount the image
    unmount_efi_image "${efi_mount}"
    
    if [ -f "${efi_img_path}" ]; then
        echo -e "${GREEN}✓ Created EFI boot image: ${efi_img_path}${NC}"
        if [ -d "${loader_entries_dir}" ] && [ -f "${loader_dir}/loader.conf" ]; then
            echo -e "${GREEN}  (Contains full boot menu configuration with all options)${NC}"
        else
            echo -e "${YELLOW}  Note: Created EFI image, but boot menu configuration was not found.${NC}"
        fi
        return 0
    else
        echo -e "${RED}Error: Failed to create EFI boot image${NC}" >&2
        return 1
    fi
}

# ── ALWAYS recreate efiboot.img from scratch ─────────────────────────────────
# ROOT CAUSE OF "Error loading EFI binary: Unsupported":
#   The original Arch ISO's efiboot.img is sized for the stock Arch kernel and
#   initramfs (~100MB total). Our linux-jarvisos initramfs is ~240MB. Trying to
#   update the existing image in-place causes silent ENOSPC: cp fails but
#   "|| true" swallowed the error, leaving a 4.5MB truncated vmlinuz (should be
#   16MB). The EFI firmware refuses to load a corrupt PE/COFF image → "Unsupported".
# FIX: Always delete and recreate efiboot.img with dynamically calculated sizing.
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Recreating EFI boot image (fresh, correctly sized)...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ -f "${EFI_IMG_PATH}" ]; then
    echo -e "${BLUE}Removing existing efiboot.img (was sized for stock Arch kernel)...${NC}"
    rm -f "${EFI_IMG_PATH}"
fi

mkdir -p "${EFI_ARCHISO_DIR}"

if [ ! -d "${EFI_BOOT_DIR}" ]; then
    echo -e "${RED}FATAL: ${EFI_BOOT_DIR} not found — EFI boot files missing from ISO extract${NC}" >&2
    exit 1
fi

if ! create_efi_image "${EFI_IMG_PATH}" "${EFI_BOOT_DIR}" "${LOADER_DIR}" "${LOADER_ENTRIES_DIR}" "${EFI_ARCHISO_DIR}"; then
    echo -e "${RED}FATAL: Failed to create EFI boot image${NC}" >&2
    exit 1
fi

# Find EFI boot image (case-insensitive search)
for path in "EFI/archiso/efiboot.img" "EFI/archiso/EFIBOOT.IMG" "EFI/boot/efiboot.img" "EFI/boot/EFIBOOT.IMG"; do
    if [ -f "${path}" ]; then
        EFI_IMG="${path}"
        echo -e "${GREEN}✓ Found EFI boot image: ${path}${NC}"
        break
    fi
done

# Also search case-insensitively
if [ -z "${EFI_IMG}" ]; then
    EFI_FOUND=$(find . -iname "efiboot.img" -type f 2>/dev/null | head -1)
    if [ -n "${EFI_FOUND}" ]; then
        EFI_IMG="${EFI_FOUND#./}"  # Remove leading ./
        echo -e "${GREEN}✓ Found EFI boot image: ${EFI_IMG}${NC}"
    fi
fi

# Verify required boot files are found
if [ -z "${ISOLINUX_BIN}" ] || [ -z "${ISOHDPFX_BIN}" ]; then
    echo -e "${RED}Error: Required boot files not found!${NC}" >&2
    echo -e "${YELLOW}Missing:${NC}"
    [ -z "${ISOLINUX_BIN}" ] && echo -e "${YELLOW}  - isolinux.bin${NC}"
    [ -z "${ISOHDPFX_BIN}" ] && echo -e "${YELLOW}  - isohdpfx.bin${NC}"
    echo -e "${YELLOW}Available boot files:${NC}"
    find . -name "*.bin" -o -name "*.cat" 2>/dev/null | head -10
    exit 1
fi

# Regenerate boot.cat if it doesn't exist or is old
# boot.cat is the boot catalog needed for BIOS boot
if [ ! -f "${BOOT_CAT:-boot/syslinux/boot.cat}" ] || [ "${ISOLINUX_BIN}" -nt "${BOOT_CAT:-boot/syslinux/boot.cat}" ]; then
    echo -e "${BLUE}Regenerating boot.cat...${NC}"
    BOOT_CAT_DIR=$(dirname "${BOOT_CAT:-boot/syslinux/boot.cat}")
    mkdir -p "${BOOT_CAT_DIR}"
    # boot.cat will be created by xorriso, but we ensure the directory exists
    touch "${BOOT_CAT:-boot/syslinux/boot.cat}" 2>/dev/null || true
fi

# ============================================================================
# BRANDING: Replace "Arch Linux" with "JarvisOS" in all boot menus
# ============================================================================
echo -e "${BLUE}Applying JarvisOS branding to boot menus...${NC}"

# Rebrand UEFI systemd-boot entries
if [ -d "loader/entries" ]; then
    for entry in loader/entries/*.conf; do
        if [ -f "${entry}" ]; then
            sed -i 's/Arch Linux install medium/JarvisOS/g' "${entry}"
            sed -i 's/Arch Linux/JarvisOS/g' "${entry}"
        fi
    done
    echo -e "${GREEN}✓ Rebranded UEFI boot entries (Arch Linux → JarvisOS)${NC}"
fi

# Rebrand CachyOS → JarvisOS in all boot configs
echo -e "${BLUE}Rebranding CachyOS → JarvisOS in boot menus...${NC}"
for _rebrand_cfg in "loader/entries/"*.conf \
                    "boot/syslinux/"*.cfg \
                    "boot/grub/loopback.cfg" \
                    "boot/grub/grub.cfg"; do
    [ -f "${_rebrand_cfg}" ] || continue
    sed -i 's/CachyOS Linux install medium/JarvisOS/g' "${_rebrand_cfg}" 2>/dev/null || true
    sed -i 's/CachyOS Linux live medium/JarvisOS/g'    "${_rebrand_cfg}" 2>/dev/null || true
    sed -i 's/CachyOS Linux/JarvisOS/g'                "${_rebrand_cfg}" 2>/dev/null || true
    sed -i 's/CachyOS/JarvisOS/g'                      "${_rebrand_cfg}" 2>/dev/null || true
done
echo -e "${GREEN}✓ Rebranded CachyOS references${NC}"

# Rebrand syslinux BIOS boot menu
if [ -f "boot/syslinux/archiso_head.cfg" ]; then
    sed -i 's/MENU TITLE Arch Linux/MENU TITLE JarvisOS/' "boot/syslinux/archiso_head.cfg"
    sed -i 's/MENU TITLE CachyOS.*/MENU TITLE JarvisOS/'  "boot/syslinux/archiso_head.cfg"
    echo -e "${GREEN}✓ Rebranded syslinux menu title${NC}"
fi
for cfg in boot/syslinux/archiso_sys-linux.cfg boot/syslinux/archiso_pxe-linux.cfg; do
    if [ -f "${cfg}" ]; then
        sed -i 's/Arch Linux install medium/JarvisOS/g' "${cfg}"
        sed -i 's/Arch Linux live medium/JarvisOS/g' "${cfg}"
        sed -i 's/Arch Linux/JarvisOS/g' "${cfg}"
    fi
done
echo -e "${GREEN}✓ Rebranded syslinux boot entries${NC}"

# Rebrand GRUB loopback.cfg (used when booting ISO from GRUB loopback)
if [ -f "boot/grub/loopback.cfg" ]; then
    sed -i 's/Arch Linux install medium/JarvisOS/g' "boot/grub/loopback.cfg"
    sed -i 's/Arch Linux/JarvisOS/g' "boot/grub/loopback.cfg"
    echo -e "${GREEN}✓ Rebranded GRUB loopback.cfg${NC}"
fi
# Rebrand any other grub.cfg files
for cfg in boot/grub/grub.cfg boot/grub/grubenv; do
    if [ -f "${cfg}" ]; then
        sed -i 's/Arch Linux install medium/JarvisOS/g' "${cfg}" 2>/dev/null || true
        sed -i 's/Arch Linux/JarvisOS/g' "${cfg}" 2>/dev/null || true
    fi
done

# ── Create linux-cachyos fallback boot entries ────────────────────────────────
if [ "${CACHYOS_FALLBACK_IN_ISO}" = true ]; then
    # systemd-boot entry (UEFI)
    if [ -d "loader/entries" ]; then
        cat > "loader/entries/02-jarvisos-cachyos.conf" << CACHYOS_ENTRY_EOF
title    JarvisOS (linux-cachyos fallback)
linux    /arch/boot/x86_64/vmlinuz-linux-cachyos
initrd   /arch/boot/x86_64/initramfs-linux-cachyos.img
options  archisobasedir=arch archisolabel=${JARVISOS_VOLID}
CACHYOS_ENTRY_EOF
        echo -e "${GREEN}✓ Created linux-cachyos fallback systemd-boot entry${NC}"
    fi

    # syslinux entry (BIOS)
    SYSLINUX_CFG="boot/syslinux/archiso_sys-linux.cfg"
    if [ -f "${SYSLINUX_CFG}" ]; then
        cat >> "${SYSLINUX_CFG}" << SYSLINUX_CACHYOS_EOF

LABEL cachyos-fallback
  MENU LABEL JarvisOS (linux-cachyos fallback)
  LINUX    /arch/boot/x86_64/vmlinuz-linux-cachyos
  INITRD   /arch/boot/x86_64/initramfs-linux-cachyos.img
  APPEND   archisobasedir=arch archisolabel=${JARVISOS_VOLID}
SYSLINUX_CACHYOS_EOF
        echo -e "${GREEN}✓ Created linux-cachyos fallback syslinux entry${NC}"
    fi
fi

# CRITICAL FIX: Update ALL boot configs to use archisolabel instead of archisosearchuuid
# The original CachyOS/Arch ISO embeds a timestamp UUID (e.g. 2026-03-08-13-36-02-00)
# that is specific to the source ISO creation date. When we rebuild with xorriso the
# volume label changes (JARVISOS_YYYYMM) so the old UUID no longer matches anything on
# the boot medium → archiso hook searches every block device and gives up with
# "ERROR: Device '...' not found". Fix: switch every boot config to archisolabel=
# which matches the volume label we pass to xorriso -volid.
# NOTE: grub.cfg is the primary bootloader for CachyOS ISOs and MUST be included here.
echo -e "${BLUE}Fixing ALL boot configs (archisosearchuuid → archisolabel)...${NC}"
for cfg in boot/syslinux/archiso_sys-linux.cfg \
            boot/syslinux/archiso_pxe-linux.cfg \
            boot/grub/grub.cfg \
            boot/grub/loopback.cfg; do
    if [ -f "${cfg}" ]; then
        # Replace archisosearchuuid=<anything> with archisolabel=<our label>
        sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${cfg}"
        # Normalise any existing archisolabel to our volume ID
        sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${cfg}"
        echo -e "${GREEN}✓ Fixed $(basename "${cfg}")${NC}"
    fi
done

# CRITICAL FIX: Update boot entry paths to match actual file locations
echo -e "${BLUE}Fixing boot entry paths...${NC}"

# Fix paths in loader entries from /EFI/archiso/boot/ to /arch/boot/
if [ -d "loader/entries" ]; then
    for entry in loader/entries/*.conf; do
        if [ -f "${entry}" ]; then
            # Fix linux path
            sed -i 's|^linux[[:space:]]*/.*/boot/|linux    /arch/boot/|' "${entry}"
            # Fix initrd path
            sed -i 's|^initrd[[:space:]]*/.*/boot/|initrd   /arch/boot/|' "${entry}"
            # Replace archisosearchuuid with archisolabel using our volume label
            sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
            sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
            # Fix options line to use archisolabel
            sed -i "s|^options .*|options archisobasedir=arch archisolabel=${JARVISOS_VOLID}|g" "${entry}"
            echo -e "${GREEN}✓ Fixed $(basename "${entry}")${NC}"
        fi
    done
fi

# CRITICAL FIX: Create proper UUID file
echo -e "${BLUE}Fixing UUID file...${NC}"
# Remove ALL old UUID files (any year pattern, not just 2026)
find boot/ -name "*.uuid" -delete 2>/dev/null || true
# Create UUID file with volume label
echo "${JARVISOS_VOLID}" > "boot/${JARVISOS_VOLID}.uuid"
echo -e "${GREEN}✓ Created boot/${JARVISOS_VOLID}.uuid${NC}"

# CRITICAL: Also fix paths inside efiboot.img
EFI_IMG_PATH="EFI/archiso/efiboot.img"
if [ -f "${EFI_IMG_PATH}" ]; then
    echo -e "${BLUE}Fixing boot entries inside efiboot.img...${NC}"
    EFI_MOUNT=$(mktemp -d)
    
    if sudo mount -o loop "${EFI_IMG_PATH}" "${EFI_MOUNT}" 2>/dev/null; then
        # Fix paths to match actual file locations inside efiboot.img
        if [ -d "${EFI_MOUNT}/loader/entries" ]; then
            for entry in "${EFI_MOUNT}/loader/entries"/*.conf; do
                if [ -f "${entry}" ]; then
                    # Files inside efiboot.img are at /EFI/archiso/boot/x86_64/
                    sudo sed -i 's|^linux[[:space:]]*/arch/boot/|linux    /EFI/archiso/boot/|' "${entry}"
                    sudo sed -i 's|^initrd[[:space:]]*/arch/boot/|initrd   /EFI/archiso/boot/|' "${entry}"
                    # Replace archisosearchuuid with archisolabel using our volume label
                    sudo sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
                    sudo sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
                    # Fix options line to use archisolabel
                    sudo sed -i "s|^options .*|options archisobasedir=arch archisolabel=${JARVISOS_VOLID}|g" "${entry}"
                    # Rebrand CachyOS inside efiboot.img
                    sudo sed -i 's/CachyOS Linux install medium/JarvisOS/g' "${entry}" 2>/dev/null || true
                    sudo sed -i 's/CachyOS Linux/JarvisOS/g'                "${entry}" 2>/dev/null || true
                    sudo sed -i 's/CachyOS/JarvisOS/g'                      "${entry}" 2>/dev/null || true
                    echo -e "${GREEN}✓ Fixed $(basename "${entry}") in efiboot.img${NC}"
                fi
            done

            # Create linux-cachyos fallback entry inside efiboot.img
            if [ "${CACHYOS_FALLBACK_IN_ISO}" = true ]; then
                sudo tee "${EFI_MOUNT}/loader/entries/02-jarvisos-cachyos.conf" > /dev/null << CACHYOS_EFI_EOF
title    JarvisOS (linux-cachyos fallback)
linux    /EFI/archiso/boot/x86_64/vmlinuz-linux-cachyos
initrd   /EFI/archiso/boot/x86_64/initramfs-linux-cachyos.img
options  archisobasedir=arch archisolabel=${JARVISOS_VOLID}
CACHYOS_EFI_EOF
                echo -e "${GREEN}✓ Created linux-cachyos fallback entry in efiboot.img${NC}"
            fi
        fi

        sudo umount "${EFI_MOUNT}" || sudo umount -l "${EFI_MOUNT}"
    fi
    rmdir "${EFI_MOUNT}" 2>/dev/null || true
fi

# Build ISO with proper boot structure
# CRITICAL: Use archisolabel instead of archisosearchuuid
# xorriso auto-generates timestamp UUID which we cannot control
# archisolabel uses the volume label (JARVISOS_202601) which we DO control

echo -e "${BLUE}Building ISO...${NC}"

# Ensure output directory exists
OUTPUT_DIR=$(dirname "${OUTPUT_ISO_ABS}")
mkdir -p "${OUTPUT_DIR}" || {
    echo -e "${RED}Error: Cannot create output directory: ${OUTPUT_DIR}${NC}" >&2
    exit 1
}

# Update boot entries to use archisolabel (volume label we control)
echo -e "${BLUE}Updating boot entries to use archisolabel (second pass)...${NC}"

# Update grub configs (second pass to catch any that were regenerated above)
for cfg in boot/grub/grub.cfg boot/grub/loopback.cfg; do
    if [ -f "${cfg}" ]; then
        sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${cfg}"
        sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${cfg}"
        echo -e "${GREEN}✓ Updated $(basename "${cfg}")${NC}"
    fi
done

# Update ISO root loader entries
if [ -d "loader/entries" ]; then
    for entry in loader/entries/*.conf; do
        if [ -f "${entry}" ]; then
            sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
            sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
            echo -e "${GREEN}✓ Updated $(basename "${entry}")${NC}"
        fi
    done
fi

# Update efiboot.img loader entries
EFI_IMG_PATH="EFI/archiso/efiboot.img"
if [ -f "${EFI_IMG_PATH}" ]; then
    EFI_MOUNT=$(mktemp -d)
    if sudo mount -o loop "${EFI_IMG_PATH}" "${EFI_MOUNT}" 2>/dev/null; then
        if [ -d "${EFI_MOUNT}/loader/entries" ]; then
            for entry in "${EFI_MOUNT}/loader/entries"/*.conf; do
                if [ -f "${entry}" ]; then
                    sudo sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
                    sudo sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
                    echo -e "${GREEN}✓ Updated $(basename "${entry}") in efiboot.img${NC}"
                fi
            done
        fi
        sudo umount "${EFI_MOUNT}" || sudo umount -l "${EFI_MOUNT}"
    fi
    rmdir "${EFI_MOUNT}" 2>/dev/null || true
fi

# Update UUID files - use volume label instead of timestamp
find boot/ -name "*.uuid" -delete 2>/dev/null || true
echo "${JARVISOS_VOLID}" > "boot/${JARVISOS_VOLID}.uuid"
echo -e "${GREEN}✓ Created boot/${JARVISOS_VOLID}.uuid${NC}"

# Build ISO with proper boot structure
if [ -n "${ISOLINUX_BIN}" ] && [ -n "${ISOHDPFX_BIN}" ] && [ -n "${EFI_IMG}" ] && [ -f "${EFI_IMG}" ]; then
    # Dual boot (BIOS + UEFI) - preferred
    # CRITICAL: These flags match Arch Linux ISO boot structure for USB compatibility
    # -partition_offset 16: Creates proper partition offset (Arch Linux standard)
    # -partition_cyl_align off: Matches Arch ISO cylinder alignment setting
    # --mbr-force-bootable: Ensures MBR partition has boot flag (0x80) for legacy BIOS boot
    echo -e "${BLUE}Using dual boot structure (BIOS + UEFI)...${NC}"
    XORRISO_OUTPUT=$(xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -joliet \
        -joliet-long \
        -rational-rock \
        -volid "${JARVISOS_VOLID}" \
        -publisher "JARVIS OS PROJECT" \
        -preparer "JARVISOS BUILD SYSTEM" \
        -appid "JARVISOS LIVE/INSTALL MEDIUM" \
        -partition_offset 16 \
        -partition_cyl_align off \
        -eltorito-boot "${ISOLINUX_BIN}" \
        -eltorito-catalog "${BOOT_CAT:-boot/syslinux/boot.cat}" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX_BIN}" \
        --mbr-force-bootable \
        -eltorito-alt-boot \
        -e "${EFI_IMG}" \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -append_partition 2 0xef "${EFI_IMG}" \
        -output "${OUTPUT_ISO_ABS}" \
        . 2>&1)
    
    XORRISO_EXIT=$?
    
    if [ ${XORRISO_EXIT} -ne 0 ]; then
        echo -e "${RED}Error: xorriso failed with exit code ${XORRISO_EXIT}${NC}" >&2
        echo -e "${YELLOW}Full xorriso output:${NC}"
        echo "${XORRISO_OUTPUT}"
        echo ""
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo "  - Check if output directory exists: ${OUTPUT_DIR}"
        echo "  - Check disk space: df -h ${OUTPUT_DIR}"
        echo "  - Check if boot files are valid"
        exit 1
    fi
    
    # Show filtered output on success
    echo "${XORRISO_OUTPUT}" | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" | tail -20 || true
elif [ -n "${ISOLINUX_BIN}" ] && [ -n "${ISOHDPFX_BIN}" ]; then
    # BIOS boot only
    # CRITICAL: These flags match Arch Linux ISO boot structure for USB compatibility
    # -partition_offset 16: Creates proper partition offset (Arch Linux standard)
    # -partition_cyl_align off: Matches Arch ISO cylinder alignment setting
    # --mbr-force-bootable: Ensures MBR partition has boot flag (0x80) for legacy BIOS boot
    echo -e "${BLUE}Using BIOS boot structure (UEFI boot files not found)...${NC}"
    
    XORRISO_OUTPUT=$(xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -joliet \
        -joliet-long \
        -rational-rock \
        -volid "${JARVISOS_VOLID}" \
        -publisher "JARVIS OS PROJECT" \
        -preparer "JARVISOS BUILD SYSTEM" \
        -appid "JARVISOS LIVE/INSTALL MEDIUM" \
        -partition_offset 16 \
        -partition_cyl_align off \
        -eltorito-boot "${ISOLINUX_BIN}" \
        -eltorito-catalog "${BOOT_CAT:-boot/syslinux/boot.cat}" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX_BIN}" \
        --mbr-force-bootable \
        -output "${OUTPUT_ISO_ABS}" \
        . 2>&1)
    
    XORRISO_EXIT=$?
    
    if [ ${XORRISO_EXIT} -ne 0 ]; then
        echo -e "${RED}Error: xorriso failed with exit code ${XORRISO_EXIT}${NC}" >&2
        echo -e "${YELLOW}Full xorriso output:${NC}"
        echo "${XORRISO_OUTPUT}"
        echo ""
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo "  - Output directory: ${OUTPUT_DIR}"
        echo "  - Disk space: $(df -h "${OUTPUT_DIR}" | tail -1 | awk '{print $4 " available"}')"
        echo "  - Boot files: ${ISOLINUX_BIN}, ${ISOHDPFX_BIN}"
        exit 1
    fi
    
    # Show filtered output on success
    echo "${XORRISO_OUTPUT}" | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" | tail -20 || true
else
    echo -e "${RED}Error: Insufficient boot files found${NC}" >&2
    exit 1
fi

echo -e "${GREEN}✓ ISO built successfully with volume label: ${JARVISOS_VOLID}${NC}"

# Verify ISO was created
if [ ! -f "${OUTPUT_ISO_ABS}" ]; then
    echo -e "${RED}Error: ISO file was not created!${NC}" >&2
    exit 1
fi

# Show ISO information
ISO_SIZE=$(du -h "${OUTPUT_ISO_ABS}" 2>/dev/null | cut -f1)
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 7 complete: ISO rebuilt${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}ISO: ${OUTPUT_ISO_ABS}${NC}"
echo -e "${BLUE}Size: ${ISO_SIZE}${NC}"
echo -e "${BLUE}Boot: ${ISOLINUX_BIN}${NC}"
if [ -n "${EFI_IMG}" ]; then
    echo -e "${BLUE}UEFI: ${EFI_IMG}${NC}"
fi
echo ""
echo -e "${GREEN}✓ ISO is ready for testing!${NC}"
echo -e "${BLUE}Boot the ISO — TUI installer launches automatically on TTY1${NC}"
