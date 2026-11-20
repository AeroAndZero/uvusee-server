#!/usr/bin/env bash
# uvusee.sh - install and run uvusee-server + ComfyUI (Flux.2 Klein 9B) on a Linux NVIDIA GPU server.
#
#   ./uvusee.sh            install anything that's missing, then start the server
#   ./uvusee.sh install    install only
#   ./uvusee.sh start      start only
#   ./uvusee.sh update     pull the latest uvusee code and re-sync its dependencies
#
# Optional settings (environment variables):
#   UVUSEE_DIR       install location (default: this script's folder if it's the repo, else ~/uvusee-server)
#   REPO_URL         repo to clone    (default: https://github.com/AeroAndZero/uvusee-server.git)
#   HF_TOKEN         Hugging Face token, only if a model repo requires accepting its license
#   COMFY_PORT       ComfyUI port     (default: 8188)
#   CUDA_VERSION     force a PyTorch CUDA build, e.g. 12.8 (default: auto-detected from the driver)
#   COMFYUI_VERSION  ComfyUI release  (default: latest)
#   COMFY_EXTRA_ARGS extra ComfyUI flags, e.g. "--lowvram"
set -euo pipefail
unset VIRTUAL_ENV
export PATH="$HOME/.local/bin:$PATH"   # where the uv installer puts uv

REPO_URL="${REPO_URL:-https://github.com/AeroAndZero/uvusee-server.git}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
if [[ -z "${UVUSEE_DIR:-}" ]]; then
  if [[ -f "$SCRIPT_DIR/pyproject.toml" ]]; then UVUSEE_DIR="$SCRIPT_DIR"; else UVUSEE_DIR="$HOME/uvusee-server"; fi
fi
COMFY_VENV="$UVUSEE_DIR/.comfy-venv"     # ComfyUI gets its own venv so `uv sync` never removes its packages
COMFY_WORKSPACE="$UVUSEE_DIR/comfy"
MODELS="$COMFY_WORKSPACE/models"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFYUI_VERSION="${COMFYUI_VERSION:-latest}"
INSTALLED_MARKER="$COMFY_WORKSPACE/.install-complete"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

run_comfy_at() {  # run_comfy_at <workspace> <comfy args...>
  local ws="$1"; shift
  VIRTUAL_ENV="$COMFY_VENV" "$COMFY_VENV/bin/comfy" --skip-prompt --workspace "$ws" "$@"
}
run_comfy() { run_comfy_at "$COMFY_WORKSPACE" "$@"; }

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
check_prereqs() {
  command -v git  >/dev/null || die "git is not installed. On Ubuntu/Debian: sudo apt-get install -y git"
  command -v curl >/dev/null || die "curl is not installed. On Ubuntu/Debian: sudo apt-get install -y curl"
  command -v nvidia-smi >/dev/null || die "nvidia-smi not found. Install the NVIDIA driver first."
  nvidia-smi >/dev/null 2>&1 || die "nvidia-smi failed: the NVIDIA driver isn't working (reboot after installing it?)."

  local vram_mib
  vram_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 | tr -dc '0-9')"
  if [[ -n "$vram_mib" ]] && (( vram_mib < 20000 )); then
    warn "GPU has $((vram_mib / 1024)) GB VRAM. Flux.2 Klein 9B (fp8) works best with ~24 GB; expect offloading and slower runs."
  fi

  if ! command -v uv >/dev/null; then
    log "Installing uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    command -v uv >/dev/null || die "uv installed but not found on PATH."
  fi
}

