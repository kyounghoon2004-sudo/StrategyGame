#!/usr/bin/env bash
# Eval server (2026-10-19): Qwen3.5-9B FP8 + two LoRAs on :8010: the baseline v3b_536 and the teacher-SFT adapter (tsft1).
set -u
export PYTHONUNBUFFERED=1
export TRITON_PTXAS_BLACKWELL_PATH=/opt/brain_vllm/venv/lib/python3.12/site-packages/triton/backends/nvidia/bin/ptxas
export VLLM_USE_FLASHINFER_SAMPLER=0
W="/mnt/d/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1"
TS="${1:-$W/synth_adv_v1/sft_teacher_v1/run1}"
exec /opt/brain_vllm/venv/bin/vllm serve /mnt/d/StrategyAI/models/Qwen3.5-9B \
  --served-model-name q35 --host 127.0.0.1 --port 8010 \
  --language-model-only --attention-backend TRITON_ATTN \
  --quantization fp8 --kv-cache-dtype fp8 --max-model-len 65536 --max-num-seqs 8 \
  --reasoning-parser qwen3 --gpu-memory-utilization 0.90 \
  --enable-lora --max-lora-rank 32 --max-loras 2 --max-cpu-loras 2 --lora-modules \
  "v3b_536=$W/sft_mix_v3b/adapters/ckpt_step536" "tsft1=$TS" > "$W/synth_adv_v1/sft_teacher_v1/vllm_eval.log" 2>&1
