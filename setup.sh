#!/usr/bin/env bash
# setup.sh - install and run uvusee-server + ComfyUI (Flux.2 Klein 9B) on a Linux NVIDIA GPU server.
#
#   ./setup.sh            install anything that's missing, then start the server
#   ./setup.sh install    install only
#   ./setup.sh start      start only
#   ./setup.sh update     pull the latest uvusee code and re-sync its dependencies
#
# Run it from the repo folder, or from the folder you want the repo cloned into.
# Everything is logged to uvusee-setup.log in the folder you run it from.
#
# Optional settings (environment variables):
#   UVUSEE_DIR       install location (default: current folder if it's the repo, else ./uvusee-server)
#   REPO_URL         repo to clone    (default: https://github.com/AeroAndZero/uvusee-server.git)
#   HF_TOKEN         Hugging Face token, if a model repo requires accepting its license
#   COMFY_PORT       ComfyUI port     (default: 8188)
#   UVUSEE_CUDA_VERSION  force a PyTorch CUDA build, e.g. 12.8 (default: auto-detected from the driver)
#   COMFYUI_VERSION  ComfyUI release  (default: latest)
#   COMFY_EXTRA_ARGS extra ComfyUI flags, e.g. "--lowvram"
#   MIN_FREE_GB      minimum free disk space required to install (default: 40)

# Must be executed, not sourced: `set -e` + `exit` inside your own shell would close the SSH session.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Run this as ./setup.sh (or: bash setup.sh), not with 'source'." >&2
  return 1
fi

set -euo pipefail
exec 3>&1 4>&2   # keep the terminal; install output is also copied to the log
unset VIRTUAL_ENV
export PATH="$HOME/.local/bin:$PATH"   # where the uv installer puts uv

REPO_URL="${REPO_URL:-https://github.com/AeroAndZero/uvusee-server.git}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$PWD/uvusee-setup.log"

is_repo() { [[ -f "$1/pyproject.toml" ]] && grep -qE '^name *= *"uvusee' "$1/pyproject.toml"; }

if [[ -z "${UVUSEE_DIR:-}" ]]; then
  if   is_repo "$PWD";        then UVUSEE_DIR="$PWD"
  elif is_repo "$SCRIPT_DIR"; then UVUSEE_DIR="$SCRIPT_DIR"
  else                             UVUSEE_DIR="$PWD/uvusee-server"
  fi
fi
UVUSEE_DIR="$(realpath -m "$UVUSEE_DIR")"

# Pin uvusee's venv to <repo>/.venv, whatever the host image has configured for uv.
export UV_PROJECT_ENVIRONMENT="$UVUSEE_DIR/.venv"
COMFY_VENV="$UVUSEE_DIR/.comfy-venv"     # ComfyUI gets its own venv so `uv sync` never removes its packages
COMFY_WORKSPACE="$UVUSEE_DIR/comfy"
MODELS="$COMFY_WORKSPACE/models"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFYUI_VERSION="${COMFYUI_VERSION:-latest}"
MIN_FREE_GB="${MIN_FREE_GB:-40}"
INSTALLED_MARKER="$COMFY_WORKSPACE/.install-complete"

# repo | file in repo | destination
MODEL_FILES=(
  "black-forest-labs/FLUX.2-klein-9b-kv-fp8|flux-2-klein-9b-kv-fp8.safetensors|diffusion_models/flux-2-klein-9b-kv-fp8.safetensors"
  "Comfy-Org/Flux-2-Klein-9B|split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors|text_encoders/qwen_3_8b_fp8mixed.safetensors"
  "Comfy-Org/Flux-2-Klein-9B|split_files/vae/flux2-vae.safetensors|vae/flux2-vae.safetensors"
)
HF_AUTH=()
if [[ -n "${HF_TOKEN:-}" ]]; then HF_AUTH=(-H "Authorization: Bearer ${HF_TOKEN}"); fi

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

run_comfy_at() {  # run_comfy_at <workspace> <comfy args...>
  local ws="$1"; shift
  VIRTUAL_ENV="$COMFY_VENV" "$COMFY_VENV/bin/comfy" --no-json --skip-prompt --workspace "$ws" "$@"
}
run_comfy() { run_comfy_at "$COMFY_WORKSPACE" "$@"; }

# ---------------------------------------------------------------------------
# Checks (all run before anything is downloaded)
# ---------------------------------------------------------------------------
check_prereqs() {
  command -v git  >/dev/null || die "git is not installed. On Ubuntu/Debian: sudo apt-get install -y git"
  command -v curl >/dev/null || die "curl is not installed. On Ubuntu/Debian: sudo apt-get install -y curl"
  command -v nvidia-smi >/dev/null || die "nvidia-smi not found. Install the NVIDIA driver first."
  nvidia-smi >/dev/null 2>&1 || die "nvidia-smi failed: the NVIDIA driver isn't working."

  local vram_mib
  vram_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 | tr -dc '0-9')"
  if [[ -n "$vram_mib" ]] && (( vram_mib < 20000 )); then
    warn "GPU has $((vram_mib / 1024)) GB VRAM. Flux.2 Klein 9B (fp8) works best with ~24 GB; expect offloading."
  fi

  if ! command -v uv >/dev/null; then
    log "Installing uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    command -v uv >/dev/null || die "uv installed but not found on PATH."
  fi
}

