#!/usr/bin/env bash
# =============================================================================
# test-jarvis.sh — JarvisOS Experience Launcher
#
# Bootstraps everything needed and launches the JARVIS autonomous agent:
#   1. Install system deps (portaudio, python venv)
#   2. Create Python venv + install vosk / pyaudio / requests
#   3. Download Vosk small English model (~45 MB) if not present
#   4. Start llama-server (downloads the GGUF model on first run)
#   5. Launch jarvis_agent.py — voice + text autonomous agent
#
# Usage:
#   ./test-jarvis.sh
#   JARVIS_MODEL=Qwen/Qwen3-8B-GGUF:Q4_K_M ./test-jarvis.sh
#   LLM_URL=http://192.168.1.10:11445 ./test-jarvis.sh   # use a running server
# =============================================================================

set -euo pipefail

LLM_URL="${LLM_URL:-http://127.0.0.1:11445}"
JARVIS_MODEL="${JARVIS_MODEL:-}"
JARVIS_DIR="${HOME}/.local/share/jarvis"
VENV_DIR="${JARVIS_DIR}/venv"
VOSK_DIR="${JARVIS_DIR}/vosk-model-small"
VOSK_ZIP="${JARVIS_DIR}/vosk-model-small.zip"
VOSK_URL="https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SCRIPT="${SCRIPT_DIR}/jarvis_agent.py"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
PRP='\033[0;35m'

die()  { echo -e "${RED}[FATAL]${RESET} $*" >&2; exit 1; }
info() { echo -e "${CYN}[INFO]${RESET}  $*"; }
ok()   { echo -e "${GRN}[ OK ]${RESET}  $*"; }
warn() { echo -e "${YEL}[WARN]${RESET}  $*"; }
step() { echo -e "\n${BOLD}${PRP}▶ $*${RESET}"; }

echo -e "${BOLD}${PRP}"
cat <<'BANNER'
     ██╗ █████╗ ██████╗ ██╗   ██╗██╗███████╗      ██████╗ ███████╗
     ██║██╔══██╗██╔══██╗██║   ██║██║██╔════╝     ██╔═══██╗██╔════╝
     ██║███████║██████╔╝██║   ██║██║███████╗     ██║   ██║███████╗
██   ██║██╔══██║██╔══██╗╚██╗ ██╔╝██║╚════██║     ██║   ██║╚════██║
╚█████╔╝██║  ██║██║  ██║ ╚████╔╝ ██║███████║     ╚██████╔╝███████║
 ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝      ╚═════╝ ╚══════╝
                     JarvisOS Experience Launcher
BANNER
echo -e "${RESET}"

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ -f "$AGENT_SCRIPT" ]] || die "jarvis_agent.py not found at ${AGENT_SCRIPT}"
command -v python3 &>/dev/null || die "python3 not found"
command -v curl    &>/dev/null || die "curl not found"

# ── Step 1: System packages ───────────────────────────────────────────────────
step "System Dependencies"

MISSING_PKGS=()
pacman -Qi portaudio    &>/dev/null || MISSING_PKGS+=(portaudio)
pacman -Qi python-pip   &>/dev/null || MISSING_PKGS+=(python-pip)
pacman -Qi unzip        &>/dev/null || MISSING_PKGS+=(unzip)

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    info "Installing: ${MISSING_PKGS[*]}"
    sudo pacman -S --noconfirm --needed "${MISSING_PKGS[@]}"
fi
ok "System packages ready"

# ── Step 2: Python venv + packages ───────────────────────────────────────────
step "Python Environment"

mkdir -p "$JARVIS_DIR"

if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    info "Creating venv at ${VENV_DIR}"
    python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

MISSING_PY=()
python3 -c "import vosk"     2>/dev/null || MISSING_PY+=(vosk)
python3 -c "import pyaudio"  2>/dev/null || MISSING_PY+=(pyaudio)
python3 -c "import requests" 2>/dev/null || MISSING_PY+=(requests)

