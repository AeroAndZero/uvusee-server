# syntax=docker/dockerfile:1.7
# Place this file in the root of the uvusee-server repo, then:
#   docker build -t uvusee .
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# CUDA build of PyTorch that ComfyUI installs. 12.8 needs host driver >= 570.
ARG CUDA_VERSION=12.8
# "latest" = latest stable ComfyUI release; pin a version (e.g. 0.3.xx) for reproducible builds.
ARG COMFYUI_VERSION=latest

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    COMFY_VENV=/opt/comfy-venv \
    COMFY_WORKSPACE=/app/comfy \
    COMFY_PORT=8188

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ---------------------------------------------------------------------------
# 1. ComfyUI (heavy layer: torch + CUDA libs). Lives in its own venv so it
#    is cached independently of your code and never fights uv.lock.
#    Equivalent of: comfy --workspace ./comfy install --fast-deps
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv "$COMFY_VENV" \
 && uv pip install --python "$COMFY_VENV/bin/python" comfy-cli \
 && VIRTUAL_ENV="$COMFY_VENV" "$COMFY_VENV/bin/comfy" --skip-prompt \
        --workspace "$COMFY_WORKSPACE" install \
        --nvidia --cuda-version "$CUDA_VERSION" \
        --version "$COMFYUI_VERSION" \
        --fast-deps --skip-manager

# ---------------------------------------------------------------------------
# 2. uvusee dependencies (cached until pyproject.toml / uv.lock change)
#    Equivalent of: uv sync
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    uv sync --locked --no-install-project

# ---------------------------------------------------------------------------
# 3. uvusee source (replaces the git clone step)
# ---------------------------------------------------------------------------
COPY . /app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked

COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh

# Models (~19 GB) are downloaded on first start into this volume, not baked in.
VOLUME ["/app/comfy/models"]

# uvusee's port - change if your server listens elsewhere.
EXPOSE 8000

ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
