#!/bin/bash
# execute-ui-unit-test.command — macOS Finder double-click wrapper.
# Mirrors execute-ui-unit-test.bat on Windows. Forwards all arguments to execute-ui-unit-test.sh.
# First-time setup on macOS:  chmod +x execute-ui-unit-test.command execute-ui-unit-test.sh

DIR="$(cd "$(dirname "$0")" && pwd)"
SH="$DIR/execute-ui-unit-test.sh"

if [ ! -f "$SH" ]; then
  echo "ERROR: execute-ui-unit-test.sh not found next to this file ($DIR)" >&2
  echo "Press Enter to close..."; read -r
  exit 1
fi
[ -x "$SH" ] || chmod +x "$SH" 2>/dev/null

# Run in place so output stays in this Terminal window.
/bin/bash "$SH" "$@"
rc=$?

# Keep the window open after finishing (double-click friendliness).
echo ""
echo "============================================================"
echo "execute-ui-unit-test finished. (exit code: $rc)"
echo "============================================================"
echo "Press Enter to close..."
read -r
