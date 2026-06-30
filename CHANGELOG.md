<!-- Copyright 2026 Blackcat Informatics Inc. / 2026 bitserv-ai -->
<!-- SPDX-License-Identifier: MIT -->

# Changelog

All notable changes to the Strix Halo vLLM build system are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Upstream sync: [`dbfb70efc26fccf6ab2b00ee60ff0c96d37d37b0`](https://github.com/paudley/ai-notes/commit/dbfb70efc26fccf6ab2b00ee60ff0c96d37d37b0)
from `paudley/ai-notes` (2026-06-06). Evaluated commits `3f15f9f` (MTP/Atomic)
and `dbfb70e` (RUNPATH/cleanup). Adopted RUNPATH fix and runtime feature merge;
skipped Atomic TurboQuant (eval only) and parametrized build functions (our
`finalize_llamacpp_backend()` is already DRY).

### Added

- **AITER RMSNorm duplicate-pattern crash detection** (`vllm-start.sh`):
  `vllm_is_aiter_rmsnorm_duplicate_pattern_failure()` detects the
  `rocm_aiter_fusion.py` + `check_and_add_duplicate_pattern` crash signature.
  `vllm_print_duplicate_pattern_diagnostics()` reports vLLM/torch/triton
  versions and `skip_duplicates=True` patch state via embedded Python.
  Automatic one-time retry with `VLLM_ROCM_USE_AITER_RMSNORM=0`, controlled
  via `VLLM_ENABLE_AITER_RMSNORM_DUP_PATTERN_RETRY=1`. From Dillflix via
  Paudley PR #14.
- **Parametrized startup failure diagnostics** (`vllm-start.sh`):
  `vllm_print_startup_failure_details()` now searches for the first traceback
  and prints focused context around it (`VLLM_STARTUP_TRACEBACK_CONTEXT_LINES`,
  default 40). Tail length configurable via `VLLM_STARTUP_ERROR_TAIL_LINES`
  (default 120). Replaces old `tail -50` + heuristic pattern matching.
- **`VLLM_MAX_GPU_MEMORY_UTILIZATION` cap** (`vllm-start.sh`): Default 0.98.
  Prevents over-commit when converting MB to utilization fraction.
- **`HIP_VISIBLE_DEVICES`-aware VRAM query** (`vllm-runtime-helpers.sh`):
  `vllm_gpu_total_mb()` now scopes to the first visible GPU and sums APU
  partitions. More robust on multi-partition Strix Halo setups.

### Changed

- **`vllm_print_startup_failure_details` moved** from `vllm-runtime-helpers.sh`
  to `vllm-start.sh` (matches upstream layout — function is start-specific).
- **`vllm_log_optimization_state`** retains `VLLM_ENABLE_V1_MULTIPROCESSING`
  line (upstream removed it; we keep it for V1 multiprocessing debugging).
- **Profiler strategy: fully disabled** (BUILD-FIXES #56/#57 superseded by
  #105–#112): Replaced hard-wired roctx64 path hacks with proper
  `THEROCK_ENABLE_PROFILER` gating on all pre-hooks and CMake args. RCCL,
  rocBLAS, rocSPARSE, hipBLASLt, hipSPARSELt, and MIOpen now skip ROCTX
  entirely when profiler is off. ROCR-Runtime OpenCL blit kernels get
  explicit `--rocm-device-lib-path` detection. RCCL tuner macros and NVTX
  stub mode fixed. From `paudley/ai-notes` BUILD-FIXES #10b–#10h2.
- **Version-Pin Update** (pre-rebuild Schritt 4a): 12 Komponenten auf neue
  Commits/Tags aktualisiert in `vllm-packages.yaml`:

  | Komponente | alt | neu |
  |-----------|-----|-----|
  | TheRock | `4363b4c` (main) | `a512f42c` (main) |
  | PyTorch | `fb6e4ef` (develop) | `9df77ad5` (**release/2.11**) |
  | TorchVision | `9bf794d` (main) | `d801a34` (**v0.24.1**) |
  | Triton | `cb89b61` (main_perf) | `0ec280c` (main_perf) |
  | AOTriton | `1884d3d` (main) | `e71fc2a` (main) |
  | vLLM | `719735d` (main) | `ee0da84` (**v0.24.0**) |
  | AITER | `9a469a6` (main) | `27fdb59` (**v0.1.16.post3**) |
  | CPython | `1cbe481` (v3.13.3) | `8f61118` (**v3.13.9**) |
  | AOCL-Utils | `421ede6` | `deb4187` |
  | AOCL-LibM | `9e33942` | `8622391` |
  | llama.cpp | `45cac7c` | `6f4f53f` |
  | Lemonade | `d434d8b` (v10.0.0) | `02071764` (**v10.8.1**) |

  Zusätzlich: `build.cpython_version` `3.13.3`→`3.13.9`, vLLM Patch #28
  marker `torch == 2.10.0`→`torch == 2.11.0`.
- **Lemonade v10.8.1 Config Migration** (Schritt 4c): `config.json`
  `config_version` 1→2, `ctx_size` 4096→-1 (auto-tune).
  `vllm-packages.yaml` backend_versions.json sed patch aktualisiert:
  Marker `"vulkan": "b8"`→`"vulkan": "b9747"`, sed `rocm`→`rocm-stable`+
  `rocm-nightly` (v10.8.1 hat zwei ROCm-Channel).

### Fixed

- **LD_LIBRARY_PATH library mixing across llama.cpp backends** (BUILD-FIXES #103):
  Removed redundant `LD_LIBRARY_PATH` exports for llama.cpp ROCm and Vulkan
  backend directories in `vllm-env.sh`. Binaries already use RUNPATH
  (`$ORIGIN:${LOCAL_PREFIX}/lib`, set by `build-vllm.sh` via `patchelf` since
  v0.3.0). The global `LD_LIBRARY_PATH` entries caused library mixing when
  Lemonade's `llama-swap` switched between backends. Inspired by upstream
  `paudley/ai-notes` commit `dbfb70e`.
- **`eval echo` expands `$ORIGIN` as unbound shell variable** (BUILD-FIXES #104):
  Replaced `eval echo` with Bash string substitution in `patchelf_rpath`,
  `patchelf_needed`, and `file_copy` handlers in `build-vllm.sh`. Only
  `${LOCAL_PREFIX}` and `${VLLM_DIR}` are expanded; `$ORIGIN` passes through
  literally as a dynamic linker token. Eliminates the `\\$ORIGIN` escape
  convention footgun for future YAML entries.
- **roctx64 pre-hook gating** (BUILD-FIXES #105): RCCL/rocBLAS/rocSPARSE
  pre-hooks now gate on `THEROCK_ENABLE_PROFILER`, eliminating the need for
  hard-wired roctx64 paths (#56/#57 superseded).
- **RCCL ROCTX tracing disabled** (BUILD-FIXES #106): `-DROCTX=OFF` injected
  into RCCL CMake args.
- **RCCL tuner macro definitions** (BUILD-FIXES #107): `#include "plugin/nccl_tuner.h"`
  added to `rccl_common.h` for `NCCL_NUM_ALGORITHMS`/`NCCL_NUM_PROTOCOLS`.
- **RCCL NVTX stub mode** (BUILD-FIXES #108): `nvtx.h` now honors
  `NVTX_NO_IMPL` guard; `nvtx_stub.h` extended with `NCCL_NVTX3_FUNC_RANGE`.
- **hipBLASLt/hipSPARSELt/MIOpen ROCTX markers** (BUILD-FIXES #109):
  `-DHIPBLASLT_ENABLE_MARKER=OFF`, `-DHIPSPARSELT_ENABLE_MARKER=OFF`,
  `-DMIOPEN_USE_ROCTRACER=OFF` injected into CMake args.
- **rocBLAS roctracer probe** (BUILD-FIXES #110): Probe gated on
  `BUILD_SHARED_LIBS AND ROCTX`; `DISABLE_ROCTX` compile definition added.
- **rocSPARSE BUILD_WITH_ROCTX** (BUILD-FIXES #111):
  `-DBUILD_WITH_ROCTX=OFF` injected into super-project CMake args.
- **ROCR-Runtime OpenCL blit kernels** (BUILD-FIXES #112): Migrated from
  inline sed to `.patch` file (`patches/rocr-blit-device-libs.patch`).
  Previous sed searched `CMAKE_PREFIX_PATH/llvm/amdgcn/bitcode` which does
  not exist in TheRock's build tree. The patch uses
  `find_package(AMDDeviceLibs QUIET CONFIG)` to resolve
  `AMD_DEVICE_LIBS_PREFIX/amdgcn/bitcode` via TheRock's dep-provider system,
  with `CMAKE_PREFIX_PATH`-based fallback for standalone builds.
- **rocRAND configure: find_package(amd_smi) before project()**
  (BUILD-FIXES #114): TheRock commit `dd51a250b` added
  `therock_primlibs_benchmark_deps.cmake` via `CMAKE_INCLUDES`, which runs
  before `project()`. `find_package(amd_smi)` calls
  `add_library(SHARED IMPORTED)` while `CMAKE_SYSTEM_NAME` is unset →
  "target platform does not support dynamic linking". Patch
  (`patches/therock-primlibs-benchmark-deps.patch`) guards with
  `if(BUILD_BENCHMARK)`.
- **`build-vllm.sh` patch handler: `${VLLM_DIR}` expansion** — the `patch`
  type in `apply_patches()` now expands `${VLLM_DIR}` and `${LOCAL_PREFIX}`
  in the `path` field, matching the existing behavior of `patchelf_rpath`
  and `file_copy` handlers.
- **rocprofiler-sdk configure: rocdecode/rocjpeg missing from RUNTIME_DEPS**
  (BUILD-FIXES #115): rocprofiler-sdk calls `find_package(rocdecode)` and
  `find_package(rocjpeg)` in `rocprofiler_config_interfaces.cmake`, but
  TheRock did not declare them as `RUNTIME_DEPS` for rocprofiler-sdk. With
  `EXCLUDE_FROM_ALL`, rocdecode was only configured but never built/staged,
  leaving `rocdecode-config.cmake` incomplete (missing
  `rocdecode-targets.cmake` and include dir). Patch
  (`patches/rocprofiler-sdk-rocdecode-deps.patch`) adds rocdecode and rocjpeg
  to `RUNTIME_DEPS` in `profiler/CMakeLists.txt`. Follow-up patch
  (`patches/therock-media-libs-before-profiler.patch`) moves
  `add_subdirectory(media-libs)` before `add_subdirectory(profiler)` in
  TheRock's root `CMakeLists.txt`, because `therock_cmake_subproject_declare`
  requires `RUNTIME_DEPS` targets to already exist when processing
  `profiler/CMakeLists.txt`.
- **Triton sampler bypass disabled** (BUILD-FIXES #41): The hard-bypass
  of the Triton top-k/top-p sampler on gfx1151 is commented out in
  `vllm-packages.yaml`. The page fault may be version-specific rather than
  architecture-specific. The next rebuild will test whether the Triton
  sampler works without the bypass.
- **PyTorch ROCm import failure diagnostics and auto-recovery**
  (BUILD-FIXES #113): `validate_pytorch()` in `build-vllm.sh` now detects
  the known `libtorch_hip.so: undefined symbol: _ZN2at4cuda4blas4gemm`
  failure, dumps diagnostics (LD_DEBUG trace, readelf, ldd, nm), and
  attempts a one-time clean wheel reinstall before giving up. Three new
  helper functions: `is_known_pytorch_rocm_import_failure()`,
  `diagnose_pytorch_import_failure()`, `retry_pytorch_wheel_install()`.
  From `paudley/ai-notes` (Dillflix via PR #14).
- **Patch #36 (ViT AITER FA revert) obsolete** (BUILD-FIXES #36): vLLM
  v0.24.0 now gates ViT AITER FA on `on_gfx9()` only — the
  `on_gfx9() or on_gfx1x()` marker no longer exists. Patch auto-skipped.
- **`enginecore-idle-backoff.patch` regenerated** (BUILD-FIXES #96) for
  vLLM v0.24.0: `has_unfinished_requests()` → `has_requests()` rename,
  updated line numbers. `git apply --check` passes.
- **`aiter-fp4-import-fix.patch` regenerated** (BUILD-FIXES #97) for
  vLLM v0.24.0: line numbers shifted (1235→1731), third occurrence
  (`is_tgemm_enabled`) added. All three `on_gfx950()` → `on_gfx9()`.
- **`handle_rebuild()` read-only packfiles** (`build-vllm.sh`): `rm -r`
  → `rm -rf` at 3 locations. Git packfiles (`.pack`) are read-only;
  `rm -r` fails with permission denied during `--rebuild` cleanup.
- **Temp venv creation before Step 8** (`build-vllm.sh`): TheRock (Step 3)
  requires Python build dependencies (`mako`, `jinja2`, etc.) that must
  be installed in a venv. Since CPython (Step 7) builds the final venv,
  a temporary venv with system Python is now created before TheRock
  configure to avoid `pip install` failures.
- **TheRock build parallelism limited** (`build-vllm.sh`):
  `CMAKE_BUILD_PARALLEL_LEVEL=16` env var + `ninja -j16` in
  `build_therock()`. TheRock uses 2-level parallelism (outer ninja
  schedules sub-projects, each spawning its own ninja). Without the
  env var, inner ninja inherits `-j$(nproc)` causing CPU oversubscription
  and thermal throttling.
- **`mako` added to `therock.build_dependencies`** (`vllm-packages.yaml`):
  TheRock's mesa sub-project requires the `mako` Python package at build
  time. Was missing from build dependencies, causing configure failure.

## [0.4.0] - 2026-06-29

Upstream sync: [`b453c3363aff30d38454f1904a91584baaad889b`](https://github.com/paudley/ai-notes/commit/b453c3363aff30d38454f1904a91584baaad889b)
from `paudley/ai-notes` (2026-04-22).

Cherry-picked: #98 (clone_pkg hardening), #99 (AITER JIT locks), #100 (smoke test --simple-io).
Skipped: duckdb wheel addition (not needed for inference stack), llamacpp branch pin to master (own branch), warmup pass changes (already handled by our --no-conversation/--log-disable).

### Added

- **W8A16 Quantisierung**: `quantize_w8a16.py` Skript (llmcompressor + RTN)
  für Qwen3-VL-Embedding und Reranker. 9.9 GiB/Modell vs. 17.3 GiB BF16.
- **AITER W8A16 Benchmarks**: 3.5× Embed-Warm-Speedup (0.56s → 0.16s),
  8.5× Reranker-Warm-Speedup (1.51s → 0.178s). Determinismus CosSim = 1.0.
- **Concurrent Pipeline**: Embed+Reranker parallel in 0.32s.
- **30-Min Burn-Test**: 8344 Requests, 0 Errors, VRAM-Delta +0.000 GiB.
- **AITER JIT Cache**: Cold-Start ~16 Min, danach 0 s (via `~/.triton/cache/`
  + `~/.cache/vllm/`). Startup-Timeout 1200 s in `.env`.
- **Dual-Instance via `.env`**: `VLLM_ROLES=dual`, `VLLM_ROCM_USE_AITER=1`.
- **Patch Policy** (`AGENTS.md`): Neu → `.patch`-Files, Bestand → inline;
  YAML bleibt Source of Truth.
- **`patches/`-Verzeichnis**: 7 `.patch`-Files ins Repo eingebracht
  (v0.3.0 hatte keine versionierten Patches):
  `aiter-fp4-import-fix.patch` (#97),
  `fp8-e5m2-quant-utils.patch` (#92/#93),
  `enginecore-idle-backoff.patch` (#96),
  `env-override-hip-blocking-sync.patch` (#101),
  `skip-distributed-single-gpu.patch` (#102),
  `cmake-zen4-only.patch` (#80),
  `grammar-max-rep-threshold.patch` (#81).
- **QWEN3-INT8-QUANT.md**: Neues Engineering-Dokument — INT8-Quantisierungs-
  Strategie (W8A16 Production, W8A8 Failure Analysis, AITER Unlock,
  Kernel Dispatch, Memory Budget, Performance Benchmarks).

### Changed

- **QWEN3-VL-EMBED.md**: Vollständig überarbeitet. Aktuelle Abschnitte:
  Model Details, vLLM Runtime Adaptations, vLLM Server Configuration,
  HTTP API Reference, Memory Tuning & Alternative Configurations.
- **`.gitignore`**: `testing/`, `techdoc/`, `TODO.md`, `drafts/`, `_backup/`
  unter "bitserv-ai internal" zusammengefasst.

### Fixed

- **ROCm HSA BusyWaitSignal 100% CPU idle** (BUILD-FIXES #101):
  `hipSetDeviceFlags(hipDeviceScheduleBlockingSync)` in `env_override.py`
  before `import torch`. Eliminates persistent HSA polling threads that
  spin 100% CPU per GPU context even when idle. Idle power ~38 W → ~5 W.
  `patches/env-override-hip-blocking-sync.patch`.
- **Single-GPU distributed init skip** (BUILD-FIXES #102):
  `SingleGPUGroup` avoids creating ~13 epoll threads per EngineCore from
  `init_process_group("gloo")`/`new_group()` when `world_size=1`. All
  collective operations are identity no-ops. Zero idle CPU, ~2 W saved per
  instance. `patches/skip-distributed-single-gpu.patch`.
- **AITER FP4 Import** (`_aiter_ops.py`): `on_gfx950()` → `on_gfx9()`
  (BUILD-FIXES #97, YAML patch #34).
- **FP8 E5M2 C++ Typen** (`quant_utils.cuh`): `.patch`-File verfügbar,
  vorher untracked live-edit (BUILD-FIXES #92/#93, YAML patch #35).
- **`clone_pkg()` submodule pull protection** (BUILD-FIXES #98):
  `--no-recurse-submodules`, `--ff-only`, detached-HEAD guard,
  explicit `git submodule sync --recursive`. Cherry-picked from
  `paudley/ai-notes` `b453c33`.
- **AITER JIT stale FileBaton lock cleanup** (BUILD-FIXES #99):
  Auto-removes orphaned `lock_*` files before pre-warm. Cherry-picked
  from `paudley/ai-notes` `b453c33`.
- **llama.cpp smoke test `--simple-io`** (BUILD-FIXES #100):
  Adds `--simple-io` flag and awk-based response extraction for both
  ROCm and Vulkan backends. Cherry-picked from `paudley/ai-notes`
  `b453c33`.

## [0.3.0] - 2026-04-22

### Added

- **Backend smoke test** (step 36): Downloads SmolLM2-135M-Instruct and runs inference through all five backends (vLLM, llama.cpp ROCm, llama.cpp Vulkan, Lemonade SDK, Ollama). TunableOp GEMM warmup now occurs as a side effect.
- **ccache integration** (`vllm-env.sh`): Transparently intercepts all compiler invocations (cmake, ninja, pip, AITER JIT) via symlink shadowing (50 GB cache). AITER JIT recompiles drop from ~45 min to ~5 min.
- **AITER JIT pre-warm & skip list** (step 29b): Compiles all buildable AITER HIP C++ modules ahead of time. 12 CDNA-only modules are skipped declaratively in YAML, saving ~2.5 hours.
- **Dual-instance Embed + Reranker deployment**: Qwen3-VL-Embedding and Reranker running simultaneously via `VLLM_ROLES`. Added per-role `KV_CACHE_DTYPE`, `CPU_OFFLOAD_GB`, `RUNNER`, `CONVERT`, and `HF_OVERRIDES`.
- **FP8 KV cache on RDNA 3+ (gfx1151)** (BUILD-FIXES #92/#93): Added `KV_CACHE_DTYPE=fp8_e5m2`, halving KV memory from 144 KB/token (BF16) to 72 KB/token. Enabled via 4-part patch (rocm.py, quant_utils.cuh, convert templates, .env).
- **Lemonade + llama.cpp triple-backend** (steps 33-35): Builds llama.cpp for ROCm hipBLAS, Vulkan, and CPU, managed by Lemonade SDK with generated `.env` files.
- **Multi-distro support & Auto-bootstrapping**: Auto-detects Arch, Ubuntu/Debian, Fedora/RHEL for prerequisites. Auto-installs `uv` and `yq` if missing.
- **AITER commit documentation**: Recorded PyTorch submodule commit (`9a469a608b2c...`) for full reproducibility.

### Changed

- **YAML-driven build pipeline**: All 36 build steps across 10 phases (A–J) are orchestrated from `vllm-packages.yaml` via `yq`.
- **`vllm-start.sh` uses `setsid`**: Replaced `nohup` for background launch to fix multiprocessing forks on ROCm/gfx1151.
- **V1 engine CPU weight offloading unlock**: Removed artificial CPU offloading block on non-NVIDIA platforms.
- **Native ROCm PagedAttention**: Re-enabled fused PagedAttention C++ kernel for RDNA 3.5.
- **Qwen3-VL-Embedding `CONVERT` correction** (BUILD-FIXES #90): Now uses `CONVERT=embed` to inject `DispatchPooler.for_embedding` (LAST-token pooling + L2 norm).
- **All wheels are mandatory**: Build `die`s on wheel failure instead of falling back to PyPI binaries. Old wheels are auto-pruned.
- **torch version pin relaxation**: `torch == 2.10.0` changed to `>= 2.10.0` to accept source-built wheels.
- **Embedding/Reranker configuration** (BUILD-FIXES #91): Added `--limit-mm-per-prompt` to disable video input for Qwen3-VL instances (prevents OOM during profiling).
- **`--skip-mm-profiling` per-role flag** (BUILD-FIXES #95): Added `VLLM_<ROLE>_SKIP_MM_PROFILING` config variable in `vllm-start.sh`.

### Fixed

- **V1 EngineCore zombie on ROCm/gfx1151 with `nohup`** (BUILD-FIXES #94): Fixed via `setsid` launch. **V1 EngineCore 100% CPU idle busy-loop** (BUILD-FIXES #96): Fixed via progressive backoff (0ms → 500ms) in idle loop.
- **ROCm HSA BusyWaitSignal 100% CPU per VLLM::EngineCore**: Fixed via `hipSetDeviceFlags(hipDeviceScheduleBlockingSync)` in `env_override.py`, called before `import torch`. Reduces idle CPU from ~100% per core to ~1%. (BUILD-FIXES #101)
- **Qwen3VL ViT NaN on gfx1151** (BUILD-FIXES #89): Forced ViT encoder to FP32 to prevent 100% NaN from BF16 overflow in ROCm SDPA/GELU.
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

[Unreleased]: https://github.com/bitserv-ai/_gfx115x_/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/bitserv-ai/_gfx115x_/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/bitserv-ai/_gfx115x_/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bitserv-ai/_gfx115x_/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bitserv-ai/_gfx115x_/releases/tag/v0.1.0
