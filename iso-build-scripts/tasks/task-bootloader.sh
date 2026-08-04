#!/bin/bash
# Install bootloader (GRUB or systemd-boot) into target.
#
# Required env vars:
#   MOUNT_ROOT   — e.g. /mnt/jarvis-install
#   BOOT_LOADER  — "grub" or "systemd-boot"
#   FS_TYPE      — "ext4" or "btrfs"
#   TARGET_DISK  — e.g. /dev/sda  (GRUB BIOS only)
#   IS_EFI       — "true" or "false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need_root
require_env MOUNT_ROOT BOOT_LOADER FS_TYPE IS_EFI

[[ "${IS_EFI}" == "true" ]] && IS_EFI=true || IS_EFI=false

info "Installing ${BOOT_LOADER}..."

# Determine which kernel is installed
if [ -f "${MOUNT_ROOT}/boot/vmlinuz-linux-jarvisos" ]; then
    KERN_VMLINUZ="vmlinuz-linux-jarvisos"
    KERN_INITRD="initramfs-linux-jarvisos.img"
    KERN_INITRD_FB="initramfs-linux-jarvisos-fallback.img"
else
    KERN_VMLINUZ="vmlinuz-linux"
    KERN_INITRD="initramfs-linux.img"
    KERN_INITRD_FB="initramfs-linux-fallback.img"
fi

if [ "${BOOT_LOADER}" = "systemd-boot" ]; then
    arch-chroot "${MOUNT_ROOT}" bootctl --esp-path=/boot install \
        || die "bootctl install failed — EFI partition may not be mounted at /boot"

    cat > "${MOUNT_ROOT}/boot/loader/loader.conf" << 'LCONF'
default jarvisos.conf
timeout 5
console-mode max
editor no
LCONF

    mkdir -p "${MOUNT_ROOT}/boot/loader/entries"
    ROOT_UUID=$(blkid -s UUID -o value \
        "$(findmnt -n -o SOURCE "${MOUNT_ROOT}" 2>/dev/null)" 2>/dev/null || \
        blkid -s UUID -o value \
        "$(mount | grep " ${MOUNT_ROOT} " | awk '{print $1}')" 2>/dev/null || true)
    [ -z "${ROOT_UUID}" ] && die "Cannot determine root partition UUID."

    FS_OPTS="rw quiet splash"
    [ "${FS_TYPE}" = "btrfs" ] && FS_OPTS="rw quiet splash rootflags=subvol=@"

    UCODE_LINES=""
    [ -f "${MOUNT_ROOT}/boot/intel-ucode.img" ] && UCODE_LINES+=$'initrd  /intel-ucode.img\n'
    [ -f "${MOUNT_ROOT}/boot/amd-ucode.img"   ] && UCODE_LINES+=$'initrd  /amd-ucode.img\n'

    printf "title   JARVIS OS\nlinux   /%s\n%sinitrd  /%s\noptions root=UUID=%s %s\n" \
        "${KERN_VMLINUZ}" "${UCODE_LINES}" "${KERN_INITRD}" "${ROOT_UUID}" "${FS_OPTS}" \
        > "${MOUNT_ROOT}/boot/loader/entries/jarvisos.conf"

    printf "title   JARVIS OS (fallback)\nlinux   /%s\n%sinitrd  /%s\noptions root=UUID=%s %s\n" \
        "${KERN_VMLINUZ}" "${UCODE_LINES}" "${KERN_INITRD_FB}" "${ROOT_UUID}" "${FS_OPTS}" \
        > "${MOUNT_ROOT}/boot/loader/entries/jarvisos-fallback.conf"

    ok "systemd-boot installed"
else
    if $IS_EFI; then
        arch-chroot "${MOUNT_ROOT}" grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot \
            --bootloader-id=JARVISOS \
            --recheck \
            || die "grub-install (EFI) failed — check EFI partition and grub package"
    else
        require_env TARGET_DISK
        arch-chroot "${MOUNT_ROOT}" grub-install \
            --target=i386-pc \
            --recheck \
            "${TARGET_DISK}" \
            || die "grub-install (BIOS) failed — check disk and grub package"
    fi

    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' \
        "${MOUNT_ROOT}/etc/default/grub" 2>/dev/null || true
    sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' \
        "${MOUNT_ROOT}/etc/default/grub" 2>/dev/null || true

    arch-chroot "${MOUNT_ROOT}" grub-mkconfig -o /boot/grub/grub.cfg \
        || die "grub-mkconfig failed — installed system will not boot"

    ok "GRUB installed"
fi
