#!/usr/bin/env bash
# Copyright 2026 bitserv-ai
# SPDX-License-Identifier: MIT
#
# make-deploy-tarball.sh — Pack runtime artifacts for deployment to other
# Linux systems with the same hardware (gfx1151) and Python version.
#
# Usage:
#   ./make-deploy-tarball.sh [--with-rocm] [--output-dir DIR]
#
#   --with-rocm     Include TheRock ROCm runtime (~7.8 GB)
#   --output-dir    Destination for tarballs (default: ./deploy)
#
# Produces:
#   vllm-python.tar.gz             — Python 3.13 interpreter + stdlib (~330 MB)
#   vllm-wheels.tar.gz             — Python wheels (~750 MB)
#   vllm-llamacpp-rocm.tar.gz      — ROCm llama.cpp backend (~150 MB)
#   vllm-llamacpp-vulkan.tar.gz    — Vulkan llama.cpp backend (~200 MB)
#   vllm-llamacpp-cpu.tar.gz       — CPU llama.cpp backend (~80 MB)
#   vllm-lemonade.tar.gz           — Lemonade server + web app (~110 MB)
#   vllm-config.tar.gz             — Scripts, configs, patches (~1 MB)
#   vllm-rocm-runtime.tar.gz       — TheRock ROCm runtime (optional, ~7.8 GB)
#
# Requirements:
#   - Build must be complete (wheels/, llama.cpp/build-*, lemonade/build/)
#   - Run as the same user who owns the build artifacts

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
WITH_ROCM=false
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-rocm)    WITH_ROCM=true; shift ;;
        --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h)
            sed -n '3,28p' "$0"
            exit 0 ;;
        *)  echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
VLLM_DIR="${VLLM_DIR:-/opt/src/vllm}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LLAMA_SRC="${VLLM_DIR}/llama.cpp"
LEMONADE_BUILD="${VLLM_DIR}/lemonade/build"
WHEELS_DIR="${VLLM_DIR}/wheels"
LOCAL_PREFIX="${VLLM_DIR}/local"
DEPLOY_DIR="${OUTPUT_DIR:-${REPO_DIR}/deploy}"