check_disk() {
  local parent avail_gb
  parent="$(dirname "$UVUSEE_DIR")"
  mkdir -p "$parent"
  avail_gb=$(( $(df -Pk "$parent" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if (( avail_gb < 40 )); then
    warn "Only ${avail_gb} GB free under $parent. A full install needs about 35-40 GB (models alone are ~19 GB)."
  fi
}

# ---------------------------------------------------------------------------
# Install steps (each one is skipped if already done, so re-running is safe)
# ---------------------------------------------------------------------------
get_code() {
  [[ -f "$UVUSEE_DIR/pyproject.toml" ]] && return 0
  log "Cloning $REPO_URL into $UVUSEE_DIR"
  git clone "$REPO_URL" "$UVUSEE_DIR"
}

sync_app() {
  log "Installing uvusee dependencies (uv sync)"
  cd "$UVUSEE_DIR"
  if [[ -f uv.lock ]]; then uv sync --frozen; else uv sync; fi
}

install_comfy() {
  [[ -f "$INSTALLED_MARKER" ]] && return 0
  if [[ -e "$COMFY_WORKSPACE" ]]; then
    die "$COMFY_WORKSPACE already exists but wasn't installed by this script. Move it away (keep models/ if you want to reuse them) and re-run."
  fi

  log "Installing ComfyUI (downloads PyTorch + CUDA libraries, several GB)"
  rm -rf "$COMFY_VENV"
  uv venv --python 3.12 "$COMFY_VENV"
  uv pip install --python "$COMFY_VENV/bin/python" comfy-cli

  # Install into a temporary folder and rename it only when it succeeds,
  # so an interrupted install never leaves a half-working ComfyUI behind.
  local tmp="$COMFY_WORKSPACE.partial"
  rm -rf "$tmp"
  local args=(install --nvidia --fast-deps --skip-manager --version "$COMFYUI_VERSION")
  if [[ -n "${CUDA_VERSION:-}" ]]; then args+=(--cuda-version "$CUDA_VERSION"); fi
  # Run from a scratch dir: comfy-cli drops helper files (override.txt) in the current folder.
  local scratch
  scratch="$(mktemp -d)"
  (cd "$scratch" && run_comfy_at "$tmp" "${args[@]}")
  rm -rf "$scratch"

  touch "$tmp/.install-complete"
  mv "$tmp" "$COMFY_WORKSPACE"
}

fetch_model() {  # fetch_model <hf-repo> <path-in-repo> <destination>
  local repo="$1" src="$2" dest="$3"
  if [[ -s "$dest" ]]; then
    log "Model present: ${dest#"$MODELS"/}"
    return 0
  fi
  local auth=()
  if [[ -n "${HF_TOKEN:-}" ]]; then auth=(-H "Authorization: Bearer ${HF_TOKEN}"); fi

  mkdir -p "$(dirname "$dest")"
  log "Downloading ${repo}/${src}"
  # -C - resumes a partial download if the script was interrupted
  if ! curl -fL --retry 5 --retry-delay 10 -C - "${auth[@]}" \
         -o "${dest}.part" "https://huggingface.co/${repo}/resolve/main/${src}"; then
    die "Download failed. If it's a 401/403, accept the model license on huggingface.co and re-run with HF_TOKEN=<your token>."
  fi
  mv "${dest}.part" "$dest"
}

download_models() {
  fetch_model black-forest-labs/FLUX.2-klein-9b-kv-fp8 \
              flux-2-klein-9b-kv-fp8.safetensors \
              "$MODELS/diffusion_models/flux-2-klein-9b-kv-fp8.safetensors"
  fetch_model Comfy-Org/Flux-2-Klein-9B \
              split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors \
              "$MODELS/text_encoders/qwen_3_8b_fp8mixed.safetensors"
  fetch_model Comfy-Org/Flux-2-Klein-9B \
              split_files/vae/flux2-vae.safetensors \
              "$MODELS/vae/flux2-vae.safetensors"
}

install_all() {
  check_prereqs
  check_disk
  get_code
  sync_app
  install_comfy
  download_models
  log "Install complete."
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
start() {
  [[ -f "$INSTALLED_MARKER" ]] || die "Not installed yet. Run: $0 install"
  cd "$UVUSEE_DIR"

  run_comfy stop >/dev/null 2>&1 || true   # clear a ComfyUI left over from a previous run
  trap 'log "Stopping ComfyUI"; run_comfy stop >/dev/null 2>&1 || true' EXIT
  trap 'exit 130' INT TERM

  local extra=()
  read -ra extra <<< "${COMFY_EXTRA_ARGS:-}"
  log "Starting ComfyUI on 127.0.0.1:${COMFY_PORT}"
  run_comfy launch --background -- --listen 127.0.0.1 --port "$COMFY_PORT" "${extra[@]}"
  log "ComfyUI log: $COMFY_WORKSPACE/user/comfyui_${COMFY_PORT}.log"

  log "Starting uvusee (Ctrl+C to stop)"
  uv run --no-sync uvusee
}

update() {
  [[ -d "$UVUSEE_DIR/.git" ]] || die "$UVUSEE_DIR is not a git checkout."
  log "Pulling latest code"
  git -C "$UVUSEE_DIR" pull --ff-only
  sync_app
  log "Updated. Restart with: $0 start"
}

case "${1:-}" in
  "")      install_all; start ;;
  install) install_all ;;
  start)   start ;;
  update)  update ;;
  *)       sed -n '3,7p' "$0"; exit 1 ;;
esac