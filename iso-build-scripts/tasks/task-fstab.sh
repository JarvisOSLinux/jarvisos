#!/bin/bash
# Generate /etc/fstab for the installed system.
#
# Required env vars:
#   MOUNT_ROOT — e.g. /mnt/jarvis-install

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need_root
require_env MOUNT_ROOT

mkdir -p "${MOUNT_ROOT}/etc"
genfstab -U "${MOUNT_ROOT}" > "${MOUNT_ROOT}/etc/fstab"
ok "fstab generated"
