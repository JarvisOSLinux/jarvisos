#!/usr/bin/env bash
# Exercises install_llama_cpp_arch against a stub pacman: it must report
# [OK] only when llama-server exists afterwards, and exit non-zero otherwise.
# Run: bash iso-build-scripts/tests/test-llama-install.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../tasks"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0

# shellcheck source-path=SCRIPTDIR/../tasks
# shellcheck source=lib.sh
. ./lib.sh
set +e

# $1 = stub pacman exit code; on 0 the stub also "installs" llama-server.
run_case() {
    local vendor="$1" pacman_rc="$2"
    rm -rf "${T:?}/bin" && mkdir -p "$T/bin"
    cat >"$T/bin/pacman" <<EOF
#!/bin/sh
[ "${pacman_rc}" = 0 ] && printf '#!/bin/sh\n' >"$T/bin/llama-server" && $(command -v chmod) +x "$T/bin/llama-server"
exit ${pacman_rc}
EOF
    chmod +x "$T/bin/pacman"
    # PATH holds only the stubs so the host's own llama-server can't leak in.
    (
        set -e
        PATH="$T/bin"
        detect_gpu_vendor() { echo "${vendor}"; }
        install_llama_cpp_arch
    ) >"$T/out" 2>&1
    echo $?
}

expect() {
    local vendor="$1" pacman_rc="$2" want_rc="$3" want_ok="$4" rc has_ok=no
    rc=$(run_case "$vendor" "$pacman_rc")
    grep -q '\[OK\]' "$T/out" && has_ok=yes
    if [[ "$rc" != "$want_rc" || "$has_ok" != "$want_ok" ]]; then
        echo "FAIL: ${vendor} pacman=${pacman_rc} -> rc=${rc} ok=${has_ok}, want rc=${want_rc} ok=${want_ok}"
        sed 's/^/    /' "$T/out"
        fail=1
    fi
}

for vendor in nvidia amd intel-arc cpu; do
    expect "$vendor" 0 0 yes
    expect "$vendor" 1 1 no
done

[[ $fail -eq 0 ]] && echo "all llama install cases pass"
exit $fail
