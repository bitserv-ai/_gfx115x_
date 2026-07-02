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
- **`--force-rebuild` CLI flag** (BUILD-FIXES #142, `build-vllm.sh`):
  `--force-rebuild vllm,aiter` bypasses `should_skip_step()` for the
  specified packages, enabling targeted rebuilds without `--rebuild`
  (which wipes everything). Usage:
  `./build-vllm.sh --step 19 --force-rebuild vllm`
- **Build pipeline skip markers** (BUILD-FIXES #141, `build-vllm.sh`):
  `build_vllm()`, `rebuild_aiter()`, and `build_flash_attention()` now
  call `should_skip_step()` — vLLM's YAML `skip_check` was defined but
  never invoked (bug). AITER and Flash Attention get new YAML
  `skip_check` entries (`type: import`). Eliminates ~30 min of
  unnecessary rebuilds on `--step 19` resume when packages haven't
  changed.
- **AITER JIT cache-intact fast path** (BUILD-FIXES #141,
  `build-vllm.sh`): `warmup_aiter_jit()` short-circuits when all
  expected `.so` files are present in the JIT directory. Avoids
  re-importing torch+aiter and iterating 67 modules just to print
  "already built" for each.
- **YAML `skip_check` for AITER and Flash Attention**
  (`vllm-packages.yaml`): New import-based skip checks for `aiter`
  (`from aiter._version import __version__`) and `flash_attention`
  (`import flash_attn; print(flash_attn.__version__)`).
- **New patch files** (16 since v0.4.0, total now 23):

  | Patch | BUILD-FIXES | Target |
  |-------|-------------|--------|
  | `aiter-gate-gfx1x.patch` | #133 (R.6) | vLLM — top-level AITER gate for gfx1x |
  | `aiter-fa-gfx1x-gate.patch` | #133 (R.6) | vLLM — Flash Attention backend gate |
  | `aiter-fusion-skip-duplicates.patch` | #133 (R.6) | vLLM — 8/8 register_replacement calls |
  | `fla-chunk-delta-h-gfx1151.patch` | #133 (R.6) | vLLM — 5 FLA fixes |
  | `fla-chunk-o-gfx1151.patch` | #133 (R.6) | vLLM — 4 FLA fixes |
  | `spinloop-x86intrin.patch` | #134 | vLLM — Clang 23 `mwaitxintrin.h` guard |
  | `triton-or-chain-fix.patch` | #135 | vLLM — Triton `or` chain parentheses |
  | `triton-knobs-import-fix.patch` | #136 | vLLM — `triton.knobs` try/except guard |
  | `rocr-blit-device-libs.patch` | #112 | TheRock — ROCR blit kernel device-lib-path |
  | `rocprofiler-sdk-rocdecode-deps.patch` | #115 | TheRock — rocdecode/rocjpeg RUNTIME_DEPS |
  | `therock-media-libs-before-profiler.patch` | #115 | TheRock — media-libs subdir ordering |
  | `therock-primlibs-benchmark-deps.patch` | #119 | TheRock — kpack zstandard dep |
  | `therock-dep-provider-no-registry.patch` | #119 | TheRock — Package Registry shadowing |
  | `rocblas-roctx-gating.patch` | #105–#112 | TheRock — ROCTX profiler gating |
  | `rccl-iostream-include.patch` | #117 | TheRock — missing `<iostream>`/`<map>` (GCC 15) |
  | `miopen-ciso646-warnings.patch` | #119 | TheRock — `<ciso646>` #warning |

### Changed

- **`vllm_print_startup_failure_details` moved** from `vllm-runtime-helpers.sh`
  to `vllm-start.sh` (matches upstream layout — function is start-specific).
- **`vllm_log_optimization_state`** retains `VLLM_ENABLE_V1_MULTIPROCESSING`
  line (upstream removed it; we keep it for V1 multiprocessing debugging).
- **vLLM v0.24.0 patch compatibility**: Patch #36 (ViT AITER FA revert)
  obsolete — upstream now gates on `on_gfx9()` only. Patches #96
  (enginecore-idle-backoff) and #97 (aiter-fp4-import-fix) regenerated
  for renamed symbols and shifted line numbers.
- **vLLM patch refactor (R.6, BUILD-FIXES #133)**: 15 broken/no-op sed
  patches removed, 5 new git patches created, 2 pre-existing git patches
  regenerated. Patch count 36→21. All sed substring/marker bugs that
  caused triple-imports, NameErrors, and partial application eliminated.
  `clean_generated: true` added to vLLM package to prevent dirty working
  tree from persisting across builds.
- **Triton sampler bypass disabled** (BUILD-FIXES #41): Hard-bypass of
  Triton top-k/top-p sampler on gfx1151 commented out — page fault may
  be version-specific, not architecture-specific.
- **TheRock build parallelism**: `CMAKE_BUILD_PARALLEL_LEVEL=16` + `ninja
  -j16` in `build_therock()` to prevent CPU oversubscription from
  2-level ninja parallelism.
- **Version-Pin Update** (pre-rebuild step 4a): 12 components updated to
  new commits/tags in `vllm-packages.yaml`:

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

  Additionally: `build.cpython_version` `3.13.3`→`3.13.9`, vLLM Patch #28
  marker `torch == 2.10.0`→`torch == 2.11.0`.
- **Lemonade v10.8.1 Config Migration** (step 4c): `config.json`
  `config_version` 1→2, `ctx_size` 4096→-1 (auto-tune).
  `vllm-packages.yaml` backend_versions.json sed patch updated:
  Marker `"vulkan": "b8"`→`"vulkan": "b9747"`, sed `rocm`→`rocm-stable`+
  `rocm-nightly` (v10.8.1 has two ROCm channels).
- **Audit fixes Phase 1–3** (commit `b858938`): 24 items across
  runtime bugs, pipeline hardening, and documentation drift:
  - Phase 1 (Quick Wins): `{{ nproc }}` template bug, TRUST_REMOTE_CODE
    boolean parsing, dead patch paths, step count, version pins.
  - Phase 2 (Runtime): Kill process on health-check timeout, kill
    process group in vllm-stop.sh, health-check on 127.0.0.1, rebuild
    cleanup, `/dev/kfd` check moved to validate_rocm, torchvision
    restore, `.pytorch-rebuilt-marker` trap EXIT, amd-aiter uninstall.
  - Phase 3 (Pipeline): Multi-lib skip check, `validate_pkg die` mode,
    TheRock commit marker, lemonade clone dedup, lemonade `shallow:
    false`, llama.cpp multi-backend skip, tee limitation documented,
    `eval` → `envsubst` (security).
- **AITER JIT pre-warm timing documented** (BUILD-FIXES #144):
  `module_moe_ck2stages` generates 200+ kernel variants (~55min).
  Total pre-warm ~1h42min on first run. Cached on subsequent runs
  unless AITER is rebuilt.

### Fixed

- **LD_LIBRARY_PATH library mixing** (BUILD-FIXES #103): Removed redundant
  exports for llama.cpp backends in `vllm-env.sh`. Binaries use RUNPATH.
- **`eval echo` `$ORIGIN` expansion** (BUILD-FIXES #104): Replaced with
  Bash string substitution in patchelf handlers.
- **Profiler/ROCTX fully disabled** (BUILD-FIXES #105–#112): All ROCTX
  paths, CMake args, and pre-hooks gated on `THEROCK_ENABLE_PROFILER`.
  RCCL, rocBLAS, rocSPARSE, hipBLASLt, hipSPARSELt, MIOpen. ROCR blit
  kernels get explicit device-lib-path. Migrated to `.patch` files.
- **PyTorch ROCm import diagnostics** (BUILD-FIXES #113): Auto-detects
  known `libtorch_hip.so` symbol failure, dumps diagnostics, retries
  wheel install.
- **TheRock configure/build fixes** (BUILD-FIXES #114–#119): rocRAND
  `find_package(amd_smi)` before `project()`; rocprofiler-sdk
  rocdecode/rocjpeg RUNTIME_DEPS + media-libs ordering; rccl missing
  `<iostream>`/`<map>`/`<string>` (GCC 15); kpack `zstandard` dep;
  dep-provider Package Registry shadowing; MIOpen `<ciso646>` #warning.
- **TheRock build scope & configure** (BUILD-FIXES #120–#123):
  `THEROCK_TEST_AMDGPU_TARGETS=gfx1151` + 6 component disables;
  `configure_therock()` call added to `build_therock()`; `CC`/`CXX`
  unset before TheRock cmake; rccl patch CRLF fix.
- **Configure deps fixes** (BUILD-FIXES #124–#125): CppHeaderParser
  installed into venv; AOCL-LibM amdclang PATH export.
- **PyTorch family build fixes** (BUILD-FIXES #126–#129): Submodule
  init for hipify; `ROCM_SOURCE_DIR` export + stale cache detection;
  `libomp.so` NEEDED on `libtorch_cpu.so`; TorchVision
  `setuptools<81`.
- **AOTriton/Triton build fixes** (BUILD-FIXES #130–#132): Triton
  submodule init; both backends loaded (`["amd", "nvidia"]`) for NVWS
  dialect dependency; GSan CUDA runtime disabled; `TRITON_BUILD_UT=OFF`;
  `git checkout` restoration for idempotent patch retries.
- **vLLM v0.24.0 patch refactor** (BUILD-FIXES #133): 15 sed patches
  broken by upstream API renames (`TORCH_CHECK`→`STD_TORCH_CHECK`,
  `at::ScalarType`→`torch::headeronly::ScalarType`, `FLA_GDN_FIX_BT`→
  `FLA_CHUNK_SIZE`, `KV_DTYPE` string→`KV_CACHE_DTYPE` enum), removed
  code paths (`is_eager_execution`, offload assertion, FLA warmup loop),
  and sed substring/marker bugs (triple-import, 3/8 skip_duplicates,
  NameError from unimported `is_amd`). 5 new git patches + 2 regenerated.
- **spinloop.cpp Clang 23 compatibility** (BUILD-FIXES #134):
  `mwaitxintrin.h` → `x86intrin.h` — Clang 23 forbids direct inclusion
  of sub-architecture intrinsics headers.
- **Triton chained `or` parse error** (BUILD-FIXES #135): Triton
  `main_perf` rejects `A or B or C` without parentheses. Added
  explicit grouping `(A or B) or C` in `penalties.py`.
  `triton-or-chain-fix.patch`.
- **Triton `knobs` module missing** (BUILD-FIXES #136): `triton.knobs`
  does not exist in `main_perf` @ `0ec280cf`. Wrapped both
  `from triton import knobs` calls in `jit_monitor.py` with
  `try/except ImportError`. `triton-knobs-import-fix.patch`.
- **EngineCore HIP corruption on fork** (BUILD-FIXES #137): AITER `.so`
  modules partially initialize the HIP runtime at import time via
  dlopen constructors. `fork()` passes corrupted state to the child,
  causing `hipErrorInvalidValue`. `VLLM_WORKER_MULTIPROC_METHOD=spawn`
  added to `vllm-env.sh`.
- **llama.cpp ROCm libomp.so missing** (BUILD-FIXES #138): ROCm backend
  call to `finalize_llamacpp_backend()` passed `"skip"` for libomp
  copy, but `libomp.so` lives at `${LOCAL_PREFIX}/llvm/lib/` — outside
  RUNPATH `$ORIGIN:${LOCAL_PREFIX}/lib`. Removed `"skip"` argument
  so libomp.so is copied to the backend directory.
- **llama.cpp shallow clone misses pinned commit** (BUILD-FIXES #139):
  `shallow: true` fetches only branch HEAD; pinned commit `6f4f53f`
  was not HEAD. Changed to `shallow: false` in `vllm-packages.yaml`.
- **`pipeline_model_parallel_size` → `pipeline_parallel_size`**
  (BUILD-FIXES #140): v0.24.0 renamed the `ParallelConfig` attribute.
  Updated `skip-distributed-single-gpu.patch` to use the new name.
- **Triton `target_info` version mismatch** (BUILD-FIXES #143):
  vLLM's `triton_kernels` package imports `triton.language.target_info`,
  which doesn't exist in our Triton 3.0.0 (`main_perf`). Non-fatal —
  vLLM falls back to `ROCM_ATTN`. Requires Triton upgrade for full fix.
- **TunableOp ROCBLAS_VERSION validator** (BUILD-FIXES #145):
  TheRock source-built rocBLAS includes a git hash that fails
  TunableOp's version validator. Expected behavior — stale tuning
  data is correctly discarded.
- **23k+ clang "argument unused" warnings suppressed** (BUILD-FIXES #146):
  `-Wno-error=unused-command-line-argument` → `-Wno-unused-command-line-argument`
  in `vllm-env.sh` and `build-vllm.sh`. Eliminates 23,496 cosmetic warnings
  from global CFLAGS propagating to link steps.
- **setuptools version conflict** (BUILD-FIXES #147): Pinned `setuptools<80`
  in `vllm-packages.yaml` — latest 82.0.1 violated vLLM `<80` and torch `<82`.
- **Smoke-test provenance false-positive** (BUILD-FIXES #148): Source-built
  wheels (`+git<sha>` suffix) were flagged "may not be from source build"
  because `__file__` path check only matched source tree, not venv install.
- **AOTriton LLVM WERROR failures** (BUILD-FIXES #149): Added
  `-DLLVM_ENABLE_WERROR=OFF` to `TRITON_APPEND_CMAKE_ARGS` — eliminates 7
  guaranteed build failures from missing NVWS tablegen headers.

## [0.4.0] - 2026-06-29

Upstream sync: [`b453c3363aff30d38454f1904a91584baaad889b`](https://github.com/paudley/ai-notes/commit/b453c3363aff30d38454f1904a91584baaad889b)
from `paudley/ai-notes` (2026-04-22).

Cherry-picked: #98 (clone_pkg hardening), #99 (AITER JIT locks), #100 (smoke test --simple-io).
Skipped: duckdb wheel addition (not needed for inference stack), llamacpp branch pin to master (own branch), warmup pass changes (already handled by our --no-conversation/--log-disable).

### Added

- **W8A16 Quantization**: `quantize_w8a16.py` script (llmcompressor + RTN)
  for Qwen3-VL-Embedding and Reranker. 9.9 GiB/model vs. 17.3 GiB BF16.
- **AITER W8A16 Benchmarks**: 3.5× Embed warm speedup (0.56s → 0.16s),
  8.5× Reranker warm speedup (1.51s → 0.178s). Determinism CosSim = 1.0.
- **Concurrent Pipeline**: Embed+Reranker parallel in 0.32s.
- **30-Min Burn-Test**: 8344 requests, 0 errors, VRAM delta +0.000 GiB.
- **AITER JIT Cache**: Cold start ~16 min, then 0 s (via `~/.triton/cache/`
  + `~/.cache/vllm/`). Startup timeout 1200 s in `.env`.
- **Dual-Instance via `.env`**: `VLLM_ROLES=dual`, `VLLM_ROCM_USE_AITER=1`.
- **Patch Policy** (`AGENTS.md`): New → `.patch` files, existing → inline;
  YAML remains source of truth.
- **`patches/` directory**: 7 `.patch` files added to repo
  (v0.3.0 had no versioned patches):
  `aiter-fp4-import-fix.patch` (#97),
  `fp8-e5m2-quant-utils.patch` (#92/#93),
  `enginecore-idle-backoff.patch` (#96),
  `env-override-hip-blocking-sync.patch` (#101),
  `skip-distributed-single-gpu.patch` (#102),
  `cmake-zen4-only.patch` (#80),
  `grammar-max-rep-threshold.patch` (#81).
- **QWEN3-INT8-QUANT.md**: New engineering document — INT8 quantization
  strategy (W8A16 production, W8A8 failure analysis, AITER unlock,
  kernel dispatch, memory budget, performance benchmarks).

### Changed

- **QWEN3-VL-EMBED.md**: Fully revised. Current sections:
  Model Details, vLLM Runtime Adaptations, vLLM Server Configuration,
  HTTP API Reference, Memory Tuning & Alternative Configurations.
- **`.gitignore`**: `testing/`, `techdoc/`, `TODO.md`, `drafts/`, `_backup/`
  consolidated under "bitserv-ai internal".

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
- **FP8 E5M2 C++ Types** (`quant_utils.cuh`): `.patch` file available,
  previously untracked live-edit (BUILD-FIXES #92/#93, YAML patch #35).
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
