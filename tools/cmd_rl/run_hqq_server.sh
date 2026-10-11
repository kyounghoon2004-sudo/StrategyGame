#!/usr/bin/env bash
# HQQ 27B server (replaces vLLM for the 2-bit test). Args passed to hqq_server.py.
cd "/mnt/d/Game development/Demon slayer/StrategyGame"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
T=/opt/brain_moe/venv/lib/python3.12/site-packages/triton/backends/nvidia/bin/ptxas
[ -x "$T" ] || T=/opt/brain_vllm/venv/lib/python3.12/site-packages/triton/backends/nvidia/bin/ptxas
export TRITON_PTXAS_BLACKWELL_PATH=$T TRITON_PTXAS_PATH=$T
exec /opt/brain_moe/venv/bin/python -u tools/cmd_rl/hqq_server.py "$@" > "/mnt/d/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1/hqq_eval/hqq_server.log" 2>&1
