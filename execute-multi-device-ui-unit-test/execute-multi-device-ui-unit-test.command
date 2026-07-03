#!/bin/bash
# execute-multi-device-ui-unit-test.command — macOS Finder double-click wrapper.
# Mirrors execute-multi-device-ui-unit-test.bat on Windows. Forwards all arguments to execute-multi-device-ui-unit-test.sh.
#
# 首次使用（任选其一）：
#   chmod +x execute-multi-device-ui-unit-test.command execute-multi-device-ui-unit-test.sh
#   或者直接： bash execute-multi-device-ui-unit-test.command
#       （本脚本会自动给自身与同目录 .sh 加执行权限，之后即可双击运行）

# 自动给自身与同目录 .sh 加执行权限（首次用 bash 调用后，下次即可双击 / ./ 直接执行）
chmod +x "$0" 2>/dev/null

DIR="$(cd "$(dirname "$0")" && pwd)"
SH="$DIR/execute-multi-device-ui-unit-test.sh"

if [ ! -f "$SH" ]; then
  echo "ERROR: execute-multi-device-ui-unit-test.sh not found next to this file ($DIR)" >&2
  echo "Press Enter to close..."; read -r
  exit 1
fi
chmod +x "$SH" 2>/dev/null

# Run in place so output stays in this Terminal window.
/bin/bash "$SH" "$@"
rc=$?

# Keep the window open after finishing (double-click friendliness).
echo ""
echo "============================================================"
echo "execute-multi-device-ui-unit-test finished. (exit code: $rc)"
echo "============================================================"
echo "Press Enter to close..."
read -r
