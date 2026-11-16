#!/bin/bash
# Shared helpers for jarvis-install task scripts.
# Source this at the top of every task script.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

die()  { echo -e "${RED}FATAL: $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}=>${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Require root or die
need_root() {
    [ "$(id -u)" -eq 0 ] || die "Must run as root."
}

# Detect Arch-based distro or die
detect_arch_based() {
    local id="" id_like=""
    if [ -f /etc/os-release ]; then
        id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        id_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    case "${id}" in
        arch|manjaro|endeavouros|garuda|cachyos|artix|parabola|arcolinux|jarvisos) return 0 ;;
    esac
    [[ "${id_like}" == *arch* ]] && return 0
    die "Not an Arch-based system (ID=${id:-unknown}, ID_LIKE=${id_like:-unknown})."
}

# Detect GPU vendor: nvidia | amd | intel-arc | cpu
detect_gpu_vendor() {
    if lspci 2>/dev/null | grep -qi 'nvidia' || lsmod 2>/dev/null | grep -q '^nvidia '; then
        echo "nvidia"; return
    fi
    if lsmod 2>/dev/null | grep -q '^amdgpu ' || \
       lspci 2>/dev/null | grep -qi 'radeon\|amdgpu\|Advanced Micro Devices.*Navi\|Advanced Micro Devices.*Ellesmere\|Advanced Micro Devices.*Polaris'; then
        echo "amd"; return
    fi
    if lspci 2>/dev/null | grep -qi 'Intel.*Arc\|Arc.*Graphics\|Intel.*Alchemist\|Intel.*Battlemage'; then
        echo "intel-arc"; return
    fi
    echo "cpu"
}

# Find JARVIS source: prints path or "installed"
find_jarvis_source() {
    [ -f /usr/lib/jarvis/main.py ] && echo "installed" && return 0
    local _src; _src="${BASH_SOURCE[1]}"
    [ -z "${_src}" ] && _src="${BASH_SOURCE[0]}"
    local script_dir; script_dir="$(cd "$(dirname "${_src}")" && pwd)"
    local try="${script_dir}/../../../Project-JARVIS"
    [ -f "${try}/jarvis/main.py" ] && echo "$(realpath "${try}")" && return 0
    echo ""
    return 1
}

