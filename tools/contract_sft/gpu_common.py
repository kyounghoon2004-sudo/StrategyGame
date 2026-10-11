"""Shared GPU plumbing for CONTRACT_SFT_V1 (generation + SFT).

Same model / quantization / sampling / memory-guard practice as the proven
marathon phases (tools/training_supervisor/marathon_phase_*.py):
Qwen3-8B @ pinned revision, NF4 double-quant BF16 compute, SDPA, device
guard 20.5 GiB, host-available guard 16 GiB, non-thinking chat template,
sampling temp 0.7 / top_p 0.8 / top_k 20 / rep 1.0 / 1280 new tokens.
Every GPU process holds the SAME exclusive GPU lock the marathon uses
(D:\\StrategyAI\\locks\\training_marathon_v1.lock) so the paused marathon
can never share the GPU with this gate.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

MODEL_DIR = r"D:\StrategyAI\models\Qwen3-8B"
REVISION = "b968826d9c46dd6066d109eabc6255188de91218"
SAMPLING = {"temperature": 0.7, "top_p": 0.8, "top_k": 20, "repetition_penalty": 1.0,
            "max_new_tokens": 1280, "enable_thinking": False}
DEVICE_GUARD_GIB = 23.0  # raised from 20.5 on 2026-09-30 (user-approved; 24.46 GiB card, desktop apps hold ~3 GiB)
HOST_GUARD_GIB = 16.0
LOCK_PATH = r"D:\StrategyAI\locks\training_marathon_v1.lock"
ARTIFACT_ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")


class GuardBreach(RuntimeError):
    pass


def device_used_gib() -> float:
    try:
        p = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=15)
        return round(float(p.stdout.strip().splitlines()[0]) / 1024, 3)
    except Exception:
        return -1.0


def host_avail_gib() -> float:
    try:
        import psutil
        return round(psutil.virtual_memory().available / 2**30, 3)
    except Exception:
        return -1.0


class Guard:
    def __init__(self, log: Callable[[str], None]):
        self.log = log
        self.peak_device = 0.0
        self.min_host = float("inf")
        self.snaps: List[Dict[str, Any]] = []

    def check(self, tag: str) -> None:
        d, h = device_used_gib(), host_avail_gib()
        if d >= 0:
            self.peak_device = max(self.peak_device, d)
        if h >= 0:
            self.min_host = min(self.min_host, h)
        self.snaps.append({"tag": tag, "device_gib": d, "host_avail_gib": h, "t": time.time()})
        self.log(f"[MEM:{tag}] device={d}GiB host_avail={h}GiB")
        if d >= 0 and d > DEVICE_GUARD_GIB:
            raise GuardBreach(f"device {d} GiB > {DEVICE_GUARD_GIB} at {tag}")
        if h >= 0 and h < HOST_GUARD_GIB:
            raise GuardBreach(f"host avail {h} GiB < {HOST_GUARD_GIB} at {tag}")

    def summary(self) -> Dict[str, Any]:
        return {"peak_device_vram_gib": round(self.peak_device, 3),
                "minimum_available_system_ram_gib": None if self.min_host == float("inf")
                else round(self.min_host, 3)}


def make_logger(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(path, "a", encoding="utf-8")

    def log(msg: str) -> None:
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        fh.write(line + "\n")
        fh.flush()
    return log


def gpu_lock(run_id: str, phase: str):
    sys.path.insert(0, r"D:\Game development\Demon slayer\StrategyGame")
    from tools.training_supervisor.gpu_lock import GpuLockManager
    return GpuLockManager(LOCK_PATH, run_id=run_id, phase=phase, purpose="contract_sft_v1",
                          test_only=False)


def load_tokenizer():
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(MODEL_DIR, trust_remote_code=False)
    if tok.pad_token_id is None:
        tok.pad_token_id = tok.eos_token_id
    tok.padding_side = "left"
    return tok


def render_prompt(tok, messages: List[Dict[str, str]]) -> str:
    return tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True,
                                   enable_thinking=False)


def load_base():
    import torch
    from transformers import AutoModelForCausalLM, BitsAndBytesConfig
    qconf = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                               bnb_4bit_use_double_quant=True,
                               bnb_4bit_compute_dtype=torch.bfloat16,
                               bnb_4bit_quant_storage="uint8")
    return AutoModelForCausalLM.from_pretrained(
        MODEL_DIR, revision=REVISION, trust_remote_code=False, attn_implementation="sdpa",
        quantization_config=qconf, device_map={"": 0})


def file_sha256(path: str) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(obj, indent=1, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)
