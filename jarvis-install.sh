#!/bin/bash
# ============================================================================
# jarvis-install — JARVIS OS TUI Installer (orchestrator)
# ============================================================================
# Launches automatically on TTY1 when booting the live ISO.
# Run as root:  jarvis-install
#
# All install logic lives in iso-build-scripts/tasks/*.sh.
# This script is the thin TUI shell: collects settings, then calls task scripts.
#
# Modes:
#   (default)           — full TUI install to a disk
#   --overlay           — install JARVIS stack onto existing running OS
#   --install-packages  — alias for --overlay
#   --uninstall / --remove — remove JARVIS components from overlay-installed system
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
JARVIS_MODEL="qwen3:4b"
KERNEL_PKG="linux"
declare -A PART_MOUNT=()
declare -A PART_FS=()
declare -A PART_FORMAT=()

# ── Helpers ────────────────────────────────────────────────────────────────
die()  { clear; echo -e "${RED}FATAL: $*${NC}" >&2; exit 1; }
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
        info "Installing missing tools: ${missing[*]}"
        pacman -Sy --noconfirm --needed \
            dialog gptfdisk 2>/dev/null || true
    fi
}

detect_uefi() {
    if [ -d /sys/firmware/efi/efivars ]; then IS_EFI=true; else IS_EFI=false; fi
}

detect_arch_based() {
    local id="" id_like=""
    if [ -f /etc/os-release ]; then
        id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        id_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    case "${id}" in
        arch|manjaro|endeavouros|garuda|cachyos|artix|parabola|arcolinux|jarvisos) return 0 ;;
    esac
    [[ "${id_like}" == *arch* ]] && return 0
    die "Not an Arch-based system (ID=${id:-unknown}, ID_LIKE=${id_like:-unknown}).\nRun on Arch Linux or an Arch-based distro."
}

cleanup_mounts() {
    sync
    umount -R "${MOUNT_ROOT}" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
}

# ── Locate task scripts ────────────────────────────────────────────────────
_find_tasks_dir() {
    local _self_dir; _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Pre-seeded in chroot by task-base-install.sh
    [ -d "/tmp/jarvis-tasks" ] && echo "/tmp/jarvis-tasks" && return 0
    # Installed on live ISO by 05-bake-installer.sh
    [ -d "/usr/share/jarvis-install/tasks" ] && echo "/usr/share/jarvis-install/tasks" && return 0
    # Repo layout (developer / host-install context)
    for _d in \
        "${_self_dir}/iso-build-scripts/tasks" \
        "${_self_dir}/../iso-build-scripts/tasks" \
        "${_self_dir}/../../iso-build-scripts/tasks"; do
        [ -d "${_d}" ] && echo "$(realpath "${_d}")" && return 0
    done
    return 1
}

TASKS_DIR=""
TASKS_DIR=$(_find_tasks_dir || true)

# ── Task runner ────────────────────────────────────────────────────────────
# Runs a task script from TASKS_DIR with live dialog output.
# On failure: shows last lines + retry/abort dialog.
run_task() {
    local task_name="$1"
    [ -n "${TASKS_DIR}" ] || die "Cannot find tasks/ directory. Check iso-build-scripts/tasks/ exists."
    local task_script="${TASKS_DIR}/${task_name}"
    [ -f "${task_script}" ] || die "Task script not found: ${task_script}"

    local log_file; log_file=$(mktemp /tmp/jarvis-task-XXXXXX.log)

    # Show live task output via dialog tailbox (background)
    dialog --backtitle "JARVIS OS Installer" \
           --title " ${task_name%.sh} " \
           --tailbox "${log_file}" 25 76 &
    local dlg_pid=$!

    # Run task; all exports already set by caller
    bash "${task_script}" >> "${log_file}" 2>&1
    local rc=$?

    sleep 0.3
    kill "${dlg_pid}" 2>/dev/null; wait "${dlg_pid}" 2>/dev/null || true

    if [ "${rc}" -ne 0 ]; then
        local last_lines; last_lines=$(tail -15 "${log_file}" | sed 's/\x1b\[[0-9;]*m//g')
        local response
        response=$(dialog --backtitle "JARVIS OS Installer" \
            --title "Task Failed: ${task_name%.sh}" \
            --menu "${last_lines}\n\nExit code: ${rc}" \
            24 78 2 \
            "retry" "Retry this task" \
            "abort" "Abort installation" \
            3>&1 1>&2 2>&3) || response="abort"
        rm -f "${log_file}"
        case "${response}" in
            retry) run_task "$@"; return $? ;;
            *)     die "Installation aborted at task: ${task_name%.sh}" ;;
        esac
    fi
    rm -f "${log_file}"
}

