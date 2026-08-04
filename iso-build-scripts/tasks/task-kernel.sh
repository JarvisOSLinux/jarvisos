#!/bin/bash
# Install linux-jarvisos into target chroot if pre-built packages exist.
# Falls back to stock linux kernel (already installed by pacstrap).
#
# Required env vars:
#   MOUNT_ROOT      — e.g. /mnt/jarvis-install
#
# Output:
#   Writes KERNEL_PKG=<value> to JARVIS_STATE_FILE (if set) or stdout.
#   Values: "linux-jarvisos" or "linux"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need_root
require_env MOUNT_ROOT

# Already installed by overlay phase?
if arch-chroot "${MOUNT_ROOT}" pacman -Q linux-jarvisos >/dev/null 2>&1; then
    ok "linux-jarvisos already installed (overlay phase)"
    KERNEL_PKG="linux-jarvisos"
else
    KERNEL_PKG="linux"

    # Search candidate locations for pre-built packages
    _pkg_dir=""
    for _candidate in \
        "/opt/jarvis-kernel-pkg" \
        "${SCRIPT_DIR}/../../build/kernel-pkg" \
        "${SCRIPT_DIR}/../../../build/kernel-pkg"; do
        if [ -d "${_candidate}" ] && \
           find "${_candidate}" -name 'linux-jarvisos-[0-9]*.pkg.tar.zst' \
               ! -name 'linux-jarvisos-headers-*' -quit 2>/dev/null | grep -q .; then
            _pkg_dir="${_candidate}"
            break
        fi
    done

    if [ -n "${_pkg_dir}" ]; then
        _pkg=$(find "${_pkg_dir}" -name 'linux-jarvisos-[0-9]*.pkg.tar.zst' \
                    ! -name 'linux-jarvisos-headers-*' 2>/dev/null \
                    | sort -V | tail -1 || true)
        _hdr=$(find "${_pkg_dir}" -name 'linux-jarvisos-headers-[0-9]*.pkg.tar.zst' \
                    2>/dev/null | sort -V | tail -1 || true)

        if [ -n "${_pkg}" ] && [ -n "${_hdr}" ]; then
            info "Found pre-built linux-jarvisos — installing into target..."
            cp "${_pkg}" "${_hdr}" "${MOUNT_ROOT}/tmp/"
            arch-chroot "${MOUNT_ROOT}" pacman -U --noconfirm \
                "/tmp/$(basename "${_pkg}")" "/tmp/$(basename "${_hdr}")" \
                && { ok "linux-jarvisos installed"; KERNEL_PKG="linux-jarvisos"; } \
                || warn "linux-jarvisos install failed — using stock linux kernel"
            rm -f "${MOUNT_ROOT}/tmp/"linux-jarvisos*.pkg.tar.zst 2>/dev/null || true
        else
            info "Incomplete pre-built packages — using stock linux kernel"
        fi
    else
        info "No pre-built linux-jarvisos found — using stock linux kernel"
    fi
fi

# Output KERNEL_PKG for orchestrator
if [ -n "${JARVIS_STATE_FILE:-}" ]; then
    # Remove any old KERNEL_PKG entry then append
    grep -v '^KERNEL_PKG=' "${JARVIS_STATE_FILE}" > "${JARVIS_STATE_FILE}.tmp" 2>/dev/null || true
    mv "${JARVIS_STATE_FILE}.tmp" "${JARVIS_STATE_FILE}" 2>/dev/null || true
    echo "KERNEL_PKG=${KERNEL_PKG}" >> "${JARVIS_STATE_FILE}"
fi

echo "KERNEL_PKG=${KERNEL_PKG}"
