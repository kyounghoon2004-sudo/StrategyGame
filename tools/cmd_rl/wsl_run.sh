#!/usr/bin/env bash
# run the trainer in the WSL training venv: wsl_run.sh <args...>
cd "/mnt/d/Game development/Demon slayer/StrategyGame"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
T=/opt/brain_moe/venv/lib/python3.12/site-packages/triton/backends/nvidia/bin/ptxas
[ -x "$T" ] || T=/opt/brain_vllm/venv/lib/python3.12/site-packages/triton/backends/nvidia/bin/ptxas
export TRITON_PTXAS_BLACKWELL_PATH=$T TRITON_PTXAS_PATH=$T
exec /opt/brain_moe/venv/bin/python -X faulthandler -u tools/cmd_rl/train_wsl.py "$@"
