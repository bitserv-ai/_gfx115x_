<!-- Copyright 2026 Blackcat Informatics Inc. / 2026 bitserv-ai -->
<!-- SPDX-License-Identifier: MIT -->

# Changelog

All notable changes to the Strix Halo vLLM build system are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.0] - 2026-04-22

### Added

- **Backend smoke test** (step 36): Downloads SmolLM2-135M-Instruct and runs inference through all five backends (vLLM, llama.cpp ROCm, llama.cpp Vulkan, Lemonade SDK, Ollama). TunableOp GEMM warmup now occurs as a side effect.
- **ccache integration** (`vllm-env.sh`): Transparently intercepts all compiler invocations (cmake, ninja, pip, AITER JIT) via symlink shadowing (50 GB cache). AITER JIT recompiles drop from ~45 min to ~5 min.
- **AITER JIT pre-warm & skip list** (step 29b): Compiles all buildable AITER HIP C++ modules ahead of time. 12 CDNA-only modules are skipped declaratively in YAML, saving ~2.5 hours.
- **Dual-instance Embed + Reranker deployment**: Qwen3-VL-Embedding and Reranker running simultaneously via `VLLM_ROLES`. Added per-role `KV_CACHE_DTYPE`, `CPU_OFFLOAD_GB`, `RUNNER`, `CONVERT`, and `HF_OVERRIDES`.
- **FP8 KV cache on RDNA 3+ (gfx1151)**: Added `KV_CACHE_DTYPE=fp8_e5m2`, halving KV memory from 144 KB/token (BF16) to 72 KB/token. Enabled via 4-part patch (rocm.py, quant_utils.cuh, convert templates, .env).
- **Lemonade + llama.cpp triple-backend** (steps 33-35): Builds llama.cpp for ROCm hipBLAS, Vulkan, and CPU, managed by Lemonade SDK with generated `.env` files.
- **Multi-distro support & Auto-bootstrapping**: Auto-detects Arch, Ubuntu/Debian, Fedora/RHEL for prerequisites. Auto-installs `uv` and `yq` if missing.
- **AITER commit documentation**: Recorded PyTorch submodule commit (`9a469a608b2c...`) for full reproducibility.

### Changed

- **YAML-driven build pipeline**: All 36 build steps across 10 phases (A–J) are orchestrated from `vllm-packages.yaml` via `yq`.
- **`vllm-start.sh` uses `setsid`**: Replaced `nohup` for background launch to fix multiprocessing forks on ROCm/gfx1151.
- **V1 engine CPU weight offloading unlock**: Removed artificial CPU offloading block on non-NVIDIA platforms.
- **Native ROCm PagedAttention**: Re-enabled fused PagedAttention C++ kernel for RDNA 3.5.
- **Qwen3-VL-Embedding `CONVERT` correction**: Now uses `CONVERT=embed` to inject `DispatchPooler.for_embedding` (LAST-token pooling + L2 norm).
- **All wheels are mandatory**: Build `die`s on wheel failure instead of falling back to PyPI binaries. Old wheels are auto-pruned.
- **torch version pin relaxation**: `torch == 2.10.0` changed to `>= 2.10.0` to accept source-built wheels.
- **Embedding/Reranker configuration**: Added `--limit-mm-per-prompt` to disable video input for Qwen3-VL instances (prevents OOM during profiling).

### Fixed

- **V1 EngineCore zombie & 100% CPU idle busy-loop**: Fixed via `setsid` launch and progressive backoff (0ms → 500ms) in idle loop.
- **Qwen3VL ViT NaN on gfx1151**: Forced ViT encoder to FP32 to prevent 100% NaN from BF16 overflow in ROCm SDPA/GELU.
- **`+rms_norm` custom_ops graph partition bug**: Prevented RMSNorm from becoming an opaque barrier in Inductor graph on wave32. Yielded 7.7-8.9x speedup with AITER.
- **FP8 linear crash on gfx1x**: Fallback to Triton blockscale GEMM to avoid CDNA-only MFMA instructions.
- **Qwen3.5 hybrid model fixes**: Fixed FLA autotuner page faults, chunk_o BK/BV limits, and KV cache block_size alignment issues on RDNA 3.5.
- **Build fixes across stack**: (See `BUILD-FIXES.md` for details)
  - *TheRock*: roctx64 runtime resolution, libhipcxx atomic_codegen tests, nested yaml-cpp cstdint.
  - *AOCL-LibM*: libau_cpuid.so RPATH.
  - *PyTorch*: CK GEMM gfx1151 enablement, RPATH fixes, SFINAE removal, duplicate symbols.
  - *vLLM/AITER*: flash_attn_2_cuda import, constexpr warpSize.
  - *llama.cpp*: CPU variant build explosion, Grammar repetition threshold, --ngl long-form crash, execvp() crash.

## [0.2.0] - 2026-03-15

### Added

- **AITER source rebuild** (step 28b): Rebuilds AITER from PyTorch submodule
  source with matching CK headers, eliminating ABI mismatches from pip wheel.
- **FLA patches** (patches 11-16, 20-28): Flash Linear Attention fixes for
  Qwen3.5 hybrid model support on RDNA 3.5.
- **`vllm-packages.yaml`**: Package manifest with all repos, branches, patches,
  and build metadata in a single declarative file.
- Qwen3.5-0.8B MoE benchmark: 285.5 tok/s with FLA + hybrid model patches.

### Changed

- AITER gfx1x gate extended to cover attention, GEMM, and normalization
  (patches 2-5).
- ViT attention reverted to gfx9-only (patch 6) — CK fmha_fwd rejects ViT
  dimensions on gfx1151.

## [0.1.0] - 2026-03-12

### Added

- Initial 32-step build pipeline across 8 phases.
- 29 documented build fixes with root cause analysis.
- `build-vllm.sh`: Master build script.
- `vllm-env.sh`: Environment activation with compiler flags for Zen 5 + RDNA 3.5.
- `vllm-start.sh`, `vllm-stop.sh`, `vllm-status.sh`: Runtime management.
- Benchmark results: 1059.8 tok/s (Qwen2.5-0.5B), 391.6 tok/s (Qwen2.5-1.5B).
- 13 optimized wheel packages (torch, triton, vllm, numpy, etc.).

[Unreleased]: https://github.com/bitserv-ai/_gfx115x_/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/bitserv-ai/_gfx115x_/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bitserv-ai/_gfx115x_/releases/tag/v0.1.0
