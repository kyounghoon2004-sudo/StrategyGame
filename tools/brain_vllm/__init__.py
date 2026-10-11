"""BRAIN_VLLM_PHASE1 tools package (Phase 1: vLLM accelerator for the Brain).

Drop-in replacement for `tools.contextual_brain.rl_vs_utility serve`:
  - a Windows-side shim (service.py) on 127.0.0.1:8096 that renders prompts with
    tools.contract_sft.gpu_common (byte-identical tokenization) and forwards
    TOKEN IDS to a vLLM engine running in WSL (FP8 base + LoRA adapter),
  - a batch generator (generate.py) matching tools.contract_sft.generate's output,
  - a client (client.py) used by the orchestrator: start/load_adapter/sleep/wake/stop/health,
  - WSL setup / engine start scripts and the Phase 1 evaluation harnesses.

Nothing here trains, edits weights, or touches sealed probe material.
"""
