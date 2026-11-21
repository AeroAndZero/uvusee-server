source .venv/bin/activate

comfy --workspace ./comfy stop  # only if an old ComfyUI is still running; an error here is fine
comfy --workspace ./comfy launch --background -- --listen 127.0.0.1 --port 8188

uv run --no-sync uvusee