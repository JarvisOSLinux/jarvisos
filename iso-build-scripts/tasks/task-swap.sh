#!/bin/bash
# Create swapfile in installed system (if SWAP_SIZE=file).
#
# Required env vars:
#   MOUNT_ROOT — e.g. /mnt/jarvis-install
#   SWAP_SIZE  — "file" to create, anything else → no-op
#   FS_TYPE    — "ext4" or "btrfs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need_root
require_env MOUNT_ROOT SWAP_SIZE FS_TYPE

if [ "${SWAP_SIZE}" != "file" ]; then
    exit 0
fi

info "Creating 4 GiB swap file..."

if [ "${FS_TYPE}" = "btrfs" ]; then
    arch-chroot "${MOUNT_ROOT}" /bin/bash -c "
        set -e
        truncate -s 0 /swapfile
        chattr +C /swapfile
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
    " || warn "btrfs swapfile setup failed — add swap manually after boot"
else
    arch-chroot "${MOUNT_ROOT}" /bin/bash -c "
        set -e
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
    " || warn "Swapfile setup failed — add swap manually after boot"
fi

echo "/swapfile none swap defaults 0 0" >> "${MOUNT_ROOT}/etc/fstab"
ok "Swap file created"
