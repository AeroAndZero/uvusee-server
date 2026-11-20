#!/usr/bin/env bash
set -euo pipefail

MODELS="${COMFY_WORKSPACE}/models"

# ---------------------------------------------------------------------------
# 1. Download Flux.2 Klein 9B files if they are not already in the volume
# ---------------------------------------------------------------------------
auth=()
if [[ -n "${HF_TOKEN:-}" ]]; then
  auth=(-H "Authorization: Bearer ${HF_TOKEN}")
fi

fetch() {  # fetch <hf-repo> <path-in-repo> <destination>
  local repo="$1" src="$2" dest="$3"
  if [[ -s "$dest" ]]; then
    echo "[models] ok: ${dest#"$MODELS"/}"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  echo "[models] downloading ${repo}/${src}"
  # -C - resumes a partial .part file if the container was stopped mid-download
  curl -fL --retry 5 --retry-delay 10 -C - "${auth[@]}" \
       -o "${dest}.part" "https://huggingface.co/${repo}/resolve/main/${src}"
  mv "${dest}.part" "$dest"
}

fetch black-forest-labs/FLUX.2-klein-9b-kv-fp8 \
      flux-2-klein-9b-kv-fp8.safetensors \
      "$MODELS/diffusion_models/flux-2-klein-9b-kv-fp8.safetensors"

fetch Comfy-Org/Flux-2-Klein-9B \
      split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors \
      "$MODELS/text_encoders/qwen_3_8b_fp8mixed.safetensors"

fetch Comfy-Org/Flux-2-Klein-9B \
      split_files/vae/flux2-vae.safetensors \
      "$MODELS/vae/flux2-vae.safetensors"

# ---------------------------------------------------------------------------
# 2. Start ComfyUI headless (comfy launch --background)
# ---------------------------------------------------------------------------
# Drop the PID comfy-cli recorded on a previous run of this container;
# container PIDs get reused, so a stale entry can block the launch.
rm -f "${HOME}/.config/comfy-cli/config.ini"

VIRTUAL_ENV="$COMFY_VENV" "$COMFY_VENV/bin/comfy" --skip-prompt \
  --workspace "$COMFY_WORKSPACE" launch --background \
  -- --listen 127.0.0.1 --port "$COMFY_PORT"

# Background mode writes ComfyUI output to a file; mirror it to `docker logs`.
tail -n +1 -F "${COMFY_WORKSPACE}/user/comfyui_${COMFY_PORT}.log" 2>/dev/null \
  | sed -u 's/^/[comfyui] /' &

# ---------------------------------------------------------------------------
# 3. Run the uvusee server in the foreground (uv run uvusee)
# ---------------------------------------------------------------------------
exec uv run --no-sync uvusee "$@"
