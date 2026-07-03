@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0execute-multi-device-ui-unit-test.ps1" %*
echo.
echo ============================================================
echo execute-multi-device-ui-unit-test finished. (exit code: %errorlevel%)
echo ============================================================
pause
