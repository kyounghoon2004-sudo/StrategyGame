"""BRAIN_VLLM_PHASE1 — engine bring-up proof (FP8 base + LoRA on sm_120).

  python -m tools.brain_vllm.smoke [--adapter <dir>] [--quant fp8]

1. Start the vLLM engine (or reuse it) with the configured gpu_memory_utilization cap.
2. Copy + register the adapter as a dynamic LoRA.
3. Run ONE real DEV opening prompt (rendered on Windows with G) through
   POST /v1/completions with locked sampling + return_token_ids, and print the
   raw completion, timings and token ids.
Writes artifacts/brain_pipeline_v1/vllm/smoke.json (or smoke_error.json with the
engine log tail on failure). No HF weights are ever touched.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.brain_vllm import common as C  # noqa: E402

VLLM_DIR = ROOT / "artifacts" / "brain_pipeline_v1" / "vllm"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", default=str(ROOT / "artifacts" / "contextual_brain_s0b" / "candidate_S0B"))
    ap.add_argument("--gpu-mem-gb", type=float, default=C.GPU_MEM_GB_DEFAULT)
    a = ap.parse_args()
    from tools.contract_sft import gpu_common as G
    tok = G.load_tokenizer()
    prompts_open = json.loads((VLLM_DIR / "parity" / "prompts_open.json").read_text(encoding="utf-8"))
    msgs = next(p for p in prompts_open if p["corpus"] == "s0b")["messages"]
    out = {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "adapter": a.adapter}
    t0 = time.time()
    try:
        e = C.engine_start(a.gpu_mem_gb, wait_s=1800, log=print)
        out["engine"] = e
        out["engine_start_wall_s"] = round(time.time() - t0, 1)
        r = C.load_lora_into_engine(a.adapter, current_lora=None, log=print)
        out["lora"] = {"name": r["lora_name"], "sha": r["sha"], "load_s": r["load_s"], "wsl_dir": r["wsl_dir"]}
        p = tok(G.render_prompt(tok, msgs), add_special_tokens=False)["input_ids"]
        payload = {"model": r["lora_name"], "prompt": p, "max_tokens": int(G.SAMPLING["max_new_tokens"]),
                   "temperature": float(G.SAMPLING["temperature"]), "top_p": float(G.SAMPLING["top_p"]),
                   "top_k": int(G.SAMPLING["top_k"]), "repetition_penalty": 1.0, "return_token_ids": True}
        t1 = time.time()
        code, body = C.http_json(C.ENGINE_URL + "/v1/completions", payload, method="POST", timeout=1800)
        dt = time.time() - t1
        out["completion_http"] = code
        if code == 200 and isinstance(body, dict):
            ch = body["choices"][0]
            ids = ch.get("token_ids")
            out["completion"] = {"text": ch.get("text", ""), "finish_reason": ch.get("finish_reason"),
                                 "n_ids": len(ids) if ids is not None else None,
                                 "return_token_ids": ids is not None, "wall_s": round(dt, 2),
                                 "tokens_per_s": round(len(ids) / dt, 1) if ids else None,
                                 "usage": body.get("usage")}
            out["ok"] = ids is not None
        else:
            out["ok"] = False
            out["error"] = str(body)[:1000]
    except Exception as e:  # noqa: BLE001
        out["ok"] = False
        out["error"] = f"{type(e).__name__}: {e}"
        try:
            ls = C.wsl("ls -t /opt/brain_vllm/logs/vllm_*.log | head -1", timeout=60, check=False)
            latest = (getattr(ls, "out_text", "") or "").strip().splitlines()
            if latest:
                tail = C.wsl(f"tail -n 60 {latest[-1]}", timeout=60, check=False)
                out["engine_log_tail"] = getattr(tail, "out_text", "")[-6000:]
        except Exception:  # noqa: BLE001
            pass
    (VLLM_DIR / ("smoke.json" if out.get("ok") else "smoke_error.json")).write_text(
        json.dumps(out, indent=1), encoding="utf-8")
    print(json.dumps(out, indent=1)[:4000])
    return 0 if out.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
