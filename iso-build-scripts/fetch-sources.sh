#!/usr/bin/env bash
# Clone the sibling repos listed in sources.conf into the repo root.
# Usage: fetch-sources.sh [name...]   (no names = all)
# An existing checkout is never modified. Exits non-zero if a clone fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${ROOT}/sources.conf"
[[ -f "$CONF" ]] || { echo "fetch-sources: ${CONF} not found" >&2; exit 1; }

command -v git &>/dev/null || { echo "fetch-sources: git not found" >&2; exit 1; }

want=("$@")
status=0
while read -r name url branch; do
    [[ -z "${name:-}" || "$name" == \#* ]] && continue
    if (( ${#want[@]} )); then
        match=0
        for w in "${want[@]}"; do [[ "$w" == "$name" ]] && match=1; done
        (( match )) || continue
    fi
    dest="${ROOT}/${name}"
    if [[ -e "${dest}/.git" ]]; then
        continue
    fi
    if [[ -d "$dest" && -n "$(ls -A "$dest")" ]]; then
        echo "fetch-sources: ${dest} exists and is not a git checkout; leaving it" >&2
        status=1
        continue
    fi
    echo "fetch-sources: cloning ${name} (${branch})..."
    git clone --depth 1 -b "$branch" "$url" "$dest" || status=1
done < "$CONF"
exit "$status"
