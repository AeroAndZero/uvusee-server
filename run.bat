@echo off
rem run.bat - restart ComfyUI and the uvusee server (after setup.bat install)
cd /d "%~dp0"
call .venv\Scripts\activate.bat

rem stop an old ComfyUI if one is still running; an error here is fine
comfy --workspace .\comfy stop >nul 2>&1
comfy --workspace .\comfy launch --background -- --listen 127.0.0.1 --port 8188

uv run --no-sync uvusee

rem reached when uvusee exits. After Ctrl+C, answer N to "Terminate batch job?" so this runs.
comfy --workspace .\comfy stop