if [[ ${#MISSING_PY[@]} -gt 0 ]]; then
    info "Installing Python packages: ${MISSING_PY[*]}"
    pip install --quiet --upgrade "${MISSING_PY[@]}"
fi

# Check what actually loaded
VOSK_OK=false
VOICE_OK=false
python3 -c "import vosk, pyaudio" 2>/dev/null && VOSK_OK=true && VOICE_OK=true

ok "Python environment ready"
if $VOICE_OK; then
    ok "Voice support: Vosk + PyAudio available"
else
    warn "Voice support: unavailable (vosk/pyaudio missing) — text-only mode"
fi

# ── Step 3: Vosk model ────────────────────────────────────────────────────────
step "Vosk Speech Model"

if $VOICE_OK; then
    if [[ ! -d "$VOSK_DIR" ]]; then
        info "Downloading Vosk small English model (~45 MB)..."
        curl -L --progress-bar -o "$VOSK_ZIP" "$VOSK_URL" \
            || { warn "Download failed — voice disabled"; VOICE_OK=false; }

        if $VOICE_OK; then
            info "Extracting model..."
            cd "$JARVIS_DIR"
            unzip -q "$VOSK_ZIP"
            # The zip extracts to vosk-model-small-en-us-0.15/
            local_extracted=$(ls -d "${JARVIS_DIR}"/vosk-model-small-en-us-* 2>/dev/null | head -1)
            if [[ -n "$local_extracted" ]]; then
                mv "$local_extracted" "$VOSK_DIR"
                rm -f "$VOSK_ZIP"
                ok "Vosk model ready at ${VOSK_DIR}"
            else
                warn "Could not find extracted model directory — voice disabled"
                VOICE_OK=false
            fi
        fi
    else
        ok "Vosk model already present"
    fi
else
    info "Skipping Vosk model download (voice unavailable)"
fi

# ── Step 4: llama-server + model ──────────────────────────────────────────────
step "Local LLM (llama.cpp)"

if ! curl -sf --max-time 3 "${LLM_URL}/health" &>/dev/null; then
    [[ "$LLM_URL" == http://127.0.0.1:* || "$LLM_URL" == http://localhost:* ]] \
        || die "No LLM server answering at ${LLM_URL}"

    if ! command -v llama-server &>/dev/null; then
        info "Installing llama-cpp..."
        sudo pacman -S --noconfirm --needed llama-cpp ggml-vulkan || die "llama-cpp install failed"
    fi

    if [[ -z "$JARVIS_MODEL" ]]; then
        MEM_AVAIL_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
        if (( MEM_AVAIL_MB > 20000 )); then
            JARVIS_MODEL="Qwen/Qwen3-8B-GGUF:Q4_K_M"
        else
            JARVIS_MODEL="Qwen/Qwen3-4B-GGUF:Q4_K_M"
        fi
    fi

    LLM_PORT="${LLM_URL##*:}"
    LLM_LOG="${JARVIS_DIR}/llama-server.log"
    mkdir -p "$JARVIS_DIR"
    info "Starting llama-server for ${BOLD}${JARVIS_MODEL}${RESET} (first run downloads the model)"
    LLAMA_CACHE="${JARVIS_DIR}/models" setsid nohup llama-server \
        -hf "$JARVIS_MODEL" --alias "$JARVIS_MODEL" --host 127.0.0.1 \
        --port "$LLM_PORT" -ngl 999 --jinja >"$LLM_LOG" 2>&1 &
    echo $! > "${JARVIS_DIR}/llama-server.pid"

    for _ in $(seq 1 450); do
        curl -sf --max-time 3 "${LLM_URL}/health" &>/dev/null && break
        kill -0 "$(cat "${JARVIS_DIR}/llama-server.pid")" 2>/dev/null \
            || die "llama-server exited — see ${LLM_LOG}"
        sleep 2
    done
    curl -sf --max-time 3 "${LLM_URL}/health" &>/dev/null \
        || die "llama-server not ready after 15 min — see ${LLM_LOG}"
fi
ok "LLM server is up at ${LLM_URL}"

if [[ -z "$JARVIS_MODEL" ]]; then
    JARVIS_MODEL=$(curl -sf "${LLM_URL}/v1/models" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || true)
fi
[[ -z "$JARVIS_MODEL" ]] && die "Could not determine the served model."
ok "Active model: ${BOLD}${JARVIS_MODEL}${RESET}"

# ── Step 5: Launch agent in a new terminal window ────────────────────────────
step "Launching JARVIS Agent"
echo ""

VOSK_PATH=""
$VOICE_OK && VOSK_PATH="$VOSK_DIR"

export LLM_URL JARVIS_MODEL VOSK_MODEL_PATH="$VOSK_PATH"

# Build the command the new terminal will run.
# Keep the window open on exit so the user can read the last output.
AGENT_CMD="export LLM_URL='${LLM_URL}' JARVIS_MODEL='${JARVIS_MODEL}' VOSK_MODEL_PATH='${VOSK_PATH}'; \
source '${VENV_DIR}/bin/activate'; \
python3 '${AGENT_SCRIPT}'; \
echo; read -rp 'Press Enter to close…'"

# Detect the user's preferred or available terminal emulator.
# Respects \$TERMINAL env var first, then tries common ones in order.
find_terminal() {
    # Explicit override
    if [[ -n "${TERMINAL:-}" ]] && command -v "${TERMINAL}" &>/dev/null; then
        echo "$TERMINAL"; return
    fi
    # KDE
    command -v konsole       &>/dev/null && { echo konsole;       return; }
    # Common alternatives
    command -v alacritty     &>/dev/null && { echo alacritty;     return; }
    command -v kitty         &>/dev/null && { echo kitty;         return; }
    command -v wezterm       &>/dev/null && { echo wezterm;       return; }
    command -v xfce4-terminal &>/dev/null && { echo xfce4-terminal; return; }
    command -v gnome-terminal &>/dev/null && { echo gnome-terminal; return; }
    command -v tilix         &>/dev/null && { echo tilix;         return; }
    command -v xterm         &>/dev/null && { echo xterm;         return; }
    echo ""
}

TERM_BIN=$(find_terminal)

if [[ -z "$TERM_BIN" ]]; then
    warn "No terminal emulator found — running in this terminal."
    echo ""
    source "${VENV_DIR}/bin/activate"
    exec python3 "$AGENT_SCRIPT"
fi

info "Opening JARVIS in: ${BOLD}${TERM_BIN}${RESET}"
echo ""

case "$TERM_BIN" in
    konsole)
        exec konsole \
            --title "JARVIS — JarvisOS Agent" \
            --profile "JARVIS" \
            -e bash -c "$AGENT_CMD" \
            2>/dev/null || \
        exec konsole --title "JARVIS — JarvisOS Agent" \
            -e bash -c "$AGENT_CMD"
        ;;
    alacritty)
        exec alacritty --title "JARVIS — JarvisOS Agent" \
            -e bash -c "$AGENT_CMD"
        ;;
    kitty)
        exec kitty --title "JARVIS — JarvisOS Agent" \
            bash -c "$AGENT_CMD"
        ;;
    wezterm)
        exec wezterm start --title "JARVIS — JarvisOS Agent" \
            -- bash -c "$AGENT_CMD"
        ;;
    xfce4-terminal)
        exec xfce4-terminal --title "JARVIS — JarvisOS Agent" \
            -e "bash -c '$AGENT_CMD'"
        ;;
    gnome-terminal)
        exec gnome-terminal --title "JARVIS — JarvisOS Agent" \
            -- bash -c "$AGENT_CMD"
        ;;
    tilix)
        exec tilix -t "JARVIS — JarvisOS Agent" \
            -e "bash -c '$AGENT_CMD'"
        ;;
    xterm)
        exec xterm -T "JARVIS — JarvisOS Agent" \
            -fa "Monospace" -fs 12 \
            -bg "#0d0d1a" -fg "#c8c8ff" \
            -e bash -c "$AGENT_CMD"
        ;;
    *)
        exec "$TERM_BIN" -e bash -c "$AGENT_CMD"
        ;;
esac
