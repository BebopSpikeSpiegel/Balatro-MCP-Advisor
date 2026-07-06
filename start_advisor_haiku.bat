@echo off
chcp 65001 >nul
title MCP Advisor brain (haiku)
set MCP_MODEL=haiku
"%~dp0.venv\Scripts\python.exe" "%~dp0mcp_brain.py"
echo.
echo (advisor stopped) - press any key to close
pause >nul
