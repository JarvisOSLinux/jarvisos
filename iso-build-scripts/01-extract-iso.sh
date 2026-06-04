#!/bin/bash
# Extract Arch Linux ISO to iso-extract
# Usage: ./01-extract-iso.sh [iso_file] [build_dir]
# Variables come from build.config

set -eo pipefail

# Source config file and shared utilities
source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

require_tool "7z" "p7zip" "p7zip p7zip-plugins" "p7zip-full" "p7zip"

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
BUILD_DEPS_DIR="${PROJECT_ROOT}${BUILD_DEPS_DIR}"
ISO_EXTRACT_DIR="${BUILD_DIR}${ISO_EXTRACT_DIR}"
ISO_FILE="${BUILD_DEPS_DIR}/${ISO_FILE}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if ISO file exists
if [ ! -f "${ISO_FILE}" ]; then
    echo -e "${RED}Error: ISO file not found: ${ISO_FILE}${NC}"
    exit 1
fi

echo -e "${BLUE}Extracting ISO...${NC}"
echo -e "${BLUE}ISO: ${ISO_FILE}${NC}"
echo -e "${BLUE}Output: ${ISO_EXTRACT_DIR}${NC}"

# Clean up any existing extraction
sudo rm -rf "${ISO_EXTRACT_DIR}"
mkdir -p "${ISO_EXTRACT_DIR}"

# Check if 7z is available
if ! command -v 7z &> /dev/null; then
    echo -e "${RED}Error: 7z not found.${NC}"
    echo -e "${YELLOW}Install: $(pkg_install_hint_multi "p7zip" "p7zip p7zip-plugins" "p7zip-full" "p7zip")${NC}"
    exit 1
fi

# Extract ISO using 7z
echo -e "${BLUE}Using 7z to extract...${NC}"
7z x -o"${ISO_EXTRACT_DIR}" "${ISO_FILE}" > /dev/null
echo -e "${GREEN}Extraction complete${NC}"

# Verify extraction succeeded
if [ ! -d "${ISO_EXTRACT_DIR}" ] || [ -z "$(ls -A "${ISO_EXTRACT_DIR}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Extraction failed - output directory is empty${NC}"
    exit 1
fi

# ============================================================================
# Handle EFI boot image extracted by 7z
# ============================================================================
# 7z extracts El Torito boot images to [BOOT]/ directory:
#   [BOOT]/1-Boot-NoEmul.img = BIOS boot image (isolinux)
#   [BOOT]/2-Boot-NoEmul.img = EFI boot image (efiboot.img)
# The EFI boot image is needed by 07-rebuild-iso.sh. Place it at the standard
# location (EFI/archiso/efiboot.img) so later scripts can find it.
BOOT_EXTRACT_DIR="${ISO_EXTRACT_DIR}/[BOOT]"
if [ -d "${BOOT_EXTRACT_DIR}" ]; then
    # Find the EFI boot image (usually the largest file, or #2)
    EFI_BOOT_IMG="${BOOT_EXTRACT_DIR}/2-Boot-NoEmul.img"
    if [ -f "${EFI_BOOT_IMG}" ]; then
        EFI_TARGET_DIR="${ISO_EXTRACT_DIR}/EFI/archiso"
        mkdir -p "${EFI_TARGET_DIR}"
        cp "${EFI_BOOT_IMG}" "${EFI_TARGET_DIR}/efiboot.img"
        EFI_SIZE=$(du -h "${EFI_TARGET_DIR}/efiboot.img" | cut -f1)
        echo -e "${GREEN}✓ Placed EFI boot image at EFI/archiso/efiboot.img (${EFI_SIZE})${NC}"
    else
        echo -e "${YELLOW}Warning: EFI boot image not found in [BOOT]/ directory${NC}"
    fi
    # Remove the [BOOT] directory to avoid it being included in the rebuilt ISO
    rm -rf "${BOOT_EXTRACT_DIR}"
fi

# ============================================================================
# Detect and save source ISO's archisosearchuuid for later scripts
# ============================================================================
# The .uuid file in boot/ contains the original ISO's search UUID.
# Save it so 07-rebuild-iso.sh can find and replace it in boot configs.
SOURCE_UUID_FILE=$(find "${ISO_EXTRACT_DIR}/boot" -name "*.uuid" -type f 2>/dev/null | head -1)
if [ -n "${SOURCE_UUID_FILE}" ]; then
    SOURCE_UUID=$(basename "${SOURCE_UUID_FILE}" .uuid)
    echo "${SOURCE_UUID}" > "${BUILD_DIR}/.source-iso-uuid"
    echo -e "${GREEN}✓ Source ISO UUID: ${SOURCE_UUID}${NC}"
fi

# Show extracted structure
echo -e "${BLUE}Extracted structure:${NC}"
find "${ISO_EXTRACT_DIR}" -maxdepth 2 -type d | sort | sed "s|${ISO_EXTRACT_DIR}|  |" | sed "s|^  $|  .|"

echo -e "${GREEN}ISO extraction complete!${NC}"
echo -e "${BLUE}Extracted to: ${ISO_EXTRACT_DIR}${NC}"
