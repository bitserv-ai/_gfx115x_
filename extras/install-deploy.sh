#!/usr/bin/env bash
# Copyright 2026 bitserv-ai
# SPDX-License-Identifier: MIT
#
# install-deploy.sh — Install vLLM stack from deploy tarballs on a target
# Linux system. Must be run from the directory containing the tarballs.
#
# Usage:
#   ./install-deploy.sh [--with-rocm] [--vllm-dir DIR] [--python PYTHON]
#
#   --with-rocm     Also extract TheRock ROCm runtime
#   --vllm-dir      Base directory (default: /opt/src/vllm)
#   --python        Override Python binary (default: bundled Python 3.13)
#
# Prerequisites on target:
#   - Same glibc or newer (≥ 2.34)
#   - Same GPU driver (AMD ROCm or Mesa Vulkan)
#   - systemd (for lemonade-server service)
#   - sudo access
#
# What this script does:
#   1. Creates /opt/src/vllm/ directory structure
#   2. Extracts ROCm runtime (if --with-rocm)
#   3. Extracts Python 3.13 interpreter (self-contained)
#   4. Creates Python venv and installs wheels
#   5. Extracts llama.cpp backends (rocm, vulkan, cpu)
#   6. Extracts Lemonade server + web app
#   7. Installs scripts, configs, patches
#   8. Sets up Lemonade runtime config (config.json, recipe_options.json)
#   9. Publishes version.txt to Lemonade cache (BUILD-FIXES #158)
#  10. Sets up systemd service for Lemonade
#  11. Runs smoke checks

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
WITH_ROCM=false
VLLM_DIR="/opt/src/vllm"
PYTHON_BIN=""  # empty = use bundled Python

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-rocm)    WITH_ROCM=true; shift ;;
        --vllm-dir)     VLLM_DIR="$2"; shift 2 ;;
        --python)       PYTHON_BIN="$2"; shift 2 ;;
        --help|-h)
            sed -n '3,28p' "$0"
            exit 0 ;;
        *)  echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "\033[32m[INFO]\033[0m  %s\n"  "$*"; }
