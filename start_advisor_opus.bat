@echo off
chcp 65001 >nul
title MCP Advisor brain (opus)
set MCP_MODEL=opus
"%~dp0.venv\Scripts\python.exe" "%~dp0mcp_brain.py"
echo.
echo (advisor stopped) - press any key to close
pause >nul
