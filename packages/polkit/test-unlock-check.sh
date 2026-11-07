#!/usr/bin/env bash
# Exercises jarvis-unlock-check in a user namespace where the caller's own
# files count as root-owned. Run: bash test-unlock-check.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ $EUID -ne 0 ]]; then
    exec unshare -Ur bash "$0" "$@"
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
now=$(date +%s)
fail=0

printf '%s alice\n' $((now + 600)) >"$T/open"
printf '%s alice\n' $((now - 5)) >"$T/expired"
printf '%s bob\n' $((now + 600)) >"$T/bob"
printf '%s alice\n' $((now + 600)) >"$T/loose"; chmod 666 "$T/loose"
printf 'junk\n' >"$T/junk"
ln -s "$T/open" "$T/link"

expect() {
    local want="$1" user="$2" file="$3" rc=0
    ./jarvis-unlock-check "$user" "$file" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" != "$want" ]]; then
        echo "FAIL: $user $(basename "$file") -> $rc, want $want"
        fail=1
    fi
}

expect 0 alice "$T/open"
expect 0 bob "$T/bob"
expect 1 alice "$T/expired"
expect 1 alice "$T/bob"
expect 1 bob "$T/open"
expect 1 alice "$T/loose"
expect 1 alice "$T/link"
expect 1 alice "$T/junk"
expect 1 alice "$T/missing"
expect 1 "" "$T/open"

[[ $fail -eq 0 ]] && echo "all unlock-check cases pass"
exit $fail
