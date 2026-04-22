<!-- Copyright 2026 Blackcat Informatics Inc. -->
<!-- SPDX-License-Identifier: MIT -->

# Qwen3-VL-Embedding-8B on AMD Strix Halo (gfx1151)

Production deployment notes for multimodal embedding inference on ROCm/gfx1151.

## Model Details

| Property | Value |
|----------|-------|
| Architecture | Qwen3VLForConditionalGeneration |
| Parameters | 8B (36 layers) |
| Context Length | 32K (configured: 32768) |
| Embedding Dim | 4096 (supports 64–4096 via Matryoshka) |
| Input Modalities | Text, images, screenshots, video, mixed |
| Model Path | `/mnt/Windows/vllm/Qwen3-VL-Embedding-8B` |

## Critical: ViT NaN on gfx1151

The ViT encoder produces **100% NaN** in `last_hidden_state` when running in
BF16 or FP16 on AMD gfx1151 (Radeon 8060S). Root cause: GELU with tanh
approximation overflows in BF16/FP16 on ROCm.

**Fix**: Wrap `self.visual = Qwen3_VisionTransformer(...)` initialization in
`set_default_torch_dtype(torch.float32)`. ViT parameters are created in FP32,
weights are preserved in FP32 via `copy_()`, and outputs are seamlessly cast
back to BF16 at the multimodal merge point
(`_merge_multimodal_embeddings` → `mm_embeds_flat.to(dtype=input_dtype)`).

This pattern already exists in vLLM for `deepseek_vl2.py` and `minicpmv.py`
(FP16-init for ViT).

| ViT dtype | Result | Forward time |
|-----------|--------|-------------|
| BF16 | 100% NaN | ~293s |
| FP16 | 100% NaN | ~84s |
| FP32 | OK | ~45s |

FP32 ViT is faster because BF16/FP16 times include NaN-propagation overhead.
The ViT is ~7% of total parameters (590M/8B), so the net FP32 overhead is
~10-15% on multimodal requests, 0% on text-only.

**Patch file**: `patches/qwen3vl-vit-fp32.patch`
**Build integration**: YAML patch #31 + build script patch #32

## Pooler Architecture

`Qwen3VLForConditionalGeneration` has **no native pooler**. vLLM's
`as_embedding_model()` injects a `DispatchPooler.for_embedding` with:

- LAST-token pooling
- L2 normalization

This is equivalent to the official `Qwen3VLEmbedder._pooling_last()` method.

**Required CLI flags**: `--runner pooling --convert embed`

Without `--convert embed`, the model outputs raw hidden states instead of
proper normalized embeddings.

## vLLM Server Configuration

### .env

```bash
VLLM_ROLES="qwen3_embed qwen3_rerank"

# Embed (port 8102)
VLLM_QWEN3_EMBED_MODEL="/mnt/Windows/vllm/Qwen3-VL-Embedding-8B"
VLLM_QWEN3_EMBED_PORT=8102
VLLM_QWEN3_EMBED_DEVICE="${VLLM_DEVICE_DEFAULT}"
VLLM_QWEN3_EMBED_RUNNER="pooling"
VLLM_QWEN3_EMBED_CONVERT="embed"
VLLM_QWEN3_EMBED_MAX_MODEL_LEN=32768
VLLM_QWEN3_EMBED_GPU_MEMORY_MB=22118   # 0.45 × 49152 (dual-instance)
VLLM_QWEN3_EMBED_KV_CACHE_DTYPE="fp8_e5m2"
VLLM_QWEN3_EMBED_CPU_OFFLOAD_GB=5
VLLM_QWEN3_EMBED_ENFORCE_EAGER=true
VLLM_QWEN3_EMBED_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'
# VLLM_QWEN3_EMBED_SKIP_MM_PROFILING=true  # NOT recommended for VL models

# Rerank (port 8103)
VLLM_QWEN3_RERANK_MODEL="/mnt/Windows/vllm/Qwen3-VL-Reranker-8B"
VLLM_QWEN3_RERANK_PORT=8103
VLLM_QWEN3_RERANK_DEVICE="${VLLM_DEVICE_DEFAULT}"
VLLM_QWEN3_RERANK_RUNNER="pooling"
VLLM_QWEN3_RERANK_MAX_MODEL_LEN=32768
VLLM_QWEN3_RERANK_GPU_MEMORY_MB=22118   # 0.45 × 49152 (dual-instance)
VLLM_QWEN3_RERANK_KV_CACHE_DTYPE="fp8_e5m2"
VLLM_QWEN3_RERANK_CPU_OFFLOAD_GB=5
VLLM_QWEN3_RERANK_ENFORCE_EAGER=true
VLLM_QWEN3_RERANK_HF_OVERRIDES='{"architectures":["Qwen3VLForSequenceClassification"],"classifier_from_token":["no","yes"],"is_original_qwen3_reranker":true}'
VLLM_QWEN3_RERANK_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'
# VLLM_QWEN3_RERANK_SKIP_MM_PROFILING=true  # NOT recommended for VL models
```

