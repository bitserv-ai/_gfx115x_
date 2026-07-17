#!/bin/bash
# Copyright 2026 bitserv-ai
# SPDX-License-Identifier: MIT
#
# build-rocdxg.sh — Build librocdxg.so for WSL2 from TheRock source
#
# This script builds the HSA→DXG bridge library (librocdxg.so) needed
# for ROCm on WSL2. On native Linux, libhsakmt.so provides the kernel
# ioctl interface; on WSL2, librocdxg.so replaces it by routing HSA
# calls through /dev/dxg (GPU paravirtualization).
#
# Prerequisites:
#   - WSL2 with /dev/dxg present
#   - build-essential, cmake, ninja-build, python3 installed
#   - TheRock source tree at /opt/src/vllm/therock/ (or override THEROCK_SRC)
#
# Usage:
#   bash build-rocdxg.sh [INSTALL_PREFIX]
#
# The resulting librocdxg.so.1.1.0 is installed to INSTALL_PREFIX/lib/
# (default: /opt/src/vllm/local).
#
# BUILD-FIXES #176-#178: This library is required for WSL2 deploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
THEROCK_SRC="${THEROCK_SRC:-/opt/src/vllm/therock}"
INSTALL_PREFIX="${1:-/opt/src/vllm/local}"
BUILD_DIR="/tmp/build-rocdxg"
SDK_DIR="/tmp/win-sdk-shared"

echo "=== librocdxg.so WSL2 Build ==="
echo "TheRock source: ${THEROCK_SRC}"
echo "Build dir:      ${BUILD_DIR}"
echo "Install prefix: ${INSTALL_PREFIX}"
echo ""

# --- 1. Windows SDK shared headers (via NuGet) ---
echo "=== Step 1: Fetching Windows SDK shared headers (NuGet) ==="
NUGET_URL="https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/10.0.28000.2270/microsoft.windows.sdk.cpp.10.0.28000.2270.nupkg"
NUGET_CACHE="/tmp/win-sdk-cpp.nupkg"

if [[ -d "${SDK_DIR}" && -f "${SDK_DIR}/d3dkmthk.h" ]]; then
    echo "  Windows SDK headers already cached at ${SDK_DIR}"
else
    echo "  Downloading NuGet package (153MB)..."
    curl -L -s -o "${NUGET_CACHE}" "${NUGET_URL}"
    echo "  Extracting shared/ headers..."
    mkdir -p "${SDK_DIR}"
    python3 -c "
import zipfile, os
z = zipfile.ZipFile('${NUGET_CACHE}')
shared = [n for n in z.namelist() if '/shared/' in n and n.endswith('.h')]
for f in shared:
    name = os.path.basename(f)
    with z.open(f) as src, open(os.path.join('${SDK_DIR}', name), 'wb') as dst:
        dst.write(src.read())
print(f'  Extracted {len(shared)} headers')
"
    rm -f "${NUGET_CACHE}"
fi
echo "  d3dkmthk.h: $(test -f ${SDK_DIR}/d3dkmthk.h && echo 'found' || echo 'MISSING')"
echo ""

# --- 2. libwkmi.a (via DVC S3 anonymous) ---
echo "=== Step 2: Fetching libwkmi.a (DVC S3) ==="
WKMI_URL="https://therock-dvc.s3.us-east-2.amazonaws.com/rocm-systems/files/md5/3c/fd159fed350b67783617548dc98b1c"
WKMI_DIR="${THEROCK_SRC}/rocm-systems/shared/amdgpu-windows-interop/wkmi/lnx/lib"

if [[ -f "${WKMI_DIR}/libwkmi.a" ]]; then
    echo "  libwkmi.a already present at ${WKMI_DIR}"
else
    echo "  Downloading libwkmi.a (337KB)..."
    mkdir -p "${WKMI_DIR}"
    curl -s -o "${WKMI_DIR}/libwkmi.a" "${WKMI_URL}"
    echo "  md5: $(md5sum ${WKMI_DIR}/libwkmi.a | cut -d' ' -f1)"
