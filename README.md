<!-- Copyright (c) 2026 paudley / 2026 bitserv-ai -->
<!-- SPDX-License-Identifier: MIT -->

# Building vLLM from Source on AMD Strix Halo / Strix Point (gfx115x)

A complete, reproducible reference for compiling the **entire vLLM inference
stack from source** on AMD Strix Halo and Strix Point APUs (Zen 5 + RDNA 3.5, gfx1150/gfx1151).

This is not a guide for installing pip wheels. Every component — from the ROCm
SDK to Python itself — is compiled from source with aggressive optimization
flags targeting the Strix Halo microarchitecture.

## Hardware Requirements

| Component | Specification |
|-----------|--------------|
| **CPU** | AMD Zen 5 (Strix Halo / Strix Point / Ryzen AI Max) |
| **GPU** | RDNA 3.5 iGPU (gfx1150/gfx1151) |
| **Memory** | 64/96/128 GB unified LPDDR5X |
| **NPU** | XDNA 2 (Phoenix) |
| **Disk** | ~100 GB free for build artifacts |
| **Kernel** | Linux 7.0-rc7+ (amdgpu + amdxdna loaded) |

## Tested Platform

This build is developed and tested on **CachyOS** (Arch-based) with the
**CachyOS kernel 7.0-rc7** (`linux-cachyos-rc`). CachyOS ships patched kernels with up-to-date amdgpu and amdxdna driver support that gfx115x GPUs require — mainline kernels prior to 7.0 do not include the necessary RDNA 3.5 firmware and drm driver changes.

| Component | Version |
|-----------|---------|
| **Distro** | CachyOS (Arch-based, rolling) |
| **Kernel** | 7.0.0-rc7+ (`linux-cachyos-rc` or equivalent) |
| **Compiler** | amdclang 23+ (TheRock ROCm SDK), host compiler: Clang/LLVM 21+ |
| **Python** | Built from source (3.13.x, PGO + LTO + amdclang) |
| **ROCm** | Built from source (TheRock nightly) |

Ubuntu and Fedora are also supported — the build script detects the distro
and provides the correct package install commands. Any distribution should
work provided the kernel is 7.0+ with the `amdgpu` and `amdxdna` modules
loaded.

## Why Build from Source?

1. **gfx1150/gfx1151 are not in upstream ROCm** (as of ROCm 6.x / early 7.x).
   TheRock ROCm nightly is the only way to get a working HIP toolchain.

2. **Unified memory architecture** means CPU and GPU share LPDDR5X.
   Cache locality optimizations (Polly, `-mprefer-vector-width=512`)
   matter more than on discrete GPUs.

3. **Native AVX-512** on Zen 5 without the clock penalty of Zen 4.
   Source builds with `-march=native` unlock full 512-bit execution.

4. **AMD-specific compiler optimizations** via amdclang's `-famd-opt`
   flag (proprietary Zen microarchitecture tuning not available in
   upstream LLVM).

## Build Pipeline (36 Steps, 9 Phases)

