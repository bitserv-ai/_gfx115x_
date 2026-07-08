<!-- Copyright 2026 Blackcat Informatics Inc. / 2026 bitserv-ai -->
<!-- SPDX-License-Identifier: MIT -->

# Changelog

All notable changes to the Strix Halo vLLM build system are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **llama.cpp b9842 → b9873**: DFlash p-min guard, KV-Injection
  assertion guard (PR #25215, AMD-authored), GDN MTP copy
  optimisation, post-revert scheduler stability. Both build patches
  revalidated against the new tree. (BUILD-FIXES #157)
- **Hybrid attention patches #160 → #164**: Replaced 4 patch files
  (shrink/expand only) with 8 patch files backporting mike07026's
  engine-layer fixes (commits `5418233`, `e05ffb0`, `51de10c`,
  `65e06f8`, `f9c9a19`). Adds `cell_zero()` with full field clearing
  + R/S tensor zeroing, checkpoint save/restore around shrink/expand,
  `seq_pos_min` hybrid fix (attn-only), `seq_rm` fallback to
  `cell_zero`, `PARTIAL_ONLY` for hybrid state write/read, `build_rs`
  snapshot plane zeroing, anchor-tracking checkpoint strategy,
  recurrent checkpoint restore path for `n_swa==0`, `pending_h`
  zeroing for MTP. Fixes crashes at `n_parallel > 1` and forced
  re-processing on multi-turn. Adapted to our base (SRV_TRC logging,
  `message_spans` checkpoint API). MTP fixes (GDN shift-register,
  premature EOS, Leviathan acceptance) deferred. (BUILD-FIXES #164)

### Added

- **Hybrid attention recurrent state shrink/expand**: Backport PR #24785
  (Moltes94) — `recurrent_shrink`/`recurrent_expand` mechanism from
  BeeLlama. Prevents forced full prompt re-processing on Gated DeltaNet
  models (Qwen3.6 etc.) by resizing the recurrent state to 1 cell
  before prompt cache save/load and expanding back after. Auto-disables
  context checkpoints on AMD GPUs for non-recurrent models (issue
  #20176). 4 patch files: API, context, memory-recurrent, server.
  (BUILD-FIXES #160)

### Fixed

- **TRITON_ATTN `make_tensor_descriptor` crash** (BUILD-FIXES #159):
  `triton_unified_attention.py` calls `tl.make_tensor_descriptor` in
  `@triton.jit` helpers that are XPU-only (`USE_TD=False` on ROCm), but
  Triton's JIT AST visitor parses all nodes before constexpr pruning,
  triggering `AttributeError` on Triton 3.0.0. Module-level fallback stub
  mirrors FLA ops pattern (upstream #37088/#38981). Enables
  `int8_per_token_head` KV-cache dtype with TRITON_ATTN.
- **Lemonade v10.9.0 backend version display**: Lemonade reads
  `version.txt` from its own cache directory, not from custom binary
  paths. Build-Script Step 35 publishes `version.txt` to
  `~/.cache/lemonade/bin/llamacpp/<backend>/` so the web UI shows
  "installed" instead of "not installed". (BUILD-FIXES #158)
- **Stale vLLM wheel after Python-only patch changes** (BUILD-FIXES
  #161): `should_skip_step` for vLLM used an `import`-type check that
  skipped Step 24 when vLLM was importable — even if patches had
  changed. A patched source tree + existing old wheel (without patch)
  resulted in the unpatched wheel staying installed. Fix: patch-hash
  comparison in `apply_patches`/`build_vllm` bypasses skip when patches
  change; post-install MD5 verification of a key Python file catches
  any remaining source-vs-site-packages discrepancy.
- **TRITON_ATTN chained `or` crash** (BUILD-FIXES #162):
  `compute_tile_loop_bounds` in `triton_attention_helpers.py` uses a
  3-way `or` chain that Triton's AST-to-TTIR compiler rejects with
  `UnsupportedLanguageConstruct`. Same root cause as #135 but in a
  different source file. Fix: add parentheses. Enables
  `int8_per_token_head` KV-cache with TRITON_ATTN (the
  `make_tensor_descriptor` fix #159 alone was insufficient).
- **Lemonade TheRock version-gate mismatch** (BUILD-FIXES #163):
  Lemonade v10.9.0 downloads its own TheRock ROCm 7.13.0 (~2 GB)
  despite a self-built TheRock 7.15.0 at `/opt/src/vllm/local/`.
  `will_install_therock()` compares the version from
  `backend_versions.json` against the system ROCm found via
  `resolve_rocm_root()` — major.minor mismatch (7.15 ≠ 7.13) fails the
  gate. Fix: patch `backend_versions.json` (source + build copy) to
  7.15.0. Systemd env vars `ROCM_PATH`, `HSA_OVERRIDE_GFX_VERSION`,
  `LD_LIBRARY_PATH` enable Lemonade to find and use the self-built
  TheRock.
- **llamacpp `--force-rebuild` ignored** (BUILD-FIXES #165): Step 33
  used a hardcoded binary existence check instead of
  `should_skip_step llamacpp`, bypassing the `--force-rebuild` CLI
  flag. Added `skip_check` to YAML + replaced inline check with
  `should_skip_step` call.
- **Hybrid/recurrent shrink/expand lifecycle safety** (BUILD-FIXES
  #166): External review identified 4 issues in the prompt-cache
  shrink/expand path: B2 (shrink races with active slots — CRITICAL),
  B3 (shrink return value ignored — HIGH), B4 (expand failure leaves
  pool at size=1 — CRITICAL), B1 (prompt_clear before expand — HIGH).
  Merged into `hybrid-attn-server.patch`: safe-shrink gate
  (`recurrent_shrink_safe_for_prompt_cache`), RAII guard
  (`recurrent_pool_guard`), return-value check, expand-before-clear
  ordering.
- **Hybrid/recurrent checkpoint data corruption + cell_zero crash +
  anchor-tracking gating** (BUILD-FIXES #167): External review #2
  found 3 issues: B1-R2 (`clear_checkpoint()` before expand destroys
  all slots' saved state — CRITICAL), B2-R2 (`cell_zero()` corrupts
  shared cells via dangling tail pointers — HIGH), L1-R2
  (anchor-tracking bypasses `do_checkpoint` gating — MEDIUM-HIGH).
  Fix verification by reviewer #2 found that the B1-R2 fix (removing
  `clear_checkpoint()`) introduced a NEW critical bug:
  `restore_checkpoint()` overwrote slot 0's freshly loaded recurrent
  state with stale backup. Fixed with selective checkpoint restore:
  new API `llama_context_recurrent_checkpoint_remove_seq()` removes
  the reloaded slot's entry from the checkpoint backup before
  `expand()`. B2-R2 and L1-R2 fixes verified correct. Touches 4
  patches: `hybrid-attn-llama-api.patch`, `hybrid-attn-llama-context.patch`,
  `hybrid-attn-memory-recurrent.patch`, `hybrid-attn-server.patch`.
- **Hybrid/recurrent checkpoint: non-zero slot data loss, tail rebuild,
  zero-prefix restore guard, double-restore guard, draft flags, cell_zero
  bookkeeping, shrink failure cleanup** (BUILD-FIXES #168): External
  review #3 + internal subagent trace found 9 issues. Subagent found
  `checkpoint_remove_seq(ret->id)` for `ret->id != 0` destroys recurrent
  state (HIGH — 75% of slot assignments). Review #3 found:
  `restore_checkpoint()` doesn't rebuild shared-cell tails (CRITICAL),
  zero-prefix restore from old conversation (HIGH), double-restore path
  conflict (HIGH), draft flags mismatch (HIGH, inert), cell_zero `used`
  not decremented (LOW), stale checkpoint on shrink failure (LOW-MED).
  Fix verification by reviewers #2 and #3: initial `ret->id == 0` guard
  was insufficient (attn/recr mismatch for non-zero slots) — revised to
  skip shrink entirely for `ret->id != 0`. Zero-prefix gate augmented
  with `prompt.checkpoints.clear()` at `n_past_prefix == 0`. 9 fixes
  across 3 patches (2 existing + 1 new):
  `hybrid-attn-server.patch` (394 lines), `hybrid-attn-memory-recurrent.patch`
  (707 lines), **NEW** `hybrid-attn-server-task.patch` (14 lines, YAML #51).

## [0.5.0] - 2026-07-03

Upstream sync: [`dbfb70ef`] from `paudley/ai-notes` (2026-06-06).
Adopted RUNPATH fix and runtime feature merge.

### Added

- **Runtime diagnostics** (`vllm-start.sh`): Startup-failure traceback
  extraction, AITER RMSNorm duplicate-pattern detection with auto-retry.
  From Dillflix via Paudley PR #14.
- **`--force-rebuild` CLI flag** (BUILD-FIXES #142): Targeted rebuilds
  without `--rebuild` (which wipes everything).
- **FP8 platform flag for gfx1x** (Patch #40): `supports_fp8()` returns
  True on RDNA 3.5.
- **`MAX_NUM_BATCHED_TOKENS` per-role config** (`vllm-start.sh`).
- **Build skip markers** (BUILD-FIXES #141): vLLM/AITER/FA
  `should_skip_step()` + AITER JIT cache-intact fast path.
- **16 new `.patch` files** (total now 20).

### Changed

- **vLLM v0.24.0 upgrade**: 12 components re-pinned (PyTorch
  release/2.11, vLLM v0.24.0, AITER v0.1.16.post3, CPython 3.13.9,
  Lemonade v10.9.0, +7 others). Lemonade config migration v1→v2.
- **Patch refactor**: 15 broken sed → 5 new git patches; 8 obsolete
  patches removed after upstream changes. `clean_generated: true`
  added. 36→24 patches.
- **4 obsolete TheRock patches removed**: `rocblas-roctx-gating` (#110),
  `rocr-blit-device-libs` (#112), `rccl-iostream-include` (#116),
  `miopen-ciso646-warnings` (#119) — all already included in pinned
  TheRock commit `a512f42c`. Build correctly detected them as
  "already applied". YAML TheRock patch section renumbered 1-18.
- **Build optimization**: 8 TheRock sub-projects disabled (~30-45 min),
  AITER JIT parallelized (ThreadPoolExecutor, ~5-8× speedup),
  `eval`→`envsubst`, clone dedup, multi-backend skip.
- **Runtime tuning**: `expandable_segments:True`, `enforce_eager`
  per-role, GPU clock lock + NUMA tuning in README.
- **Audit Phase 1-3** (commit `b858938`): 24 fixes — `{{ nproc }}`
  template, TRUST_REMOTE_CODE, health-check 127.0.0.1, kill process
  group, `/dev/kfd` check, `validate_pkg die` mode.

### Fixed

- **Profiler/ROCTX fully disabled** (BUILD-FIXES #105-#119): All ROCTX
  paths in RCCL, rocBLAS, rocSPARSE, hipBLASLt, hipSPARSELt, and MIOpen
  gated on `THEROCK_ENABLE_PROFILER`. ROCR blit kernels get explicit
  device-lib-path. Originally migrated to 6 `.patch` files; 4 later
  removed as obsolete (upstream included in `a512f42c`).
- **vLLM v0.24.0 API renames** (BUILD-FIXES #133, #140): 15 sed patches
  broken by upstream renames (`TORCH_CHECK`→`STD_TORCH_CHECK`,
  `at::ScalarType`→`torch::headeronly::ScalarType`,
  `KV_DTYPE`→`KV_CACHE_DTYPE`) and sed substring/marker bugs causing
  triple-imports and NameErrors. 5 new git patches + 2 regenerated.
  `pipeline_model_parallel_size`→`pipeline_parallel_size` in
  `skip-distributed-single-gpu.patch`.
- **Clang 23 compatibility** (BUILD-FIXES #134, #146, #149):
  `mwaitxintrin.h`→`x86intrin.h` — Clang 23 forbids direct inclusion
  of sub-architecture intrinsics headers. 23k "argument unused"
  warnings suppressed via `-Wno-unused-command-line-argument`.
  `LLVM_ENABLE_WERROR=OFF` for AOTriton tablegen headers.
- **EngineCore HIP corruption on fork** (BUILD-FIXES #137): AITER
  `.so` modules partially initialize HIP runtime via dlopen
  constructors at import time. `fork()` passes corrupted state to
  child, causing `hipErrorInvalidValue`. Fixed via
  `VLLM_WORKER_MULTIPROC_METHOD=spawn` in `vllm-env.sh`.
- **Runtime fixes** (BUILD-FIXES #150-#156): HIP allocator fragmentation
  via `expandable_segments:True`; EXTRA_ARGS validated with
  `read -r -a`; AITER RMSNorm detection fallback; Patch 26 marked
  obsolete; 8 TheRock sub-projects disabled; AITER JIT parallel
  compilation; obsolete patches removed after upstream changes;
  `HIP_VISIBLE_DEVICES` `set -u` crash fixed.
- **Build fixes across stack**: (See `BUILD-FIXES.md` #103-#156 for
  full root-cause analysis.)

## [0.4.0] - 2026-06-29

Upstream sync: [`b453c33`] from `paudley/ai-notes` (2026-04-22).

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
