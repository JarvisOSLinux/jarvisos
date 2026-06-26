#!/usr/bin/env bash
# vps-kernel-build.sh — spin up Linode 48-core LA, build linux-jarvisos, fetch ZSTs, destroy.
#
# Usage: bash iso-build-scripts/vps-kernel-build.sh [--keep-vps]
#   --keep-vps  don't delete the Linode after build (debug)
#
# Requires: JARVIS_LINODE_TOKEN in env or ~/.bashrc

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
KEEP_VPS=0
[[ "${1:-}" == "--keep-vps" ]] && KEEP_VPS=1

TOKEN="${JARVIS_LINODE_TOKEN:?JARVIS_LINODE_TOKEN not set — run: source ~/.bashrc first}"

REGION="us-lax"
TYPE="g6-dedicated-48"
IMAGE="linode/arch"
LABEL="jarvisos-kernel-build-$(date +%s)"
ROOT_PASS="$(openssl rand -base64 32)"
SSH_KEY_FILE="/tmp/jarvis-vps-key-$$"
LOG_FILE="/tmp/jarvis-kernel-build-$(date +%Y%m%d-%H%M%S).log"
OUT_DIR="${JARVIS_PKG_OUT:-$(pwd)/build/kernel-pkg}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_REPO="https://github.com/JarvisOSLinux/linux-jarvisos.git"
KERNEL_BRANCH="jarvisos-7.1-stable"

mkdir -p "$OUT_DIR"

linode_api() {
    local method="$1"; shift
    local path="$1"; shift
    curl -fsSL -X "$method" "https://api.linode.com/v4${path}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" "$@"
}

cleanup() {
    local exit_code=$?
    rm -f "$SSH_KEY_FILE" "${SSH_KEY_FILE}.pub"
    if [[ -n "${LINODE_ID:-}" && "$KEEP_VPS" -eq 0 ]]; then
        echo ""
        echo "==> Deleting Linode $LINODE_ID..."
        linode_api DELETE "/linode/instances/$LINODE_ID" >/dev/null 2>&1 || true
        echo "    Linode deleted."
    elif [[ -n "${LINODE_ID:-}" ]]; then
        echo "==> --keep-vps: Linode $LINODE_ID at ${IP:-<pending>} preserved."
    fi
    exit "$exit_code"
}
trap cleanup EXIT

# ── SSH key ──────────────────────────────────────────────────────────────────
ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -q
PUB_KEY="$(cat "${SSH_KEY_FILE}.pub")"

# ── Create Linode ─────────────────────────────────────────────────────────────
echo "==> Creating 48-core dedicated Linode in $REGION..."
RESPONSE=$(linode_api POST "/linode/instances" -d "{
    \"region\": \"$REGION\",
    \"type\": \"$TYPE\",
    \"image\": \"$IMAGE\",
    \"label\": \"$LABEL\",
    \"root_pass\": \"$ROOT_PASS\",
    \"authorized_keys\": [\"$PUB_KEY\"],
    \"booted\": true
}")
LINODE_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "    Linode ID: $LINODE_ID"

# ── Wait for running ──────────────────────────────────────────────────────────
echo "==> Waiting for Linode to reach 'running' state..."
for i in $(seq 1 40); do
    STATUS=$(linode_api GET "/linode/instances/$LINODE_ID" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
    echo "    [$i] status: $STATUS"
    [[ "$STATUS" == "running" ]] && break
    sleep 15
done
[[ "$STATUS" != "running" ]] && { echo "ERROR: Linode never reached running state"; exit 1; }

IP=$(linode_api GET "/linode/instances/$LINODE_ID" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['ipv4'][0])")
echo "    IP: $IP"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
echo "==> Waiting for SSH..."
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes -o UserKnownHostsFile=/dev/null -i "$SSH_KEY_FILE")
for i in $(seq 1 30); do
    ssh "${SSH_OPTS[@]}" root@"$IP" "echo ssh-ok" 2>/dev/null && break
    echo "    [$i] ssh not ready, retrying in 15s..."
    sleep 15
done

# ── Upload PKGBUILD + helpers ─────────────────────────────────────────────────
echo "==> Uploading PKGBUILD, install file, and build script..."

