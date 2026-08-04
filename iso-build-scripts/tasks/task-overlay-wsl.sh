#!/bin/bash
# Install JARVIS OS components in WSL — no kernel install, packages only.
# Delegates to task-overlay-debian.sh with JARVIS_ENV=wsl.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

JARVIS_MODEL="${JARVIS_MODEL:-qwen3:4b}"
OVERLAY_MODE="${OVERLAY_MODE:---overlay}"

# Detect base distro inside WSL to pick right package manager
_id=$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
_id_like=$(grep -E '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)

export JARVIS_MODEL OVERLAY_MODE JARVIS_ENV=wsl

# Route to correct task based on underlying distro
_family=""
case "${_id}" in
    debian|ubuntu|mint|kali|pop|elementary|raspbian) _family="debian" ;;
    rhel|centos|fedora|rocky|almalinux)              _family="rhel" ;;
    arch|manjaro|cachyos|artix)                      _family="arch" ;;
esac
[[ "${_id_like}" == *debian* || "${_id_like}" == *ubuntu* ]] && _family="debian"
[[ "${_id_like}" == *rhel* || "${_id_like}" == *fedora* ]]   && _family="rhel"
[[ "${_id_like}" == *arch* ]]                                 && _family="arch"

[ -z "${_family}" ] && _family="debian"  # safe default for Ubuntu WSL (most common)

info "WSL base distro: ${_id:-unknown} (family: ${_family})"
info "Kernel install: SKIPPED (WSL)"

exec bash "${SCRIPT_DIR}/task-overlay-${_family}.sh"