check_disk() {
  [[ -f "$INSTALLED_MARKER" ]] && return 0   # already installed; only models may be missing
  local parent avail_gb
  parent="$(dirname "$UVUSEE_DIR")"
  mkdir -p "$parent"
  avail_gb=$(( $(df -Pk "$parent" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  log "Free disk space under $parent: ${avail_gb} GB"
  if (( avail_gb < MIN_FREE_GB )); then
    die "Not enough disk: ${avail_gb} GB free, need ~${MIN_FREE_GB} GB (PyTorch/CUDA ~10 GB, models ~19 GB, cache). On vast.ai the disk size is fixed when the instance is created, so create one with a larger disk. Override with MIN_FREE_GB=<n> if you're sure."
  fi
}

check_model_access() {  # fail in seconds instead of after a 10-minute install
  local entry repo src dest code
  for entry in "${MODEL_FILES[@]}"; do
    IFS='|' read -r repo src dest <<< "$entry"
    [[ -s "$MODELS/$dest" ]] && continue
    code="$(curl -sL -o /dev/null -w '%{http_code}' -r 0-0 "${HF_AUTH[@]}" \
              "https://huggingface.co/${repo}/resolve/main/${src}" || true)"
    case "$code" in
      200|206) ;;
      401|403) die "No access to ${repo} (HTTP $code). Accept its license on huggingface.co/${repo} and re-run with HF_TOKEN=<your token>." ;;
      *)       die "Can't reach ${repo}/${src} (HTTP ${code:-none}). Check the server's internet connection." ;;
    esac
  done
  log "Model downloads reachable"
}

# ---------------------------------------------------------------------------
# Install steps (each one is skipped if already done, so re-running is safe)
# ---------------------------------------------------------------------------
get_code() {
  is_repo "$UVUSEE_DIR" && return 0
  [[ -e "$UVUSEE_DIR" ]] && die "$UVUSEE_DIR exists but isn't the uvusee repo."
  log "Cloning $REPO_URL into $UVUSEE_DIR"
  git clone "$REPO_URL" "$UVUSEE_DIR"
}

sync_app() {
  log "Installing uvusee dependencies into $UV_PROJECT_ENVIRONMENT"
  cd "$UVUSEE_DIR"
  if [[ -f uv.lock ]]; then uv sync --frozen; else uv sync; fi
}

install_comfy() {
  [[ -f "$INSTALLED_MARKER" ]] && return 0
  if [[ -e "$COMFY_WORKSPACE" ]]; then
    die "$COMFY_WORKSPACE already exists but wasn't installed by this script. Move it away (keep models/ if you want to reuse them) and re-run."
  fi

  log "Installing ComfyUI into $COMFY_VENV (PyTorch + CUDA libraries, several GB)"
  rm -rf "$COMFY_VENV"
  uv venv --python 3.12 "$COMFY_VENV"
  uv pip install --python "$COMFY_VENV/bin/python" comfy-cli

  # Install into a temporary folder and rename it only when it succeeds,
  # so an interrupted install never leaves a half-working ComfyUI behind.
  local tmp="$COMFY_WORKSPACE.partial"
  rm -rf "$tmp"
  local args=(install --nvidia --fast-deps --skip-manager --version "$COMFYUI_VERSION")
  # Not $CUDA_VERSION: NVIDIA/vast.ai images already set that (e.g. 13.2.1) for the toolkit.
  if [[ -n "${UVUSEE_CUDA_VERSION:-}" ]]; then
    local maj min
    IFS=. read -r maj min _ <<< "$UVUSEE_CUDA_VERSION"   # comfy-cli wants major.minor, e.g. 12.8
    args+=(--cuda-version "${maj}.${min:-0}")
  fi
  # Run from a scratch dir: comfy-cli drops helper files (override.txt) in the current folder.
  local scratch
  scratch="$(mktemp -d)"
  (cd "$scratch" && run_comfy_at "$tmp" "${args[@]}")
  rm -rf "$scratch"

  touch "$tmp/.install-complete"
  mv "$tmp" "$COMFY_WORKSPACE"
  log "ComfyUI installed"
}

download_models() {
  local entry repo src dest
  for entry in "${MODEL_FILES[@]}"; do
    IFS='|' read -r repo src dest <<< "$entry"
    dest="$MODELS/$dest"
    if [[ -s "$dest" ]]; then
      log "Model present: ${dest#"$MODELS"/}"
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    log "Downloading ${repo}/${src}"
    # -C - resumes a partial download if the script was interrupted
    curl -fL --retry 5 --retry-delay 10 -C - "${HF_AUTH[@]}" \
         -o "${dest}.part" "https://huggingface.co/${repo}/resolve/main/${src}" \
      || die "Download of ${repo}/${src} failed; re-run to resume."
    mv "${dest}.part" "$dest"
  done
}

install_all() {
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "$(date '+%F %T') - installing into $UVUSEE_DIR (log: $LOG_FILE)"
  check_prereqs
  check_disk
  check_model_access
  get_code
  sync_app
  install_comfy
  download_models
  log "Install complete in $UVUSEE_DIR"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
start() {
  [[ -f "$INSTALLED_MARKER" ]] || die "Not installed in $UVUSEE_DIR yet. Run: $0 install"
  exec 1>&3 2>&4   # server output goes to the terminal, not the install log
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
  PYTHONUNBUFFERED=1 uv run --no-sync uvusee
}

update() {
  is_repo "$UVUSEE_DIR" || die "$UVUSEE_DIR is not the uvusee repo."
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