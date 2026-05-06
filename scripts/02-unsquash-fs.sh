#!/bin/bash
# Step 2: Unsquash the SquashFS filesystem
# Extracts the compressed root filesystem from the ISO

set -eo pipefail

# Source config file and shared utilities
source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

require_tool "unsquashfs" "squashfs-tools" "squashfs-tools" "squashfs-tools" "squashfs"

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

# Check if step 1 was completed (ISO extracted)
if [ ! -d "${ISO_EXTRACT_DIR}" ] || [ -z "$(ls -A "${ISO_EXTRACT_DIR}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: ISO not extracted. Please run step 1 first${NC}" >&2
    exit 1
fi

# Find SquashFS file (handle both uppercase and lowercase paths)
SQUASHFS_FILE=$(find "${ISO_EXTRACT_DIR}" -type f -iname "airootfs.sfs" | head -1)

if [ -z "${SQUASHFS_FILE}" ] || [ ! -f "${SQUASHFS_FILE}" ]; then
    echo -e "${RED}Error: Could not find airootfs.sfs in extracted ISO${NC}" >&2
    echo -e "${YELLOW}Looking for SquashFS files:${NC}"
    find "${ISO_EXTRACT_DIR}" -type f -iname "*.sfs" | head -5 || echo "  None found"
    exit 1
fi

echo -e "${BLUE}Unsquashing SquashFS filesystem...${NC}"
echo -e "${BLUE}SquashFS file: ${SQUASHFS_FILE}${NC}"
echo -e "${BLUE}Output: ${SQUASHFS_ROOTFS}${NC}"

# Check if unsquashfs is available
if ! command -v unsquashfs &> /dev/null; then
    echo -e "${RED}Error: unsquashfs not found. Please install squashfs-tools${NC}" >&2
    echo -e "${YELLOW}Install: $(pkg_install_hint squashfs-tools)${NC}"
    exit 1
fi

# ── Tear down any leftover mounts from a previous interrupted run ─────────────
# arch-chroot (used in steps 3-5) bind-mounts proc/sys/dev/run into the rootfs.
# If the previous run was interrupted those mounts are still active.  rm -rf on
# a live mountpoint silently fails and unsquashfs then writes device files
# THROUGH the bind-mount onto the host's real /dev, corrupting /dev/null etc.
echo -e "${BLUE}Unmounting any stale mounts in existing rootfs...${NC}"
for _mp in dev/pts dev/shm dev proc sys run tmp; do
    sudo umount -l "${SQUASHFS_ROOTFS}/${_mp}" 2>/dev/null || true
done
sudo umount -l "${SQUASHFS_ROOTFS}" 2>/dev/null || true

# Clean up any existing rootfs (may need sudo for root-owned files)
echo -e "${BLUE}Cleaning up any existing rootfs...${NC}"
sudo rm -rf "${SQUASHFS_ROOTFS}" 2>/dev/null || true

# Create directory with proper permissions
sudo mkdir -p "${SQUASHFS_ROOTFS}"
sudo chown root:root "${SQUASHFS_ROOTFS}" 2>/dev/null || true
sudo chmod 755 "${SQUASHFS_ROOTFS}"

# Extract SquashFS - must extract completely for chroot to work
EXTRACT_LOG="${BUILD_DIR}/squashfs-extract.log"
echo -e "${BLUE}Extracting SquashFS (this may take a minute)...${NC}"
echo -e "${BLUE}Extracting to: ${SQUASHFS_ROOTFS}${NC}"

# Extract with sudo (needed for proper permissions)
# Use -f to force overwrite, -n to not create device files, -no-xattrs to skip extended attributes
if sudo unsquashfs -f -n -no-xattrs -d "${SQUASHFS_ROOTFS}" "${SQUASHFS_FILE}" 2>&1 | tee "${EXTRACT_LOG}"; then
    EXTRACT_EXIT=0
else
    EXTRACT_EXIT=$?
    echo -e "${YELLOW}Warning: unsquashfs exited with code ${EXTRACT_EXIT}${NC}"
fi

# Show extraction summary
if [ -f "${EXTRACT_LOG}" ]; then
    echo -e "${BLUE}Extraction summary:${NC}"
    tail -10 "${EXTRACT_LOG}" | grep -E "created|inodes|blocks|files|directories|extracted" || tail -5 "${EXTRACT_LOG}"
fi

# Wait a moment for filesystem to sync
sleep 1

# Verify extraction succeeded by checking for key directories/files
# CRITICAL: /usr/bin must exist for chroot to work
EXTRACT_VERIFIED=false
if [ -d "${SQUASHFS_ROOTFS}/etc" ] && [ -d "${SQUASHFS_ROOTFS}/boot" ]; then
    # Check if /usr/bin exists directly (most reliable check)
    if [ -d "${SQUASHFS_ROOTFS}/usr/bin" ] || [ -e "${SQUASHFS_ROOTFS}/usr/bin" ]; then
        # Verify it's not empty
        if [ "$(ls -A "${SQUASHFS_ROOTFS}/usr/bin" 2>/dev/null | wc -l)" -gt 0 ]; then
            EXTRACT_VERIFIED=true
        else
            echo -e "${YELLOW}Warning: /usr/bin exists but is empty${NC}"
        fi
    elif [ -L "${SQUASHFS_ROOTFS}/bin" ]; then
        # If bin is a symlink, check if it resolves to usr/bin and that target exists
        BIN_TARGET=$(readlink -f "${SQUASHFS_ROOTFS}/bin" 2>/dev/null || readlink "${SQUASHFS_ROOTFS}/bin")
        if [ -e "${BIN_TARGET}" ] || [ -d "${BIN_TARGET}" ]; then
            # Verify the target directory has files
            if [ -d "${BIN_TARGET}" ] && [ "$(ls -A "${BIN_TARGET}" 2>/dev/null | wc -l)" -gt 0 ]; then
                EXTRACT_VERIFIED=true
            else
                echo -e "${YELLOW}Warning: /bin symlink resolves but target is empty${NC}"
            fi
        fi
    fi
fi

if [ "$EXTRACT_VERIFIED" = "false" ]; then
    echo -e "${RED}Error: SquashFS extraction failed - /usr/bin missing${NC}" >&2
    echo -e "${YELLOW}Checking what was extracted...${NC}"
    ls -la "${SQUASHFS_ROOTFS}" 2>&1 | head -15 || true
    if [ -f "${EXTRACT_LOG}" ]; then
        echo -e "${YELLOW}Checking extraction log for errors...${NC}"
        tail -30 "${EXTRACT_LOG}" | grep -E "error|Error|ERROR|failed|Failed|FAILED|Permission|permission|denied|No space" || tail -20 "${EXTRACT_LOG}"
    fi
    exit 1
fi

echo -e "${GREEN}SquashFS extraction complete!${NC}"

# NEW: Ensure mount point directories exist
echo -e "${BLUE}Ensuring mount point directories exist...${NC}"
MOUNT_DIRS=(proc sys dev run tmp)
for dir in "${MOUNT_DIRS[@]}"; do
    if [ ! -d "${SQUASHFS_ROOTFS}/${dir}" ]; then
        echo -e "${YELLOW}Creating missing directory: /${dir}${NC}"
        sudo mkdir -p "${SQUASHFS_ROOTFS}/${dir}"
        sudo chmod 755 "${SQUASHFS_ROOTFS}/${dir}"
    else
        echo -e "  ${GREEN}✓${NC} /${dir} exists"
    fi
done

echo -e "${BLUE}Root filesystem extracted to: ${SQUASHFS_ROOTFS}${NC}"
echo -e "${BLUE}You can now modify this filesystem in steps 3-5${NC}"

# Show some key directories to confirm extraction
echo -e "${BLUE}Key directories extracted:${NC}"
for dir in etc usr/bin boot; do
    if [ -d "${SQUASHFS_ROOTFS}/${dir}" ]; then
        COUNT=$(sudo find "${SQUASHFS_ROOTFS}/${dir}" -type f 2>/dev/null | wc -l || echo "0")
        echo -e "  ${GREEN}✓${NC} /${dir} (${COUNT} files)"
    fi
done

echo -e "${GREEN}SquashFS extraction complete!${NC}"
echo -e "${BLUE}Root filesystem extracted to: ${SQUASHFS_ROOTFS}${NC}"
echo -e "${BLUE}You can now modify this filesystem in steps 3-5${NC}"
