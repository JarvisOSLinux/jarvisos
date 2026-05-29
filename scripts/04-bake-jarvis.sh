#!/bin/bash
# Step 4: Bake in Project-JARVIS
# Installs Project-JARVIS code, dependencies, and services into the rootfs

set -eo pipefail

# Source config file and shared utilities
source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

# Validate required variables
if [ -z "${SCRIPTS_DIR}" ]; then
    echo "Error: SCRIPTS_DIR not set in build.config" >&2
    exit 1
fi

if [ -z "${PROJECT_ROOT}" ]; then
    echo "Error: PROJECT_ROOT not set in build.config" >&2
    exit 1
fi

# Construct paths from build.config (paths starting with / are relative to PROJECT_ROOT)
SCRIPTS_DIR="${PROJECT_ROOT}${SCRIPTS_DIR}"
BUILD_DIR="${PROJECT_ROOT}${BUILD_DIR}"
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"
BUILD_DEPS_DIR="${PROJECT_ROOT}${BUILD_DEPS_DIR}"
# Use submodule if initialized, otherwise auto-clone
if [ -d "${PROJECT_ROOT}/Project-JARVIS" ] && [ -f "${PROJECT_ROOT}/Project-JARVIS/requirements.txt" ]; then
    PROJECT_JARVIS="${PROJECT_ROOT}/Project-JARVIS"
else
    PROJECT_JARVIS="/tmp/jarvisos-Project-JARVIS"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if step 3 was completed (Wayland installed)
if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Rootfs not extracted. Please run step 2 first${NC}" >&2
    exit 1
fi

# Verify rootfs has essential directories
if [ ! -d "${SQUASHFS_ROOTFS}/usr/bin" ] && [ ! -d "${SQUASHFS_ROOTFS}/bin" ]; then
    echo -e "${RED}Error: Rootfs appears invalid - /usr/bin or /bin missing${NC}" >&2
    exit 1
fi

# Auto-clone Project-JARVIS if submodule not initialized
if [ ! -d "${PROJECT_JARVIS}" ] || [ ! -f "${PROJECT_JARVIS}/requirements.txt" ]; then
    echo -e "${BLUE}Project-JARVIS submodule not found — cloning...${NC}"
    git clone --depth 1 -b linux-integration-preparation \
        https://github.com/YakupAtahanov/Project-JARVIS.git \
        "${PROJECT_JARVIS}"
    echo -e "${GREEN}✓ Project-JARVIS cloned${NC}"
fi

# Determine chroot command (distro-aware error messages via build-utils.sh)
detect_chroot_cmd

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 4: Installing Project-JARVIS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Rootfs: ${SQUASHFS_ROOTFS}${NC}"
echo -e "${BLUE}Project-JARVIS: ${PROJECT_JARVIS}${NC}"

# Step 1: Copy DNS resolution file
echo -e "${BLUE}Copying DNS resolution file...${NC}"
if [ -f /etc/resolv.conf ]; then
    sudo cp /etc/resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
fi

# Step 2: Bind mount iso-rootfs to itself
echo -e "${BLUE}Bind mounting iso-rootfs to itself...${NC}"
sudo mount --bind "${SQUASHFS_ROOTFS}" "${SQUASHFS_ROOTFS}" || {
    echo -e "${RED}Error: Failed to bind mount rootfs${NC}" >&2
    exit 1
}

