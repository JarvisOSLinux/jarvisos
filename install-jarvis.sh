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
#   ./install-jarvis.sh                    # Full install
#   ./install-jarvis.sh --daemon-only      # Skip kernel install
#   ./install-jarvis.sh --no-model         # Skip Ollama model pull
#   ./install-jarvis.sh --clean            # Wipe build cache + reinstall everything
#   JARVIS_MODEL=qwen3:14b ./install-jarvis.sh
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
DO_CLEAN=0
JARVIS_MODEL="${JARVIS_MODEL:-}"

for arg in "$@"; do
    case "$arg" in
        --daemon-only) DAEMON_ONLY=1 ;;
        --no-model)    NO_MODEL=1 ;;
        --clean|-c)    DO_CLEAN=1 ;;
        --help|-h)     sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown argument: $arg  (use --help)" >&2; exit 1 ;;
    esac
done

if (( DO_CLEAN )); then
    echo -e "\n${BOLD}${YEL}━━━ Clean ━━━${NC}"
    echo "  Removing kernel build cache..."
    rm -rf "${REPO_ROOT}/kernel-pkg"
    if [[ -f "${REPO_ROOT}/linux-jarvisos/Makefile" ]]; then
        make -C "${REPO_ROOT}/linux-jarvisos" clean 2>/dev/null || true
        rm -f "${REPO_ROOT}/linux-jarvisos/.config" "${REPO_ROOT}/linux-jarvisos/.config.old"
    fi
    echo "  Removing JARVIS daemon install..."
    sudo rm -rf /usr/lib/jarvis /var/lib/jarvis/venv
    echo "  Removing systemd service..."
    sudo systemctl stop jarvis.service 2>/dev/null || true
    sudo systemctl disable jarvis.service 2>/dev/null || true
    sudo rm -f /usr/lib/systemd/system/jarvis.service
    sudo systemctl daemon-reload 2>/dev/null || true
    echo -e "${GRN}✓${NC}  Clean complete — reinstalling from scratch"
fi

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

REAL_USER="$(whoami)"
[[ "$REAL_USER" == "root" ]] && die "Do not run as root. Run as your normal user: ./install-jarvis.sh"

# Verify sudo access upfront — caches credentials for the session
info "Checking sudo access..."
sudo -v || die "sudo required. Ensure your user has sudo privileges."
ok "sudo credentials cached"

# ── Distro detection ──────────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-}"
    else
        DISTRO_ID="unknown"; DISTRO_LIKE=""
    fi
    IS_ARCH=0
    if [[ "$DISTRO_ID" == "arch" || "$DISTRO_ID" == "cachyos" || \
          "$DISTRO_ID" == "endeavouros" || "$DISTRO_ID" == "manjaro" ]] \
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
        info "Model: ${JARVIS_MODEL} (user-specified)"; return
    fi
    if   (( ram_gb >= 32 )); then JARVIS_MODEL="qwen3:14b"
    elif (( ram_gb >= 16 )); then JARVIS_MODEL="qwen2.5:7b"
    elif (( ram_gb >= 8  )); then JARVIS_MODEL="qwen2.5:3b"
    else
        warn "< 8 GB RAM — model skipped. Set JARVIS_MODEL manually."
        NO_MODEL=1; JARVIS_MODEL="qwen2.5:3b"
    fi
    info "RAM: ${ram_gb}GB → model: ${JARVIS_MODEL}"
}
select_model

# ── System dependencies ───────────────────────────────────────────────────────
hdr "System Dependencies"

if (( IS_ARCH )); then
    sudo pacman -Sy --noconfirm --needed \
        python python-pip git curl wget \
        portaudio python-pyaudio alsa-utils \
        base-devel bc flex bison openssl libelf pahole
elif command -v apt-get &>/dev/null; then
    sudo apt-get update -q
    sudo apt-get install -y \
        python3 python3-pip python3-venv python3-dev \
        git curl wget build-essential \
        portaudio19-dev python3-pyaudio alsa-utils
elif command -v dnf &>/dev/null; then
    sudo dnf install -y \
        python3 python3-pip python3-devel \
        git curl wget gcc gcc-c++ portaudio-devel alsa-utils
elif command -v zypper &>/dev/null; then
    sudo zypper install -y \
        python3 python3-pip python3-devel \
        git curl wget gcc gcc-c++ portaudio-devel alsa-utils
else
    warn "Unknown package manager — install python3, git, portaudio manually."
fi
ok "System dependencies installed"