### Startup

```bash
cd /opt/src/vllm/_gfx115x_
scripts/vllm-start.sh   # uses setsid (not nohup) to avoid EngineCore zombie
```

### Runtime Characteristics

#### Per Instance (Embed or Reranker)

| Metric | Value |
|--------|-------|
| Model weights (BF16) | ~15.3 GiB (embed) / ~16.5 GiB (rerank) |
| Weights offloaded (CPU/UMA) | ~5.0 GiB via UVA zero-copy |
| Weights on GPU | ~10.3 GiB (embed) / ~11.5 GiB (rerank) |
| ViT FP32 overhead | ~1.2 GiB |
| KV Cache (FP8, reserved) | ~7.0 GiB |
| Framework overhead | ~2.0 GiB |
| **Total VRAM per instance** | **~21.6 GiB** |
| **GPU memory budget** | **22.1 GiB** (0.45 × 49152 MB) |
| **Headroom** | **~0.5 GiB** |
| GPU Memory Util | 0.45 (22118/49152 MB) |
| FP8 KV per token | 72 KB |
| KV capacity @ 32K ctx | ~3 concurrent sequences |
| KV capacity @ <1K (embed) | ~70+ concurrent sequences |
| Startup Time | ~4-6 min (MIOpen JIT + cpu-offload) |
| Video Input | **Disabled** — `--limit-mm-per-prompt video=0` (see below) |

#### Combined (Both Instances)

| Metric | Value |
|--------|-------|
| **Total VRAM used** | **~43.2 GiB** |
| **Total CPU/UMA used** | **~10.0 GiB** |
| **Free VRAM buffer** | **~4.8 GiB** |

Embedding workloads are short-sequence (typically <512 tokens). FP8 KV cache
at 0.45 utilization provides ~7 GiB for KV — sufficient for ~70+ concurrent
embedding requests or ~3 concurrent sequences at maximum 32K context.

## Memory Optimization for Co-Hosting

vLLM allocates **all** GPU memory at startup — there is no "optimistic" or
dynamic mode that frees unused memory at runtime. The KV cache is fully
pre-allocated based on `gpu_memory_utilization`, and PagedAttention does not
release blocks back to the OS when idle.

This means a server tuned for maximum throughput (0.93 utilization) wastes
~16-17 GiB on unused KV cache capacity when serving short-sequence embedding
requests.

### Available Optimizations

| # | Option | Description | Savings | Risk |
|---|--------|-------------|---------|------|
| 1 | `--gpu-memory-utilization 0.55` | Reduce VRAM budget; embeddings need little KV cache | ~20 GiB | Low — embedding sequences are short |
| 2 | `--kv-cache-dtype fp8_e5m2` | Store KV cache in FP8 instead of BF16 (halves KV cache size) | ~4-5 GiB | Required on gfx1151; E4M3 crashes on RDNA 3+ |
| 3 | `--kv-offloading-size 4 --kv-offloading-backend native` | Move inactive KV blocks to CPU RAM | ~4 GiB | Re-activation latency on idle |
| 4 | `--cpu-offload-gb 5` | Offload model weights to CPU via UVA zero-copy | ~5 GiB | Higher per-forward latency |
| 5 | `--max-model-len 4096` | Halve max context → halve KV cache reservation | ~4-8 GiB | Shorter max context |
| 6 | `--enforce-eager` | Already active — disables CUDA graphs, saves their memory | 0 (already on) | None |
| 7 | `VLLM_ROCM_SHUFFLE_KV_CACHE_LAYOUT=1` | **Performance only** — requires AITER, not available on gfx1151 | 0 GiB | N/A — unsupported |

