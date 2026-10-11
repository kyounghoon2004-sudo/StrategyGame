"""BRAIN_VLLM_PHASE1 — vLLM-backed equivalent of tools.contract_sft.generate.

Identical procedure/format: same prompts (rendered with G.render_prompt on the
Windows side), same job order, same batch composition, same per-batch seed
recorded, locked sampling, RAW decoded completion (no strip, no repair).
Rows match tools.contract_sft.generate field for field; values that belong to
the vLLM backend (load_s = engine/adapter load observed this run) are recorded
as measured. Completions carry the exact sampled token ids from the engine
(return_token_ids); the terminal EOS is included like the HF path.

  python -m tools.brain_vllm.generate --adapter <dir|""> --label T0086 \
     --jobs <jobs.json> --out <gen.json> [--batch-size 8] [--gpu-mem-gb 13.5]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.brain_vllm import common as C  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", default="")
    ap.add_argument("--label", required=True)
    ap.add_argument("--jobs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--gpu-mem-gb", type=float, default=C.GPU_MEM_GB_DEFAULT)
    ap.add_argument("--engine-url", default=C.ENGINE_URL)
    args = ap.parse_args()

    from tools.contract_sft import gpu_common as G
    out = Path(args.out)
    log = G.make_logger(out.with_suffix(".log"))
    jobs = json.loads(Path(args.jobs).read_text(encoding="utf-8"))
    log(f"[GEN:vllm] label={args.label} adapter={args.adapter or '(base)'} jobs={len(jobs)} "
        f"batch={args.batch_size} sampling={G.SAMPLING} engine={args.engine_url}")
    done = {}
    if out.exists():  # resumable: keep finished rows
        for r in json.loads(out.read_text(encoding="utf-8"))["rows"]:
            done[r["job_id"]] = r
        log(f"[GEN:vllm] resume: {len(done)} rows already present")

    tok = G.load_tokenizer()
    e = C.engine_start(args.gpu_mem_gb, log=log)
    lora = None
    adapter_sha = None
    adapter_load_s = 0.0
    if args.adapter:
        r = C.load_lora_into_engine(args.adapter, current_lora=None, log=log)
        lora, adapter_sha, adapter_load_s = r["lora_name"], r["sha"], r["load_s"]
    load_s = round((e.get("load_s") or 0.0) + (adapter_load_s or 0.0), 1)

    # whole-GPU memory sampler
    peak = {"gib": 0.0}
    stop = threading.Event()

    def sample():
        while not stop.is_set():
            m = C.gpu_used_mib()
            if m >= 0:
                peak["gib"] = max(peak["gib"], round(m / 1024, 3))
            stop.wait(5)
    threading.Thread(target=sample, daemon=True).start()

    min_host = None
    try:
        import psutil
        min_host = round(psutil.virtual_memory().available / 2**30, 3)
    except Exception:  # noqa: BLE001
        pass

    max_new = int(G.SAMPLING["max_new_tokens"])

    def one(job: dict):
        text = G.render_prompt(tok, job["messages"])
        p = tok(text, add_special_tokens=False)["input_ids"]
        payload = {"model": lora or "rl_policy", "prompt": p, "max_tokens": max_new,
                   "temperature": float(G.SAMPLING["temperature"]), "top_p": float(G.SAMPLING["top_p"]),
                   "top_k": int(G.SAMPLING["top_k"]), "repetition_penalty": float(G.SAMPLING["repetition_penalty"]),
                   "seed": int(job.get("seed", 0)), "return_token_ids": True}
        code, body = C.http_json(args.engine_url + "/v1/completions", payload, method="POST", timeout=1800)
        if code != 200 or not isinstance(body, dict):
            raise RuntimeError(f"engine http {code}: {str(body)[:400]}")
        ch = (body.get("choices") or [{}])[0]
        ids = ch.get("token_ids")
        if ids is None:
            raise RuntimeError("engine did not return token_ids (return_token_ids unsupported)")
        ids = [int(x) for x in ids]
        finish = str(ch.get("finish_reason", ""))
        if finish == "stop" and (not ids or ids[-1] != tok.eos_token_id):
            ids = ids + [int(tok.eos_token_id)]
        n_tok = len(ids)
        ended = finish == "stop"
        return {"job_id": job["job_id"], "prompt_id": job["prompt_id"], "seed": job["seed"],
                "gen_tokens": n_tok, "text": tok.decode(ids, skip_special_tokens=True),
                "hit_token_cap": (not ended) and n_tok >= max_new}

    rows = list(done.values())
    todo = [j for j in jobs if j["job_id"] not in done]
    order = {j["job_id"]: i for i, j in enumerate(jobs)}
    bs = max(1, args.batch_size)
    batches = [jobs[i:i + bs] for i in range(0, len(jobs), bs)]
    try:
        for bi, batch in enumerate(batches):
            if all(j["job_id"] in done for j in batch):
                continue
            seed = int(batch[0]["seed"])
            tb = time.time()
            with ThreadPoolExecutor(max_workers=len(batch)) as ex:
                res = list(ex.map(one, batch))
            dt = time.time() - tb
            for j, r in zip(batch, res):
                r.update({"batch_index": bi, "batch_seed": seed, "batch_size": len(batch),
                          "batch_wall_s": round(dt, 2)})
                rows.append(r)
            rows.sort(key=lambda r: order.get(r["job_id"], 1 << 30))
            G.write_json(out, {"label": args.label, "adapter": args.adapter or None,
                               "adapter_sha256": adapter_sha, "backend": "vllm_fp8",
                               "sampling": G.SAMPLING, "batch_size": bs, "load_s": load_s,
                               "memory": {"peak_device_vram_gib": peak["gib"],
                                          "minimum_available_system_ram_gib": min_host}, "rows": rows})
            ntoks = [r["gen_tokens"] for r in res]
            log(f"[GEN:vllm] batch {bi + 1}/{len(batches)} n={len(batch)} {dt:.1f}s "
                f"max_tokens={max(ntoks)} sum_tokens={sum(ntoks)} tok/s={sum(ntoks) / dt:.1f}")
        stop.set()
        G.write_json(out, {"label": args.label, "adapter": args.adapter or None,
                           "adapter_sha256": adapter_sha, "backend": "vllm_fp8",
                           "sampling": G.SAMPLING, "batch_size": bs, "load_s": load_s,
                           "memory": {"peak_device_vram_gib": peak["gib"],
                                      "minimum_available_system_ram_gib": min_host},
                           "rows": rows, "complete": True})
    finally:
        stop.set()
    log(f"[GEN:vllm] done rows={len(rows)} peak_gpu={peak['gib']}GiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
