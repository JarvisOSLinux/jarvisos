#!/bin/bash
# JARVIS OS Build Utilities
# Shared helper functions for host-system distro detection and package management.
# Source this file from build scripts: source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

# ============================================================================
# Distro Detection
# ============================================================================

# Returns the lowercase distro ID (e.g. "arch", "fedora", "ubuntu", "opensuse-leap")
detect_host_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        ( . /etc/os-release; echo "${ID}" )
    elif command -v lsb_release >/dev/null 2>&1; then
        lsb_release -si | tr '[:upper:]' '[:lower:]'
    else
        echo "unknown"
    fi
}

# Returns the package manager family: arch | fedora | debian | opensuse | unknown
detect_pkg_family() {
    local distro
    distro=$(detect_host_distro)
    case "${distro}" in
        arch|cachyos|endeavouros|manjaro|garuda|artix|parabola|archarm)
            echo "arch" ;;
        fedora|rhel|centos|rocky|almalinux|ol|amzn)
            echo "fedora" ;;
        ubuntu|debian|linuxmint|pop|elementary|kali|raspbian|neon|zorin|deepin|mx)
            echo "debian" ;;
        opensuse*|sles|suse)
            echo "opensuse" ;;
        *)
            # Fallback: detect by available command
            if command -v pacman >/dev/null 2>&1; then
                echo "arch"
            elif command -v dnf >/dev/null 2>&1; then
                echo "fedora"
            elif command -v apt-get >/dev/null 2>&1; then
                echo "debian"
            elif command -v zypper >/dev/null 2>&1; then
                echo "opensuse"
            else
                echo "unknown"
            fi
            ;;
    esac
}

# ============================================================================
# Package Installation (HOST system only - not inside chroot)
# ============================================================================

# Install one or more packages on the host system.
# Package names can differ per distro - pass the right name for each family.
#
# Usage: install_host_package <pkg_arch> <pkg_fedora> <pkg_debian> [<pkg_opensuse>]
# Example: install_host_package "p7zip" "p7zip p7zip-plugins" "p7zip-full" "p7zip"
install_host_package() {
    local pkg_arch="${1}"
    local pkg_fedora="${2}"
    local pkg_debian="${3}"
    local pkg_opensuse="${4:-${pkg_fedora}}"

    local family
    family=$(detect_pkg_family)

    case "${family}" in
        arch)
            # shellcheck disable=SC2086
            sudo pacman -Sy --needed --noconfirm ${pkg_arch}
            ;;
        fedora)
            # shellcheck disable=SC2086
            sudo dnf install -y ${pkg_fedora}
            ;;
        debian)
            sudo apt-get update -qq
            # shellcheck disable=SC2086
            sudo apt-get install -y ${pkg_debian}
            ;;
        opensuse)
            # shellcheck disable=SC2086
            sudo zypper install -y ${pkg_opensuse}
            ;;
        *)
            echo "Warning: Unknown package manager family. Cannot auto-install package." >&2
            return 1
            ;;
    esac
}

# ============================================================================
# Install Hint (prints the correct install command for the running system)
# ============================================================================

# Returns an install command string appropriate for the host distro.
# Usage: HINT=$(pkg_install_hint "package-name")
# For packages with different names per distro, pass all four variants:
#   HINT=$(pkg_install_hint_multi "arch-pkg" "fedora-pkg" "debian-pkg" "opensuse-pkg")
pkg_install_hint() {
    local pkg="${1}"
    pkg_install_hint_multi "${pkg}" "${pkg}" "${pkg}" "${pkg}"
}

pkg_install_hint_multi() {
    local pkg_arch="${1}"
    local pkg_fedora="${2}"
    local pkg_debian="${3}"
    local pkg_opensuse="${4:-${pkg_fedora}}"

    local family
    family=$(detect_pkg_family)

    case "${family}" in
        arch)    echo "sudo pacman -S ${pkg_arch}" ;;
        fedora)  echo "sudo dnf install ${pkg_fedora}" ;;
        debian)  echo "sudo apt-get install ${pkg_debian}" ;;
        opensuse)echo "sudo zypper install ${pkg_opensuse}" ;;
        *)       echo "your-package-manager install ${pkg_arch}" ;;
    esac
}

