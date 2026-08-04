#!/bin/bash
# Install JARVIS OS components on a RHEL/Fedora-based system.
# No kernel install — JARVIS runs on the stock kernel.
#
# Required env vars:
#   JARVIS_MODEL  — e.g. "qwen3:4b"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

need_root

JARVIS_MODEL="${JARVIS_MODEL:-qwen3:4b}"

trap 'echo "JARVIS RHEL overlay failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# Detect package manager: dnf (Fedora 22+, RHEL 8+) or yum (RHEL 7, CentOS 7)
if command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
else
    die "No supported package manager found (tried dnf, yum)."
fi

# ── Ensure deps ────────────────────────────────────────────────────────────
info "Updating package index..."
${PKG} -y update --quiet || warn "Package update had issues — continuing"

info "Installing required host tools..."
${PKG} -y install \
    dialog curl wget git python3 python3-pip python3-devel \
    gcc make pkgconfig portaudio-devel unzip \
    || warn "Some host tool packages failed"

# ── Base utilities ────────────────────────────────────────────────────────
info "Installing base utilities..."
${PKG} -y install \
    sudo nano vim wget curl git openssh-clients man-db \
    unzip zip rsync tzdata bash-completion lsof htop \
    || warn "Some base packages failed"
ok "Base utilities installed"

# ── KDE Plasma ────────────────────────────────────────────────────────────
info "Installing KDE Plasma Wayland..."
${PKG} -y groupinstall "KDE Plasma Workspaces" 2>/dev/null || \
    ${PKG} -y install \
        plasma-desktop sddm \
        plasma-nm plasma-pa \
        konsole dolphin kate \
        xdg-user-dirs xdg-desktop-portal \
        || warn "Some KDE packages failed — desktop may be incomplete"
ok "KDE Plasma installed"

# ── PipeWire ──────────────────────────────────────────────────────────────
info "Installing PipeWire audio..."
${PKG} -y install \
    pipewire pipewire-pulseaudio wireplumber alsa-utils \
    || warn "Some audio packages failed"
ok "PipeWire installed"

# ── GPU drivers ───────────────────────────────────────────────────────────
info "Installing GPU drivers..."
${PKG} -y install \
    mesa-dri-drivers mesa-vulkan-drivers \
    || warn "Some GPU packages failed"
ok "GPU drivers installed"

# ── Network ───────────────────────────────────────────────────────────────
info "Installing network tools..."
${PKG} -y install NetworkManager wpa_supplicant \
    || warn "Some network packages failed"
ok "Network tools installed"

# ── Python + JARVIS deps ──────────────────────────────────────────────────
info "Installing Python + JARVIS system dependencies..."
${PKG} -y install \
    python3 python3-pip python3-devel python3-setuptools \
    gcc make pkgconfig portaudio-devel \
    || warn "Some Python packages failed"
ok "Python dependencies installed"

# ── JARVIS OS branding ────────────────────────────────────────────────────
info "Applying JARVIS OS branding..."
if [ -f /etc/os-release ] && ! grep -q '^ID=jarvisos' /etc/os-release 2>/dev/null; then
    _orig_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    sed -i "s|^ID=.*|ID=jarvisos|" /etc/os-release 2>/dev/null || true
    grep -q '^ID_LIKE=' /etc/os-release \
        && sed -i "s|^ID_LIKE=.*|ID_LIKE=${_orig_id}|" /etc/os-release \
        || echo "ID_LIKE=${_orig_id}" >> /etc/os-release
    grep -q '^PRETTY_NAME=' /etc/os-release \
        && sed -i 's|^PRETTY_NAME=.*|PRETTY_NAME="JARVIS OS"|' /etc/os-release \
        || echo 'PRETTY_NAME="JARVIS OS"' >> /etc/os-release
fi
ok "JARVIS OS branding applied"

