@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0execute-ui-unit-test.ps1" %*
echo.
echo ============================================================
echo execute-ui-unit-test finished. (exit code: %errorlevel%)
echo ============================================================
pause
