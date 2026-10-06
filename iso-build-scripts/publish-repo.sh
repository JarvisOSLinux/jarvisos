#!/usr/bin/env bash
# publish-repo.sh — Build all JarvisOS packages and publish to Cloudflare R2.
#
# Usage:
#   ./iso-build-scripts/publish-repo.sh [--dry-run] [--skip-build] [--pkg PKG]
#
# Prerequisites:
#   pacman -S rclone base-devel
#   rclone config  (add remote named "r2", type s3, provider Cloudflare)
#
# R2 remote config (~/.config/rclone/rclone.conf):
#   [r2]
#   type = s3
#   provider = Cloudflare
#   access_key_id = <R2_ACCESS_KEY>
#   secret_access_key = <R2_SECRET_KEY>
#   endpoint = https://<ACCOUNT_ID>.r2.cloudflarestorage.com
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

R2_REMOTE="${R2_REMOTE:-r2}"
R2_BUCKET="${R2_BUCKET:-jarvisos-packages}"
REPO_NAME="jarvisos"
ARCH="x86_64"
# Bucket path: repo/$arch/$repo/
R2_PATH="${R2_REMOTE}:${R2_BUCKET}/repo/${ARCH}/${REPO_NAME}"

REPO_DIR="${PROJECT_ROOT}/build/repo/${ARCH}/${REPO_NAME}"
PKGDEST="${REPO_DIR}"

DRY_RUN=0
SKIP_BUILD=0
ONLY_PKG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --pkg)       ONLY_PKG="$2"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

mkdir -p "$REPO_DIR"

# ---------------------------------------------------------------------------
# Package build definitions: name → source dir, extra env
# ---------------------------------------------------------------------------
declare -A PKG_DIRS=(
    [linux-jarvisos]="${PROJECT_ROOT}/packages/linux-jarvisos"
    [jarvisos-mirrorlist]="${PROJECT_ROOT}/packages/jarvisos-mirrorlist"
    [jarvisos-keyring]="${PROJECT_ROOT}/packages/jarvisos-keyring"
    [dmcp]="${PROJECT_ROOT}/dmcp"
    [dispatch-mcp]="${PROJECT_ROOT}/dispatch"
    [project-jarvis]="${PROJECT_ROOT}/Project-JARVIS/packaging"
)

declare -A PKG_ENV=(
    [linux-jarvisos]="KERNEL_SRC=${PROJECT_ROOT}/linux-jarvisos"
    [project-jarvis]="JARVIS_SRC=${PROJECT_ROOT}/Project-JARVIS"
)

build_package() {
    local name="$1"
    local dir="${PKG_DIRS[$name]}"
    local env="${PKG_ENV[$name]:-}"

    echo "==> Building ${name} from ${dir}"
    if [[ ! -f "${dir}/PKGBUILD" ]]; then
        echo "  ERROR: No PKGBUILD at ${dir}" >&2
        return 1
    fi

    local cmd="PKGDEST=${PKGDEST} makepkg --nodeps --nocheck --skipinteg --force --cleanbuild"
    if [[ -n "$env" ]]; then
        cmd="env ${env} ${cmd}"
    fi

    (cd "$dir" && eval "$cmd")
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
if [[ $SKIP_BUILD -eq 0 ]]; then
    if [[ -n "$ONLY_PKG" ]]; then
        build_package "$ONLY_PKG"
    else
        for pkg in "${!PKG_DIRS[@]}"; do
            build_package "$pkg"
        done
    fi
fi

# ---------------------------------------------------------------------------
# Regenerate repo database
# ---------------------------------------------------------------------------
echo "==> Regenerating repo database: ${REPO_NAME}.db"
(
    cd "$REPO_DIR"
    # Remove stale DBs before rebuilding
    rm -f "${REPO_NAME}.db" "${REPO_NAME}.db.tar.gz" \
          "${REPO_NAME}.files" "${REPO_NAME}.files.tar.gz"

    shopt -s nullglob
    pkgs=( *.pkg.tar.zst )
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        echo "  ERROR: No packages found in ${REPO_DIR}" >&2
        exit 1
    fi

    repo-add "${REPO_NAME}.db.tar.gz" "${pkgs[@]}"
)

# ---------------------------------------------------------------------------
# Upload to R2
# ---------------------------------------------------------------------------
echo "==> Uploading to ${R2_PATH}"
rclone_args=(
    sync "$REPO_DIR" "$R2_PATH"
    --include "*.pkg.tar.zst"
    --include "*.pkg.tar.zst.sig"
    --include "*.db"
    --include "*.db.tar.gz"
    --include "*.files"
    --include "*.files.tar.gz"
    --progress
)

if [[ $DRY_RUN -eq 1 ]]; then
    rclone_args+=(--dry-run)
    echo "  (dry run)"
fi

rclone "${rclone_args[@]}"
echo "==> Published: https://packages.jarvisos.org/repo/${ARCH}/${REPO_NAME}/"
