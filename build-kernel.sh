#!/usr/bin/env bash
# build-kernel.sh — Build (and optionally install) linux-jarvisos on any Arch Linux system
#
# Usage:
#   ./build-kernel.sh                        # Build packages only → ./kernel-pkg/
#   ./build-kernel.sh --install              # Build + install on this host via pacman
#   ./build-kernel.sh --install --force      # Force rebuild even if packages exist
#   SKIP_BUILD=1 ./build-kernel.sh --install # Reuse existing packages, just install
#
# Prerequisites:
#   sudo pacman -S base-devel bc flex bison pahole libelf
#   git submodule update --init linux-jarvisos
#
# Optional: install ccache for much faster incremental rebuilds (~3-5× speedup).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SRC="${REPO_ROOT}/linux-jarvisos"
PKGBUILD_DIR="${REPO_ROOT}/packages/linux-jarvisos"
PKG_DEST="${REPO_ROOT}/kernel-pkg"
LOCALVERSION="-jarvisos"

# Always use x86_64_defconfig as the base config instead of /proc/config.gz.
# The host kernel (e.g. CachyOS 7.1-rc) has newer APIs that are incompatible
# with the linux-jarvisos 7.0.x source tree. The PKGBUILD re-enables all
# required features (BTRFS, AMDGPU, Nouveau, USB, WiFi, etc.) on top of
# defconfig, so the resulting kernel is fully functional.
export JARVIS_CI_BUILD=1

# ── ANSI colours ──────────────────────────────────────────────────────────────
BLU='\033[0;34m'; GRN='\033[0;32m'; YEL='\033[1;33m'
RED='\033[0;31m'; PRP='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

hdr()  { echo -e "\n${BOLD}${BLU}━━━ $* ━━━${NC}"; }
ok()   { echo -e "${GRN}✓${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC}  $*"; }
die()  { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLU}  →${NC} $*"; }

# ── Parse flags ───────────────────────────────────────────────────────────────
DO_INSTALL=0
FORCE_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --install|-i) DO_INSTALL=1 ;;
        --force|-f)   FORCE_FLAG="--force" ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown argument: $arg  (use --help)" ;;
    esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${PRP}"
cat <<'BANNER'
     ██╗ █████╗ ██████╗ ██╗   ██╗██╗███████╗     ██╗  ██╗███████╗██████╗ ███╗   ██╗███████╗██╗
     ██║██╔══██╗██╔══██╗██║   ██║██║██╔════╝     ██║ ██╔╝██╔════╝██╔══██╗████╗  ██║██╔════╝██║
     ██║███████║██████╔╝██║   ██║██║███████╗     █████╔╝ █████╗  ██████╔╝██╔██╗ ██║█████╗  ██║
██   ██║██╔══██║██╔══██╗╚██╗ ██╔╝██║╚════██║     ██╔═██╗ ██╔══╝  ██╔══██╗██║╚██╗██║██╔══╝  ██║
╚█████╔╝██║  ██║██║  ██║ ╚████╔╝ ██║███████║     ██║  ██╗███████╗██║  ██║██║ ╚████║███████╗███████╗
 ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝
BANNER
echo -e "${NC}"

echo -e "  ${BOLD}Kernel source${NC} : ${KERNEL_SRC}"
echo -e "  ${BOLD}PKGBUILD     ${NC} : ${PKGBUILD_DIR}"
echo -e "  ${BOLD}Package dest ${NC} : ${PKG_DEST}"
echo -e "  ${BOLD}Install mode ${NC} : $([ "$DO_INSTALL" -eq 1 ] && echo 'host install (pacman -U)' || echo 'build only')"
[[ -n "$FORCE_FLAG" ]] && echo -e "  ${BOLD}Rebuild      ${NC} : forced"
echo ""

# ── Sanity checks ─────────────────────────────────────────────────────────────
hdr "Prerequisites"

[[ -f "${KERNEL_SRC}/Makefile" ]] \
    || die "linux-jarvisos/ submodule not populated at ${KERNEL_SRC}\n       Run: git submodule update --init linux-jarvisos"

