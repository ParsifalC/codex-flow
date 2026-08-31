@echo off
if /I "%~1"=="uninstall" goto uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-flow.ps1" %*
exit /b %errorlevel%

:uninstall
set "CODEX_FLOW_DEFER_WINDOWS_CLI_DELETE=1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-flow.ps1" %*
if errorlevel 1 exit /b %errorlevel%
del /q "%~dp0codex-flow.ps1" >nul 2>&1
(goto) 2>nul & del /q "%~f0"