# Function to cleanup on exit
cleanup() {
    echo -e "${BLUE}Cleaning up...${NC}"
    for _mp in dev/pts dev/shm dev proc sys run tmp; do
        sudo umount -l "${SQUASHFS_ROOTFS}/${_mp}" 2>/dev/null || true
    done
    sudo umount -l "${SQUASHFS_ROOTFS}" 2>/dev/null || true
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Step 3: Install system dependencies for JARVIS
echo -e "${BLUE}Installing system dependencies for JARVIS...${NC}"

# Audio libraries (for voice input/output)
# Note: PipeWire is already installed in step 3, so we don't need pulseaudio
echo -e "${BLUE}Installing audio libraries...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    portaudio \
    alsa-utils \
    python-pyaudio

# Python development tools (for building Python packages)
echo -e "${BLUE}Installing Python development tools...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    python \
    python-pip \
    python-virtualenv \
    python-setuptools \
    python-wheel \
    gcc \
    make \
    pkg-config

# Step 4: Install Ollama
echo -e "${BLUE}Installing Ollama...${NC}"
# The install.sh script tries to run systemd in chroot which will fail - we suppress that
# We use a custom approach: download the binary and install it manually
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Try the official install script first (it handles binary download and GPU detection)
    # OLLAMA_NO_SYSTEM_SERVICE=1 prevents systemd service creation in chroot
    if curl -fsSL https://ollama.com/install.sh | OLLAMA_NO_SYSTEM_SERVICE=1 sh 2>/dev/null; then
        echo '✓ Ollama installed via install.sh'
    else
        echo 'Warning: Ollama install.sh failed or not available, trying direct binary download...'
        ARCH=\$(uname -m)
        if [ \"\${ARCH}\" = 'x86_64' ]; then
            OLLAMA_URL='https://ollama.com/download/ollama-linux-amd64'
        elif [ \"\${ARCH}\" = 'aarch64' ]; then
            OLLAMA_URL='https://ollama.com/download/ollama-linux-arm64'
        else
            echo 'Warning: Unsupported architecture for Ollama: '\${ARCH}
            exit 0
        fi

        if curl -fsSL -o /usr/local/bin/ollama \"\${OLLAMA_URL}\"; then
            chmod +x /usr/local/bin/ollama
            echo '✓ Ollama binary installed manually'
        else
            echo 'Warning: Could not download Ollama binary - it can be installed later'
            echo 'Run: curl -fsSL https://ollama.com/install.sh | sh'
            exit 0
        fi
    fi

    # Install systemd service file for use after installation (not enabled in chroot)
    mkdir -p /usr/lib/systemd/system
    cat > /usr/lib/systemd/system/ollama.service << 'OLLAMAEOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"
Environment=\"HOME=/usr/share/ollama\"
Environment=\"OLLAMA_HOST=127.0.0.1\"

[Install]
WantedBy=default.target
OLLAMAEOF

    # Create ollama user/group for the service
    if ! getent group ollama >/dev/null 2>&1; then
        groupadd -r ollama 2>/dev/null || true
    fi
    if ! getent passwd ollama >/dev/null 2>&1; then
        useradd -r -g ollama -d /usr/share/ollama -s /bin/false -c 'Ollama Service' ollama 2>/dev/null || true
    fi
    mkdir -p /usr/share/ollama
    chown -R ollama:ollama /usr/share/ollama 2>/dev/null || true
"

# Note: Ollama service not enabled in chroot (systemd not running)
# It will be started via autostart on live boot, and can be enabled after installation
echo -e "${BLUE}Ollama installed - service will autostart via XDG autostart on live boot${NC}"

# Step 4b: Ollama model — NOT pre-pulled into the ISO
# The model is downloaded on first boot of the installed system by
# jarvis-setup.service (see Step 15 below).  Skipping the pre-pull keeps
# the ISO under 4 GB; users need internet access on first launch.
echo -e "${BLUE}Skipping Ollama model pre-pull — model downloads on first boot via jarvis-setup.service${NC}"

# Step 5: Create jarvis user, group, and supplementary group memberships
echo -e "${BLUE}Creating jarvis user and group...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Create group if it doesn't exist
    if ! getent group jarvis >/dev/null 2>&1; then
        groupadd -r jarvis
    fi

    # Create user if it doesn't exist
    if ! getent passwd jarvis >/dev/null 2>&1; then
        useradd -r -g jarvis -d /var/lib/jarvis -s /sbin/nologin \
                -c 'JARVIS AI Assistant' jarvis
    fi

    # Add jarvis to supplementary groups needed for autonomous system management.
    # Groups that don't exist on this system are silently skipped.
    #   audio          — PipeWire / ALSA microphone and speaker access
    #   video          — GPU / DRM device access
    #   network        — NetworkManager CLI socket access
    #   systemd-journal — journalctl log reading without root
    #   storage        — block device and storage access
    #   optical        — CD/DVD device access
    for grp in audio video network systemd-journal storage optical; do
        if getent group \"\$grp\" >/dev/null 2>&1; then
            usermod -aG \"\$grp\" jarvis
        fi
    done
"

# Step 5b: sudoers drop-in — allow jarvis to run system management commands
# without a password.  The jarvis policy engine (SAFE/ELEVATED/DANGEROUS/
# FORBIDDEN tiers) is the primary access-control layer; these rules only
# permit the specific commands the agent is designed to execute autonomously.
echo -e "${BLUE}Installing sudoers rules for jarvis...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/etc/sudoers.d/10-jarvis" > /dev/null << 'SUDOERS_EOF'
# JARVIS daemon — autonomous system management
# The jarvis policy engine enforces SAFE/ELEVATED/DANGEROUS/FORBIDDEN tier
# checks before any command is dispatched.  These NOPASSWD rules allow
# non-interactive execution of the commands JARVIS is designed to manage.
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
    /usr/bin/chmod,         \
    /usr/bin/chown,         \
    /usr/bin/mkdir,         \
    /usr/bin/tee,           \
    /usr/bin/cp,            \
    /usr/bin/mv,            \
    /usr/bin/rm
SUDOERS_EOF
sudo chmod 440 "${SQUASHFS_ROOTFS}/etc/sudoers.d/10-jarvis"

# Step 5c: polkit rules — allow jarvis to manage system resources via D-Bus
# without interactive prompts (NetworkManager, systemd units, timedatectl, etc.)
echo -e "${BLUE}Installing polkit rules for jarvis...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/polkit-1/rules.d"
sudo tee "${SQUASHFS_ROOTFS}/etc/polkit-1/rules.d/49-jarvis.rules" > /dev/null << 'POLKIT_EOF'
/* JARVIS daemon — D-Bus authorisation
 *
 * Allows the jarvis system user to manage systemd units, network connections,
 * and basic system settings through D-Bus without interactive prompts.
 * The jarvis policy engine enforces SAFE/ELEVATED/DANGEROUS tier checks
 * before any D-Bus call reaches this layer.
 */
polkit.addRule(function(action, subject) {
    if (subject.user === "jarvis") {
        var allowed = [
            "org.freedesktop.systemd1",
            "org.freedesktop.NetworkManager",
            "org.freedesktop.timedate1",
            "org.freedesktop.locale1",
            "org.freedesktop.hostname1",
            "org.freedesktop.login1",
        ];
        for (var i = 0; i < allowed.length; i++) {
            if (action.id.indexOf(allowed[i]) === 0) {
                return polkit.Result.YES;
            }
        }
    }
});
POLKIT_EOF
sudo chmod 644 "${SQUASHFS_ROOTFS}/etc/polkit-1/rules.d/49-jarvis.rules"

# Step 5c-udev: Install udev rule so /dev/jarvis is GROUP=jarvis MODE=0660
# This allows any user in the jarvis group to use the JARVIS CLI without sudo.
echo -e "${BLUE}Installing udev rule for /dev/jarvis...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/usr/lib/udev/rules.d"
sudo cp "${PROJECT_ROOT}/packages/udev/99-jarvis.rules" \
    "${SQUASHFS_ROOTFS}/usr/lib/udev/rules.d/99-jarvis.rules"
sudo chmod 644 "${SQUASHFS_ROOTFS}/usr/lib/udev/rules.d/99-jarvis.rules"

# Step 6: Create directories
echo -e "${BLUE}Creating JARVIS directories...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    mkdir -p /usr/lib/jarvis
    mkdir -p /var/lib/jarvis/models/piper
    mkdir -p /var/lib/jarvis/models/vosk
    mkdir -p /var/log/jarvis

    # /etc/jarvis: setgid so new files inherit the jarvis group;
    # group-writable so any jarvis-group member can update config without sudo.
    mkdir -p /etc/jarvis
    chown jarvis:jarvis /etc/jarvis
    chmod 2775 /etc/jarvis

    # Set ownership
    chown -R jarvis:jarvis /var/lib/jarvis
    chown -R jarvis:jarvis /var/log/jarvis
    chmod 755 /var/lib/jarvis
    chmod 755 /var/log/jarvis
"

# Step 7: Copy Project-JARVIS code
echo -e "${BLUE}Copying Project-JARVIS code...${NC}"
sudo cp -r "${PROJECT_JARVIS}/jarvis"/* "${SQUASHFS_ROOTFS}/usr/lib/jarvis/"
# Explicitly copy dotfiles (glob * skips them)
[ -f "${PROJECT_JARVIS}/jarvis/.env.example" ] && \
    sudo cp "${PROJECT_JARVIS}/jarvis/.env.example" "${SQUASHFS_ROOTFS}/usr/lib/jarvis/.env.example"
# Copy requirements.txt for venv installation
sudo cp "${PROJECT_JARVIS}/requirements.txt" "${SQUASHFS_ROOTFS}/usr/lib/jarvis/requirements.txt"
# Chown inside chroot (user exists there)
sudo arch-chroot "${SQUASHFS_ROOTFS}" chown -R jarvis:jarvis /usr/lib/jarvis

# Verify core jarvis module was copied correctly
echo -e "${BLUE}Verifying JARVIS module installation...${NC}"
if [ ! -f "${SQUASHFS_ROOTFS}/usr/lib/jarvis/main.py" ]; then
    echo -e "${RED}ERROR: jarvis/main.py not found after copy${NC}" >&2
    exit 1
fi
if [ ! -f "${SQUASHFS_ROOTFS}/usr/lib/jarvis/cli.py" ]; then
    echo -e "${RED}ERROR: jarvis/cli.py not found after copy${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ JARVIS module verified successfully${NC}"

# ---- DMCP: build and install -----------------------------------------------
# dmcp is a Rust binary (MCP server manager). We build it on the host for the
# target architecture and drop the binary into the rootfs at /usr/bin/dmcp.
# Building inside the chroot would require installing Rust there; building on
# the host and copying is simpler and faster.

DMCP_DIR="${PROJECT_ROOT}/dmcp"
DMCP_BINARY_SRC="${DMCP_DIR}/target/release/dmcp"
_DMCP_BINARY_READY=0

echo -e "${BLUE}Installing dmcp (MCP server manager)...${NC}"

# Path A: submodule present — build from source
if [ -d "${DMCP_DIR}" ] && [ -f "${DMCP_DIR}/Cargo.toml" ]; then
    if command -v cargo &>/dev/null; then
        (cd "${DMCP_DIR}" && cargo build --release 2>&1) || {
            echo -e "${RED}ERROR: dmcp build failed${NC}" >&2; exit 1
        }
        [ -f "${DMCP_BINARY_SRC}" ] && _DMCP_BINARY_READY=1
    else
        echo -e "${YELLOW}Warning: cargo not found — falling back to release download${NC}"
    fi
fi

# Path B: no submodule or cargo missing — download pre-built binary from GitHub Releases
if [ "${_DMCP_BINARY_READY}" = "0" ]; then
    echo -e "${BLUE}Downloading dmcp binary from GitHub Releases...${NC}"
    if ! command -v gh &>/dev/null; then
        echo -e "${YELLOW}Warning: gh CLI not found — skipping dmcp install${NC}"
    else
        _DMCP_TMP=$(mktemp -d)
        if gh release download --repo YakupAtahanov/dmcp \
            --pattern "dmcp-linux-x86_64" \
            --dir "${_DMCP_TMP}" --clobber 2>/dev/null; then
            DMCP_BINARY_SRC="${_DMCP_TMP}/dmcp-linux-x86_64"
            chmod +x "${DMCP_BINARY_SRC}"
            _DMCP_BINARY_READY=1
        else
            echo -e "${YELLOW}Warning: dmcp release not found — skipping dmcp install${NC}"
        fi
    fi
fi

if [ "${_DMCP_BINARY_READY}" = "1" ]; then
        echo -e "${BLUE}Installing dmcp binary to rootfs...${NC}"
        sudo cp "${DMCP_BINARY_SRC}" "${SQUASHFS_ROOTFS}/usr/bin/dmcp"
        sudo chmod 755 "${SQUASHFS_ROOTFS}/usr/bin/dmcp"
        sudo chown root:root "${SQUASHFS_ROOTFS}/usr/bin/dmcp"

        # System-level MCP sources list (empty by default; registry URLs added here)
        sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/mcp"
        sudo tee "${SQUASHFS_ROOTFS}/etc/mcp/sources.list" > /dev/null << 'DMCP_SOURCES_EOF'
# /etc/mcp/sources.list — system-wide dmcp registry sources
# Add registry URLs below (one per line). Lines starting with # are ignored.
# Example:
#   https://raw.githubusercontent.com/example/mcp-registry/main/registry.json
DMCP_SOURCES_EOF
        sudo chmod 644 "${SQUASHFS_ROOTFS}/etc/mcp/sources.list"

        # dmcp systemd service (runs `dmcp serve` as the jarvis user so JARVIS
        # can use it as its MCP server via stdio)
        sudo tee "${SQUASHFS_ROOTFS}/usr/lib/systemd/system/dmcp.service" > /dev/null << 'DMCP_SVC_EOF'
[Unit]
Description=DMCP MCP Server Manager
Documentation=man:dmcp(1)
After=network.target
PartOf=jarvis.service

[Service]
Type=simple
User=jarvis
Group=jarvis
ExecStart=/usr/bin/dmcp serve
Restart=on-failure
RestartSec=3
StandardInput=null
StandardOutput=journal
StandardError=journal
Environment="HOME=/var/lib/jarvis"
Environment="XDG_DATA_HOME=/var/lib/jarvis/.local/share"
Environment="XDG_CONFIG_HOME=/etc"

[Install]
WantedBy=multi-user.target
DMCP_SVC_EOF
        sudo chmod 644 "${SQUASHFS_ROOTFS}/usr/lib/systemd/system/dmcp.service"

        echo -e "${GREEN}✓ dmcp installed (/usr/bin/dmcp + dmcp.service)${NC}"
fi
# ---- end DMCP ---------------------------------------------------------------

# ---- DISPATCH: build and install --------------------------------------------
DISPATCH_DIR="${PROJECT_ROOT}/dispatch"
DISPATCH_BINARY_SRC="${DISPATCH_DIR}/target/release/dispatch"
_DISPATCH_BINARY_READY=0

echo -e "${BLUE}Installing dispatch (MCP task orchestrator)...${NC}"

# Path A: submodule present — build from source
if [ -f "${DISPATCH_DIR}/Cargo.toml" ]; then
    if command -v cargo &>/dev/null; then
        (cd "${DISPATCH_DIR}" && cargo build --release 2>&1) || {
            echo -e "${RED}ERROR: dispatch build failed${NC}" >&2; exit 1
        }
        [ -f "${DISPATCH_BINARY_SRC}" ] && _DISPATCH_BINARY_READY=1
    else
        echo -e "${YELLOW}Warning: cargo not found — falling back to release download${NC}"
    fi
fi

# Path B: no submodule or cargo missing — download pre-built binary
if [ "${_DISPATCH_BINARY_READY}" = "0" ]; then
    echo -e "${BLUE}Downloading dispatch binary from GitHub Releases...${NC}"
    if ! command -v gh &>/dev/null; then
        echo -e "${YELLOW}Warning: gh CLI not found — skipping dispatch install${NC}"
    else
        _DISPATCH_TMP=$(mktemp -d)
        if gh release download --repo YakupAtahanov/dispatch \
            --pattern "dispatch-linux-x86_64" \
            --dir "${_DISPATCH_TMP}" --clobber 2>/dev/null; then
            DISPATCH_BINARY_SRC="${_DISPATCH_TMP}/dispatch-linux-x86_64"
            chmod +x "${DISPATCH_BINARY_SRC}"
            _DISPATCH_BINARY_READY=1
        else
            echo -e "${YELLOW}Warning: dispatch release not found — skipping dispatch install${NC}"
        fi
    fi
fi

if [ "${_DISPATCH_BINARY_READY}" = "1" ]; then
    echo -e "${BLUE}Installing dispatch binary to rootfs...${NC}"
    sudo cp "${DISPATCH_BINARY_SRC}" "${SQUASHFS_ROOTFS}/usr/bin/dispatch"
    sudo chmod 755 "${SQUASHFS_ROOTFS}/usr/bin/dispatch"
    sudo chown root:root "${SQUASHFS_ROOTFS}/usr/bin/dispatch"
    echo -e "${GREEN}✓ dispatch installed (/usr/bin/dispatch)${NC}"
fi
# ---- end DISPATCH -----------------------------------------------------------

# Step 8: Install Python dependencies in virtual environment
echo -e "${BLUE}Installing Python dependencies...${NC}"

# First verify requirements.txt was copied
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" test -f /usr/lib/jarvis/requirements.txt; then
    echo -e "${RED}ERROR: requirements.txt not found at /usr/lib/jarvis/requirements.txt${NC}" >&2
    exit 1
fi

echo -e "${BLUE}Requirements.txt contents:${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" cat /usr/lib/jarvis/requirements.txt

sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    set -e  # Exit on any error
    
    cd /var/lib/jarvis
    
    # Create virtual environment
    echo 'Creating virtual environment...'
    python3 -m venv venv
    
    # Activate venv and install dependencies
    source venv/bin/activate
    
    # Upgrade pip first
    echo 'Upgrading pip...'
    pip install --upgrade pip
    
    # Install dependencies with verbose output
    echo 'Installing dependencies from requirements.txt...'
    pip install -r /usr/lib/jarvis/requirements.txt --verbose
    
    # Verify critical packages were installed
    echo 'Verifying installations...'
    python -c 'import dotenv; print(\"✓ dotenv installed\")'
    python -c 'import ollama; print(\"✓ ollama installed\")'
    python -c 'import vosk; print(\"✓ vosk installed\")'
    
    # Show installed package count
    PACKAGE_COUNT=\$(pip list | wc -l)
    echo \"Total packages installed: \${PACKAGE_COUNT}\"
    
    if [ \${PACKAGE_COUNT} -lt 20 ]; then
        echo 'ERROR: Too few packages installed, something went wrong'
        exit 1
    fi
    
    deactivate
    
    # Set ownership
    chown -R jarvis:jarvis venv
    
    echo '✓ All dependencies installed successfully'
"

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to install Python dependencies${NC}" >&2
    exit 1
fi

echo -e "${GREEN}✓ Python dependencies installed successfully${NC}"

# Step 9: Create jarvis CLI wrapper script
echo -e "${BLUE}Creating jarvis CLI wrapper...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/usr/bin/jarvis" > /dev/null << 'EOF'
#!/bin/bash
# JARVIS CLI Wrapper
# Activates the virtual environment and runs jarvis CLI

VENV_PATH="/var/lib/jarvis/venv"
JARVIS_PATH="/usr/lib/jarvis"

if [ -f "${VENV_PATH}/bin/activate" ]; then
    source "${VENV_PATH}/bin/activate"
else
    echo "Warning: Virtual environment not found at ${VENV_PATH}" >&2
fi

# Set PYTHONPATH to /usr/lib so Python can find the jarvis module
# The jarvis module is at /usr/lib/jarvis/, so PYTHONPATH should be /usr/lib
export PYTHONPATH="/usr/lib:${PYTHONPATH}"
cd "${JARVIS_PATH}"
python -m jarvis.cli "$@"
EOF

sudo chmod +x "${SQUASHFS_ROOTFS}/usr/bin/jarvis"
sudo chown root:root "${SQUASHFS_ROOTFS}/usr/bin/jarvis"

# Step 10: Install jarvis-daemon script (venv-aware wrapper around jarvis run)
echo -e "${BLUE}Installing jarvis-daemon...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/usr/bin/jarvis-daemon" > /dev/null << 'EOF'
#!/bin/bash
# JARVIS Daemon — activates the venv and runs the async event loop
# (voice + socket + stdin). Used by jarvis.service / XDG autostart.

VENV_PATH="/var/lib/jarvis/venv"
JARVIS_PATH="/usr/lib/jarvis"

if [ -f "${VENV_PATH}/bin/activate" ]; then
    source "${VENV_PATH}/bin/activate"
else
    echo "Warning: Virtual environment not found at ${VENV_PATH}" >&2
fi

export PYTHONPATH="/usr/lib:${PYTHONPATH}"
cd "${JARVIS_PATH}"
exec python -m jarvis.cli run "$@"
EOF

sudo chmod +x "${SQUASHFS_ROOTFS}/usr/bin/jarvis-daemon"
sudo chown root:root "${SQUASHFS_ROOTFS}/usr/bin/jarvis-daemon"

# Step 11: Install systemd service (patched for OS integration)
# The upstream jarvis.service uses ProtectHome=yes and MemoryDenyWriteExecute=yes
# which break audio access and onnxruntime respectively. We install a fixed copy.
echo -e "${BLUE}Installing systemd service...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/usr/lib/systemd/system/jarvis.service" > /dev/null << 'JARVISSVC'
[Unit]
Description=JARVIS AI Voice Assistant
Documentation=https://github.com/YakupAtahanov/Project-JARVIS
After=network.target sound.target ollama.service
Wants=network.target ollama.service

[Service]
Type=simple
User=jarvis
Group=jarvis
# Hardware and system access groups needed for autonomous operation:
#   audio          — PipeWire microphone/speaker
#   video          — GPU/DRM access
#   network        — NetworkManager CLI socket
#   systemd-journal — journalctl log reading
#   storage        — block device access
SupplementaryGroups=audio video network systemd-journal storage

WorkingDirectory=/usr/lib/jarvis
RuntimeDirectory=jarvis
RuntimeDirectoryMode=0775
ExecStart=/usr/bin/jarvis-daemon
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30

# CAP_NET_ADMIN allows direct network interface operations.
# CAP_SYS_NICE allows rtkit real-time scheduling for PipeWire audio.
# /dev/jarvis access is via group membership (GROUP=jarvis, MODE=0660) —
# CAP_SYS_ADMIN is not needed.
AmbientCapabilities=CAP_NET_ADMIN CAP_SYS_NICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_SYS_NICE

# NoNewPrivileges and RestrictSUIDSGID are intentionally absent:
# the daemon spawns `sudo` for system management (pacman, systemctl, etc.).
# sudo is a setuid binary — NO_NEW_PRIVS makes setuid a no-op, breaking it.
# The jarvis policy engine (SAFE/ELEVATED/DANGEROUS/FORBIDDEN) and the
# sudoers rules in /etc/sudoers.d/10-jarvis are the access-control layer.

# ProtectSystem is intentionally absent: package management (pacman) writes
# to /usr, /etc, and /var.  ProtectSystem=strict would create a read-only
# bind-mount namespace that blocks those writes even when running as root
# via sudo.

PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

# Environment
Environment=JARVIS_CONFIG_DIR=/etc/jarvis
Environment=JARVIS_DATA_DIR=/var/lib/jarvis
Environment=JARVIS_INPUT_SOCKET=/run/jarvis/input.sock
Environment=JARVIS_LOG_DIR=/var/log/jarvis
Environment=JARVIS_MODELS_DIR=/var/lib/jarvis/models
Environment=PYTHONPATH=/usr/lib
Environment=OLLAMA_HOST=127.0.0.1:11434
Environment=XDG_RUNTIME_DIR=/run/user/0

# Standard output/error
StandardOutput=journal
StandardError=journal
SyslogIdentifier=jarvis

[Install]
WantedBy=multi-user.target
JARVISSVC
sudo chmod 644 "${SQUASHFS_ROOTFS}/usr/lib/systemd/system/jarvis.service"

# Step 12: Set up configuration
echo -e "${BLUE}Setting up JARVIS configuration...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Copy config template (source is .env.example)
    if [ -f /usr/lib/jarvis/.env.example ]; then
        cp /usr/lib/jarvis/.env.example /etc/jarvis/jarvis.conf.template
        chown jarvis:jarvis /etc/jarvis/jarvis.conf.template

        # Create initial .env file from template (if it doesn't exist)
        if [ ! -f /usr/lib/jarvis/.env ]; then
            cp /usr/lib/jarvis/.env.example /usr/lib/jarvis/.env
            chown jarvis:jarvis /usr/lib/jarvis/.env
        fi
    else
        echo 'Warning: .env.example not found, skipping config template setup'
    fi
"

# Step 12b: Patch .env defaults for OS deployment
echo -e "${BLUE}Patching .env defaults for OS deployment...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    ENV_FILE=/usr/lib/jarvis/.env
    if [ -f \"\${ENV_FILE}\" ]; then
        # Helper: set key=value (update if exists, append if not)
        set_env() {
            local key=\$1 val=\$2
            if grep -q \"^\${key}=\" \"\${ENV_FILE}\"; then
                sed -i \"s|^\${key}=.*|\${key}=\${val}|\" \"\${ENV_FILE}\"
            else
                echo \"\${key}=\${val}\" >> \"\${ENV_FILE}\"
            fi
        }
        set_env LLM_AUTO_PULL         true
        set_env LLM_MODEL             qwen3:4b
        set_env VOSK_MODEL_PATH       /var/lib/jarvis/models/vosk/vosk-model-small-en-us-0.15
        set_env TTS_MODEL_ONNX        /var/lib/jarvis/models/piper/en_US-amy-medium.onnx
        set_env TTS_MODEL_JSON        /var/lib/jarvis/models/piper/en_US-amy-medium.onnx.json
        set_env OUTPUT_MODE           voice
        set_env CONTEXTOR_ENABLED     true
        set_env DATA_CONSENT          true
        chown jarvis:jarvis \"\${ENV_FILE}\"
    fi
"
echo -e "${GREEN}✓ .env defaults patched${NC}"

# Step 13: Download Vosk STT model
echo -e "${BLUE}Downloading Vosk STT model...${NC}"
VOSK_MODEL="vosk-model-small-en-us-0.15"
VOSK_URL="https://alphacephei.com/vosk/models/${VOSK_MODEL}.zip"
VOSK_DEST="${SQUASHFS_ROOTFS}/var/lib/jarvis/models/vosk"

if [ -d "${VOSK_DEST}/${VOSK_MODEL}" ]; then
    echo -e "${GREEN}✓ Vosk model already present${NC}"
else
    VOSK_TMP=$(mktemp -d)
    if curl -fSL -o "${VOSK_TMP}/${VOSK_MODEL}.zip" "${VOSK_URL}"; then
        sudo unzip -qo "${VOSK_TMP}/${VOSK_MODEL}.zip" -d "${VOSK_DEST}/"
        sudo chown -R root:root "${VOSK_DEST}/${VOSK_MODEL}"
        echo -e "${GREEN}✓ Vosk model downloaded${NC}"
    else
        echo -e "${YELLOW}Warning: Could not download Vosk model — STT won't work until manually installed${NC}"
    fi
    rm -rf "${VOSK_TMP}"
fi

# Step 14: Download Piper TTS model
echo -e "${BLUE}Downloading Piper TTS model...${NC}"
PIPER_MODEL="en_US-amy-medium"
PIPER_BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/amy/medium"
PIPER_DEST="${SQUASHFS_ROOTFS}/var/lib/jarvis/models/piper"

if [ -f "${PIPER_DEST}/${PIPER_MODEL}.onnx" ] && [ -f "${PIPER_DEST}/${PIPER_MODEL}.onnx.json" ]; then
    echo -e "${GREEN}✓ Piper model already present${NC}"
else
    sudo mkdir -p "${PIPER_DEST}"
    PIPER_OK=true
    if ! sudo curl -fSL -o "${PIPER_DEST}/${PIPER_MODEL}.onnx" \
        "${PIPER_BASE_URL}/${PIPER_MODEL}.onnx"; then
        echo -e "${YELLOW}Warning: Could not download Piper ONNX model${NC}"
        PIPER_OK=false
    fi
    if ! sudo curl -fSL -o "${PIPER_DEST}/${PIPER_MODEL}.onnx.json" \
        "${PIPER_BASE_URL}/${PIPER_MODEL}.onnx.json"; then
        echo -e "${YELLOW}Warning: Could not download Piper JSON config${NC}"
        PIPER_OK=false
    fi
    if [ "${PIPER_OK}" = "true" ]; then
        sudo chown -R root:root "${PIPER_DEST}"
        echo -e "${GREEN}✓ Piper TTS model downloaded${NC}"
    else
        echo -e "${YELLOW}Warning: Piper model incomplete — TTS won't work until manually installed${NC}"
    fi
fi

# Step 15: Create first-boot service for Ollama model pull
echo -e "${BLUE}Creating first-boot service...${NC}"

# First-boot script
sudo tee "${SQUASHFS_ROOTFS}/usr/local/bin/jarvis-first-boot.sh" > /dev/null << 'FIRSTBOOT'
#!/bin/bash
# JARVIS first-boot setup: GPU detection, Ollama GPU reinstall, LLM model pull.
# Runs once after installation, then disables itself.
#
# GPU note: the ISO bakes a CPU-only Ollama binary because the build runs in a
# chroot where no GPU is visible.  This script runs on the real installed system
# and replaces the binary with the correct GPU variant before pulling the model.

set -e

MARKER="/var/lib/jarvis/.setup-done"
LOG="/var/log/jarvis/first-boot.log"
mkdir -p /var/log/jarvis
exec > >(tee -a "$LOG") 2>&1
echo "=== JARVIS first-boot $(date) ==="

[ -f "$MARKER" ] && echo "Setup already completed." && exit 0

# ── GPU detection ─────────────────────────────────────────────────────────────
_detect_gpu() {
    # NVIDIA: check PCI bus or loaded kernel module
    if lspci 2>/dev/null | grep -qi 'nvidia' || \
       lsmod 2>/dev/null | grep -q '^nvidia '; then
        echo "nvidia"; return
    fi
    # AMD discrete GPU: amdgpu module loaded (APUs show radeon, not amdgpu)
    if lsmod 2>/dev/null | grep -q '^amdgpu '; then
        echo "amd"; return
    fi
    # Fallback PCI scan for AMD/Radeon
    if lspci 2>/dev/null | grep -qi 'radeon\|amdgpu'; then
        echo "amd"; return
    fi
    echo "cpu"
}

# ── Reinstall Ollama with GPU support ────────────────────────────────────────
GPU=$(_detect_gpu)
echo "GPU detected: ${GPU}"
_ARCH=$(uname -m)

case "${GPU}" in
    nvidia)
        echo "Installing Ollama with NVIDIA CUDA support..."
        curl -fsSL https://ollama.com/install.sh | sh \
            || echo "Warning: CUDA install failed — Ollama stays in CPU mode"
        ;;
    amd)
        echo "Installing Ollama with AMD ROCm support..."
        if [ "${_ARCH}" = "x86_64" ]; then
            curl -fsSL -o /usr/local/bin/ollama \
                    https://ollama.com/download/ollama-linux-amd64-rocm \
                && chmod +x /usr/local/bin/ollama \
                && echo "✓ Ollama ROCm binary installed" \
                || { echo "Warning: ROCm download failed — falling back to install.sh";
                     curl -fsSL https://ollama.com/install.sh | sh || true; }
        else
            curl -fsSL https://ollama.com/install.sh | sh || true
        fi
        # Grant ollama service user access to GPU render/DRI devices
        usermod -aG render ollama 2>/dev/null || true
        usermod -aG video  ollama 2>/dev/null || true
        ;;
    cpu)
        echo "No discrete GPU detected — Ollama running in CPU mode"
        ;;
esac

# Restart Ollama so the new binary (or groups) take effect
systemctl restart ollama.service 2>/dev/null || true
sleep 3

# ── Read model from .env ──────────────────────────────────────────────────────
MODEL="qwen3:4b"
if [ -f /usr/lib/jarvis/.env ]; then
    ENV_MODEL=$(grep -E '^LLM_MODEL=' /usr/lib/jarvis/.env | cut -d= -f2-)
    [ -n "$ENV_MODEL" ] && MODEL="$ENV_MODEL"
fi

# ── Wait for Ollama ───────────────────────────────────────────────────────────
echo "Waiting for Ollama..."
for i in $(seq 1 60); do
    curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && \
        echo "Ollama is ready." && break
    sleep 2
done

# ── Pull LLM model ────────────────────────────────────────────────────────────
if ollama list 2>/dev/null | grep -q "${MODEL%%:*}"; then
    echo "Model ${MODEL} already present. Skipping download."
else
    echo "Pulling model: ${MODEL} ..."
    ollama pull "$MODEL" || { echo "Warning: model pull failed — will retry on next boot."; exit 1; }
fi

touch "$MARKER"
echo "First-boot setup complete."
systemctl disable jarvis-setup.service 2>/dev/null || true
FIRSTBOOT

sudo chmod 755 "${SQUASHFS_ROOTFS}/usr/local/bin/jarvis-first-boot.sh"

# First-boot systemd service
sudo tee "${SQUASHFS_ROOTFS}/usr/lib/systemd/system/jarvis-setup.service" > /dev/null << 'SETUPSVC'
[Unit]
Description=JARVIS First-Boot Setup (pull LLM model)
After=network-online.target ollama.service
Wants=network-online.target
Requires=ollama.service
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

sudo chmod 644 "${SQUASHFS_ROOTFS}/usr/lib/systemd/system/jarvis-setup.service"
echo -e "${GREEN}✓ First-boot service created${NC}"

# Step 16: Enable services in rootfs (systemctl enable just creates symlinks in chroot)
# Also enabled by Calamares services-systemd.conf on installed system as a safety net.
echo -e "${BLUE}Enabling JARVIS/Ollama systemd services...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable ollama.service 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable jarvis.service 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable jarvis-setup.service 2>/dev/null || true
echo -e "${GREEN}✓ Systemd services enabled${NC}"

# Step 17: Create XDG autostart entries for live environment and installed system
echo -e "${BLUE}Creating XDG autostart entries...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/xdg/autostart"

# Ollama autostart (for live environment; installed system uses ollama.service)
sudo tee "${SQUASHFS_ROOTFS}/etc/xdg/autostart/ollama.desktop" > /dev/null << 'EOF'
[Desktop Entry]
Type=Application
Name=Ollama Service
Comment=Start Ollama server for JARVIS
Exec=/usr/local/bin/ollama serve
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=true
EOF
sudo chmod 644 "${SQUASHFS_ROOTFS}/etc/xdg/autostart/ollama.desktop"

# JARVIS autostart — runs in the user session where PipeWire audio is available
sudo tee "${SQUASHFS_ROOTFS}/etc/xdg/autostart/jarvis.desktop" > /dev/null << 'EOF'
[Desktop Entry]
Type=Application
Name=JARVIS AI Assistant
Comment=Start JARVIS voice assistant
Exec=/usr/bin/jarvis-daemon
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=true
X-KDE-autostart-phase=2
EOF
sudo chmod 644 "${SQUASHFS_ROOTFS}/etc/xdg/autostart/jarvis.desktop"

echo -e "${GREEN}✓ XDG autostart entries created${NC}"

# Step 17b: Create JARVIS welcome/first-boot interactive setup script
# This script opens in a terminal on first login after installation.
# It gives the user a friendly onboarding experience: shows progress while
# pulling the AI model, verifies everything works, and shows usage tips.
# The jarvis-setup.service still runs as a systemd fallback, but they
# coordinate via the same /var/lib/jarvis/.setup-done marker.
echo -e "${BLUE}Creating JARVIS welcome script...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/usr/local/bin/jarvis-welcome.sh" > /dev/null << 'WELCOME_EOF'
#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  JARVIS OS — First-Boot Welcome & Setup                        ║
# ║  Opens in a terminal on first login after installation.         ║
# ║  Pulls the AI model, verifies the stack, shows usage tips.     ║
# ╚══════════════════════════════════════════════════════════════════╝

set -euo pipefail

MARKER="/var/lib/jarvis/.setup-done"
LOG="/var/log/jarvis/welcome.log"
AUTOSTART_FILE="${HOME}/.config/autostart/jarvis-welcome.desktop"

# Colours
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# Logging (user sees stdout, we also tee to log)
sudo mkdir -p /var/log/jarvis 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

# ── Helpers ──────────────────────────────────────────────────────────
banner() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "     ██╗ █████╗ ██████╗ ██╗   ██╗██╗███████╗"
    echo "     ██║██╔══██╗██╔══██╗██║   ██║██║██╔════╝"
    echo "     ██║███████║██████╔╝██║   ██║██║███████╗"
    echo "██   ██║██╔══██║██╔══██╗╚██╗ ██╔╝██║╚════██║"
    echo "╚█████╔╝██║  ██║██║  ██║ ╚████╔╝ ██║███████║"
    echo " ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝"
    echo -e "${NC}"
    echo -e "${BOLD}  Welcome to JARVIS OS${NC}"
    echo -e "${DIM}  Your AI-powered operating system${NC}"
    echo ""
    echo -e "${DIM}  ─────────────────────────────────────────────${NC}"
    echo ""
}

step() { echo -e "  ${CYAN}▸${NC} ${BOLD}$1${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

spinner() {
    local pid=$1 msg=$2
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}%s${NC} %s" "${chars:i%${#chars}:1}" "$msg"
        sleep 0.1
        i=$((i + 1))
    done
    printf "\r"
}

# ── Already done? ───────────────────────────────────────────────────
if [ -f "$MARKER" ]; then
    banner
    echo -e "  ${GREEN}Setup already complete!${NC}"
    echo ""
    echo -e "  JARVIS is ready. You can:"
    echo ""
    echo -e "    ${BOLD}jarvis chat${NC}        — Chat with JARVIS in the terminal"
    echo -e "    ${BOLD}jarvis ask \"...\"${NC}   — Ask a quick question"
    echo -e "    ${BOLD}Hey, Jarvis${NC}        — Voice activation (if enabled)"
    echo ""
    # Remove the autostart so this doesn't open again
    rm -f "$AUTOSTART_FILE" 2>/dev/null || true
    echo -e "${DIM}  Press Enter to close...${NC}"
    read -r
    exit 0
fi

# ── Main setup ──────────────────────────────────────────────────────
banner

echo -e "  Setting up your AI assistant. This may take a few minutes"
echo -e "  depending on your internet speed."
echo ""

# 1. Check internet connectivity
step "Checking internet connectivity..."
ONLINE=false
for attempt in $(seq 1 30); do
    if curl -sf --max-time 5 https://ollama.com >/dev/null 2>&1; then
        ONLINE=true
        break
    fi
    if [ $attempt -eq 1 ]; then
        echo -e "    ${DIM}Waiting for network...${NC}"
    fi
    sleep 2
done

if [ "$ONLINE" = true ]; then
    ok "Internet connected"
else
    warn "No internet connection detected"
    echo -e "    ${DIM}JARVIS needs internet to download the AI model.${NC}"
    echo -e "    ${DIM}Connect to WiFi and run: sudo /usr/local/bin/jarvis-welcome.sh${NC}"
    echo ""
    echo -e "${DIM}  Press Enter to close...${NC}"
    read -r
    exit 1
fi

# 2. Wait for Ollama
step "Starting Ollama AI engine..."
OLLAMA_READY=false
for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        OLLAMA_READY=true
        break
    fi
    # Try starting Ollama if it's not running
    if [ $i -eq 1 ]; then
        if ! pgrep -x ollama >/dev/null 2>&1; then
            nohup ollama serve >/dev/null 2>&1 &
        fi
    fi
    sleep 2
done

if [ "$OLLAMA_READY" = true ]; then
    ok "Ollama is running"
else
    fail "Ollama failed to start"
    echo -e "    ${DIM}Try: ollama serve${NC}"
    echo ""
    echo -e "${DIM}  Press Enter to close...${NC}"
    read -r
    exit 1
fi

# 3. Read configured model
MODEL="qwen3:4b"
if [ -f /usr/lib/jarvis/.env ]; then
    ENV_MODEL=$(grep -E '^LLM_MODEL=' /usr/lib/jarvis/.env | cut -d= -f2- || true)
    [ -n "$ENV_MODEL" ] && MODEL="$ENV_MODEL"
fi

# 4. Check if model already downloaded
step "Checking for AI model: ${MODEL}..."
if ollama list 2>/dev/null | grep -q "${MODEL%%:*}"; then
    ok "Model ${MODEL} already available"
else
    echo ""
    echo -e "  ${CYAN}▸${NC} ${BOLD}Downloading AI model: ${MODEL}${NC}"
    echo -e "    ${DIM}This is a one-time download (~2.5 GB)...${NC}"
    echo ""

    # Pull with visible progress
    if ollama pull "$MODEL"; then
        echo ""
        ok "Model downloaded successfully"
    else
        echo ""
        fail "Failed to download model"
        echo -e "    ${DIM}Check your internet and try: ollama pull ${MODEL}${NC}"
        echo ""
        echo -e "${DIM}  Press Enter to close...${NC}"
        read -r
        exit 1
    fi
fi

# 5. Quick verification
step "Verifying JARVIS..."
VERIFY_OK=true

# Check JARVIS CLI
if command -v jarvis >/dev/null 2>&1; then
    ok "JARVIS CLI available"
else
    warn "JARVIS CLI not found in PATH"
    VERIFY_OK=false
fi

# Check voice models
if [ -d /var/lib/jarvis/models/vosk ] && [ -n "$(ls /var/lib/jarvis/models/vosk/ 2>/dev/null)" ]; then
    ok "Voice recognition model installed"
else
    warn "Voice recognition model not found (voice commands disabled)"
fi

if [ -f /var/lib/jarvis/models/piper/en_US-amy-medium.onnx ]; then
    ok "Text-to-speech model installed"
else
    warn "TTS model not found (voice output disabled)"
fi

# 6. Mark setup as done (coordinate with jarvis-setup.service)
sudo touch "$MARKER" 2>/dev/null || touch "$MARKER" 2>/dev/null || true
sudo systemctl disable jarvis-setup.service 2>/dev/null || true

echo ""
echo -e "  ${DIM}─────────────────────────────────────────────${NC}"
echo ""
echo -e "  ${GREEN}${BOLD}Setup complete! JARVIS is ready.${NC}"
echo ""
echo -e "  ${BOLD}How to use JARVIS:${NC}"
echo ""
echo -e "    ${BOLD}jarvis chat${NC}           Open an interactive chat session"
echo -e "    ${BOLD}jarvis ask \"...\"${NC}      Ask a quick question"
echo -e "    ${BOLD}jarvis voice${NC}          Switch to voice output mode"
echo -e "    ${BOLD}jarvis text${NC}           Switch to text output mode"
echo -e "    ${BOLD}jarvis model <name>${NC}   Change the AI model"
echo ""
echo -e "  ${DIM}Voice activation: Say \"Hey, Jarvis\" (if voice recognition enabled)${NC}"
echo -e "  ${DIM}Find JARVIS in the application menu or search for \"JARVIS\"${NC}"
echo ""

# Remove autostart so this doesn't open again
rm -f "$AUTOSTART_FILE" 2>/dev/null || true

echo -e "${DIM}  Press Enter to launch JARVIS chat, or Ctrl+C to close...${NC}"
if read -r -t 60; then
    exec jarvis chat
fi
WELCOME_EOF

sudo chmod 755 "${SQUASHFS_ROOTFS}/usr/local/bin/jarvis-welcome.sh"
echo -e "${GREEN}✓ Welcome script created${NC}"

# Step 17c: Create JARVIS desktop launcher (application menu entry)
echo -e "${BLUE}Creating JARVIS desktop launcher...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/usr/share/applications"
sudo tee "${SQUASHFS_ROOTFS}/usr/share/applications/jarvis.desktop" > /dev/null << 'EOF'
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
sudo chmod 644 "${SQUASHFS_ROOTFS}/usr/share/applications/jarvis.desktop"
echo -e "${GREEN}✓ JARVIS desktop launcher created${NC}"

# Step 18: Cleanup package cache
echo -e "${BLUE}Cleaning up package cache...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Scc --noconfirm 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" sh -c "rm -rf /tmp/* /var/cache/pacman/pkg/*" 2>/dev/null || true

# Cleanup will be handled by trap
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 4 complete: Project-JARVIS installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installed components:${NC}"
echo -e "${BLUE}  - JARVIS code + venv (/usr/lib/jarvis, /var/lib/jarvis/venv)${NC}"
echo -e "${BLUE}  - Ollama (/usr/local/bin/ollama + ollama.service)${NC}"
echo -e "${BLUE}  - dmcp + dispatch (/usr/bin/dmcp, /usr/bin/dispatch)${NC}"
echo -e "${BLUE}  - Vosk STT model (/var/lib/jarvis/models/vosk/)${NC}"
echo -e "${BLUE}  - Piper TTS model (/var/lib/jarvis/models/piper/)${NC}"
echo -e "${BLUE}  - First-boot service (jarvis-setup.service)${NC}"
echo -e "${BLUE}  - Welcome script (/usr/local/bin/jarvis-welcome.sh)${NC}"
echo -e "${BLUE}  - Desktop launcher (jarvis.desktop in applications)${NC}"
echo -e "${BLUE}  - XDG autostart (ollama.desktop, jarvis.desktop)${NC}"