# ── Serialize associative arrays for manual partition mode ─────────────────
_write_state_file() {
    # Writes PART_MOUNT/PART_FS/PART_FORMAT + other state to JARVIS_STATE_FILE
    # so task-partition.sh can source it.
    {
        echo "# jarvis-install state — auto-generated"
        echo "declare -A PART_MOUNT=()"
        for k in "${!PART_MOUNT[@]}"; do
            printf 'PART_MOUNT[%q]=%q\n' "${k}" "${PART_MOUNT[$k]}"
        done
        echo "declare -A PART_FS=()"
        for k in "${!PART_FS[@]}"; do
            printf 'PART_FS[%q]=%q\n' "${k}" "${PART_FS[$k]}"
        done
        echo "declare -A PART_FORMAT=()"
        for k in "${!PART_FORMAT[@]}"; do
            printf 'PART_FORMAT[%q]=%q\n' "${k}" "${PART_FORMAT[$k]}"
        done
        echo "FS_TYPE=${FS_TYPE}"
        echo "SWAP_SIZE=${SWAP_SIZE}"
        echo "KERNEL_PKG=${KERNEL_PKG}"
    } > "${JARVIS_STATE_FILE}"
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

    local _disk_bytes
    _disk_bytes=$(lsblk -bdno SIZE "${TARGET_DISK}" 2>/dev/null || echo 0)
    if (( _disk_bytes < 20 * 1024 * 1024 * 1024 )); then
        d_yesno "Disk Too Small" \
            "${TARGET_DISK} is under 20 GiB.\nJARVIS OS needs 20 GiB minimum.\n\nContinue anyway?" \
            || { clear; echo "Aborted."; exit 0; }
    fi
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

    if [ "${region}" = "UTC" ]; then TIMEZONE="UTC"; return; fi

    local city_items=()
    while IFS= read -r city; do
        city_items+=("${city}" "")
    done < <(find "/usr/share/zoneinfo/${region}" -type f 2>/dev/null \
             | sed "s|/usr/share/zoneinfo/${region}/||" | sort)

    if [ ${#city_items[@]} -eq 0 ]; then TIMEZONE="${region}"; return; fi

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
    local _reserved="root bin daemon mail ftp http nobody dbus systemd-network systemd-resolve"
    while true; do
        NEW_USER=$(d_input "Create User" "Enter username for the new account:" "user") || { clear; exit 0; }
        NEW_USER="${NEW_USER:-user}"
        NEW_USER=$(echo "${NEW_USER}" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')
        if [ -z "${NEW_USER}" ]; then
            d_msgbox "Invalid" "Username cannot be empty."; continue
        fi
        if [[ "${NEW_USER}" =~ ^[0-9] ]]; then
            d_msgbox "Invalid" "Username cannot start with a digit."; continue
        fi
        if echo "${_reserved}" | grep -qw "${NEW_USER}"; then
            d_msgbox "Reserved" "\"${NEW_USER}\" is a reserved system name. Choose another."; continue
        fi
        break
    done

    local pass1 pass2
    while true; do
        pass1=$(d_password "User Password" "Password for ${NEW_USER}:") || { clear; exit 0; }
        if [ -z "${pass1}" ]; then d_msgbox "Empty" "Password cannot be empty."; continue; fi
        pass2=$(d_password "Confirm Password" "Confirm password:") || { clear; exit 0; }
        [ "${pass1}" = "${pass2}" ] && break
        d_msgbox "Mismatch" "Passwords do not match. Try again."
    done
    USER_PASS="${pass1}"

    local rp1 rp2
    while true; do
        rp1=$(d_password "Root Password" "Set the root password:") || { clear; exit 0; }
        if [ -z "${rp1}" ]; then d_msgbox "Empty" "Root password cannot be empty."; continue; fi
        rp2=$(d_password "Confirm Root Password" "Confirm root password:") || { clear; exit 0; }
        [ "${rp1}" = "${rp2}" ] && break
        d_msgbox "Mismatch" "Passwords do not match. Try again."
    done
    ROOT_PASS="${rp1}"
}

# ── Step 11: AI Model Selection ────────────────────────────────────────────
step_ai_model() {
    local ram_mb rec_model
    ram_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)
    local ram_gb=$(( ram_mb / 1024 ))

    if   [ "${ram_mb}" -ge 16000 ]; then rec_model="llama3.1:8b"
    elif [ "${ram_mb}" -ge  8000 ]; then rec_model="qwen3:8b"
    elif [ "${ram_mb}" -ge  4000 ]; then rec_model="qwen3:4b"
    else                                 rec_model="llama3.2:3b"
    fi

    local _q4b="Qwen3 4B     — balanced quality  (~2.6 GB)"
    local _q8b="Qwen3 8B     — better quality    (~5.2 GB)"
    local _l3b="Llama 3.2 3B — lightweight       (~2.0 GB)"
    local _l8b="Llama 3.1 8B — high quality      (~4.9 GB)"
    local _g4b="Gemma 3 4B   — Google model      (~3.3 GB)"
    case "${rec_model}" in
        "qwen3:4b")    _q4b="${_q4b} ★" ;;
        "qwen3:8b")    _q8b="${_q8b} ★" ;;
        "llama3.2:3b") _l3b="${_l3b} ★" ;;
        "llama3.1:8b") _l8b="${_l8b} ★" ;;
    esac

    local choice
    choice=$(dialog --clear --backtitle "JARVIS OS Installer" \
        --title "AI Model Selection" \
        --default-item "${rec_model}" \
        --menu "Select AI model to install  (System RAM: ${ram_gb} GB — ★ = recommended)" \
        22 72 6 \
        "qwen3:4b"    "${_q4b}" \
        "qwen3:8b"    "${_q8b}" \
        "llama3.2:3b" "${_l3b}" \
        "llama3.1:8b" "${_l8b}" \
        "gemma3:4b"   "${_g4b}" \
        "none"        "None — skip model download (configure after first boot)" \
        3>&1 1>&2 2>&3) || choice="${rec_model}"

    JARVIS_MODEL="${choice:-${rec_model}}"
}