# ── Ollama ────────────────────────────────────────────────────────────────
info "Installing Ollama..."
if command -v ollama >/dev/null 2>&1; then
    ok "Ollama already installed ($(ollama --version 2>/dev/null || echo unknown))"
else
    info "Installing Ollama via official install script..."
    curl -fsSL https://ollama.com/install.sh | sh \
        || die "Ollama install failed — check network connectivity"
    ok "Ollama installed"
fi

# ── JARVIS user + directories ─────────────────────────────────────────────
info "Setting up JARVIS user and directories..."
getent group  jarvis >/dev/null 2>&1 || groupadd -r jarvis
getent passwd jarvis >/dev/null 2>&1 || \
    useradd -r -g jarvis -d /var/lib/jarvis -s /sbin/nologin \
            -c 'JARVIS AI Assistant' jarvis
for grp in audio video network systemd-journal; do
    getent group "${grp}" >/dev/null 2>&1 && \
        usermod -aG "${grp}" jarvis 2>/dev/null || true
done
mkdir -p /usr/lib/jarvis \
         /var/lib/jarvis/models/piper \
         /var/lib/jarvis/models/vosk \
         /var/log/jarvis \
         /etc/jarvis
chown jarvis:jarvis /etc/jarvis
chmod 2775 /etc/jarvis
chown -R jarvis:jarvis /var/lib/jarvis /var/log/jarvis
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
        warn "Could not clone Project-JARVIS — install JARVIS code manually"
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
    local _inst_model="${JARVIS_MODEL:-qwen3:4b}"
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

# ── sudoers ───────────────────────────────────────────────────────────────
cat > /etc/sudoers.d/10-jarvis << 'SUDOERS_EOF'
Defaults:jarvis !requiretty, !lecture, passwd_tries=0
jarvis ALL=(ALL) NOPASSWD: \
    /usr/bin/dnf,            \
    /usr/bin/yum,            \
    /usr/bin/systemctl,      \
    /usr/bin/journalctl,     \
    /usr/bin/nmcli,          \
    /usr/bin/timedatectl,    \
    /usr/bin/localectl,      \
    /usr/bin/hostnamectl,    \
    /usr/bin/modprobe,       \
    /usr/bin/sysctl,         \
    /usr/bin/mkdir
SUDOERS_EOF
chmod 440 /etc/sudoers.d/10-jarvis

# ── Systemd services ──────────────────────────────────────────────────────
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
SupplementaryGroups=audio video network systemd-journal
WorkingDirectory=/usr/lib/jarvis
RuntimeDirectory=jarvis
RuntimeDirectoryMode=0775
ExecStart=/usr/bin/jarvis-daemon
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30
PrivateTmp=yes
LimitNOFILE=65536
Environment=JARVIS_CONFIG_DIR=/etc/jarvis
Environment=JARVIS_DATA_DIR=/var/lib/jarvis
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
[ "${AUTO_PULL}" = "false" ] && { touch "$MARKER"; exit 0; }
echo "Waiting for Ollama..."
for i in $(seq 1 60); do
    curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break; sleep 2
done
ollama list 2>/dev/null | grep -q "${MODEL%%:*}" || ollama pull "$MODEL" || exit 1
touch "$MARKER"
echo "First-boot complete."
FIRSTBOOT
chmod 755 /usr/local/bin/jarvis-first-boot.sh

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
ok "Systemd service units installed"

# ── Enable services ────────────────────────────────────────────────────────
info "Enabling systemd services..."
systemctl daemon-reload 2>/dev/null || true
systemctl enable ollama.service          2>/dev/null || true
systemctl enable jarvis.service          2>/dev/null || true
systemctl enable jarvis-setup.service    2>/dev/null || true
systemctl enable NetworkManager.service  2>/dev/null || true
systemctl enable sddm.service            2>/dev/null || true
ok "Services enabled"

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
        warn "Vosk download failed"
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
        warn "Piper download failed"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}  JARVIS OS components installed (RHEL/Fedora).${NC}"
echo ""
