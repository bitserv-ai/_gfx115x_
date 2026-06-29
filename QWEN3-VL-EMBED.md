<!-- Copyright 2026 bitserv-ai -->
<!-- SPDX-License-Identifier: MIT -->

# Qwen3-VL Embedding & Reranking on AMD Strix Halo (gfx1151)

Production deployment notes for multimodal embedding and reranking inference
on ROCm/gfx1151. Covers BF16 baseline and INT8 W8A16 quantized deployments.

## Model Details

| Property | Embedding | Reranker |
|----------|-----------|----------|
| BF16 Model Checkpoint | Qwen/Qwen3-VL-Embedding-8B | Qwen/Qwen3-VL-Reranker-8B |
| W8A16 Model Checkpoint | bitserv-ai/Qwen3-VL-Embedding-8B-W8A16 | bitserv-ai/Qwen3-VL-Reranker-8B-W8A16 |
| Architecture | Qwen3VLForConditionalGeneration | Qwen3VLForConditionalGeneration |
| Parameters | 8B (36 layers) | 8B (36 layers) |
| Context Length | 32K (configured: 32768) | 32K (configured: 32768) |
| Embedding Dim | 4096 (supports 64–4096 via Matryoshka) | N/A (classification) |
| Input Modalities | Text, images, screenshots, video, mixed | Text, images, screenshots, video, mixed |
| Checkpoint Size (BF16) | 16 GiB | 17 GiB |
| Checkpoint Size (W8A16) | 9.9 GiB | 9.9 GiB |

## vLLM Runtime Adaptations

Qwen3-VL is a conditional generation model. vLLM applies three runtime
adaptations to support embedding and reranking workloads.

### ViT FP32 Enforcement

<!-- REPLACED: ViT FP32 root cause analysis, GELU-tanh overflow detail, benchmark table, patch file reference → BUILD-FIXES #89 -->