```
Phase A: ROCm SDK (TheRock)
  1. Clone TheRock          3. Build TheRock (~3 hours)
  2. Configure TheRock      4. Validate ROCm

Phase B: CPU Libraries + Python
  5. Build AOCL-Utils       7. Build Python 3.13 (PGO + LTO)
  6. Build AOCL-LibM        8. Create venv

Phase C: ML Framework (PyTorch + TorchVision)
  9. Clone PyTorch         12. Clone TorchVision
 10. Build PyTorch (~1-2h) 13. Build TorchVision
 11. Validate PyTorch

Phase D: Kernel Compilers
 14. Clone Triton          17. Clone AOTriton
 15. Build Triton          18. Build AOTriton
 16. Validate Triton

Phase E: Inference Engine
 19. Clone vLLM            23. Install ROCm requirements
 20. Patch amdsmi import   24. Build vLLM (AITER first)
 20b. Patch gfx115x AITER
 21. Install build deps
 22. use_existing_torch.py

Phase F: Attention (Flash Attention + AITER)
 25. Reinstall amdsmi      28. Build Flash Attention
 26. Clone Flash Attention  28b. Rebuild AITER from source (CK-aligned)
 27. Patch Flash Attention

Phase G: Validation + Warmup
  29. Smoke test + AITER JIT pre-warm

Phase H: Optimized Wheels (Zen 5 native builds for downstream venvs)
 30. Build Rust wheels     (orjson, cryptography — AVX-512 + VAES)
 31. Build C/C++ wheels    (numpy, sentencepiece, zstandard, asyncpg)
 32. Export source wheels   (torch, triton, torchvision, amd-aiter, amdsmi)

Phase I: Lemonade Inference Server
  33. Clone Lemonade + build llama.cpp (ROCm + Vulkan + CPU backends)
  34. Install Lemonade Server from source
  35. Validate Lemonade (all backends)
  36. Backend smoke test
```

### Lemonade: Triple-Backend llama.cpp

