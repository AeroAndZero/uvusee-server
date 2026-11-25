@echo off
rem setup.bat - set up and run uvusee-server + ComfyUI (Flux.2 Klein 9B) on Windows with an NVIDIA GPU.
rem
rem   setup.bat            install anything that's missing, then start the server
rem   setup.bat install    install only
rem   setup.bat start      start only
rem   setup.bat update     git pull, then re-sync packages (uvusee first, then ComfyUI's)
rem
rem Run it from the repo folder, or from the folder you want the repo cloned into.
rem
rem Steps (same as steps.txt):
rem   1. git clone the repo
rem   2. call .venv\Scripts\activate.bat
rem   3. uv sync                    (installs uvusee + comfy-cli from uv.lock into .venv)
rem   4. comfy --workspace .\comfy install --fast-deps   (ComfyUI's packages go into the same .venv)
rem   5. download Flux.2 Klein 9B model files into comfy\models\...
rem   6. comfy launch --background, then uv run uvusee
rem
rem Optional settings - set them before running, e.g.   set HF_TOKEN=hf_xxx
rem   UVUSEE_DIR           install location (default: current folder if it's the repo, else .\uvusee-server)
rem   REPO_URL             repo to clone    (default: https://github.com/AeroAndZero/uvusee-server.git)
rem   HF_TOKEN             Hugging Face token, if a model repo requires accepting its license
rem   COMFY_PORT           ComfyUI port     (default: 8188)
rem   COMFY_EXTRA_ARGS     extra ComfyUI flags, e.g. --lowvram
rem   COMFYUI_VERSION      ComfyUI version for comfy install, e.g. latest (default: comfy-cli's default)
rem   UVUSEE_CUDA_VERSION  force a PyTorch CUDA build, e.g. 12.8 (default: auto-detected from the driver)

setlocal EnableExtensions DisableDelayedExpansion

set "VIRTUAL_ENV="
set "PATH=%USERPROFILE%\.local\bin;%PATH%"
if not defined REPO_URL set "REPO_URL=https://github.com/AeroAndZero/uvusee-server.git"
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

if defined UVUSEE_DIR goto :have_dir
call :is_repo "%CD%" && (set "UVUSEE_DIR=%CD%" & goto :have_dir)
call :is_repo "%SCRIPT_DIR%" && (set "UVUSEE_DIR=%SCRIPT_DIR%" & goto :have_dir)
set "UVUSEE_DIR=%CD%\uvusee-server"
:have_dir
for %%I in ("%UVUSEE_DIR%") do set "UVUSEE_DIR=%%~fI"

set "VENV=%UVUSEE_DIR%\.venv"
rem always <repo>\.venv, whatever else is configured for uv
set "UV_PROJECT_ENVIRONMENT=%VENV%"
set "COMFY_WORKSPACE=%UVUSEE_DIR%\comfy"
set "MODELS=%COMFY_WORKSPACE%\models"
if not defined COMFY_PORT set "COMFY_PORT=8188"
set "INSTALLED_MARKER=%COMFY_WORKSPACE%\.uvusee-install-complete"
set "HF_AUTH="
if defined HF_TOKEN set HF_AUTH=-H "Authorization: Bearer %HF_TOKEN%"

if "%~1"=="" goto :cmd_all
if /i "%~1"=="install" goto :cmd_install
if /i "%~1"=="start" goto :cmd_start
if /i "%~1"=="update" goto :cmd_update
echo Usage: setup.bat [install^|start^|update]
exit /b 1

:cmd_all
call :install_all || exit /b 1
call :start
exit /b %errorlevel%

:cmd_install
call :install_all
exit /b %errorlevel%

:cmd_start
call :start
exit /b %errorlevel%

:cmd_update
call :update
exit /b %errorlevel%


rem ---------------------------------------------------------------------------
rem Helpers
rem ---------------------------------------------------------------------------
:log
echo ==^> %~1
exit /b 0

:fail
>&2 echo [error] %~1
exit /b 1

:is_repo
if not exist "%~1\pyproject.toml" exit /b 1
findstr /r /b /c:"name *= *\"uvusee\"" "%~1\pyproject.toml" >nul 2>&1
exit /b %errorlevel%

rem Step 2: activate .venv. comfy-cli needs VIRTUAL_ENV set: without it, it creates a second venv in comfy\.venv.
:activate_venv
if not exist "%VENV%\Scripts\activate.bat" (call :fail "%VENV% doesn't exist yet. Run: setup.bat install" & exit /b 1)
call "%VENV%\Scripts\activate.bat"
where comfy >nul 2>&1 || (call :fail "comfy-cli is missing from %VENV% - it should come from pyproject.toml. Run: setup.bat update" & exit /b 1)
exit /b 0

:comfy_cmd
comfy --no-json --skip-prompt --workspace "%COMFY_WORKSPACE%" %*
exit /b %errorlevel%


rem ---------------------------------------------------------------------------
rem Checks (all run before anything is downloaded)
rem ---------------------------------------------------------------------------
:check_prereqs
where git >nul 2>&1 || (call :fail "git is not installed. Get it from https://git-scm.com/download/win" & exit /b 1)
where curl >nul 2>&1 || (call :fail "curl.exe not found - it ships with Windows 10 and later." & exit /b 1)
where nvidia-smi >nul 2>&1 || (call :fail "nvidia-smi not found. Install the NVIDIA driver first." & exit /b 1)
nvidia-smi >nul 2>&1 || (call :fail "nvidia-smi failed: the NVIDIA driver isn't working." & exit /b 1)

set "VRAM_MIB="
for /f "usebackq tokens=1 delims=, " %%V in (`nvidia-smi --query-gpu^=memory.total --format^=csv^,noheader^,nounits`) do if not defined VRAM_MIB set "VRAM_MIB=%%V"
if defined VRAM_MIB if %VRAM_MIB% LSS 20000 echo [warn] GPU has under 20 GB VRAM. Flux.2 Klein 9B ^(fp8^) works best with ~24 GB; expect offloading.

where uv >nul 2>&1 && exit /b 0
call :log "Installing uv"
powershell -NoProfile -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
where uv >nul 2>&1 || (call :fail "uv installed but not found on PATH. Open a new terminal and re-run." & exit /b 1)
exit /b 0

rem Fail in seconds instead of after the long install
:check_model_access
call :check_one "black-forest-labs/FLUX.2-klein-9b-kv-fp8" "flux-2-klein-9b-kv-fp8.safetensors" "diffusion_models\flux-2-klein-9b-kv-fp8.safetensors" || exit /b 1
call :check_one "Comfy-Org/Flux-2-Klein-9B" "split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors" "text_encoders\qwen_3_8b_fp8mixed.safetensors" || exit /b 1
call :check_one "Comfy-Org/Flux-2-Klein-9B" "split_files/vae/flux2-vae.safetensors" "vae\flux2-vae.safetensors" || exit /b 1
call :log "Model downloads reachable"
exit /b 0

:check_one
if exist "%MODELS%\%~3" exit /b 0
set "CODE=000"
for /f %%C in ('curl -sL -o NUL -w "%%{http_code}" -r 0-0 %HF_AUTH% "https://huggingface.co/%~1/resolve/main/%~2"') do set "CODE=%%C"
if "%CODE%"=="200" exit /b 0
if "%CODE%"=="206" exit /b 0
if "%CODE%"=="401" goto :check_one_denied
if "%CODE%"=="403" goto :check_one_denied
call :fail "Can't reach %~1/%~2 (HTTP %CODE%). Check the internet connection."
exit /b 1
:check_one_denied
call :fail "No access to %~1 (HTTP %CODE%). Accept its license on huggingface.co/%~1, then: set HF_TOKEN=your_token and re-run."
exit /b 1


rem ---------------------------------------------------------------------------
rem Install steps (each is skipped if already done, so re-running is safe)
rem ---------------------------------------------------------------------------
rem 1. git clone
:step_clone
call :is_repo "%UVUSEE_DIR%" && exit /b 0
if exist "%UVUSEE_DIR%" (call :fail "%UVUSEE_DIR% exists but isn't the uvusee repo." & exit /b 1)
call :log "Cloning %REPO_URL% into %UVUSEE_DIR%"
git clone "%REPO_URL%" "%UVUSEE_DIR%" || exit /b 1
exit /b 0

rem 3. uv sync. --inexact: never remove packages that aren't in uv.lock (that's all of ComfyUI's, incl. PyTorch)
:uv_sync
cd /d "%UVUSEE_DIR%" || exit /b 1
set "UV_ARGS=sync"
if exist uv.lock set "UV_ARGS=%UV_ARGS% --frozen"
if not exist .python-version set "UV_ARGS=%UV_ARGS% --python 3.12"
uv %UV_ARGS% --inexact
exit /b %errorlevel%

rem 4. comfy install --fast-deps. On an existing comfy folder this skips the clone and only (re)installs packages.
:comfy_install
set "COMFY_ARGS=install --nvidia --restore --fast-deps"
if defined COMFYUI_VERSION set "COMFY_ARGS=%COMFY_ARGS% --version %COMFYUI_VERSION%"
rem comfy-cli wants major.minor, e.g. 12.8
if defined UVUSEE_CUDA_VERSION (
  for /f "tokens=1,2 delims=." %%A in ("%UVUSEE_CUDA_VERSION%") do (
    if "%%B"=="" (set "COMFY_ARGS=%COMFY_ARGS% --cuda-version %%A.0") else (set "COMFY_ARGS=%COMFY_ARGS% --cuda-version %%A.%%B")
  )
)
rem Run from a scratch dir: comfy-cli drops helper files (override.txt) in the current folder.
set "SCRATCH=%TEMP%\uvusee-comfy-%RANDOM%%RANDOM%"
mkdir "%SCRATCH%"
pushd "%SCRATCH%"
call :comfy_cmd %COMFY_ARGS%
set "RC=%errorlevel%"
popd
rmdir /s /q "%SCRATCH%" 2>nul
exit /b %RC%

rem 5. models
:download_models
call :fetch "black-forest-labs/FLUX.2-klein-9b-kv-fp8" "flux-2-klein-9b-kv-fp8.safetensors" "diffusion_models\flux-2-klein-9b-kv-fp8.safetensors" || exit /b 1
call :fetch "Comfy-Org/Flux-2-Klein-9B" "split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors" "text_encoders\qwen_3_8b_fp8mixed.safetensors" || exit /b 1
call :fetch "Comfy-Org/Flux-2-Klein-9B" "split_files/vae/flux2-vae.safetensors" "vae\flux2-vae.safetensors" || exit /b 1
exit /b 0

:fetch
set "DEST=%MODELS%\%~3"
if exist "%DEST%" (call :log "Model present: %~3" & exit /b 0)
for %%D in ("%DEST%") do if not exist "%%~dpD" mkdir "%%~dpD"
call :log "Downloading %~1/%~2"
rem -C - resumes a partial download if the script was interrupted
curl -fL --retry 5 --retry-delay 10 -C - %HF_AUTH% -o "%DEST%.part" "https://huggingface.co/%~1/resolve/main/%~2"
if errorlevel 1 (call :fail "Download of %~1/%~2 failed; re-run to resume." & exit /b 1)
move /y "%DEST%.part" "%DEST%" >nul || exit /b 1
exit /b 0

:install_all
call :log "Installing into %UVUSEE_DIR%"
call :check_prereqs || exit /b 1
call :check_model_access || exit /b 1
call :step_clone || exit /b 1
if exist "%INSTALLED_MARKER%" goto :install_models
call :log "uv sync (uvusee + comfy-cli into %VENV%)"
call :uv_sync || exit /b 1
call :activate_venv || exit /b 1
call :log "Installing ComfyUI into %COMFY_WORKSPACE% (PyTorch + CUDA libraries, several GB)"
call :comfy_install || exit /b 1
type nul > "%INSTALLED_MARKER%"
:install_models
call :download_models || exit /b 1
call :log "Install complete in %UVUSEE_DIR%"
call :log "To use comfy/uv yourself:  call %VENV%\Scripts\activate.bat"
exit /b 0


rem ---------------------------------------------------------------------------
rem Run (step 6)
rem ---------------------------------------------------------------------------
:start
if not exist "%INSTALLED_MARKER%" (call :fail "Not installed in %UVUSEE_DIR% yet. Run: setup.bat install" & exit /b 1)
cd /d "%UVUSEE_DIR%" || exit /b 1
call :activate_venv || exit /b 1

rem clear a ComfyUI left over from a previous run
call :comfy_cmd stop >nul 2>&1

call :log "Starting ComfyUI on 127.0.0.1:%COMFY_PORT%"
call :comfy_cmd launch --background -- --listen 127.0.0.1 --port %COMFY_PORT% %COMFY_EXTRA_ARGS%
if errorlevel 1 exit /b 1
call :log "ComfyUI log: %COMFY_WORKSPACE%\user\comfyui_%COMFY_PORT%.log"

call :log "Starting uvusee. Ctrl+C stops it - answer N to 'Terminate batch job?' so ComfyUI is stopped too"
set "PYTHONUNBUFFERED=1"
rem --no-sync: a normal `uv run` would reset packages ComfyUI changed back to uv.lock's versions
uv run --no-sync uvusee

call :log "Stopping ComfyUI"
call :comfy_cmd stop >nul 2>&1
exit /b 0

:update
call :is_repo "%UVUSEE_DIR%" || (call :fail "%UVUSEE_DIR% is not the uvusee repo." & exit /b 1)
if not exist "%INSTALLED_MARKER%" (call :fail "Not installed yet. Run: setup.bat install" & exit /b 1)
call :check_prereqs || exit /b 1
call :log "Pulling latest code"
git -C "%UVUSEE_DIR%" pull --ff-only || exit /b 1
call :log "uv sync"
call :uv_sync || exit /b 1
call :activate_venv || exit /b 1
call :log "Re-applying ComfyUI's packages"
call :comfy_install || exit /b 1
call :log "Updated. Restart with: setup.bat start"
exit /b 0
