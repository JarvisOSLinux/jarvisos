#!/bin/bash
# Install JARVIS OS components on an existing Arch-based system.
# Extracted from install_packages_mode() in jarvis-install.sh.
#
# Required env vars:
#   JARVIS_MODEL  — e.g. "qwen3:4b" or "none"
#   OVERLAY_MODE  — "--overlay" or "--install-packages"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need_root
detect_arch_based

JARVIS_MODEL="${JARVIS_MODEL:-qwen3:4b}"
OVERLAY_MODE="${OVERLAY_MODE:---overlay}"

trap 'echo "JARVIS overlay failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# ── Ensure host build tools ────────────────────────────────────────────────
echo "Syncing package database and installing required host tools..."
pacman -Sy --noconfirm --quiet 2>&1 | tail -1 || true
pacman -S --noconfirm --needed \
    dialog base-devel bc flex bison openssl libelf pahole \
    || echo "Warning: some host tool packages failed to install — continuing"

# ── Sync DB ───────────────────────────────────────────────────────────────
info "Syncing package database..."
pacman -Sy --noconfirm 2>&1 || warn "pacman -Sy had issues — continuing"
ok "Package database synced"

# ── Base utilities ────────────────────────────────────────────────────────
info "Installing base utilities..."
pacman -S --noconfirm --needed \
    sudo less nano vim wget curl git openssh man-db man-pages \
    unzip zip p7zip rsync tzdata bash-completion which lsof htop fastfetch \
    || warn "Some base packages failed"
ok "Base utilities installed"

# ── Kernel packages ───────────────────────────────────────────────────────
info "Installing kernel packages..."
pacman -S --noconfirm --needed linux linux-headers linux-firmware \
    || warn "Kernel packages had issues"
ok "Kernel packages installed"

