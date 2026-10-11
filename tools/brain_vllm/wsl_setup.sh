#!/usr/bin/env bash
# BRAIN_VLLM_PHASE1 — WSL provisioning (idempotent). Run as root inside the distro:
#   wsl -d Ubuntu-24.04 -u root -- bash /opt/brain_vllm/wsl_setup.sh
# Installs python tooling + vLLM (CUDA 12.9 build) + torch cu129, creates the venv,
# copies the local Qwen3-8B base model into ext4. Never downloads model weights.
# Records exact versions to VERSIONS.txt.
#
# Driver/passthrough constraint on this machine: NVIDIA 577.03 = CUDA 12.9, so we
# MUST use the vLLM +cu129 release wheel with the torch cu129 build
# (the plain PyPI wheel is linked against libcudart.so.13 and cannot load).
set -euo pipefail

VLLM_VERSION="${1:-0.30.0}"
TORCH_VERSION="2.13.0"
CUDA_VARIANT="129"
export DEBIAN_FRONTEND=noninteractive

mkdir -p /opt/brain_vllm/logs /opt/adapters /opt/models
LOG=/opt/brain_vllm/logs/setup.log
echo "[setup] $(date -Is) vllm=$VLLM_VERSION torch=$TORCH_VERSION+cu$CUDA_VARIANT" | tee -a "$LOG"

echo "[setup] apt packages" | tee -a "$LOG"
apt-get update -qq >>"$LOG" 2>&1
apt-get install -y -qq curl ca-certificates git python3-venv python3.12-dev build-essential >>"$LOG" 2>&1

# uv (standalone installer; only if missing)
if [ ! -x /root/.local/bin/uv ]; then
  echo "[setup] installing uv" | tee -a "$LOG"
  curl -LsSf https://astral.sh/uv/install.sh | sh >>"$LOG" 2>&1
fi
export PATH=/root/.local/bin:$PATH

# venv
if [ ! -x /opt/brain_vllm/venv/bin/python ]; then
  echo "[setup] creating venv" | tee -a "$LOG"
  uv venv /opt/brain_vllm/venv --python 3.12 >>"$LOG" 2>&1
fi

# vLLM +cu129 release wheel (CUDA 12.9 build; matches driver 577.03)
echo "[setup] installing vllm==$VLLM_VERSION+cu$CUDA_VARIANT (this may take a while)" | tee -a "$LOG"
uv pip install --python /opt/brain_vllm/venv/bin/python \
  "https://github.com/vllm-project/vllm/releases/download/v${VLLM_VERSION}/vllm-${VLLM_VERSION}+cu${CUDA_VARIANT}-cp38-abi3-manylinux_2_28_x86_64.whl" \
  --extra-index-url "https://download.pytorch.org/whl/cu${CUDA_VARIANT}" >>"$LOG" 2>&1

# make sure torch + torchvision + torchaudio are the cu129 builds of the pinned versions
echo "[setup] torch cu$CUDA_VARIANT pin (torch, torchvision, torchaudio)" | tee -a "$LOG"
uv pip install --python /opt/brain_vllm/venv/bin/python --index-url "https://download.pytorch.org/whl/cu${CUDA_VARIANT}" \
  --reinstall-package torch --reinstall-package torchvision --reinstall-package torchaudio \
  "torch==${TORCH_VERSION}+cu${CUDA_VARIANT}" "torchvision==0.28.0+cu${CUDA_VARIANT}" "torchaudio==2.11.0+cu${CUDA_VARIANT}" >>"$LOG" 2>&1

# base model copy (from the Windows model dir on /mnt; never downloaded)
if [ ! -f /opt/models/Qwen3-8B/model.safetensors.index.json ]; then
  echo "[setup] copying base model to ext4" | tee -a "$LOG"
  rm -rf /opt/models/Qwen3-8B.tmp
  mkdir -p /opt/models/Qwen3-8B.tmp
  cp -r "/mnt/d/StrategyAI/models/Qwen3-8B/." /opt/models/Qwen3-8B.tmp/
  mv /opt/models/Qwen3-8B.tmp /opt/models/Qwen3-8B
fi

# engine start script (canonical copy: tools/brain_vllm/run_vllm.sh in the repo)
cat > /opt/brain_vllm/run_vllm.sh <<'SH'
#!/usr/bin/env bash
# vLLM engine for the Brain (FP8 base + dynamic LoRA + sleep mode).
# gpu_memory_utilization comes from VLLM_GPU_UTIL (default 0.5651 = 13.5 GiB of 23.89 GiB).
set -u
export VLLM_ALLOW_RUNTIME_LORA_UPDATING=1
export VLLM_SERVER_DEV_MODE=1
export PYTHONUNBUFFERED=1
# HOST FIX (measured 2026-10-01): triton 3.7.1 compiles every arch >= 100
# (incl. this GPU's sm_120) with its bundled ptxas-blackwell = CUDA 13.1 ptxas;
# the resulting cubins SEGFAULT the 577.03 (CUDA 12.9) WSL driver stub inside
# cuModuleLoadData (engine dies ~11 s into torch.compile, no traceback). The
# bundled regular ptxas is CUDA 12.8, which fully supports sm_120 and produces
# driver-12.x-compatible cubins. Point the ptxas-blackwell knob at the 12.8
# binary so ALL triton cubins are CUDA 12.8 builds.
export TRITON_PTXAS_BLACKWELL_PATH=/opt/brain_vllm/venv/lib/python3.12/site-packages/triton/backends/nvidia/bin/ptxas
# HOST FIX 2 (measured 2026-10-01): flashinfer 0.6.18 ships no sm_120
# sampling cubins, so the engine JITs the FlashInfer top-k/top-p sampler on
# first use; WSL has no nvcc/CUDA toolkit, so the JIT raises RuntimeError
# (loud in DEBUG: "Could not find nvcc...") and the EngineCore dies during
# warmup. Force vLLM's torch/triton top-k/top-p sampler instead.
export VLLM_USE_FLASHINFER_SAMPLER=0
UTIL="${VLLM_GPU_UTIL:-0.5651}"
exec /opt/brain_vllm/venv/bin/vllm serve /opt/models/Qwen3-8B \
  --served-model-name rl_policy \
  --host 127.0.0.1 --port 8000 \
  --quantization fp8 \
  --kv-cache-dtype bfloat16 \
  --max-model-len 10240 \
  --enable-lora --max-lora-rank 16 --max-loras 2 --max-cpu-loras 4 \
  --enable-sleep-mode \
  --gpu-memory-utilization "$UTIL"
SH
chmod +x /opt/brain_vllm/run_vllm.sh

# versions record
{
  echo "distro: $(. /etc/os-release && echo "$NAME $VERSION")"
  echo "kernel: $(uname -r)"
  /opt/brain_vllm/venv/bin/python - <<'PY'
import importlib.metadata as md
for p in ("vllm", "torch", "transformers", "peft", "flashinfer-python", "triton"):
    try:
        print(f"{p}: {md.version(p)}")
    except Exception:
        print(f"{p}: -")
import torch
print("torch cuda:", torch.version.cuda)
print("device:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "no cuda")
print("capability:", torch.cuda.get_device_capability(0) if torch.cuda.is_available() else None)
PY
  echo "nvidia-smi (WSL pass-through):"
  nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv,noheader || true
  echo "model files: $(ls /opt/models/Qwen3-8B | wc -l)"
} > /opt/brain_vllm/VERSIONS.txt 2>&1

echo "[setup] done" | tee -a "$LOG"
cat /opt/brain_vllm/VERSIONS.txt
