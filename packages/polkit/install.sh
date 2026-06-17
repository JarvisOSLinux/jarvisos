#!/usr/bin/env bash
# Install JARVIS PolicyKit rules and action definitions.
# Must run as root.
set -euo pipefail

RULES_DIR="/usr/share/polkit-1/rules.d"
ACTIONS_DIR="/usr/share/polkit-1/actions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root" >&2
    exit 1
fi

install -Dm644 "$SCRIPT_DIR/org.jarvisos.jarvis.rules"   "$RULES_DIR/org.jarvisos.jarvis.rules"
install -Dm644 "$SCRIPT_DIR/jarvis-actions.conf"         "$ACTIONS_DIR/org.jarvisos.jarvis.policy"

# Reload polkit to pick up new rules
if command -v pkaction &>/dev/null; then
    pkill -HUP polkitd 2>/dev/null || true
fi

echo "JARVIS PolicyKit rules installed."