[[ -f "${PKGBUILD_DIR}/PKGBUILD" ]] \
    || die "PKGBUILD not found at ${PKGBUILD_DIR}/PKGBUILD"

command -v makepkg &>/dev/null \
    || die "makepkg not found — install base-devel:\n       sudo pacman -S base-devel"

# Check build tool dependencies
MISSING_TOOLS=()
for tool in make gcc bc flex bison pahole perl; do
    command -v "$tool" &>/dev/null || MISSING_TOOLS+=("$tool")
done

# openssl headers (module signing / cert generation)
if ! pkg-config --exists openssl 2>/dev/null && [[ ! -f /usr/include/openssl/ssl.h ]]; then
    MISSING_TOOLS+=("openssl")
fi

# libelf headers (BTF/BPF support)
if ! pkg-config --exists libelf 2>/dev/null \
   && [[ ! -f /usr/include/libelf.h ]] \
   && [[ ! -f /usr/include/gelf.h ]]; then
    MISSING_TOOLS+=("libelf (elfutils)")
fi

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    die "Missing build tools: ${MISSING_TOOLS[*]}\n\
       Install: sudo pacman -S base-devel bc flex bison pahole libelf openssl"
fi

NCPU=$(nproc)
ok "Build tools present (${NCPU} CPU threads)"

# ccache — optional but highly recommended for incremental builds
if command -v ccache &>/dev/null; then
    export CC="ccache gcc"
    export HOSTCC="ccache gcc"
    ok "ccache enabled"
else
    warn "ccache not installed — first build will be slow (20–60 min)"
    warn "Speed it up: sudo pacman -S ccache"
fi

# ── Check for existing packages ───────────────────────────────────────────────
mkdir -p "${PKG_DEST}"
EXISTING_PKG_LINUX=$(ls -t "${PKG_DEST}"/linux-jarvisos-[0-9]*.pkg.tar.zst 2>/dev/null | head -1 || true)
EXISTING_PKG_HEADERS=$(ls -t "${PKG_DEST}"/linux-jarvisos-headers-*.pkg.tar.zst 2>/dev/null | head -1 || true)

# ── Kernel .config guard ──────────────────────────────────────────────────────
# A stale .config without CONFIG_JARVIS will silently drop jarvis.ko from the build.
# Remove it so the PKGBUILD's prepare() starts clean from /proc/config.gz.
cd "${KERNEL_SRC}"
if [[ -f .config ]]; then
    if grep -q "^CONFIG_JARVIS=" .config 2>/dev/null; then
        ok ".config already has CONFIG_JARVIS — keeping it"
    else
        warn "Stale .config missing CONFIG_JARVIS — removing so PKGBUILD rebuilds from /proc/config.gz"
        rm -f .config
    fi
else
    info "No existing .config — PKGBUILD will derive one from /proc/config.gz"
fi

# ── Build ─────────────────────────────────────────────────────────────────────
hdr "Build"

KERNELRELEASE=$(make -s kernelrelease LOCALVERSION="${LOCALVERSION}" 2>/dev/null || echo "unknown")
info "Kernel release: ${KERNELRELEASE}"

if [[ "${SKIP_BUILD:-0}" == "1" ]] \
   && [[ -n "${EXISTING_PKG_LINUX}" ]] \
   && [[ -n "${EXISTING_PKG_HEADERS}" ]]; then
    warn "SKIP_BUILD=1 — reusing pre-built packages:"
    info "  $(basename "${EXISTING_PKG_LINUX}")"
    info "  $(basename "${EXISTING_PKG_HEADERS}")"
else
    echo ""
    warn "Initial kernel compilation takes 20–60 min (faster with ccache on subsequent builds)"
    echo ""

    export KERNEL_SRC
    export MAKEFLAGS="-j${NCPU}"

    cd "${PKGBUILD_DIR}"
    PKGDEST="${PKG_DEST}" makepkg --nodeps --nocheck --skipinteg ${FORCE_FLAG}

    echo ""
    ok "Packages built"
