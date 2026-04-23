<!-- Copyright 2026 Blackcat Informatics Inc. / 2026 bitserv-ai -->
<!-- SPDX-License-Identifier: MIT -->

# Build Fixes and Workarounds

Every patch applied by `build-vllm.sh`, documented with root cause analysis
and rationale. These are the real-world issues you'll hit building the vLLM
stack from source on a bleeding-edge AMD platform with modern compilers.

### Attribution

Merged three relevant patches from the 
[Dillflix gfx1151-stack](https://github.com/Dillflix/gfx1151-stack) fork.

## TheRock ROCm SDK (Phase A)

### 1. elfutils -Werror

**Symptom**: Build fails in elfutils with implicit `const void*` -> `struct*`
conversion errors.

**Root cause**: elfutils' `config/eu.am` unconditionally adds `-Werror` to
every compile command. Modern compilers (Clang 21+, GCC 15+) reject the
implicit pointer conversions from `bsearch()` return values that older
compilers accepted.

**Fix**: Inject `CFLAGS=-Wno-error` into the elfutils CMakeLists.txt
`./configure` environment, effectively neutralizing `-Werror`.

```bash
sed -i 's|"CPPFLAGS=${EXTRA_CPPFLAGS}"|"CPPFLAGS=${EXTRA_CPPFLAGS}"\n      "CFLAGS=-Wno-error"|' \
    third-party/sysdeps/linux/elfutils/CMakeLists.txt
```

### 2. rocprofiler-sdk vendored yaml-cpp missing `<cstdint>`

**Symptom**: `uint16_t`/`uint32_t` undeclared in `emitterutils.cpp`.

**Root cause**: Newer compilers (Clang 18+, GCC 13+) removed transitive
includes of `<cstdint>`. The vendored yaml-cpp relied on getting `uint16_t`
through other headers.

**Fix**: Add explicit `#include <cstdint>` to `emitterutils.cpp`.

### 3. rocprofiler-sdk vendored elfio missing `<cstdint>`

**Symptom**: `Elf64_Half` (typedef for `uint16_t`) undeclared in `elf_types.hpp`.

**Root cause**: Same as #2 -- transitive include removal in modern compilers.

**Fix**: Add `#include <cstdint>` after the header guard in `elf_types.hpp`.

### 4. Polly not enabled by default

**Symptom**: amdclang doesn't support `-mllvm -polly` after TheRock build.

**Root cause**: TheRock's `LLVM_ENABLE_PROJECTS` list doesn't include `polly`.

**Fix**: Patch `compiler/pre_hook_amd-llvm.cmake` to add `polly` to the
semicolon-separated project list:

```bash
sed -i 's|clang;lld;clang-tools-extra;flang|clang;lld;clang-tools-extra;flang;polly|' \
    compiler/pre_hook_amd-llvm.cmake
```

### 5. TheRock requires GCC

**Symptom**: Build fails with "GNU compiler required" errors from
rocprofiler-systems.

**Root cause**: rocprofiler-systems has an explicit GNU compiler check that
blocks Clang. TheRock's internal LLVM build also expects GCC as the host
compiler.

**Fix**: Configure TheRock with `-DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++`.
Use GCC only for TheRock; all downstream builds use amdclang from TheRock.

### 6. CachyOS system CFLAGS contamination

**Symptom**: TheRock build fails with unknown flag errors like `-fipa-pta`,
`-fvect-cost-model=very-cheap`, `-flto=20`.

**Root cause**: CachyOS (and some other Arch-based distros) set aggressive
GCC-specific CFLAGS/CXXFLAGS/LDFLAGS in the system environment. These flags
are invalid for clang and break any build that inherits them.

**Fix**: Unset `CFLAGS`, `CXXFLAGS`, `LDFLAGS` before TheRock configure and
build steps. Re-source `vllm-env.sh` afterward to restore our amdclang flags.

### 7. HSA_OVERRIDE_GFX_VERSION leak

**Symptom**: HIPCC fails with `--offload-arch=Invalid` during TheRock build.

**Root cause**: `vllm-env.sh` sets `HSA_OVERRIDE_GFX_VERSION=11.5.1` which
leaks into HIPCC's arch detection, producing invalid target strings.

**Fix**: Unset `HSA_OVERRIDE_GFX_VERSION` during TheRock build.

### 8. Tensile Python dependencies

**Symptom**: hipBLASLt build fails with `ModuleNotFoundError: No module
named 'joblib'` (or msgpack, numpy, pandas).

**Root cause**: hipBLASLt's Tensile kernel generator imports these packages
at code-generation time. They're not declared as cmake dependencies.

**Fix**: `uv pip install joblib msgpack numpy pandas pyyaml pytest` before
the TheRock build.

### 9. MLIR object libraries not installed

**Symptom**: Triton build fails looking for MLIR CAPI object libraries.

**Root cause**: TheRock's `cmake --install` copies `.a` and `.so` files but
skips the `objects-Release/` directory that MLIR's cmake exports reference.

**Fix**: Manually copy `objects-Release/` from the build tree to the install
tree after `cmake --install`.

### 10. FileCheck not installed

**Symptom**: Triton's cmake fails looking for `FileCheck` binary.

**Root cause**: TheRock builds FileCheck (an LLVM test utility) but doesn't
install it when `THEROCK_BUILD_TESTING=OFF`.

**Fix**: Copy `FileCheck` from the build tree to the LLVM bin directory.

## AOCL-LibM (Phase B, Step 6)

### 11. -muse-unaligned-vector-move (AOCC-only flag)

**Symptom**: Build fails with "unknown argument: '-muse-unaligned-vector-move'"

**Root cause**: AOCL-LibM's SConscript assumes any clang >= 14.0.6 is AOCC
(AMD's proprietary compiler). TheRock's open-source amdclang doesn't support
this AOCC-specific flag.

**Fix**: Patch the SConscript to remove the flag injection.

### 12. CMPLX/CMPLXF macro redefinition with -Werror

**Symptom**: Fatal error from `-Werror` + `-Wmacro-redefined` on CMPLX macros.

**Root cause**: AOCL-LibM headers redefine macros that glibc's `complex.h`
already provides (identically).

**Fix**: Add `-Wno-macro-redefined` after `-Werror` in the SConscript.

### 13. Linker flags incompatible with clang

**Symptom**: Link fails with `-ealm_main` not recognized.

**Root cause**: GCC passes `-e` directly to the linker; clang requires
`-Wl,-e,alm_main` syntax. Additionally, AOCL-LibM's hand-written AVX
assembly uses absolute relocations that lld rejects in shared libraries.

**Fix**: Change `-ealm_main` to `-Wl,-e,alm_main` and add `-fuse-ld=bfd`
to use GNU ld for the final link (GNU ld handles the absolute relocations
via dynamic text relocations).

## AOCL-Utils (Phase B, Step 5)

### 14. No LTO for AOCL-Utils

**Why**: AOCL-LibM links against AOCL-Utils `.a` files using GNU ld (see #13).
GNU ld cannot read LLVM bitcode objects produced by `-flto=thin`. Build
AOCL-Utils without LTO.

### 15. clang-tidy crashes

**Symptom**: AOCL-Utils build hangs or crashes during clang-tidy analysis.

**Root cause**: AOCL-Utils auto-enables clang-tidy if found on PATH. Both
TheRock's clang-tidy (crashes on cleanup) and system clang-tidy (doesn't
understand `-famd-opt`) cause failures.

**Fix**: Set `CMAKE_CXX_CLANG_TIDY="/bin/true"` to satisfy the cmake check
while doing nothing.

## CPython (Phase B, Step 7)

### 16. AOCL-LibM breaks PGO test_math

**Symptom**: CPython's PGO profiling run fails on `test_math`.

**Root cause**: AOCL-LibM's transcendentals have slightly different ULP
rounding than glibc's libm:
- `cbrt(-0.0)` returns `+0.0` (should return `-0.0`)
- `fmod(-10, 1)` returns incorrect results
- `nextafter()` and `ulp()` are broken

**Fix**: Do NOT link CPython against `-lalm`. Unset all vllm-env.sh env vars
(which include `-lalm` in LDFLAGS) before CPython's `./configure`. AOCL-LibM
is available at runtime via `LD_LIBRARY_PATH` for downstream libraries
(NumPy, PyTorch) that benefit from it but don't run CPython's exact math tests.

## PyTorch (Phase C, Step 10)

### 17. HIPGraph.hip cudaGraphConditionalHandle

**Symptom**: Compilation error on undefined `cudaGraphConditionalHandle` type.

**Root cause**: PyTorch's hipify step creates `HIPGraph.hip` containing a
`set_conditional_handle()` function that references `cudaGraphConditionalHandle`
-- a CUDA 12.4+ type with no HIP equivalent. Dead code that fails to compile.

**Fix**: Replace `HIPGraph.hip` with a minimal stub containing only the
namespace declaration and a comment explaining the removal.

### 18. -fclang-abi-compat=17 ABI mismatch

**Symptom**: Undefined symbol errors at link time (e.g., `const_data_ptr<Half>`
mangled differently between `libtorch_cpu.so` and `libtorch_hip.so`).

**Root cause**: PyTorch's `cmake/Dependencies.cmake` adds
`-fclang-abi-compat=17` to HIPCC flags "for compat with newer hip-clang C++20
mangling rules". This forces HIP device code to use Clang 17 ABI while host
code uses amdclang 22 ABI, causing name mangling mismatches.

**Fix**: Remove the `-fclang-abi-compat=17` line from `Dependencies.cmake`.

### 19. Missing librocm_smi64.so linkage (upstream bug)

**Symptom**: `undefined symbol: rsmi_init` at runtime when loading PyTorch.

**Root cause**: PyTorch's hipify maps `nvml.h` -> `rocm_smi/rocm_smi.h` in
headers, so `rsmi_*` functions are compiled into `libtorch_hip.so`. But the
build system never adds `-lrocm_smi64` to the link line.

**Fix**: Post-build `patchelf --add-needed librocm_smi64.so libtorch_hip.so`.
This is a real upstream PyTorch bug worth reporting.

### 20. Google Benchmark -Werror with C2y extensions

**Symptom**: Build fails on `__COUNTER__` flagged as C2y extension.

**Root cause**: amdclang 22 flags `__COUNTER__` as a C2y extension in C++
mode. Google Benchmark uses `-Werror`, making this fatal.

**Fix**: `BUILD_TEST=0 USE_BENCHMARK=0` (not needed for inference).

## Triton (Phase D, Step 15)

### 21. -Werror + _POSIX_C_SOURCE redefinition

**Symptom**: Build fails with `-Wmacro-redefined` on `_POSIX_C_SOURCE`.

**Root cause**: Triton's CMakeLists.txt hardcodes `-Werror`. Our custom-built
Python 3.13's `pyconfig.h` redefines `_POSIX_C_SOURCE`, triggering
`-Wmacro-redefined` which becomes fatal with `-Werror`.

**Fix**: Remove `-Werror` from Triton's CMakeLists.txt.

### 22. ROCm/triton setup.py location

**Symptom**: `pip wheel .` fails with "no setup.py found".

**Root cause**: ROCm's Triton fork keeps `setup.py` in `python/` subdirectory
(upstream moved it to repo root).

**Fix**: Detect and use `python/` subdirectory if `setup.py` is there.

## AOTriton (Phase D, Step 18)

### 23. Stray git rebase "pick" line

**Symptom**: cmake parse error on `pick <hash>` line in CMakeLists.txt.

**Root cause**: Upstream ROCm/aotriton main has a stray git rebase "pick"
line at the end of CMakeLists.txt (accidentally committed).

**Fix**: `sed -i '/^pick /d' CMakeLists.txt`

## PyTorch Wheel Fixes (Phase C, Step 10)

### 24. numpy>=2 ABI compatibility

**Symptom**: Runtime `ImportError` or ABI mismatch when numpy 2.x is installed
alongside a PyTorch wheel built against numpy 1.x headers.

**Root cause**: numpy 2.0 changed C header locations from `numpy/core/include`
to `numpy/_core/include` and introduced ABI changes. Building PyTorch against
`numpy<2` then installing `numpy>=2` at runtime causes header mismatches and
potential segfaults in C extensions.

**Fix**: Build PyTorch (and all downstream) against `numpy>=2.0,<3`. This
ensures the wheel's compiled extensions are ABI-compatible with numpy 2.x
at runtime. The old `numpy<2` downgrade guard in `install_rocm_requirements`
is no longer needed and was removed.

### 25. PyTorch .so patches not baked into wheel

**Symptom**: PyTorch wheel installed on a different machine lacks RPATH fixes
and `librocm_smi64.so` NEEDED entry, causing runtime `undefined symbol: rsmi_init`.

**Root cause**: The original build flow ran `pip wheel .` (which compiles AND
packages in one step), then patched .so files with `patchelf`. But the wheel
was already written to disk -- the patches only affected the local build tree,
not the distributable wheel.

**Fix**: Build the wheel normally with `pip wheel .`, then unpack the `.whl`,
apply patchelf fixes to the `.so` files inside, and repack with Python's
`zipfile` module. This is the only reliable approach because `pip wheel .`
re-invokes cmake which copies fresh `.so` files, overwriting any pre-build
patches.

```bash
# 1. Build wheel normally
pip wheel . --no-build-isolation --no-deps --wheel-dir $WHEELS_DIR -v
# 2. Unpack → patch → repack
unzip -q "$WHEEL" -d "$TMPDIR"
patchelf --set-rpath '$ORIGIN:/opt/src/vllm/local/lib' torch/lib/libtorch_python.so
patchelf --add-needed librocm_smi64.so torch/lib/libtorch_hip.so
# repack with zipfile
```

### 25b. Build tree RPATH leak in libtorch_python.so

**Symptom**: `import torch` fails with `undefined symbol: rsmi_init` pointing
at `/opt/src/vllm/pytorch/build/lib/libtorch_hip.so` even though the installed
wheel copy has the fix.

**Root cause**: cmake bakes the build tree path
(`/opt/src/vllm/pytorch/build/lib`) into `libtorch_python.so`'s RUNPATH. When
the dynamic linker loads `libtorch_hip.so`, it finds the unpatched build-tree
copy before the installed (patched) copy.

**Fix**: During the unpack/patch/repack step, clean all `.so` RPATHs to remove
build tree references:

```bash
patchelf --set-rpath '/opt/src/vllm/local/lib:$ORIGIN' torch/lib/libtorch_python.so
```

### 25c. NumPy 2.0 ABI target version

**Symptom**: `import torch` crashes with "A module that was compiled using
NumPy 1.x cannot be run in NumPy 2.4.3".

**Root cause**: PyTorch's `numpy_stub.h` does NOT set `NPY_TARGET_VERSION`.
Without this, numpy 2.x headers compile against the oldest compatible API
(1.20 / `0x0e`) by default, producing a `.so` that fails the runtime ABI
check when loaded with numpy >= 2.0.

**Fix**: Patch `torch/csrc/utils/numpy_stub.h` to set `NPY_TARGET_VERSION`
before including `<numpy/arrayobject.h>`:

```c
#ifndef NPY_TARGET_VERSION
#define NPY_TARGET_VERSION 0x00000012  /* NPY_2_0_API_VERSION */
#endif
```

The hex value must be used directly because `NPY_2_0_API_VERSION` is defined
inside `numpyconfig.h` which is included by `arrayobject.h`.

## TorchVision (Phase C, Steps 12-13)

### 26. TorchVision source build

**Non-issue**: TorchVision is now built from source (steps 12-13) against
the source-built PyTorch to ensure ABI compatibility. Uses amdclang from
TheRock. CPU-only (no CUDA/ROCm GPU ops -- TorchVision's GPU kernels are
not needed for inference).

## Flash Attention (Phase F, Steps 26-28)

### 27. amdsmi import order (flash_attn)

**Symptom**: Same as vLLM (#35 Patch 1) — amdsmi C extension crash when
loaded after torch.

**Root cause**: Identical to the vLLM fix. flash_attn's `__init__.py`
imports torch before amdsmi, causing the same C extension initialization
conflict.

**Fix**: Prepend `import amdsmi` before any torch imports in
`flash_attn/__init__.py`.

## Wheel Builds (Phase H)

### 28. cmake pip wrapper in build isolation

**Symptom**: sentencepiece source build fails with `ImportError: No module
named 'cmake'`.

**Root cause**: The `cmake` pip package installs a Python wrapper at
`.venv/bin/cmake` that does `from cmake import cmake`. Inside pip's build
isolation, the cmake Python module isn't available, so the wrapper fails.

**Fix**: Replace the Python wrapper with a symlink to the real system cmake
binary (`/usr/bin/cmake`).

### 29. meson -Werror vs -mllvm flags (numpy build)

**Symptom**: numpy build fails on meson capability probes.

**Root cause**: meson hard-codes `-Werror=unused-command-line-argument` in
`ClangCompiler.get_compiler_check_args()` AFTER our CFLAGS. Driver-level
`-mllvm` flags are reported as "unused" in compile-only checks (`-c`),
killing every meson capability probe.

**Fix**: Transform `-mllvm <arg>` to `-Xclang -mllvm -Xclang <arg>` in
CFLAGS for wheel builds. `-Xclang` passes flags directly to the compiler
frontend/backend, bypassing the driver's argument tracking. Move `-famd-opt`
to LDFLAGS (link-time only, no-op at compile time).

### 30. Rust + amdclang linker

**Symptom**: Cargo fails to link with "cc: error: unrecognized argument".

**Root cause**: AMD's `cc` symlink (created in step 4) rejects binaries
not prefixed by "amd". Cargo uses `cc` by default.

**Fix**: Set `CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=amdclang`.
Also unset CFLAGS/CXXFLAGS/LDFLAGS because they contain clang-specific
flags that Rust's internal `cc` invocations don't understand.

### 31. Rust -C target-cpu=native bug

**Symptom**: Rust binary only uses SSE2 despite running on Zen 5.

**Root cause**: Rust's native CPU detection identifies znver5 but only
enables SSE2 features (a known `rustc` bug).

**Fix**: Use explicit `-C target-cpu=znver5` instead of `-C target-cpu=native`.
This enables all 40+ target features including AVX-512, VAES, VPCLMULQDQ,
GFNI, SHA.

### 32. pyzstd is now pure Python

**Non-issue**: pyzstd v0.19.1 restructured -- the C extension moved to a
separate `backports-zstd` package. The main `pyzstd` package is now pure
Python (`py3-none-any`). Since `zstandard` covers the same use case, pyzstd
was removed from the build list.

### 33. pyarrow requires full Arrow C++ build

**Non-issue**: pyarrow's source build requires the entire Apache Arrow C++
library pre-installed (30+ minute build with its own dependency tree). The
PyPI binary uses runtime SIMD dispatch and detects AVX-512 at startup, so
there's no meaningful gain from a source build.

## vLLM Runtime Patches (Phase E, Step 20b)

These patches fix runtime issues specific to gfx1151 (RDNA 3.5, wave32).
They are applied after cloning vLLM and before building. "Patch N" numbers
in parentheses refer to the YAML `packages.vllm.patches[]` index.

### 34. amdsmi import order (Patch 1)

**Symptom**: `segfault` or `ImportError` on `import torch` when amdsmi is
installed.

**Root cause**: amdsmi's C extension conflicts with torch's ROCm
initialization if loaded after torch. Both bind to the same ROCm SMI
shared library but expect different initialization states.

**Fix**: Prepend `import amdsmi` before any torch imports in vLLM's
`__init__.py`. Identical to the flash_attn fix (#27).

### 35. AITER gate extension to gfx1x (Patches 2-5)

**Symptom**: AITER optimizations (attention, GEMM, normalization) are
silently disabled on gfx1151 — only eager PyTorch paths are used.

**Root cause**: vLLM upstream gates AITER behind `on_gfx9()` checks
(MI300X architecture family). gfx1151 is RDNA 3.5, not gfx9.

**Fix**: Extend `is_aiter_found_and_supported()` in `_aiter_ops.py` and
`supports_compute_capability()` in `rocm_aiter_fa.py` to accept
`on_gfx1x()` alongside `on_gfx9()`. AITER has explicit gfx1151 tuning
(chip_info.py enum 13, BLOCK_M/N=32, waves_per_eu=2).

### 36. ViT attention revert to gfx9-only (Patch 6)

**Symptom**: Vision Transformer (ViT) encoder attention crashes with
"invalid argument for fmha_fwd" on gfx1151.

**Root cause**: The CK fmha_fwd kernel rejects ViT-specific attention
dimensions (head_dim/seq_len combinations) on gfx1151. The decoder
attention path (unified + FA) works correctly on gfx1x, but the ViT
encoder path cannot use CK attention.

**Fix**: Keep ViT attention gated to `on_gfx9()` only. On gfx1151, ViT
falls through to `TRITON_ATTN` which works correctly. If a previous build
had extended the gate, this patch reverts it.

### 37. FP8 linear disable on gfx1x (Patch 7)

**Symptom**: GPU page fault crash during FP8 quantized inference.

**Root cause**: CK GEMM kernels (`module_gemm_a8w8_blockscale`) compile
for gfx1151 but use CDNA-specific MFMA (Matrix Fused Multiply-Add)
instructions that don't exist on RDNA 3.5. The kernel executes illegal
instructions, causing page faults.

**Fix**: Add gfx1x guard to `is_linear_fp8_enabled()` in `_aiter_ops.py`.
Returns `False` on RDNA 3.x, forcing vLLM to use its Triton blockscale
GEMM fallback which generates correct gfx1151 kernels.

### 38. AttrsDescriptor `__repr__` for Inductor codegen (Triton Patch 2, vLLM inline)

**Symptom**: `SyntaxError` when loading torch.compile-generated Triton
kernel files. torch.compile works on first run but fails on cache reload.

**Root cause**: torch Inductor's codegen uses `{triton_meta!r}` to
serialize kernel metadata into generated Python source. The ROCm Triton
fork's `AttrsDescriptor` class has no `__repr__`, so Python falls back to
`object.__repr__()` producing `<triton.backends.compiler.AttrsDescriptor
object at 0x...>` — invalid Python syntax that causes `SyntaxError` when
the generated file is re-imported.

**Fix**: Add `__repr__` to `AttrsDescriptor` in
`triton/backends/compiler.py` that produces valid, round-trippable Python
via `from_dict()`. Applied in two places: (1) Triton source tree during
`build_triton()` (YAML triton patch 2), and (2) the installed triton
package during `patch_vllm_gfx1151()` to catch pre-built wheels. With this
patch, `torch.compile` works correctly on gfx1151 — `--enforce-eager` is
NOT required.

### 39. Duplicate pattern registration crash (Patch 9)

**Symptom**: `RuntimeError: Duplicate pattern` during torch.compile
initialization with AITER fusion passes enabled.

**Root cause**: `RocmAiterRMSNormQuantFusionPass` in
`rocm_aiter_fusion.py` registers patterns in a loop over
`epsilon x match_aiter_quant` combinations. Some combinations produce
identical pattern graphs, and `torch._inductor.pattern_matcher` raises
on duplicates.

**Fix**: Add `skip_duplicates=True` to all `pm.register_replacement()`
calls in the fusion pass.

### 40. `+rms_norm` custom_ops block on gfx1x (Patch 8)

**Symptom**: Model produces garbage/incoherent output with AITER enabled
and torch.compile active. Correct output in eager mode.

**Root cause**: When AITER RMSNorm is detected, vLLM's `rocm.py` adds
`+rms_norm` to the `custom_ops` list. This tells torch.compile/Inductor
to treat RMSNorm as an **opaque barrier** in the compute graph rather
than an inline operation. On gfx1x (RDNA 3/4, wave32), Inductor generates
incorrect code at the graph partition boundaries created by this barrier.

Both the CK and Triton RMSNorm kernels are correct in isolation — the bug
is purely in how Inductor restructures the compute graph when RMSNorm is
declared as an opaque custom op. The effect is subtle: the model runs
without errors but produces nonsensical output.

**Fix**: Add `and not on_gfx1x()` guard to the `+rms_norm` insertion in
`rocm.py`. RMSNorm stays inline in the Inductor graph and gets fused
normally by the compiler. This was the single most impactful fix:

| Model | Before (PIECEWISE, no AITER) | After (FULL graph, ALL AITER) | Speedup |
|-------|------------------------------|-------------------------------|---------|
| Qwen2.5-0.5B | 137.4 tok/s | 1059.8 tok/s | 7.7x |
| Qwen2.5-1.5B | 44.2 tok/s | 391.6 tok/s | 8.9x |

The speedup comes from enabling FULL CUDA graph capture (entire forward
pass as a single HIPGraph) combined with ALL AITER optimizations
(attention, GEMM, normalization). Previously, the `+rms_norm` bug forced
PIECEWISE graph mode with AITER disabled.

### 41. Triton sampler page fault on gfx1151 (Patch 10)

**Symptom**: GPU page fault during top-k/top-p sampling after torch.compile
AOT compilation on RDNA 3.5.

**Root cause**: The Triton top-k/top-p sampler kernel
(`apply_top_k_top_p_triton`) page-faults on gfx1151 after ahead-of-time
compilation by torch.compile. The kernel works in eager mode but the
compiled version triggers an illegal memory access on RDNA 3.5's wave32
architecture.

**Fix**: Bypass the Triton sampler in
`vllm/v1/sample/ops/topk_topp_sampler.py`. The PyTorch sort-based path
(`topk` + `cumsum`) is functionally identical and works on all
architectures.

### 42. FLA chunk_delta_h autotuner + exp() type inference (Patches 11-15)

**Symptom**: Two issues in FLA (Flash Linear Attention) Triton kernels:
1. Page faults during autotuning with `num_stages>2` or `BV=64`
2. Invalid IR from `exp()` type inference on HIP

**Root cause**: The chunk_delta_h Triton kernel's autotuner tries pipeline
depths (stages=2,3,4) and block sizes (BV=32,64) that exceed RDNA 3.5's
register pressure limits, causing page faults. Separately, the HIP Triton
compiler fails to infer types for `exp(scalar_bf16 - block_ptr_load_bf16)`,
generating invalid intermediate representation.

**Fix**:
- Restrict AMD autotuning to `num_stages=2` and `BV=32` only (via
  `is_amd` flag)
- Cast `exp()` operands to `tl.float32` explicitly, which also improves
  precision

### 43. Qwen3.5 FLA warmup page fault for T < BT (Patch 16)

**Symptom**: Page fault during Qwen3.5-next model warmup when FLA kernels
are called with sequence lengths T=16 or T=32.

**Root cause**: On RDNA 3.5 (wave32), `tl.make_block_ptr` page-faults when
the sequence length T is less than the chunk size BT (64). HIP materializes
the out-of-bounds address computation that CDNA (wave64) handles
differently. The warmup loop iterates `T in (16, 32, 64)` but only T=64
(where T==BT) is safe.

**Fix**: Restrict the warmup loop in `qwen3_next.py` to `for T in (64,)`
only.

### 44. flash_attn_2_cuda import on ROCm (Patch 17)

**Symptom**: `ModuleNotFoundError: flash_attn_2_cuda` when loading rotary
embedding with flash_attn installed.

**Root cause**: On ROCm, flash_attn is a pure-Python wheel that provides
Triton-based kernels via `flash_attn.ops.triton.*` but does NOT include the
CUDA native extension `flash_attn_2_cuda`. The import chain
`flash_attn.ops.triton.rotary` -> `flash_attn_2_cuda` fails because the
`.so` doesn't exist.

**Fix**: Wrap the import in `rotary_embedding/common.py` with a try/except
for `ImportError`/`ModuleNotFoundError`. When the native extension is
absent, the Triton-based rotary path is still available through other code
paths.

### 45. AITER RMSNorm CK dispatch on gfx1x (Patches 18-19)

**Symptom**: Illegal instruction crash during quantized inference when AITER
RMSNorm is active on gfx1151.

**Root cause**: The CK (Composable Kernel) RMSNorm implementations
(`rocm_aiter.rmsnorm2d_fwd_with_dynamicquant` and
`rmsnorm2d_fwd_with_add_dynamicquant`) use CDNA-specific assembly (MFMA
instructions) that doesn't exist on RDNA 3.5. Additionally, the CK versions
accept a `use_model_sensitive_rmsnorm=0` kwarg that the Triton versions
don't.

**Fix**: Add architecture dispatch in `_aiter_ops.py`. On `on_gfx1x()`, use
the Triton RMSNorm from `aiter.ops.triton.normalization.rmsnorm` (which
generates correct wave32 kernels). On gfx9 (CDNA), use the original CK path
with the `use_model_sensitive_rmsnorm=0` kwarg.

## AITER Source Rebuild (Phase F, Step 28b)

**AITER version**: `9a469a608b2c10b7157df573a38d31e5bf4038b4` (PyTorch submodule,
`pytorch/third_party/aiter` at time of build).

### 46. AITER CK ABI mismatch

**Symptom**: JIT compilation of AITER MHA kernels fails with ABI
mismatches -- struct field types, missing members, narrowing conversion
errors.

**Root cause**: AITER's MHA (Multi-Head Attention) kernels use CK
(Composable Kernel) tile headers for JIT compilation at runtime. The
pip-installed aiter wheel includes pre-compiled `.cu` interface files built
against a specific CK commit. If `CK_DIR` points to a different CK version,
the compiled interfaces and runtime JIT headers disagree on struct layouts,
causing compilation failures.

**Fix**: Step 28b rebuilds AITER from the PyTorch submodule source tree
(`pytorch/third_party/aiter`) with `CK_DIR` pointing to the matching CK
submodule. This ensures the compiled `.cu` interfaces and CK headers are
from the same commit. The stale JIT cache is cleared before rebuild.

### 47. AITER vec_convert.h CDNA-only packed ISA (gfx1151 header patch)

**Symptom**: JIT compilation fails with "invalid instruction" for AITER
kernels that use packed FP8 conversion on gfx1151.

**Root cause**: `ck_tile/vec_convert.h` contains three CDNA-only packed
instructions:
- `v_pk_mul_f32` (packed FP32 multiply, gfx940+ only)
- `v_cvt_pk_fp8_f32` (packed FP8 convert, gfx942+ only)
- `v_cvt_pk_bf8_f32` (packed BF8 convert, gfx942+ only)

These are inline assembly instructions that RDNA 3/3.5 hardware cannot
execute.

**Fix**: Replace with architecture-dispatched code using
`CK_TILE_RDNA3_NO_PK_FP8` preprocessor guard. On RDNA 3/3.5
(`__gfx11xx__`), scalar C++ equivalents are used instead of packed assembly.

### 48. AITER hip_reduce.h DPP broadcast instructions (gfx1151 header patch)

**Symptom**: Illegal instruction during warp reduction operations in AITER
kernels on gfx1151.

**Root cause**: `hip_reduce.h` uses two DPP (Data Parallel Primitives)
broadcast instructions:
- `row_bcast:15` (0x142) -- cross-row broadcast, CDNA only
- `row_bcast:31` (0x143) -- cross-half broadcast, CDNA only

These DPP modes don't exist on RDNA, which uses a different warp shuffle
mechanism.

**Fix**: Replace with `ds_swizzle` (`warp_swizzle<T, 0x1e0>`) matching
rocprim's own `warp_reduce_dpp.hpp` RDNA path. The `WarpSize > 32` path
uses a `static_assert` since RDNA is wave32-only (CDNA is wave64). Patches
target installed site-packages headers (not source tree) because AITER's
JIT reads from the venv.

### 49. FLA chunk_o autotuner page fault on AMD HIP (Patches 20-23)

**Symptom**: GPU page fault during Triton autotuning of the
`chunk_fwd_kernel_o` kernel in the FLA (Flash Linear Attention) ops for
Qwen3.5 GDN (Gated Delta Network) layers.

**Root cause**: Same class of issue as chunk_delta_h (#37). The autotune
search space includes BK/BV=64/128 and pipeline depths num_stages=3,4 that
exceed RDNA 3.5's register pressure limits. The kernel page-faults during
autotuning with the larger tile configurations.

**Fix**: Four sed patches to `chunk_o.py`:
1. Add `is_amd` to the utils import
2. Restrict BK to `[32]` on AMD (vs `BKV_LIST = [64, 128]`)
3. Restrict BV to `[32]` on AMD
4. Restrict num_stages to `[2]` on AMD (vs `[2, 3, 4]`)

### 50. KV cache page size mismatch: ROCm block_size vs hybrid alignment (Patches 24-25)

**Symptom**: Qwen3.5 GDN (hybrid mamba+attention model) fails with
assertion errors or incorrect generation due to block_size mismatch between
AITER's requirement and the hybrid model's mamba state alignment.

**Root cause**: The vLLM configuration pipeline has a sequencing issue:
1. `HybridAttentionMambaModelConfig.verify_and_update_config()` computes
   `attn_block_size` as lcm(mamba_state, kernel_alignment=32), producing
   e.g. 576 for Qwen3.5
2. `current_platform.check_and_update_config()` runs AFTER and sets
   `block_size=64` (ROCm AITER's requirement), clobbering step 1
3. The mamba layers now get a block_size (64) that doesn't satisfy their
   state alignment requirement

**Fix**: Two patches:
- **Patch 24** (`config/vllm.py`): Re-run
  `HybridAttentionMambaModelConfig.verify_and_update_config()` after the
  platform config, so the hybrid alignment is recomputed with the
  platform's block_size as a constraint
- **Patch 25** (`models/config.py`): Use
  `max(kernel_block_alignment_size, cache_config.block_size)` as the kernel
  alignment. If the platform already set block_size=64, the computed
  attn_block_size will be a multiple of both 64 (AITER) and the mamba state
  size

### 51. AITER unified attention Triton kernel crash on non-power-of-2 block_size (vLLM Patches 26-27, aiter/3) [TESTING]

**Status**: TESTING — routing hybrid models away from AITER attention
entirely (Patch 26) may be too aggressive. An alternative approach would be
to fix the AITER kernel to decouple TILE_SIZE from block_size, similar to
how `TritonAttentionBackend` handles it. Patches 27 and aiter/3 are
defense-in-depth and may be sufficient on their own.

**Symptom**: `OutOfResources: shared memory, Required: 1081344, Hardware
limit: 65536` crash when AITER unified attention is used with hybrid models
that produce non-power-of-2 block_size (e.g. 576).

**Root cause**: AITER's unified attention Triton kernel uses
`TILE_SIZE = block_size` directly in `tl.arange()`, which requires N to be
a power of 2. After fix #50, block_size=576 (not power of 2).
`next_power_of_2(576) = 1024`, and the resulting shared memory allocation
(1024 * head_size * elem_size per K/V tile) exceeds the 64 KiB LDS on all
AMD GPUs.

**Fix**: Three-layer defense-in-depth:
- **Patch 26** (`rocm.py`) [TESTING]: Detect hybrid models via
  `model_config.is_hybrid` and skip AITER unified attention and AITER FA
  backends entirely. Hybrid models fall through to `TRITON_ATTN`, which
  decouples tile size from block size
- **Patch 27** (`rocm_aiter_unified_attn.py`) [TESTING]: Add power-of-2
  constraint to `supports_block_size()`. The original check only validated
  `block_size % 16 == 0`; now also requires
  `(block_size & (block_size - 1)) == 0`
- **aiter/3** (AITER `unified_attention.py`) [TESTING]: Cap
  `TILE_SIZE = min(block_size, 128)` in both `select_2d_config` and
  `select_3d_config`. For standard block sizes (64/128) this is a no-op.
  For abnormal block sizes that somehow reach the kernel, the cap prevents
  the LDS overflow

### 52. Flash Attention internal AITER install failure (Step 28)

**Symptom**: Flash Attention build fails with `error: [Errno 2] No such file
or directory: 'aiter_meta/hsa/gfx942/fmoe_2stages/...'`.

**Root cause**: Flash Attention's `setup.py` (ROCm `main_perf` branch) runs
`subprocess.run([sys.executable, "-m", "pip", "install", "--no-build-isolation",
"third_party/aiter"])` during the build. This AITER submodule bundles
pre-compiled `.co` (code object) files for gfx942 only. On gfx1151 the gfx942
code objects are missing from the source tree, causing `FileNotFoundError`
during `setup.py`'s `package_data` collection.

**Fix**: Patch `setup.py` to replace the `subprocess.run(pip install aiter)`
call with `pass`. We build AITER separately from the PyTorch submodule source
(step 28b) with proper gfx1151 patches, so the flash_attn internal install
is unnecessary and harmful.

### 53. AITER JIT pre-warm SystemExit propagation (Step 29b)

**Symptom**: Build script exits non-zero during AITER JIT pre-warm when any
module fails to compile, killing subsequent build steps.

**Root cause**: AITER's `build_module()` function (`aiter/jit/core.py:694`)
raises `SystemExit` on compilation failure. `SystemExit` inherits from
`BaseException`, not `Exception`, so the warmup script's `except Exception`
clause doesn't catch it. The `SystemExit` propagates out of the Python
interpreter, making it exit non-zero.

**Fix**: Change the warmup script's exception handler from `except Exception`
to `except (Exception, SystemExit)`. Expected failures (CDNA-only modules like
`module_activation`, `module_quick_all_reduce`, `module_moe_asm`) are caught,
counted, and logged without terminating the build.

### 54. Optimized wheels not installed into venv (Steps 30-31)

**Symptom**: After build completes, the venv has pip-resolved versions of
numpy (2.1.3), and lacks orjson and asyncpg entirely, despite Zen 5-optimized
wheels being present in `wheels/`.

**Root cause**: Steps 30-31 build optimized wheels into `wheels/` but never
install them back into the build venv. The wheels were only intended for
distribution to other environments.

**Fix**: Add `uv pip install --force-reinstall --no-deps <wheel>` after each
wheel is built (or confirmed to exist). This replaces the venv's
pip-installed versions with the source-built, Zen 5-optimized versions.

### 55. Triton stdout pollution breaks AITER JIT directory capture (Step 29b)

**Error**: After AITER JIT pre-warm completes, the build script dies with exit
code 1 instead of continuing to steps 30-35.

**Root cause**: `get_user_jit_dir()` imports triton, which prints a warning to
**stdout** (not stderr): `Warning: triton.experimental.gluon or
triton.experimental.gluon.language not exists...`. The bash `$(...)` captures
this warning along with the actual JIT directory path, creating a multi-line
`jit_dir` variable. When `find "${jit_dir}" -maxdepth 1 ...` runs, the garbage
path causes `find` to fail, and `set -euo pipefail` kills the script.

**Fix**: Pipe the `get_user_jit_dir()` output through `tail -1` to grab only
the last line (the actual path), discarding any stdout pollution from upstream
imports. Applied to all three `jit_dir` capture sites (lines 2372, 3037, 3204).

## TheRock Phase A — Additional Patches

### 56. TheRock roctx64 path in explicit finders (therock/7)

**Symptom**: Unresolved symbol errors for roctx64 at runtime despite
successful build.

**Root cause**: `cmake/therock_explicit_finders.cmake` uses
`find_library(roctx64 ...)` which resolves to a system or staging copy at
configure time. At runtime the embedded path may not be on
`LD_LIBRARY_PATH`, causing `libroctx64.so` to not be found.

**Fix**: Replace bare `roctx64` with the absolute path
`${LOCAL_PREFIX}/profiler/roctracer/stage/lib/libroctx64.so`.

### 57. RCCL roctx64 path (therock/8)

**Symptom**: RCCL initialization fails at runtime with unresolved roctx64
symbols.

**Root cause**: RCCL links roctx64 via its own pre-hook
(`comm-libs/pre_hook_rccl.cmake`), separate from TheRock's explicit
finders. Same `find_library` resolution problem as #56.

**Fix**: Same hard-wired absolute path as #56, applied to
`pre_hook_rccl.cmake`.

### 58. libhipcxx atomic_codegen tests disabled (therock/9)

**Symptom**: Build fails with `Could not find cuobjdump` or device-side
atomics errors during libhipcxx test compilation.

**Root cause**: The `atomic_codegen` tests require CUDA tools and
device-side atomics not available for gfx1151 at TheRock build time.
Not required for the runtime library.

**Fix**: Replace `atomics_tests` target with a comment in the CMakeLists
to skip test compilation.

### 59. rocprofiler-sdk nested yaml-cpp missing `<cstdint>` (therock/10)

**Symptom**: `uint32_t` undeclared in `emitterutils.cpp` inside the
rocprofiler-sdk nested under `rocm-systems/`.

**Root cause**: Same transitive include removal as #2, but in a second
copy of yaml-cpp vendored inside
`rocm-systems/projects/rocprofiler-sdk/external/`. The top-level copy
(fixed by #2) and this nested copy are built independently.

**Fix**: Add `#include <cstdint>` after `#include <sstream>` in the
nested copy. Identical to #2, different file path.

### 60. rocprofiler-sdk nested elfio missing `<cstdint>` (therock/11)

**Symptom**: `Elf64_Half` (typedef for `uint16_t`) undeclared in
`elf_types.hpp` inside the rocprofiler-sdk nested under `rocm-systems/`.

**Root cause**: Same transitive include removal as #3, but in a second
copy of elfio. See #59.

**Fix**: Add `#include <cstdint>` before `#define ELFTYPES_H` in the
nested copy. Identical to #3, different file path.

## AOCL-LibM Phase B — Additional Patches

### 61. AOCL-LibM RPATH for libau_cpuid.so (aocl_libm/4)

**Symptom**: `libalm.so` fails to load with `cannot open shared object
file: libau_cpuid.so`.

**Root cause**: `libalm.so` dynamically depends on `libau_cpuid.so` from
AOCL-Utils but has no RPATH pointing to the install directory. The
dynamic linker only searches standard system paths.

**Fix**: `patchelf --add-rpath ${LOCAL_PREFIX}/lib libalm.so`. Applied
only if `libalm.so` doesn't already contain the prefix in its RPATH
(idempotent guard).

## PyTorch Phase C — Additional Build Patches

### 62. CK GEMM gfx1151 support (pytorch/3)

**Symptom**: PyTorch logs "Attempting to use CK on an unsupported
architecture!" and TunableOp cannot include CK kernels in autotuning
candidates on gfx1151.

**Root cause**: `aten/src/ATen/Context.cpp` has a hardcoded vector of
supported architectures for Composable Kernel GEMM:
`{"gfx90a", "gfx942", "gfx950"}`. gfx1151 (RDNA 3.5) is not in the
list.

**Fix**: Append `"gfx1151"` to the supported arch vector.

### 63. gloo types.h missing `<cstdint>` (pytorch/9a)

**Symptom**: `uint8_t` undeclared in `third_party/gloo/gloo/types.h`.

**Root cause**: Modern compilers (Clang 18+) no longer transitively
include `<cstdint>` from other standard headers. Same class of issue as
#2/#3.

**Fix**: Add `#include <cstdint>` after `#pragma once`.

### 64. Flatbuffers v24 version assertion bypass (pytorch/9b)

**Symptom**: Build fails with `static_assert(FLATBUFFERS_VERSION_MAJOR ==
24)` when the system has flatbuffers v25 installed.

**Root cause**: PyTorch's auto-generated
`mobile_bytecode_generated.h` has a hardcoded version check against
flatbuffers v24. The build system has flatbuffers v25.

**Fix**: Change `static_assert(FLATBUFFERS_VERSION_MAJOR == 24` to
`static_assert(true || FLATBUFFERS_VERSION_MAJOR == 24`. The original
assertion text is preserved for documentation; `true ||` short-circuits
the check.

### 65. Dynamo C files compile options override (pytorch/9c)

**Symptom**: amdclang errors compiling Dynamo C source files
(`cpython_defs.c`, `eval_frame.c`).

**Root cause**: PyTorch's `torch/CMakeLists.txt` adds C++ compile flags
globally, including `-std=c++17` which is invalid for C source files.
amdclang's C frontend rejects C++-only flags.

**Fix**: Insert `set_source_files_properties()` before
`add_library(torch_python SHARED)` to override compile options for the
two Dynamo C files to `-std=c11 -D_GNU_SOURCE`.

### 66. TORCH_CUDA_CPP_API fallback define (pytorch/10a-c)

**Symptom**: `unknown type name 'TORCH_HIP_CPP_API'` in the generated
HIP `ATenNVRTC.h`, causing compilation failure of the NVRTC stub.

**Root cause**: `ATenNVRTC.h` is generated from a CUDA template by
hipify, which mechanically renames `TORCH_CUDA_CPP_API` to
`TORCH_HIP_CPP_API`. However, `ATenHIPGeneral.h` does not define
`TORCH_HIP_CPP_API` — this is a known leak in the hipify process. The
CUDA template defines `TORCH_CUDA_CPP_API` as `C10_EXPORT`, but the
hipify output doesn't carry this definition forward.

**Fix**: Three-step sed applied to the **CUDA template**
(`aten/src/ATen/cuda/nvrtc_stub/ATenNVRTC.h`), not the HIP-generated
file, so hipify carries the guard into the generated output:
1. Insert `#ifndef TORCH_CUDA_CPP_API` after the `ATenCUDAGeneral.h`
   include
2. Insert `#define TORCH_CUDA_CPP_API C10_EXPORT` (the correct fallback
   from `c10/macros/Export.h`)
3. Insert `#endif // TORCH_CUDA_CPP_API` after the define

### 67. CUDA includes replaced with HIP equivalents (pytorch/11)

**Symptom**: Compilation failures in the NVRTC stub due to missing CUDA
headers.

**Root cause**: The CUDA template `ATenNVRTC.h` contains `#include
<cuda.h>` and `#include <nvrtc.h>`. After hipify generates the HIP
version, these CUDA-specific includes remain unchanged. The HIP build
needs `<hip/hip_runtime_api.h>` and `<hip/hiprtc.h>` instead.

**Fix**: Global replacement in the CUDA template: `<cuda.h>` →
`<hip/hip_runtime_api.h>`, `<nvrtc.h>` → `<hip/hiprtc.h>`. Applied to
the template so hipify carries the correct includes.

### 68. CUB_SUPPORTS_SCAN_BY_KEY macro evaluation error (pytorch/12)

**Symptom**: Preprocessor error in `LegacyThrustHelpers.hip`:
`token is not a valid binary operator in a preprocessor subexpression`
on `#if !CUB_SUPPORTS_SCAN_BY_KEY()`.

**Root cause**: `CUB_SUPPORTS_SCAN_BY_KEY()` is a function-like macro
that is **undefined** in ROCm 7.x hipCUB headers. The preprocessor
evaluates `#if !()` — the empty parentheses are invalid syntax. The
macro existed in NVIDIA's CUB but was never properly ported to ROCm's
hipCUB. Modern ROCm provides `scan_by_key` natively via rocPRIM.

**Fix**: Replace `#if !CUB_SUPPORTS_SCAN_BY_KEY()` with `#if 0 // Fixed:
CUB_SUPPORTS_SCAN_BY_KEY macro evaluation error on modern ROCm`. The
legacy fallback code block (which provides `scan_by_key` only for
toolchains that lack it) is permanently skipped since rocPRIM handles
it natively.

### 69. Duplicate symbol from typo-named file (pytorch/13)

**Symptom**: Linker error: `duplicate symbol:
at::native::_sparse_semi_structured_apply` with both
`SparseSemiStructuredApply.hip` and `SparseSemiSturcturedApply.hip`
defining the same symbol.

**Root cause**: Two files exist in
`aten/src/ATen/native/sparse/hip/`:
- `SparseSemiStructuredApply.hip` (correct spelling)
- `SparseSemiSturcturedApply.hip` (typo: "Sturctured")

Both contain identical code. The ROCm build compiles `*.hip` via
wildcard, so both are compiled, producing duplicate symbols at link time.
A known artifact in the upstream ROCm fork.

**Fix**: Empty the typo-named file (type: `file_rewrite` to a stub
comment). The file must remain for git/CMake integrity but compiles to
an empty `.o` with no symbols.

### 70. Unknown license crash in bundled submodule (pytorch/14)

**Symptom**: `ValueError: could not identify license file for
.../pdcurses` during `pip wheel bdist_wheel`, killing the entire wheel
packaging.

**Root cause**: `third_party/build_bundled.py` collects licenses of
vendored submodules using heuristic text matching against known patterns
(Apache, MIT, BSD). The `pdcurses` port inside `opentelemetry-cpp`
has a license text that doesn't match any pattern. The function falls
through to an `else` branch that raises `ValueError`.

**Fix**: Replace `raise ValueError('unknown license')` with `return
'Unrecognized'`. Type-compatible (the function returns strings like
`'Apache'`, `'MIT'`) and allows packaging to continue.

### 71. SFINAE removal from gemm/bgemm templates (pytorch/15a-b)

**Symptom**: Template compilation errors or ABI mismatch warnings in
GEMM/BGEMM overloads on amdclang 17+.

**Root cause**: `CUDABlas.h` and `HIPBlas.h` use `std::enable_if`
SFINAE constraints on `gemm()`/`bgemm()` overloads with deeply nested
template traits (`CUDABLAS_GEMM_DTYPE_IS_FLOAT_TYPE_AND_C_DTYPE_IS_FLOAT`).
Modern amdclang handles these differently, causing issues with the
nested bracket matching.

**Fix**: Remove the `typename std::enable_if<...>::type* = nullptr`
constraints from both files using a greedy sed pattern that handles the
nested template brackets.

## PyTorch Phase C — Additional Wheel RPATH Fixes

### 72. Build tree RPATH leak in torch/lib/*.so (pytorch/5)

**Symptom**: `import torch` resolves libraries from the build tree path
(`/opt/src/vllm/pytorch/build/lib/`) instead of the wheel.

**Root cause**: cmake bakes the build tree path into RUNPATH of all
`torch/lib/lib*.so` files. Same class of issue as #25b, but generalized
to the entire `torch/lib/` directory rather than a single file.

**Fix**: During wheel unpack/patch/repack, `patchelf --set-rpath` on all
`torch/lib/lib*.so` to
`${LOCAL_PREFIX}/lib:${LOCAL_PREFIX}/lib/llvm/lib:$ORIGIN`. The
`llvm/lib` entry resolves `libomp.so`.

### 73. ROCm-linked libraries missing RPATH (pytorch/6)

**Symptom**: `import torch` fails with `cannot open shared object file`
for ROCm libraries (libalm.so, libamdhip64, librocm_smi64).

**Root cause**: Some `torch/lib/*.so` files have `NEEDED` entries for
ROCm libraries but no RPATH pointing to the ROCm install directory.

**Fix**: `patchelf --add-rpath ${LOCAL_PREFIX}/lib` on any
`torch/lib/lib*.so` whose `NEEDED` list contains `libalm.so`,
`libamdhip64`, or `librocm_smi`.

### 74. _C extension module RPATH (pytorch/7)

**Symptom**: `import torch` fails because `torch/_C*.so` can't find
sibling libraries in the wheel's `lib/` subdirectory.

**Root cause**: The `_C` extension module sits in `torch/` but needs to
resolve libraries in `torch/lib/`. Without `$ORIGIN/lib` in its RPATH,
the dynamic linker can't locate them.

**Fix**: `patchelf --set-rpath
${LOCAL_PREFIX}/lib:${LOCAL_PREFIX}/lib/llvm/lib:$ORIGIN/lib` on
`torch/_C*.so`.

## vLLM Phase E — Additional Patches

### 75. torch version pin relaxation (vllm/28)

**Symptom**: pip downloads PyTorch 2.10.0 from PyPI despite a custom
source-built torch >= 2.10.0 already installed in the venv.

**Root cause**: vLLM's `pyproject.toml` specifies `"torch == 2.10.0"`
as a build dependency. pip interprets the exact pin as requiring that
version from PyPI.

**Fix**: Change `"torch == 2.10.0"` to `"torch >= 2.10.0"` in
`pyproject.toml`.

### 76. Native ROCm PagedAttention for gfx1151 (vllm/29)

**Symptom**: PagedAttention falls back to slow Triton kernels on gfx1151
instead of using native ROCm C++ kernels.

**Root cause**: The PagedAttention backend selection in
`vllm/platforms/rocm.py` gates native ROCm kernels behind `on_gfx9()`
only. gfx1151 (RDNA 3.5) is not gfx9.

**Fix**: Scoped sed extending the `_ON_GFX9` check to include
`("gfx1151" in _GCN_ARCH)` only within the
`use_rocm_custom_paged_attention` function. The scope is deliberately
limited to avoid activating unstable FlashAttention or ViT paths that
require gfx9 CDNA instructions.

### 77. V1 engine CPU weight offloading unlock (vllm/30)

**Symptom**: vLLM V1 engine refuses to start with any `--cpu-offload-gb
> 0`, asserting `cpu_offload_gb == 0`.

**Root cause**: `gpu_model_runner.py` has an unconditional assertion
blocking CPU weight offloading in the V1 engine. On discrete GPUs this
makes sense (PCIe bandwidth bottleneck), but on Strix Halo UMA the CPU
and GPU share 96 GB DDR5 with high bandwidth, making CPU offloading
viable for models exceeding the 48 GB VRAM carveout.

**Fix**: Replace the assertion with `if False: pass # Patched for
Offloading`. The original assertion text is preserved as a comment for
documentation.

## AITER Phase F — Additional Patches

### 78. constexpr warpSize fix for gfx1151 (aiter/4)

**Symptom**: 51 of 67 AITER JIT modules fail to compile with `error:
'warpSize' is not a constant expression`.

**Root cause**: `ck_tile/core/arch/arch.hpp` defines
`CK_TILE_HOST_DEVICE constexpr index_t get_warp_size() { return warpSize;
}`. In ROCm >= 5.x, `warpSize` is a `__device__` runtime variable
(Builtin attribute), not a compile-time constant. C++20 `constexpr`
requires compile-time evaluatable expressions, making this function
ill-formed.

**Fix**: Replace `return warpSize;` with `return 32; // Patched for
gfx1151`. RDNA 3.5 always uses wavefront size 32 (wave32). Applied to
the installed JIT header path (`aiter_meta/csrc/include/...`) to match
existing AITER header patches (#47, #48). Applied before JIT warmup so
modules compile successfully.

## llama.cpp + Lemonade Server (Phase I, Steps 33-34)

### 79. GTT dynamic device detection (DISABLED)

**File:** `/opt/src/vllm/patches/gtt-dynamic-device.patch`
**Status:** DISABLED — commented out in `vllm-packages.yaml`.

**Symptom**: `cudaMalloc failed: out of memory` crashes on ROCm despite
llama.cpp reporting ~72 GB available VRAM.

**Root cause**: The patch adds GTT pool (~25 GB) to reported VRAM in
`ggml/src/ggml-cuda/ggml-cuda.cu` by dynamically enumerating DRM devices
via `opendir`/`readdir` instead of hardcoded `card0`/`card1`. However,
`hipMalloc` can only allocate from the 48 GB BIOS carveout. The GTT pool
is managed by the `amdgpu` kernel driver for page tables and command
buffers and is not accessible via `hipMalloc`. This mismatch causes
llama.cpp to over-commit memory.

**Fix**: Keep disabled. The 48 GB BIOS carveout is the only allocatable
VRAM on Strix Halo. Vulkan/RADV was never affected as `ggml-cuda.cu` is
not compiled for the Vulkan backend.

### 80. CPU variant build explosion (14 → 2)

**File:** `/opt/src/vllm/patches/cmake-zen4-only.patch`

**Symptom**: All three llama.cpp backends build 14 CPU variant shared
libraries (`libggml-cpu-{sse42,sandybridge,...,sapphirerapids}.so`),
multiplying compile time and disk usage with no benefit on Zen 5.

**Root cause**: `GGML_CPU_ALL_VARIANTS=ON` (pulled in by
`GGML_BACKEND_DL=ON`) enables all x86 CPU variants in
`ggml/src/CMakeLists.txt`. The runtime dynamic loader picks the best
variant via CPUID, but intermediate variants like `haswell` and
`skylakex` are unused on Zen 5.

**Fix**: Patch `ggml/src/CMakeLists.txt` under the
`GGML_CPU_ALL_VARIANTS` block to keep only `x64` (baseline) and `zen4`
(highest tier). Zen 5 uses zen4 ISA extensions in llama.cpp's variant
scheme, so the runtime loader selects `libggml-cpu-zen4.so`. Applied to
all three backends (ROCm, Vulkan, CPU).

### 81. Grammar repetition threshold too low

**File:** `/opt/src/vllm/patches/grammar-max-rep-threshold.patch`

**Symptom**: `parse: error parsing grammar: number of rules ... exceeds
sane defaults` when using Lemonade/OpenClaw tool calling with 24+ tool
grammars.

**Root cause**: `MAX_REPETITION_THRESHOLD = 2000` hardcoded in
`src/llama-grammar.cpp`. OpenClaw's combined tool grammars (cron,
sessions, video-generate, etc.) produce rule counts exceeding 2000.

**Fix**: Cherry-pick of PR #21003. Replaces the macro with a per-instance
`uint64_t max_repetition_threshold` field, reads `LLAMA_GRAMMAR_MAX_REPS`
envvar at construction time (with try/catch for invalid values). Default
raised to 50000. Applied to all three backends.

### 82. Lemonade backend manager "update required" UI lock

**File**: Inline sed in `vllm-packages.yaml`, no separate patch file.

**Symptom**: Lemonade Web UI shows "update required" for all llamacpp
backends and locks the backend selector, preventing model loading.

**Root cause**: Lemonade compares builtin cache `version.txt` with
expected versions in `src/cpp/resources/backend_versions.json`. Custom
paths are used for binary detection, but the version check always reads
from builtin cache — producing a mismatch for any custom build. The UI
enters an unrecoverable "update required" state.

**Fix**: sed with range address `/"llamacpp"/,/}/` clears the `vulkan`,
`rocm`, and `cpu` expected version strings to empty in
`backend_versions.json`. With empty expected versions, `has_expected`
evaluates to false, `needs_update` becomes false, and backend state
becomes `"installed"`. Only affects custom builds — AUR has its own
compiled-in resources.

Range address is critical: a global sed pattern like
`s/"vulkan": "[^"]*"/"vulkan": ""/` would also match `whispercpp`,
`sd-cpp`, `kokoro` sections.

### 83. libomp.so transitive dependency not found at runtime

**Non-issue**: libomp.so is a transitive dependency of amdclang-compiled
`.so` files. Linux dynamic linker searches transitive deps only in
`$ORIGIN` of the calling `.so`, ignoring RUNPATH of the main binary.
Setting RPATH on the llama-server binary is insufficient.

**Fix**: Copy `libomp.so` from TheRock SDK into each build directory
alongside the other `.so` files (same approach as ROCm backend shared
libs). ROCm backend skips this copy as it links against TheRock's
libomp directly.

### 84. execvp() crash with AUR Lemonade + custom backends

**Symptom**: AUR `lemonade-server` v10.2 crashes when launching custom
llama-server via `execvp()` (`llamacpp_server.cpp:372`). The same binary
works perfectly when run standalone.

**Root cause**: Unresolved. The AUR-built `lemond` binary (stripped,
3.5 MB, no RUNPATH, no TheRock deps) fails to exec the custom-built
llama-server despite PATH and permissions being correct. May be related
to sandbox/ambient capability interaction or stripped binary symbol
resolution.

**Fix**: Source-built Lemonade (4.3 MB, unstripped, RUNPATH
`[$ORIGIN:/opt/src/vllm/local/lib]`, TheRock deps `libalm.so` and
`libau_cpuid.so`) resolves the issue entirely. Verified with Qwen3.5-9B
(Vulkan + ROCm) and Qwen3.6-35B-A3B (Vulkan). The source build is 130
commits ahead of v10.0.0, including fixes not present in the AUR v10.2.0
tag.

### 85. --ngl long-form crashes llama.cpp v229

**Non-issue**: `--ngl 99` (long-form double-dash) causes a crash in
llama.cpp v229. `-ngl 99` (short-form single-dash) works correctly.

**Impact**: None — Lemonade uses `-ngl` (short-form) internally
(`llamacpp_server.cpp:322`). Only relevant for manual invocation.

### 86. .env template `{{ nproc }}` not interpolated

**Symptom**: `generate_env_file` in `build-vllm.sh` produces a literal
`{{ nproc }}` string in the output `.env` file instead of the actual
core count.

**Root cause**: Template variable `{{ nproc }}` is not recognized by the
shell-based substitution logic in `generate_env_file()`.

**Fix**: Shell-template interpolation in `generate_env_file()`: values matching
`{{ cmd }}` are evaluated via `eval` at generation time. `nproc` is the only
current use; the pattern supports arbitrary shell commands.

### 87. Smoke test robustness and diagnostics (Dillflix cherry-pick)

**Symptom**: Several issues in `backend_smoke_test()`:
- `continue` used outside any loop in llama.cpp ROCm/Vulkan mktemp
  error handlers (bash error, but silently swallowed by `||`).
- vLLM smoke test uses default (bf16) dtype instead of fp16, wasting
  memory on UMA systems.
- No version information printed before vLLM inference, making
  triage of smoke test failures harder.
- No explicit multiprocessing start method set before vLLM import.

**Root cause**: Original smoke test implementation lacked error handling
polish. `continue` was copy-pasted from a loop context into an
if/elif/else chain. Dillflix/gfx1151-stack identified and fixed these.

**Fix**:
1. Removed invalid `continue` from both mktemp error handlers (ROCm
   and Vulkan). Result is already set to FAIL; execution falls through
   to the timeout block which handles empty `_rocm_tmp`/`_vulkan_tmp`
   gracefully.
2. Added `dtype='half'` to `LLM()` constructor for fp16 inference
   (half the memory of bf16 on UMA).
3. Added version printing for torch, triton, and vllm before the
   inference test.
4. Added `torch.multiprocessing.set_start_method('spawn', force=True)`
   before vLLM import for robust process forking on ROCm.

### 88. Runtime helper robustness (Dillflix cherry-pick)

**Symptom**: Several issues in the runtime helper scripts:
- `vllm_gpu_total_mb()` uses `head -1` on rocm-smi output, only
  returning the first GPU's VRAM on multi-GPU systems.
- GTT memory is reported per-partition; `head -1` only captures the
  first partition, underreporting available memory when GTT is split.
- `vllm-start.sh` does not set `--gpu-memory-utilization` when
  `VLLM_<ROLE>_GPU_MEMORY_MB` is not configured, leaving vLLM's
  default at 0.9 (10% wasted on UMA systems with 48 GB carveout).
- Startup failures only show `tail -30` of the log with no pattern
  analysis, making triage difficult.

**Root cause**: Runtime helpers were written for a single-GPU, single-
partition environment. Dillflix/gfx1151-stack addressed these gaps.

**Fix**:
1. Rewrote `vllm_gpu_total_mb()` to sum VRAM across all GPUs and all
   GTT partitions using `while read` loops instead of `head -1`.
2. Added default `--gpu-memory-utilization 0.98` in `vllm-start.sh`
   when no explicit memory limit is configured per role.
3. Added `vllm_print_startup_failure_details()` in
   `vllm-runtime-helpers.sh` that shows last 50 log lines and checks
   for common error patterns (OOM, HIP errors, import errors, port
   conflicts, permission denied). Replaced `tail -30` call in
   `vllm-start.sh`.

### 89. Qwen3VL ViT NaN on gfx1151 (ROCm BF16 overflow)

**Symptom**: Qwen3-VL-Embedding-8B produces 100% NaN in
`last_hidden_state` when processing images through the ViT encoder on
AMD gfx1151 (Radeon 8060S). Text-only embeddings work correctly.
Image-only and text+image embeddings are completely NaN.

**Root cause**: The ViT encoder's SDPA (scaled dot-product attention)
and/or GELU-tanh operations produce NaN in BF16 and FP16 on
gfx1151/ROCm. The `[ROCm] PyTorch's native GELU with tanh
approximation is unstable` warning logged at startup confirms the
tanh path is problematic. FP16 also fails (narrower range ±65504
makes overflow even easier). Only FP32 computation avoids the NaN.

**Fix**: Wrap `self.visual = Qwen3_VisionTransformer(...)` initialization
in `set_default_torch_dtype(torch.float32)` so all ViT parameters are
created in FP32. Weight loading preserves FP32 via `copy_()`, and ViT
outputs are seamlessly cast back to BF16 at the multimodal merge point
(`_merge_multimodal_embeddings` casts to `input_dtype`).

Patch file: `patches/qwen3vl-vit-fp32.patch`

**Verification**: Transformers direct test (Phase 1) confirmed BF16=NaN,
FP16=NaN, FP32=OK. vLLM offline test (Phase 2) confirmed correct
similarity scores: Q1→Doc1=0.74, Q1→Doc2=0.65 (image embedding).
vLLM HTTP API test (Phase 3) confirmed text-only embeddings return
4096-dim vectors with correct cosine similarity.

### 90. Qwen3-VL-Embedding requires `--convert embed` (no native pooler)

**Symptom**: vLLM server starts with `--runner pooling` but without
`--convert embed`, producing incorrect embedding vectors (no L2 norm,
no LAST-token pooling). Documentation incorrectly stated the model has
its own pooler in `config.json`.

**Root cause**: `Qwen3VLForConditionalGeneration` has no native pooler.
Without `--convert embed`, vLLM's `as_embedding_model()` is not invoked
and the model outputs raw hidden states instead of proper embeddings.

**Fix**: Set `VLLM_QWEN3_EMBED_CONVERT=embed` in `.env`, which maps to
`--convert embed` in `vllm-start.sh`. The `as_embedding_model()` call
injects a `DispatchPooler.for_embedding` with LAST-token pooling +
L2 normalization, equivalent to the official `Qwen3VLEmbedder._pooling_last()`.

**Verification**: Phase 3 HTTP API test confirmed 4096-dim embeddings
with correct cosine similarity scores.

### 91. Qwen3VL encoder-cache profiling crash (video OOM)

**Symptom**: Dual-instance vLLM setup (Embed + Reranker) crashes during
startup. The EngineCore process becomes a zombie (`ZN`, `<defunct>`) while
the APIServer remains alive but unresponsive. VRAM is not released (16.2 GiB
leaked). Health check never passes.

Log stops at:
```
Encoder cache will be initialized with a budget of 12288 tokens,
and profiled with 1 video items of the maximum feature size.
```

**Root cause**: `Qwen3_VLMultiModalProcessor` defines
`DUMMY_VIDEO_NUM_FRAMES = 2048`. During startup, vLLM profiles the encoder
cache by running a full ViT forward pass with 2048 video frames at maximum
resolution (~12288 visual tokens). On gfx1151 with only ~22 GiB per instance
(dual-instance, `gpu_memory_utilization=0.45`), this spike exceeds available
VRAM and crashes the EngineCore.

The profiling path (`gpu_model_runner.py:5757-5788`) selects video as the
"maximum token modality" and runs `model.embed_multimodal()` with dummy video
data. Video produces ~12× more tokens than image (~12288 vs ~1100).

**Fix**: Add `--limit-mm-per-prompt '{"video": 0, "image": 1}'` to both
Embed and Reranker roles. Setting `video: 0` removes video from
`tower_modalities` in `encoder_budget.py:73-77`, preventing the video
profiling forward pass entirely. Only image profiling is performed
(~1100 tokens, ~1 GiB ViT activation instead of ~12+ GiB).

**Implementation**:
- `.env`: Added `VLLM_QWEN3_*_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'`
- `vllm-start.sh`: Added `limit_mm_per_prompt` variable and `--limit-mm-per-prompt`
  CLI flag support

**Alternative considered**: `--skip-mm-profiling` skips ALL multimodal profiling
including images, which means vLLM cannot properly size the encoder cache for
image inputs. Not recommended for multimodal models.

### 92. FP8 E5M2 KV cache for RDNA 3+ (gfx1151 Strix Halo)

**Symptom**: `--kv-cache-dtype fp8_e4m3` crashes vLLM on gfx1151 with:

```
ValueError("type fp8e4nv not supported in this architecture.
The supported fp8 dtypes are ('fp8e5',)")
```

And `--kv-cache-dtype fp8_e5m2` crashes with:

```
RuntimeError: Unsupported data type of kv cache: fp8_e5m2
```

**Root cause**: Three separate issues prevent FP8 KV cache on RDNA 3+ GPUs:

1. **Triton JIT** (`prefix_prefill.py`, `chunked_prefill_paged_decode.py`):
   These kernels derive the FP8 scalar type from
   `current_platform.fp8_dtype()`. On gfx1151, `RocmPlatform.fp8_dtype()`
   returned `torch.float8_e4m3fn`, but Triton can only compile `fp8e5`
   (=`float8_e5m2`) for RDNA 3+ hardware. The resulting JIT compilation
   failure kills the EngineCore.

2. **C++ KV cache dispatch** (`amd/quant_utils.cuh`):
   The `DISPATCH_BY_KV_CACHE_DTYPE` macro only handled `"fp8"` and
   `"fp8_e4m3"`, with no branch for `"fp8_e5m2"`. Any `fp8_e5m2` request
   fell through to `TORCH_CHECK(false, "Unsupported data type of kv cache")`.

3. **C++ FP8 conversion functions** (`amd/quant_utils.cuh`):
   The `convert` and `scaled_convert` template functions only dispatched to
   `Fp8KVCacheDataType::kFp8E4M3`, with no `kFp8E5M2` branch. Even with the
   dispatch macro fixed, the E5M2 path would hit `assert(false)`.

4. **Platform detection** (`rocm.py`):
   `supports_fp8()` excluded gfx1151 (only checked gfx94/gfx95/gfx12), and
   `fp8_dtype()` always returned `float8_e4m3fn` for non-FNUZ platforms,
   even though RDNA 3+ hardware only supports E5M2 natively.

**Fix**: Four-part patch enabling `--kv-cache-dtype fp8_e5m2` on gfx1151:

- `vllm/platforms/rocm.py`: Added gfx1100/gfx1151 to `supports_fp8()`, and
  made `fp8_dtype()` return `torch.float8_e5m2` for Navi GPUs (`is_navi()`).
  This ensures Triton kernels use the correct E5M2 scalar type.

- `vllm/csrc/quantization/w8a8/fp8/amd/quant_utils.cuh`: Added E5M2 branch
  to `DISPATCH_BY_KV_CACHE_DTYPE` macro (matching the NVIDIA path), and
  added `vec_conversion_e5m2`/`scaled_vec_conversion_e5m2` function sets
  using `__hip_fp8_e5m2` types. Updated `convert`/`scaled_convert` to
  dispatch `kFp8E5M2` to the new E5M2 functions.

- `.env`: Set `VLLM_QWEN3_*_KV_CACHE_DTYPE="fp8_e5m2"` for both roles.

- C++ extension rebuild required after patching `quant_utils.cuh`.

**Patch file**: `patches/fp8-e5m2-quant-utils.patch` (YAML patch #35)

**Note**: `fp8_e4m3` remains broken on gfx1151 because Triton cannot compile
`float8_e4m3fn` atoms for this architecture. E5M2 has less mantissa precision
(2 bits vs 3 bits) but halves KV cache memory like E4M3.

### 93. FP8 E5M2: missing native-type vector specializations (build error)

**Symptom**: C++ extension build fails in `paged_attention_v1.hip` and
`paged_attention_v2.hip` with:

```
error: no viable conversion from returned value of type 'const unsigned int'
      to function return type 'HIP_vector_type<float, 4>'
error: no viable conversion from returned value of type
      'const HIP_vector_type<unsigned int, 2>' to function return type 'vllm::bf16_8_t'
```

**Root cause**: The paged attention kernel instantiates
`fp8::scaled_convert<V_vec, V_quant_vec, kFp8E5M2>` where `V_vec` is the
*native* HIP type `float4` or `bf16_8_t` (from `Vec<scalar_t, VEC_SIZE>::Type`).
The E5M2 patch (#92) only provided `Float4_` (custom struct) and
`bf16_4_t` specializations for the vec4 dequant path. The native-type
specializations (`float4←uint32_t` and `bf16_8_t←uint2`) were missing,
causing the generic fallback template `return x` (identity) to compile,
which fails when `Tout ≠ Tin`.

**Fix**: Added two template specializations to `quant_utils.cuh`:

- `scaled_vec_conversion_e5m2<bf16_8_t, uint2>` — delegates to
  `bf16_4_t←uint32_t`, assembles into `bf16_8_t` (matches E4M3 Z.378).

- `scaled_vec_conversion_e5m2<float4, uint32_t>` — delegates to
  `Float4_←uint32_t`, then unpacks to native `float4` via
  `{res.x.x, res.x.y, res.y.x, res.y.y}` (matches E4M3 Z.421).

No other specializations are needed: all other `scaled_vec_conversion_e5m2`
combinations exist, `vec_conversion_e5m2` (unscaled) is never instantiated,
and the `Half` path is blocked by `TORCH_CHECK` at runtime.

**Prerequisite**: Delete stale hipified copy before incremental build:
`find build/ -name "quant_utils.cuh.hip" -delete`

### 94. V1 EngineCore zombie on ROCm/gfx1151 with `nohup`

**Symptom**: When vLLM V1 is launched via `nohup ... &` in the background, the
EngineCore subprocess becomes a zombie (`<defunct>`). The APIServer stays alive
but never responds to health checks. VRAM is leaked (no release from the zombie
process). `ps aux` shows `ZN` state for the EngineCore.

The following did **not** fix this:
- `--skip-mm-profiling` — crash is not caused by ViT profiling
- `HSA_LAUNCH_BLOCKING=1` — not a HIP kernel timing issue
- `VLLM_ENABLE_V1_MULTIPROCESSING=0` with `nohup` — EngineCore still forking
  inside a `nohup` session

**Root cause**: vLLM V1 launches the EngineCore via `multiprocessing.Process`
using Python's "forkserver" start method. When the parent process runs inside
a `nohup ... &` background shell, the child process inherits a broken session
state. On ROCm/gfx1151, the HIP runtime initialization inside the forked child
fails silently — the process becomes a zombie without ever completing startup.

`nohup` detaches from the terminal but does **not** create a new session.
The parent remains in the original session's process group. When Python's
`multiprocessing` forks, the child tries to set up its own signal handlers
and HIP context, but the session structure is inconsistent.

**Fix**: Replace `nohup` with `setsid` in `vllm-start.sh`. `setsid` creates a
new session and process group, giving the forked EngineCore subprocess a clean
session state. The `setsid` command also detaches from the terminal (like
`nohup`), so it serves the same background-launch purpose.

```bash
# Before (broken):
nohup vllm serve ... > log 2>&1 &

# After (fixed):
setsid vllm serve ... > log 2>&1 &
```

**Alternative**: `VLLM_ENABLE_V1_MULTIPROCESSING=0` runs EngineCore in-process
(avoiding the fork entirely), but loses process isolation — an EngineCore crash
kills the entire server.

**Implementation**:
- `vllm-start.sh` line 224: `nohup` → `setsid`
- No `.env` change needed (default `VLLM_ENABLE_V1_MULTIPROCESSING=1` is correct)

### 95. `--skip-mm-profiling` per-role flag in vllm-start.sh

**Symptom**: No per-role mechanism to skip multimodal encoder-cache profiling
during startup. Some models (e.g., pure text models, or models with known
profiling issues) benefit from skipping this step entirely.

**Root cause**: `vllm-start.sh` had no configuration variable for the
`--skip-mm-profiling` CLI flag. The only MM-related flag was
`--limit-mm-per-prompt`, which is the correct approach for VL models (it
removes specific modalities like video without disabling all MM profiling).

**Fix**: Added `VLLM_<ROLE>_SKIP_MM_PROFILING` as a per-role configuration
variable, mapped to the `--skip-mm-profiling` CLI flag.

```bash
# .env (NOT recommended for VL models — use LIMIT_MM_PER_PROMPT instead)
# VLLM_QWEN3_EMBED_SKIP_MM_PROFILING=true
```

For VL models, `--limit-mm-per-prompt '{"video": 0, "image": 1}'` (BUILD-FIXES
#82) is preferred because it preserves image encoder-cache profiling while
only disabling the problematic video modality. `--skip-mm-profiling` disables
all MM profiling, preventing proper encoder-cache sizing for any modality.

**Implementation**:
- `vllm-start.sh`: Added `skip_mm_profiling` variable and `--skip-mm-profiling`
  flag support
- `vllm-runtime-helpers.sh`: Added `VLLM_ENABLE_V1_MULTIPROCESSING` to
  `vllm_log_optimization_state()` display
- `.env`: Added commented-out `SKIP_MM_PROFILING` per-role lines

### 96. V1 EngineCore 100% CPU idle busy-loop

**Symptom**: Each EngineCore subprocess consumes 100% of one CPU core when idle
(no active requests). For dual-instance setups (Embed + Reranker), this wastes 2
cores permanently.

**Root cause**: `_process_engine_step()` in `v1/engine/core.py` sleeps only when
`model_executed=False AND scheduler.has_unfinished_requests()`. In the idle
state, `has_unfinished_requests()` is false, so no sleep occurs and the
`run_busy_loop()` immediately retries, creating a tight hot loop. PR #29476 added
a conditional `time.sleep(0.001)` but it does not trigger when truly idle.

**Fix**: Progressive backoff in `_process_engine_step()`:
- 0ms → 1ms → 10ms → 100ms → 500ms across consecutive idle steps
- Reset to 0ms immediately on any model execution or new request arrival

```python
# In EngineCore.__init__:
self._idle_backoff = [0.0, 0.001, 0.010, 0.100, 0.500]
self._idle_level = 0

# In _process_engine_step(), replace:
if not model_executed and self.scheduler.has_unfinished_requests():
    time.sleep(0.001)

# With:
if not model_executed:
    if self.scheduler.has_unfinished_requests():
        time.sleep(0.001)
        self._idle_level = 0
    else:
        sleep_dur = self._idle_backoff[
            min(self._idle_level, len(self._idle_backoff) - 1)]
        time.sleep(sleep_dur)
        self._idle_level += 1
else:
    self._idle_level = 0
```

**Implementation**:
- `vllm/vllm/v1/engine/core.py`: Added `_idle_backoff` / `_idle_level` to
  `EngineCore.__init__`, replaced sleep logic in `_process_engine_step()`
- `patches/enginecore-idle-backoff.patch`: Git diff patch file for idempotent
  application via `git apply --reverse --check` (BUILD-FIXES mechanism)
- `vllm-packages.yaml`: Patch entry #33 (`type: patch`) under `packages.vllm.patches`
  ensures the fix is automatically applied on every rebuild
- `.env`: Removed `VLLM_ENABLE_V1_MULTIPROCESSING=0` (ineffective for `vllm serve`)

**Upstream status**: Not yet fixed upstream (as of vLLM commit 719735d6c).

### 97. AITER FP4 method calls unimported `on_gfx950()`

**Symptom**: `NameError: name 'on_gfx950' is not defined` when AITER dispatches
FP4 linear kernels (e.g. `is_fp4bmm_enabled()` or
`is_asm_fp4_gemm_dynamic_quant_enabled()`). Both methods import `on_gfx9`
but call `on_gfx950()`, which is not in scope.

**Root cause**: Upstream `_aiter_ops.py` lines 1235-1244 import `on_gfx9`
from `vllm.platforms.rocm` but invoke `on_gfx950()` instead. The `on_gfx950`
function exists in `rocm.py` but is never imported. This is likely an upstream
editing error introduced during the FP4 feature addition.

**Fix**: Replace `on_gfx950()` with `on_gfx9()` in both methods. Since
`on_gfx9()` returns `True` for gfx94x/gfx95x (CDNA3/4) which are exactly
the GPUs that support FP4, this is functionally correct and avoids the
`NameError`. On gfx1151, `on_gfx9()` returns `False`, correctly disabling
FP4 which is not supported on RDNA 3.5.

**Patch**: `patches/aiter-fp4-import-fix.patch`

**YAML**: `type: patch` in `vllm-packages.yaml`

**Upstream status**: Not yet reported upstream (as of vLLM commit 719735d6c).

### 98. `clone_pkg()` — recursive submodule pull corrupts working tree

**Symptom**: During `build-vllm.sh` package updates, `git pull` with user git
config (`pull.rebase=true` or `submodule.recurse=true`) can leave dependency
submodules in conflicted rebases or detached HEAD states. Detached-HEAD repos
with no branch configured silently fail to update.

**Root cause**: The original `clone_pkg()` used bare `git fetch` and `git pull`
without isolating the superproject update from submodule recursion, and had
no guard against detached-HEAD state when no branch was configured.

**Fix**: Fetch and pull with `--no-recurse-submodules` and `--ff-only` to
prevent accidental submodule rebases. Guard detached-HEAD with an explicit
error. Add `git submodule sync --recursive` before `update --init` to ensure
remote URLs are correct after branch switches.

**Upstream**: Cherry-picked from `paudley/ai-notes` commit `b453c33`.

### 99. AITER JIT stale FileBaton locks block pre-warm

**Symptom**: After a crashed AITER JIT compilation, subsequent `warmup_aiter_jit`
runs hang indefinitely because PyTorch's `FileBaton` waits on orphaned `lock_*`
files in the JIT build directory.

**Root cause**: `FileBaton` uses filesystem-level locks for serial compilation.
If the process crashes, lock files remain and the next run deadlocks.

**Fix**: Before the serial pre-warm loop, scan `${jit_dir}/build` for
`lock_*` and `lock` files, check with `lsof`/`fuser` whether any live process
holds them, and remove orphaned locks.

**Upstream**: Cherry-picked from `paudley/ai-notes` commit `b453c33`.

### 100. llama.cpp smoke test output extraction unreliable with PTY mode

**Symptom**: Smoke tests for llama.cpp ROCm and Vulkan backends sometimes
report empty output even though inference succeeded, because `llama-cli`
in PTY-backed mode emits banner and prompt text that contaminates the output.

**Root cause**: The original sed-based extraction (`sed '/^| *//p'`) assumed
conversation-formatted output. With PTY mode, `llama-cli` emits extra lines
that the sed filter cannot cleanly remove.

**Fix**: Add `--simple-io` flag to disable PTY-backed output, and use
`awk`-based extraction that isolates the assistant reply between the `> `
prompt line and the `[ Prompt:` performance footer.

**Upstream**: Cherry-picked from `paudley/ai-notes` commit `b453c33`.

## Runtime Environment Files (Phase I)

The build generates `.env` files for llama.cpp backends used by Lemonade.
These are generated from `vllm-packages.yaml` via the `generate_env_file()`
helper — the YAML `packages.llamacpp.backends.{rocm,vulkan}.env` maps are
the single source of truth.

### ROCm backend `.env`

| Variable | Value | Purpose |
|----------|-------|---------|
| `HSA_OVERRIDE_GFX_VERSION` | `11.5.1` | Override for ROCm runtime gfx1151 detection |
| `ROCBLAS_USE_HIPBLASLT` | `1` | Use hipBLASLt for GEMM (faster on gfx1151) |
| `THP` | `always` | Transparent Huge Pages for unified memory |
| `LLAMA_ARG_BATCH` | `2048` | +33% prefill throughput over default (512) |
| `LLAMA_ARG_UBATCH` | `2048` | Micro-batch size matching batch size |

**Note**: Q8 KV cache (`LLAMA_ARG_CACHE_TYPE_K/V=q8_0`) is omitted from
the generated `.env`. It halves KV bandwidth on unified memory but causes
context creation failures on some small models (e.g. Qwen2.5 0.5B FP16).
Enable per-model during benchmarks.

### Vulkan backend `.env`

| Variable | Value | Purpose |
|----------|-------|---------|
| `LLAMA_ARG_BATCH` | `2048` | Batch size optimization |
| `LLAMA_ARG_UBATCH` | `2048` | Micro-batch size matching batch size |

No HSA/ROCm variables needed — Vulkan uses its own driver stack.
