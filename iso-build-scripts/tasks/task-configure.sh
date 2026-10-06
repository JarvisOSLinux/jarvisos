#!/bin/bash
# Configure the installed system inside its chroot:
# locale, timezone, keyboard, hostname, users, services, mkinitcpio.
#
# Required env vars:
#   MOUNT_ROOT    — e.g. /mnt/jarvis-install
#   HOSTNAME_VAL
#   NEW_USER
#   USER_PASS
#   ROOT_PASS
#   BOOT_LOADER   — "grub" or "systemd-boot"
#   FS_TYPE       — "ext4" or "btrfs"
#   TIMEZONE      — e.g. "America/New_York"
#   KEYMAP        — e.g. "us"
#   LOCALE        — e.g. "en_US.UTF-8"
#   KERNEL_PKG    — "linux" or "linux-jarvisos"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need_root
require_env MOUNT_ROOT HOSTNAME_VAL NEW_USER USER_PASS ROOT_PASS \
            BOOT_LOADER FS_TYPE TIMEZONE KEYMAP LOCALE

KERNEL_PKG="${KERNEL_PKG:-linux}"

arch-chroot "${MOUNT_ROOT}" /bin/bash -s \
    "${HOSTNAME_VAL}" "${NEW_USER}" "${USER_PASS}" "${ROOT_PASS}" \
    "${BOOT_LOADER}" "${FS_TYPE}" "${TIMEZONE}" "${KEYMAP}" "${LOCALE}" \
    "${KERNEL_PKG}" <<'CHROOT_EOF'
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
timedatectl set-ntp true 2>/dev/null || true
hwclock --systohc 2>/dev/null || true

# Locale
LOCALE_BASE=$(echo "${LOCALE}" | cut -d' ' -f1)
LOCALE_ESC="${LOCALE_BASE//./\\.}"
sed -i "s/^#\(${LOCALE_ESC}\)/\1/" /etc/locale.gen 2>/dev/null || true
grep -q "^en_US\.UTF-8" /etc/locale.gen 2>/dev/null || \
    sed -i 's/^#\(en_US\.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
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
printf '%s:%s\n' "root" "${ROOT_PASS}" | chpasswd

# User setup
for grp in wheel audio video storage optical network power lp sys scanner input jarvis; do
    getent group "${grp}" >/dev/null 2>&1 || groupadd --system "${grp}" 2>/dev/null || true
done

useradd -m -G wheel,audio,video,storage,optical,network,power,jarvis -s /bin/bash "${NEW_USER}" 2>/dev/null || \
    useradd -m -s /bin/bash "${NEW_USER}"

for grp in wheel audio video storage optical network power lp sys scanner input jarvis; do
    usermod -aG "${grp}" "${NEW_USER}" 2>/dev/null || true
done

printf '%s:%s\n' "${NEW_USER}" "${USER_PASS}" | chpasswd

# sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || \
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/'     /etc/sudoers 2>/dev/null || true
chmod 440 /etc/sudoers

# Remove live autologin and TTY1 override
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

# Fix mkinitcpio.conf for installed system (remove archiso/memdisk live hooks)
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap block filesystems fsck)/' \
    /etc/mkinitcpio.conf

# mkinitcpio
if [ "${KERNEL_PKG}" = "linux-jarvisos" ]; then
    rm -f /boot/vmlinuz-linux /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img
    rm -f /etc/mkinitcpio.d/linux.preset 2>/dev/null || true
    if [ -f /etc/mkinitcpio.d/linux-jarvisos.preset ]; then
        mkinitcpio -p linux-jarvisos || warn "mkinitcpio failed — check manually after install"
    elif [ -f /boot/initramfs-linux-jarvisos.img ]; then
        warn "linux-jarvisos.preset missing — rebuilding initramfs directly"
        _kver=$(ls /usr/lib/modules/ 2>/dev/null | grep -m1 'jarvisos' || true)
        if [ -n "${_kver}" ]; then
            mkinitcpio -k "${_kver}" -g /boot/initramfs-linux-jarvisos.img \
                || warn "mkinitcpio failed — check /boot/ manually after install"
        else
            warn "Cannot find linux-jarvisos modules — installed system may not boot"
        fi
    else
        warn "No linux-jarvisos kernel or preset found — bootloader will not work"
    fi
else
    if [ -f /etc/mkinitcpio.d/linux.preset ]; then
        mkinitcpio -p linux || warn "mkinitcpio failed"
    fi
fi

# Auto-load jarvis.ko at boot
_jkver=$(ls /usr/lib/modules/ 2>/dev/null | grep -m1 'jarvisos' || true)
[ -n "${_jkver}" ] && depmod -a "${_jkver}" 2>/dev/null || true
mkdir -p /usr/lib/modules-load.d
printf 'jarvis\n' > /usr/lib/modules-load.d/jarvis.conf

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

# JARVIS welcome autostart for new user
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
