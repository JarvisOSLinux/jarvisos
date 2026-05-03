#!/bin/bash
# Step 3: Arch Linux → JARVIS OS
#
# Installs KDE Plasma Wayland, all hardware drivers, and stamps JARVIS OS
# identity onto the base Arch Linux rootfs.
#
# linux-jarvisos is built and installed by the NEXT step (03b-build-kernel.sh).
# The stock Arch linux kernel is kept as the live boot kernel until 03b runs.

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
KERNEL_BACKUP_DIR="${BUILD_DIR}/kernel-files"
ISO_EXTRACT_DIR="${BUILD_DIR}${ISO_EXTRACT_DIR}"
ISO_BOOT_DIR="${ISO_EXTRACT_DIR}/arch/boot/x86_64"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Rootfs not extracted. Run step 2 first.${NC}" >&2; exit 1
fi
if [ ! -d "${SQUASHFS_ROOTFS}/usr/bin" ] && [ ! -d "${SQUASHFS_ROOTFS}/bin" ]; then
    echo -e "${RED}Error: Rootfs invalid — /usr/bin missing.${NC}" >&2; exit 1
fi

detect_chroot_cmd

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 3: Arch Linux → JARVIS OS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Rootfs: ${SQUASHFS_ROOTFS}${NC}"

# ── DNS ───────────────────────────────────────────────────────────────────────
echo -e "${BLUE}Setting up DNS...${NC}"
if [ -f "${BUILD_DEPS_DIR}/resolv.conf" ]; then
    sudo cp "${BUILD_DEPS_DIR}/resolv.conf" "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
elif [ -f /etc/resolv.conf ]; then
    sudo cp /etc/resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
fi
if [ ! -s "${SQUASHFS_ROOTFS}/etc/resolv.conf" ]; then
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' \
        | sudo tee "${SQUASHFS_ROOTFS}/etc/resolv.conf" > /dev/null
fi

# ── Mirror list: prepend geo-aware CDN mirrors ───────────────────────────────
# The base Arch ISO mirrorlist may have stale or geographically distant servers.
# Prepend Arch's CDN geo-mirror so package downloads are fast regardless of region.
echo -e "${BLUE}Setting fast mirrors in chroot...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/etc/pacman.d/mirrorlist" > /dev/null << 'MIRROREOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
MIRROREOF
echo -e "${GREEN}✓ Mirrors set (Arch CDN + Rackspace + kernel.org)${NC}"

# ── Bind mount + cleanup trap ─────────────────────────────────────────────────
echo -e "${BLUE}Bind mounting rootfs...${NC}"
sudo mount --bind "${SQUASHFS_ROOTFS}" "${SQUASHFS_ROOTFS}" || {
    echo -e "${RED}Error: Failed to bind mount rootfs${NC}" >&2; exit 1
}
cleanup() {
    echo -e "${BLUE}Cleaning up mounts...${NC}"
    for _mp in dev/pts dev/shm dev proc sys run tmp; do
        sudo umount -l "${SQUASHFS_ROOTFS}/${_mp}" 2>/dev/null || true
    done
    sudo umount -l "${SQUASHFS_ROOTFS}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Pacman tuning ─────────────────────────────────────────────────────────────
echo -e "${BLUE}Tuning pacman...${NC}"
sudo sed -i -e 's/^#\?\(ParallelDownloads\).*/ParallelDownloads = 5/' \
    "${SQUASHFS_ROOTFS}/etc/pacman.conf"
sudo grep -q '^DisableDownloadTimeout' "${SQUASHFS_ROOTFS}/etc/pacman.conf" || \
    sudo sed -i '/^ParallelDownloads/a DisableDownloadTimeout' \
        "${SQUASHFS_ROOTFS}/etc/pacman.conf"
echo -e "${GREEN}✓ pacman tuned${NC}"

# ── Keyring ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}Reinitializing pacman keyring...${NC}"
sudo rm -rf "${SQUASHFS_ROOTFS}/etc/pacman.d/gnupg"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --init
echo -e "${BLUE}Populating keyring (archlinux)...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --populate archlinux
echo -e "${GREEN}✓ Keyring initialized${NC}"

# ── Sync DB ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}Syncing package database...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Sy --noconfirm 2>&1 || {
    echo -e "${YELLOW}Warning: pacman -Sy had issues — continuing${NC}"
}

