@echo off
setlocal
cd /d "%~dp0"

set "PWSH="
where pwsh.exe >nul 2>nul && set "PWSH=pwsh.exe"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%USERPROFILE%\Tools\PowerShell\7\pwsh.exe" set "PWSH=%USERPROFILE%\Tools\PowerShell\7\pwsh.exe"
if not defined PWSH (
    echo [ERROR] PowerShell 7 ^(pwsh.exe^) not found. Please install PowerShell 7 first.
    pause
    exit /b 1
)

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1" -PauseOnExit %*
exit /b %ERRORLEVEL%
