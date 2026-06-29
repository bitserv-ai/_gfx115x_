<!-- Copyright 2026 bitserv-ai -->
<!-- SPDX-License-Identifier: MIT -->

# INT8 Quantization for Qwen3-VL on gfx1151

Quantization strategy and implementation notes for reducing VRAM footprint
of Qwen3-VL-Embedding-8B and Qwen3-VL-Reranker-8B on ROCm/gfx1151, freeing
memory for co-hosted Lemonade inference.

## Executive Summary

RDNA 3.5 (gfx1151) has native INT8 WMMA hardware (`v_wmma_i32_16x16x16_iu8`)
but **no native FP8 compute**. INT8 is the physically correct quantization
path. The vLLM `compressed-tensors` backend supports INT8 W8A8 and W8A16.
The kernel dispatch chain rejects CUDA-centric kernels (Conch, Exllama,
Marlin) on ROCm, falling back to the architecture-agnostic
`TritonInt8ScaledMMLinearKernel` which compiles via MLIR to native WMMA.

**Validated approach**: W8A16 (QuantizationModifier, RTN) is the production
path. W8A8 was tested and failed (Spearman ρ=0.6, ranking flips). Both
paths save \~50% on weight storage (\~10.5 GiB instead of \~16 GiB per model).

**Sources**: Findings synthesized from three independent Deep Research
queries (Perplexity, Claude, Gemini) plus local build analysis.

## Path to Production

```
Quantize Qwen3-VL Embed+Rerank?
  │
  ├─ FP8? ──→ NO: Triton float8_e4m3fn crashes on gfx1151
  │
  ├─ W8A8 INT8? ──→ TESTED: collin-park pre-quant (GPTQ)
  │   │                Self-quant (GPTQModifier)
  │   └─ FAILED: Spearman ρ=0.6, ranking flips (36-layer activation noise)
  │
  ├─ W8A16 INT8? ──→ No pre-quantized checkpoint available
  │   └─ Self-quantize via QuantizationModifier (RTN, ~30 s per model)
  │   └─ PASSED: CosSim 0.999995, ρ=1.0, 5/5 position matches
  │
  ├─ Accelerate? ──→ AITER gate unlock (on_gfx1x, BUILD-FIXES #35)
  │   └─ VALIDATED: 3.5× embed, 8.5× rerank, determinism 1.0
  │   └─ Tradeoff: ~16 min JIT cold start (cached: ~30 s)
  │
  ├─ Scale to dual-instance? ──→ 21.2 GiB total, 0 errors (30-min burn)
  │   └─ Concurrent pipeline: 0.32s (embed+rerank parallel)
  │
  ├─ Lemonade co-host? ──→ YES — VALIDATED
  │   └─ Running live, triple-backend
  │
  ▼
Production path: W8A16 + AITER
```

## Hardware Foundation

### RDNA 3.5 ISA: INT8 Native, FP8 Emulated

| Capability | Status | Detail |
|-----------|--------|--------|
| INT8 WMMA | **Native** | `v_wmma_i32_16x16x16_iu8` (16x16x16 tile, I8→I32 accumulate) |
| BF16 WMMA | **Native** | `v_wmma_f32_16x16x16_bf16` |
| FP16 WMMA | **Native** | `v_wmma_f32_16x16x16_f16` |
| FP8 WMMA | **None** | Must cast to BF16 via `hip_fp8` library before FMA |
| Peak INT8 throughput | **Higher than BF16** | Scalar INT8 paths outperform packed ops by \~32% on gfx1151 |
| Peak BF16 throughput | \~59.4 TFLOPS | 40 CUs @ 2.9 GHz theoretical |
| Memory bandwidth | 212 GB/s sustained | 256-bit LPDDR5-8000 (256 GB/s theoretical) |

**Confidence**: Confirmed (RDNA3 ISA spec, AMD GPUOpen WMMA guide, FSR4
benchmarks on gfx1151)

 **Key insight**: FP8 on RDNA 3.5 is storage-only. Every FP8 GEMM incurs a software cast to BF16, making it slower than native INT8. FP8 E4M3 additionally crashes on gfx1151 due to Triton compilation failures (`float8_e4m3fn` atoms unsupported in RDNA3+ Triton backend).

### UMA Memory Hierarchy

| Pool | Size | Accessible by |
|------|------|---------------|
| VRAM (BIOS carveout) | 48 GiB | ROCm `hipMalloc`, Vulkan/RADV |
| GTT (kernel-managed) | \~25 GiB | Vulkan/RADV only (not `hipMalloc`) |
| System RAM | \~23 GiB | CPU, vLLM cpu-offload via UVA |

## Quantization Comparison