fi
echo ""

# --- 3. Prepare source (copy CMakeLists_wsl.txt → CMakeLists.txt) ---
echo "=== Step 3: Preparing build tree ==="
LIBHSAKMT_SRC="${THEROCK_SRC}/rocm-systems/projects/rocr-runtime/libhsakmt"

if [[ ! -d "${LIBHSAKMT_SRC}" ]]; then
    echo "ERROR: TheRock libhsakmt source not found at ${LIBHSAKMT_SRC}"
    exit 1
fi

# Work on a copy in /tmp to avoid modifying the source tree
TMP_SRC="/tmp/rocdxg-src"
rm -rf "${TMP_SRC}"
cp -a "${LIBHSAKMT_SRC}" "${TMP_SRC}"

# Also copy the runtime util sources (referenced by relative path)
RUNTIME_SRC="${THEROCK_SRC}/rocm-systems/projects/rocr-runtime/runtime"
mkdir -p "$(dirname ${TMP_SRC})/runtime"
cp -a "${RUNTIME_SRC}" "$(dirname ${TMP_SRC})/runtime"

# Copy wkmi (referenced by ../../../shared/...)
SHARED_SRC="${THEROCK_SRC}/rocm-systems/shared"
mkdir -p "$(dirname ${TMP_SRC})/../../../shared"
cp -a "${SHARED_SRC}" "$(dirname ${TMP_SRC})/../../../shared" 2>/dev/null || true

# Swap CMakeLists
cp "${TMP_SRC}/CMakeLists_wsl.txt" "${TMP_SRC}/CMakeLists.txt"

# Patch wddm_types.h: add FARPROC + WINAPI (not in Linux compat layer)
WDDM_TYPES="${TMP_SRC}/include/impl/wddm/wddm_types.h"
sed -i 's/^#define FAR$/#define FAR\n#define WINAPI/' "${WDDM_TYPES}"
sed -i '/^#define __stdcall$/a typedef int (*FARPROC)();' "${WDDM_TYPES}"
echo "  wddm_types.h patched (FARPROC, WINAPI)"
echo ""

# --- 4. Configure ---
echo "=== Step 4: Configuring (cmake) ==="
rm -rf "${BUILD_DIR}"
cmake -B "${BUILD_DIR}" -S "${TMP_SRC}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DWIN_SDK="${SDK_DIR}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DROCDXG_WERROR=OFF \
    2>&1
echo ""

# --- 5. Build ---
echo "=== Step 5: Building ==="
cmake --build "${BUILD_DIR}" --target rocdxg -- -j"$(nproc)" 2>&1
echo ""

# --- 6. Verify ---
echo "=== Step 6: Verifying ==="
SO_FILE="${BUILD_DIR}/librocdxg.so.1.1.0"
if [[ ! -f "${SO_FILE}" ]]; then
    echo "ERROR: librocdxg.so not found in build dir"
    ls -la "${BUILD_DIR}"/librocdxg* 2>/dev/null || echo "  No librocdxg files at all"
    exit 1
fi

echo "Built: $(ls -lh ${SO_FILE})"
echo "Symbols: $(nm -D ${SO_FILE} | grep -c hsaKmt) hsaKmt symbols exported"
echo ""

# --- 7. Install ---
echo "=== Step 7: Installing to ${INSTALL_PREFIX}/lib/ ==="
cp "${SO_FILE}" "${INSTALL_PREFIX}/lib/"
ln -sf librocdxg.so.1.1.0 "${INSTALL_PREFIX}/lib/librocdxg.so.1"
ln -sf librocdxg.so.1.1.0 "${INSTALL_PREFIX}/lib/librocdxg.so"
ldconfig 2>/dev/null || true
echo "Installed: $(ls -lh ${INSTALL_PREFIX}/lib/librocdxg.so*)"
echo ""
echo "=== Done ==="
echo "Test with: LD_LIBRARY_PATH=\"/usr/lib/wsl/lib:${INSTALL_PREFIX}/lib\" rocminfo"