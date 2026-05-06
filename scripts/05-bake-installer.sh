#!/bin/bash
# Step 5: Bake in TUI Installer
#
# Installs the jarvis-install TUI script and configures the live environment
# to auto-launch it on TTY1 at boot (no SDDM on live).

set -eo pipefail

source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

if [ -z "${SCRIPTS_DIR}" ]; then
    echo "Error: SCRIPTS_DIR not set in build.config" >&2; exit 1
fi
if [ -z "${PROJECT_ROOT}" ]; then
    echo "Error: PROJECT_ROOT not set in build.config" >&2; exit 1
fi

SCRIPTS_DIR="${PROJECT_ROOT}${SCRIPTS_DIR}"
BUILD_DIR="${PROJECT_ROOT}${BUILD_DIR}"
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"
BUILD_DEPS_DIR="${PROJECT_ROOT}${BUILD_DEPS_DIR}"
PACKAGES_DIR="${PROJECT_ROOT}/packages"
INSTALLER_SRC="${PACKAGES_DIR}/jarvis-installer/jarvis-install.sh"
KERNEL_PKG_DIR="${PROJECT_ROOT}/build/kernel-pkg"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validate
if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Rootfs not extracted. Run step 2 first.${NC}" >&2; exit 1
fi
if [ ! -d "${SQUASHFS_ROOTFS}/usr/bin" ] && [ ! -d "${SQUASHFS_ROOTFS}/bin" ]; then
    echo -e "${RED}Error: Rootfs invalid — /usr/bin missing.${NC}" >&2; exit 1
fi
if [ ! -f "${INSTALLER_SRC}" ]; then
    echo -e "${RED}Error: Installer not found: ${INSTALLER_SRC}${NC}" >&2; exit 1
fi

