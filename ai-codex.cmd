:<<"::CMDLITERAL"
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0ai.ps1" --agent=codex %*
exit /b %errorlevel%
::CMDLITERAL
exec pwsh "$(dirname "$0")/ai.ps1" --agent=codex "$@"