The ViT encoder runs in FP32 on gfx1151 to prevent NaN from GELU-tanh
overflow in BF16/FP16 (auto-applied via BUILD-FIXES #89). Overhead is
\~10–15% on multimodal requests, 0% on text-only.

### Pooler Injection (Embedding)

The architecture has **no native pooler**. vLLM injects
`DispatchPooler.for_embedding` (LAST-token pooling + L2 normalization),
equivalent to the official `Qwen3VLEmbedder._pooling_last()` method.

**Required CLI flags**: `--runner pooling --convert embed`

Without `--convert embed`, the model outputs raw hidden states instead of
proper normalized embeddings.

### Classification Head Injection (Reranker)

The Reranker checkpoint uses the same `Qwen3VLForConditionalGeneration`
architecture — it has no classification head. `vllm-start.sh` passes
`--hf-overrides` to inject `Qwen3VLForSequenceClassification`, which
adds a token-classification head reading `"no"` / `"yes"` logits:

```bash
--hf-overrides '{"architectures":["Qwen3VLForSequenceClassification"],
  "classifier_from_token":["no","yes"],
  "is_original_qwen3_reranker":true}'
```

Without this override, the Reranker does not produce relevance scores.
Configured via `VLLM_QWEN3_RERANK_W8A16_HF_OVERRIDES` in `.env`.

## vLLM Server Configuration

### .env

```bash
VLLM_MODEL_HOME="<adjust-to-local-path>"

# =============================================================================
# Role: qwen3_embed (BF16 Baseline — for quality comparison only)
# =============================================================================
VLLM_QWEN3_EMBED_MODEL="${VLLM_MODEL_HOME}/Qwen3-VL-Embedding-8B"
VLLM_QWEN3_EMBED_PORT=8102
VLLM_QWEN3_EMBED_DEVICE="rocm"
VLLM_QWEN3_EMBED_RUNNER="pooling"
VLLM_QWEN3_EMBED_CONVERT="embed"
VLLM_QWEN3_EMBED_MAX_MODEL_LEN=32768
VLLM_QWEN3_EMBED_GPU_MEMORY_MB=22118
VLLM_QWEN3_EMBED_CPU_OFFLOAD_GB=5
VLLM_QWEN3_EMBED_ENFORCE_EAGER=true
VLLM_QWEN3_EMBED_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'

# =============================================================================
# Role: qwen3_rerank (BF16 Baseline — for quality comparison only)
# =============================================================================
VLLM_QWEN3_RERANK_MODEL="${VLLM_MODEL_HOME}/Qwen3-VL-Reranker-8B"
VLLM_QWEN3_RERANK_PORT=8103
VLLM_QWEN3_RERANK_DEVICE="rocm"
VLLM_QWEN3_RERANK_RUNNER="pooling"
VLLM_QWEN3_RERANK_MAX_MODEL_LEN=32768
VLLM_QWEN3_RERANK_GPU_MEMORY_MB=22118
VLLM_QWEN3_RERANK_CPU_OFFLOAD_GB=5
VLLM_QWEN3_RERANK_ENFORCE_EAGER=true
VLLM_QWEN3_RERANK_HF_OVERRIDES='{"architectures":["Qwen3VLForSequenceClassification"],"classifier_from_token":["no","yes"],"is_original_qwen3_reranker":true}'
VLLM_QWEN3_RERANK_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'

# =============================================================================
# Role: qwen3_embed_w8a8 (Reference W8A8 — for comparison only)
# =============================================================================
VLLM_QWEN3_EMBED_W8A8_MODEL="${VLLM_MODEL_HOME}/Qwen3-VL-Embedding-8B-W8A8"
VLLM_QWEN3_EMBED_W8A8_PORT=8102
VLLM_QWEN3_EMBED_W8A8_DEVICE="rocm"
VLLM_QWEN3_EMBED_W8A8_RUNNER="pooling"
VLLM_QWEN3_EMBED_W8A8_CONVERT="embed"
VLLM_QWEN3_EMBED_W8A8_QUANTIZATION="compressed-tensors"
VLLM_QWEN3_EMBED_W8A8_MAX_MODEL_LEN=32768
VLLM_QWEN3_EMBED_W8A8_GPU_MEMORY_MB=12000
VLLM_QWEN3_EMBED_W8A8_CPU_OFFLOAD_GB=5
VLLM_QWEN3_EMBED_W8A8_ENFORCE_EAGER=true
VLLM_QWEN3_EMBED_W8A8_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'

# =============================================================================
# Role: qwen3_embed_w8a16 (Multimodal Embedding — W8A16 Production)
# =============================================================================
VLLM_QWEN3_EMBED_W8A16_MODEL="${VLLM_MODEL_HOME}/Qwen3-VL-Embedding-8B-W8A16"
VLLM_QWEN3_EMBED_W8A16_PORT=8102
VLLM_QWEN3_EMBED_W8A16_DEVICE="rocm"
VLLM_QWEN3_EMBED_W8A16_RUNNER="pooling"
VLLM_QWEN3_EMBED_W8A16_CONVERT="embed"
VLLM_QWEN3_EMBED_W8A16_QUANTIZATION="compressed-tensors"
VLLM_QWEN3_EMBED_W8A16_MAX_MODEL_LEN=32768
VLLM_QWEN3_EMBED_W8A16_GPU_MEMORY_MB=12000
VLLM_QWEN3_EMBED_W8A16_CPU_OFFLOAD_GB=5
VLLM_QWEN3_EMBED_W8A16_ENFORCE_EAGER=true
VLLM_QWEN3_EMBED_W8A16_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'

# =============================================================================
# Role: qwen3_rerank_w8a16 (Multimodal Reranker — W8A16 Production)
# =============================================================================
VLLM_QWEN3_RERANK_W8A16_MODEL="${VLLM_MODEL_HOME}/Qwen3-VL-Reranker-8B-W8A16"
VLLM_QWEN3_RERANK_W8A16_PORT=8103
VLLM_QWEN3_RERANK_W8A16_DEVICE="rocm"
VLLM_QWEN3_RERANK_W8A16_RUNNER="pooling"
VLLM_QWEN3_RERANK_W8A16_MAX_MODEL_LEN=32768
VLLM_QWEN3_RERANK_W8A16_GPU_MEMORY_MB=12000
VLLM_QWEN3_RERANK_W8A16_CPU_OFFLOAD_GB=5
VLLM_QWEN3_RERANK_W8A16_ENFORCE_EAGER=true
VLLM_QWEN3_RERANK_W8A16_HF_OVERRIDES='{"architectures":["Qwen3VLForSequenceClassification"],"classifier_from_token":["no","yes"],"is_original_qwen3_reranker":true}'
VLLM_QWEN3_RERANK_W8A16_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'

# =============================================================================
# Global Settings — Production: dual W8A16 instances
# =============================================================================
VLLM_ROLES="qwen3_embed_w8a16 qwen3_rerank_w8a16"
VLLM_HOST="0.0.0.0"
VLLM_STARTUP_TIMEOUT=1200
# AITER: 3.5x embed speedup validated (0.56s → 0.16s). First start compiles
# JIT kernels for ~16 min (cached in ~/.triton/cache/ thereafter).
VLLM_ROCM_USE_AITER=1
# Reduce PyTorch thread pool size (default: ~80 per instance). 8 threads
# sufficient for single-user inference; halves thread count (240→126 per EC)
# with no performance impact — only reduces scheduler/RSS overhead.
OMP_NUM_THREADS=8
```

### Startup

```bash
cd /opt/src/vllm/_gfx115x_
./vllm-start.sh
```

### Memory Breakdown (W8A16 + AITER, dual-instance)

#### Per Instance

| Metric | Value |
|--------|-------|
| Model weights (W8A16) | \~9.9 GiB |
| Weights on GPU | \~4.9 GiB |
| ViT FP32 additional overhead | \~1.2 GiB |
| KV Cache (reserved) | \~0 (negligible at 0.244 util) |
| Framework overhead | \~2.0 GiB |
| Other (KV reservation, etc.) | \~2.5 GiB |
| **Total VRAM per instance** | **\~10.6 GiB** |
| **GPU memory budget** | **12.0 GiB** (0.244 × 49152 MB) |
| **Headroom** | **\~1.5 GiB** |
| GPU Memory Util | 0.244 (12000/49152 MB) |

#### Combined (Both Instances)

| Metric | Value |
|--------|-------|
| **Total VRAM used** | **\~21.2 GiB** (measured) |
| **Total CPU/UMA used** | **\~10.0 GiB** |
| **Free VRAM buffer** | **\~26.8 GiB** (for Lemonade or other models) |
| **30-min burn test** | 8344 requests (0 errors, VRAM delta: +0.000 GiB) |

### Runtime Notes

- Startup Time (cached): \~30s (AITER kernels cached)
- Startup Time (first AITER): \~16 min (JIT kernel compilation)
- Warm latency (embed): **0.16s** (AITER) / 0.56s (no AITER)
- Warm latency (rerank, 5 docs): **0.18s** (AITER) / 1.51s (no AITER)
- Concurrent pipeline: **0.32s** (embed+rerank parallel)

### JIT Compilation

**BF16 — MIOpen (ViT forward pass)**:

The first ViT forward pass triggers MIOpen JIT compilation for gfx1151,
taking \~5 minutes. Subsequent calls are fast (\~45s for ViT in offline mode).
The HTTP API returns after full processing — clients should set appropriate
timeouts (≥300s for first request).

**INT8/W8A16 — AITER (server start)**:

AITER kernels JIT-compile via `hipcc+ninja` on first server start (\~16 min for
Embedding, additional time for Reranker if different architecture). Compiled
kernels are cached and reused on subsequent starts.

**Cache paths**:
- `~/.triton/cache/` — Triton-compiled kernels (`.hsaco` for gfx1151,
  `.amdgcn`, `.llir`, `.ttir`, `.ttgir`). \~7 MiB after Embed+Rerank warmup.
- `~/.cache/vllm/` — vLLM model info + torch_compile_cache (\~466 MiB).

**When to clear cache**:
- AITER version update (pip/conda update) — kernel hashes change
- Triton version update — IR/LLIR format may change
- ROCm/TheRock version change — hsaco binary compatibility
- Strange crashes or silent correctness regressions after an update

**How to clear**:
```bash
rm -rf ~/.triton/cache/   # AITER + Triton kernels (7 MiB)
rm -rf ~/.cache/vllm/     # vLLM model info + compile cache (466 MiB)
# Restart vLLM to trigger re-compilation (~16 min first start)
```

**Cold start** (first start after cache clear): \~15–17 min total (Embed only), \~20–25 min (Embed+Rerank).
**Warm start** (cached kernels): \~30–60s (same as without AITER).

### Eager Execution Mandatory

`--enforce-eager` cannot be removed, even with AITER enabled. vLLM V1 +
torch.compile crashes on gfx1151 with `Cannot access data pointer of Tensor
(FakeTensor)`. Root cause: ROCm custom kernels (flash attention, etc.) cannot
be traced by TorchDynamo. AITER does NOT fix this. `--enforce-eager` is
**mandatory** on gfx1151 regardless of AITER or cpu-offload settings.

### Image Token Budget at 32K Context

Qwen3-VL: patch_size=16, spatial_merge_size=2 → 1024 pixels per visual token.

| Image Size | Pixels | Visual Tokens | Fits in 32K? |
|------------|--------|--------------|---------------|
| Default max (\~1 MP) | \~1,000,000 | \~1,100 | Yes (3%) |
| 2K (2048×2048) | 4,194,304 | \~4,100 | Yes (13%) |
| 4K (3840×2160) | 8,294,400 | \~8,100 | Yes (25%) |
| 8K (7680×4320) | 33,177,600 | \~32,400 | Marginal (100%) |

At 32K context, 4K images fit comfortably with room for text. The model's
built-in auto-resize caps at \~1 MP by default, so most images consume only
\~1,100 tokens.

## HTTP API Reference

### Supported Endpoints

| Endpoint | Style | Multimodal | Notes |
|----------|-------|-----------|-------|
| `/v1/embeddings` | Completion | No | `input: str \| [int]` — text only |
| `/v1/embeddings` | Chat | **Yes** | `messages: [{role, content}]` — multimodal |
| `/pooling` | Chat | **Yes** | Same as chat-style embeddings |
| `/v2/embed` | Cohere | **Yes** | `images: [url]` or `inputs: [{content}]` |

### Text-only (completion-style, simplest)

```json
POST /v1/embeddings
{
  "model": "Qwen3-VL-Embedding-8B",
  "input": "A woman playing with her dog on a beach at sunset."
}
```

### Multimodal: Image + Text (chat-style)

```json
POST /v1/embeddings
{
  "model": "Qwen3-VL-Embedding-8B",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "image_url", "image_url": {"url": "https://example.com/photo.jpg"}},
        {"type": "text", "text": "a woman and a dog"}
      ]
    }
  ]
}
```

### Multimodal: Image-only (chat-style)

```json
POST /v1/embeddings
{
  "model": "Qwen3-VL-Embedding-8B",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "image_url", "image_url": {"url": "https://example.com/photo.jpg"}}
      ]
    }
  ]
}
```

### Text with Instruction (chat-style)

```json
POST /v1/embeddings
{
  "model": "Qwen3-VL-Embedding-8B",
  "messages": [
    {
      "role": "system",
      "content": [{"type": "text", "text": "Retrieve relevant documents for the query."}]
    },
    {
      "role": "user",
      "content": [{"type": "text", "text": "A woman playing with her dog on a beach."}]
    }
  ]
}
```

### Cohere-style: Image (simplest for images)

```json
POST /v2/embed
{
  "model": "Qwen3-VL-Embedding-8B",
  "images": ["https://example.com/photo.jpg"],
  "embedding_types": ["float"]
}
```

### Cohere-style: Mixed text + image

```json
POST /v2/embed
{
  "model": "Qwen3-VL-Embedding-8B",
  "inputs": [
    {
      "content": [
        {"type": "text", "text": "a woman and a dog"},
        {"type": "image_url", "image_url": {"url": "https://example.com/photo.jpg"}}
      ]
    }
  ],
  "embedding_types": ["float"]
}
```

### Cohere-style: Text-only

```json
POST /v2/embed
{
  "model": "Qwen3-VL-Embedding-8B",
  "texts": ["A woman playing with her dog on a beach at sunset."],
  "embedding_types": ["float"]
}
```

### /pooling endpoint

```json
POST /pooling
{
  "model": "Qwen3-VL-Embedding-8B",
  "task": "embed",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "image_url", "image_url": {"url": "https://example.com/photo.jpg"}},
        {"type": "text", "text": "a woman and a dog"}
      ]
    }
  ]
}
```

### API Endpoint Verification Results

All eight API endpoint combinations were tested with a consistent scenario
("a woman playing with her dog on a beach at sunset") across different
modality inputs (text-only, image+text, image-only, text+instruction).
The table shows cosine similarity against the text-only baseline — lower
values reflect cross-modal distance, not quality loss.

| API | Format | Mods | Cosine Sim vs. Text Baseline |
|-----|--------|------|------------------------------|
| `/v1/embeddings` | completion | text | 1.0000 |
| `/v1/embeddings` | chat | img+text | 0.30 |
| `/v1/embeddings` | chat | image | 0.19 |
| `/v1/embeddings` | chat (instr) | text+sys | 0.38 |
| `/pooling` | chat | img+text | 0.30 |
| `/v2/embed` | Cohere images | image | 0.19 |
| `/v2/embed` | Cohere inputs | img+text | 0.23 |
| `/v2/embed` | Cohere texts | text | 1.00 |

Semantic plausibility check: Image+Text vs. Text+Instruction (both
describing a woman with a dog on a beach) = **0.51** — related but distinct
modalities as expected.

### Known Limitations

#### `input_type` not supported (Cohere endpoint)

The `/v2/embed` endpoint rejects `input_type` (e.g., `search_document`,
`search_query`). Qwen3-VL-Embedding does not define task instructions in its
`config.json`. Omit `input_type` from Cohere requests.

#### Old completion-style `input` array does not support images

```json
// WRONG — this produces validation errors
{
  "input": [
    {"type": "image_url", "image_url": {"url": "..."}},
    {"type": "text", "text": "..."}
  ]
}
```

The `input` field only accepts `str`, `list[str]`, `list[int]`, or
`list[list[int]]`. For multimodal, use the `messages` format (chat-style) or
the Cohere `images`/`inputs` format.

## Memory Tuning & Alternative Configurations

The target system has **48 GiB GPU VRAM** (BIOS carveout, allocatable via
`hipMalloc`) and **96 GiB DDR5** (48 GiB UMA framebuffer + 48 GiB system RAM).
vLLM uses ROCm/`hipMalloc` which can only allocate from the 48 GiB carveout;
the \~25 GiB GTT pool is kernel-managed and not accessible.

vLLM allocates **all** GPU memory at startup — there is no "optimistic" or
dynamic mode that frees unused memory at runtime. The KV cache is fully
pre-allocated based on `gpu_memory_utilization`, and PagedAttention does not
release blocks back to the OS when idle.

This means a server tuned for maximum throughput (0.93 utilization) wastes
\~16-17 GiB on unused KV cache capacity when serving short-sequence embedding
requests. The goal was to find a configuration that runs both Embed+Reranker
and leaves enough free VRAM to co-host Lemonade (GGUF inference).

The following parameter variations were tested. The winner (W8A16+AITER)
became the Production Environment documented above.

### BF16 Baseline (dual-instance, 32K)

```bash
--gpu-memory-utilization 0.45       # 22118 MiB each
--kv-cache-dtype fp8_e5m2           # Halves KV cache (E5M2 required on gfx1151; E4M3 crashes)
--cpu-offload-gb 5                  # UVA zero-copy weight offload
--max-model-len 32768               # Full 32K context
--enforce-eager                      # Required for cpu-offload on V1
--limit-mm-per-prompt '{"video": 0, "image": 1}'  # Disable video (BUILD-FIXES #91)
```

| Component | Per Instance (GiB) | Total (GiB) |
|-----------|-------------------|-------------|
| Model weights (BF16) | \~15.3 (embed) / \~16.5 (rerank) | — |
| Weights offloaded (CPU/UMA) | 5.0 | 10.0 |
| Weights on GPU | \~10.3 (embed) / \~11.5 (rerank) | 21.8 |
| ViT FP32 additional overhead | 1.2 | 2.4 |
| KV Cache (FP8, reserved) | 7.0 | 14.0 |
| Framework overhead | 2.0 | 4.0 |
| **Total VRAM** | **\~20.5–21.6** | **\~41.0–43.2** |
| **Free VRAM buffer** | — | **\~4.8 GiB** |

- FP8 KV per token: 72 KB
- KV capacity @ 32K ctx: \~3 concurrent sequences
- KV capacity @ 1K (embed): \~70+ concurrent sequences
- Startup Time: \~4-6 min (MIOpen JIT + cpu-offload)
- Video Input: **Disabled** — `--limit-mm-per-prompt video=0`

**Result**: Functional but only \~4.8 GiB free — insufficient for co-hosting
Lemonade or other models.

### Solo Embedding (max throughput, 8K)

```bash
--gpu-memory-utilization 0.93
--kv-cache-dtype auto               # BF16 default
--max-model-len 8192
--enforce-eager
```

| Component | VRAM |
|-----------|------|
| Model weights | \~15.3 GiB |
| ViT FP32 | \~1.2 GiB |
| KV cache (BF16, full budget) | \~22.5 GiB |
| Framework | \~2 GiB |
| **Total vLLM** | **\~41-43 GiB** |
| **Free for Lemonade** | **\~7-8 GiB** (unusable) |

**Result**: Maximum throughput for a single model, but no room for Lemonade
or a second model instance.

### W8A16+AITER (dual-instance, 32K)

```bash
--quantization compressed-tensors    # Enable INT8 weight loading
--gpu-memory-utilization 0.244       # ~12000 MiB each
--cpu-offload-gb 5
--max-model-len 32768
--enforce-eager
--limit-mm-per-prompt '{"video": 0, "image": 1}'
# AITER: VLLM_ROCM_USE_AITER=1 (global env)
# Embed only: --runner pooling --convert embed
# Rerank only: --runner pooling --hf-overrides {...}
```

**Result**: \~21.2 GiB total, **\~26.8 GiB free** for Lemonade. 3.5× embed
speedup, 8.5× rerank speedup via AITER. 30-min burn test: 8344 requests,
0 errors, VRAM delta +0.000 GiB.

→ **Adopted as Production Environment** (see Memory Breakdown above).

### Available Optimizations

| # | Option | Description | Savings | Used in | Risk |
|---|--------|-------------|---------|---------|------|
| 1 | `--gpu-memory-utilization` | Reduce VRAM budget; embeddings need little KV cache | varies | BF16 (0.45), Solo (0.93), W8A16 (0.244) | Low — embedding sequences are short |
| 2 | `--kv-cache-dtype fp8_e5m2` | Store KV cache in FP8 instead of BF16 (halves KV cache size) | \~4-5 GiB | BF16 | Required on gfx1151; E4M3 crashes. Incompatible with compressed-tensors (INT8). |
| 3 | `--kv-offloading-size 4 --kv-offloading-backend native` | Move inactive KV blocks to CPU RAM | \~4 GiB | — | Re-activation latency on idle |
| 4 | `--cpu-offload-gb 5` | Offload model weights to CPU via UVA zero-copy | \~5 GiB | BF16, W8A16 | Higher per-forward latency |
| 5 | `--max-model-len` | Reduce max context → smaller KV cache reservation | varies | BF16 (32K), Solo (8K), W8A16 (32K) | Shorter max context |
| 6 | `--enforce-eager` | Disables torch.compile (TorchDynamo cannot trace ROCm custom kernels) | 0 (mandatory) | all | None — mandatory on gfx1151 |

### FP8 E5M2 KV Cache

On gfx1151 (RDNA 3+), `--kv-cache-dtype fp8_e5m2` is required for FP8 KV cache.
`fp8_e4m3` crashes because Triton cannot compile `float8_e4m3fn` atoms on RDNA 3+.
The E5M2 patch (BUILD-FIXES #92, #93) adds the missing C++ dispatch and conversion
functions in `amd/quant_utils.cuh` and corrects `fp8_dtype()` in `rocm.py`.

The ROCm attention backends (`rocm_aiter_fa.py`, `rocm_aiter_unified_attn.py`,
`triton_attn.py`) all include `is_fp8_kv_cache` handling with dynamic
quantization scales.

| `cache_dtype` | KV Size | ROCm Support | Notes |
|---------------|---------|---------------|-------|
| `auto` (= BF16) | 1× | Yes | Default |
| `fp8_e4m3` | 0.5× | **No (gfx1151)** | Triton cannot compile `float8_e4m3fn` on RDNA 3+ |
| `fp8_e5m2` | 0.5× | **Yes (with patch)** | Required on gfx1151 — auto-applied via BUILD-FIXES #92, #93 |
| `fp8_ds_mla` | 0.5× | **No** | DeepSeek MLA architecture only |

For embedding workloads, FP8 KV cache quality impact is negligible — the model
outputs a single vector after pooling, not token-level logits.

**Incompatibility**: FP8 E5M2 KV cache is **incompatible** with
`compressed-tensors` checkpoints (both W8A8 and W8A16). vLLM raises
`ValueError: fp8_e5m2 kv-cache is not supported with fp8 checkpoints`.
For pooling/reranker models this has zero practical impact — single forward pass,
no autoregressive KV-cache buildup.

### What Does NOT Work

- **Dynamic/optimistic allocation**: vLLM has no runtime memory release.
  All KV cache blocks are pre-allocated at startup.
- **`VLLM_ROCM_SHUFFLE_KV_CACHE_LAYOUT`**: Requires AITER
  (`VLLM_ROCM_USE_AITER=1`). Not validated on gfx1151. Shuffle is a
  performance optimization, not a memory optimization.
- **GTT as VRAM extension**: `hipMalloc` can only allocate from the 48 GiB
  BIOS carveout. The GTT pool (\~25 GiB) is kernel-managed and not accessible
  via `hipMalloc`. Vulkan/RADV can use GTT, but vLLM/ROCm cannot.
- **W8A8 quantization (compressed-tensors)**: Weight-only INT8 quantization
  produces unacceptably low embedding quality (ρ≈0.6 vs. BF16 baseline).
  Use W8A16 instead.
- **FP8 E4M3 quantization**: Triton cannot compile `float8_e4m3fn` atoms on
  RDNA 3+. Pre-quantized FP8 checkpoints (RamManavalan, Forturne) are unusable.
- **GPTQModifier as RTN shortcut**: `GPTQModifier` always computes Hessians
  regardless of scheme. Use `QuantizationModifier` for true RTN (no calibration).
- **`device_map="cpu"` with llmcompressor**: `QuantizationModifier` uses
  `DataFreePipeline` which calls `dispatch_model()` internally — this requires
  a visible device via `get_device_memory()`. On CPU-only systems,
  `get_device_memory()` returns an empty dict and crashes. The
  `quantize_w8a16.py` script monkey-patches `get_device_memory()` to inject
  CPU memory as a device entry.
