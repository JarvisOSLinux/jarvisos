#!/bin/bash
# Partition, format, and mount target disk.
#
# Required env vars (set by jarvis-install.sh):
#   TARGET_DISK     — e.g. /dev/sda
#   PARTITION_MODE  — "auto" or "manual"
#   FS_TYPE         — "ext4" or "btrfs"  (auto mode only)
#   SWAP_SIZE       — MiB number, "0", or "file" (auto mode only)
#   IS_EFI          — "true" or "false"
#   MOUNT_ROOT      — e.g. /mnt/jarvis-install
#
# For manual mode, also set (serialized from jarvis-install.sh via state file):
#   JARVIS_STATE_FILE — path to file containing PART_MOUNT/PART_FS/PART_FORMAT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need_root
require_env TARGET_DISK PARTITION_MODE IS_EFI MOUNT_ROOT

IS_EFI="${IS_EFI:-false}"
[[ "${IS_EFI}" == "true" ]] && IS_EFI=true || IS_EFI=false

# ── Format helpers ──────────────────────────────────────────────────────────

_format_part() {
    local dev="$1" fs="$2" label="${3:-DATA}"
    label="${label//\//-}"; label="${label#-}"
    case "${fs}" in
        ext4)  mkfs.ext4  -F   -L "JARVIS-${label}" "${dev}" >/dev/null ;;
        btrfs) mkfs.btrfs -f   -L "JARVIS-ROOT"     "${dev}" >/dev/null ;;
        xfs)   mkfs.xfs   -f   -L "JARVIS-${label}" "${dev}" >/dev/null ;;
        fat32) mkfs.fat   -F32 -n "JARVIS-EFI"      "${dev}" >/dev/null ;;
        swap)  mkswap "${dev}" >/dev/null ;;
        keep)  : ;;
    esac
}

format_root() {
    local dev="$1"
    case "${FS_TYPE}" in
        ext4)
            mkfs.ext4 -L JARVISOS-ROOT "${dev}" >/dev/null
            ;;
        btrfs)
            mkfs.btrfs -L JARVISOS-ROOT -f "${dev}" >/dev/null
            mount "${dev}" "${MOUNT_ROOT}"
            btrfs subvolume create "${MOUNT_ROOT}/@"
            btrfs subvolume create "${MOUNT_ROOT}/@home"
            btrfs subvolume create "${MOUNT_ROOT}/@var"
            btrfs subvolume create "${MOUNT_ROOT}/@snapshots"
            umount "${MOUNT_ROOT}"
            mount -o compress=zstd,noatime,subvol=@ "${dev}" "${MOUNT_ROOT}"
            mkdir -p "${MOUNT_ROOT}"/{home,var,.snapshots}
            mount -o compress=zstd,noatime,subvol=@home "${dev}" "${MOUNT_ROOT}/home"
            mount -o compress=zstd,noatime,subvol=@var  "${dev}" "${MOUNT_ROOT}/var"
            mount -o compress=zstd,noatime,subvol=@snapshots "${dev}" "${MOUNT_ROOT}/.snapshots"
            return
            ;;
        *)
            die "Unknown filesystem: ${FS_TYPE}"
            ;;
    esac
}

