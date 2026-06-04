#!/usr/bin/env bash
# install-jarvis.sh — Install JarvisOS as an overlay on any existing Linux system
#
# Installs:
#   1. linux-jarvisos kernel with JARVIS drivers (Arch/CachyOS only)
#   2. /dev/jarvis udev rules + jarvis group + module auto-load
#   3. Project-JARVIS daemon (dispatch gateway) with Python venv
#   4. Ollama + RAM-appropriate LLM model
#   5. systemd services (jarvis.service, ollama.service)
#   6. /etc/jarvis/ configuration
#
# Usage:
#   sudo ./install-jarvis.sh                    # Full install
#   sudo ./install-jarvis.sh --daemon-only      # Skip kernel install
#   sudo ./install-jarvis.sh --no-model         # Skip Ollama model pull
#   sudo JARVIS_MODEL=qwen3:14b ./install-jarvis.sh
#
# Supported distros:
#   Kernel install : Arch Linux, CachyOS (requires makepkg)
#   Daemon + tools : Any systemd-based Linux (Arch, Ubuntu, Fedora, openSUSE)

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/lib/jarvis"
DATA_DIR="/var/lib/jarvis"
CONFIG_DIR="/etc/jarvis"
LOG_DIR="/var/log/jarvis"
VENV_DIR="${DATA_DIR}/venv"
SYSTEMD_DIR="/usr/lib/systemd/system"
UDEV_DIR="/etc/udev/rules.d"
MODULES_LOAD_DIR="/etc/modules-load.d"

JARVIS_USER="jarvis"
JARVIS_GROUP="jarvis"

PROJECT_JARVIS="${REPO_ROOT}/Project-JARVIS"
UDEV_RULES="${REPO_ROOT}/packages/udev/99-jarvis.rules"

# ── Flags ─────────────────────────────────────────────────────────────────────
DAEMON_ONLY=0
NO_MODEL=0
JARVIS_MODEL="${JARVIS_MODEL:-}"

for arg in "$@"; do
    case "$arg" in
        --daemon-only) DAEMON_ONLY=1 ;;
        --no-model)    NO_MODEL=1 ;;
        --help|-h)
            sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown argument: $arg  (use --help)" >&2; exit 1 ;;
    esac
done

# ── Colours ───────────────────────────────────────────────────────────────────
BLU='\033[0;34m'; GRN='\033[0;32m'; YEL='\033[1;33m'
RED='\033[0;31m'; PRP='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

hdr()  { echo -e "\n${BOLD}${BLU}━━━ $* ━━━${NC}"; }
ok()   { echo -e "${GRN}✓${NC}  $*"; }
warn() { echo -e "${YEL}⚠${NC}   $*"; }
die()  { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLU}  →${NC} $*"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${PRP}"
cat <<'BANNER'
     ██╗ █████╗ ██████╗ ██╗   ██╗██╗███████╗     ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗
     ██║██╔══██╗██╔══██╗██║   ██║██║██╔════╝     ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║
     ██║███████║██████╔╝██║   ██║██║███████╗     ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║
██   ██║██╔══██║██╔══██╗╚██╗ ██╔╝██║╚════██║     ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║
╚█████╔╝██║  ██║██║  ██║ ╚████╔╝ ██║███████║     ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗
 ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝     ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝
BANNER
echo -e "${NC}"
echo -e "  ${BOLD}JarvisOS Overlay Installer${NC}"
echo -e "  Kernel → /dev/jarvis → Daemon → Services"
echo ""

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo ./install-jarvis.sh"

# Remember the invoking user for group membership
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"

# ── Distro detection ──────────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-}"
    else
        DISTRO_ID="unknown"
        DISTRO_LIKE=""
    fi

    IS_ARCH=0
    if [[ "$DISTRO_ID" == "arch" || "$DISTRO_ID" == "cachyos" || "$DISTRO_ID" == "endeavouros" || "$DISTRO_ID" == "manjaro" ]] \
       || [[ "$DISTRO_LIKE" == *"arch"* ]]; then
        IS_ARCH=1
    fi
}

detect_distro
info "Distro: ${DISTRO_ID} (arch-based: ${IS_ARCH})"