# ── linux-jarvisos custom kernel ──────────────────────────────────────────
info "Installing linux-jarvisos custom kernel..."
_install_linux_jarvisos() {
    if pacman -Q linux-jarvisos >/dev/null 2>&1; then
        ok "linux-jarvisos already installed ($(pacman -Q linux-jarvisos | awk '{print $2}'))"
        return 0
    fi

    local _script_dir; _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _project_root; _project_root="$(cd "${_script_dir}/../.." && pwd)"
    local _kernel_src="${_project_root}/linux-jarvisos"
    local _pkgbuild_dir="${_project_root}/packages/linux-jarvisos"
    local _pkg_dest="${_project_root}/build/kernel-pkg"

    _kjf_find_dir() {
        local _d
        for _d in "/opt/jarvis-kernel-pkg" "${_pkg_dest}" \
                  "${_project_root}/build/kernel-pkg"; do
            if [ -d "${_d}" ] && \
               find "${_d}" -name 'linux-jarvisos-[0-9]*.pkg.tar.zst' \
                   ! -name 'linux-jarvisos-headers-*' -quit 2>/dev/null | grep -q .; then
                echo "${_d}"; return 0
            fi
        done
        return 1
    }

    _kjf_install_from_dir() {
        local _d="$1" _pkg _hdr
        _pkg=$(find "${_d}" -name 'linux-jarvisos-[0-9]*.pkg.tar.zst' \
                    ! -name 'linux-jarvisos-headers-*' 2>/dev/null | sort -V | tail -1)
        _hdr=$(find "${_d}" -name 'linux-jarvisos-headers-[0-9]*.pkg.tar.zst' \
                    2>/dev/null | sort -V | tail -1)
        [ -n "${_pkg}" ] && [ -n "${_hdr}" ] || return 1
        info "Installing: $(basename "${_pkg}")"
        pacman -U --noconfirm "${_pkg}" "${_hdr}" \
            && ok "linux-jarvisos installed from pre-built packages" && return 0
        warn "Pre-built package install failed"
        return 1
    }

    local _found_dir
    if _found_dir=$(_kjf_find_dir); then
        _kjf_install_from_dir "${_found_dir}" && return 0
    fi

    if [[ "${SKIP_BUILD_KERNEL:-0}" == "1" ]]; then
        warn "SKIP_BUILD_KERNEL=1 set and no pre-built packages found — skipping kernel build"
        warn "linux-jarvisos not installed. JARVIS kernel features unavailable."
        return 0
    fi

    if [ ! -f "${_kernel_src}/Makefile" ]; then
        warn "linux-jarvisos submodule not initialized — ${_kernel_src}/Makefile missing"
        warn "Run: git submodule update --init linux-jarvisos"
        warn "linux-jarvisos not installed."
        return 0
    fi
    if [ ! -f "${_pkgbuild_dir}/PKGBUILD" ]; then
        warn "PKGBUILD missing at ${_pkgbuild_dir}/PKGBUILD"
        return 0
    fi
    if ! command -v makepkg >/dev/null 2>&1; then
        warn "makepkg not found — cannot build linux-jarvisos"
        return 0
    fi

    local _missing=()
    for _tool in make gcc bc flex bison perl; do
        command -v "${_tool}" >/dev/null 2>&1 || _missing+=("${_tool}")
    done
    if ! pkg-config --exists openssl 2>/dev/null \
       && [ ! -f /usr/include/openssl/ssl.h ]; then
        _missing+=("openssl")
    fi
    if ! pkg-config --exists libelf 2>/dev/null \
       && [ ! -f /usr/include/libelf.h ] \
       && [ ! -f /usr/include/gelf.h ]; then
        _missing+=("libelf")
    fi
    if [ ${#_missing[@]} -gt 0 ]; then
        warn "Missing kernel build tools: ${_missing[*]}"
        warn "Install: sudo pacman -S base-devel bc flex bison openssl libelf pahole"
        return 0
    fi

    info "Building linux-jarvisos from source (20-60 min first run)..."

    if [ -f "${_kernel_src}/.config" ] && \
       ! grep -q "^CONFIG_JARVIS=" "${_kernel_src}/.config" 2>/dev/null; then
        warn "Stale .config missing CONFIG_JARVIS — removing for clean rebuild"
        rm -f "${_kernel_src}/.config"
    fi

    local _build_user="${SUDO_USER:-$(logname 2>/dev/null || true)}"
    local _makepkg_prefix=""
    if [ "$(id -u)" -eq 0 ]; then
        if [ -z "${_build_user}" ] || [ "${_build_user}" = "root" ]; then
            warn "Running as root with no SUDO_USER — cannot invoke makepkg"
            return 0
        fi
        mkdir -p "${_pkg_dest}"
        chown "${_build_user}" "${_pkg_dest}"
        chown -R "${_build_user}" "${_pkgbuild_dir}"
        chown -R "${_build_user}" "${_kernel_src}"
        _makepkg_prefix="sudo -u ${_build_user}"
    fi

    mkdir -p "${_pkg_dest}"
    local _ncpu; _ncpu=$(nproc)
    (
        cd "${_pkgbuild_dir}"
        ${_makepkg_prefix} env \
            KERNEL_SRC="${_kernel_src}" \
            PKGDEST="${_pkg_dest}" \
            MAKEFLAGS="-j${_ncpu}" \
            makepkg --nodeps --nocheck --skipinteg --force
    ) || { warn "linux-jarvisos build failed — JARVIS kernel features unavailable"; return 0; }
    ok "linux-jarvisos packages built"

    if _found_dir=$(_kjf_find_dir); then
        _kjf_install_from_dir "${_found_dir}" && return 0
    fi
    warn "Build succeeded but packages not found in ${_pkg_dest}"
    return 0
}
_install_linux_jarvisos

if pacman -Q linux-jarvisos >/dev/null 2>&1; then
    local _jkver; _jkver=$(ls /usr/lib/modules/ 2>/dev/null | grep -m1 'jarvisos' || true)
    [ -n "${_jkver}" ] && depmod -a "${_jkver}" 2>/dev/null \
        && ok "jarvis module dependency map regenerated (${_jkver})" \
        || warn "depmod failed for linux-jarvisos"
    mkdir -p /usr/lib/modules-load.d
    printf 'jarvis\n' > /usr/lib/modules-load.d/jarvis.conf
fi

if pacman -Q linux-jarvisos >/dev/null 2>&1; then
    if [ -f /boot/vmlinuz-linux-jarvisos ]; then
        if [ -d /sys/firmware/efi/efivars ] && [ -d /boot/loader/entries ]; then
            local _entry="/boot/loader/entries/jarvisos.conf"
            if [ ! -f "${_entry}" ]; then
                local _root_partuuid; _root_partuuid=$(blkid -s PARTUUID -o value "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
                if [ -n "${_root_partuuid}" ]; then
                    cat > "${_entry}" << BOOTEOF
title   JARVIS OS (linux-jarvisos)
linux   /vmlinuz-linux-jarvisos
initrd  /initramfs-linux-jarvisos.img
options root=PARTUUID=${_root_partuuid} rw
BOOTEOF
                    ok "systemd-boot entry added for linux-jarvisos"
                fi
            fi
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null \
                && ok "GRUB updated to include linux-jarvisos entry" \
                || warn "grub-mkconfig failed"
        fi
        if [ -f /etc/mkinitcpio.d/linux-jarvisos.preset ]; then
            mkinitcpio -p linux-jarvisos \
                && ok "linux-jarvisos initramfs regenerated" \
                || warn "mkinitcpio failed for linux-jarvisos"
        fi
    fi
fi

# ── KDE Plasma Wayland ────────────────────────────────────────────────────
info "Installing KDE Plasma Wayland..."
pacman -S --noconfirm --needed \
    plasma-desktop plasma-workspace \
    kwin plasma-nm plasma-pa kscreen powerdevil bluedevil \
    kinfocenter polkit-kde-agent kdeplasma-addons plasma-systemmonitor \
    sddm sddm-kcm breeze breeze-gtk kde-gtk-config oxygen-sounds \
    kwalletmanager kwallet-pam \
    qt5-wayland qt6-wayland xorg-xwayland \
    dolphin konsole kate ark spectacle gwenview okular kcalc \
    filelight kdeconnect \
    xdg-user-dirs xdg-desktop-portal xdg-desktop-portal-kde \
    || warn "Some KDE packages failed"
ok "KDE Plasma installed"

# ── PipeWire ──────────────────────────────────────────────────────────────
info "Installing PipeWire audio..."
pacman -S --noconfirm --needed \
    pipewire pipewire-alsa pipewire-jack pipewire-pulse wireplumber \
    gst-plugin-pipewire gst-plugins-good gst-plugins-bad gst-plugins-ugly \
    sof-firmware alsa-firmware alsa-utils alsa-plugins \
    rtkit pavucontrol \
    || warn "Some audio packages failed"
ok "PipeWire installed"

# ── Bluetooth ─────────────────────────────────────────────────────────────
info "Installing Bluetooth..."
pacman -S --noconfirm --needed bluez bluez-utils \
    || warn "Bluetooth packages failed"

# ── Network ───────────────────────────────────────────────────────────────
info "Installing network tools..."
pacman -S --noconfirm --needed \
    networkmanager nm-connection-editor network-manager-applet \
    wpa_supplicant wireless-regdb iw modemmanager dhcpcd \
    || warn "Some network packages failed"
ok "Network tools installed"

# ── GPU drivers ───────────────────────────────────────────────────────────
info "Installing GPU drivers..."
pacman -S --noconfirm --needed \
    mesa vulkan-intel vulkan-radeon vulkan-swrast \
    libva-intel-driver intel-media-driver xf86-video-amdgpu \
    || warn "Some GPU packages failed"
ok "GPU drivers installed"

# ── Input + fonts + filesystem tools ─────────────────────────────────────
info "Installing input drivers, fonts, filesystem tools..."
pacman -S --noconfirm --needed \
    libinput xf86-input-libinput xf86-input-evdev libevdev \
    noto-fonts noto-fonts-emoji ttf-liberation ttf-dejavu noto-fonts-cjk \
    e2fsprogs btrfs-progs dosfstools exfatprogs ntfs-3g \
    parted gptfdisk grub efibootmgr arch-install-scripts \
    || warn "Some packages failed"
ok "Drivers, fonts, filesystem tools installed"

# ── Python + JARVIS system deps ───────────────────────────────────────────
info "Installing Python + JARVIS system dependencies..."
pacman -S --noconfirm --needed \
    python python-pip python-setuptools python-wheel python-virtualenv \
    gcc make pkg-config dialog portaudio python-pyaudio \
    || warn "Some Python packages failed"
ok "Python dependencies installed"

# ── JARVIS OS branding ────────────────────────────────────────────────────
info "Applying JARVIS OS branding..."
cat > /etc/os-release << 'EOF'
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
ok "JARVIS OS branding applied"

# ── Ollama (GPU-aware install) ────────────────────────────────────────────
info "Installing Ollama..."
_install_ollama_gpu() {
    local gpu; gpu=$(detect_gpu_vendor)
    info "GPU detected: ${gpu} — selecting Ollama variant"
    case "${gpu}" in
        nvidia)
            info "Installing ollama-cuda + NVIDIA drivers + CUDA..."
            pacman -S --noconfirm --needed \
                ollama-cuda nvidia-dkms nvidia-utils dkms cuda \
                || warn "Some NVIDIA/CUDA packages failed"
            ok "Ollama installed with NVIDIA CUDA support"
            ;;
        amd)
            info "Installing ollama-rocm + ROCm runtime..."
            pacman -S --noconfirm --needed \
                ollama-rocm rocm-hip-runtime rocm-opencl-runtime rocm-device-libs \
                || warn "Some ROCm packages failed"
            getent group render >/dev/null 2>&1 && usermod -aG render ollama 2>/dev/null || true
            usermod -aG video ollama 2>/dev/null || true
            ok "Ollama installed with AMD ROCm support"
            ;;
        intel-arc)
            info "Installing ollama-vulkan + Intel Arc compute runtime..."
            pacman -S --noconfirm --needed \
                ollama-vulkan vulkan-intel intel-compute-runtime \
                level-zero-loader intel-media-driver \
                || warn "Some Intel Arc packages failed"
            ok "Ollama installed with Intel Arc Vulkan support"
            ;;
        cpu|*)
            info "No dedicated GPU — installing ollama (CPU mode)..."
            pacman -S --noconfirm --needed ollama || warn "ollama install failed"
            ok "Ollama installed (CPU mode)"
            ;;
    esac
}