detect_chroot_cmd

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 5: Installing TUI Installer${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Rootfs: ${SQUASHFS_ROOTFS}${NC}"

# ── DNS + bind mount ──────────────────────────────────────────────────────────
echo -e "${BLUE}Copying DNS file...${NC}"
if [ -f /etc/resolv.conf ]; then
    sudo cp /etc/resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
fi

echo -e "${BLUE}Bind mounting rootfs...${NC}"
sudo mount --bind "${SQUASHFS_ROOTFS}" "${SQUASHFS_ROOTFS}" || {
    echo -e "${RED}Error: Failed to bind mount rootfs${NC}" >&2; exit 1
}

cleanup() {
    echo -e "${BLUE}Cleaning up...${NC}"
    for _mp in dev/pts dev/shm dev proc sys run tmp; do
        sudo umount -l "${SQUASHFS_ROOTFS}/${_mp}" 2>/dev/null || true
    done
    sudo umount -l "${SQUASHFS_ROOTFS}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Install TUI installer dependencies ───────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installing TUI installer dependencies...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    dialog \
    parted \
    gptfdisk \
    dosfstools \
    btrfs-progs \
    e2fsprogs \
    arch-install-scripts \
    rsync \
    pv \
    cryptsetup \
    lvm2 \
    || {
    echo -e "${RED}Error: Failed to install installer dependencies${NC}" >&2; exit 1
}
echo -e "${GREEN}✓ Installer dependencies installed${NC}"

# ── Copy installer script ─────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installing jarvis-install script...${NC}"
sudo cp "${INSTALLER_SRC}" "${SQUASHFS_ROOTFS}/usr/local/bin/jarvis-install"
sudo chmod 755 "${SQUASHFS_ROOTFS}/usr/local/bin/jarvis-install"
sudo chown root:root "${SQUASHFS_ROOTFS}/usr/local/bin/jarvis-install"
echo -e "${GREEN}✓ /usr/local/bin/jarvis-install installed${NC}"

# ── TTY1 auto-login as root ───────────────────────────────────────────────────
# On the live ISO, TTY1 auto-logs in as root and launches the TUI installer.
# No SDDM on the live environment — the installer configures and enables
# SDDM on the installed system.
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Configuring TTY1 auto-login (root → installer)...${NC}"

sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/systemd/system/getty@tty1.service.d"
sudo tee "${SQUASHFS_ROOTFS}/etc/systemd/system/getty@tty1.service.d/autologin.conf" > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --noclear %I $TERM
EOF
echo -e "${GREEN}✓ TTY1 auto-login configured${NC}"

# Root .bash_profile: launch installer on TTY1, show welcome on other TTYs
sudo tee "${SQUASHFS_ROOTFS}/root/.bash_profile" > /dev/null << 'PROFILE_EOF'
# JARVIS OS live environment
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [ "$(tty)" = "/dev/tty1" ]; then
    clear
    printf '\033[1;36m'
    cat << 'BANNER'

     ██╗ █████╗ ██████╗ ██╗   ██╗██╗███████╗
     ██║██╔══██╗██╔══██╗██║   ██║██║██╔════╝
     ██║███████║██████╔╝██║   ██║██║███████╗
██   ██║██╔══██║██╔══██╗╚██╗ ██╔╝██║╚════██║
╚█████╔╝██║  ██║██║  ██║ ╚████╔╝ ██║███████║
 ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝

BANNER
    printf '\033[0m'
    printf '  Welcome to JARVIS OS Live\n'
    printf '  Launching installer...\n\n'
    sleep 1
    exec /usr/local/bin/jarvis-install
fi
PROFILE_EOF
sudo chmod 644 "${SQUASHFS_ROOTFS}/root/.bash_profile"
echo -e "${GREEN}✓ Root .bash_profile configured${NC}"

# ── mount-bootmnt helper ──────────────────────────────────────────────────────
# Mounts the live medium so the installer can find airootfs.sfs.
echo -e "${BLUE}Installing mount-bootmnt helper...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/usr/local/bin/mount-bootmnt.sh" > /dev/null << 'EOF'
#!/bin/bash
# Mount the live ISO medium at /run/archiso/bootmnt so the installer can
# access airootfs.sfs.  The archiso initramfs hook normally does this;
# this script is a manual fallback.

BOOTMNT="/run/archiso/bootmnt"

if mountpoint -q "${BOOTMNT}" 2>/dev/null; then
    echo "Boot medium already mounted at ${BOOTMNT}"
    exit 0
fi

mkdir -p "${BOOTMNT}"

# Find ISO9660 or squashfs device
LIVE_DEV=$(blkid -o device -t TYPE="iso9660" 2>/dev/null | head -1 || true)
if [ -z "${LIVE_DEV}" ]; then
    echo "Warning: No ISO9660 device found; trying by label..."
    LIVE_DEV=$(blkid -o device -t LABEL_FATBOOT="JARVISOS*" 2>/dev/null | head -1 || true)
fi

if [ -z "${LIVE_DEV}" ]; then
    echo "Error: Cannot find live medium device" >&2
    exit 1
fi

echo "Mounting ${LIVE_DEV} at ${BOOTMNT}..."
mount -r "${LIVE_DEV}" "${BOOTMNT}"
echo "Mounted. Squashfs: $(find "${BOOTMNT}" -name 'airootfs.sfs' 2>/dev/null | head -1 || echo 'not found')"
EOF
sudo chmod 755 "${SQUASHFS_ROOTFS}/usr/local/bin/mount-bootmnt.sh"
echo -e "${GREEN}✓ mount-bootmnt.sh installed${NC}"

# ── jarvis-setup.service — first-boot Ollama model pull ──────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Creating jarvis-setup.service (first-boot Ollama model pull)...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/usr/lib/systemd/system/jarvis-setup.service" > /dev/null << 'SVCEOF'
[Unit]
Description=JARVIS OS First-Boot Setup (Ollama model pull)
After=network-online.target ollama.service
Wants=network-online.target ollama.service
ConditionPathExists=!/var/lib/jarvis/.setup-done

[Service]
Type=oneshot
User=root
WorkingDirectory=/var/lib/jarvis
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/jarvis-first-boot.sh
ExecStartPost=/bin/touch /var/lib/jarvis/.setup-done
RemainAfterExit=yes
TimeoutStartSec=600
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
echo -e "${GREEN}✓ jarvis-setup.service created${NC}"

# ── Polkit rules for liveuser ─────────────────────────────────────────────────
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/polkit-1/rules.d"
sudo tee "${SQUASHFS_ROOTFS}/etc/polkit-1/rules.d/50-liveuser.rules" > /dev/null << 'EOF'
/* Allow liveuser to manage network and system without prompts on live ISO */
polkit.addRule(function(action, subject) {
    if (subject.user === "liveuser") {
        var allowed = [
            "org.freedesktop.NetworkManager",
            "org.freedesktop.systemd1",
            "org.freedesktop.udisks2",
            "org.freedesktop.login1",
        ];
        for (var i = 0; i < allowed.length; i++) {
            if (action.id.indexOf(allowed[i]) === 0) {
                return polkit.Result.YES;
            }
        }
    }
});
EOF
sudo chmod 644 "${SQUASHFS_ROOTFS}/etc/polkit-1/rules.d/50-liveuser.rules"
echo -e "${GREEN}✓ Polkit rules installed${NC}"

# ── Copy linux-jarvisos packages into live ISO (for installer's ensure_kernel) ─
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
_kpkg=$(find "${KERNEL_PKG_DIR}" -name 'linux-jarvisos-[0-9]*.pkg.tar.zst' \
        ! -name 'linux-jarvisos-headers-*' 2>/dev/null | sort -V | tail -1 || true)
_khdr=$(find "${KERNEL_PKG_DIR}" -name 'linux-jarvisos-headers-[0-9]*.pkg.tar.zst' \
        2>/dev/null | sort -V | tail -1 || true)
if [ -n "${_kpkg}" ] && [ -n "${_khdr}" ]; then
    echo -e "${BLUE}Copying linux-jarvisos packages into live rootfs...${NC}"
    sudo mkdir -p "${SQUASHFS_ROOTFS}/opt/jarvis-kernel-pkg"
    sudo cp "${_kpkg}" "${_khdr}" "${SQUASHFS_ROOTFS}/opt/jarvis-kernel-pkg/"
    echo -e "${GREEN}✓ linux-jarvisos packages staged at /opt/jarvis-kernel-pkg/${NC}"
else
    echo -e "${YELLOW}⚠ No pre-built linux-jarvisos packages found in build/kernel-pkg/ — run make step3b first${NC}"
    echo -e "${YELLOW}  Installer will fall back to stock linux kernel${NC}"
fi

# ── Cleanup package cache ─────────────────────────────────────────────────────
echo -e "${BLUE}Cleaning package cache...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Scc --noconfirm 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" sh -c "rm -rf /tmp/* /var/cache/pacman/pkg/*" 2>/dev/null || true

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 5 complete: TUI installer installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  ✓ Installer:    /usr/local/bin/jarvis-install${NC}"
echo -e "${BLUE}  ✓ Auto-launch:  TTY1 → root auto-login → installer${NC}"
echo -e "${BLUE}  ✓ Boot medium:  /usr/local/bin/mount-bootmnt.sh${NC}"
echo -e "${BLUE}  ✓ First-boot:   jarvis-setup.service (Ollama model pull)${NC}"
echo -e "${BLUE}  ✓ Polkit:       liveuser rules installed${NC}"
