#!/bin/bash
# ============================================================================
# jarvis-install — JARVIS OS TUI Installer
# ============================================================================
# Launches automatically on TTY1 when booting the live ISO.
# Run as root:  jarvis-install
#
# Requirements: dialog, parted, dosfstools, arch-install-scripts, gptfdisk, rsync
# ============================================================================

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── State variables ────────────────────────────────────────────────────────
TARGET_DISK=""
BOOT_LOADER=""   # "grub" or "systemd-boot"
FS_TYPE=""       # "ext4" or "btrfs"
SWAP_SIZE=""     # in MiB, "0" = none, "file" = swapfile
TIMEZONE="UTC"
KEYMAP="us"
LOCALE="en_US.UTF-8"
HOSTNAME_VAL=""
NEW_USER=""
USER_PASS=""
ROOT_PASS=""
IS_EFI=false
MOUNT_ROOT="/mnt/jarvis-install"
PARTITION_MODE=""        # "auto" or "manual"
declare -A PART_MOUNT=() # partition dev -> mountpoint
declare -A PART_FS=()    # partition dev -> filesystem
declare -A PART_FORMAT=() # partition dev -> "yes"/"no"

# ── Helpers ────────────────────────────────────────────────────────────────
die() { clear; echo -e "${RED}FATAL: $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}=>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Must run as root. Use: sudo jarvis-install"
}

check_deps() {
    local missing=()
    for cmd in dialog parted mkfs.fat arch-chroot genfstab pacstrap blkid lsblk sgdisk wipefs; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        clear
        echo "Installing missing tools: ${missing[*]}"
        pacman -S --noconfirm --needed arch-install-scripts parted dosfstools \
            dialog gptfdisk 2>/dev/null || true
    fi
}

detect_uefi() {
    if [ -d /sys/firmware/efi/efivars ]; then
        IS_EFI=true
    else
        IS_EFI=false
    fi
}

# ── Dialog wrappers ────────────────────────────────────────────────────────
d_menu() {
    local title="$1" h="$2" w="$3"; shift 3
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "${title}" \
           --menu "" "${h}" "${w}" $# "$@" \
           3>&1 1>&2 2>&3
}

d_input() {
    local title="$1" prompt="$2" default="$3"
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "${title}" \
           --inputbox "${prompt}" 8 60 "${default}" \
           3>&1 1>&2 2>&3
}

d_password() {
    local title="$1" prompt="$2"
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "${title}" \
           --passwordbox "${prompt}" 8 60 \
           3>&1 1>&2 2>&3
}

d_yesno() {
    local title="$1" msg="$2"
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "${title}" \
           --yesno "${msg}" 10 65
}

d_msgbox() {
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "$1" \
           --msgbox "$2" 10 65
}

d_infobox() {
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "$1" \
           --infobox "$2" 7 65
}

# ── Step 1: Welcome ────────────────────────────────────────────────────────
step_welcome() {
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "Welcome to JARVIS OS" \
           --msgbox "\
JARVIS OS — AI-Powered Arch Linux\n\
\n\
This installer will:\n\
  1. Partition your chosen disk\n\
  2. Bootstrap a base Arch system (pacstrap)\n\
  3. Install KDE Plasma, Ollama, and the JARVIS AI stack\n\
  4. Configure bootloader, user, and services\n\
  5. Set up the JARVIS AI assistant (model downloads on first boot)\n\
\n\
Boot mode: $(${IS_EFI} && echo 'UEFI' || echo 'BIOS (Legacy)')\n\
Internet connection required.\n\
\n\
WARNING: All data on the target disk will be erased.\n\
Ensure you have backups before continuing.\n\
\n\
Press OK to begin." \
           18 68 || { clear; echo "Aborted."; exit 0; }
}