# ── Step 12: Summary ───────────────────────────────────────────────────────
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
        local _model_label="${JARVIS_MODEL}"
        [ "${_model_label}" = "none" ] && _model_label="None (configure after boot)"
        body+="
Bootloader:  ${BOOT_LOADER}
Timezone:    ${TIMEZONE}
Keyboard:    ${KEYMAP}
Locale:      ${LOCALE}
Hostname:    ${HOSTNAME_VAL}
User:        ${NEW_USER}
AI Model:    ${_model_label}

Marked partitions will be formatted. Others kept.
Proceed with installation?"
    else
        local swap_label="${SWAP_SIZE} MiB"
        [ "${SWAP_SIZE}" = "0" ]    && swap_label="None"
        [ "${SWAP_SIZE}" = "file" ] && swap_label="4 GiB swapfile"
        local _model_label="${JARVIS_MODEL}"
        [ "${_model_label}" = "none" ] && _model_label="None (configure after boot)"
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
AI Model:    ${_model_label}

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

        if [ "${mountpt}" = "swap" ]; then
            PART_FS["${part}"]="swap"
            local fmt_choice
            fmt_choice=$(d_menu "Format? — ${part}" 10 60 \
                "yes" "Format as swap (mkswap)" \
                "no"  "Use existing swap partition") \
                || { clear; exit 0; }
            PART_FORMAT["${part}"]="${fmt_choice}"
        else
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