warn()  { printf "\033[33m[WARN]\033[0m  %s\n"  "$*"; }
fail()  { printf "\033[31m[FAIL]\033[0m  %s\n" "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

for tarball in vllm-python.tar.gz vllm-wheels.tar.gz \
               vllm-llamacpp-rocm.tar.gz vllm-llamacpp-vulkan.tar.gz \
               vllm-llamacpp-cpu.tar.gz vllm-lemonade.tar.gz \
               vllm-config.tar.gz; do
    [[ -f "${SCRIPT_DIR}/${tarball}" ]] || \
        fail "Missing tarball: ${tarball}"
done

if [[ "${WITH_ROCM}" == "true" ]]; then
    [[ -f "${SCRIPT_DIR}/vllm-rocm-runtime.tar.gz" ]] || \
        fail "Missing tarball: vllm-rocm-runtime.tar.gz (use --with-rocm on make-deploy-tarball.sh)"
fi

info "Installing vLLM stack to: ${VLLM_DIR}"
[[ "${WITH_ROCM}" == "true" ]] && info "Including ROCm runtime"
[[ -n "${PYTHON_BIN}" ]] && info "Using custom Python: ${PYTHON_BIN}"

# ---------------------------------------------------------------------------
# 1. Create directory structure
# ---------------------------------------------------------------------------
info "Creating directory structure..."
sudo mkdir -p "${VLLM_DIR}"/{wheels,lemonade/build,llama.cpp}
sudo chown -R "$(id -u):$(id -g)" "${VLLM_DIR}"

# ---------------------------------------------------------------------------
# 2. Extract ROCm runtime (optional, must be before Python so Python's
#    bundled system libs in local/lib/ are not overwritten)
# ---------------------------------------------------------------------------
if [[ "${WITH_ROCM}" == "true" ]]; then
    info "Extracting TheRock ROCm runtime..."
    mkdir -p "${VLLM_DIR}/local"
    tar -xzf "${SCRIPT_DIR}/vllm-rocm-runtime.tar.gz" -C "${VLLM_DIR}/local"
    info "ROCm runtime: $(cat ${VLLM_DIR}/local/version.txt 2>/dev/null || echo 'unknown')"
fi

# ---------------------------------------------------------------------------
# 3. Python 3.13 interpreter (self-contained, no system Python required)
#    Extracted AFTER ROCm so bundled system libs (libssl, libcrypto, libb2,
#    libedit, etc.) are guaranteed intact in local/lib/.
# ---------------------------------------------------------------------------
info "Extracting Python 3.13 interpreter..."
mkdir -p "${VLLM_DIR}/local"
tar -xzf "${SCRIPT_DIR}/vllm-python.tar.gz" -C "${VLLM_DIR}/local"

BUNDLED_PYTHON="${VLLM_DIR}/local/bin/python3.13"

# Determine which Python to use for venv
if [[ -n "${PYTHON_BIN}" ]]; then
    # User override
    command -v "${PYTHON_BIN}" >/dev/null 2>&1 || \
        fail "Python not found: ${PYTHON_BIN}"
    VENV_PYTHON="${PYTHON_BIN}"
else
    # Use bundled Python
    [[ -x "${BUNDLED_PYTHON}" ]] || \
        fail "Bundled Python not executable: ${BUNDLED_PYTHON}"
    VENV_PYTHON="${BUNDLED_PYTHON}"
fi

# Always set LD_LIBRARY_PATH when using bundled Python — the C extensions
# (_ssl, _hashlib, _blake2, etc.) link against bundled system libs in
# local/lib/. Without this, they fail to load on distros where the libs
# are missing or in different paths (e.g. Ubuntu 24.04).
if [[ -z "${PYTHON_BIN}" ]]; then
    export LD_LIBRARY_PATH="${VLLM_DIR}/local/lib:${LD_LIBRARY_PATH:-}"
fi

PY_VER="$("${VENV_PYTHON}" --version 2>&1)"
info "Using Python: ${PY_VER} (${VENV_PYTHON})"

# Smoke test: verify SSL and hashlib load correctly (after all extractions)
if [[ -z "${PYTHON_BIN}" ]]; then
    if "${VENV_PYTHON}" -c "import ssl, hashlib; print('ssl/hashlib OK')" 2>/dev/null; then
        info "ssl/hashlib OK"
    else
        warn "Bundled Python ssl/hashlib test failed — C extensions may not work"
        warn "  Check: LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Python venv + wheels
# ---------------------------------------------------------------------------
info "Creating Python venv..."
"${VENV_PYTHON}" -m venv "${VLLM_DIR}/.venv"
source "${VLLM_DIR}/.venv/bin/activate"

info "Installing wheels..."
tar -xzf "${SCRIPT_DIR}/vllm-wheels.tar.gz" -C "${VLLM_DIR}/wheels"
# --no-deps: all wheels come from a known-good venv snapshot, so we don't
# need pip's dependency resolver (which may reject custom-build version
# numbers like triton 3.0.0+git... that don't match upstream pins).
pip install --no-index --no-deps --find-links "${VLLM_DIR}/wheels" \
    -r "${VLLM_DIR}/wheels/requirements.txt"

info "Installed packages:"
pip list 2>/dev/null | grep -iE 'torch|vllm|triton|aiter|flash' || true

# ---------------------------------------------------------------------------
# 5. llama.cpp backends
# ---------------------------------------------------------------------------
for backend in rocm vulkan cpu; do
    info "Extracting llama.cpp ${backend} backend..."
    tar -xzf "${SCRIPT_DIR}/vllm-llamacpp-${backend}.tar.gz" -C "${VLLM_DIR}/llama.cpp"
    [[ -x "${VLLM_DIR}/llama.cpp/build-${backend}/llama-server" ]] || \
        warn "build-${backend}/llama-server not executable after extraction"
done

# Show versions
for backend in rocm vulkan cpu; do
    ver=$(cat "${VLLM_DIR}/llama.cpp/build-${backend}/version.txt" 2>/dev/null || echo '?')
    info "  build-${backend}: ${ver}"
done

# ---------------------------------------------------------------------------
# 6. Lemonade
# ---------------------------------------------------------------------------
info "Extracting Lemonade server..."
tar -xzf "${SCRIPT_DIR}/vllm-lemonade.tar.gz" -C "${VLLM_DIR}/lemonade/build"
[[ -x "${VLLM_DIR}/lemonade/build/lemond" ]] || warn "lemond not executable"

# ---------------------------------------------------------------------------
# 7. Config + scripts
# ---------------------------------------------------------------------------
info "Extracting config and scripts..."
CONF_STAGING="$(mktemp -d)"
trap 'rm -rf "${CONF_STAGING}"' EXIT
tar -xzf "${SCRIPT_DIR}/vllm-config.tar.gz" -C "${CONF_STAGING}"

# Copy scripts
mkdir -p "${VLLM_DIR}/_gfx115x_"
if [[ -d "${CONF_STAGING}/strix-halo" ]]; then
    cp -r "${CONF_STAGING}/strix-halo/"* "${VLLM_DIR}/_gfx115x_/" 2>/dev/null || true
    [[ -f "${CONF_STAGING}/strix-halo/.env" ]] && \
        cp "${CONF_STAGING}/strix-halo/.env" "${VLLM_DIR}/_gfx115x_/.env"
fi

# Copy patches
[[ -d "${CONF_STAGING}/strix-halo/patches" ]] && \
    cp -r "${CONF_STAGING}/strix-halo/patches" "${VLLM_DIR}/_gfx115x_/patches/" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 8. Lemonade runtime config
# ---------------------------------------------------------------------------
info "Setting up Lemonade runtime config..."

LEMONADE_CONFIG_DIR="${HOME}/.config/lemonade"
LEMONADE_CACHE_DIR="${HOME}/.cache/lemonade"

mkdir -p "${LEMONADE_CONFIG_DIR}"
mkdir -p "${LEMONADE_CACHE_DIR}"

# lemonade.env
if [[ -f "${CONF_STAGING}/lemonade-config/lemonade.env" ]]; then
    cp "${CONF_STAGING}/lemonade-config/lemonade.env" \
       "${LEMONADE_CONFIG_DIR}/lemonade.env"
    info "  lemonade.env installed"
fi

# config.json — update binary paths if VLLM_DIR differs from default
if [[ -f "${CONF_STAGING}/lemonade-config/config.json" ]]; then
    if [[ "${VLLM_DIR}" != "/opt/src/vllm" ]]; then
        sed -i "s|/opt/src/vllm|${VLLM_DIR}|g" \
            "${CONF_STAGING}/lemonade-config/config.json"
    fi
    cp "${CONF_STAGING}/lemonade-config/config.json" \
       "${LEMONADE_CACHE_DIR}/config.json"
    info "  config.json installed"
fi

# recipe_options.json — replace ${USER} placeholder
if [[ -f "${CONF_STAGING}/lemonade-config/recipe_options.json" ]]; then
    sed "s|\${USER}|${USER}|g" \
        "${CONF_STAGING}/lemonade-config/recipe_options.json" \
        > "${LEMONADE_CACHE_DIR}/recipe_options.json"
    info "  recipe_options.json installed"
fi

# ---------------------------------------------------------------------------
# 9. Lemonade cache version.txt (BUILD-FIXES #158)
# ---------------------------------------------------------------------------
info "Publishing version.txt to Lemonade cache..."

CACHE_LLAMACPP="${LEMONADE_CACHE_DIR}/bin/llamacpp"
mkdir -p "${CACHE_LLAMACPP}"/{rocm-stable,vulkan,cpu}

if [[ -d "${CONF_STAGING}/lemonade-cache/bin/llamacpp" ]]; then
    for b in rocm-stable vulkan cpu; do
        if [[ -f "${CONF_STAGING}/lemonade-cache/bin/llamacpp/${b}/version.txt" ]]; then
            cp "${CONF_STAGING}/lemonade-cache/bin/llamacpp/${b}/version.txt" \
               "${CACHE_LLAMACPP}/${b}/version.txt"
        fi
    done
else
    # Fallback: read from build dirs
    for b in rocm-stable vulkan cpu; do
        build_b="${b//-stable/}"
        ver=$(cat "${VLLM_DIR}/llama.cpp/build-${build_b}/version.txt" 2>/dev/null || echo 'unknown')
        echo "${ver}" > "${CACHE_LLAMACPP}/${b}/version.txt"
    done
fi

info "  version.txt published for rocm-stable, vulkan, cpu"

# ---------------------------------------------------------------------------
# 10. systemd service
# ---------------------------------------------------------------------------
info "Setting up systemd service..."

OVERRIDE_DIR="/etc/systemd/system/lemonade-server.service.d"
sudo mkdir -p "${OVERRIDE_DIR}"

# If the base service unit doesn't exist, create a minimal one.
# On Arch this is normally provided by the lemonade-server AUR package,
# but on other distros (Ubuntu, Debian, Fedora, etc.) there is no such package.
if ! systemctl cat lemonade-server >/dev/null 2>&1; then
    info "  lemonade-server.service not found — creating base unit"
    sudo tee /etc/systemd/system/lemonade-server.service >/dev/null <<'UNIT'
[Unit]
Description=Lemonade AI Inference Server
After=network.target

[Service]
Type=simple
ExecStart=/opt/src/vllm/lemonade/build/lemond
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi

# Install override (custom binary path, user, env)
if [[ -f "${CONF_STAGING}/lemonade-config/override.conf" ]]; then
    sed \
        -e "s|\${USER}|${USER}|g" \
        -e "s|/opt/src/vllm|${VLLM_DIR}|g" \
        "${CONF_STAGING}/lemonade-config/override.conf" \
        | sudo tee "${OVERRIDE_DIR}/override.conf" >/dev/null
    info "  systemd override installed"
else
    sudo tee "${OVERRIDE_DIR}/override.conf" >/dev/null <<OVERRIDE
[Service]
ExecStart=
ExecStart=${VLLM_DIR}/lemonade/build/lemond
User=${USER}
Group=${USER}
EnvironmentFile=-${HOME}/.config/lemonade/lemonade.env
Environment=HOME=${HOME}
ProtectHome=no
ProtectSystem=off
ReadWritePaths=/
OVERRIDE
    info "  systemd override generated (minimal)"
fi

sudo systemctl daemon-reload
info "  systemctl daemon-reload done"

# ---------------------------------------------------------------------------
# 10b. WSL2 rocdxg bridge (BUILD-FIXES #176-#178)
# ---------------------------------------------------------------------------
if [[ -e /dev/dxg ]]; then
    info "WSL2 detected (/dev/dxg) — installing librocdxg.so..."
    ROCDXG_TARBALL="${SCRIPT_DIR:-$(dirname "$0")}/vllm-rocdxg.tar.gz"
    if [[ -f "${ROCDXG_TARBALL}" ]]; then
        tar -xzf "${ROCDXG_TARBALL}" -C "${VLLM_DIR}/local/lib/"
        ln -sf librocdxg.so.1.1.0 "${VLLM_DIR}/local/lib/librocdxg.so.1"
        ln -sf librocdxg.so.1.1.0 "${VLLM_DIR}/local/lib/librocdxg.so"
        sudo ldconfig 2>/dev/null || true
        info "  librocdxg.so installed"
    else
        warn "  vllm-rocdxg.tar.gz not found — librocdxg.so not installed"
        warn "  Build with extras/wsl/build-rocdxg.sh or download separately"
    fi
    # TRITON_HIP_LLD_PATH: Triton can't find ld.lld on WSL2 (no /opt/rocm)
    LEMONADE_ENV="${LEMONADE_CONFIG_DIR}/lemonade.env"
    if ! grep -q "TRITON_HIP_LLD_PATH" "${LEMONADE_ENV}" 2>/dev/null; then
        echo "TRITON_HIP_LLD_PATH=${VLLM_DIR}/local/llvm/bin/ld.lld" | \
            sudo tee -a "${LEMONADE_ENV}" >/dev/null
        info "  TRITON_HIP_LLD_PATH added to lemonade.env"
    fi
else
    info "Native Linux (no /dev/dxg) — skipping rocdxg"
fi

# ---------------------------------------------------------------------------
# 11. Smoke checks
# ---------------------------------------------------------------------------
info "Running smoke checks..."
echo

# Ensure bundled libs are on LD_LIBRARY_PATH for import checks
if [[ -z "${PYTHON_BIN:-}" ]]; then
    export LD_LIBRARY_PATH="${VLLM_DIR}/local/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

PASS=0
FAIL=0

check() {
    if timeout 30 bash -c "$2" >/dev/null 2>&1; then
        printf "  \033[32mPASS\033[0m  %s\n" "$1"
        PASS=$((PASS + 1))
    else
        printf "  \033[31mFAIL\033[0m  %s\n" "$1"
        FAIL=$((FAIL + 1))
    fi
}

check "venv python"       "${VLLM_DIR}/.venv/bin/python --version"
check "python 3.13"       "${VENV_PYTHON} --version"
check "torch import"      "${VLLM_DIR}/.venv/bin/python -c 'import torch; print(torch.__version__)'"
check "vllm import"       "${VLLM_DIR}/.venv/bin/python -c 'import vllm; print(vllm.__version__)'"
check "llama-server rocm" "[[ -x ${VLLM_DIR}/llama.cpp/build-rocm/llama-server ]]"
check "llama-server vulk" "[[ -x ${VLLM_DIR}/llama.cpp/build-vulkan/llama-server ]]"
check "llama-server cpu"  "[[ -x ${VLLM_DIR}/llama.cpp/build-cpu/llama-server ]]"
check "lemond binary"     "[[ -x ${VLLM_DIR}/lemonade/build/lemond ]]"
check "lemonade config"   "[[ -f ${LEMONADE_CACHE_DIR}/config.json ]]"
check "version.txt rocm"  "[[ -f ${CACHE_LLAMACPP}/rocm-stable/version.txt ]]"
check "version.txt vulk"   "[[ -f ${CACHE_LLAMACPP}/vulkan/version.txt ]]"
check "version.txt cpu"   "[[ -f ${CACHE_LLAMACPP}/cpu/version.txt ]]"
check "build-vllm.sh"     "[[ -f ${VLLM_DIR}/_gfx115x_/build-vllm.sh ]]"
check ".env template"     "[[ -f ${VLLM_DIR}/_gfx115x_/.env ]]"
check "patches dir"       "[[ -d ${VLLM_DIR}/_gfx115x_/patches ]]"
check "libpython"         "[[ -f ${VLLM_DIR}/local/lib/libpython3.13.so.1.0 ]]"

if [[ "${WITH_ROCM}" == "true" ]]; then
    check "ROCm local"    "[[ -f ${VLLM_DIR}/local/lib/libamdhip64.so ]]"
fi

if [[ -e /dev/dxg ]]; then
    check "rocdxg"        "[[ -f ${VLLM_DIR}/local/lib/librocdxg.so.1.1.0 ]]"
fi

echo
info "Smoke checks: ${PASS} passed, ${FAIL} failed"

if [[ ${FAIL} -gt 0 ]]; then
    warn "Some checks failed. Review the output above."
    exit 1
fi

info "Installation complete!"
echo
info "Next steps:"
echo "  1. Edit ${VLLM_DIR}/_gfx115x_/.env — set VLLM_MODEL_HOME to your models"
echo "  2. Edit ${LEMONADE_CONFIG_DIR}/lemonade.env — set HF_HUB_CACHE"
echo "  3. sudo systemctl enable --now lemonade-server"
echo "  4. Open http://localhost:13305 in browser"
echo "  5. Start vLLM: ${VLLM_DIR}/_gfx115x_/vllm-start.sh"