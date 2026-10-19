#!/usr/bin/env bash
# Clone the sibling repos listed in sources.conf into the repo root, each at the
# commit recorded in versions.lock.
#
# Usage: fetch-sources.sh [name...]     fetch (no names = all)
#        fetch-sources.sh --update-lock rewrite versions.lock from the branch heads
#
# JARVIS_SOURCES_FLOAT=1 ignores the lock and takes the branch head instead.
# An existing checkout is never modified. Exits non-zero if a fetch fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${ROOT}/sources.conf"
LOCK="${ROOT}/versions.lock"
[[ -f "$CONF" ]] || { echo "fetch-sources: ${CONF} not found" >&2; exit 1; }

command -v git &>/dev/null || { echo "fetch-sources: git not found" >&2; exit 1; }

entries() { grep -v '^[[:space:]]*\(#\|$\)' "$CONF"; }

if [[ "${1:-}" == "--update-lock" ]]; then
    tmp="$(mktemp)"
    {
        echo "# Pinned sibling-repo commits, read by iso-build-scripts/fetch-sources.sh."
        echo "# Updated by .github/workflows/track-subsystems.yml when a repo pushes, or by"
        echo "# fetch-sources.sh --update-lock."
        while read -r name url branch; do
            sha="$(git ls-remote "$url" "refs/heads/${branch}" "refs/tags/${branch}^{}" "refs/tags/${branch}" \
                | awk 'NR==1{print $1}')"
            [[ -n "$sha" ]] || { echo "fetch-sources: cannot resolve ${name} ${branch}" >&2; exit 1; }
            echo "${name}=${sha}"
        done < <(entries)
    } > "$tmp"
    mv "$tmp" "$LOCK"
    echo "fetch-sources: wrote ${LOCK}"
    exit 0
fi

locked() { [[ -f "$LOCK" ]] && sed -n "s/^${1}=\([0-9a-f]\{40\}\)\$/\1/p" "$LOCK" | head -1; }

want=("$@")
status=0
while read -r name url branch; do
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
    sha=""
    [[ "${JARVIS_SOURCES_FLOAT:-0}" == "1" ]] || sha="$(locked "$name")"
    if [[ -n "$sha" ]]; then
        echo "fetch-sources: ${name} at ${sha:0:7} (versions.lock)..."
        if ! { git init -q "$dest" \
            && git -C "$dest" remote add origin "$url" \
            && git -C "$dest" fetch -q --depth 1 origin "$sha" \
            && git -C "$dest" checkout -q FETCH_HEAD; }; then
            echo "fetch-sources: could not fetch ${name} at ${sha}" >&2
            rm -rf "$dest"
            status=1
        fi
    else
        echo "fetch-sources: ${name} at ${branch} head..."
        git clone -q --depth 1 -b "$branch" "$url" "$dest" || status=1
    fi
done < <(entries)
exit "$status"