Phase I builds [llama.cpp](https://github.com/ggml-org/llama.cpp) with
three backends, managed by
[Lemonade Server](https://github.com/lemonade-sdk/lemonade) (built from
source in step 34):

| Backend | Best For | Notes |
|---------|----------|-------|
| **ROCm** (hipBLAS) | Prefill < 32K context | Primary GPU backend, uses amdclang + gfx115x HIP flags |
| **Vulkan** | Generation speed, prefill > 32K | +22% tok/s generation, no 32K VMM limitation |
| **CPU** | Embedding models, fallback | Zen 5 AVX-512, no GPU memory required |

All three backends are built under `${VLLM_DIR}/llama.cpp/build-{rocm,vulkan,cpu}`
and exposed via PATH and Lemonade env vars. Lemonade routes between
them based on workload. Each backend gets its own `.env` file with
gfx115x runtime optimizations (batch sizing, hipBLASLt, THP).

## Supported Distributions

The build script auto-detects the distro via `/etc/os-release` and adapts
prerequisite checks and install hints accordingly.

| Family | Distros | Package Manager |
|--------|---------|-----------------|
| **Arch** | CachyOS, Arch, EndeavourOS, Manjaro, Garuda | pacman |
| **Ubuntu** | Ubuntu, Debian, Linux Mint, Pop!_OS, Elementary, Zorin | apt |
| **Fedora** | Fedora, Nobara, RHEL, CentOS, Rocky, Alma | dnf |

`uv` and `yq` are **auto-bootstrapped** if not found on PATH. The
script tries `go install` first (always gets latest), then falls back to
downloading a release binary from GitHub. `uv` is pinned to a specific
version (`0.7.12`, configured in `vllm-packages.yaml`) for reproducibility.
Both tools are also installed into the venv for self-contained builds.

## Quick Start

```bash
# 1. Install system prerequisites
#    The build script will tell you exactly what's missing, but here are
#    the full install commands for each distro family:

# Arch / CachyOS:
sudo pacman -S clang lld cmake ninja git curl \
    gcc-fortran patchelf automake libtool bison flex xxd scons meson \
    vulkan-devel vulkan-radeon

# Ubuntu / Debian:
sudo apt install clang lld cmake ninja-build git curl \
    gfortran patchelf automake libtool bison flex xxd scons meson \
    libvulkan-dev mesa-vulkan-drivers

# Fedora / RHEL:
sudo dnf install clang lld cmake ninja-build git curl \
    gcc-gfortran patchelf automake libtool bison flex vim-common scons meson \
    vulkan-devel mesa-vulkan-drivers

# 2. Install a kernel with gfx115x amdgpu support (kernel 7.0+)
#    Skip if already running kernel 7.0-rc7+
#    Arch:   sudo pacman -S linux-cachyos-rc linux-cachyos-rc-headers
#    Ubuntu: Use mainline kernel PPA or HWE kernel >= 7.0
#    Fedora: Rawhide or kernel-next >= 7.0

# 3. Create the build directory (all source lives under /opt/src/vllm)
sudo mkdir -p /opt/src/vllm
sudo chown $(id -u):$(id -g) /opt/src/vllm

# 4. Run the full build
./build-vllm.sh

# 5. Activate the environment (for interactive use)
source ./vllm-env.sh
source ./vllm-env.sh --info   # Show settings
```

### Resuming and Rebuilding

```bash
./build-vllm.sh --step 14   # Resume from step 14 (e.g., after Triton fix)
./build-vllm.sh --rebuild    # Clean everything and rebuild from scratch
./build-vllm.sh --step 24 --force-rebuild vllm  # Rebuild only vllm (no full clean)
```

## Compiler Flags

### CPU (Zen 5) -- CFLAGS/CXXFLAGS

```
-O3 -march=native -flto=thin -mprefer-vector-width=512
-mavx512f -mavx512dq -mavx512vl -mavx512bw
-famd-opt                          # amdclang only: Zen microarch tuning
-mllvm -polly                      # polyhedral loop optimizer
-mllvm -polly-vectorizer=stripmine # cache hierarchy restructuring
-mllvm -inline-threshold=600       # aggressive inlining for wide pipeline
-mllvm -unroll-threshold=150       # aggressive unrolling for large ROB
-mllvm -adce-remove-loops          # dead loop cleanup
```

### GPU (RDNA 3.5, gfx1150/gfx1151) -- HIP_CLANG_FLAGS

```
--offload-arch=gfx1151
-mllvm -amdgpu-early-inline-all=true     # keep VALU busy
-mllvm -amdgpu-function-calls=false      # eliminate call overhead on iGPU
-famd-opt
```

### Rust -- RUSTFLAGS

```
-C target-cpu=znver5 -C opt-level=3
```

Explicit `znver5` (not `native`) because Rust's native detection has a bug
where it identifies znver5 but only enables SSE2. Explicit znver5 enables
all 40+ target features including AVX-512, VAES, VPCLMULQDQ, GFNI, SHA.

## Files

| File | Description |
|------|-------------|
| `build-vllm.sh` | Master build script (36-step pipeline) |
| `vllm-env.sh` | Environment activation (compiler flags, ROCm paths, venv) |
| `vllm-packages.yaml` | Package manifest (repos, branches, patches, per-distro prerequisites, bootstrap config) |
| `vllm-start.sh` | Start all vLLM inference instances (role-based, multi-model) |
| `vllm-stop.sh` | Stop all running vLLM instances (graceful SIGTERM + SIGKILL) |
| `vllm-status.sh` | Check health/PID/model status of all vLLM instances |
| `common.sh` | Shared shell helpers (logging, section headers, prerequisite checks) |
| `vllm-runtime-helpers.sh` | Shared library for start/stop/status scripts |
| `BUILD-FIXES.md` | Detailed documentation of all build patches and workarounds |
| `CHANGELOG.md` | Version history and notable changes |
| `QWEN3-VL-EMBED.md` | Qwen3-VL multimodal embedding and reranking deployment (production) |
| `QWEN3-INT8-QUANT.md` | INT8 quantization strategy for Qwen3-VL on gfx1151 (engineering deep-dive) |
| `extras/quantize_w8a16.py` | W8A16 quantization script (llmcompressor + RTN) for Qwen3-VL models |
| `extras/make-deploy-tarball.sh` | Build deploy tarball for target systems |
| `extras/install-deploy.sh` | Install deploy bundle on target system |
| `extras/DEPLOY.md` | Deploy documentation |

## Repo Variants

| Component | Repository | Branch |
|-----------|-----------|--------|
| TheRock | ROCm/TheRock | main |
| PyTorch | ROCm/pytorch | release/2.11 |
| TorchVision | pytorch/vision | v0.24.1 |
| Triton | ROCm/triton | main_perf |
| Flash Attention | ROCm/flash-attention | main_perf |
| vLLM | vllm-project/vllm | v0.24.0 |
| AOTriton | ROCm/aotriton | main |
| AOCL-LibM | amd/aocl-libm-ose | master |
| AOCL-Utils | amd/aocl-utils | main |
| AITER | ROCm/aiter | v0.1.16.post3 |
| llama.cpp | ggml-org/llama.cpp | master |
| Lemonade | lemonade-sdk/lemonade | v10.9.0 |

Note: PyTorch, Triton, and Flash Attention use the **ROCm forks**, not
upstream. The ROCm forks carry AMD-specific fixes (hipify patches, Tensile
integration, rocm_smi linkage) that haven't been upstreamed. vLLM uses
upstream (the ROCm fork is deprecated).

## Output

When complete, the build produces 13 optimized wheel packages:

| Wheel | Size | Type |
|-------|------|------|
| torch | 387M | C++/HIP |
| triton | 159M | C++/LLVM |
| vllm | 74M | C++/HIP |
| amd-aiter | 43M | C++/HIP |
| numpy | 7.2M | C (meson) |
| amdsmi | 2.1M | Pure Python |
| cryptography | 2.0M | Rust |
| sentencepiece | 1.5M | C++ (cmake) |
| torchvision | 1.4M | C++ |
| zstandard | 941K | C |
| asyncpg | 829K | Cython |
| orjson | 374K | Rust |
| flash_attn | 202K | Pure Python |

All wheels are in `/opt/src/vllm/wheels/` and can be installed into any
Python 3.13 venv.

## Using the Built Wheels

The build produces two key artifacts:

1. **Optimized CPython 3.13** at `/opt/src/vllm/python/bin/python3`
   (PGO + ThinLTO + amdclang `-famd-opt`, Zen 5 native)
2. **13 optimized wheel packages** in `/opt/src/vllm/wheels/`

Both are portable to any environment on the same machine (or any machine
with the same architecture and ROCm libraries at `/opt/src/vllm/local/lib`).

### Quick: pip install into any venv

```bash
# From any activated venv (Python 3.13 required)
pip install /opt/src/vllm/wheels/*.whl
```

### Full Setup: New project with optimized Python + wheels

This is the recommended approach for maximum performance — the optimized
Python interpreter alone provides ~5-15% speedup on compute-bound code.

```bash
# 1. Create a new project with the source-built Python
mkdir my-project && cd my-project
uv venv --python /opt/src/vllm/python/bin/python3 .venv
source .venv/bin/activate

# 2. Install all optimized wheels
uv pip install /opt/src/vllm/wheels/*.whl

# 3. Verify
python -c "import torch; print(f'PyTorch {torch.__version__}, ROCm {torch.version.hip}')"
python -c "import vllm; print(f'vLLM {vllm.__version__}')"
```

### Recommended: uv project with find-links

For uv-managed projects, add to `pyproject.toml` to have uv automatically
resolve source-built wheels from the local directory instead of PyPI:

```toml
[project]
requires-python = ">=3.13"
dependencies = [
    "vllm",
    "torch",
    "numpy",
]

[tool.uv]
find-links = ["/opt/src/vllm/wheels"]
prerelease = "if-necessary-or-explicit"
python-preference = "only-system"

override-dependencies = [
    # Source-built ROCm wheels (versions resolved via find-links after build)
    "torch",
    "triton",
    "torchvision",
    "vllm",
    "flash-attn",
    "amd-aiter",
    "amdsmi",
    # Zen 5 optimized native wheels
    "numpy",
    "cryptography",
    "orjson",
    "sentencepiece",
    "zstandard",
    "asyncpg",
]
```

Then create the venv with the optimized Python:

```bash
# Point uv at the source-built Python
uv venv --python /opt/src/vllm/python/bin/python3
uv sync
```

**How this works:**
- `find-links` tells uv to check the local wheel directory before PyPI
- `override-dependencies` pins exact versions (including dev/pre-release
  suffixes like `2.12.0a0+git...`) so uv resolves to the local wheels
- `prerelease = "if-necessary-or-explicit"` is needed because source
  builds produce pre-release version strings by default
- `python-preference = "only-system"` prevents uv from downloading a
  generic Python when the optimized one is available

Update the version strings after each rebuild — they change with every
git commit in the upstream repos. To get current versions:

```bash
ls /opt/src/vllm/wheels/*.whl | xargs -I{} basename {} | sed 's/-cp313.*//'
```

### Runtime Environment

The ROCm wheels need the TheRock libraries at runtime. Source
`vllm-env.sh` to set up all paths, or manually set:

```bash
export LD_LIBRARY_PATH="/opt/src/vllm/local/lib:${LD_LIBRARY_PATH}"
export HSA_OVERRIDE_GFX_VERSION=11.5.1    # For gfx1150/gfx1151
export ROCBLAS_USE_HIPBLASLT=1
export PYTORCH_HIP_ALLOC_CONF="expandable_segments:True"  # Reduce GPU memory fragmentation
export PYTORCH_TUNABLEOP_ENABLED=1           # Auto-tune GEMM kernels for gfx1151
export VLLM_WORKER_MULTIPROC_METHOD=spawn    # Fix AITER fork() HIP corruption
```

Or simply source the activation script:

```bash
source /path/to/_gfx115x_/vllm-env.sh
```

### Eager Mode (Default)

CUDA graph capture is incompatible with CPU weight offloading and can OOM
during profiling on 48 GB UMA. `vllm-start.sh` defaults to
`ENFORCE_EAGER=true` (no graph capture) for all roles. This can be
overridden per-role in `.env`:

```bash
VLLM_EMBED_ENFORCE_EAGER=false  # Enable CUDA graphs (more VRAM, faster)
```

### System Tuning (Optional)

For inference workloads on Strix Halo, the following sysfs/sysctl settings
improve latency and throughput:

```bash
# Lock GPU clocks to maximum (prevents iGPU downclock under light load)
echo high | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level

# Disable NUMA balancing (prevents page migration latency spikes)
echo 0 | sudo tee /proc/sys/kernel/numa_balancing
# Or persist: echo "kernel.numa_balancing = 0" | sudo tee /etc/sysctl.d/99-numa-balancing.conf
```

## Runtime Management

The `vllm-start.sh`, `vllm-stop.sh`, and `vllm-status.sh` scripts
manage multiple vLLM inference instances via a role-based configuration
system. Each role (e.g., `director`, `voice`) gets its own model, port,
device assignment, and GPU memory allocation.

### Configuration

Create a `.env` file with role definitions:

```bash
# Roles to launch (space-separated)
VLLM_ROLES="embed reranker"

# Per-role configuration
VLLM_EMBED_MODEL="Qwen/Qwen3-VL-Embedding"
VLLM_EMBED_PORT=8102
VLLM_EMBED_DEVICE=rocm
VLLM_EMBED_GPU_MEMORY_MB=10240
VLLM_EMBED_RUNNER="pooling"
VLLM_EMBED_CONVERT="embed"

VLLM_RERANKER_MODEL="Qwen/Qwen3-VL-Reranker"
VLLM_RERANKER_PORT=8103
VLLM_RERANKER_DEVICE=cpu          # CPU offload: no GPU memory needed
VLLM_RERANKER_RUNNER="pooling"
VLLM_RERANKER_CONVERT="rerank"
```

### Usage

```bash
source ./vllm-env.sh       # Activate the vLLM environment
./vllm-start.sh            # Start all roles
./vllm-status.sh           # Check health + loaded models
./vllm-stop.sh             # Graceful shutdown
```

## License

Copyright (c) 2026 paudley / 2026 bitserv-ai

[MIT](./LICENSE) — The upstream projects (TheRock, PyTorch, Triton,
vLLM, etc.) each have their own licenses. See the respective
repositories for details.