# ── Install archiso + configure mkinitcpio BEFORE linux install ───────────────
# archiso provides the mkinitcpio hooks required for live boot.
# Must be present before linux package triggers mkinitcpio.
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installing archiso (live boot hooks)...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed archiso || {
    echo -e "${YELLOW}Warning: archiso install had issues${NC}"
}

echo -e "${BLUE}Configuring mkinitcpio.conf for live-boot...${NC}"
MKINIT_CONF="${SQUASHFS_ROOTFS}/etc/mkinitcpio.conf"
if [ -f "${MKINIT_CONF}" ]; then
    sudo sed -i \
        's/^MODULES=.*/MODULES=(squashfs overlay loop xhci_hcd xhci_pci ehci_hcd ehci_pci ohci_hcd)/' \
        "${MKINIT_CONF}"
    sudo sed -i \
        's/^HOOKS=.*/HOOKS=(base udev archiso memdisk modconf kms keyboard keymap)/' \
        "${MKINIT_CONF}"
    echo -e "${GREEN}✓ mkinitcpio.conf set (archiso/memdisk HOOKS)${NC}"
else
    sudo tee "${MKINIT_CONF}" > /dev/null << 'MKINITEOF'
MODULES=(squashfs overlay loop xhci_hcd xhci_pci ehci_hcd ehci_pci ohci_hcd)
BINARIES=()
FILES=()
HOOKS=(base udev archiso memdisk modconf kms keyboard keymap)
MKINITEOF
    echo -e "${GREEN}✓ mkinitcpio.conf created${NC}"
fi

# ── Install all packages ──────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installing packages (this will take a while)...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Base utilities
echo -e "${BLUE}Installing base utilities...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    sudo less nano vim wget curl git openssh man-db man-pages \
    unzip zip p7zip rsync tzdata \
    bash-completion which lsof strace htop fastfetch \
    || echo -e "${YELLOW}Warning: Some base packages failed${NC}"

# Kernel
echo -e "${BLUE}Installing kernel...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    linux linux-headers linux-firmware \
    || { echo -e "${RED}Error: Kernel install failed${NC}" >&2; exit 1; }
echo -e "${GREEN}✓ Kernel installed${NC}"

# KDE Plasma Wayland desktop
echo -e "${BLUE}Installing KDE Plasma Wayland...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    plasma-desktop \
    plasma-workspace \
    kwin \
    plasma-nm \
    plasma-pa \
    kscreen \
    powerdevil \
    bluedevil \
    kinfocenter \
    polkit-kde-agent \
    kdeplasma-addons \
    plasma-systemmonitor \
    sddm \
    sddm-kcm \
    breeze \
    breeze-gtk \
    kde-gtk-config \
    oxygen-sounds \
    kwalletmanager \
    kwallet-pam \
    || { echo -e "${RED}Error: KDE Plasma install failed${NC}" >&2; exit 1; }
echo -e "${GREEN}✓ KDE Plasma installed${NC}"

# Qt Wayland
echo -e "${BLUE}Installing Qt Wayland support...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    qt5-wayland qt6-wayland xorg-xwayland \
    || echo -e "${YELLOW}Warning: Some Qt/Wayland packages failed${NC}"

# KDE applications
echo -e "${BLUE}Installing KDE applications...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    dolphin konsole kate ark spectacle gwenview okular kcalc \
    filelight kdeconnect \
    || echo -e "${YELLOW}Warning: Some KDE app packages failed${NC}"

# Audio: PipeWire ecosystem
# jack2 conflicts with pipewire-jack — remove it first if present (comes from base Arch ISO)
echo -e "${BLUE}Removing jack2 if present (conflicts with pipewire-jack)...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Rdd --noconfirm jack2 2>/dev/null || true

