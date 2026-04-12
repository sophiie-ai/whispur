#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SCREENSHOT_DIR="$ROOT/docs/screenshots"

mkdir -p "$SCREENSHOT_DIR"

cat <<'EOF'
Screenshot automation is not implemented yet.

Suggested next step:
1. Launch Whispur with representative provider settings.
2. Capture menu bar, onboarding, settings, and about window states.
3. Save the final PNGs into docs/screenshots/.
EOF