if command -v ollama >/dev/null 2>&1; then
    ok "Ollama already installed ($(ollama --version 2>/dev/null || echo unknown))"
else
    _install_ollama_gpu
fi

if [ ! -f /usr/lib/systemd/system/ollama.service ]; then
    local _ollama_bin; _ollama_bin=$(command -v ollama 2>/dev/null || echo "/usr/bin/ollama")
    cat > /usr/lib/systemd/system/ollama.service << OLLAMAEOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=${_ollama_bin} serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="HOME=/usr/share/ollama"
Environment="OLLAMA_HOST=127.0.0.1"

[Install]
WantedBy=default.target
OLLAMAEOF
fi
getent group  ollama >/dev/null 2>&1 || groupadd -r ollama
getent passwd ollama >/dev/null 2>&1 || \
    useradd -r -g ollama -d /usr/share/ollama -s /bin/false -c 'Ollama Service' ollama
mkdir -p /usr/share/ollama && chown -R ollama:ollama /usr/share/ollama

# ── JARVIS user + directories ─────────────────────────────────────────────
info "Setting up JARVIS user and directories..."
getent group  jarvis >/dev/null 2>&1 || groupadd -r jarvis
getent passwd jarvis >/dev/null 2>&1 || \
    useradd -r -g jarvis -d /var/lib/jarvis -s /sbin/nologin \
            -c 'JARVIS AI Assistant' jarvis