echo -e "${BLUE}Installing PipeWire audio...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    pipewire pipewire-alsa pipewire-jack pipewire-pulse wireplumber \
    gst-plugin-pipewire gst-plugins-good gst-plugins-bad gst-plugins-ugly \
    sof-firmware alsa-firmware alsa-utils alsa-plugins \
    rtkit pavucontrol \
    || { echo -e "${RED}Error: Audio packages failed${NC}" >&2; exit 1; }
echo -e "${GREEN}✓ PipeWire installed${NC}"

# Bluetooth
echo -e "${BLUE}Installing Bluetooth...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    bluez bluez-utils \
    || echo -e "${YELLOW}Warning: Bluetooth packages failed${NC}"

# Network
echo -e "${BLUE}Installing network tools...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    networkmanager nm-connection-editor network-manager-applet \
    wpa_supplicant wireless-regdb iw modemmanager \
    dhcpcd \
    || { echo -e "${RED}Error: Network packages failed${NC}" >&2; exit 1; }
echo -e "${GREEN}✓ Network tools installed${NC}"

# Graphics / GPU drivers
echo -e "${BLUE}Installing GPU drivers...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    mesa \
    vulkan-intel vulkan-radeon vulkan-swrast \
    libva-intel-driver intel-media-driver \
    xf86-video-amdgpu \
    || echo -e "${YELLOW}Warning: Some GPU driver packages failed${NC}"

# Input drivers
echo -e "${BLUE}Installing input drivers...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    libinput xf86-input-libinput xf86-input-evdev \
    libevdev \
    || echo -e "${YELLOW}Warning: Some input packages failed${NC}"

# Fonts
echo -e "${BLUE}Installing fonts...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    noto-fonts noto-fonts-emoji ttf-liberation ttf-dejavu \
    noto-fonts-cjk \
    || echo -e "${YELLOW}Warning: Some font packages failed${NC}"

# Filesystem and bootloader tools (needed by TUI installer)
echo -e "${BLUE}Installing filesystem + bootloader tools...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    e2fsprogs btrfs-progs dosfstools exfatprogs ntfs-3g \
    parted gptfdisk \
    grub efibootmgr os-prober \
    || { echo -e "${RED}Error: Filesystem/bootloader packages failed${NC}" >&2; exit 1; }
echo -e "${GREEN}✓ Filesystem + bootloader tools installed${NC}"

# XDG desktop integration
echo -e "${BLUE}Installing XDG support...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    xdg-user-dirs xdg-desktop-portal xdg-desktop-portal-kde \
    || echo -e "${YELLOW}Warning: Some XDG packages failed${NC}"

# Python (for JARVIS, step 4 installs full deps)
echo -e "${BLUE}Installing Python...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    python python-pip python-setuptools python-wheel python-virtualenv \
    gcc make pkg-config \
    || { echo -e "${RED}Error: Python packages failed${NC}" >&2; exit 1; }

# Dialog (for TUI installer)
echo -e "${BLUE}Installing dialog (TUI installer)...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    dialog \
    || { echo -e "${RED}Error: dialog install failed${NC}" >&2; exit 1; }

# Portaudio + ALSA (for JARVIS audio)
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    portaudio python-pyaudio \
    || echo -e "${YELLOW}Warning: portaudio/pyaudio failed${NC}"

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ All packages installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ── JARVIS OS branding ────────────────────────────────────────────────────────
echo -e "${BLUE}Applying JARVIS OS branding...${NC}"

sudo tee "${SQUASHFS_ROOTFS}/etc/os-release" > /dev/null << 'EOF'
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

echo "jarvisos" | sudo tee "${SQUASHFS_ROOTFS}/etc/hostname" > /dev/null

sudo tee "${SQUASHFS_ROOTFS}/etc/hosts" > /dev/null << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   jarvisos.localdomain jarvisos
EOF

echo -e "${GREEN}✓ JARVIS OS branding applied${NC}"

# ── liveuser ──────────────────────────────────────────────────────────────────
# Create liveuser account. No SDDM autologin on live — step 5 sets up
# root TTY1 auto-login for the TUI installer instead.
echo -e "${BLUE}Configuring liveuser...${NC}"