# ── RAM-based model selection ─────────────────────────────────────────────────
select_model() {
    local ram_kb ram_gb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_gb=$(( ram_kb / 1024 / 1024 ))

    if [[ -n "$JARVIS_MODEL" ]]; then
        info "Model: ${JARVIS_MODEL} (user-specified)"
        return
    fi

    if   (( ram_gb >= 32 )); then JARVIS_MODEL="qwen3:14b"
    elif (( ram_gb >= 16 )); then JARVIS_MODEL="qwen2.5:7b"
    elif (( ram_gb >= 8  )); then JARVIS_MODEL="qwen2.5:3b"
    else
        warn "< 8 GB RAM detected — Ollama model skipped. Set JARVIS_MODEL manually."
        NO_MODEL=1
        JARVIS_MODEL="qwen2.5:3b"
    fi

    info "RAM: ${ram_gb}GB → model: ${JARVIS_MODEL}"
}

select_model

# ── Install system dependencies ───────────────────────────────────────────────
hdr "System Dependencies"

install_deps() {
    if (( IS_ARCH )); then
        pacman -Sy --noconfirm --needed \
            python python-pip git curl wget \
            portaudio python-pyaudio alsa-utils \
            base-devel bc flex bison openssl libelf pahole
    elif command -v apt-get &>/dev/null; then
        apt-get update -q
        apt-get install -y \
            python3 python3-pip python3-venv python3-dev \
            git curl wget build-essential \
            portaudio19-dev python3-pyaudio alsa-utils
    elif command -v dnf &>/dev/null; then
        dnf install -y \
            python3 python3-pip python3-devel \
            git curl wget gcc gcc-c++ \
            portaudio-devel alsa-utils
    elif command -v zypper &>/dev/null; then
        zypper install -y \
            python3 python3-pip python3-devel \
            git curl wget gcc gcc-c++ \
            portaudio-devel alsa-utils
    else
        warn "Unknown package manager — install python3, git, portaudio manually."
    fi
    ok "System dependencies installed"
}

install_deps

# ── Kernel install (Arch only) ────────────────────────────────────────────────
hdr "Kernel: linux-jarvisos"

if (( DAEMON_ONLY )); then
    warn "Skipping kernel install (--daemon-only)"
elif (( ! IS_ARCH )); then
    warn "Non-Arch distro — kernel install requires makepkg."
    warn "Build manually: https://github.com/JarvisOSLinux/linux-jarvisos"
    warn "Continuing with daemon install..."
else
    KERNEL_SCRIPT="${REPO_ROOT}/build-kernel.sh"
    [[ -f "$KERNEL_SCRIPT" ]] || die "build-kernel.sh not found at ${KERNEL_SCRIPT}"

    if [[ -f /boot/vmlinuz-linux-jarvisos ]]; then
        ok "linux-jarvisos already installed at /boot/vmlinuz-linux-jarvisos"
    else
        info "Building linux-jarvisos kernel (this takes 20-60 min)..."
        bash "$KERNEL_SCRIPT" --install
        ok "linux-jarvisos kernel installed"
    fi
fi

# ── /dev/jarvis setup ─────────────────────────────────────────────────────────
hdr "/dev/jarvis Configuration"

# jarvis group
if ! getent group "$JARVIS_GROUP" &>/dev/null; then
    groupadd -r "$JARVIS_GROUP"
    ok "Created group: ${JARVIS_GROUP}"
else
    ok "Group ${JARVIS_GROUP} already exists"
fi

# Add invoking user to jarvis group
if [[ -n "$REAL_USER" ]] && id "$REAL_USER" &>/dev/null; then
    usermod -aG "$JARVIS_GROUP" "$REAL_USER"
    ok "Added ${REAL_USER} to ${JARVIS_GROUP} group"
fi

# udev rule
install -Dm644 "$UDEV_RULES" "${UDEV_DIR}/99-jarvis.rules"
ok "udev rule installed: ${UDEV_DIR}/99-jarvis.rules"