for grp in audio video network systemd-journal storage optical; do
    getent group "${grp}" >/dev/null 2>&1 && \
        usermod -aG "${grp}" jarvis 2>/dev/null || true
done
mkdir -p /usr/lib/jarvis \
         /var/lib/jarvis/models/piper \
         /var/lib/jarvis/models/vosk \
         /var/log/jarvis
mkdir -p /etc/jarvis
chown jarvis:jarvis /etc/jarvis
chmod 2775 /etc/jarvis
chown -R jarvis:jarvis /var/lib/jarvis /var/log/jarvis

mkdir -p /usr/lib/udev/rules.d
cat > /usr/lib/udev/rules.d/99-jarvis.rules << 'UDEVRULES'
KERNEL=="jarvis", GROUP="jarvis", MODE="0660"
UDEVRULES
chmod 644 /usr/lib/udev/rules.d/99-jarvis.rules
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --name-match=jarvis 2>/dev/null || true
ok "JARVIS user and directories configured"

# ── JARVIS code ───────────────────────────────────────────────────────────
info "Installing JARVIS code..."
_jarvis_src=$(find_jarvis_source) || true

if [ "${_jarvis_src}" = "installed" ]; then
    ok "JARVIS code already at /usr/lib/jarvis"
elif [ -n "${_jarvis_src}" ]; then
    cp -r "${_jarvis_src}/jarvis/"* /usr/lib/jarvis/
    [ -f "${_jarvis_src}/jarvis/.env.example" ] && \
        cp "${_jarvis_src}/jarvis/.env.example" /usr/lib/jarvis/.env.example
    [ -f "${_jarvis_src}/requirements.txt" ] && \
        cp "${_jarvis_src}/requirements.txt" /usr/lib/jarvis/requirements.txt
    chown -R jarvis:jarvis /usr/lib/jarvis
    ok "JARVIS code installed from ${_jarvis_src}"
