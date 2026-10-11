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