# modules-load.d — auto-load jarvis.ko at boot
echo "jarvis" > "${MODULES_LOAD_DIR}/jarvis.conf"
ok "Module auto-load: ${MODULES_LOAD_DIR}/jarvis.conf"

# Reload udev
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=misc 2>/dev/null || true

# Load module now if the kernel is installed
if modinfo jarvis &>/dev/null 2>&1; then
    modprobe jarvis 2>/dev/null && ok "/dev/jarvis activated" \
        || warn "modprobe jarvis failed — reboot required"
elif [[ -c /dev/jarvis ]]; then
    ok "/dev/jarvis already present"
else
    warn "jarvis.ko not found — /dev/jarvis will appear after rebooting into linux-jarvisos"
fi

# ── Project-JARVIS installation ───────────────────────────────────────────────
hdr "Project-JARVIS Daemon"

# Validate submodule
if [[ ! -f "${PROJECT_JARVIS}/pyproject.toml" ]]; then
    info "Submodule not populated — initialising..."
    git -C "$REPO_ROOT" submodule update --init Project-JARVIS
fi
[[ -f "${PROJECT_JARVIS}/pyproject.toml" ]] \
    || die "Project-JARVIS submodule empty. Run: git submodule update --init Project-JARVIS"

# jarvis system user
if ! getent passwd "$JARVIS_USER" &>/dev/null; then
    useradd -r -g "$JARVIS_GROUP" -G "$JARVIS_GROUP" \
            -d "$DATA_DIR" -s /sbin/nologin \
            -c "JARVIS AI Daemon" "$JARVIS_USER"
    ok "Created system user: ${JARVIS_USER}"
else
    ok "User ${JARVIS_USER} already exists"
fi

# Directories
install -dm755 "$INSTALL_DIR" "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR"
install -dm755 "${DATA_DIR}/models"
chown -R "${JARVIS_USER}:${JARVIS_GROUP}" "$DATA_DIR" "$LOG_DIR"
ok "Directories created"

# Copy source
rsync -a --delete \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.venv' \
    --exclude='venv' \
    --exclude='tests' \
    --exclude='docker*' \
    "${PROJECT_JARVIS}/" "${INSTALL_DIR}/"
chown -R "${JARVIS_USER}:${JARVIS_GROUP}" "$INSTALL_DIR"
ok "Source installed to ${INSTALL_DIR}"

# Python venv
info "Creating Python venv..."
python3 -m venv "$VENV_DIR"
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip

# Install with voice support if pyaudio is available, else minimal
if python3 -c "import pyaudio" 2>/dev/null; then
    "${VENV_DIR}/bin/pip" install --quiet -e "${INSTALL_DIR}[voice]" \
        || "${VENV_DIR}/bin/pip" install --quiet -e "${INSTALL_DIR}"
else
    "${VENV_DIR}/bin/pip" install --quiet -e "${INSTALL_DIR}"
fi

chown -R "${JARVIS_USER}:${JARVIS_GROUP}" "$VENV_DIR"
ok "Python venv ready: ${VENV_DIR}"

# ── Ollama ────────────────────────────────────────────────────────────────────
hdr "Ollama"

if ! command -v ollama &>/dev/null; then
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installed"
else
    ok "Ollama already installed: $(ollama --version 2>/dev/null | head -1)"
fi

# Enable ollama service
if systemctl list-unit-files ollama.service &>/dev/null; then
    systemctl enable --now ollama.service 2>/dev/null || true
    ok "ollama.service enabled"
fi

# Pull model
if (( ! NO_MODEL )); then
    info "Pulling model ${JARVIS_MODEL} (may take several minutes)..."
    ollama pull "$JARVIS_MODEL" && ok "Model ${JARVIS_MODEL} ready" \
        || warn "Model pull failed — run: ollama pull ${JARVIS_MODEL}"
fi

# ── /etc/jarvis/jarvis.conf ───────────────────────────────────────────────────
hdr "Configuration"

if [[ ! -f "${CONFIG_DIR}/jarvis.conf" ]]; then
    cat > "${CONFIG_DIR}/jarvis.conf" << EOF
# /etc/jarvis/jarvis.conf — JarvisOS system configuration
# Generated by install-jarvis.sh