### FP8 KV Cache on ROCm

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
| `fp8_e5m2` | 0.5× | **Yes (with patch)** | Required on gfx1151 — needs E5M2 patch (#92, #93) |
| `fp8_ds_mla` | 0.5× | **No** | DeepSeek MLA architecture only |

For embedding workloads, FP8 KV cache quality impact is negligible — the model
outputs a single vector after pooling, not token-level logits.

### Co-Hosting Scenarios

#### A: Dual-Instance Embed + Reranker (current, 32K)

Both models run simultaneously, each with FP8 KV cache and 5 GiB CPU offload.

```bash
# Per-instance flags (applied to both roles):
--gpu-memory-utilization 0.45       # 22118 MiB each
--kv-cache-dtype fp8_e5m2           # Halves KV cache (E5M2 required on gfx1151; E4M3 crashes)
--cpu-offload-gb 5                  # UVA zero-copy weight offload
--max-model-len 32768               # Full 32K context
--enforce-eager                      # Required for cpu-offload on V1
--limit-mm-per-prompt '{"video": 0, "image": 1}'  # Disable video (crash fix)
# IMPORTANT: Launch with setsid (not nohup) to avoid EngineCore zombie on ROCm
```

| Component | Per Instance (GiB) | Total (GiB) |
|-----------|-------------------|-------------|
| Weights on GPU | 10.3–11.5 | 21.8 |
| Weights offloaded (CPU) | 5.0 | 10.0 |
| ViT FP32 | 1.2 | 2.4 |
| KV Cache (FP8) | 7.0 | 14.0 |
| Framework | 2.0 | 4.0 |
| **Total VRAM** | **~21.6** | **~43.2** |
| **Total CPU/UMA** | **5.0** | **10.0** |
| **Free VRAM buffer** | — | **~4.8** |

#### B: Solo Embedding (single model, max throughput)

```bash
--gpu-memory-utilization 0.93
--kv-cache-dtype auto               # BF16 default
--max-model-len 8192
--enforce-eager
```

| Component | VRAM |
|-----------|------|
| Model weights | ~15.3 GiB |
| ViT FP32 | ~1.2 GiB |
| KV cache (BF16, full budget) | ~22.5 GiB |
| Framework | ~2 GiB |
| **Total vLLM** | **~41-43 GiB** |
| **Free for Lemonade** | **~7-8 GiB** (unusable) |

### What Does NOT Work

- **Dynamic/optimistic allocation**: vLLM has no runtime memory release.
  All KV cache blocks are pre-allocated at startup.
- **`VLLM_ROCM_SHUFFLE_KV_CACHE_LAYOUT`**: Requires AITER
  (`VLLM_ROCM_USE_AITER=1`), which is not enabled on gfx1151. Shuffle is a
  performance optimization, not a memory optimization.
- **`--kv-cache-dtype fp8_e4m3`**: Triton cannot compile `float8_e4m3fn` atoms on
  RDNA 3+ (gfx1151). Use `fp8_e5m2` instead (requires E5M2 patch, BUILD-FIXES #92/#93).
- **`--kv-cache-dtype fp8_ds_mla`**: Only for DeepSeek MLA architectures.
- **GTT as VRAM extension**: `hipMalloc` can only allocate from the 48 GiB
  BIOS carveout. The GTT pool (~25 GiB) is kernel-managed and not accessible
  via `hipMalloc`. Vulkan/RADV can use GTT, but vLLM/ROCm cannot.

### Image Token Budget at 32K Context

Qwen3-VL: patch_size=16, spatial_merge_size=2 → 1024 pixels per visual token.

| Image Size | Pixels | Visual Tokens | Fits in 32K? |
|------------|--------|--------------|---------------|
| Default max (~1 MP) | ~1,000,000 | ~1,100 | Yes (3%) |
| 2K (2048×2048) | 4,194,304 | ~4,100 | Yes (13%) |
| 4K (3840×2160) | 8,294,400 | ~8,100 | Yes (25%) |
| 8K (7680×4320) | 33,177,600 | ~32,400 | Marginal (100%) |

At 32K context, 4K images fit comfortably with room for text. The model's
built-in auto-resize caps at ~1 MP by default, so most images consume only
~1,100 tokens.

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

## Encoder-Cache Profiling Crash (Video Fix)

### Symptom

Both Embed and Reranker instances crash during startup at the encoder-cache
profiling step:

```
Encoder cache will be initialized with a budget of 12288 tokens,
and profiled with 1 video items of the maximum feature size.
```

The EngineCore becomes a zombie (`ZN`, `<defunct>`) while the APIServer
remains sleeping. VRAM is **not released** (16.2 GiB leaked). No health check
ever passes.

### Root Cause

Qwen3VL defines `DUMMY_VIDEO_NUM_FRAMES = 2048` in vLLM's model code.
During startup profiling, vLLM runs a full ViT forward pass with 2048 video
frames at maximum resolution to determine the encoder cache budget. On
gfx1151 with only ~22 GiB VRAM per instance (dual-instance setup), this
memory spike exceeds available VRAM and crashes the EngineCore.

The profiling path in `gpu_model_runner.py:5757-5788` performs:
1. `mm_budget.get_modality_with_max_tokens()` → selects `"video"` (highest token count)
2. `_get_mm_dummy_batch("video", 1)` → generates 2048-frame dummy video
3. `model.embed_multimodal(**inputs)` → full ViT forward pass → **OOM crash**

Video is the **maximum-token modality** by far: 2048 frames × temporal compression
produces ~12288 visual tokens, versus ~1100 tokens for a single image.

### Fix: `--limit-mm-per-prompt '{"video": 0, "image": 1}'`

Setting `video: 0` removes video from `tower_modalities` in
`encoder_budget.py:73-77` — the video modality is never profiled and never
included in the encoder cache budget. Only image (with `image: 1`) is profiled,
which uses ~1100 tokens instead of ~12288.

This is the **correct** approach because:
- Embedding/reranking use cases don't need video input
- Video profiling at 2048 frames is the **most memory-intensive** operation in vLLM startup
- Image-only profiling uses the much smaller ViT forward pass (~1 GiB vs ~12+ GiB)
- The alternative (`--skip-mm-profiling`) would skip ALL MM profiling including images

### Alternative Considered: `--skip-mm-profiling`

This flag skips multimodal profiling entirely. While it avoids the video crash,
it also skips image profiling, which means vLLM cannot properly size the
encoder cache for image inputs. **Not recommended** for multimodal models.

```bash
# NOT RECOMMENDED — disables image encoder cache too
--skip-mm-profiling
```

### Implementation

Added per-role `LIMIT_MM_PER_PROMPT` in `.env`:

```bash
VLLM_QWEN3_EMBED_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'
VLLM_QWEN3_RERANK_LIMIT_MM_PER_PROMPT='{"video": 0, "image": 1}'
```

Added `--limit-mm-per-prompt` CLI flag support in `vllm-start.sh`.

### Startup Log (After Fix)

Expected log output should show image-only profiling:
```
Encoder cache will be initialized with a budget of N tokens,
and profiled with 1 image items of the maximum feature size.
```

Instead of the crash-inducing:
```
... 1 video items of the maximum feature size.
```

## V1 EngineCore Zombie on ROCm/gfx1151

### Symptom

When vLLM V1 is launched via `nohup ... &` in the background, the EngineCore
subprocess becomes a zombie (`<defunct>`). The APIServer stays alive but never
responds to health checks. VRAM is leaked (no release from the zombie process).

`ps aux` shows:
```
bosadm  12345  0.0  0.0      0     0 ?        Z    <date>   0:00 [python] <defunct>
```

### Root Cause

vLLM V1 launches the EngineCore via `multiprocessing.Process` using Python's
forkserver start method. When the parent process runs inside a `nohup ... &`
background shell, the child process inherits a broken session state. On
ROCm/gfx1151, the HIP runtime initialization inside the forked child fails
silently — the process becomes a zombie without ever completing startup.

`nohup` detaches from the terminal but does **not** create a new session. The
parent remains in the original session's process group, causing inconsistent
session state for the forked child.

### Fix

Replace `nohup` with `setsid` in `vllm-start.sh`. `setsid` creates a new
session and process group, giving the forked EngineCore a clean session state.

```bash
# Broken:
nohup vllm serve ... > log 2>&1 &

# Fixed:
setsid vllm serve ... > log 2>&1 &
```

**Alternative**: `VLLM_ENABLE_V1_MULTIPROCESSING=0` runs EngineCore in-process,
avoiding the fork entirely. However, this loses process isolation — an
EngineCore crash kills the entire server, and there is no separate process
to monitor or restart.

### Manual Start (fish shell)

For manual/foreground startup (e.g., debugging), use:

```fish
# In-process (no fork, simpler for debugging):
env VLLM_ENABLE_V1_MULTIPROCESSING=0 vllm serve ...

# Or with setsid for multiprocessing:
setsid vllm serve ... > log 2>&1 &
```

**Do NOT use `nohup ... &`** on ROCm/gfx1151 with vLLM V1.

## V1 EngineCore 100% CPU Idle Busy-Loop

### Symptom

When vLLM V1 is running but has no active requests, each EngineCore subprocess
consumes 100% of one CPU core. For dual-instance setups (Embed + Reranker), this
wastes 2 cores permanently.

`htop` shows:
```
PID   USER   PRI  NI  VIRT   RES   SHR S  %CPU %MEM  TIME+  COMMAND
1234  bosadm  20   0  50.2g  20.1g  2.1g R  99.9  2.1   0:00   python -c ...
```

### Root Cause

The EngineCore `run_busy_loop()` calls `_process_engine_step()` every iteration.
When idle (`model_executed=False`), the existing code only sleeps if
`scheduler.has_unfinished_requests()` is true — but in the idle state this is
false, so no sleep occurs and the loop spins at full speed.

PR #29476 added `time.sleep(0.001)` but it is conditional on
`has_unfinished_requests()`, which is false when truly idle.

### Fix: Progressive Backoff in EngineCore

Patch `vllm/vllm/v1/engine/core.py` to add a progressive idle backoff:

```python
# In EngineCore.__init__:
self._idle_backoff = [0.0, 0.001, 0.010, 0.100, 0.500]  # seconds
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

| Consecutive idle steps | Sleep | CPU impact |
|------------------------|-------|------------|
| 1 | 0ms | ~100% |
| 2 | 1ms | ~50% |
| 3 | 10ms | ~10% |
| 4 | 100ms | ~1% |
| 5+ | 500ms | ~0.2% |

Reset is immediate on model execution or new request arrival.

**BUILD-FIXES:** #96  
**Auto-applied on rebuild:** Yes — patch #33 in `vllm-packages.yaml` applies
`patches/enginecore-idle-backoff.patch` idempotently via `git apply`.
**Upstream status:** Not yet fixed upstream (as of vLLM commit 719735d6c).

### Post-Fix Verification

After restart, CPU usage per EngineCore at idle should drop to <1%:
```
PID   USER   PRI  NI  VIRT   RES   SHR S  %CPU %MEM  TIME+  COMMAND
1234  bosadm  20   0  50.2g  20.1g  2.1g S   0.0  2.1   0:00   python -c ...
```

Note: `S` (sleeping) instead of `R` (running) in the `S` column.

## Known Limitations

### `input_type` not supported (Cohere endpoint)

The `/v2/embed` endpoint rejects `input_type` (e.g., `search_document`,
`search_query`). Qwen3-VL-Embedding does not define task instructions in its
`config.json`. Omit `input_type` from Cohere requests.

### Old completion-style `input` array does not support images

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

### MIOpen JIT on first request

The first ViT forward pass triggers MIOpen JIT compilation for gfx1151,
taking ~5 minutes. Subsequent calls are fast (~45s for ViT in offline mode).
The HTTP API returns after full processing — clients should set appropriate
timeouts (≥300s for first request).

## Verification Results

All eight API combinations tested and verified:

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

## Offline SDK (Reference)

For batch processing or when the HTTP API is not needed, the vLLM offline SDK
is available. See `test_embed_offline.py` for a working example that produced
correct multimodal similarity scores:

- Q1→Doc1 (text): 0.74
- Q1→Doc2 (image): 0.65
- Q1→Doc3 (text+image): 0.62
- Q4→Doc1-3: 0.06/-0.02/0.02 (unrelated, correctly low)