sudo arch-chroot "${SQUASHFS_ROOTFS}" bash << 'LIVEUSER_EOF'
set -e

if ! id liveuser >/dev/null 2>&1; then
    echo "Creating liveuser..."
    for grp in wheel audio video storage optical network power scanner input; do
        getent group "${grp}" >/dev/null 2>&1 || groupadd --system "${grp}" 2>/dev/null || true
    done
    useradd -m -G wheel,audio,video,storage,optical,network,power \
            -s /bin/bash liveuser 2>/dev/null || true
else
    echo "liveuser already exists"
fi

passwd -d liveuser 2>/dev/null || true

getent group wheel >/dev/null 2>&1 || groupadd --system wheel 2>/dev/null || true
usermod -aG wheel liveuser 2>/dev/null || true

if grep -q "^%wheel.*NOPASSWD" /etc/sudoers 2>/dev/null; then
    echo "NOPASSWD sudoers entry already present"
else
    sed -i '/^%wheel.*ALL=(ALL.*) ALL$/d' /etc/sudoers 2>/dev/null || true
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
fi
chmod 440 /etc/sudoers

# SDDM default config (Wayland) — no autologin for live, installer enables it
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/jarvisos.conf << 'SDDMEOF'
[General]
DisplayServer=wayland
Numlock=on

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions
SDDMEOF

mkdir -p /home/liveuser/{Desktop,Downloads,Documents,Pictures,Music,Videos}
chown -R liveuser:liveuser /home/liveuser

echo "liveuser configured"
LIVEUSER_EOF

echo -e "${GREEN}✓ liveuser configured${NC}"

# ── Enable live-boot services ─────────────────────────────────────────────────
echo -e "${BLUE}Enabling services for live environment...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash << 'SVCEOF'
systemctl enable NetworkManager.service      2>/dev/null || true
systemctl enable systemd-resolved.service    2>/dev/null || true
systemctl enable systemd-timesyncd.service   2>/dev/null || true
systemctl enable wpa_supplicant.service      2>/dev/null || true
systemctl enable bluetooth.service           2>/dev/null || true
systemctl enable rtkit-daemon.service        2>/dev/null || true
# sddm NOT enabled for live — TUI installer auto-launches via TTY1 (step 5)
# Disable iwd: we use wpa_supplicant + NetworkManager
systemctl disable iwd.service                2>/dev/null || true
systemctl mask    iwd.service                2>/dev/null || true
# Disable NM-wait-online (causes 90-second boot timeout)
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
SVCEOF
echo -e "${GREEN}✓ Services enabled${NC}"

# ── NetworkManager WiFi backend ───────────────────────────────────────────────
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/NetworkManager/conf.d"
sudo tee "${SQUASHFS_ROOTFS}/etc/NetworkManager/conf.d/wifi-backend.conf" > /dev/null << 'EOF'
[device]
wifi.backend=wpa_supplicant
EOF
sudo tee "${SQUASHFS_ROOTFS}/etc/NetworkManager/conf.d/wifi.conf" > /dev/null << 'EOF'
[connection]
wifi.powersave=2

[connectivity]
uri=http://networkcheck.kde.org/

[main]
dns=systemd-resolved
EOF
echo -e "${GREEN}✓ NetworkManager configured${NC}"

# ── Locale ────────────────────────────────────────────────────────────────────
echo -e "${BLUE}Generating en_US.UTF-8 locale...${NC}"
sudo sed -i 's/^#\(en_US.UTF-8\)/\1/' "${SQUASHFS_ROOTFS}/etc/locale.gen" 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" locale-gen 2>&1 || true
echo -e "${GREEN}✓ Locale generated${NC}"

# ── resolv.conf — runtime symlink ────────────────────────────────────────────
sudo rm -f "${SQUASHFS_ROOTFS}/etc/resolv.conf"
sudo ln -sf /run/systemd/resolve/stub-resolv.conf \
    "${SQUASHFS_ROOTFS}/etc/resolv.conf"