# Write a self-contained build script to upload (avoids heredoc nesting issues)
BUILD_SCRIPT_LOCAL="/tmp/jarvis-remote-build-$$.sh"
cat > "$BUILD_SCRIPT_LOCAL" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "--- [VPS] Updating pacman and installing build deps ---"
pacman -Sy --noconfirm --needed \
    base-devel git bc flex bison openssl libelf pahole python \
    cpio gettext perl tar xz zstd

echo "--- [VPS] Creating build dir and non-root builder user ---"
useradd -m builder 2>/dev/null || true
mkdir -p /build/out /build/src
chown -R builder:builder /build
cp /root/PKGBUILD /build/
cp /root/linux-jarvisos.install /build/

# Write makepkg.conf for the builder
cat > /build/makepkg.conf << 'MKCFG'
CARCH="x86_64"
CHOST="x86_64-pc-linux-gnu"
BUILDENV=(!distcc !color !ccache check !sign)
COMPRESSZST=(zstd -c -z -q --threads=0 -)
PKGEXT='.pkg.tar.zst'
SRCEXT='.src.tar.gz'
MKCFG
chown builder:builder /build/makepkg.conf

# Allow builder to sudo (for pacman if needed inside build)
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

echo "--- [VPS] Cloning linux-jarvisos source (depth=1, ~1-2 GB) ---"
sudo -u builder git clone --depth=1 -b jarvisos-7.1-stable \
    https://github.com/JarvisOSLinux/linux-jarvisos.git \
    /build/linux-jarvisos-src

echo "--- [VPS] Running makepkg with $(nproc) cores ---"
cd /build
JOBS=$(nproc)
sudo -u builder env \
    KERNEL_SRC=/build/linux-jarvisos-src \
    PKGDEST=/build/out \
    SRCDEST=/build/src \
    BUILDDIR=/build \
    MAKEFLAGS="-j${JOBS}" \
    makepkg \
        --config /build/makepkg.conf \
        --nodeps --nocheck --skipinteg --force --ignorearch

echo "--- [VPS] Build done. Packages: ---"
find /build/out -name "*.pkg.tar.zst" -exec ls -lh {} \;
EOF

BUILD_SCRIPT_NAME="$(basename "$BUILD_SCRIPT_LOCAL")"
scp "${SSH_OPTS[@]}" \
    "$REPO_ROOT/packages/linux-jarvisos/PKGBUILD" \
    "$REPO_ROOT/packages/linux-jarvisos/linux-jarvisos.install" \
    "$BUILD_SCRIPT_LOCAL" \
    root@"$IP":/root/
rm -f "$BUILD_SCRIPT_LOCAL"

# ── Remote build ─────────────────────────────────────────────────────────────
echo "==> Starting remote build (logging to $LOG_FILE)..."
ssh "${SSH_OPTS[@]}" root@"$IP" "bash /root/${BUILD_SCRIPT_NAME}" 2>&1 | tee "$LOG_FILE"

# ── Fetch packages ────────────────────────────────────────────────────────────
echo "==> Fetching built packages..."
PKG_PATHS=$(ssh "${SSH_OPTS[@]}" root@"$IP" "find /build/out -name '*.pkg.tar.zst' 2>/dev/null")

if [[ -z "$PKG_PATHS" ]]; then
    echo "ERROR: No .pkg.tar.zst files found on VPS — check $LOG_FILE"
    exit 1
fi

while IFS= read -r pkg; do
    echo "    Copying $pkg..."
    scp "${SSH_OPTS[@]}" "root@${IP}:${pkg}" "$OUT_DIR/"
done <<< "$PKG_PATHS"

echo ""
echo "==> Done! Packages in $OUT_DIR:"
ls -lh "$OUT_DIR/"*.pkg.tar.zst
echo ""
echo "==> Build log: $LOG_FILE"
echo ""
echo "Install with:"
echo "  sudo pacman -U $OUT_DIR/linux-jarvisos-*.pkg.tar.zst $OUT_DIR/linux-jarvisos-headers-*.pkg.tar.zst"
echo "  sudo mkinitcpio -p linux-jarvisos"
echo "  sudo grub-mkconfig -o /boot/grub/grub.cfg   # if using GRUB"
echo "  # or update bootloader entry manually"