# ── Uninstall mode ─────────────────────────────────────────────────────────
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

    userdel jarvis 2>/dev/null || true
    groupdel jarvis 2>/dev/null || true

    systemctl daemon-reload 2>/dev/null || true

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
    # ── Overlay / install-packages mode ──────────────────────────────────
    if [[ "${1:-}" == "--install-packages" || "${1:-}" == "--overlay" ]]; then
        OVERLAY_MODE="${1}"
        # Read model selection written by task-base-install.sh before chroot
        JARVIS_MODEL=$(cat /tmp/.jarvis-model-choice 2>/dev/null \
            | tr -cd '[:alnum:]:.-' | head -c 64)
        [ -z "${JARVIS_MODEL}" ] && JARVIS_MODEL="qwen3:4b"

        if [ "$(id -u)" -ne 0 ]; then
            echo "Root required — re-launching with sudo"
            exec sudo bash "${BASH_SOURCE[0]}" "${OVERLAY_MODE}"
        fi

        export JARVIS_MODEL OVERLAY_MODE

        # Locate and dispatch to task-overlay-detect.sh
        local _tasks
        if ! _tasks=$(_find_tasks_dir 2>/dev/null); then
            # Fallback: try standard install path
            if [ -d "/usr/share/jarvis-install/tasks" ]; then
                _tasks="/usr/share/jarvis-install/tasks"
            else
                die "Cannot find task scripts. Expected at iso-build-scripts/tasks/ or /tmp/jarvis-tasks/."
            fi
        fi
        exec bash "${_tasks}/task-overlay-detect.sh"
    fi

    # ── Uninstall mode ────────────────────────────────────────────────────
    if [[ "${1:-}" == "--uninstall" || "${1:-}" == "--remove" ]]; then
        uninstall_mode
        exit 0
    fi

    # ── Full disk install mode ────────────────────────────────────────────
    need_root
    check_deps
    detect_uefi

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
    step_ai_model
    step_summary

    clear
    echo ""
    echo -e "${BOLD}${CYAN}  JARVIS OS Installation${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    trap cleanup_mounts EXIT

    # Create state file for task scripts
    JARVIS_STATE_FILE=$(mktemp /tmp/jarvis-state-XXXXXX.sh)
    _write_state_file

    # Export all settings for task scripts
    export TARGET_DISK PARTITION_MODE FS_TYPE SWAP_SIZE MOUNT_ROOT
    export IS_EFI HOSTNAME_VAL NEW_USER USER_PASS ROOT_PASS
    export BOOT_LOADER LOCALE TIMEZONE KEYMAP
    export JARVIS_MODEL JARVIS_STATE_FILE KERNEL_PKG
    export INSTALLER_PATH; INSTALLER_PATH="$(realpath "${BASH_SOURCE[0]}")"

    # ── Run install tasks in sequence ─────────────────────────────────────
    run_task task-partition.sh

    # After manual partition, re-read FS_TYPE from state file
    if [ "${PARTITION_MODE}" = "manual" ]; then
        # shellcheck source=/dev/null
        source "${JARVIS_STATE_FILE}"
        export FS_TYPE
    fi

    run_task task-base-install.sh
    run_task task-kernel.sh

    # Read KERNEL_PKG back from state file (written by task-kernel.sh)
    # shellcheck source=/dev/null
    source "${JARVIS_STATE_FILE}"
    export KERNEL_PKG="${KERNEL_PKG:-linux}"

    run_task task-fstab.sh
    run_task task-configure.sh
    run_task task-bootloader.sh
    run_task task-swap.sh

    rm -f "${JARVIS_STATE_FILE}"
    trap - EXIT
    cleanup_mounts

    # ── Success banner ────────────────────────────────────────────────────
    clear
    echo ""
    echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}  ║         JARVIS OS Installation Complete!         ║${NC}"
    echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    local _final_model="${JARVIS_MODEL:-qwen3:4b}"
    echo -e "  ${BOLD}Summary:${NC}"
    echo -e "    Disk:        ${TARGET_DISK}"
    echo -e "    Bootloader:  ${BOOT_LOADER}"
    echo -e "    Filesystem:  ${FS_TYPE}"
    echo -e "    Timezone:    ${TIMEZONE}"
    echo -e "    Keyboard:    ${KEYMAP}"
    echo -e "    Locale:      ${LOCALE}"
    echo -e "    Hostname:    ${HOSTNAME_VAL}"
    echo -e "    User:        ${NEW_USER}"
    echo -e "    AI Model:    ${_final_model}"
    echo ""
    if [ "${_final_model}" = "none" ]; then
        echo -e "  ${CYAN}JARVIS AI:${NC} No model selected. Run 'ollama pull <model>' after boot."
    else
        echo -e "  ${CYAN}JARVIS AI:${NC} Model '${_final_model}' pulls on first boot (internet required)."
    fi
    echo -e "  A setup wizard runs automatically after your first login."
    echo ""
    echo -e "  ${YELLOW}Remove the installation medium, then reboot:${NC}"
    echo -e "    ${BOLD}reboot${NC}"
    echo ""
}

main "$@"
