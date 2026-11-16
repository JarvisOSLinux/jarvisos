#!/usr/bin/env bash
# Checks the shared RAM-to-model table in lib.sh (used by jarvis-install.sh,
# install-jarvis.sh and test-jarvis.sh): the thresholds, and that every model
# it recommends is in JARVIS_MODEL_MENU so the installer can star it.
# Run: bash iso-build-scripts/tests/test-model-table.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../tasks"

# shellcheck source-path=SCRIPTDIR/../tasks
# shellcheck source=lib.sh
. ./lib.sh
fail=0

expect() {
    local mb="$1" want="$2" got i in_menu=no
    got=$(jarvis_recommended_model "$mb")
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: ${mb} MiB -> ${got}, want ${want}"
        fail=1
    fi
    for (( i = 0; i < ${#JARVIS_MODEL_MENU[@]}; i += 2 )); do
        [[ "${JARVIS_MODEL_MENU[i]}" == "$got" ]] && in_menu=yes
    done
    if [[ "$in_menu" != yes ]]; then
        echo "FAIL: ${got} (for ${mb} MiB) is not in JARVIS_MODEL_MENU"
        fail=1
    fi
}

expect 2048  "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M"
expect 3999  "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M"
expect 4000  "${JARVIS_DEFAULT_MODEL}"
expect 7999  "${JARVIS_DEFAULT_MODEL}"
expect 8000  "Qwen/Qwen3-8B-GGUF:Q4_K_M"
expect 15999 "Qwen/Qwen3-8B-GGUF:Q4_K_M"
expect 16000 "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q4_K_M"
expect 65536 "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q4_K_M"

[[ "$(jarvis_recommended_model)" == "$(jarvis_recommended_model \
    "$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)")" ]] \
    || { echo "FAIL: no-argument call does not use MemTotal"; fail=1; }

[[ $fail -eq 0 ]] && echo "all model table cases pass"
exit $fail