# ── Kernel install (Arch only, runs as current user) ─────────────────────────
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

    # Ensure kernel-pkg dir exists and is writable by current user
    # (may be root-owned from a previous failed sudo run)
    mkdir -p "${REPO_ROOT}/kernel-pkg"
    sudo chown "${REAL_USER}:${REAL_USER}" "${REPO_ROOT}/kernel-pkg"

    if [[ -f /boot/vmlinuz-linux-jarvisos ]]; then
        ok "linux-jarvisos already installed"
    else
        info "Building linux-jarvisos kernel (20-60 min)..."
        bash "$KERNEL_SCRIPT" --install
        ok "linux-jarvisos kernel installed"
    fi
fi

# ── /dev/jarvis setup ─────────────────────────────────────────────────────────
hdr "/dev/jarvis Configuration"

if ! getent group "$JARVIS_GROUP" &>/dev/null; then
    sudo groupadd -r "$JARVIS_GROUP"
    ok "Created group: ${JARVIS_GROUP}"
else
    ok "Group ${JARVIS_GROUP} already exists"
fi

sudo usermod -aG "$JARVIS_GROUP" "$REAL_USER"
ok "Added ${REAL_USER} to ${JARVIS_GROUP} group"

sudo install -Dm644 "$UDEV_RULES" "${UDEV_DIR}/99-jarvis.rules"
ok "udev rule: ${UDEV_DIR}/99-jarvis.rules"

echo "jarvis" | sudo tee "${MODULES_LOAD_DIR}/jarvis.conf" > /dev/null
ok "Module auto-load: ${MODULES_LOAD_DIR}/jarvis.conf"

sudo udevadm control --reload-rules 2>/dev/null || true
sudo udevadm trigger --subsystem-match=misc 2>/dev/null || true

if modinfo jarvis &>/dev/null 2>&1; then
    sudo modprobe jarvis 2>/dev/null && ok "/dev/jarvis activated" \
        || warn "modprobe jarvis failed — reboot required"
elif [[ -c /dev/jarvis ]]; then
    ok "/dev/jarvis already present"
else
    warn "jarvis.ko not found — /dev/jarvis will appear after reboot into linux-jarvisos"
fi

# ── Project-JARVIS daemon ─────────────────────────────────────────────────────
hdr "Project-JARVIS Daemon"

if [[ ! -f "${PROJECT_JARVIS}/pyproject.toml" ]]; then
    info "Initialising Project-JARVIS submodule..."
    git -C "$REPO_ROOT" submodule update --init Project-JARVIS
fi
[[ -f "${PROJECT_JARVIS}/pyproject.toml" ]] \
    || die "Project-JARVIS submodule empty. Run: git submodule update --init Project-JARVIS"

if ! getent passwd "$JARVIS_USER" &>/dev/null; then
    sudo useradd -r -g "$JARVIS_GROUP" -G "$JARVIS_GROUP" \
                 -d "$DATA_DIR" -s /sbin/nologin \
                 -c "JARVIS AI Daemon" "$JARVIS_USER"
    ok "Created system user: ${JARVIS_USER}"
else
    ok "User ${JARVIS_USER} already exists"
fi

sudo install -dm755 "$INSTALL_DIR" "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR"
sudo install -dm755 "${DATA_DIR}/models"
sudo chown -R "${JARVIS_USER}:${JARVIS_GROUP}" "$DATA_DIR" "$LOG_DIR"
ok "Directories created"

sudo rsync -a --delete \
    --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='.venv' --exclude='venv' --exclude='tests' --exclude='docker*' \
    "${PROJECT_JARVIS}/" "${INSTALL_DIR}/"
sudo chown -R "${JARVIS_USER}:${JARVIS_GROUP}" "$INSTALL_DIR"
ok "Source installed to ${INSTALL_DIR}"

info "Creating Python venv..."
sudo python3 -m venv "$VENV_DIR"
sudo "${VENV_DIR}/bin/pip" install --quiet --upgrade pip

if python3 -c "import pyaudio" 2>/dev/null; then
    sudo "${VENV_DIR}/bin/pip" install --quiet -e "${INSTALL_DIR}[voice]" \
        || sudo "${VENV_DIR}/bin/pip" install --quiet -e "${INSTALL_DIR}"
else
    sudo "${VENV_DIR}/bin/pip" install --quiet -e "${INSTALL_DIR}"
fi

sudo chown -R "${JARVIS_USER}:${JARVIS_GROUP}" "$VENV_DIR"
ok "Python venv ready: ${VENV_DIR}"

