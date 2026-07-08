# Deployment

Transfer the vLLM build stack to another Linux system with the same
hardware (gfx1151). Python 3.13 is bundled — no system Python required.

## Scripts

| Script | Runs on | Purpose |
|--------|---------|---------|
| `make-deploy-tarball.sh` | Build system | Packs runtime artifacts into tarballs |
| `install-deploy.sh` | Target system | Extracts tarballs, creates venv, sets up systemd |

## Pack (Build System)

```bash
# Without ROCm (~1.3 GB total — target must have its own ROCm)
./extras/make-deploy-tarball.sh

# With TheRock ROCm runtime (~9 GB total)
./extras/make-deploy-tarball.sh --with-rocm

# Custom output directory
./extras/make-deploy-tarball.sh --output-dir /tmp/deploy
```

### Produced Tarballs

| File | Content | Size |
|------|---------|------|
| `vllm-python.tar.gz` | Python 3.13 interpreter + stdlib (self-contained) | ~330 MB |
| `vllm-wheels.tar.gz` | Python wheels (torch, vllm, triton, aiter, …) | ~750 MB |
| `vllm-llamacpp-rocm.tar.gz` | ROCm llama.cpp backend (binaries + .so) | ~150 MB |
| `vllm-llamacpp-vulkan.tar.gz` | Vulkan backend + SPIR-V shaders | ~200 MB |
| `vllm-llamacpp-cpu.tar.gz` | CPU backend | ~80 MB |
| `vllm-lemonade.tar.gz` | lemond + lemonade CLI + web app | ~110 MB |
| `vllm-config.tar.gz` | Scripts, .env template, patches, Lemonade configs | ~1 MB |
| `vllm-rocm-runtime.tar.gz` | TheRock ROCm SDK (only with `--with-rocm`) | ~7.8 GB |

Output directory: `deploy/` (or `--output-dir`).

## Install (Target System)

Transfer the entire `deploy/` folder to the target, then:

```bash
cd deploy
./install-deploy.sh

# Install with bundled ROCm runtime
./install-deploy.sh --with-rocm

# Custom install path (Python RPATH is patched via LD_LIBRARY_PATH)
./install-deploy.sh --vllm-dir /opt/src/vllm

# Override Python (use system Python instead of bundled)
./install-deploy.sh --python python3.13
```

### What It Does

1. Creates `/opt/src/vllm/` directory structure
2. Extracts Python 3.13 interpreter to `local/` (self-contained, no system Python needed)
3. Extracts ROCm runtime (if `--with-rocm`)
4. Creates Python venv, installs all wheels
5. Extracts llama.cpp backends (rocm, vulkan, cpu)
6. Extracts Lemonade server + web app
7. Installs scripts, `.env` template, patches into `_gfx115x_/`
8. Sets up Lemonade runtime config (`config.json`, `recipe_options.json`, `lemonade.env`)
9. Publishes `version.txt` to Lemonade cache (BUILD-FIXES #158)
10. Creates systemd service + override for `lemonade-server.service`
    (generates base unit file if not present — works on any Linux with systemd)
11. Runs 16 smoke checks

### Post-Install

```bash
# 1. Edit .env — set model paths
vim /opt/src/vllm/_gfx115x_/.env
#   VLLM_MODEL_HOME="/path/to/your/models"

# 2. Edit lemonade.env — set HF cache
vim ~/.config/lemonade/lemonade.env
#   HF_HUB_CACHE=/path/to/hf-cache

# 3. Start Lemonade
sudo systemctl enable --now lemonade-server

# 4. Start vLLM
/opt/src/vllm/_gfx115x_/vllm-start.sh
```

## Prerequisites (Target)

- glibc ≥ 2.34 (Ubuntu 22.04+, Debian 12+, Fedora 36+, Arch)
- AMD GPU driver (ROCm 7.x or Mesa Vulkan)
- systemd (for lemonade-server service)
- `sudo` access
- No Python required — 3.13 is bundled in `vllm-python.tar.gz`