LLM_PROVIDER=ollama
LLM_MODEL=${JARVIS_MODEL}
LLM_AUTO_PULL=false
OLLAMA_HOST=127.0.0.1:11434

JARVIS_CONFIG_DIR=${CONFIG_DIR}
JARVIS_DATA_DIR=${DATA_DIR}
JARVIS_LOG_DIR=${LOG_DIR}
JARVIS_MODELS_DIR=${DATA_DIR}/models

# /dev/jarvis kernel device
JARVIS_DEVICE=/dev/jarvis

LOG_LEVEL=INFO
LOG_COLORS=true
EOF
    chown "${JARVIS_USER}:${JARVIS_GROUP}" "${CONFIG_DIR}/jarvis.conf"
    chmod 640 "${CONFIG_DIR}/jarvis.conf"
    ok "Config written: ${CONFIG_DIR}/jarvis.conf"
else
    ok "Config already exists: ${CONFIG_DIR}/jarvis.conf"
fi

# ── systemd service ───────────────────────────────────────────────────────────
hdr "systemd Services"

cat > "${SYSTEMD_DIR}/jarvis.service" << EOF
[Unit]
Description=JARVIS AI Kernel Integration Daemon
Documentation=https://github.com/JarvisOSLinux/jarvisos
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=${JARVIS_USER}
Group=${JARVIS_GROUP}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_DIR}/bin/python -m jarvis.daemon.gateway --host 127.0.0.1 --port 18789
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30

# /dev/jarvis access
DeviceAllow=/dev/jarvis rw
SupplementaryGroups=${JARVIS_GROUP}

# Security
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${DATA_DIR} ${LOG_DIR}
ProtectKernelModules=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

# Environment
EnvironmentFile=-${CONFIG_DIR}/jarvis.conf
Environment=PYTHONPATH=${INSTALL_DIR}
Environment=PYTHONUNBUFFERED=1

StandardOutput=journal
StandardError=journal
SyslogIdentifier=jarvis

[Install]
WantedBy=multi-user.target
EOF

ok "Service file: ${SYSTEMD_DIR}/jarvis.service"

systemctl daemon-reload
systemctl enable jarvis.service
ok "jarvis.service enabled (starts on boot)"

# Attempt start — may fail if /dev/jarvis absent, that's OK
if systemctl start jarvis.service 2>/dev/null; then
    ok "jarvis.service started"
else
    warn "jarvis.service start deferred — /dev/jarvis may not exist until reboot into linux-jarvisos"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
hdr "Done"
echo ""
echo -e "  ${BOLD}Kernel   ${NC}: $( [[ -f /boot/vmlinuz-linux-jarvisos ]] && echo "linux-jarvisos installed" || echo "not installed — reboot needed after kernel build" )"
echo -e "  ${BOLD}Device   ${NC}: $( [[ -c /dev/jarvis ]] && echo "/dev/jarvis active" || echo "/dev/jarvis — available after reboot into linux-jarvisos" )"
echo -e "  ${BOLD}Daemon   ${NC}: ${INSTALL_DIR}  (venv: ${VENV_DIR})"
echo -e "  ${BOLD}Config   ${NC}: ${CONFIG_DIR}/jarvis.conf"
echo -e "  ${BOLD}Model    ${NC}: ${JARVIS_MODEL}"
echo -e "  ${BOLD}Service  ${NC}: systemctl status jarvis"
echo -e "  ${BOLD}Logs     ${NC}: journalctl -u jarvis -f"
echo ""

if [[ -n "$REAL_USER" ]]; then
    echo -e "  ${YEL}⚠${NC}  Log out and back in as ${REAL_USER} to activate jarvis group membership."
fi

if ! [[ -c /dev/jarvis ]]; then
    echo ""
    echo -e "  ${YEL}Next step:${NC} reboot into linux-jarvisos to activate /dev/jarvis"
    echo -e "  Add bootloader entry or run: ${BOLD}sudo grub-mkconfig -o /boot/grub/grub.cfg${NC}"
fi

echo ""
ok "JarvisOS overlay install complete"
echo ""