else
    warn "JARVIS source not found locally — cloning from GitHub..."
    if git clone --depth=1 \
            https://github.com/YakupAtahanov/Project-JARVIS \
            /tmp/Project-JARVIS-pkginstall 2>&1; then
        cp -r /tmp/Project-JARVIS-pkginstall/jarvis/* /usr/lib/jarvis/
        [ -f /tmp/Project-JARVIS-pkginstall/jarvis/.env.example ] && \
            cp /tmp/Project-JARVIS-pkginstall/jarvis/.env.example /usr/lib/jarvis/.env.example
        [ -f /tmp/Project-JARVIS-pkginstall/requirements.txt ] && \
            cp /tmp/Project-JARVIS-pkginstall/requirements.txt /usr/lib/jarvis/requirements.txt
        chown -R jarvis:jarvis /usr/lib/jarvis
        rm -rf /tmp/Project-JARVIS-pkginstall
        ok "JARVIS code cloned and installed"
    else
        warn "Could not clone Project-JARVIS — install JARVIS code manually:"
        warn "  git clone https://github.com/YakupAtahanov/Project-JARVIS /tmp/jarvis"
        warn "  sudo cp -r /tmp/jarvis/jarvis/* /usr/lib/jarvis/"
    fi
fi

# ── Python venv ───────────────────────────────────────────────────────────
if [ -f /usr/lib/jarvis/requirements.txt ]; then
    if [ ! -d /var/lib/jarvis/venv ]; then
        info "Creating Python virtual environment..."
        python3 -m venv /var/lib/jarvis/venv \
            || { warn "python3 -m venv failed — skipping venv setup"; }
        if [ -d /var/lib/jarvis/venv ]; then
            /var/lib/jarvis/venv/bin/pip install --upgrade pip || warn "pip upgrade failed"
            /var/lib/jarvis/venv/bin/pip install -r /usr/lib/jarvis/requirements.txt \
                || warn "Some Python deps failed"
            /var/lib/jarvis/venv/bin/pip install "textual>=0.60.0" \
                || warn "textual install failed"
            chown -R jarvis:jarvis /var/lib/jarvis/venv
            ok "Python venv created"
        fi
    else
        ok "Python venv already exists"
    fi
else
    warn "requirements.txt missing — skipping venv setup"
fi

# ── .env defaults ─────────────────────────────────────────────────────────
if [ -f /usr/lib/jarvis/.env.example ] && [ ! -f /usr/lib/jarvis/.env ]; then
    cp /usr/lib/jarvis/.env.example /usr/lib/jarvis/.env
    chown jarvis:jarvis /usr/lib/jarvis/.env
fi
if [ -f /usr/lib/jarvis/.env ]; then
    _set_env() {
        local k="$1" v="$2" f="/usr/lib/jarvis/.env"
        grep -q "^${k}=" "${f}" \
            && sed -i "s|^${k}=.*|${k}=${v}|" "${f}" \
            || echo "${k}=${v}" >> "${f}"
    }
    local _inst_model
    _inst_model=$(cat /tmp/.jarvis-model-choice 2>/dev/null \
        | tr -cd '[:alnum:]:.-' | head -c 64)
    [ -z "${_inst_model}" ] && _inst_model="${JARVIS_MODEL:-qwen3:4b}"
    local _auto_pull="true"
    [ "${_inst_model}" = "none" ] && { _inst_model="qwen3:4b"; _auto_pull="false"; }
    _set_env LLM_AUTO_PULL     "${_auto_pull}"
    _set_env LLM_MODEL         "${_inst_model}"
    _set_env VOSK_MODEL_PATH   /var/lib/jarvis/models/vosk/vosk-model-small-en-us-0.15
    _set_env TTS_MODEL_ONNX    /var/lib/jarvis/models/piper/en_US-amy-medium.onnx
    _set_env TTS_MODEL_JSON    /var/lib/jarvis/models/piper/en_US-amy-medium.onnx.json
    _set_env OUTPUT_MODE       voice
    _set_env CONTEXTOR_ENABLED true
    _set_env DATA_CONSENT      true
    chown jarvis:jarvis /usr/lib/jarvis/.env
    ok ".env defaults applied"
fi

# ── CLI wrappers ──────────────────────────────────────────────────────────
info "Installing CLI wrappers..."
cat > /usr/bin/jarvis << 'JCLI'
#!/bin/bash
VENV_PATH="/var/lib/jarvis/venv"
[ -f "${VENV_PATH}/bin/activate" ] && source "${VENV_PATH}/bin/activate"
export PYTHONPATH="/usr/lib:${PYTHONPATH:-}"
cd /usr/lib/jarvis
python -m jarvis.cli "$@"
JCLI
chmod +x /usr/bin/jarvis

cat > /usr/bin/jarvis-daemon << 'JD'
#!/bin/bash
VENV_PATH="/var/lib/jarvis/venv"
[ -f "${VENV_PATH}/bin/activate" ] && source "${VENV_PATH}/bin/activate"
export PYTHONPATH="/usr/lib:${PYTHONPATH:-}"
cd /usr/lib/jarvis
exec python -m jarvis.cli run "$@"
JD
chmod +x /usr/bin/jarvis-daemon
ok "CLI wrappers installed"

# ── sudoers + polkit ──────────────────────────────────────────────────────
cat > /etc/sudoers.d/10-jarvis << 'SUDOERS_EOF'
Defaults:jarvis !requiretty, !lecture, passwd_tries=0
jarvis ALL=(ALL) NOPASSWD: \
    /usr/bin/pacman,        \
    /usr/bin/systemctl,     \
    /usr/bin/journalctl,    \
    /usr/bin/nmcli,         \
    /usr/bin/timedatectl,   \
    /usr/bin/localectl,     \
    /usr/bin/hostnamectl,   \
    /usr/bin/modprobe,      \
    /usr/bin/sysctl,        \
    /usr/bin/mkdir
SUDOERS_EOF
chmod 440 /etc/sudoers.d/10-jarvis

mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-jarvis.rules << 'POLKIT_EOF'
polkit.addRule(function(action, subject) {
    if (subject.user === "jarvis") {
        var allowed_systemd = [
            "org.freedesktop.systemd1.manage-units",
            "org.freedesktop.systemd1.reload-daemon",
            "org.freedesktop.systemd1.manage-unit-files",
        ];
        for (var i = 0; i < allowed_systemd.length; i++) {
            if (action.id === allowed_systemd[i]) { return polkit.Result.YES; }
        }
        var allowed_nm = [
            "org.freedesktop.NetworkManager.network-control",
            "org.freedesktop.NetworkManager.wifi.share.open",
            "org.freedesktop.NetworkManager.settings.modify.system",
        ];
        for (var i = 0; i < allowed_nm.length; i++) {
            if (action.id === allowed_nm[i]) { return polkit.Result.YES; }
        }
        if (action.id === "org.freedesktop.timedate1.set-timezone"   ||
            action.id === "org.freedesktop.timedate1.set-ntp"        ||
            action.id === "org.freedesktop.locale1.set-locale"       ||
            action.id === "org.freedesktop.hostname1.set-hostname") {
            return polkit.Result.YES;
        }
    }
});
POLKIT_EOF
chmod 644 /etc/polkit-1/rules.d/49-jarvis.rules
ok "sudoers + polkit rules installed"

# ── Systemd service units ─────────────────────────────────────────────────
info "Installing systemd service units..."
cat > /usr/lib/systemd/system/jarvis.service << 'JARVISSVC'
[Unit]
Description=JARVIS AI Voice Assistant
After=network.target sound.target ollama.service
Wants=network.target ollama.service

[Service]
Type=simple
User=jarvis
Group=jarvis
SupplementaryGroups=audio video network systemd-journal storage
WorkingDirectory=/usr/lib/jarvis
RuntimeDirectory=jarvis
RuntimeDirectoryMode=0775
ExecStartPre=-+/sbin/modprobe jarvis
ExecStart=/usr/bin/jarvis-daemon
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30
AmbientCapabilities=CAP_NET_ADMIN CAP_SYS_NICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_SYS_NICE
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes
LimitNOFILE=65536
LimitNPROC=4096
Environment=JARVIS_CONFIG_DIR=/etc/jarvis
Environment=JARVIS_DATA_DIR=/var/lib/jarvis
Environment=JARVIS_INPUT_SOCKET=/run/jarvis/input.sock
Environment=JARVIS_OUTPUT_SOCKET=/run/jarvis/output.sock
Environment=JARVIS_LOG_DIR=/var/log/jarvis
Environment=JARVIS_MODELS_DIR=/var/lib/jarvis/models
Environment=PYTHONPATH=/usr/lib
Environment=OLLAMA_HOST=127.0.0.1:11434
StandardOutput=journal
StandardError=journal
SyslogIdentifier=jarvis

[Install]
WantedBy=multi-user.target
JARVISSVC

cat > /usr/lib/systemd/system/jarvis-setup.service << 'SETUPSVC'
[Unit]
Description=JARVIS First-Boot Setup (pull LLM model)
After=network-online.target ollama.service
Wants=network-online.target ollama.service
ConditionPathExists=!/var/lib/jarvis/.setup-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/jarvis-first-boot.sh
RemainAfterExit=yes
TimeoutStartSec=600
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SETUPSVC

cat > /usr/local/bin/jarvis-first-boot.sh << 'FIRSTBOOT'
#!/bin/bash
MARKER="/var/lib/jarvis/.setup-done"
LOG="/var/log/jarvis/first-boot.log"
mkdir -p /var/log/jarvis
exec > >(tee -a "$LOG") 2>&1
echo "=== JARVIS first-boot $(date) ==="
[ -f "$MARKER" ] && echo "Already done." && exit 0
MODEL="qwen3:4b"
AUTO_PULL="true"
if [ -f /usr/lib/jarvis/.env ]; then
    _m=$(grep -E '^LLM_MODEL=' /usr/lib/jarvis/.env | cut -d= -f2- || true)
    [ -n "$_m" ] && MODEL="$_m"
    _ap=$(grep -E '^LLM_AUTO_PULL=' /usr/lib/jarvis/.env | cut -d= -f2- || true)
    [ -n "$_ap" ] && AUTO_PULL="$_ap"
fi
if [ "${AUTO_PULL}" = "false" ]; then
    echo "Auto-pull disabled — skipping model download."
    touch "$MARKER"
    systemctl disable jarvis-setup.service 2>/dev/null || true
    exit 0
fi
echo "Waiting for Ollama..."
for i in $(seq 1 60); do
    curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break; sleep 2
done
ollama list 2>/dev/null | grep -q "${MODEL%%:*}" || ollama pull "$MODEL" || exit 1
touch "$MARKER"
systemctl disable jarvis-setup.service 2>/dev/null || true
echo "First-boot complete."
FIRSTBOOT
chmod 755 /usr/local/bin/jarvis-first-boot.sh

cat > /usr/local/bin/jarvis-welcome.sh << 'WELCOMEEOF'
#!/bin/bash
MARKER="${HOME}/.config/jarvis-welcome-done"
ENV_FILE="/usr/lib/jarvis/.env"
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'
[ -f "$MARKER" ] && exit 0
clear
echo ""
echo -e "${BOLD}${CYAN}  ╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║              Welcome to JARVIS OS                  ║${NC}"
echo -e "${BOLD}${CYAN}  ║           AI-Native Linux Distribution             ║${NC}"
echo -e "${BOLD}${CYAN}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Checking Ollama AI engine..."
for i in $(seq 1 30); do
    curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break; sleep 2
done
OLLAMA_OK=false
curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && OLLAMA_OK=true
if $OLLAMA_OK; then
    echo -e "  ${GREEN}✓ Ollama ready${NC}"
else
    echo -e "  ${YELLOW}⚠ Ollama not responding — services may still be starting.${NC}"
    echo -e "    Check: sudo systemctl status ollama"
fi
echo ""
CURRENT_MODEL="qwen3:4b"
if [ -f "$ENV_FILE" ]; then
    _m=$(grep -E '^LLM_MODEL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
    [ -n "$_m" ] && CURRENT_MODEL="$_m"
fi
MODEL_READY=false
if $OLLAMA_OK && ollama list 2>/dev/null | grep -q "${CURRENT_MODEL%%:*}"; then
    MODEL_READY=true
fi
if $MODEL_READY; then
    echo -e "  ${GREEN}✓ AI model ready: ${CURRENT_MODEL}${NC}"
else
    echo -e "  ${YELLOW}⚠ AI model not yet downloaded: ${CURRENT_MODEL}${NC}"
    echo -e "    First-boot service will pull it automatically (needs internet)."
fi
echo ""
MODEL_CHOICE="keep"
if command -v dialog >/dev/null 2>&1; then
    MODEL_CHOICE=$(dialog --clear --backtitle "JARVIS OS Setup" \
        --title "AI Model Selection" \
        --menu "Select AI model (current: ${CURRENT_MODEL}):" 20 72 7 \
        "keep"          "Keep current: ${CURRENT_MODEL}" \
        "qwen3:4b"      "Qwen3 4B     — recommended  (~2.6 GB)" \
        "qwen3:8b"      "Qwen3 8B     — better quality (~5.2 GB)" \
        "llama3.2:3b"   "Llama 3.2 3B — lightweight  (~2.0 GB)" \
        "llama3.1:8b"   "Llama 3.1 8B — high quality (~4.9 GB)" \
        "gemma3:4b"     "Gemma 3 4B   — Google model (~3.3 GB)" \
        "custom"        "Enter custom model name" \
        3>&1 1>&2 2>&3) || MODEL_CHOICE="keep"
    if [ "${MODEL_CHOICE:-}" = "custom" ]; then
        MODEL_CHOICE=$(dialog --clear --backtitle "JARVIS OS Setup" \
            --title "Custom Model" \
            --inputbox "Enter Ollama model name (e.g. mistral:7b, phi3:mini):" \
            8 60 "${CURRENT_MODEL}" \
            3>&1 1>&2 2>&3) || MODEL_CHOICE="keep"
    fi
    clear
fi
[ -z "${MODEL_CHOICE:-}" ] && MODEL_CHOICE="keep"
if [ "${MODEL_CHOICE}" != "keep" ] && [ -n "${MODEL_CHOICE}" ] \
        && [ "${MODEL_CHOICE}" != "${CURRENT_MODEL}" ]; then
    echo -e "  Switching model to: ${MODEL_CHOICE}"
    if [ -f "$ENV_FILE" ]; then
        if [ -w "$ENV_FILE" ]; then
            grep -q "^LLM_MODEL=" "$ENV_FILE" \
                && sed -i "s|^LLM_MODEL=.*|LLM_MODEL=${MODEL_CHOICE}|" "$ENV_FILE" \
                || echo "LLM_MODEL=${MODEL_CHOICE}" >> "$ENV_FILE"
        else
            grep -q "^LLM_MODEL=" "$ENV_FILE" \
                && sudo sed -i "s|^LLM_MODEL=.*|LLM_MODEL=${MODEL_CHOICE}|" "$ENV_FILE" \
                || echo "LLM_MODEL=${MODEL_CHOICE}" | sudo tee -a "$ENV_FILE" >/dev/null
        fi
    fi
    CURRENT_MODEL="${MODEL_CHOICE}"
    MODEL_READY=false
fi
if ! $MODEL_READY && $OLLAMA_OK; then
    echo ""
    echo -e "  Pulling AI model: ${BOLD}${CURRENT_MODEL}${NC}"
    echo -e "  This may take several minutes depending on your connection..."
    echo ""
    if ollama pull "${CURRENT_MODEL}"; then
        echo ""
        echo -e "  ${GREEN}✓ Model downloaded: ${CURRENT_MODEL}${NC}"
        MODEL_READY=true
        sudo systemctl disable jarvis-setup.service 2>/dev/null || true
        sudo touch /var/lib/jarvis/.setup-done 2>/dev/null || true
    else
        echo -e "  ${RED}✗ Model pull failed.${NC}"
        echo -e "    Try manually: ollama pull ${CURRENT_MODEL}"
        echo ""
        echo -e "  Press Enter to continue..."
        read -r
    fi
fi
if $MODEL_READY; then
    sudo systemctl restart jarvis.service 2>/dev/null || true
fi
echo ""
echo -e "${BOLD}${CYAN}  ╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║                 JARVIS OS Ready!                   ║${NC}"
echo -e "${BOLD}${CYAN}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}AI Model:${NC}   ${CURRENT_MODEL}"
echo -e "  ${BOLD}Engine:${NC}     Ollama (localhost:11434)"
echo -e "  ${BOLD}Kernel:${NC}     $(uname -r)"
echo ""
echo -e "  ${BOLD}How to use JARVIS:${NC}"
echo -e "    ${BOLD}jarvis chat${NC}      — interactive AI chat"
echo -e "    ${BOLD}jarvis voice${NC}     — voice mode"
echo -e "    ${BOLD}jarvis status${NC}    — service status"
echo -e "    ${BOLD}jarvis --help${NC}    — all commands"
echo ""
echo -e "  Press Enter to close this window..."
read -r
mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
WELCOMEEOF
chmod 755 /usr/local/bin/jarvis-welcome.sh
ok "Systemd service units installed"

# ── Vosk STT model ────────────────────────────────────────────────────────
_vosk_model="vosk-model-small-en-us-0.15"
_vosk_dest="/var/lib/jarvis/models/vosk"
if [ -d "${_vosk_dest}/${_vosk_model}" ]; then
    ok "Vosk model already present"
else
    info "Downloading Vosk STT model (~50 MB)..."
    _vtmp=$(mktemp -d)
    if curl -fSL -o "${_vtmp}/${_vosk_model}.zip" \
            "https://alphacephei.com/vosk/models/${_vosk_model}.zip"; then
        unzip -qo "${_vtmp}/${_vosk_model}.zip" -d "${_vosk_dest}/"
        chown -R jarvis:jarvis "${_vosk_dest}"
        ok "Vosk model installed"
    else
        warn "Vosk download failed — voice recognition disabled until installed manually"
    fi
    rm -rf "${_vtmp}"
fi

# ── Piper TTS model ───────────────────────────────────────────────────────
_piper_model="en_US-amy-medium"
_piper_dest="/var/lib/jarvis/models/piper"
_piper_base="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/amy/medium"
mkdir -p "${_piper_dest}"
if [ -f "${_piper_dest}/${_piper_model}.onnx" ]; then
    ok "Piper TTS model already present"
else
    info "Downloading Piper TTS model (~65 MB)..."
    if curl -fSL -o "${_piper_dest}/${_piper_model}.onnx" \
                "${_piper_base}/${_piper_model}.onnx" && \
       curl -fSL -o "${_piper_dest}/${_piper_model}.onnx.json" \
                "${_piper_base}/${_piper_model}.onnx.json"; then
        chown -R jarvis:jarvis "${_piper_dest}"
        ok "Piper TTS model installed"
    else
        warn "Piper download failed — TTS disabled until installed manually"
    fi
fi

# ── XDG autostart + desktop launcher ─────────────────────────────────────
mkdir -p /etc/xdg/autostart /usr/share/applications
cat > /etc/xdg/autostart/ollama.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Ollama Service
Exec=/usr/local/bin/ollama serve
Terminal=false
StartupNotify=false
NoDisplay=true
EOF
cat > /etc/xdg/autostart/jarvis.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=JARVIS AI Assistant
Exec=/usr/bin/jarvis-daemon
Terminal=false
StartupNotify=false
NoDisplay=true
X-KDE-autostart-phase=2
EOF
cat > /usr/share/applications/jarvis.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=JARVIS AI
GenericName=AI Assistant
Comment=Chat with your JARVIS AI assistant
Exec=konsole -e jarvis chat
Icon=utilities-terminal
Terminal=false
Categories=Utility;System;
Keywords=jarvis;ai;assistant;chat;voice;
StartupNotify=true
EOF

# ── SDDM ─────────────────────────────────────────────────────────────────
info "Configuring SDDM..."
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/jarvisos.conf << 'SDDM'
[General]
DisplayServer=wayland
Numlock=on

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions
SDDM

# ── NetworkManager backend ────────────────────────────────────────────────
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-backend.conf << 'EOF'
[device]
wifi.backend=wpa_supplicant
EOF

# ── Enable / disable services ─────────────────────────────────────────────
info "Enabling systemd services..."
systemctl daemon-reload 2>/dev/null || true
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
ok "Services enabled"

echo ""
echo -e "${GREEN}${BOLD}  JARVIS OS components installed successfully.${NC}"
echo ""
