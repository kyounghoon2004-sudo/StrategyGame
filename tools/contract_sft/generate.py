"""Batched raw generation for CONTRACT_SFT_V1 (fresh process; exits when done).

Identical procedure for every model compared: same prompts, same order,
same batch composition, same per-batch seed, locked sampling. Output is
the RAW decoded completion (no strip, no repair).

  python -m tools.contract_sft.generate --adapter <dir|""> --label T0086
     --jobs <jobs.json> --out <gen.json> [--batch-size 8]

jobs.json: [{"job_id", "prompt_id", "messages", "seed"}] -- grouped into
batches in file order; a batch's seed is the seed of its first job.
Latency mode (--batch-size 1) measures production-like single-call latency.
"""
from __future__ import annotations

import argparse
import gc
import json
import os
import time
from pathlib import Path

from tools.contract_sft import gpu_common as G


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", default="")
    ap.add_argument("--label", required=True)
    ap.add_argument("--jobs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--batch-size", type=int, default=8)
    args = ap.parse_args()
    out = Path(args.out)
    log = G.make_logger(out.with_suffix(".log"))
    jobs = json.loads(Path(args.jobs).read_text(encoding="utf-8"))
    log(f"[GEN] label={args.label} adapter={args.adapter or '(base)'} jobs={len(jobs)} "
        f"batch={args.batch_size} sampling={G.SAMPLING}")
    done = {}
    if out.exists():  # resumable: keep finished rows
        for r in json.loads(out.read_text(encoding="utf-8"))["rows"]:
            done[r["job_id"]] = r
        log(f"[GEN] resume: {len(done)} rows already present")

    import torch
    guard = G.Guard(log)
    with G.gpu_lock(f"contract_sft_gen_{args.label}", "SFT_GEN"):
        torch.cuda.empty_cache()
        guard.check("init")
        if G.device_used_gib() > 4.0:
            raise G.GuardBreach("GPU not initially clear")
        tok = G.load_tokenizer()
        t0 = time.time()
        base = G.load_base()
        model = base
        if args.adapter:
            from peft import PeftModel
            assert (Path(args.adapter) / "adapter_model.safetensors").exists(), args.adapter
            model = PeftModel.from_pretrained(base, args.adapter)
        model.eval()
        model.config.use_cache = True
        load_s = round(time.time() - t0, 1)
        log(f"[GEN] model loaded in {load_s}s")
        guard.check("loaded")
        rows = list(done.values())
        todo = [j for j in jobs if j["job_id"] not in done]
        order = {j["job_id"]: i for i, j in enumerate(jobs)}
        bs = max(1, args.batch_size)
        # Batches are formed over the FULL job list so composition is
        # identical across models and across resumes.
        batches = [jobs[i:i + bs] for i in range(0, len(jobs), bs)]
        for bi, batch in enumerate(batches):
            if all(j["job_id"] in done for j in batch):
                continue
            texts = [G.render_prompt(tok, j["messages"]) for j in batch]
            enc = tok(texts, add_special_tokens=False, return_tensors="pt", padding=True)
            enc = {k: v.to("cuda:0") for k, v in enc.items()}
            seed = int(batch[0]["seed"])
            torch.manual_seed(seed)
            torch.cuda.manual_seed_all(seed)
            tb = time.time()
            with torch.inference_mode():
                gen = model.generate(**enc, max_new_tokens=G.SAMPLING["max_new_tokens"], do_sample=True,
                                     temperature=G.SAMPLING["temperature"], top_p=G.SAMPLING["top_p"],
                                     top_k=G.SAMPLING["top_k"],
                                     repetition_penalty=G.SAMPLING["repetition_penalty"],
                                     pad_token_id=tok.pad_token_id, eos_token_id=tok.eos_token_id)
            dt = time.time() - tb
            plen = enc["input_ids"].shape[1]
            for k, j in enumerate(batch):
                ids = gen[k][plen:].tolist()
                n_tok = len(ids)
                while n_tok and ids[n_tok - 1] == tok.pad_token_id:
                    n_tok -= 1
                ended = n_tok < len(ids) or (n_tok and ids[n_tok - 1] == tok.eos_token_id)
                text = tok.decode(ids[:n_tok], skip_special_tokens=True)
                rows.append({"job_id": j["job_id"], "prompt_id": j["prompt_id"], "seed": j["seed"],
                             "batch_index": bi, "batch_seed": seed, "batch_size": len(batch),
                             "text": text, "gen_tokens": n_tok,
                             "hit_token_cap": (not ended) and n_tok >= G.SAMPLING["max_new_tokens"],
                             "batch_wall_s": round(dt, 2)})
            rows.sort(key=lambda r: order.get(r["job_id"], 1 << 30))
            G.write_json(out, {"label": args.label, "adapter": args.adapter or None,
                               "adapter_sha256": G.file_sha256(os.path.join(
                                   args.adapter, "adapter_model.safetensors")) if args.adapter else None,
                               "sampling": G.SAMPLING, "batch_size": bs, "load_s": load_s,
                               "memory": guard.summary(), "rows": rows})
            ntoks = [r["gen_tokens"] for r in rows if r["batch_index"] == bi]
            log(f"[GEN] batch {bi + 1}/{len(batches)} n={len(batch)} {dt:.1f}s "
                f"max_tokens={max(ntoks)} sum_tokens={sum(ntoks)} tok/s={sum(ntoks) / dt:.1f}")
            guard.check(f"batch{bi + 1}")
            del gen, enc
            gc.collect()
            torch.cuda.empty_cache()
        G.write_json(out, {"label": args.label, "adapter": args.adapter or None,
                           "adapter_sha256": G.file_sha256(os.path.join(
                               args.adapter, "adapter_model.safetensors")) if args.adapter else None,
                           "sampling": G.SAMPLING, "batch_size": bs, "load_s": load_s,
                           "memory": guard.summary(), "rows": rows, "complete": True})
        del model, base
        gc.collect()
        torch.cuda.empty_cache()
    log(f"[GEN] done rows={len(rows)} memory={guard.summary()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