| Property | BF16 (current) | W8A8 INT8 | W8A16 INT8 | FP8 E4M3 |
|----------|---------------|-----------|------------|----------|
| Weight storage | \~16 GiB | \~10.5 GiB | \~10-11 GiB | \~9 GiB |
| Weight precision | 16-bit float | INT8 per-channel | INT8 per-channel | FP8 E4M3 per-channel |
| Activation precision | BF16 | INT8 dynamic per-token | **BF16 (preserved)** | FP8 dynamic |
| KV Cache | FP8 E5M2 | FP8 E5M2 | FP8 E5M2 | N/A |
| Matmul path | BF16 WMMA | INT8 WMMA via Triton | Dequant→BF16 WMMA | **Crash on gfx1151** |
| Accuracy risk | None | Medium (activation quant) | Low (BF16 activations) | N/A |
| Embedding quality | Baseline | Acceptable with GPTQ | Near-native | N/A |
| Reranker scoring | Baseline | Risk: binary logit shift | Near-native | N/A |
| vLLM backend | native | `compressed-tensors` | `compressed-tensors` | N/A |
| Pre-quantized HF | N/A | `collin-park/...W8A8` | Self-quantize | `RamManavalan/...FP8` |
| gfx1151 confidence | Proven | High (Triton path) | **Very high** | Dead |

**Recommendation**: W8A16 for all production embedding/reranking workloads.
W8A8 is not viable for ranking-sensitive tasks (Spearman ρ=0.6).

### Why W8A16 is Better for Embedding/Reranking

Embedding models pool the last hidden state → L2-normalize → cosine similarity.
Every bit in the activation matters because small errors propagate directly
into the embedding vector. Rerankers have only 2 output classes (yes/no) — a
tiny logit shift can flip the ranking.

W8A8 quantizes activations to INT8 at **every layer** (36 layers = 36x
accumulated quantization error). W8A16 preserves BF16 activations throughout,
limiting error to weight dequantization only.

### INT8 Quality Results

**Embedding quality**: 5 documents (Dog+Beach, Pets+Beach, Stock market,
Travel packing, Cooking) embedded with each quantization scheme. Cosine
similarity and L2 distance measured against BF16 baseline. Rankings compared
via Spearman ρ and position matches.

| Metric | BF16 | W8A8 | W8A16 |
|--------|------|------|-------|
| CosSim preservation (vs BF16) | — | 0.999913 | **0.999995** |
| L2 distance (vs BF16) | — | 0.020704 | **0.003630** |
| Spearman ρ (vs BF16 ranking) | — | 0.6000 | **1.0000** |
| Position matches | — | 3/5 | **5/5** |
| Determinism (CosSim re-embed) | 1.000000 | 1.000000 | 1.000000 |

**W8A8 failure**: Swaps Dog+Beach ↔ Pets+Beach (CosSim diff \~0.007 suffices
to flip ranking). Root cause: INT8 activation quantization noise propagates
through 36 transformer layers.

**W8A16**: Near-perfect BF16 fidelity. Weight-only INT8 with BF16 activations
preserves ranking completely.

**Reranker quality**: Same 5 documents re-ranked by relevance query
(binary yes/no classifier). Spearman ρ and position matches measured
against BF16 baseline. W8A8 reranker not tested separately (embedding
failure already disqualifies W8A8).

| Metric | BF16 | W8A16 |
|--------|------|-------|
| Spearman ρ | — | 0.9000 |
| Position matches | — | 3/5 |
| Score shift | — | +0.054 to +0.084 |
| Score spread | 0.1569 | 0.1392 |
| Top-2 gap | 0.0645 | 0.0482 |

Both BF16 and W8A16 rerankers show identical ranking anomalies (Stock market
scores highest). This is an intrinsic artifact of the binary yes/no classifier —
**not** a quantization issue. The \~+0.07 score shift is expected from INT8 weight
dequantization.

## Kernel Dispatch Path

This is the critical finding from the research: how vLLM routes INT8 linear
layers on ROCm/gfx1151.

### Dispatch Chain for CompressedTensorsW8A8Int8

```
Model loads with --quantization compressed-tensors
  → CompressedTensorsW8A8Int8 scheme activated
    → MPLinearKernel selector checks kernels in priority order:

      1. AiterInt8ScaledMMLinearKernel
         → REJECT: gated behind on_gfx9() — only gfx94x/gfx95x (CDNA3/4)
         → Bypassable with source patch (see AITER Unlock section)

      2. ConchLinearKernel (ROCm priority)
         → min_capability=80: PASS (gfx1151 reports 115)
         → BUT: rejects at can_implement() — CUDA-centric, group_size
           assertions fail on ROCm, conch library deps missing
         → REJECT

      3. ExllamaLinearKernel (fallback)
         → Strictly supports float16 activations only
         → W8A8 produces int8 activations — incompatible
         → REJECT

      4. MarlinLinearKernel / MacheteLinearKernel
         → Explicit CUDA-only assertions
         → REJECT

      5. TritonInt8ScaledMMLinearKernel (final fallback)
         → Architecture-agnostic: compiles via MLIR to host ISA
         → Emits v_wmma_i32_16x16x16_iu8 on gfx1151
         → **ACCEPT: This is the operational kernel**
```

