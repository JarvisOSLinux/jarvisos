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

# Timed unlock for root MCP tools (Project-JARVIS#310): `sudo jarvis-unlock 4h`
install -Dm644 "$SCRIPT_DIR/49-jarvis-unlock.rules"      "$RULES_DIR/49-jarvis-unlock.rules"
install -Dm755 "$SCRIPT_DIR/jarvis-unlock-check"         /usr/lib/jarvis/jarvis-unlock-check
install -Dm755 "$SCRIPT_DIR/jarvis-unlock"               /usr/bin/jarvis-unlock

# Reload polkit to pick up new rules
if command -v pkaction &>/dev/null; then
    pkill -HUP polkitd 2>/dev/null || true
fi

echo "JARVIS PolicyKit rules installed."