# ── Ollama ────────────────────────────────────────────────────────────────────
hdr "Ollama"

if ! command -v ollama &>/dev/null; then
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installed"
else
    ok "Ollama: $(ollama --version 2>/dev/null | head -1)"
fi

if systemctl list-unit-files ollama.service &>/dev/null 2>&1; then
    sudo systemctl enable --now ollama.service 2>/dev/null || true
    ok "ollama.service enabled"
fi

if (( ! NO_MODEL )); then
    info "Pulling ${JARVIS_MODEL} (may take several minutes)..."
    ollama pull "$JARVIS_MODEL" && ok "Model ${JARVIS_MODEL} ready" \
        || warn "Model pull failed — run: ollama pull ${JARVIS_MODEL}"
fi

# ── /etc/jarvis/jarvis.conf ───────────────────────────────────────────────────
hdr "Configuration"

if [[ ! -f "${CONFIG_DIR}/jarvis.conf" ]]; then
    sudo tee "${CONFIG_DIR}/jarvis.conf" > /dev/null << EOF
# /etc/jarvis/jarvis.conf — JarvisOS system configuration
LLM_PROVIDER=ollama
LLM_MODEL=${JARVIS_MODEL}
LLM_AUTO_PULL=false
OLLAMA_HOST=127.0.0.1:11434

JARVIS_CONFIG_DIR=${CONFIG_DIR}
JARVIS_DATA_DIR=${DATA_DIR}
JARVIS_LOG_DIR=${LOG_DIR}
JARVIS_MODELS_DIR=${DATA_DIR}/models
JARVIS_DEVICE=/dev/jarvis

LOG_LEVEL=INFO
LOG_COLORS=true
EOF
    sudo chown "${JARVIS_USER}:${JARVIS_GROUP}" "${CONFIG_DIR}/jarvis.conf"
    sudo chmod 640 "${CONFIG_DIR}/jarvis.conf"
    ok "Config: ${CONFIG_DIR}/jarvis.conf"
else
    ok "Config already exists: ${CONFIG_DIR}/jarvis.conf"
fi

# ── systemd service ───────────────────────────────────────────────────────────
hdr "systemd Services"

sudo tee "${SYSTEMD_DIR}/jarvis.service" > /dev/null << EOF
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

DeviceAllow=/dev/jarvis rw
SupplementaryGroups=${JARVIS_GROUP}

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

LimitNOFILE=65536
LimitNPROC=4096

EnvironmentFile=-${CONFIG_DIR}/jarvis.conf
Environment=PYTHONPATH=${INSTALL_DIR}
Environment=PYTHONUNBUFFERED=1

StandardOutput=journal
StandardError=journal
SyslogIdentifier=jarvis

[Install]
WantedBy=multi-user.target
EOF

ok "Service: ${SYSTEMD_DIR}/jarvis.service"
sudo systemctl daemon-reload
sudo systemctl enable jarvis.service
ok "jarvis.service enabled"

if sudo systemctl start jarvis.service 2>/dev/null; then
    ok "jarvis.service started"
else
    warn "jarvis.service start deferred — /dev/jarvis absent until reboot into linux-jarvisos"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
hdr "Done"
echo ""
echo -e "  ${BOLD}Kernel  ${NC}: $([[ -f /boot/vmlinuz-linux-jarvisos ]] && echo "linux-jarvisos installed" || echo "pending reboot")"
echo -e "  ${BOLD}Device  ${NC}: $([[ -c /dev/jarvis ]] && echo "/dev/jarvis active" || echo "/dev/jarvis — available after reboot into linux-jarvisos")"
echo -e "  ${BOLD}Daemon  ${NC}: ${INSTALL_DIR}  (venv: ${VENV_DIR})"
echo -e "  ${BOLD}Config  ${NC}: ${CONFIG_DIR}/jarvis.conf"
echo -e "  ${BOLD}Model   ${NC}: ${JARVIS_MODEL}"
echo -e "  ${BOLD}Service ${NC}: systemctl status jarvis"
echo -e "  ${BOLD}Logs    ${NC}: journalctl -u jarvis -f"
echo ""
echo -e "  ${YEL}⚠${NC}  Log out and back in to activate ${JARVIS_GROUP} group membership."
if ! [[ -c /dev/jarvis ]]; then
    echo -e "  ${YEL}⚠${NC}  Reboot into linux-jarvisos to activate /dev/jarvis."
fi
echo ""
ok "JarvisOS overlay install complete"
echo ""