**Source**: Gemini Deep Research (kernel dispatch analysis), confirmed by
vLLM source code inspection (`compressed_tensors_w8a8_int8.py`,
`mp_linear_kernel`)

### Dispatch for CompressedTensorsWNA16 (W8A16)

```
W8A16 (weight-only) follows a simpler path:
  → CompressedTensorsWNA16 with num_bit=8
    → Dequantize INT8 weights to BF16 in SRAM
    → Standard BF16 GEMM via hipBLASLt/hipBLAS
    → No INT8 GEMM kernel required
```

**Confidence**: Confirmed (Gemini, Claude, vLLM source)

## Triton Constraints on gfx1151

### Block Size Limits

The Triton compiler on gfx1151 has strict tile-size requirements for INT8
`tl.dot` operations. Exceeding these causes MLIR lowering failures:

```
cast<Ty>() argument of incompatible type!
```

| Parameter | Maximum | Recommended |
|-----------|---------|-------------|
| BLOCK_M | 32 | 32 |
| BLOCK_N | 32 | 32 |
| BLOCK_K | 64 | 64 |

**Mitigation**: vLLM's `TritonInt8ScaledMMLinearKernel` should respect these
limits via its autotuner config. If not, manual tuning required.

**Source**: Gemini (Triton issue #5669, community testing)

### Triton 3.6.0 Implicit Casting Bug

Triton 3.6.0 (bundled with ROCm 7.x stacks) has a known bug: `store(i1, i32)`
operations can implicitly cast 32-bit integers down to 8-bit, corrupting
activation scales during the dequantization pass.

**Mitigation** (W8A8 only): Ensure Triton kernels explicitly enforce `.to(tl.float32)`
bounds prior to scaling multiplication. W8A16 is unaffected — it does not use
Triton INT8 kernels.

**Source**: Gemini (Triton issue tracker)

### tl.dot(int8, int8, out_dtype=tl.int32) on gfx1151

AOTriton 0.10b introduced experimental gfx1151 support. Triton's AMD backend
targets gfx1151 in recent builds and should emit `v_wmma_i32_16x16x16_iu8`
when compiling `tl.dot(int8, int8, out_dtype=tl.int32)`.

**Confidence**: Probable (ISA confirms hardware capability, AOTriton
experimental support exists, but no public production vLLM benchmark confirms
end-to-end performance)

## ViT FP32 Compatibility

### Interaction with INT8 Quantization

The INT8 quantization (both W8A8 and W8A16) applies only to LLM decoder
Linear layers. The ViT encoder is explicitly excluded via `ignore` patterns.

| Component | Quantized Model Precision | Runtime Behavior |
|-----------|--------------------------|-----------------|
| ViT weights | BF16 (excluded from quant) | Cast to FP32 by existing patch (BUILD-FIXES #89) |
| ViT activations | FP32 (forced by patch) | Same as BF16 baseline |
| LLM Linear weights | INT8 (quantized) | Dequantized by Triton kernel |
| LLM activations | INT8 (W8A8) or BF16 (W8A16) | Per-scheme behavior |
| KV Cache | FP8 E5M2 (BUILD-FIXES #92/#93) | Unchanged |

The ViT FP32 patch (BUILD-FIXES #89, `patches/qwen3vl-vit-fp32.patch`) must
remain active. It operates independently of INT8 quantization — ViT weights
are stored in BF16 in the quantized model and converted to FP32 at model
initialization time.

**Confidence**: Confirmed (ViT exclusion is explicit in quantization recipes,
FP32 patch operates at model init, not at weight serialization level)

## Pre-Quantized Models

### HuggingFace Checkpoints

| Model | Repo | Format | Size | ViT Precision |
|-------|------|--------|------|---------------|
| Embedding W8A8 | `collin-park/Qwen3-VL-Embedding-8B-W8A8` | compressed-tensors | \~10.5 GiB | BF16 (preserved) |
| Embedding FP8 | `RamManavalan/Qwen3-VL-Embedding-8B-FP8` | compressed-tensors | \~9 GiB | BF16 (preserved) |
| Reranker FP8 | `Forturne/Qwen3-VL-Reranker-8B-FP8` | compressed-tensors | \~9 GiB | BF16 (preserved) |

### W8A8 Embedding Details (collin-park)

- **Method**: GPTQ W8A8 INT8 (weights INT8 per-channel, activations INT8 dynamic per-token)
- **Calibration**: 512 samples from ultrachat-200k, max 2048 tokens
- **ViT**: Excluded (`ignore=["re:.*visual.*"]`), kept in BF16
- **No SmoothQuant**: Correctly avoided — corrupts RMSNorm weights
- **Tensor types**: `BF16` + `I8` (not F8_E4M3)
- **vLLM usage**: `--quantization compressed-tensors`
- **Tested on**: RTX 3090 (24 GB), vLLM 0.17.1

### FP8 Models (NOT usable on gfx1151)

Both FP8 models use FP8_E4M3 weights which crash on gfx1151 due to Triton
compilation failures (BUILD-FIXES #92/#93). Listed here for completeness only — do not use.

## Self-Quantization Recipes

### Tool: llm-compressor

```bash
pip install llm-compressor>=0.8.0
```

llm-compressor 0.8.0+ has explicit Qwen3-VL architecture support and defaults
to `actorder: "weight"` which improves accuracy recovery by up to 2 percentage
points.

#### Tested Toolchain

| Component | Version | Notes |
|-----------|---------|-------|
| Python | 3.12.13 | CPU-only venv sufficient |
| llmcompressor | 0.10.0.1 | `QuantizationModifier` + `GPTQModifier` |
| compressed-tensors | 0.14.0.1 | Output format for vLLM |
| PyTorch | 2.11.0+cpu | GPU not required for W8A16 RTN |
| transformers | 4.57.6 | `AutoModelForImageTextToText` resolves to `Qwen3VLForConditionalGeneration` |

#### QuantizationModifier vs GPTQModifier

| Aspect | `QuantizationModifier` | `GPTQModifier` |
|--------|----------------------|----------------|
| Algorithm | **RTN** (round-to-nearest) | **GPTQ** (Hessian-based error compensation) |
| Calibration data | **Not required** | Required (512+ samples) |
| Hessian computation | **None** | Always (Cholesky decomposition) |
| `oneshot()` dataset param | Not needed | Must provide `dataset`, `num_calibration_samples` |
| Quality (W8A16) | Near-native | Marginally better (\~0.1%) |
| RAM overhead | \~16 GiB (model only) | \~30-40 GiB (model + Hessians) |
| Time | \~30 sec | \~60-120 min |

`GPTQModifier.on_start()` always computes Hessians on every forward pass
— there is no code path that skips Hessians for weight-only schemes.
`QuantizationModifier.on_start()` uses `memoryless_minmax` observer directly
on weights — no Hessians, no calibration data, pure RTN.

**Decision**: `QuantizationModifier` (RTN) for W8A16. GPTQModifier available
as W8A8 fallback only.

### W8A16 INT8 — Weight-Only (Production Path)

W8A16 weight-only quantization produces per-channel INT8 scales with no
activation quantization:

```
QuantizationArgs(num_bits=8, type=INT, strategy=CHANNEL, symmetric=True, dynamic=False)
```

Weights are stored as INT8 with per-channel BF16 scales. Activations remain
BF16 throughout — dequantization happens in SRAM before the BF16 GEMM.

The production recipe uses `QuantizationModifier` (RTN) — no calibration
data required, \~30 seconds per model:

```python
import torch
from transformers import AutoModelForImageTextToText, AutoProcessor
from llmcompressor import oneshot
from llmcompressor.modifiers.quantization import QuantizationModifier

DTYPE = torch.bfloat16
INPUT_DIR = "/path/to/Qwen3-VL-Embedding-8B"
OUTPUT_DIR = "/path/to/Qwen3-VL-Embedding-8B-W8A16"
IGNORE = ["lm_head", "re:.*visual.*"]

model = AutoModelForImageTextToText.from_pretrained(
    INPUT_DIR,
    torch_dtype=DTYPE,
    low_cpu_mem_usage=True,
    trust_remote_code=True,
)

model = model.to("cuda" if torch.cuda.is_available() else "cpu")
processor = AutoProcessor.from_pretrained(INPUT_DIR, trust_remote_code=True)

recipe = QuantizationModifier(
    targets="Linear",
    scheme="W8A16",
    ignore=IGNORE,
)

oneshot(
    model=model,
    recipe=recipe,
    output_dir=OUTPUT_DIR,
)
```

For Reranker, use the same recipe with `INPUT_DIR` and `OUTPUT_DIR` changed.
The `IGNORE` list is identical — there is no `score` layer in the checkpoint
(it only exists via `--hf-overrides` at runtime).

#### Quantization Ignore Patterns

| Pattern | Matched layers | Reason |
|---------|---------------|--------|
| `lm_head` | `model.lm_head` | Classification head; INT8 error propagates to output logits |
| `re:.*visual.*` | All 108 ViT Linear layers | ViT produces NaN in BF16 on gfx1151; must stay BF16 for FP32 patch |

`re:` prefix → regex match. Without prefix → exact/class match. No suffix/prefix matching.

The Reranker checkpoint does **not** contain `score.weight` — the `score` head
only exists when vLLM overrides the architecture to `Qwen3VLForSequenceClassification`
at runtime via `--hf-overrides`. `"score"` in the ignore list is harmless but unnecessary.

#### device_map and torch_dtype Rationale

No explicit `device_map` is passed — the model loads onto a single device via
`.to("cuda"|"cpu")` after construction. llmcompressor's `DataFreePipeline`
calls `dispatch_model()` internally, which requires a visible device in
`get_device_memory()`. On CPU-only systems this returns an empty dict, causing
a crash. The `quantize_w8a16.py` script monkey-patches `get_device_memory()`
to inject CPU memory as a device entry, making `dispatch_model()` place
everything on CPU automatically.

On systems with a GPU, `.to("cuda")` works — but stop vLLM/Lemonade before
running to avoid VRAM contention.

The Reranker's `config.json` declares `float32` dtype, but actual weights are
BF16 (17 GiB checkpoint, not 32 GiB). `torch_dtype=torch.bfloat16` is correct —
RTN computes per-channel scales identically whether source is FP32 or BF16,
and halves RAM during quantization (\~16 GiB instead of \~32 GiB).

### W8A8 INT8 — Reference (Failed: Spearman ρ=0.6)

W8A8 was tested with GPTQModifier using calibration data from ultrachat-200k.
Both models were quantized. Result: ranking flips (Spearman ρ=0.6) due to
INT8 activation quantization noise accumulating across 36 transformer layers
(see INT8 Quality Results).

Use `Qwen3VLForConditionalGeneration` (not `AutoModel`) to preserve
`model.*` weight prefix for vLLM compatibility.

```python
from transformers import Qwen3VLForConditionalGeneration
from llmcompressor import oneshot
from llmcompressor.modifiers.quantization import GPTQModifier

model = Qwen3VLForConditionalGeneration.from_pretrained(
    MODEL_ID,
    dtype="auto",
    device_map="auto",
    trust_remote_code=True,
)

recipe = GPTQModifier(
    targets="Linear",
    scheme="W8A8",
    ignore=["lm_head", "re:.*visual.*"],
)

oneshot(
    model=model,
    dataset="ultrachat-200k",
    splits={"calibration": "train_sft"},
    recipe=recipe,
    max_seq_length=MAX_SEQ_LEN,
    num_calibration_samples=512,
    output_dir=OUTPUT_DIR,
)
```

| Variant | `MODEL_ID` | `MAX_SEQ_LEN` | `dampening_frac` | `offload_hessians` |
|---------|-----------|---------------|-------------------|---------------------|
| Embedding | `Qwen/Qwen3-VL-Embedding-8B` | 2048 | (default) | (default) |
| Reranker | `Qwen/Qwen3-VL-Reranker-8B` | 4096 | (default) | (default) |
| UMA-optimized | Either | 2048 | 0.01 | `True` |

The UMA-optimized variant reduces RAM by \~15 GiB via `offload_hessians=True`
(critical on shared-memory systems with 96 GiB total).

### Quantization Duration Estimate

| Model | Scheme | Modifier | Estimated Time | RAM Required |
|-------|--------|----------|---------------|--------------|
| Either 8B | W8A16 | QuantizationModifier (RTN) | \~30 sec | \~16 GiB |
| Embedding 8B | W8A8 | GPTQModifier (GPTQ) | 60-120 min | \~30 GiB |
| Reranker 8B | W8A8 | GPTQModifier (GPTQ) | 60-120 min | \~30 GiB |

## Memory Budget

### Current (BF16, dual-instance, 5 GiB CPU offload each)

| Component | Per Instance | Both |
|-----------|-------------|------|
| Weights on GPU | 10.3-11.5 GiB | 21.8 GiB |
| Weights offloaded (CPU) | 5.0 GiB | 10.0 GiB |
| ViT FP32 overhead | 1.2 GiB | 2.4 GiB |
| KV Cache (FP8 E5M2) | 7.0 GiB | 14.0 GiB |
| Framework | 2.0 GiB | 4.0 GiB |
| **Total VRAM** | **\~21.6 GiB** | **\~43.2 GiB** |
| **Free VRAM buffer** | — | **\~4.8 GiB** |
| **Free for Lemonade** | — | **\~4.8 GiB** |

### Target (INT8 W8A16, reduced GPU util)

| Component | Per Instance | Both |
|-----------|-------------|------|
| Weights on GPU (INT8) | \~4.9 GiB | \~9.8 GiB |
| Weights offloaded (CPU) | \~5.6 GiB | \~11.2 GiB |
| ViT FP32 overhead | 1.2 GiB | 2.4 GiB |
| KV Cache | \~0 | \~0 |
| Framework | 2.0 GiB | 4.0 GiB |
| Allocator overhead, temp buffers | \~2.5 GiB | \~5.0 GiB |
| **Total VRAM (measured)** | **\~10.6 GiB** | **\~21.2 GiB** |
| **Free for Lemonade** | — | **\~26.8 GiB (VRAM) + \~25 GiB (GTT)** |

### Memory Savings Summary

| | BF16 Current | W8A16+AITER (measured) | Savings |
|---|-------------|------------------------|---------|
| vLLM total VRAM | \~43.2 GiB | \~21.2 GiB | **\~22 GiB** |
| Available for Lemonade | \~4.8 GiB | \~51.8 GiB (VRAM+GTT) | **+47 GiB** |

\~45+ GiB (VRAM + GTT) enables Lemonade with 128k context for 35B model
(running live, triple-backend build):
- Model weights: \~21.7 GiB
- KV Cache Q8: \~16 GiB
- Buffer: \~3 GiB
- Total: \~41 GiB ← fits comfortably

## Performance Benchmarks

**Embedding** (single 32k query):

| Config | Cold Start | Warm Mean | Warm Min |
|--------|-----------|-----------|----------|
| BF16 / 0 GiB offload | 21.4s | 0.51s | 0.49s |
| BF16 / 2 GiB offload | 21.7s | 0.51s | 0.50s |
| BF16 / 5 GiB offload | 22.0s | 0.51s | 0.50s |
| BF16 / 8 GiB offload | 22.3s | 0.52s | 0.50s |
| W8A16 / 0 GiB offload | 33.6s | 0.56s | 0.54s |
| W8A16 / 2 GiB offload | 33.7s | 0.57s | 0.55s |
| W8A16 / 5 GiB offload | 34.2s | 0.57s | 0.56s |
| W8A16 / 8 GiB offload | 34.4s | 0.59s | 0.55s |
| W8A16+AITER / 5 GiB offload | \~973s* | **0.16s** | 0.16s |

\* First start includes JIT kernel compilation (\~16 min). Subsequent starts
use cached kernels from `~/.triton/cache/`.

**Reranker** (5 docs × \~6k tokens ≈ 32k total):

| Config | Cold Start | Warm Mean | Warm Min |
|--------|-----------|-----------|----------|
| BF16 / 0 GiB offload | 65.3s | 4.14s | 1.47s |
| BF16 / 2 GiB offload | 65.8s | 1.69s | 1.46s |
| BF16 / 5 GiB offload | 66.2s | 1.72s | 1.46s |
| BF16 / 8 GiB offload | 66.9s | 1.73s | 1.46s |
| W8A16 / 0 GiB offload | 88.7s | 1.78s | 1.50s |
| W8A16 / 2 GiB offload | 89.0s | 1.51s | 1.49s |
| W8A16 / 5 GiB offload | 89.7s | 1.77s | 1.50s |
| W8A16 / 8 GiB offload | 90.3s | 1.67s | 1.51s |
| W8A16+AITER / 5 GiB offload | —* | **0.178s** | 0.166s |

**Key findings**:
1. W8A16 embed warm: 0.56s — 10% slower than BF16 (0.51s), due to INT8→BF16 dequantize
2. W8A16+AITER embed warm: **0.16s** — **3.5× faster** than without AITER, **3.2× faster** than BF16
3. W8A16+AITER rerank warm: **0.178s** — **8.5× faster** than without AITER
4. CPU offload: Negligible impact on warm latency (\~0.01s per 3 GiB added)
5. AITER first start: \~973s (\~16 min) JIT compilation; cached in `~/.triton/cache/`
6. Offload sweetspot: Any value 0–8 GiB works equally well; choose offload based on VRAM budget

## AITER Unlock

vLLM's AITER (AI Tensor Engine for ROCm) kernels are gated behind
`on_gfx9()` in `vllm/platforms/rocm.py`. This restricts AITER to
gfx94x/gfx95x (CDNA3/4) datacenter GPUs only. Three one-line changes enable
AITER for gfx1151 (BUILD-FIXES #35). This unlocks:

- `AiterInt8ScaledMMLinearKernel` — fused INT8 GEMM (replaces Triton fallback)
- `ROCM_AITER_FA` — AITER Flash Attention for ViT
- `ROCM_AITER_MLA` / `ROCM_AITER_UNIFIED_ATTN` — unified attention backends
- AITER RMSNorm, fused MoE, shared experts

**Validated for Embedding + Reranker (W8A16)**:
- Embedding: 3.5× warm latency improvement (0.56s → 0.16s)
- Reranker: 8.5× warm latency improvement (1.51s → 0.178s)
- Ranking accuracy preserved: 5/5 matches, Spearman ρ = 1.0
- Determinism preserved: CosSim = 1.00000000 (embed), 1.00000000 (rerank)

**ViT vs Decoder Attention Dispatch**:

| Component | Backend | Reason |
|-----------|---------|--------|
| ViT (visual encoder) | `TRITON_ATTN` | CK `fmha_fwd` crashes on gfx1151; ViT falls back via `on_gfx9()` gate (BUILD-FIXES #36) |
| Decoder (text) | `ROCM_ATTN` | Uses `on_gfx1x()` patched gate; standard ROCm flash attention |
| RMSNorm | **AITER** (JIT-compiled for gfx1151) | `module_rmsnorm` compiled via hipcc+ninja targeting `-target-cpu gfx1151` |
| Linear layers | **AITER** `AiterInt8ScaledMMLinearKernel` | W8A16 dequant+GEMM via AITER optimized path |

**Required Patches** (all auto-applied via BUILD-FIXES):
1. AITER Gate — `_aiter_ops.py`: `on_mi3xx() or on_gfx1x()` (BUILD-FIXES #35)
2. AITER FA Attention — `rocm_aiter_fa.py`: `on_mi3xx() or on_gfx1x()` (BUILD-FIXES #35)
3. FP4 Import Fix — `_aiter_ops.py`: `on_gfx950()` → `on_gfx9()` (BUILD-FIXES #97)

**AITER JIT Observations**:
- `rmsnorm2d_fwd_with_add` type hints overridden by AITER at runtime (logged as "type hints mismatch, override to -->")
- `hipcc+ninja` targets `-target-cpu gfx1151` with `oclc_isa_version_1151.bc`

**Risk**: AITER kernels for gfx1151 may not be fully validated. Test with
`VLLM_ROCM_USE_AITER=1 VLLM_ROCM_USE_AITER_LINEAR=1` and monitor for
correctness (not just speed).

**Alternative**: Set `VLLM_ROCM_USE_AITER=0` to force clean Triton fallback
without AITER involvement.

**Source**: Perplexity (three one-line patches), Gemini (AITER gfx1151
compatibility confirmed), local build analysis

### AITER PR #1498 (ROCm)

A draft PR adds gfx11xx targets to AITER. Once merged into TheRock nightly,
the `on_gfx9()` patch becomes unnecessary.

## Known Risks and Mitigations

### hipBLASLt Performance Regression

ROCm issue #4566: hipBLASLt shows severe FP32 degradation on gfx1151 (up to
89.69% vs FP16). Our TheRock build includes gfx1151 TensileLibrary kernels
and extop support (`extop_gfx1151.co`), which may mitigate this (BUILD-FIXES #62).

**Mitigation**: Set `TORCH_BLAS_PREFER_HIPBLASLT=1` for FP16/BF16 paths.
Monitor with `rocprof` for unexpected FP32 dispatch.

### `--enforce-eager` on UMA

Gemini identifies `--enforce-eager` as an anti-pattern on UMA architectures,
claiming it caps throughput at \~17 tok/s by preventing HIP Graph Capture from
hiding `hipMemcpyWithStream` latency (95% of decode time on UMA).

**However**: `--enforce-eager` is **mandatory** on gfx1151 regardless of AITER
or cpu-offload settings. vLLM V1 + torch.compile crashes on gfx1151 with
`Cannot access data pointer of Tensor (FakeTensor)`. Root cause: ROCm custom
kernels (flash attention, etc.) cannot be traced by TorchDynamo. AITER does NOT
fix this (BUILD-FIXES #38, #40). AITER compensates by providing fused kernels
as an alternative optimization path.

**Mitigation**: Keep `--enforce-eager` at all times. AITER provides equivalent
performance gains through fused kernels (3.5× embed, 8.5× rerank speedup).

### MES 0x86 Firmware Requirement

ROCm issue #6165: Silent hard hang under sustained vLLM inference on gfx1151.
Requires Linux firmware tag >= 20260410 with MES version 0x86 to resolve 0x83
page-fault class errors.

**Mitigation**: Verify firmware version before testing. Workaround:
`VLLM_LOGGING_LEVEL=DEBUG` throttles execution sufficiently to prevent hangs.

### hipMemcpyWithStream Latency

PyTorch issue #171687: On UMA architectures, \~90-95% of decode-phase time is
consumed by `hipMemcpyWithStream` operations due to legacy discrete-PCIe
memory assumptions in PyTorch/vLLM allocators.

The HSA BusyWaitSignal fix (BUILD-FIXES #101) resolves the idle-CPU aspect of
this, but the per-forward `hipMemcpyWithStream` latency remains. HIP Graph
Capture (disabled by `--enforce-eager`) is the primary throughput fix.
AITER unlock may also help by reducing kernel dispatch overhead.

## Build Stack Notes

### Our TheRock Build vs. Standard ROCm

| Component | Standard ROCm | Our TheRock Build |
|-----------|--------------|-------------------|
| hipBLASLt | "Unsupported architecture" on gfx1151 | **gfx1151 TensileLibrary + extop kernels present** |
| FP8 support | Unclear for gfx1151 | **`supports_fp8()` returns True** (E5M2 KV cache) |
| `compressed-tensors` | Listed in `supported_quantization` | Same |
| AITER | `on_gfx9()` only | **Patched + validated** (3.5× embed, 8.5× rerank speedup) |
| HIP runtime | Package-managed | Self-built (TheRock nightly) |
| Compiler | System clang | **amdclang 23.0** (TheRock-built, gfx1151 target) |

The TheRock build has gfx1151-specific hipBLASLt kernels that standard ROCm
packages lack. This invalidates many "gfx1151 unsupported" assumptions in the
research reports.

### vLLM Version

```
Commit: 719735d6c (BUILD-FIXES reference)
supported_quantization: ["awq", "gptq", "fp8", "compressed-tensors",
    "fbgemm_fp8", "gguf", "quark", "mxfp4", "petit_nvfp4", "torchao",
    "bitsandbytes"]
supports_fp8(): True for ["gfx94", "gfx95", "gfx12", "gfx1100", "gfx1151"]
```

## References

### vLLM

| Ref | Description | URL |
|-----|-------------|-----|
| PR #39939 | INT8 WMMA Triton attention for gfx1100-gfx1153 | github.com/vllm-project/vllm (draft, not merged) |
| PR #110845 | Asymmetric INT8 for TritonInt8ScaledMMLinearKernel | github.com/vllm-project/vllm |
| PR #38455 | RDNA 3.5/4 device ID mapping (gfx1151) | github.com/vllm-project/vllm (merged Apr 2026) |
| Issue #32180 | Performance bottlenecks on gfx1151 | github.com/vllm-project/vllm |
| Issue #37472 | V1 engine hangs on encoder cache profiling (VL models) | github.com/vllm-project/vllm |

### ROCm

| Ref | Description | URL |
|-----|-------------|-----|
| Issue #6165 | Silent hard hang, MES 0x86 fix | github.com/ROCm/ROCm |
| Issue #6157 | FP8 GPU crashes on Radeon 8060S | github.com/ROCm/ROCm |
| Issue #4566 | hipBLASLt performance regression on gfx1151 | github.com/ROCm/ROCm |
| Issue #5643 | hipBLASLt "unsupported arch" on gfx1151 | github.com/ROCm/ROCm |
| AITER PR #1498 | gfx11xx targets for AITER | github.com/ROCm/aiter (draft) |

### Triton

| Ref | Description | URL |
|-----|-------------|-----|
| Issue #5669 | tl.dot INT8 x INT8 broken | github.com/triton-lang/triton |

### HuggingFace

| Ref | Description |
|-----|-------------|
| `collin-park/Qwen3-VL-Embedding-8B-W8A8` | W8A8 INT8, compressed-tensors, \~10.5 GiB |
| `RamManavalan/Qwen3-VL-Embedding-8B-FP8` | FP8 E4M3 (unusable on gfx1151, BUILD-FIXES #92/#93) |
| `Forturne/Qwen3-VL-Reranker-8B-FP8` | FP8 E4M3 (unusable on gfx1151) |

### Research Sources

| Source | Key Contributions |
|--------|-------------------|
| Perplexity Deep Research | AITER on_gfx9() bypass, PR #39939 status, VL encoder hang, W8A8 17% slower than FP16 on gfx1100 |
| Claude Deep Research | ConchLinearKernel W4A16-only finding, W8A16 recommendation, AOTriton 0.10b gfx1151 support |
| Gemini Deep Research | TritonInt8ScaledMMLinearKernel operational path, block-size constraints, Triton 3.6.0 casting bug, --enforce-eager anti-pattern |