# ── Step 2: Disk selection ─────────────────────────────────────────────────
step_select_disk() {
    local items=()
    while IFS= read -r line; do
        local dev size model
        dev=$(echo "${line}" | awk '{print $1}')
        size=$(echo "${line}" | awk '{print $2}')
        model=$(echo "${line}" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')
        [ -z "${model}" ] && model="Unknown"
        items+=("${dev}" "${size}  ${model}")
    done < <(lsblk -d -o NAME,SIZE,MODEL --noheadings -e 7,11 2>/dev/null | grep -v "^loop")

    if [ ${#items[@]} -eq 0 ]; then
        die "No suitable disks found."
    fi

    TARGET_DISK=$(d_menu "Select Target Disk" 16 68 "${items[@]}") || { clear; exit 0; }
    TARGET_DISK="/dev/${TARGET_DISK}"
}

# ── Step 2b: Partition mode ────────────────────────────────────────────────
step_partition_mode() {
    PARTITION_MODE=$(d_menu "Partitioning Mode" 12 68 \
        "auto"   "Automatic — erase disk, create standard layout" \
        "manual" "Manual  — cfdisk editor + assign mount points") \
        || { clear; exit 0; }

    if [ "${PARTITION_MODE}" = "auto" ]; then
        d_yesno "Confirm Disk Wipe" \
            "ALL DATA on ${TARGET_DISK} will be permanently erased.\n\nAre you sure?" \
            || { clear; echo "Aborted."; exit 0; }
    fi
}

# ── Step 3: Bootloader ─────────────────────────────────────────────────────
step_select_bootloader() {
    if $IS_EFI; then
        BOOT_LOADER=$(d_menu "Bootloader" 12 68 \
            "systemd-boot" "Fast, lightweight — UEFI only (recommended)" \
            "grub"         "Full-featured — UEFI + dual-boot support") || { clear; exit 0; }
    else
        BOOT_LOADER="grub"
        d_msgbox "Bootloader" "BIOS system detected.\nGRUB will be installed (systemd-boot requires UEFI)."
    fi
}

# ── Step 4: Filesystem ─────────────────────────────────────────────────────
step_select_fs() {
    FS_TYPE=$(d_menu "Root Filesystem" 10 68 \
        "ext4"  "Stable, widely supported (recommended)" \
        "btrfs" "Copy-on-write, snapshots, compression") || { clear; exit 0; }
}

# ── Step 5: Swap ───────────────────────────────────────────────────────────
step_select_swap() {
    local ram_mb
    ram_mb=$(awk '/MemTotal/ {printf "%.0f\n", $2/1024}' /proc/meminfo)

    local choice
    choice=$(d_menu "Swap Space" 14 68 \
        "0"     "None" \
        "2048"  "2 GiB" \
        "4096"  "4 GiB (system RAM: ${ram_mb} MiB)" \
        "8192"  "8 GiB" \
        "16384" "16 GiB" \
        "file"  "Swap file (4 GiB, created after install)") || { clear; exit 0; }
    SWAP_SIZE="${choice}"
}

# ── Step 6: Timezone ───────────────────────────────────────────────────────
step_timezone() {
    # Build region list from zoneinfo
    local region_items=()
    while IFS= read -r region; do
        region_items+=("${region}" "")
    done < <(find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d \
             2>/dev/null | sed 's|/usr/share/zoneinfo/||' | sort | \
             grep -xE 'Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific|US')
    region_items+=("UTC" "Coordinated Universal Time")

    local region
    region=$(dialog --clear --backtitle "JARVIS OS Installer" \
                    --title "Timezone — Region" \
                    --menu "Select your region:" 22 60 15 \
                    "${region_items[@]}" \
                    3>&1 1>&2 2>&3) || { clear; exit 0; }

    if [ "${region}" = "UTC" ]; then
        TIMEZONE="UTC"
        return
    fi

    # Build city list for chosen region
    local city_items=()
    while IFS= read -r city; do
        city_items+=("${city}" "")
    done < <(find "/usr/share/zoneinfo/${region}" -type f 2>/dev/null \
             | sed "s|/usr/share/zoneinfo/${region}/||" | sort)

    if [ ${#city_items[@]} -eq 0 ]; then
        TIMEZONE="${region}"
        return
    fi

    local city
    city=$(dialog --clear --backtitle "JARVIS OS Installer" \
                  --title "Timezone — City" \
                  --menu "Select your city:" 22 60 15 \
                  "${city_items[@]}" \
                  3>&1 1>&2 2>&3) || { clear; exit 0; }

    TIMEZONE="${region}/${city}"
}

# ── Step 7: Keyboard layout ────────────────────────────────────────────────
step_keyboard() {
    local choice
    choice=$(d_menu "Keyboard Layout" 20 68 \
        "us"     "US English (default)" \
        "gb"     "British English" \
        "de"     "German" \
        "fr"     "French" \
        "es"     "Spanish" \
        "it"     "Italian" \
        "pt"     "Portuguese" \
        "ru"     "Russian" \
        "pl"     "Polish" \
        "nl"     "Dutch" \
        "sv"     "Swedish" \
        "no"     "Norwegian" \
        "dk"     "Danish" \
        "tr"     "Turkish" \
        "custom" "Other (enter manually)") || { clear; exit 0; }

    if [ "${choice}" = "custom" ]; then
        KEYMAP=$(d_input "Custom Keymap" \
            "Enter keymap name (e.g. dvorak, colemak-dh):" "us") || { clear; exit 0; }
        KEYMAP="${KEYMAP:-us}"
    else
        KEYMAP="${choice}"
    fi
}

# ── Step 8: Locale ─────────────────────────────────────────────────────────
step_locale() {
    local choice
    choice=$(d_menu "System Locale" 18 68 \
        "en_US.UTF-8"  "English — United States" \
        "en_GB.UTF-8"  "English — United Kingdom" \
        "en_AU.UTF-8"  "English — Australia" \
        "en_CA.UTF-8"  "English — Canada" \
        "de_DE.UTF-8"  "German — Germany" \
        "fr_FR.UTF-8"  "French — France" \
        "es_ES.UTF-8"  "Spanish — Spain" \
        "es_MX.UTF-8"  "Spanish — Mexico" \
        "it_IT.UTF-8"  "Italian — Italy" \
        "pt_PT.UTF-8"  "Portuguese — Portugal" \
        "pt_BR.UTF-8"  "Portuguese — Brazil" \
        "ru_RU.UTF-8"  "Russian — Russia" \
        "pl_PL.UTF-8"  "Polish — Poland" \
        "nl_NL.UTF-8"  "Dutch — Netherlands" \
        "sv_SE.UTF-8"  "Swedish — Sweden") || { clear; exit 0; }
    LOCALE="${choice}"
}

# ── Step 9: Hostname ───────────────────────────────────────────────────────
step_hostname() {
    HOSTNAME_VAL=$(d_input "Hostname" "Enter the system hostname:" "jarvisos") || { clear; exit 0; }
    HOSTNAME_VAL="${HOSTNAME_VAL:-jarvisos}"
    HOSTNAME_VAL=$(echo "${HOSTNAME_VAL}" | tr -cd '[:alnum:]-' | head -c 63)
    if [ -z "${HOSTNAME_VAL}" ]; then HOSTNAME_VAL="jarvisos"; fi
}

# ── Step 10: User ──────────────────────────────────────────────────────────
step_user() {
    NEW_USER=$(d_input "Create User" "Enter username for the new account:" "user") || { clear; exit 0; }
    NEW_USER="${NEW_USER:-user}"
    NEW_USER=$(echo "${NEW_USER}" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')

    local pass1 pass2
    while true; do
        pass1=$(d_password "User Password" "Password for ${NEW_USER}:") || { clear; exit 0; }
        pass2=$(d_password "Confirm Password" "Confirm password:") || { clear; exit 0; }
        [ "${pass1}" = "${pass2}" ] && break
        d_msgbox "Mismatch" "Passwords do not match. Try again."
    done
    USER_PASS="${pass1}"

    local rp1 rp2
    while true; do
        rp1=$(d_password "Root Password" "Set the root password:") || { clear; exit 0; }
        rp2=$(d_password "Confirm Root Password" "Confirm root password:") || { clear; exit 0; }
        [ "${rp1}" = "${rp2}" ] && break
        d_msgbox "Mismatch" "Passwords do not match. Try again."
    done
    ROOT_PASS="${rp1}"
}

# ── Step 11: Summary ───────────────────────────────────────────────────────
step_summary() {
    local body=""

    if [ "${PARTITION_MODE}" = "manual" ]; then
        body="Disk:        ${TARGET_DISK}
Partitioning: Manual
"
        for part in $(printf '%s\n' "${!PART_MOUNT[@]}" | sort); do
            local mnt="${PART_MOUNT[$part]}"
            local fs="${PART_FS[$part]}"
            local fmt="${PART_FORMAT[$part]}"
            [ "${fmt}" = "yes" ] && fmt="format" || fmt="keep"
            body+="  ${part} → ${mnt} (${fs}, ${fmt})
"
        done
        body+="
Bootloader:  ${BOOT_LOADER}
Timezone:    ${TIMEZONE}
Keyboard:    ${KEYMAP}
Locale:      ${LOCALE}
Hostname:    ${HOSTNAME_VAL}
User:        ${NEW_USER}

Marked partitions will be formatted. Others kept.
Proceed with installation?"
    else
        local swap_label="${SWAP_SIZE} MiB"
        [ "${SWAP_SIZE}" = "0" ]    && swap_label="None"
        [ "${SWAP_SIZE}" = "file" ] && swap_label="4 GiB swapfile"
        body="Disk:        ${TARGET_DISK}
Partitioning: Automatic
Bootloader:  ${BOOT_LOADER}
Filesystem:  ${FS_TYPE}
Swap:        ${swap_label}
Timezone:    ${TIMEZONE}
Keyboard:    ${KEYMAP}
Locale:      ${LOCALE}
Hostname:    ${HOSTNAME_VAL}
User:        ${NEW_USER}

ALL DATA on ${TARGET_DISK} will be erased.
Proceed with installation?"
    fi

    d_yesno "Installation Summary" "${body}" || { clear; echo "Aborted."; exit 0; }
}

# ── Manual: cfdisk editor ─────────────────────────────────────────────────
step_cfdisk_edit() {
    d_msgbox "Manual Partitioning" \
"cfdisk will open for: ${TARGET_DISK}

Create partitions, then select Write and Quit.

UEFI recommended layout:
  512 MiB+  EFI partition  (type: EFI System)
  [optional] swap partition (type: Linux swap)
  remainder  root /         (type: Linux filesystem)

BIOS recommended layout:
  1 MiB     BIOS boot      (type: BIOS boot)
  [optional] swap partition (type: Linux swap)
  remainder  root /         (type: Linux filesystem)

Press OK to open cfdisk."
    clear
    cfdisk "${TARGET_DISK}" || true
    partprobe "${TARGET_DISK}" 2>/dev/null || true
    sleep 1
}

# ── Manual: assign mount points ────────────────────────────────────────────
step_manual_assign() {
    PART_MOUNT=()
    PART_FS=()
    PART_FORMAT=()

    local parts=()
    while IFS= read -r p; do
        [ -n "$p" ] && parts+=("/dev/$p")
    done < <(lsblk -lno NAME "${TARGET_DISK}" --noheadings 2>/dev/null \
             | grep -v "^$(basename "${TARGET_DISK}")$")

    if [ ${#parts[@]} -eq 0 ]; then
        d_msgbox "No Partitions" \
            "No partitions found on ${TARGET_DISK}.\nReturn to cfdisk to create them."
        step_cfdisk_edit
        step_manual_assign
        return
    fi

    for part in "${parts[@]}"; do
        local psize pfs
        psize=$(lsblk -lno SIZE  "${part}" 2>/dev/null || echo "?")
        pfs=$(  lsblk -lno FSTYPE "${part}" 2>/dev/null || echo "none")
        [ -z "${pfs}" ] && pfs="none"

        local mountpt
        mountpt=$(dialog --clear --backtitle "JARVIS OS Installer" \
            --title "Assign: ${part} (${psize}, current fs: ${pfs})" \
            --menu "Select use for ${part}:" 20 70 10 \
            "skip"   "Skip — do not use this partition" \
            "/"      "Root filesystem (required)" \
            "/boot"  "Boot / EFI partition" \
            "/home"  "Home directory" \
            "/var"   "Variable data" \
            "/tmp"   "Temporary files" \
            "swap"   "Swap space" \
            "/data"  "Data partition" \
            "custom" "Custom mount point…" \
            3>&1 1>&2 2>&3) || { clear; exit 0; }

        [ "${mountpt}" = "skip" ] && continue

        if [ "${mountpt}" = "custom" ]; then
            mountpt=$(d_input "Custom Mount Point" \
                "Enter absolute path (e.g. /srv):" "") \
                || { clear; exit 0; }
            [ -z "${mountpt}" ] && continue
            [[ "${mountpt}" != /* ]] && mountpt="/${mountpt}"
        fi

        PART_MOUNT["${part}"]="${mountpt}"

        # Pick filesystem
        if [ "${mountpt}" = "swap" ]; then
            PART_FS["${part}"]="swap"
            local fmt_choice
            fmt_choice=$(d_menu "Format? — ${part}" 10 60 \
                "yes" "Format as swap (mkswap)" \
                "no"  "Use existing swap partition") \
                || { clear; exit 0; }
            PART_FORMAT["${part}"]="${fmt_choice}"
        else
            local fs_hint="ext4"
            [ "${mountpt}" = "/boot" ] && $IS_EFI && fs_hint="fat32"

            local chosen_fs
            chosen_fs=$(dialog --clear --backtitle "JARVIS OS Installer" \
                --title "Filesystem — ${part} → ${mountpt}" \
                --menu "Format ${part} as:" 16 68 5 \
                "ext4"  "ext4  — stable, widely supported" \
                "btrfs" "btrfs — copy-on-write, snapshots" \
                "xfs"   "xfs   — high performance" \
                "fat32" "FAT32 — EFI / boot partitions" \
                "keep"  "Keep existing — do not format" \
                3>&1 1>&2 2>&3) || { clear; exit 0; }

            PART_FS["${part}"]="${chosen_fs}"
            [ "${chosen_fs}" = "keep" ] && PART_FORMAT["${part}"]="no" \
                                        || PART_FORMAT["${part}"]="yes"
        fi
    done

    validate_manual_parts || { step_manual_assign; return; }
}

# ── Manual: validate ──────────────────────────────────────────────────────
validate_manual_parts() {
    local has_root=false has_boot=false
    for part in "${!PART_MOUNT[@]}"; do
        [ "${PART_MOUNT[$part]}" = "/" ]     && has_root=true
        [ "${PART_MOUNT[$part]}" = "/boot" ] && has_boot=true
    done

    if ! $has_root; then
        d_msgbox "Missing Root" \
            "No root (/) partition assigned.\nRe-assign partitions."
        return 1
    fi

    if $IS_EFI && ! $has_boot; then
        d_msgbox "Missing EFI Partition" \
            "UEFI requires /boot assigned to an EFI System Partition (FAT32)."
        return 1
    fi
    return 0
}

# ── Manual: swap (if no swap partition assigned) ───────────────────────────
step_manual_swap() {
    for part in "${!PART_MOUNT[@]}"; do
        [ "${PART_MOUNT[$part]}" = "swap" ] && { SWAP_SIZE="0"; return 0; }
    done
    local choice
    choice=$(d_menu "Swap Space" 10 68 \
        "0"    "None" \
        "file" "4 GiB swapfile (created after install)") \
        || { SWAP_SIZE="0"; return 0; }
    SWAP_SIZE="${choice}"
}

# ── Manual: format one partition ──────────────────────────────────────────
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

# ── Manual: format and mount all assigned partitions ──────────────────────
manual_format_and_mount() {
    mkdir -p "${MOUNT_ROOT}"

    # Find root partition
    local root_dev=""
    for part in "${!PART_MOUNT[@]}"; do
        [ "${PART_MOUNT[$part]}" = "/" ] && root_dev="${part}" && break
    done
    [ -z "${root_dev}" ] && die "No root partition assigned."

    local root_fs="${PART_FS[$root_dev]}"
    FS_TYPE="${root_fs}"
    [ "${FS_TYPE}" = "keep" ] && FS_TYPE="ext4"

    # Format + mount root
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
        # Skip btrfs subvols already mounted
        if [ "${root_fs}" = "btrfs" ] && [ "${PART_FORMAT[$root_dev]}" = "yes" ]; then
            [[ "${mnt}" == "/home" || "${mnt}" == "/var" ]] && continue
        fi
        entries+=("${mnt}:${part}")
    done

    # Sort by mount depth (number of slashes)
    local sorted=()
    if [ ${#entries[@]} -gt 0 ]; then
        IFS=$'\n' sorted=($(printf '%s\n' "${entries[@]}" \
            | awk -F: '{n=split($1,a,"/"); print n":"$0}' \
            | sort -n | sed 's/^[0-9]*://'))
        unset IFS
    fi

    for entry in "${sorted[@]}"; do
        local mnt="${entry%%:*}"
        local dev="${entry##*:}"
        local fs="${PART_FS[$dev]}"
        mkdir -p "${MOUNT_ROOT}${mnt}"
        [ "${PART_FORMAT[$dev]}" = "yes" ] && _format_part "${dev}" "${fs}" "${mnt#/}"
        mount "${dev}" "${MOUNT_ROOT}${mnt}"
    done

    # Swap partitions
    for part in "${!PART_MOUNT[@]}"; do
        if [ "${PART_MOUNT[$part]}" = "swap" ]; then
            [ "${PART_FORMAT[$part]}" = "yes" ] && mkswap "${part}" >/dev/null
            swapon "${part}"
        fi
    done

    ok "Partitions formatted and mounted"
}

# ── Partitioning ───────────────────────────────────────────────────────────
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

# Derive partition names (handles nvme0n1p1, mmcblk0p1, sda1)
part() {
    local disk="$1" num="$2"
    if echo "${disk}" | grep -qE '(nvme|mmcblk)'; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

format_and_mount() {
    mkdir -p "${MOUNT_ROOT}"

    if $IS_EFI; then
        local esp_dev
        esp_dev=$(part "${TARGET_DISK}" 1)
        mkfs.fat -F32 -n JARVISOS-EFI "${esp_dev}" >/dev/null

        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_dev root_dev
            swap_dev=$(part "${TARGET_DISK}" 2)
            root_dev=$(part "${TARGET_DISK}" 3)
            mkswap "${swap_dev}" && swapon "${swap_dev}"
            format_root "${root_dev}"
            mount "${root_dev}" "${MOUNT_ROOT}"
            mkdir -p "${MOUNT_ROOT}/boot"
            mount "${esp_dev}" "${MOUNT_ROOT}/boot"
        else
            local root_dev
            root_dev=$(part "${TARGET_DISK}" 2)
            format_root "${root_dev}"
            mount "${root_dev}" "${MOUNT_ROOT}"
            mkdir -p "${MOUNT_ROOT}/boot"
            mount "${esp_dev}" "${MOUNT_ROOT}/boot"
        fi
    else
        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_dev root_dev
            swap_dev=$(part "${TARGET_DISK}" 2)
            root_dev=$(part "${TARGET_DISK}" 3)
            mkswap "${swap_dev}" && swapon "${swap_dev}"
            format_root "${root_dev}"
            mount "${root_dev}" "${MOUNT_ROOT}"
        else
            local root_dev
            root_dev=$(part "${TARGET_DISK}" 2)
            format_root "${root_dev}"
            mount "${root_dev}" "${MOUNT_ROOT}"
        fi
    fi

    ok "Partitions formatted and mounted"
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


# ── Install system ─────────────────────────────────────────────────────────
install_system() {
    clear
    echo ""
    echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}  ║      Installing JARVIS OS                    ║${NC}"
    echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════╝${NC}"
    echo ""

    # ── Bootstrap base Arch system ────────────────────────────────────────
    info "Bootstrapping base system via pacstrap (needs internet)..."
    echo ""
    pacstrap -K "${MOUNT_ROOT}" \
        base base-devel linux linux-firmware \
        sudo nano vim wget curl git openssh \
        networkmanager wpa_supplicant wireless-regdb \
        arch-install-scripts \
        || die "pacstrap failed — check network and /etc/pacman.d/mirrorlist"
    echo ""
    ok "Base system installed"

    # ── Copy installer into chroot, run --overlay to install JARVIS stack ─
    local _self; _self="$(realpath "${BASH_SOURCE[0]}")"
    cp "${_self}" "${MOUNT_ROOT}/tmp/jarvis-install"
    chmod +x "${MOUNT_ROOT}/tmp/jarvis-install"

    info "Installing JARVIS OS components (KDE, Ollama, JARVIS stack)..."
    echo ""
    arch-chroot "${MOUNT_ROOT}" bash /tmp/jarvis-install --overlay \
        || die "JARVIS component install failed"

    rm -f "${MOUNT_ROOT}/tmp/jarvis-install"
    ok "JARVIS OS components installed"
}

# ── Kernel selection ───────────────────────────────────────────────────────
# linux is already installed by pacstrap. Attempt linux-jarvisos if pre-built
# packages exist alongside the installer (e.g. from a prior make step3b run).
ensure_kernel() {
    KERNEL_PKG="linux"

    local _script_dir; _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _pkg_dir="${_script_dir}/../../build/kernel-pkg"
    local _pkg; _pkg=$(find "${_pkg_dir}" -name 'linux-jarvisos-[0-9]*.pkg.tar.zst' \
                        ! -name 'linux-jarvisos-headers-*' 2>/dev/null \
                        | sort -V | tail -1 || true)
    local _hdr; _hdr=$(find "${_pkg_dir}" -name 'linux-jarvisos-headers-[0-9]*.pkg.tar.zst' \
                        2>/dev/null | sort -V | tail -1 || true)

    if [ -n "${_pkg}" ] && [ -n "${_hdr}" ]; then
        info "Found pre-built linux-jarvisos — installing into target..."
        cp "${_pkg}" "${_hdr}" "${MOUNT_ROOT}/tmp/"
        arch-chroot "${MOUNT_ROOT}" pacman -U --noconfirm \
            "/tmp/$(basename "${_pkg}")" "/tmp/$(basename "${_hdr}")" \
            && ok "linux-jarvisos installed" && KERNEL_PKG="linux-jarvisos" \
            || warn "linux-jarvisos install failed — using stock linux kernel"
        rm -f "${MOUNT_ROOT}/tmp/"linux-jarvisos*.pkg.tar.zst 2>/dev/null || true
    else
        info "No pre-built linux-jarvisos found — using stock linux kernel"
    fi
}

# ── fstab ──────────────────────────────────────────────────────────────────
generate_fstab() {
    mkdir -p "${MOUNT_ROOT}/etc"
    genfstab -U "${MOUNT_ROOT}" > "${MOUNT_ROOT}/etc/fstab"
    ok "fstab generated"
}

# ── Configure installed system ─────────────────────────────────────────────
configure_system() {
    arch-chroot "${MOUNT_ROOT}" /bin/bash -s \
        "${HOSTNAME_VAL}" "${NEW_USER}" "${USER_PASS}" "${ROOT_PASS}" \
        "${BOOT_LOADER}" "${FS_TYPE}" "${TIMEZONE}" "${KEYMAP}" "${LOCALE}" \
        "${KERNEL_PKG:-linux}" <<'CHROOT_EOF'
set -euo pipefail

HOSTNAME_VAL="$1"
NEW_USER="$2"
USER_PASS="$3"
ROOT_PASS="$4"
BOOT_LOADER="$5"
FS_TYPE="$6"
TIMEZONE="$7"
KEYMAP="$8"
LOCALE="$9"
KERNEL_PKG="${10:-linux}"

warn() { echo "WARNING: $*" >&2; }

# Timezone
if [ "${TIMEZONE}" = "UTC" ]; then
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
elif [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
else
    warn "Timezone ${TIMEZONE} not found — defaulting to UTC"
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
fi
hwclock --systohc

# Locale
LOCALE_BASE=$(echo "${LOCALE}" | cut -d' ' -f1)
sed -i "s/^#\(${LOCALE_BASE}\)/\1/" /etc/locale.gen 2>/dev/null || true
# Also ensure en_US is generated if a different locale is chosen
grep -q "^en_US.UTF-8" /etc/locale.gen 2>/dev/null || \
    sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
locale-gen
echo "LANG=${LOCALE_BASE}" > /etc/locale.conf

# Keyboard
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# Hostname
echo "${HOSTNAME_VAL}" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_VAL}.localdomain ${HOSTNAME_VAL}
EOF

# Root password
echo "root:${ROOT_PASS}" | chpasswd

# User setup
for grp in wheel audio video storage optical network power lp sys scanner input; do
    getent group "${grp}" >/dev/null 2>&1 || groupadd --system "${grp}" 2>/dev/null || true
done

useradd -m -G wheel,audio,video,storage,optical,network,power -s /bin/bash "${NEW_USER}" 2>/dev/null || \
    useradd -m -s /bin/bash "${NEW_USER}"

for grp in wheel audio video storage optical network power lp sys scanner input; do
    usermod -aG "${grp}" "${NEW_USER}" 2>/dev/null || true
done

echo "${NEW_USER}:${USER_PASS}" | chpasswd

# sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || \
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/'     /etc/sudoers 2>/dev/null || true
chmod 440 /etc/sudoers

# Remove live autologin config and TTY1 override
rm -f /etc/sddm.conf.d/autologin.conf 2>/dev/null || true
rm -rf /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
rm -f /root/.bash_profile 2>/dev/null || true

# SDDM config for installed system
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/jarvisos.conf << SDDM
[General]
DisplayServer=wayland
Numlock=on

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions
SDDM

# Remove liveuser account
userdel -r liveuser 2>/dev/null || true
rm -rf /home/liveuser 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-liveuser.rules 2>/dev/null || true

# Fix mkinitcpio.conf for installed system
# Remove archiso/memdisk live hooks; add block+filesystems for real boot
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap block filesystems)/' \
    /etc/mkinitcpio.conf

# mkinitcpio
if [ "${KERNEL_PKG}" = "linux-jarvisos" ]; then
    # Remove stock linux files — linux-jarvisos is the installed kernel
    rm -f /boot/vmlinuz-linux /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img
    rm -f /etc/mkinitcpio.d/linux.preset 2>/dev/null || true
    if [ -f /etc/mkinitcpio.d/linux-jarvisos.preset ]; then
        mkinitcpio -p linux-jarvisos || warn "mkinitcpio failed — check manually after install"
    elif [ -f /boot/initramfs-linux-jarvisos.img ]; then
        # initramfs present but preset missing — the file was copied from the live
        # medium and was built with archiso hooks (not block/filesystems).
        # The installed system will NOT boot from it.  Re-generate using the
        # kernel version string found in /usr/lib/modules/.
        warn "linux-jarvisos.preset missing — rebuilding initramfs directly"
        _kver=$(ls /usr/lib/modules/ 2>/dev/null | grep -m1 'jarvisos')
        if [ -n "${_kver}" ]; then
            mkinitcpio -k "${_kver}" -g /boot/initramfs-linux-jarvisos.img \
                || warn "mkinitcpio failed — check /boot/ manually after install"
        else
            warn "Cannot find linux-jarvisos modules in /usr/lib/modules/ — installed system may not boot"
        fi
    else
        warn "No linux-jarvisos kernel or preset found — bootloader will not work"
    fi
else
    # Stock linux kernel fallback — keep vmlinuz-linux and linux.preset
    if [ -f /etc/mkinitcpio.d/linux.preset ]; then
        mkinitcpio -p linux || warn "mkinitcpio failed"
    fi
fi

# Enable services
systemctl enable NetworkManager.service              2>/dev/null || true
systemctl enable systemd-resolved.service            2>/dev/null || true
systemctl enable sddm.service                        2>/dev/null || true
systemctl enable bluetooth.service                   2>/dev/null || true
systemctl enable rtkit-daemon.service                2>/dev/null || true
systemctl enable ollama.service                      2>/dev/null || true
systemctl enable jarvis.service                      2>/dev/null || true
systemctl enable jarvis-setup.service                2>/dev/null || true
systemctl disable iwd.service                        2>/dev/null || true
systemctl mask    iwd.service                        2>/dev/null || true
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true

# resolv.conf
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# XDG user dirs
if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    runuser -u "${NEW_USER}" -- xdg-user-dirs-update 2>/dev/null || true
fi

# JARVIS welcome autostart for new user (runs on first login)
AUTOSTART_DIR="/home/${NEW_USER}/.config/autostart"
mkdir -p "${AUTOSTART_DIR}"
cat > "${AUTOSTART_DIR}/jarvis-welcome.desktop" << JDESKTOP
[Desktop Entry]
Type=Application
Name=JARVIS Setup
Comment=First-boot JARVIS AI setup wizard
Exec=konsole -e /usr/local/bin/jarvis-welcome.sh
Icon=utilities-terminal
Terminal=false
StartupNotify=true
X-KDE-autostart-phase=2
JDESKTOP
chmod 644 "${AUTOSTART_DIR}/jarvis-welcome.desktop"
chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.config" 2>/dev/null || true

# btrfs fstab options
if [ "${FS_TYPE}" = "btrfs" ]; then
    sed -i 's|subvol=@,|compress=zstd,noatime,subvol=@,|' /etc/fstab 2>/dev/null || true
fi

echo "System configuration complete."
CHROOT_EOF

    ok "System configured"
}

# ── Bootloader ─────────────────────────────────────────────────────────────
install_bootloader() {
    info "Installing ${BOOT_LOADER}..."

    # Determine which kernel to boot
    local KERN_VMLINUZ KERN_INITRD KERN_INITRD_FB
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
        arch-chroot "${MOUNT_ROOT}" bootctl --esp-path=/boot install

        cat > "${MOUNT_ROOT}/boot/loader/loader.conf" << 'LCONF'
default jarvisos.conf
timeout 5
console-mode max
editor no
LCONF

        mkdir -p "${MOUNT_ROOT}/boot/loader/entries"
        local ROOT_UUID
        ROOT_UUID=$(blkid -s UUID -o value \
            "$(findmnt -n -o SOURCE "${MOUNT_ROOT}" 2>/dev/null)" 2>/dev/null || \
            blkid -s UUID -o value \
            "$(mount | grep " ${MOUNT_ROOT} " | awk '{print $1}')" 2>/dev/null || true)

        local FS_OPTS="rw quiet splash"
        [ "${FS_TYPE}" = "btrfs" ] && FS_OPTS="rw quiet splash rootflags=subvol=@"

        local UCODE_LINES=""
        [ -f "${MOUNT_ROOT}/boot/intel-ucode.img" ] && UCODE_LINES+="initrd  /intel-ucode.img\n"
        [ -f "${MOUNT_ROOT}/boot/amd-ucode.img"   ] && UCODE_LINES+="initrd  /amd-ucode.img\n"

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
                --recheck
        else
            arch-chroot "${MOUNT_ROOT}" grub-install \
                --target=i386-pc \
                --recheck \
                "${TARGET_DISK}"
        fi

        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' \
            "${MOUNT_ROOT}/etc/default/grub" 2>/dev/null || true
        sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' \
            "${MOUNT_ROOT}/etc/default/grub" 2>/dev/null || true

        arch-chroot "${MOUNT_ROOT}" grub-mkconfig -o /boot/grub/grub.cfg

        ok "GRUB installed"
    fi
}

# ── Swap file ──────────────────────────────────────────────────────────────
create_swapfile() {
    if [ "${SWAP_SIZE}" = "file" ]; then
        info "Creating 4 GiB swap file..."
        arch-chroot "${MOUNT_ROOT}" /bin/bash -c "
            dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress 2>&1 || true
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
        "
        echo "/swapfile none swap defaults 0 0" >> "${MOUNT_ROOT}/etc/fstab"
        ok "Swap file created"
    fi
}

# ── Cleanup ────────────────────────────────────────────────────────────────
cleanup_mounts() {
    sync
    umount -R "${MOUNT_ROOT}" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
}

# ── Detect Arch-based distro ───────────────────────────────────────────────
detect_arch_based() {
    local id="" id_like=""
    if [ -f /etc/os-release ]; then
        id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        id_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    case "${id}" in
        arch|manjaro|endeavouros|garuda|cachyos|artix|parabola|arcolinux) return 0 ;;
    esac
    [[ "${id_like}" == *arch* ]] && return 0
    die "Not an Arch-based system (ID=${id:-unknown}, ID_LIKE=${id_like:-unknown}).\nRun on Arch Linux or an Arch-based distro."
}

# ── Find JARVIS source code ────────────────────────────────────────────────
find_jarvis_source() {
    [ -f /usr/lib/jarvis/main.py ] && echo "installed" && return 0
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local try="${script_dir}/../../Project-JARVIS"
    [ -f "${try}/jarvis/main.py" ] && echo "$(realpath "${try}")" && return 0
    echo ""
    return 1
}

# ── GPU vendor detection ──────────────────────────────────────────────────
# Returns: "nvidia", "amd", or "cpu"
_detect_gpu_vendor() {
    if lspci 2>/dev/null | grep -qi 'nvidia' || \
       lsmod 2>/dev/null | grep -q '^nvidia '; then
        echo "nvidia"; return
    fi
    if lsmod 2>/dev/null | grep -q '^amdgpu '; then
        echo "amd"; return
    fi
    if lspci 2>/dev/null | grep -qi 'radeon\|amdgpu'; then
        echo "amd"; return
    fi
    echo "cpu"
}

# ── Install Ollama with GPU-appropriate binary ────────────────────────────
_install_ollama_gpu() {
    local gpu; gpu=$(_detect_gpu_vendor)
    local arch; arch=$(uname -m)
    info "GPU detected: ${gpu} — installing Ollama accordingly"

    case "${gpu}" in
        nvidia)
            # install.sh auto-detects CUDA via nvidia-smi and installs libs
            if curl -fsSL https://ollama.com/install.sh | sh; then
                ok "Ollama installed with NVIDIA CUDA support"
            else
                warn "Ollama CUDA install failed — falling back to CPU binary"
                local _url="https://ollama.com/download/ollama-linux-amd64"
                [ "${arch}" = "aarch64" ] && _url="https://ollama.com/download/ollama-linux-arm64"
                curl -fsSL -o /usr/local/bin/ollama "${_url}" && chmod +x /usr/local/bin/ollama || true
            fi
            ;;
        amd)
            if [ "${arch}" = "x86_64" ]; then
                if curl -fsSL -o /usr/local/bin/ollama \
                        https://ollama.com/download/ollama-linux-amd64-rocm; then
                    chmod +x /usr/local/bin/ollama
                    ok "Ollama installed with AMD ROCm support"
                else
                    warn "ROCm binary download failed — falling back to install.sh"
                    curl -fsSL https://ollama.com/install.sh | sh || true
                fi
            else
                curl -fsSL https://ollama.com/install.sh | sh || true
            fi
            # Grant ollama service user access to GPU render/DRI devices
            getent group render >/dev/null 2>&1 && usermod -aG render ollama 2>/dev/null || true
            usermod -aG video ollama 2>/dev/null || true
            ;;
        cpu|*)
            local _url="https://ollama.com/download/ollama-linux-amd64"
            [ "${arch}" = "aarch64" ] && _url="https://ollama.com/download/ollama-linux-arm64"
            if curl -fsSL -o /usr/local/bin/ollama "${_url}"; then
                chmod +x /usr/local/bin/ollama
                ok "Ollama installed (CPU mode)"
            else
                warn "Ollama download failed — install manually: curl -fsSL https://ollama.com/install.sh | sh"
            fi
            ;;
    esac
}

# ── Install JARVIS OS components on existing Arch system ───────────────────
install_packages_mode() {
    need_root
    detect_arch_based

    local distro_name
    distro_name=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null \
        | cut -d= -f2 | tr -d '"' || echo "Arch Linux")

    dialog --clear --backtitle "JARVIS OS Package Installer" \
           --title "Install JARVIS OS on ${distro_name}" \
           --yesno "\
Install JARVIS OS components on: ${distro_name}

This will install (existing packages kept):
  • KDE Plasma Wayland desktop + SDDM
  • PipeWire audio ecosystem
  • NetworkManager + WiFi (wpa_supplicant backend)
  • GPU drivers: Mesa, Vulkan, Intel VA-API, AMD
  • Fonts: Noto, Liberation, DejaVu, CJK
  • linux + linux-headers kernel packages
  • Ollama AI engine
  • JARVIS Python code + venv + dependencies
  • Vosk speech recognition model (~50 MB)
  • Piper TTS model (~65 MB)
  • JARVIS systemd services (enabled)
  • SDDM enabled as display manager

No disk will be wiped. No partitioning.

Proceed?" 28 70 || { clear; echo "Aborted."; exit 0; }

    clear
    echo ""
    echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}  ║    Installing JARVIS OS Components               ║${NC}"
    echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    # ── Sync DB ──────────────────────────────────────────────────────────
    info "Syncing package database..."
    pacman -Sy --noconfirm 2>&1 || warn "pacman -Sy had issues — continuing"
    ok "Package database synced"

    # ── Base utilities ───────────────────────────────────────────────────
    info "Installing base utilities..."
    pacman -S --noconfirm --needed \
        sudo less nano vim wget curl git openssh man-db man-pages \
        unzip zip p7zip rsync tzdata bash-completion which lsof htop neofetch \
        || warn "Some base packages failed"
    ok "Base utilities installed"

    # ── Kernel packages ──────────────────────────────────────────────────
    info "Installing kernel packages..."
    pacman -S --noconfirm --needed linux linux-headers linux-firmware \
        || warn "Kernel packages had issues"
    ok "Kernel packages installed"

    # ── linux-jarvisos custom kernel ─────────────────────────────────────
    # Install alongside the existing kernel — does not remove it.
    # Looks for pre-built packages first, then offers to build from source.
    info "Installing linux-jarvisos custom kernel..."
    _install_linux_jarvisos() {
        # 1. Already installed?
        if pacman -Q linux-jarvisos >/dev/null 2>&1; then
            ok "linux-jarvisos already installed ($(pacman -Q linux-jarvisos | awk '{print $2}'))"
            return 0
        fi

        # 2. Pre-built package nearby (sibling build/kernel-pkg/ from ISO build)?
        local _script_dir; _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local _pkg_dir="${_script_dir}/../../build/kernel-pkg"
        local _pkg; _pkg=$(find "${_pkg_dir}" -name 'linux-jarvisos-[0-9]*.pkg.tar.zst' \
                            ! -name 'linux-jarvisos-headers-*' 2>/dev/null \
                            | sort -V | tail -1 || true)
        local _hdr; _hdr=$(find "${_pkg_dir}" -name 'linux-jarvisos-headers-[0-9]*.pkg.tar.zst' \
                            2>/dev/null | sort -V | tail -1 || true)

        if [ -n "${_pkg}" ] && [ -n "${_hdr}" ]; then
            info "Found pre-built packages: $(basename "${_pkg}")"
            pacman -U --noconfirm "${_pkg}" "${_hdr}" \
                && ok "linux-jarvisos installed from pre-built packages" && return 0
            warn "Pre-built package install failed — falling through to build from source"
        fi

        # 3. Build from source if linux-jarvisos submodule is available
        local _kernel_src="${_script_dir}/../../linux-jarvisos"
        local _build_script="${_script_dir}/../../scripts/03b-build-kernel.sh"
        if [ -f "${_kernel_src}/Makefile" ] && [ -f "${_build_script}" ]; then
            info "Building linux-jarvisos from source (may take 20-60 min)..."
            if command -v makepkg >/dev/null 2>&1; then
                bash "${_build_script}" --host-install \
                    && ok "linux-jarvisos built and installed from source" && return 0
                warn "linux-jarvisos build failed"
            else
                warn "makepkg not found — cannot build linux-jarvisos on this system"
            fi
        fi

        # 4. Not available — print instructions and continue
        warn "linux-jarvisos not installed. JARVIS kernel features (/dev/jarvis, policy engine,"
        warn "sysmon sysfs) will be unavailable. The JARVIS AI stack runs on the stock kernel."
        warn "To install linux-jarvisos later:"
        warn "  git clone --recursive https://github.com/JarvisOSLinux/linux-jarvisos linux-jarvisos"
        warn "  bash scripts/03b-build-kernel.sh --host-install"
        return 0
    }
    _install_linux_jarvisos

    # Update GRUB/systemd-boot to add linux-jarvisos entry if kernel installed
    if pacman -Q linux-jarvisos >/dev/null 2>&1; then
        if [ -f /boot/vmlinuz-linux-jarvisos ]; then
            if [ -d /sys/firmware/efi/efivars ] && [ -d /boot/loader/entries ]; then
                # systemd-boot: add entry if not already present
                local _entry="/boot/loader/entries/jarvisos.conf"
                if [ ! -f "${_entry}" ]; then
                    local _root_partuuid; _root_partuuid=$(blkid -s PARTUUID -o value "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
                    if [ -n "${_root_partuuid}" ]; then
                        cat > "${_entry}" << BOOTEOF
title   JARVIS OS (linux-jarvisos)
linux   /vmlinuz-linux-jarvisos
initrd  /initramfs-linux-jarvisos.img
options root=PARTUUID=${_root_partuuid} rw
BOOTEOF
                        ok "systemd-boot entry added for linux-jarvisos"
                    fi
                fi
            elif command -v grub-mkconfig >/dev/null 2>&1; then
                # GRUB: os-prober + grub-mkconfig picks up all installed kernels
                grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null \
                    && ok "GRUB updated to include linux-jarvisos entry" \
                    || warn "grub-mkconfig failed — update GRUB manually: grub-mkconfig -o /boot/grub/grub.cfg"
            fi
            # Regenerate initramfs for linux-jarvisos
            if [ -f /etc/mkinitcpio.d/linux-jarvisos.preset ]; then
                mkinitcpio -p linux-jarvisos \
                    && ok "linux-jarvisos initramfs regenerated" \
                    || warn "mkinitcpio failed for linux-jarvisos"
            fi
        fi
    fi

    # ── KDE Plasma Wayland ───────────────────────────────────────────────
    info "Installing KDE Plasma Wayland..."
    pacman -S --noconfirm --needed \
        plasma-desktop plasma-workspace \
        kwin plasma-nm plasma-pa kscreen powerdevil bluedevil \
        kinfocenter polkit-kde-agent kdeplasma-addons plasma-systemmonitor \
        sddm sddm-kcm breeze breeze-gtk kde-gtk-config oxygen-sounds \
        kwalletmanager kwallet-pam \
        qt5-wayland qt6-wayland xorg-xwayland \
        dolphin konsole kate ark spectacle gwenview okular kcalc \
        filelight kdeconnect \
        xdg-user-dirs xdg-desktop-portal xdg-desktop-portal-kde \
        || warn "Some KDE packages failed"
    ok "KDE Plasma installed"

    # ── PipeWire ─────────────────────────────────────────────────────────
    info "Installing PipeWire audio..."
    pacman -S --noconfirm --needed \
        pipewire pipewire-alsa pipewire-jack pipewire-pulse wireplumber \
        gst-plugin-pipewire gst-plugins-good gst-plugins-bad gst-plugins-ugly \
        sof-firmware alsa-firmware alsa-utils alsa-plugins \
        rtkit pavucontrol \
        || warn "Some audio packages failed"
    ok "PipeWire installed"

    # ── Bluetooth ────────────────────────────────────────────────────────
    info "Installing Bluetooth..."
    pacman -S --noconfirm --needed bluez bluez-utils \
        || warn "Bluetooth packages failed"

    # ── Network ──────────────────────────────────────────────────────────
    info "Installing network tools..."
    pacman -S --noconfirm --needed \
        networkmanager nm-connection-editor network-manager-applet \
        wpa_supplicant wireless-regdb iw modemmanager dhcpcd \
        || warn "Some network packages failed"
    ok "Network tools installed"

    # ── GPU drivers ──────────────────────────────────────────────────────
    info "Installing GPU drivers..."
    pacman -S --noconfirm --needed \
        mesa vulkan-intel vulkan-radeon vulkan-swrast \
        libva-intel-driver intel-media-driver xf86-video-amdgpu \
        || warn "Some GPU packages failed"
    ok "GPU drivers installed"

    # ── Input + fonts + filesystem tools ─────────────────────────────────
    info "Installing input drivers, fonts, filesystem tools..."
    pacman -S --noconfirm --needed \
        libinput xf86-input-libinput xf86-input-evdev libevdev \
        noto-fonts noto-fonts-emoji ttf-liberation ttf-dejavu noto-fonts-cjk \
        e2fsprogs btrfs-progs dosfstools exfatprogs ntfs-3g \
        parted gptfdisk grub efibootmgr arch-install-scripts \
        || warn "Some packages failed"
    ok "Drivers, fonts, filesystem tools installed"

    # ── Python + JARVIS system deps ───────────────────────────────────────
    info "Installing Python + JARVIS system dependencies..."
    pacman -S --noconfirm --needed \
        python python-pip python-setuptools python-wheel python-virtualenv \
        gcc make pkg-config dialog portaudio python-pyaudio \
        || warn "Some Python packages failed"
    ok "Python dependencies installed"

    # ── JARVIS OS branding ────────────────────────────────────────────────
    info "Applying JARVIS OS branding..."
    cat > /etc/os-release << 'EOF'
NAME="JARVIS OS"
PRETTY_NAME="JARVIS OS"
ID=jarvisos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://github.com/JarvisOSLinux/jarvisos"
DOCUMENTATION_URL="https://github.com/JarvisOSLinux/jarvisos/wiki"
LOGO=distributor-logo-jarvisos
EOF
    ok "JARVIS OS branding applied"

    # ── Ollama (GPU-aware install) ─────────────────────────────────────────
    info "Installing Ollama..."
    if command -v ollama >/dev/null 2>&1; then
        ok "Ollama already installed ($(ollama --version 2>/dev/null || echo unknown))"
    else
        _install_ollama_gpu
    fi

    # Ollama systemd service
    if [ ! -f /usr/lib/systemd/system/ollama.service ]; then
        cat > /usr/lib/systemd/system/ollama.service << 'OLLAMAEOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="HOME=/usr/share/ollama"
Environment="OLLAMA_HOST=127.0.0.1"

[Install]
WantedBy=default.target
OLLAMAEOF
    fi
    getent group  ollama >/dev/null 2>&1 || groupadd -r ollama
    getent passwd ollama >/dev/null 2>&1 || \
        useradd -r -g ollama -d /usr/share/ollama -s /bin/false -c 'Ollama Service' ollama
    mkdir -p /usr/share/ollama && chown -R ollama:ollama /usr/share/ollama

    # ── JARVIS user + directories ─────────────────────────────────────────
    info "Setting up JARVIS user and directories..."
    getent group  jarvis >/dev/null 2>&1 || groupadd -r jarvis
    getent passwd jarvis >/dev/null 2>&1 || \
        useradd -r -g jarvis -d /var/lib/jarvis -s /sbin/nologin \
                -c 'JARVIS AI Assistant' jarvis
    for grp in audio video network systemd-journal storage optical; do
        getent group "${grp}" >/dev/null 2>&1 && \
            usermod -aG "${grp}" jarvis 2>/dev/null || true
    done
    mkdir -p /usr/lib/jarvis /etc/jarvis \
             /var/lib/jarvis/models/piper \
             /var/lib/jarvis/models/vosk \
             /var/log/jarvis
    chown -R jarvis:jarvis /var/lib/jarvis /var/log/jarvis
    ok "JARVIS user and directories configured"

    # ── JARVIS code ───────────────────────────────────────────────────────
    info "Installing JARVIS code..."
    local _jarvis_src
    _jarvis_src=$(find_jarvis_source)

    if [ "${_jarvis_src}" = "installed" ]; then
        ok "JARVIS code already at /usr/lib/jarvis"
    elif [ -n "${_jarvis_src}" ]; then
        cp -r "${_jarvis_src}/jarvis/"* /usr/lib/jarvis/
        [ -f "${_jarvis_src}/jarvis/.env.example" ] && \
            cp "${_jarvis_src}/jarvis/.env.example" /usr/lib/jarvis/.env.example
        [ -f "${_jarvis_src}/requirements.txt" ] && \
            cp "${_jarvis_src}/requirements.txt" /usr/lib/jarvis/requirements.txt
        chown -R jarvis:jarvis /usr/lib/jarvis
        ok "JARVIS code installed from ${_jarvis_src}"
    else
        warn "JARVIS source not found locally — cloning from GitHub..."
        if git clone --depth=1 \
                https://github.com/YakupAtahanov/Project-JARVIS \
                /tmp/Project-JARVIS-pkginstall 2>&1; then
            cp -r /tmp/Project-JARVIS-pkginstall/jarvis/* /usr/lib/jarvis/
            [ -f /tmp/Project-JARVIS-pkginstall/jarvis/.env.example ] && \
                cp /tmp/Project-JARVIS-pkginstall/jarvis/.env.example /usr/lib/jarvis/.env.example
            [ -f /tmp/Project-JARVIS-pkginstall/requirements.txt ] && \
                cp /tmp/Project-JARVIS-pkginstall/requirements.txt /usr/lib/jarvis/requirements.txt
            chown -R jarvis:jarvis /usr/lib/jarvis
            rm -rf /tmp/Project-JARVIS-pkginstall
            ok "JARVIS code cloned and installed"
        else
            warn "Could not clone Project-JARVIS — install JARVIS code manually:"
            warn "  git clone https://github.com/YakupAtahanov/Project-JARVIS /tmp/jarvis"
            warn "  sudo cp -r /tmp/jarvis/jarvis/* /usr/lib/jarvis/"
        fi
    fi

    # ── Python venv ───────────────────────────────────────────────────────
    if [ -f /usr/lib/jarvis/requirements.txt ]; then
        if [ ! -d /var/lib/jarvis/venv ]; then
            info "Creating Python virtual environment..."
            python3 -m venv /var/lib/jarvis/venv
            /var/lib/jarvis/venv/bin/pip install --upgrade pip
            /var/lib/jarvis/venv/bin/pip install -r /usr/lib/jarvis/requirements.txt \
                || warn "Some Python deps failed — check /var/lib/jarvis/venv manually"
            chown -R jarvis:jarvis /var/lib/jarvis/venv
            ok "Python venv created"
        else
            ok "Python venv already exists"
        fi
    else
        warn "requirements.txt missing — skipping venv setup"
    fi

    # ── .env defaults ─────────────────────────────────────────────────────
    if [ -f /usr/lib/jarvis/.env.example ] && [ ! -f /usr/lib/jarvis/.env ]; then
        cp /usr/lib/jarvis/.env.example /usr/lib/jarvis/.env
        chown jarvis:jarvis /usr/lib/jarvis/.env
    fi
    if [ -f /usr/lib/jarvis/.env ]; then
        _set_env() {
            local k="$1" v="$2" f="/usr/lib/jarvis/.env"
            grep -q "^${k}=" "${f}" \
                && sed -i "s|^${k}=.*|${k}=${v}|" "${f}" \
                || echo "${k}=${v}" >> "${f}"
        }
        _set_env LLM_AUTO_PULL     true
        _set_env LLM_MODEL         qwen3:4b
        _set_env VOSK_MODEL_PATH   /var/lib/jarvis/models/vosk/vosk-model-small-en-us-0.15
        _set_env TTS_MODEL_ONNX    /var/lib/jarvis/models/piper/en_US-amy-medium.onnx
        _set_env TTS_MODEL_JSON    /var/lib/jarvis/models/piper/en_US-amy-medium.onnx.json
        _set_env OUTPUT_MODE       voice
        _set_env CONTEXTOR_ENABLED true
        _set_env DATA_CONSENT      true
        chown jarvis:jarvis /usr/lib/jarvis/.env
        ok ".env defaults applied"
    fi

    # ── CLI wrappers ──────────────────────────────────────────────────────
    info "Installing CLI wrappers..."
    cat > /usr/bin/jarvis << 'JCLI'
#!/bin/bash
VENV_PATH="/var/lib/jarvis/venv"
[ -f "${VENV_PATH}/bin/activate" ] && source "${VENV_PATH}/bin/activate"
export PYTHONPATH="/usr/lib:${PYTHONPATH:-}"
cd /usr/lib/jarvis
python -m jarvis.cli "$@"
JCLI
    chmod +x /usr/bin/jarvis

    cat > /usr/bin/jarvis-daemon << 'JD'
#!/bin/bash
VENV_PATH="/var/lib/jarvis/venv"
[ -f "${VENV_PATH}/bin/activate" ] && source "${VENV_PATH}/bin/activate"
export PYTHONPATH="/usr/lib:${PYTHONPATH:-}"
cd /usr/lib/jarvis
exec python -m jarvis.cli run "$@"
JD
    chmod +x /usr/bin/jarvis-daemon
    ok "CLI wrappers installed"

    # ── sudoers + polkit ──────────────────────────────────────────────────
    cat > /etc/sudoers.d/10-jarvis << 'SUDOERS_EOF'
Defaults:jarvis !requiretty, !lecture, passwd_tries=0
jarvis ALL=(ALL) NOPASSWD: \
    /usr/bin/pacman,        \
    /usr/bin/systemctl,     \
    /usr/bin/journalctl,    \
    /usr/bin/nmcli,         \
    /usr/bin/timedatectl,   \
    /usr/bin/localectl,     \
    /usr/bin/hostnamectl,   \
    /usr/bin/modprobe,      \
    /usr/bin/sysctl,        \
    /usr/bin/chmod,         \
    /usr/bin/chown,         \
    /usr/bin/mkdir,         \
    /usr/bin/tee,           \
    /usr/bin/cp,            \
    /usr/bin/mv,            \
    /usr/bin/rm
SUDOERS_EOF
    chmod 440 /etc/sudoers.d/10-jarvis

    mkdir -p /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/49-jarvis.rules << 'POLKIT_EOF'
polkit.addRule(function(action, subject) {
    if (subject.user === "jarvis") {
        var allowed = [
            "org.freedesktop.systemd1",
            "org.freedesktop.NetworkManager",
            "org.freedesktop.timedate1",
            "org.freedesktop.locale1",
            "org.freedesktop.hostname1",
            "org.freedesktop.login1",
        ];
        for (var i = 0; i < allowed.length; i++) {
            if (action.id.indexOf(allowed[i]) === 0) { return polkit.Result.YES; }
        }
    }
});
POLKIT_EOF
    chmod 644 /etc/polkit-1/rules.d/49-jarvis.rules
    ok "sudoers + polkit rules installed"

    # ── Systemd service units ─────────────────────────────────────────────
    info "Installing systemd service units..."
    cat > /usr/lib/systemd/system/jarvis.service << 'JARVISSVC'
[Unit]
Description=JARVIS AI Voice Assistant
After=network.target sound.target ollama.service
Wants=network.target ollama.service

[Service]
Type=simple
User=jarvis
Group=jarvis
SupplementaryGroups=audio video network systemd-journal storage
WorkingDirectory=/usr/lib/jarvis
RuntimeDirectory=jarvis
RuntimeDirectoryMode=0775
ExecStart=/usr/bin/jarvis-daemon
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30
AmbientCapabilities=CAP_SYS_ADMIN CAP_NET_ADMIN CAP_SYS_NICE
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_NET_ADMIN CAP_SYS_NICE
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes
LimitNOFILE=65536
LimitNPROC=4096
Environment=JARVIS_CONFIG_DIR=/etc/jarvis
Environment=JARVIS_DATA_DIR=/var/lib/jarvis
Environment=JARVIS_INPUT_SOCKET=/run/jarvis/input.sock
Environment=JARVIS_LOG_DIR=/var/log/jarvis
Environment=JARVIS_MODELS_DIR=/var/lib/jarvis/models
Environment=PYTHONPATH=/usr/lib
Environment=OLLAMA_HOST=127.0.0.1:11434
Environment=XDG_RUNTIME_DIR=/run/user/0
StandardOutput=journal
StandardError=journal
SyslogIdentifier=jarvis

[Install]
WantedBy=multi-user.target
JARVISSVC

    cat > /usr/lib/systemd/system/jarvis-setup.service << 'SETUPSVC'
[Unit]
Description=JARVIS First-Boot Setup (pull LLM model)
After=network-online.target ollama.service
Wants=network-online.target ollama.service
ConditionPathExists=!/var/lib/jarvis/.setup-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/jarvis-first-boot.sh
RemainAfterExit=yes
TimeoutStartSec=600
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SETUPSVC

    cat > /usr/local/bin/jarvis-first-boot.sh << 'FIRSTBOOT'
#!/bin/bash
MARKER="/var/lib/jarvis/.setup-done"
LOG="/var/log/jarvis/first-boot.log"
mkdir -p /var/log/jarvis
exec > >(tee -a "$LOG") 2>&1
echo "=== JARVIS first-boot $(date) ==="
[ -f "$MARKER" ] && echo "Already done." && exit 0
MODEL="qwen3:4b"
[ -f /usr/lib/jarvis/.env ] && \
    _m=$(grep -E '^LLM_MODEL=' /usr/lib/jarvis/.env | cut -d= -f2-) && \
    [ -n "$_m" ] && MODEL="$_m"
echo "Waiting for Ollama..."
for i in $(seq 1 60); do
    curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break; sleep 2
done
ollama list 2>/dev/null | grep -q "${MODEL%%:*}" || ollama pull "$MODEL" || exit 1
touch "$MARKER"
systemctl disable jarvis-setup.service 2>/dev/null || true
echo "First-boot complete."
FIRSTBOOT
    chmod 755 /usr/local/bin/jarvis-first-boot.sh

    # ── First-login welcome + model selection wizard ──────────────────────
    cat > /usr/local/bin/jarvis-welcome.sh << 'WELCOMEEOF'
#!/bin/bash
# JARVIS OS first-login setup wizard — runs once via KDE autostart
MARKER="${HOME}/.config/jarvis-welcome-done"
ENV_FILE="/usr/lib/jarvis/.env"
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'

[ -f "$MARKER" ] && exit 0

clear
echo ""
echo -e "${BOLD}${CYAN}  ╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║              Welcome to JARVIS OS                  ║${NC}"
echo -e "${BOLD}${CYAN}  ║           AI-Native Linux Distribution             ║${NC}"
echo -e "${BOLD}${CYAN}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Wait for Ollama ───────────────────────────────────────────────────────
echo -e "  Checking Ollama AI engine..."
for i in $(seq 1 30); do
    curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
    sleep 2
done

OLLAMA_OK=false
curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && OLLAMA_OK=true

if $OLLAMA_OK; then
    echo -e "  ${GREEN}✓ Ollama ready${NC}"
else
    echo -e "  ${YELLOW}⚠ Ollama not responding — services may still be starting.${NC}"
    echo -e "    Check: sudo systemctl status ollama"
fi
echo ""

# ── Read current model from .env ─────────────────────────────────────────
CURRENT_MODEL="qwen3:4b"
if [ -f "$ENV_FILE" ]; then
    _m=$(grep -E '^LLM_MODEL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
    [ -n "$_m" ] && CURRENT_MODEL="$_m"
fi

# ── Check model already downloaded ───────────────────────────────────────
MODEL_READY=false
if $OLLAMA_OK && ollama list 2>/dev/null | grep -q "${CURRENT_MODEL%%:*}"; then
    MODEL_READY=true
fi

if $MODEL_READY; then
    echo -e "  ${GREEN}✓ AI model ready: ${CURRENT_MODEL}${NC}"
else
    echo -e "  ${YELLOW}⚠ AI model not yet downloaded: ${CURRENT_MODEL}${NC}"
    echo -e "    First-boot service will pull it automatically (needs internet)."
fi
echo ""

# ── Model selection ───────────────────────────────────────────────────────
MODEL_CHOICE="keep"
if command -v dialog >/dev/null 2>&1; then
    MODEL_CHOICE=$(dialog --clear --backtitle "JARVIS OS Setup" \
        --title "AI Model Selection" \
        --menu "Select AI model (current: ${CURRENT_MODEL}):" 20 72 7 \
        "keep"          "Keep current: ${CURRENT_MODEL}" \
        "qwen3:4b"      "Qwen3 4B     — recommended  (~2.6 GB)" \
        "qwen3:8b"      "Qwen3 8B     — better quality (~5.2 GB)" \
        "llama3.2:3b"   "Llama 3.2 3B — lightweight  (~2.0 GB)" \
        "llama3.1:8b"   "Llama 3.1 8B — high quality (~4.9 GB)" \
        "gemma3:4b"     "Gemma 3 4B   — Google model (~3.3 GB)" \
        "custom"        "Enter custom model name" \
        3>&1 1>&2 2>&3) || MODEL_CHOICE="keep"

    if [ "${MODEL_CHOICE:-}" = "custom" ]; then
        MODEL_CHOICE=$(dialog --clear --backtitle "JARVIS OS Setup" \
            --title "Custom Model" \
            --inputbox "Enter Ollama model name (e.g. mistral:7b, phi3:mini):" \
            8 60 "${CURRENT_MODEL}" \
            3>&1 1>&2 2>&3) || MODEL_CHOICE="keep"
    fi
    clear
fi
[ -z "${MODEL_CHOICE:-}" ] && MODEL_CHOICE="keep"

# ── Apply model change ────────────────────────────────────────────────────
if [ "${MODEL_CHOICE}" != "keep" ] && [ -n "${MODEL_CHOICE}" ] \
        && [ "${MODEL_CHOICE}" != "${CURRENT_MODEL}" ]; then
    echo -e "  Switching model to: ${MODEL_CHOICE}"
    if [ -f "$ENV_FILE" ]; then
        if [ -w "$ENV_FILE" ]; then
            grep -q "^LLM_MODEL=" "$ENV_FILE" \
                && sed -i "s|^LLM_MODEL=.*|LLM_MODEL=${MODEL_CHOICE}|" "$ENV_FILE" \
                || echo "LLM_MODEL=${MODEL_CHOICE}" >> "$ENV_FILE"
        else
            grep -q "^LLM_MODEL=" "$ENV_FILE" \
                && sudo sed -i "s|^LLM_MODEL=.*|LLM_MODEL=${MODEL_CHOICE}|" "$ENV_FILE" \
                || echo "LLM_MODEL=${MODEL_CHOICE}" | sudo tee -a "$ENV_FILE" >/dev/null
        fi
    fi
    CURRENT_MODEL="${MODEL_CHOICE}"
    MODEL_READY=false
fi

# ── Pull model if not downloaded ─────────────────────────────────────────
if ! $MODEL_READY && $OLLAMA_OK; then
    echo ""
    echo -e "  Pulling AI model: ${BOLD}${CURRENT_MODEL}${NC}"
    echo -e "  This may take several minutes depending on your connection..."
    echo ""
    if ollama pull "${CURRENT_MODEL}"; then
        echo ""
        echo -e "  ${GREEN}✓ Model downloaded: ${CURRENT_MODEL}${NC}"
        MODEL_READY=true
        sudo systemctl disable jarvis-setup.service 2>/dev/null || true
        sudo touch /var/lib/jarvis/.setup-done 2>/dev/null || true
    else
        echo -e "  ${RED}✗ Model pull failed.${NC}"
        echo -e "    Try manually: ollama pull ${CURRENT_MODEL}"
        echo -e "    Or check:     sudo systemctl status jarvis-setup"
        echo ""
        echo -e "  Press Enter to continue..."
        read -r
    fi
fi

# ── Restart JARVIS daemon to pick up model/config changes ─────────────────
if $MODEL_READY; then
    sudo systemctl restart jarvis.service 2>/dev/null || true
fi

# ── Usage ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}  ╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║                 JARVIS OS Ready!                   ║${NC}"
echo -e "${BOLD}${CYAN}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}AI Model:${NC}   ${CURRENT_MODEL}"
echo -e "  ${BOLD}Engine:${NC}     Ollama (localhost:11434)"
echo -e "  ${BOLD}Kernel:${NC}     $(uname -r)"
echo ""
echo -e "  ${BOLD}How to use JARVIS:${NC}"
echo -e "    ${BOLD}jarvis chat${NC}      — interactive AI chat"
echo -e "    ${BOLD}jarvis voice${NC}     — voice mode (microphone + TTS)"
echo -e "    ${BOLD}jarvis status${NC}    — service status"
echo -e "    ${BOLD}jarvis --help${NC}    — all commands"
echo ""
echo -e "  ${CYAN}JARVIS runs as a background service and restarts automatically.${NC}"
echo -e "  Find it in the applications menu or launch from terminal."
echo ""
echo -e "  Press Enter to close this window..."
read -r

# ── Mark done — do not re-run on next login ───────────────────────────────
mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
WELCOMEEOF
    chmod 755 /usr/local/bin/jarvis-welcome.sh
    ok "Systemd service units installed"

    # ── Vosk STT model ────────────────────────────────────────────────────
    local _vosk_model="vosk-model-small-en-us-0.15"
    local _vosk_dest="/var/lib/jarvis/models/vosk"
    if [ -d "${_vosk_dest}/${_vosk_model}" ]; then
        ok "Vosk model already present"
    else
        info "Downloading Vosk STT model (~50 MB)..."
        local _vtmp; _vtmp=$(mktemp -d)
        if curl -fSL -o "${_vtmp}/${_vosk_model}.zip" \
                "https://alphacephei.com/vosk/models/${_vosk_model}.zip"; then
            unzip -qo "${_vtmp}/${_vosk_model}.zip" -d "${_vosk_dest}/"
            chown -R jarvis:jarvis "${_vosk_dest}"
            ok "Vosk model installed"
        else
            warn "Vosk download failed — voice recognition disabled until installed manually"
        fi
        rm -rf "${_vtmp}"
    fi

    # ── Piper TTS model ───────────────────────────────────────────────────
    local _piper_model="en_US-amy-medium"
    local _piper_dest="/var/lib/jarvis/models/piper"
    local _piper_base="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/amy/medium"
    mkdir -p "${_piper_dest}"
    if [ -f "${_piper_dest}/${_piper_model}.onnx" ]; then
        ok "Piper TTS model already present"
    else
        info "Downloading Piper TTS model (~65 MB)..."
        if curl -fSL -o "${_piper_dest}/${_piper_model}.onnx" \
                    "${_piper_base}/${_piper_model}.onnx" && \
           curl -fSL -o "${_piper_dest}/${_piper_model}.onnx.json" \
                    "${_piper_base}/${_piper_model}.onnx.json"; then
            chown -R jarvis:jarvis "${_piper_dest}"
            ok "Piper TTS model installed"
        else
            warn "Piper download failed — TTS disabled until installed manually"
        fi
    fi

    # ── XDG autostart + desktop launcher ─────────────────────────────────
    mkdir -p /etc/xdg/autostart /usr/share/applications
    cat > /etc/xdg/autostart/ollama.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Ollama Service
Exec=/usr/local/bin/ollama serve
Terminal=false
StartupNotify=false
NoDisplay=true
EOF
    cat > /etc/xdg/autostart/jarvis.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=JARVIS AI Assistant
Exec=/usr/bin/jarvis-daemon
Terminal=false
StartupNotify=false
NoDisplay=true
X-KDE-autostart-phase=2
EOF
    cat > /usr/share/applications/jarvis.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=JARVIS AI
GenericName=AI Assistant
Comment=Chat with your JARVIS AI assistant
Exec=konsole -e jarvis chat
Icon=utilities-terminal
Terminal=false
Categories=Utility;System;
Keywords=jarvis;ai;assistant;chat;voice;
StartupNotify=true
EOF

    # ── SDDM ─────────────────────────────────────────────────────────────
    info "Configuring SDDM..."
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/jarvisos.conf << 'SDDM'
[General]
DisplayServer=wayland
Numlock=on

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions
SDDM

    # ── NetworkManager backend ────────────────────────────────────────────
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/wifi-backend.conf << 'EOF'
[device]
wifi.backend=wpa_supplicant
EOF

    # ── Enable / disable services ─────────────────────────────────────────
    info "Enabling systemd services..."
    systemctl daemon-reload
    systemctl enable NetworkManager.service              2>/dev/null || true
    systemctl enable systemd-resolved.service            2>/dev/null || true
    systemctl enable sddm.service                        2>/dev/null || true
    systemctl enable bluetooth.service                   2>/dev/null || true
    systemctl enable rtkit-daemon.service                2>/dev/null || true
    systemctl enable ollama.service                      2>/dev/null || true
    systemctl enable jarvis.service                      2>/dev/null || true
    systemctl enable jarvis-setup.service                2>/dev/null || true
    systemctl disable iwd.service                        2>/dev/null || true
    systemctl mask    iwd.service                        2>/dev/null || true
    systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
    ok "Services enabled"

    # ── Done ──────────────────────────────────────────────────────────────
    clear
    echo ""
    echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}  ║     JARVIS OS Components Installed!              ║${NC}"
    echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Installed:${NC}"
    echo -e "    ✓ KDE Plasma Wayland + SDDM (enabled)"
    echo -e "    ✓ PipeWire audio + Bluetooth"
    echo -e "    ✓ NetworkManager + WiFi (wpa_supplicant)"
    echo -e "    ✓ GPU drivers (Mesa / Vulkan / Intel / AMD)"
    echo -e "    ✓ Ollama AI engine"
    echo -e "    ✓ JARVIS AI assistant + Python venv"
    echo -e "    ✓ Vosk STT + Piper TTS models"
    echo -e "    ✓ All systemd services enabled"
    echo ""
    echo -e "  ${CYAN}Next steps:${NC}"
    echo -e "    Reboot to start KDE Plasma Wayland + JARVIS"
    echo -e "    AI model (qwen3:4b) downloads on first boot (internet required)"
    echo ""
    echo -e "    ${BOLD}reboot${NC}"
    echo ""
}

# ── Uninstall JARVIS OS components from an overlay-installed system ────────
uninstall_mode() {
    need_root
    detect_arch_based

    dialog --clear --backtitle "JARVIS OS Uninstaller" \
           --title "Remove JARVIS OS Components" \
           --yesno "Remove JARVIS OS components from this system?\n\nThis will:\n  • Stop and disable jarvis, jarvis-setup, dmcp, ollama services\n  • Remove /usr/lib/jarvis, /var/lib/jarvis, /var/log/jarvis, /etc/jarvis\n  • Remove /usr/bin/jarvis, /usr/bin/jarvis-daemon, /usr/bin/dmcp, /usr/bin/dispatch\n  • Remove sudoers and polkit rules\n  • Remove systemd service units\n  • Remove SDDM config (if JarvisOS-managed)\n  • Remove XDG autostart entries\n\nDoes NOT remove: KDE Plasma, PipeWire, NetworkManager, linux-jarvisos kernel.\nTo remove linux-jarvisos: sudo pacman -R linux-jarvisos linux-jarvisos-headers\n\nProceed?" 28 70 \
        || { clear; echo "Aborted."; exit 0; }

    clear
    echo ""
    echo -e "${BOLD}${CYAN}  Removing JARVIS OS Components...${NC}"
    echo ""

    systemctl stop  jarvis.service jarvis-setup.service dmcp.service ollama.service 2>/dev/null || true
    systemctl disable jarvis.service jarvis-setup.service dmcp.service ollama.service 2>/dev/null || true

    rm -rf /usr/lib/jarvis /var/lib/jarvis /var/log/jarvis /etc/jarvis
    rm -f /usr/bin/jarvis /usr/bin/jarvis-daemon /usr/bin/dmcp /usr/bin/dispatch
    rm -f /usr/local/bin/jarvis-first-boot.sh /usr/local/bin/mount-bootmnt.sh
    rm -f /etc/sudoers.d/10-jarvis
    rm -f /etc/polkit-1/rules.d/49-jarvis.rules
    rm -f /usr/lib/systemd/system/jarvis.service \
          /usr/lib/systemd/system/jarvis-setup.service \
          /usr/lib/systemd/system/dmcp.service \
          /usr/lib/systemd/system/ollama.service
    rm -f /etc/xdg/autostart/jarvis.desktop /etc/xdg/autostart/ollama.desktop
    rm -f /usr/share/applications/jarvis.desktop
    rm -f /etc/NetworkManager/conf.d/wifi-backend.conf 2>/dev/null || true

    # Remove jarvis user/group (don't remove home since /var/lib/jarvis already deleted)
    userdel jarvis 2>/dev/null || true
    groupdel jarvis 2>/dev/null || true

    systemctl daemon-reload

    echo ""
    echo -e "${GREEN}JARVIS OS components removed.${NC}"
    echo ""
    echo -e "  To also remove linux-jarvisos kernel:"
    echo -e "    ${BOLD}sudo pacman -R linux-jarvisos linux-jarvisos-headers${NC}"
    echo -e "  Then update your bootloader:"
    echo -e "    ${BOLD}sudo grub-mkconfig -o /boot/grub/grub.cfg${NC}  (GRUB)"
    echo -e "    ${BOLD}sudo bootctl update${NC}  (systemd-boot)"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    # Overlay-install mode: add JarvisOS components to existing Arch system
    if [[ "${1:-}" == "--install-packages" || "${1:-}" == "--overlay" ]]; then
        install_packages_mode
        exit 0
    fi

    # Uninstall mode: remove JarvisOS components from overlay-installed system
    if [[ "${1:-}" == "--uninstall" || "${1:-}" == "--remove" ]]; then
        uninstall_mode
        exit 0
    fi

    need_root
    check_deps
    detect_uefi

    # Load keymap if set
    [ -f /etc/vconsole.conf ] && source /etc/vconsole.conf 2>/dev/null || true
    [ -n "${KEYMAP:-}" ] && loadkeys "${KEYMAP}" 2>/dev/null || true

    step_welcome
    step_select_disk
    step_partition_mode

    if [ "${PARTITION_MODE}" = "manual" ]; then
        step_cfdisk_edit
        step_manual_assign
        step_manual_swap
        step_select_bootloader
    else
        step_select_bootloader
        step_select_fs
        step_select_swap
    fi

    step_timezone
    step_keyboard
    step_locale
    step_hostname
    step_user
    step_summary

    clear
    echo ""
    echo -e "${BOLD}${CYAN}  JARVIS OS Installation${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    trap cleanup_mounts EXIT

    if [ "${PARTITION_MODE}" = "manual" ]; then
        info "Formatting and mounting partitions..."
        manual_format_and_mount
    else
        info "Partitioning ${TARGET_DISK}..."
        partition_disk
        info "Formatting partitions..."
        format_and_mount
    fi

    install_system

    info "Checking for linux-jarvisos kernel..."
    ensure_kernel

    info "Generating fstab..."
    generate_fstab

    info "Configuring system..."
    configure_system

    info "Installing bootloader..."
    install_bootloader

    create_swapfile

    trap - EXIT
    cleanup_mounts

    clear
    echo ""
    echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}  ║         JARVIS OS Installation Complete!         ║${NC}"
    echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo -e "    Disk:        ${TARGET_DISK}"
    echo -e "    Bootloader:  ${BOOT_LOADER}"
    echo -e "    Filesystem:  ${FS_TYPE}"
    echo -e "    Timezone:    ${TIMEZONE}"
    echo -e "    Keyboard:    ${KEYMAP}"
    echo -e "    Locale:      ${LOCALE}"
    echo -e "    Hostname:    ${HOSTNAME_VAL}"
    echo -e "    User:        ${NEW_USER}"
    echo ""
    echo -e "  ${CYAN}JARVIS AI:${NC} The AI model downloads on first login."
    echo -e "  A setup wizard will run automatically after you log in."
    echo ""
    echo -e "  ${YELLOW}Remove the installation medium, then reboot:${NC}"
    echo -e "    ${BOLD}reboot${NC}"
    echo ""
}

main "$@"