echo -e "${GREEN}✓ resolv.conf → systemd-resolved${NC}"

# ── Clean package cache ───────────────────────────────────────────────────────
echo -e "${BLUE}Cleaning package cache...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Scc --noconfirm 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg/"* 2>/dev/null || true
echo -e "${GREEN}✓ Package cache cleaned${NC}"

# ── Backup Arch linux kernel files for step 07 ───────────────────────────────
# Step 07 copies kernel files from kernel-files/ to the ISO's arch/boot/x86_64/.
# After step 3b, linux-jarvisos kernel replaces these as the primary boot kernel.
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Backing up Arch linux kernel files for ISO rebuild (step 7)...${NC}"
mkdir -p "${KERNEL_BACKUP_DIR}"

find_kernel_file() {
    local name="$1"
    # 1. Rootfs /boot/ — freshly built with our mkinitcpio.conf (preferred)
    local found
    found=$(sudo find "${SQUASHFS_ROOTFS}/boot" -maxdepth 1 -name "${name}" 2>/dev/null | head -1)
    if [ -n "${found}" ]; then echo "${found}"; return 0; fi
    # 2. ISO boot dir — original Arch kernel (fallback)
    if [ -f "${ISO_BOOT_DIR}/${name}" ]; then
        echo "${ISO_BOOT_DIR}/${name}"; return 0
    fi
    return 0
}

VMLINUZ=$(find_kernel_file "vmlinuz-linux")
INITRAMFS=$(find_kernel_file "initramfs-linux.img")
INITRAMFS_FALLBACK=$(find_kernel_file "initramfs-linux-fallback.img")

if [ -z "${VMLINUZ}" ]; then
    echo -e "${RED}FATAL: vmlinuz-linux not found${NC}" >&2
    echo -e "${YELLOW}  Searched:${NC}"
    echo -e "${YELLOW}    ${SQUASHFS_ROOTFS}/boot/${NC}"
    echo -e "${YELLOW}    ${ISO_BOOT_DIR}/${NC}"
    sudo ls -la "${SQUASHFS_ROOTFS}/boot/" 2>/dev/null || true
    ls -la "${ISO_BOOT_DIR}/" 2>/dev/null || echo "  (ISO boot dir missing — did step 1 run?)"
    exit 1
fi

sudo cp "${VMLINUZ}" "${KERNEL_BACKUP_DIR}/vmlinuz-linux"
echo -e "${GREEN}  ✓ vmlinuz-linux backed up${NC}"

if [ -n "${INITRAMFS}" ]; then
    sudo cp "${INITRAMFS}" "${KERNEL_BACKUP_DIR}/initramfs-linux.img"
    echo -e "${GREEN}  ✓ initramfs-linux.img backed up${NC}"
fi
if [ -n "${INITRAMFS_FALLBACK}" ]; then
    sudo cp "${INITRAMFS_FALLBACK}" "${KERNEL_BACKUP_DIR}/initramfs-linux-fallback.img"
    echo -e "${GREEN}  ✓ initramfs-linux-fallback.img backed up${NC}"
fi

sudo chown -R "$(id -u):$(id -g)" "${KERNEL_BACKUP_DIR}" 2>/dev/null || true
sudo chmod 644 "${KERNEL_BACKUP_DIR}"/vmlinuz-linux* \
               "${KERNEL_BACKUP_DIR}"/initramfs-linux* 2>/dev/null || true

echo -e "${GREEN}✓ Arch linux kernel files backed up${NC}"

# ── Done ─────────────────────────────────────────────────────────────────────
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 3 complete: Arch Linux → JARVIS OS done${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installed : KDE Plasma Wayland, PipeWire, NetworkManager, drivers${NC}"
echo -e "${BLUE}Applied   : JARVIS OS branding, hostname=jarvisos, liveuser${NC}"
echo -e "${BLUE}Note      : SDDM NOT enabled on live — TUI installer via TTY1 (step 5)${NC}"
echo -e "${BLUE}Next      : Run step 3b to build + install linux-jarvisos${NC}"
