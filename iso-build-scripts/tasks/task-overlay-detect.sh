#!/bin/bash
# Detect install environment and dispatch to the correct overlay task script.
# Called by jarvis-install.sh --overlay.
#
# Detection order:
#   1. WSL (check /proc/version + WSL_DISTRO_NAME)
#   2. Native Windows (uname -s check — stub, exits unsupported)
#   3. Linux distro family via /etc/os-release ID/ID_LIKE
#
# Env vars forwarded to chosen task script:
#   JARVIS_MODEL, OVERLAY_MODE (set by caller)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

JARVIS_MODEL="${JARVIS_MODEL:-qwen3:4b}"
OVERLAY_MODE="${OVERLAY_MODE:---overlay}"

# ── WSL detection (must precede generic Linux, since WSL reports as the
#    underlying distro in /etc/os-release) ─────────────────────────────────
_is_wsl=false
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || \
   [ -n "${WSL_DISTRO_NAME:-}" ] || \
   [ -n "${WSL_INTEROP:-}" ]; then
    _is_wsl=true
fi

if $_is_wsl; then
    info "Environment: WSL (${WSL_DISTRO_NAME:-unknown distro})"
    info "Kernel install skipped in WSL — packages only."
    export JARVIS_MODEL OVERLAY_MODE JARVIS_ENV=wsl
    exec bash "${SCRIPT_DIR}/task-overlay-wsl.sh"
fi

# ── Native Windows stub ────────────────────────────────────────────────────
if [[ "$(uname -s 2>/dev/null || true)" == MINGW* ]] || \
   [[ "$(uname -s 2>/dev/null || true)" == MSYS* ]] || \
   [[ "$(uname -s 2>/dev/null || true)" == CYGWIN* ]]; then
    echo ""
    echo "ERROR: Native Windows is not supported by the JARVIS OS overlay installer."
    echo ""
    echo "  Options:"
    echo "    1. Use WSL2 (Windows Subsystem for Linux) — run this script inside WSL."
    echo "    2. Boot the JARVIS OS live ISO in a VM (VirtualBox, VMware, Hyper-V)."
    echo "    3. Dual-boot: install JARVIS OS on a physical partition."
    echo ""
    echo "  WSL2 quickstart:"
    echo "    wsl --install"
    echo "    wsl --set-default-version 2"
    echo "    # Then open WSL and run: bash jarvis-install --overlay"
    echo ""
    exit 1
fi

# ── Linux distro family detection ─────────────────────────────────────────
if [ ! -f /etc/os-release ]; then
    die "Cannot detect OS: /etc/os-release not found. Supported: Arch, Debian/Ubuntu, RHEL/Fedora."
fi

_id=""
_id_like=""
_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
_id_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')

_distro_family=""

# Arch family
case "${_id}" in
    arch|manjaro|endeavouros|garuda|cachyos|artix|parabola|arcolinux|jarvisos)
        _distro_family="arch" ;;
esac
[[ "${_id_like}" == *arch* ]] && _distro_family="arch"

# Debian/Ubuntu family
if [ -z "${_distro_family}" ]; then
    case "${_id}" in
        debian|ubuntu|mint|kali|pop|elementary|zorin|raspbian|linuxmint)
            _distro_family="debian" ;;
    esac
    [[ "${_id_like}" == *debian* ]] && _distro_family="debian"
    [[ "${_id_like}" == *ubuntu* ]] && _distro_family="debian"
fi

# RHEL/Fedora family
if [ -z "${_distro_family}" ]; then
    case "${_id}" in
        rhel|centos|fedora|rocky|almalinux|ol|scientific|amzn)
            _distro_family="rhel" ;;
    esac
    [[ "${_id_like}" == *rhel*   ]] && _distro_family="rhel"
    [[ "${_id_like}" == *fedora* ]] && _distro_family="rhel"
    [[ "${_id_like}" == *centos* ]] && _distro_family="rhel"
fi

if [ -z "${_distro_family}" ]; then
    die "Cannot identify distro family (ID=${_id:-unknown}, ID_LIKE=${_id_like:-unknown}).\nSupported families: arch, debian/ubuntu, rhel/fedora.\nIf your distro is compatible, set JARVIS_DISTRO_FAMILY=arch|debian|rhel and re-run."
fi

info "Environment: Linux / ${_distro_family} family (ID=${_id})"

export JARVIS_MODEL OVERLAY_MODE JARVIS_ENV="linux-${_distro_family}"

case "${_distro_family}" in
    arch)
        exec bash "${SCRIPT_DIR}/task-overlay-arch.sh"
        ;;
    debian)
        exec bash "${SCRIPT_DIR}/task-overlay-debian.sh"
        ;;
    rhel)
        exec bash "${SCRIPT_DIR}/task-overlay-rhel.sh"
        ;;
esac