mkdir -p "${DEPLOY_DIR}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "\033[32m[INFO]\033[0m  %s\n"  "$*"; }
warn()  { printf "\033[33m[WARN]\033[0m  %s\n"  "$*"; }
fail()  { printf "\033[31m[FAIL]\033[0m  %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[[ -d "${WHEELS_DIR}" ]]      || fail "Wheels directory not found: ${WHEELS_DIR}"
[[ -d "${LLAMA_SRC}" ]]      || fail "llama.cpp source not found: ${LLAMA_SRC}"
[[ -d "${LEMONADE_BUILD}" ]] || fail "Lemonade build not found: ${LEMONADE_BUILD}"

for backend in rocm vulkan cpu; do
    [[ -x "${LLAMA_SRC}/build-${backend}/llama-server" ]] || \
        fail "llama.cpp build-${backend}/llama-server not found"
done

[[ -x "${LEMONADE_BUILD}/lemond" ]] || fail "lemond binary not found"

# Python interpreter check
PYTHON_BIN="${LOCAL_PREFIX}/bin/python3.13"
[[ -x "${PYTHON_BIN}" ]] || fail "Python 3.13 not found: ${PYTHON_BIN}"
[[ -f "${LOCAL_PREFIX}/lib/libpython3.13.so.1.0" ]] || \
    fail "libpython3.13.so.1.0 not found in ${LOCAL_PREFIX}/lib/"
[[ -d "${LOCAL_PREFIX}/lib/python3.13/" ]] || \
    fail "Python stdlib not found: ${LOCAL_PREFIX}/lib/python3.13/"

if [[ "${WITH_ROCM}" == "true" ]]; then
    [[ -d "${LOCAL_PREFIX}" ]] || fail "ROCm local prefix not found: ${LOCAL_PREFIX}"
fi

# ---------------------------------------------------------------------------
# Detect llama.cpp version
# ---------------------------------------------------------------------------
LLAMA_VERSION="$(cat "${LLAMA_SRC}/build-rocm/version.txt" 2>/dev/null || echo 'unknown')"
info "llama.cpp version: ${LLAMA_VERSION}"

# Detect Python version
PY_VERSION="$("${PYTHON_BIN}" --version 2>&1 | awk '{print $2}')"
info "Python version: ${PY_VERSION}"

# ---------------------------------------------------------------------------
# 1. Python 3.13 interpreter + stdlib + system libs (fully self-contained)
# ---------------------------------------------------------------------------
info "Packing Python ${PY_VERSION} interpreter..."

# Create staging dir for Python bundle
PY_STAGING="$(mktemp -d)"
mkdir -p "${PY_STAGING}/bin" "${PY_STAGING}/lib"

# Binary
cp "${LOCAL_PREFIX}/bin/python3.13" "${PY_STAGING}/bin/"
ln -s python3.13 "${PY_STAGING}/bin/python3"

# Shared library
cp "${LOCAL_PREFIX}/lib/libpython3.13.so.1.0" "${PY_STAGING}/lib/"
ln -s libpython3.13.so.1.0 "${PY_STAGING}/lib/libpython3.13.so"

# Stdlib (pure Python modules + C extensions in lib-dynload/)
cp -a "${LOCAL_PREFIX}/lib/python3.13" "${PY_STAGING}/lib/python3.13"

# Bundle system libraries needed by C extensions (_ssl, _hashlib, _blake2,
# _bz2, _lzma, _sqlite3, _ctypes, etc.). These are small (~11 MB total) and
# ensure the Python interpreter works on any Linux distro without installing
# dev packages.
info "  Bundling system libraries for C extensions..."
PY_SYSLIBS=(
    libb2.so.1       libbz2.so.1.0     libcrypto.so.3    libedit.so.0
    libexpat.so.1    libffi.so.8      libgcc_s.so.1     libgdbm_compat.so.4
    libgdbm.so.6     libgomp.so.1     liblzma.so.5      libmpdec.so.4
    libncursesw.so.6 libpanelw.so.6   libreadline.so.8  libsqlite3.so.0
    libssl.so.3     libuuid.so.1     libz.so.1
)
for lib in "${PY_SYSLIBS[@]}"; do
    # Resolve the real file (follow symlinks). Filter x86-64 to avoid lib32.
    path=$(ldconfig -p 2>/dev/null | grep "x86-64" | grep -m1 "${lib}" | awk '{print $NF}' | xargs)
    if [[ -n "${path}" ]] && [[ -f "${path}" ]]; then
        real=$(readlink -f "${path}")
        cp "${real}" "${PY_STAGING}/lib/"
        # Create symlink if the lib name differs from the real file name
        realname=$(basename "${real}")
        if [[ "${realname}" != "${lib}" ]]; then
            ln -sf "${realname}" "${PY_STAGING}/lib/${lib}"
        fi
    else
        warn "  System lib not found: ${lib} (may need to install on target)"
    fi
done

# Strip __pycache__ and test suite to reduce size
find "${PY_STAGING}/lib/python3.13" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
rm -rf "${PY_STAGING}/lib/python3.13/test" 2>/dev/null || true
rm -rf "${PY_STAGING}/lib/python3.13/idlelib" 2>/dev/null || true
rm -rf "${PY_STAGING}/lib/python3.13/turtledemo" 2>/dev/null || true

# Pack with paths relative to local/ (extracts into ${VLLM_DIR}/local/)
tar -czf "${DEPLOY_DIR}/vllm-python.tar.gz" -C "${PY_STAGING}" .
rm -rf "${PY_STAGING}"

# ---------------------------------------------------------------------------
# 2. Wheels (full venv export — all dependencies, not just compiled ones)
# ---------------------------------------------------------------------------
info "Exporting all venv packages as wheels..."

WHEELS_STAGING="$(mktemp -d)"

# Get all packages from venv. Separate PyPI packages from local builds.
"${VLLM_DIR}/.venv/bin/pip" freeze 2>/dev/null > "${WHEELS_STAGING}/freeze.txt"

# PyPI packages (name==version) — download as wheels
grep -v 'file://' "${WHEELS_STAGING}/freeze.txt" | grep -v ' @ ' > "${WHEELS_STAGING}/pypi-requirements.txt"
info "  Downloading $(wc -l < "${WHEELS_STAGING}/pypi-requirements.txt") PyPI packages..."
"${VLLM_DIR}/.venv/bin/pip" download --no-deps -d "${WHEELS_STAGING}" \
    -r "${WHEELS_STAGING}/pypi-requirements.txt" 2>/dev/null

# Local compiled wheels — copy from wheels/
info "  Copying local compiled wheels..."
cp "${WHEELS_DIR}"/*.whl "${WHEELS_STAGING}/"

# Generate requirements.txt for install-deploy.sh (all package names)
grep -v 'file://' "${WHEELS_STAGING}/freeze.txt" | grep -v ' @ ' | sed 's/==.*//' >> "${WHEELS_STAGING}/requirements.txt"
cat >> "${WHEELS_STAGING}/requirements.txt" <<'EOF'
amd-aiter
amdsmi
asyncpg
cryptography
flash-attn
numpy
orjson
sentencepiece
torch
torchvision
triton
vllm
zstandard
EOF
sort -o "${WHEELS_STAGING}/requirements.txt" "${WHEELS_STAGING}/requirements.txt"

# Clean up staging files
rm -f "${WHEELS_STAGING}/freeze.txt" "${WHEELS_STAGING}/pypi-requirements.txt"

info "Packing wheels ($(ls "${WHEELS_STAGING}"/*.whl | wc -l) packages)..."
tar -czf "${DEPLOY_DIR}/vllm-wheels.tar.gz" -C "${WHEELS_STAGING}" .
rm -rf "${WHEELS_STAGING}"

# ---------------------------------------------------------------------------
# 3. llama.cpp backends (filtered — only runtime files)
# ---------------------------------------------------------------------------
pack_llamacpp_backend() {
    local backend="$1"
    local build_dir="${LLAMA_SRC}/build-${backend}"
    local tarball="${DEPLOY_DIR}/vllm-llamacpp-${backend}.tar.gz"

    info "Packing llama.cpp ${backend} backend..."

    # Collect files: *.so, *.so.*, executables, bin/, version.txt, backend.txt
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find "${build_dir}" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) -print
        find "${build_dir}" -maxdepth 1 -type f -executable \
            ! -name 'compile_commands.json' ! -name '*.ninja' -print
    )

    [[ -d "${build_dir}/bin" ]]              && files+=("${build_dir}/bin")
    [[ -f "${build_dir}/version.txt" ]]      && files+=("${build_dir}/version.txt")
    [[ -f "${build_dir}/backend.txt" ]]      && files+=("${build_dir}/backend.txt")

    # Vulkan shaders
    local spv_dir="${build_dir}/ggml/src/ggml-vulkan/vulkan-shaders.spv"
    [[ -d "${spv_dir}" ]] && files+=("${spv_dir}")

    # Tar with paths relative to llama.cpp/ (use -C instead of --transform
    # because tar strips leading / before transform, breaking the regex)
    local rel_files=()
    for f in "${files[@]}"; do
        rel_files+=("${f#${LLAMA_SRC}/}")
    done

    tar -czf "${tarball}" -C "${LLAMA_SRC}" "${rel_files[@]}"
}

pack_llamacpp_backend rocm
pack_llamacpp_backend vulkan
pack_llamacpp_backend cpu

# ---------------------------------------------------------------------------
# 4. Lemonade
# ---------------------------------------------------------------------------
info "Packing Lemonade server..."

LEMON_FILES=(lemond lemonade resources/ web-app-staging/)
[[ -f "${LEMONADE_BUILD}/version.txt" ]] && LEMON_FILES+=(version.txt)

tar -czf "${DEPLOY_DIR}/vllm-lemonade.tar.gz" \
    -C "${LEMONADE_BUILD}" \
    "${LEMON_FILES[@]}"

# ---------------------------------------------------------------------------
# 5. Config + scripts (sanitized)
# ---------------------------------------------------------------------------
info "Packing config and scripts..."

# Create staging directory
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

# --- Scripts + YAML + patches ---
mkdir -p "${STAGING}/strix-halo"
cp "${REPO_DIR}"/{build-vllm.sh,common.sh,vllm-env.sh,vllm-runtime-helpers.sh,vllm-start.sh,vllm-status.sh,vllm-stop.sh,vllm-packages.yaml} \
   "${STAGING}/strix-halo/" 2>/dev/null || true
cp -r "${REPO_DIR}/patches" "${STAGING}/strix-halo/" 2>/dev/null || true
cp "${SCRIPT_DIR}"/{make-deploy-tarball.sh,install-deploy.sh} \
   "${STAGING}/strix-halo/" 2>/dev/null || true

# --- .env (sanitized) ---
sed \
    -e 's|/mnt/Windows/vllm|/path/to/models|g' \
    -e 's|/mnt/Windows/hub|/path/to/hf-cache|g' \
    "${REPO_DIR}/.env" > "${STAGING}/strix-halo/.env"

# --- Lemonade configs (sanitized) ---
mkdir -p "${STAGING}/lemonade-config"

# lemonade.env — strip HF cache path
if [[ -f "${HOME}/.config/lemonade/lemonade.env" ]]; then
    sed 's|/mnt/Windows/hub|/path/to/hf-cache|g' \
        "${HOME}/.config/lemonade/lemonade.env" \
        > "${STAGING}/lemonade-config/lemonade.env"
fi

# config.json — keep binary paths as-is (they reference /opt/src/vllm which
# the install script creates), but strip any personal paths
if [[ -f "${HOME}/.cache/lemonade/config.json" ]]; then
    cp "${HOME}/.cache/lemonade/config.json" \
       "${STAGING}/lemonade-config/config.json"
fi

# recipe_options.json — anonymize home dir
if [[ -f "${HOME}/.cache/lemonade/recipe_options.json" ]]; then
    sed "s|${HOME}|/home/\${USER}|g" \
        "${HOME}/.cache/lemonade/recipe_options.json" \
        > "${STAGING}/lemonade-config/recipe_options.json"
fi

# systemd override — anonymize
if [[ -f /etc/systemd/system/lemonade-server.service.d/override.conf ]]; then
    sed \
        -e "s|${HOME}|/home/\${USER}|g" \
        -e "s|User=.*|User=\${USER}|g" \
        -e "s|Group=.*|Group=\${USER}|g" \
        /etc/systemd/system/lemonade-server.service.d/override.conf \
        > "${STAGING}/lemonade-config/override.conf"
fi

# --- Lemonade cache version.txt files (BUILD-FIXES #158) ---
mkdir -p "${STAGING}/lemonade-cache/bin/llamacpp"/{rocm-stable,vulkan,cpu}
CACHE_DIR="${HOME}/.cache/lemonade/bin/llamacpp"
for b in rocm-stable vulkan cpu; do
    if [[ -f "${CACHE_DIR}/${b}/version.txt" ]]; then
        cp "${CACHE_DIR}/${b}/version.txt" \
           "${STAGING}/lemonade-cache/bin/llamacpp/${b}/version.txt"
    else
        echo "${LLAMA_VERSION}" \
            > "${STAGING}/lemonade-cache/bin/llamacpp/${b}/version.txt"
    fi
done

tar -czf "${DEPLOY_DIR}/vllm-config.tar.gz" -C "${STAGING}" .

# ---------------------------------------------------------------------------
# 6. ROCm runtime (optional)
# ---------------------------------------------------------------------------
if [[ "${WITH_ROCM}" == "true" ]]; then
    info "Packing TheRock ROCm runtime (this will take a while)..."
    tar -czf "${DEPLOY_DIR}/vllm-rocm-runtime.tar.gz" -C "${LOCAL_PREFIX}" .
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
info "Deploy tarballs created in: ${DEPLOY_DIR}"
echo
printf "%-40s %10s\n" "File" "Size"
printf "%-40s %10s\n" "----" "----"
for f in "${DEPLOY_DIR}"/*.tar.gz; do
    printf "%-40s %10s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
echo

TOTAL=$(du -sh "${DEPLOY_DIR}" | cut -f1)
info "Total: ${TOTAL}"

# Copy install-deploy.sh into deploy/ so the folder is self-contained
cp "${SCRIPT_DIR}/install-deploy.sh" "${DEPLOY_DIR}/"
info "install-deploy.sh copied to ${DEPLOY_DIR}/"

echo
info "Transfer the deploy/ folder to the target system, then run:"
info "  cd deploy && ./install-deploy.sh ${WITH_ROCM:+--with-rocm}"