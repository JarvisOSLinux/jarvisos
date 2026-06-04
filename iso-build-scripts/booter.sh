#!/bin/bash
# JARVIS OS QEMU Test Launcher
# Boots the built ISO in QEMU for testing
source build.config

BUILD_DIR_FULL="${PROJECT_ROOT}${BUILD_DIR}"

# Find the most recently built JARVIS OS ISO
ISO_FILE=$(find "${BUILD_DIR_FULL}" -maxdepth 1 -name "jarvisos-*-x86_64.iso" -type f | sort | tail -1)

if [ -z "${ISO_FILE}" ] || [ ! -f "${ISO_FILE}" ]; then
    echo "Error: No JARVIS OS ISO found in ${BUILD_DIR_FULL}"
    echo "Run 'make step7' (or 'make all') to build the ISO first."
    exit 1
fi

echo "Booting: ${ISO_FILE}"
echo "Memory: 4GB, KVM enabled"
echo ""
echo "Press Ctrl+Alt+G to release mouse from QEMU window"
echo "Press Ctrl+Alt+F to toggle fullscreen"
echo ""

# Boot with KVM, 4GB RAM, UEFI via OVMF if available, otherwise BIOS
if [ -f /usr/share/edk2/x64/OVMF.fd ]; then
    BIOS_FLAGS="-bios /usr/share/edk2/x64/OVMF.fd"
elif [ -f /usr/share/ovmf/x64/OVMF.fd ]; then
    BIOS_FLAGS="-bios /usr/share/ovmf/x64/OVMF.fd"
elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
    BIOS_FLAGS="-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd"
else
    BIOS_FLAGS=""
    echo "Note: OVMF not found - using legacy BIOS boot (install edk2-ovmf for UEFI testing)"
fi

qemu-system-x86_64 \
    -cdrom "${ISO_FILE}" \
    -boot d \
    -m 4096 \
    -enable-kvm \
    -cpu host \
    -smp 4 \
    -vga virtio \
    -device virtio-sound-pci \
    -nic user,model=virtio-net-pci \
    ${BIOS_FLAGS}