# Required env vars check
require_env() {
    local missing=()
    for v in "$@"; do
        local _val="${!v}"
        [ -n "${_val}" ] || missing+=("${v}")
    done
    [ ${#missing[@]} -eq 0 ] || die "Required env vars not set: ${missing[*]}"
}

# ── Local LLM runner (llama-server, managed by the JARVIS daemon) ──────────
# Models are Hugging Face GGUF references: user/repo[:quant]
JARVIS_DEFAULT_MODEL="Qwen/Qwen3-4B-GGUF:Q4_K_M"

# Model menu offered by the installer and the welcome script: id, label pairs
JARVIS_MODEL_MENU=(
    "${JARVIS_DEFAULT_MODEL}"                          "Qwen3 4B     — balanced quality  (~2.6 GB)"
    "Qwen/Qwen3-8B-GGUF:Q4_K_M"                        "Qwen3 8B     — better quality    (~5.2 GB)"
    "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M"      "Llama 3.2 3B — lightweight       (~2.0 GB)"
    "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q4_K_M" "Llama 3.1 8B — high quality      (~4.9 GB)"
    "ggml-org/gemma-3-4b-it-GGUF:Q4_K_M"               "Gemma 3 4B   — Google model      (~3.3 GB)"
)

# Model to recommend for this much RAM in MiB (default: this machine's MemTotal)
jarvis_recommended_model() {
    local ram_mb="${1:-$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)}"
    if   [ "${ram_mb}" -ge 16000 ]; then echo "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q4_K_M"
    elif [ "${ram_mb}" -ge  8000 ]; then echo "Qwen/Qwen3-8B-GGUF:Q4_K_M"
    elif [ "${ram_mb}" -ge  4000 ]; then echo "${JARVIS_DEFAULT_MODEL}"
    else                                 echo "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M"
    fi
}

# Model of the first llama.cpp provider in /etc/jarvis/providers.json, or nothing.
# The generated first-boot and welcome scripts embed it with declare -f.
jarvis_configured_model() {
    python3 -c 'import json
p = json.load(open("/etc/jarvis/providers.json"))["providers"]
print(next((x["model"] for x in p if x.get("type") == "llamacpp"), ""))' 2>/dev/null || true
}

# Run the jarvis CLI as the service user (embedded in the welcome scripts)
as_jarvis() {
    sudo -u jarvis env JARVIS_CONFIG_DIR=/etc/jarvis JARVIS_DATA_DIR=/var/lib/jarvis \
        JARVIS_MODELS_DIR=/var/lib/jarvis/models /usr/bin/jarvis "$@"
}

# Keep only characters valid in a model reference
sanitize_model() { tr -cd '[:alnum:]:./_-' | head -c 128; }

# Write /etc/jarvis/providers.json with one local provider, unless the user
# already has a provider pool. "none" writes nothing.
write_jarvis_providers() {
    local spec="$1" f=/etc/jarvis/providers.json
    [ -z "${spec}" ] || [ "${spec}" = "none" ] && return 0
    [ -f "${f}" ] && return 0
    mkdir -p /etc/jarvis
    printf '{\n  "providers": [\n    {"name": "local", "type": "llamacpp", "model": "%s"}\n  ]\n}\n' \
        "${spec}" > "${f}"
    chown jarvis:jarvis "${f}" 2>/dev/null || true
}

# First-boot unit + script: pull the chat and embedding models as the jarvis
# user. A failed pull leaves no marker, so the next boot retries.
install_jarvis_first_boot() {
    cat > /usr/lib/systemd/system/jarvis-setup.service << 'SETUPSVC'
[Unit]
Description=JARVIS First-Boot Setup (pull LLM models)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/jarvis/.setup-done

[Service]
Type=oneshot
User=jarvis
Group=jarvis
ExecStart=/usr/local/bin/jarvis-first-boot.sh
RemainAfterExit=yes
TimeoutStartSec=3600
Environment=JARVIS_CONFIG_DIR=/etc/jarvis
Environment=JARVIS_DATA_DIR=/var/lib/jarvis
Environment=JARVIS_LOG_DIR=/var/log/jarvis
Environment=JARVIS_MODELS_DIR=/var/lib/jarvis/models
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SETUPSVC

    {
        echo '#!/bin/bash'
        declare -f jarvis_configured_model
        cat << 'FIRSTBOOT'
MARKER="/var/lib/jarvis/.setup-done"
LOG="/var/log/jarvis/first-boot.log"
mkdir -p /var/log/jarvis
exec > >(tee -a "$LOG") 2>&1
echo "=== JARVIS first-boot $(date) ==="
[ -f "$MARKER" ] && echo "Already done." && exit 0

MODEL=$(jarvis_configured_model)
EMBED=$(grep -E '^EMBED_MODEL=' /usr/lib/jarvis/.env 2>/dev/null | cut -d= -f2- || true)
[ -z "$EMBED" ] && EMBED="nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0"

for spec in "$MODEL" "$EMBED"; do
    [ -z "$spec" ] && continue
    echo "Pulling $spec ..."
    /usr/bin/jarvis model pull "$spec" || { echo "Pull failed: $spec"; exit 1; }
done
touch "$MARKER"
echo "First-boot complete."
FIRSTBOOT
    } > /usr/local/bin/jarvis-first-boot.sh
    chmod 755 /usr/local/bin/jarvis-first-boot.sh
}

# GPU-aware llama.cpp install (Arch): backend packages per vendor
install_llama_cpp_arch() {
    local gpu backend; gpu=$(detect_gpu_vendor)
    info "GPU detected: ${gpu} — selecting llama.cpp backend"
    case "${gpu}" in
        nvidia)
            backend="CUDA backend"
            pacman -S --noconfirm --needed llama-cpp ggml-cuda nvidia-dkms nvidia-utils dkms cuda \
                || warn "Some NVIDIA/CUDA packages failed" ;;
        amd)
            backend="Vulkan backend (AMD)"
            pacman -S --noconfirm --needed llama-cpp ggml-vulkan vulkan-radeon \
                || warn "Some AMD Vulkan packages failed" ;;
        intel-arc)
            backend="Vulkan backend (Intel Arc)"
            pacman -S --noconfirm --needed llama-cpp ggml-vulkan vulkan-intel \
                intel-compute-runtime level-zero-loader \
                || warn "Some Intel Arc packages failed" ;;
        *)
            backend="CPU mode"
            pacman -S --noconfirm --needed llama-cpp || warn "llama-cpp install failed" ;;
    esac
    command -v llama-server >/dev/null 2>&1 \
        || die "llama-server not found after installing llama-cpp — see pacman output above"
    ok "llama.cpp installed (${backend})"
}

# llama.cpp on non-Arch distros: distro package if one exists, otherwise a
# CPU build from source into /usr/local (llama-server only).
# Usage: install_llama_cpp_generic apt|dnf
install_llama_cpp_generic() {
    local mgr="$1" pkg=() deps=()
    command -v llama-server >/dev/null 2>&1 && { ok "llama-server already installed"; return 0; }
    case "${mgr}" in
        apt) pkg=(apt-get install -y llama.cpp)
             deps=(apt-get install -y git cmake build-essential libssl-dev) ;;
        dnf) pkg=(dnf install -y llama-cpp)
             deps=(dnf install -y git cmake gcc-c++ make openssl-devel) ;;
    esac
    "${pkg[@]}" 2>/dev/null || true
    command -v llama-server >/dev/null 2>&1 && { ok "llama-server installed from distro package"; return 0; }

    info "No llama.cpp package available — building llama-server from source..."
    "${deps[@]}" || die "Could not install llama.cpp build dependencies"
    local src; src=$(mktemp -d)
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "${src}" \
        || die "Could not clone llama.cpp"
    cmake -S "${src}" -B "${src}/build" -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_SERVER=ON -DCMAKE_INSTALL_PREFIX=/usr/local \
        && cmake --build "${src}/build" --target llama-server -j"$(nproc)" \
        && cmake --install "${src}/build" \
        || die "llama.cpp build failed"
    rm -rf "${src}"
    command -v llama-server >/dev/null 2>&1 || die "llama-server not found after build"
    ok "llama-server built from source"
}
