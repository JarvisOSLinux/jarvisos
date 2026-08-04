#!/bin/bash
# Shared helpers for jarvis-install task scripts.
# Source this at the top of every task script.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

die()  { echo -e "${RED}FATAL: $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}=>${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Require root or die
need_root() {
    [ "$(id -u)" -eq 0 ] || die "Must run as root."
}

# Detect Arch-based distro or die
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
    die "Not an Arch-based system (ID=${id:-unknown}, ID_LIKE=${id_like:-unknown})."
}

# Detect GPU vendor: nvidia | amd | intel-arc | cpu
detect_gpu_vendor() {
    if lspci 2>/dev/null | grep -qi 'nvidia' || lsmod 2>/dev/null | grep -q '^nvidia '; then
        echo "nvidia"; return
    fi
    if lsmod 2>/dev/null | grep -q '^amdgpu ' || \
       lspci 2>/dev/null | grep -qi 'radeon\|amdgpu\|Advanced Micro Devices.*Navi\|Advanced Micro Devices.*Ellesmere\|Advanced Micro Devices.*Polaris'; then
        echo "amd"; return
    fi
    if lspci 2>/dev/null | grep -qi 'Intel.*Arc\|Arc.*Graphics\|Intel.*Alchemist\|Intel.*Battlemage'; then
        echo "intel-arc"; return
    fi
    echo "cpu"
}

# Find JARVIS source: prints path or "installed"
find_jarvis_source() {
    [ -f /usr/lib/jarvis/main.py ] && echo "installed" && return 0
    local _src; _src="${BASH_SOURCE[1]}"
    [ -z "${_src}" ] && _src="${BASH_SOURCE[0]}"
    local script_dir; script_dir="$(cd "$(dirname "${_src}")" && pwd)"
    local try="${script_dir}/../../../Project-JARVIS"
    [ -f "${try}/jarvis/main.py" ] && echo "$(realpath "${try}")" && return 0
    echo ""
    return 1
}

# Required env vars check
require_env() {
    local missing=()
    for v in "$@"; do
        local _val="${!v}"
        [ -n "${_val}" ] || missing+=("${v}")
    done
    [ ${#missing[@]} -eq 0 ] || die "Required env vars not set: ${missing[*]}"
}