# ============================================================================
# Tool Check + Auto-Install Helper
# ============================================================================

# Ensure a host tool is available, optionally installing it automatically.
# Usage: ensure_host_tool <binary> <pkg_arch> <pkg_fedora> <pkg_debian> [<pkg_opensuse>]
# Returns 0 if available (or successfully installed), 1 if not available.
ensure_host_tool() {
    local binary="${1}"
    local pkg_arch="${2}"
    local pkg_fedora="${3}"
    local pkg_debian="${4}"
    local pkg_opensuse="${5:-${pkg_fedora}}"

    if command -v "${binary}" >/dev/null 2>&1; then
        return 0
    fi

    echo "  '${binary}' not found - attempting to install..." >&2
    if install_host_package "${pkg_arch}" "${pkg_fedora}" "${pkg_debian}" "${pkg_opensuse}" 2>/dev/null; then
        if command -v "${binary}" >/dev/null 2>&1; then
            return 0
        fi
    fi

    echo "  Could not install '${binary}' automatically." >&2
    echo "  Install manually: $(pkg_install_hint_multi "${pkg_arch}" "${pkg_fedora}" "${pkg_debian}" "${pkg_opensuse}")" >&2
    return 1
}

# ============================================================================
# require_tool — like ensure_host_tool but exits on failure (fatal check)
# Usage: require_tool <binary> <pkg_arch> <pkg_fedora> <pkg_debian> [<pkg_opensuse>]
# ============================================================================

require_tool() {
    local binary="${1}"
    local pkg_arch="${2}"
    local pkg_fedora="${3}"
    local pkg_debian="${4}"
    local pkg_opensuse="${5:-${pkg_fedora}}"

    if ensure_host_tool "${binary}" "${pkg_arch}" "${pkg_fedora}" "${pkg_debian}" "${pkg_opensuse}"; then
        return 0
    fi
    echo "Error: Required tool '${binary}' unavailable and could not be installed." >&2
    exit 1
}

# Convenience wrapper for tools with identical package name across all distros.
# Usage: require_tool_simple <binary> [<package>]
require_tool_simple() {
    local binary="${1}"
    local pkg="${2:-${1}}"
    require_tool "${binary}" "${pkg}" "${pkg}" "${pkg}" "${pkg}"
}

# ============================================================================
# Chroot Tool Check with Distro-Aware Error Message
# ============================================================================

# Detects and sets CHROOT_CMD to arch-chroot or systemd-nspawn.
# Prints a distro-appropriate install hint if neither is found and exits.
# Usage: detect_chroot_cmd   (sets $CHROOT_CMD in calling script)
detect_chroot_cmd() {
    if command -v arch-chroot >/dev/null 2>&1; then
        CHROOT_CMD="arch-chroot"
        echo -e "\033[0;34mUsing arch-chroot\033[0m"
    elif command -v systemd-nspawn >/dev/null 2>&1; then
        CHROOT_CMD="systemd-nspawn"
        echo -e "\033[1;33mUsing systemd-nspawn (arch-chroot preferred)\033[0m"
        echo -e "\033[1;33mTip: Install arch-install-scripts for better compatibility:\033[0m"
        echo -e "\033[1;33m  $(pkg_install_hint arch-install-scripts)\033[0m"
    else
        echo -e "\033[0;31mError: Neither arch-chroot nor systemd-nspawn found!\033[0m" >&2
        echo -e "\033[1;33mInstall arch-install-scripts:\033[0m" >&2
        echo -e "\033[1;33m  $(pkg_install_hint arch-install-scripts)\033[0m" >&2
        exit 1
    fi
}