fi

# Locate built packages
PKG_LINUX=$(ls -t "${PKG_DEST}"/linux-jarvisos-[0-9]*.pkg.tar.zst 2>/dev/null | head -1 || true)
PKG_HEADERS=$(ls -t "${PKG_DEST}"/linux-jarvisos-headers-*.pkg.tar.zst 2>/dev/null | head -1 || true)

[[ -n "${PKG_LINUX}" && -n "${PKG_HEADERS}" ]] \
    || die "Expected packages not found in ${PKG_DEST}\n$(ls -la "${PKG_DEST}/" 2>/dev/null || true)"

info "linux-jarvisos         : $(basename "${PKG_LINUX}")"
info "linux-jarvisos-headers : $(basename "${PKG_HEADERS}")"

# ── Install (optional) ────────────────────────────────────────────────────────
if [[ "${DO_INSTALL}" -eq 1 ]]; then
    hdr "Install"
    echo ""
    info "Running: sudo pacman -U linux-jarvisos + linux-jarvisos-headers"
    echo ""

    # pacman -U runs the .install hooks: depmod -a + mkinitcpio -p linux-jarvisos
    sudo pacman -U --noconfirm "${PKG_LINUX}" "${PKG_HEADERS}"

    VMLINUZ_SIZE=$(du -h /boot/vmlinuz-linux-jarvisos 2>/dev/null | cut -f1 || echo "?")
    INITRD_SIZE=$(du -h /boot/initramfs-linux-jarvisos.img 2>/dev/null | cut -f1 || echo "?")

    echo ""
    ok "linux-jarvisos installed"
    ok "linux-jarvisos-headers installed"
    info "vmlinuz-linux-jarvisos         : ${VMLINUZ_SIZE}"
    info "initramfs-linux-jarvisos.img   : ${INITRD_SIZE}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
hdr "Done"
echo ""
echo -e "  ${BOLD}Kernel release  ${NC}: ${KERNELRELEASE}"
echo -e "  ${BOLD}Packages        ${NC}: ${PKG_DEST}/"
echo ""

if [[ "${DO_INSTALL}" -eq 1 ]]; then
    ok "linux-jarvisos is ready to boot"
    echo ""
    echo -e "  ${BOLD}Bootloader setup:${NC}"
    echo ""
    echo -e "  ${BOLD}systemd-boot${NC} — add an entry to /boot/loader/entries/linux-jarvisos.conf :"
    cat <<ENTRY
    title   JarvisOS (linux-jarvisos)
    linux   /vmlinuz-linux-jarvisos
    initrd  /amd-ucode.img
    initrd  /initramfs-linux-jarvisos.img
    options root=PARTUUID=<your-root-partuuid> rw quiet splash
ENTRY
    echo ""
    echo -e "  ${BOLD}GRUB${NC} — run: sudo grub-mkconfig -o /boot/grub/grub.cfg"
    echo ""
    echo -e "  ${BOLD}JARVIS kernel drivers included:${NC}"
    echo "    jarvis.ko       — /dev/jarvis AI query/response channel"
    echo "    jarvis_sysmon   — CPU/memory/thermal metrics for model selection"
    echo "    jarvis_policy   — AI action security policy (SAFE/ELEVATED/DANGEROUS)"
    echo "    jarvis_keys     — Kernel keyring for API-key secure storage"
    echo ""
    echo -e "  Reboot and select ${BOLD}linux-jarvisos${NC} from your bootloader."
else
    echo -e "  ${BOLD}To install on this system:${NC}"
    echo ""
    echo "    sudo pacman -U ${PKG_DEST}/linux-jarvisos-*.pkg.tar.zst \\"
    echo "                   ${PKG_DEST}/linux-jarvisos-headers-*.pkg.tar.zst"
    echo ""
    echo -e "  Or re-run with: ${BOLD}./build-kernel.sh --install${NC}"
fi
echo ""