# Derive partition names (handles nvme0n1p1, mmcblk0p1, sda1)
_part() {
    local disk="$1" num="$2"
    if echo "${disk}" | grep -qE '(nvme|mmcblk)'; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# ── Auto partitioning ──────────────────────────────────────────────────────

partition_disk() {
    wipefs -af "${TARGET_DISK}" >/dev/null 2>&1 || true
    sgdisk --zap-all "${TARGET_DISK}" >/dev/null 2>&1 || true

    if $IS_EFI; then
        parted -s "${TARGET_DISK}" mklabel gpt
        parted -s "${TARGET_DISK}" mkpart ESP fat32 1MiB 1025MiB
        parted -s "${TARGET_DISK}" set 1 esp on

        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_end=$(( 1025 + SWAP_SIZE ))
            parted -s "${TARGET_DISK}" mkpart swap linux-swap 1025MiB "${swap_end}MiB"
            parted -s "${TARGET_DISK}" mkpart root "${FS_TYPE}" "${swap_end}MiB" 100%
        else
            parted -s "${TARGET_DISK}" mkpart root "${FS_TYPE}" 1025MiB 100%
        fi
    else
        parted -s "${TARGET_DISK}" mklabel msdos
        parted -s "${TARGET_DISK}" mkpart primary 1MiB 3MiB
        parted -s "${TARGET_DISK}" set 1 bios_grub on

        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_end=$(( 3 + SWAP_SIZE ))
            parted -s "${TARGET_DISK}" mkpart primary linux-swap 3MiB "${swap_end}MiB"
            parted -s "${TARGET_DISK}" mkpart primary ext4 "${swap_end}MiB" 100%
            parted -s "${TARGET_DISK}" set 3 boot on
        else
            parted -s "${TARGET_DISK}" mkpart primary ext4 3MiB 100%
            parted -s "${TARGET_DISK}" set 2 boot on
        fi
    fi

    partprobe "${TARGET_DISK}" 2>/dev/null || true
    sleep 2
    ok "Disk partitioned"
}

format_and_mount() {
    mkdir -p "${MOUNT_ROOT}"

    if $IS_EFI; then
        local esp_dev; esp_dev=$(_part "${TARGET_DISK}" 1)
        mkfs.fat -F32 -n JARVIS-EFI "${esp_dev}" >/dev/null

        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_dev; swap_dev=$(_part "${TARGET_DISK}" 2)
            local root_dev; root_dev=$(_part "${TARGET_DISK}" 3)
            mkswap "${swap_dev}" && swapon "${swap_dev}"
            format_root "${root_dev}"
            [ "${FS_TYPE}" != "btrfs" ] && mount "${root_dev}" "${MOUNT_ROOT}"
            mkdir -p "${MOUNT_ROOT}/boot"
            mount "${esp_dev}" "${MOUNT_ROOT}/boot"
        else
            local root_dev; root_dev=$(_part "${TARGET_DISK}" 2)
            format_root "${root_dev}"
            [ "${FS_TYPE}" != "btrfs" ] && mount "${root_dev}" "${MOUNT_ROOT}"
            mkdir -p "${MOUNT_ROOT}/boot"
            mount "${esp_dev}" "${MOUNT_ROOT}/boot"
        fi
    else
        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_dev; swap_dev=$(_part "${TARGET_DISK}" 2)
            local root_dev; root_dev=$(_part "${TARGET_DISK}" 3)
            mkswap "${swap_dev}" && swapon "${swap_dev}"
            format_root "${root_dev}"
            [ "${FS_TYPE}" != "btrfs" ] && mount "${root_dev}" "${MOUNT_ROOT}"
        else
            local root_dev; root_dev=$(_part "${TARGET_DISK}" 2)
            format_root "${root_dev}"
            [ "${FS_TYPE}" != "btrfs" ] && mount "${root_dev}" "${MOUNT_ROOT}"
        fi
    fi

    ok "Partitions formatted and mounted"
}

# ── Manual partitioning ────────────────────────────────────────────────────

manual_format_and_mount() {
    # JARVIS_STATE_FILE contains serialized PART_MOUNT / PART_FS / PART_FORMAT
    # as: PART_MOUNT[/dev/sda1]="/" etc.
    [ -f "${JARVIS_STATE_FILE:-}" ] || die "JARVIS_STATE_FILE not set or missing."
    source "${JARVIS_STATE_FILE}"

    mkdir -p "${MOUNT_ROOT}"

    # Find root partition
    local root_dev=""
    for part in "${!PART_MOUNT[@]}"; do
        [ "${PART_MOUNT[$part]}" = "/" ] && root_dev="${part}" && break
    done
    [ -z "${root_dev}" ] && die "No root partition assigned in state file."

    local root_fs="${PART_FS[$root_dev]}"
    FS_TYPE="${root_fs}"
    [ "${FS_TYPE}" = "keep" ] && FS_TYPE="ext4"

    [ "${PART_FORMAT[$root_dev]}" = "yes" ] && _format_part "${root_dev}" "${root_fs}" "ROOT"

    if [ "${root_fs}" = "btrfs" ] && [ "${PART_FORMAT[$root_dev]}" = "yes" ]; then
        mount "${root_dev}" "${MOUNT_ROOT}"
        btrfs subvolume create "${MOUNT_ROOT}/@"
        btrfs subvolume create "${MOUNT_ROOT}/@home"
        btrfs subvolume create "${MOUNT_ROOT}/@var"
        btrfs subvolume create "${MOUNT_ROOT}/@snapshots"
        umount "${MOUNT_ROOT}"
        mount -o compress=zstd,noatime,subvol=@ "${root_dev}" "${MOUNT_ROOT}"
        mkdir -p "${MOUNT_ROOT}"/{home,var,.snapshots}
        mount -o compress=zstd,noatime,subvol=@home "${root_dev}" "${MOUNT_ROOT}/home"
        mount -o compress=zstd,noatime,subvol=@var  "${root_dev}" "${MOUNT_ROOT}/var"
        mount -o compress=zstd,noatime,subvol=@snapshots "${root_dev}" "${MOUNT_ROOT}/.snapshots"
    else
        mount "${root_dev}" "${MOUNT_ROOT}"
    fi

    # Build sorted list of non-root, non-swap mounts
    local entries=()
    for part in "${!PART_MOUNT[@]}"; do
        local mnt="${PART_MOUNT[$part]}"
        [ "${mnt}" = "/"    ] && continue
        [ "${mnt}" = "swap" ] && continue
        if [ "${root_fs}" = "btrfs" ] && [ "${PART_FORMAT[$root_dev]}" = "yes" ]; then
            [[ "${mnt}" == "/home" || "${mnt}" == "/var" ]] && continue
        fi
        entries+=("${mnt}:${part}")
    done

    local sorted=()
    if [ ${#entries[@]} -gt 0 ]; then
        mapfile -t sorted < <(printf '%s\n' "${entries[@]}" \
            | awk -F: '{n=split($1,a,"/"); print n":"$0}' \
            | sort -n | sed 's/^[0-9]*://')
    fi

    for entry in "${sorted[@]}"; do
        local mnt="${entry%%:*}"
        local dev="${entry##*:}"
        local fs="${PART_FS[$dev]}"
        mkdir -p "${MOUNT_ROOT}${mnt}"
        [ "${PART_FORMAT[$dev]}" = "yes" ] && _format_part "${dev}" "${fs}" "${mnt#/}"
        mount "${dev}" "${MOUNT_ROOT}${mnt}"
    done

    for part in "${!PART_MOUNT[@]}"; do
        if [ "${PART_MOUNT[$part]}" = "swap" ]; then
            [ "${PART_FORMAT[$part]}" = "yes" ] && mkswap "${part}" >/dev/null
            swapon "${part}"
        fi
    done

    # Write resolved FS_TYPE back so orchestrator can read it
    echo "FS_TYPE=${FS_TYPE}" >> "${JARVIS_STATE_FILE}"

    ok "Partitions formatted and mounted"
}

# ── Main ──────────────────────────────────────────────────────────────────

case "${PARTITION_MODE}" in
    auto)
        require_env FS_TYPE SWAP_SIZE
        info "Partitioning ${TARGET_DISK}..."
        partition_disk
        info "Formatting and mounting..."
        format_and_mount
        ;;
    manual)
        info "Formatting and mounting (manual layout)..."
        manual_format_and_mount
        ;;
    *)
        die "PARTITION_MODE must be 'auto' or 'manual' (got: '${PARTITION_MODE}')"
        ;;
esac
