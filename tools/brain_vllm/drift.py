"""BRAIN_VLLM_PHASE1 — drift measurement (report only, no gate).

  python -m tools.brain_vllm.drift vllm --jobs <drift_jobs.json> --out <drift_vllm.json>
  python -m tools.brain_vllm.drift hf   --jobs <drift_jobs.json> --vllm <drift_vllm.json> --out <drift_hf.json>
  python -m tools.brain_vllm.drift score --vllm <drift_vllm.json> --hf <drift_hf.json> --out <drift.json>

40 prompts, greedy decoding on both backends:
  - rate of full-completion exact match (token ids, trailing EOS normalized),
  - median first-divergence token position,
  - mean |delta log-prob| of vLLM's chosen tokens re-scored by HF (NF4).
The HF side holds the project GPU lock (G.gpu_lock) like every other HF job.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.brain_vllm import common as C  # noqa: E402

VLLM_DIR = ROOT / "artifacts" / "brain_pipeline_v1" / "vllm"


def _norm_ids(ids, eos):
    ids = list(ids)
    while ids and ids[-1] == eos:
        ids.pop()
    return ids


def cmd_vllm(a) -> int:
    from tools.contract_sft import gpu_common as G
    jobs = json.loads(Path(a.jobs).read_text(encoding="utf-8"))
    tok = G.load_tokenizer()
    e = C.engine_start(C.GPU_MEM_GB_DEFAULT, log=print)
    r = C.load_lora_into_engine(a.adapter, current_lora=None, log=print)
    out = {"jobs": [], "engine_load_s": e.get("load_s"), "adapter": a.adapter, "adapter_sha256": r["sha"]}
    for j in jobs:
        text = G.render_prompt(tok, j["messages"])
        p = tok(text, add_special_tokens=False)["input_ids"]
        payload = {"model": r["lora_name"], "prompt": p, "max_tokens": int(G.SAMPLING["max_new_tokens"]),
                   "temperature": 0.0, "top_p": 1.0, "top_k": -1, "repetition_penalty": 1.0,
                   "logprobs": 1, "return_token_ids": True}
        code, body = C.http_json(C.ENGINE_URL + "/v1/completions", payload, method="POST", timeout=1800)
        if code != 200:
            raise RuntimeError(f"engine http {code}: {str(body)[:300]}")
        ch = body["choices"][0]
        ids = [int(x) for x in ch["token_ids"]]
        lp = ch.get("logprobs") or {}
        out["jobs"].append({"job_id": j["job_id"], "prompt_ids": p, "ids": ids,
                            "logprobs": [float(x) if x is not None else None for x in (lp.get("token_logprobs") or [])],
                            "finish_reason": ch.get("finish_reason")})
        print(f"[drift:vllm] {j['job_id']} tokens={len(ids)}", flush=True)
    Path(a.out).write_text(json.dumps(out), encoding="utf-8")
    print(f"[drift:vllm] wrote {a.out}")
    return 0


def cmd_hf(a) -> int:
    import gc
    import torch
    from tools.contract_sft import gpu_common as G
    jobs = json.loads(Path(a.jobs).read_text(encoding="utf-8"))
    vllm = json.loads(Path(a.vllm).read_text(encoding="utf-8"))
    vmap = {j["job_id"]: j for j in vllm["jobs"]}
    log = G.make_logger(VLLM_DIR / "drift_hf.log")
    guard = G.Guard(log)
    out = {"jobs": []}
    with G.gpu_lock("brain_vllm_drift_hf", "PARITY_DRIFT"):
        torch.cuda.empty_cache()
        guard.check("init")
        if G.device_used_gib() > 4.0:
            raise G.GuardBreach("GPU not initially clear")
        tok = G.load_tokenizer()
        from peft import PeftModel
        base = G.load_base()
        model = PeftModel.from_pretrained(base, a.adapter)
        model.eval()
        model.config.use_cache = True
        guard.check("loaded")
        for j in jobs:
            text = G.render_prompt(tok, j["messages"])
            enc = tok(text, add_special_tokens=False, return_tensors="pt").to("cuda:0")
            t0 = time.time()
            with torch.inference_mode():
                gen = model.generate(**enc, max_new_tokens=int(G.SAMPLING["max_new_tokens"]), do_sample=False,
                                     pad_token_id=tok.pad_token_id, eos_token_id=tok.eos_token_id)
            ids = gen[0][enc["input_ids"].shape[1]:].tolist()
            row = {"job_id": j["job_id"], "ids": ids, "text": tok.decode(ids, skip_special_tokens=True),
                   "gen_s": round(time.time() - t0, 1)}
            # re-score vLLM's chosen tokens with HF (teacher forcing)
            v = vmap[j["job_id"]]
            vids = v["ids"]
            if vids:
                full = torch.tensor([v["prompt_ids"] + vids[:-1]], device="cuda:0")
                with torch.inference_mode(), torch.autocast(device_type="cuda", dtype=torch.bfloat16):
                    logits = model(input_ids=full, logits_to_keep=len(vids)).logits
                lp = torch.log_softmax(logits[0].float(), -1)
                vlogp = lp.gather(1, torch.tensor(vids, device="cuda:0")[:, None])[:, 0].tolist()
                row["hf_logprobs_of_vllm_ids"] = [round(x, 5) for x in vlogp]
                dels = [abs(hf_lp - vl) for hf_lp, vl in zip(vlogp, v["logprobs"]) if vl is not None]
                row["mean_abs_delta"] = round(statistics.mean(dels), 5) if dels else None
                del full, logits, lp
            out["jobs"].append(row)
            guard.check(f"job{len(out['jobs'])}")
            del enc, gen
            gc.collect()
            torch.cuda.empty_cache()
            log(f"[drift:hf] {j['job_id']} hf_tokens={len(ids)} vllm_tokens={len(v['ids'])} delta={row.get('mean_abs_delta')}")
        del model, base
        gc.collect()
        torch.cuda.empty_cache()
    Path(a.out).write_text(json.dumps(out), encoding="utf-8")
    print(f"[drift:hf] wrote {a.out}")
    return 0


def cmd_score(a) -> int:
    from tools.contract_sft import gpu_common as G
    tok = G.load_tokenizer()
    eos = tok.eos_token_id
    vllm = json.loads(Path(a.vllm).read_text(encoding="utf-8"))
    hf = json.loads(Path(a.hf).read_text(encoding="utf-8"))
    vmap = {j["job_id"]: j for j in vllm["jobs"]}
    exact, first_div, deltas = [], [], []
    for j in hf["jobs"]:
        v = vmap[j["job_id"]]
        va, ha = _norm_ids(v["ids"], eos), _norm_ids(j["ids"], eos)
        same = va == ha
        exact.append(same)
        if same:
            first_div.append(min(len(va), len(ha)))
        else:
            pos = next(i for i, (x, y) in enumerate(zip(va, ha)) if x != y) if va and ha else 0
            if len(va) != len(ha) and va[:min(len(va), len(ha))] == ha[:min(len(va), len(ha))]:
                pos = min(len(va), len(ha))
            first_div.append(pos)
        if j.get("mean_abs_delta") is not None:
            deltas.append(j["mean_abs_delta"])
    res = {"n_prompts": len(hf["jobs"]),
           "exact_match_rate": round(sum(exact) / len(exact), 4),
           "median_first_divergence_token": statistics.median(first_div) if first_div else None,
           "mean_abs_delta_logprob": round(statistics.mean(deltas), 5) if deltas else None,
           "note": "report only, no gate; vLLM greedy vs HF(NF4)-greedy, HF re-scores vLLM's chosen tokens",
           "vllm_adapter_sha256": vllm.get("adapter_sha256"), "generated": time.strftime("%Y-%m-%dT%H:%M:%S")}
    Path(a.out).write_text(json.dumps(res, indent=1), encoding="utf-8")
    print(json.dumps(res, indent=1))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("vllm")
    v.add_argument("--jobs", required=True)
    v.add_argument("--adapter", required=True)
    v.add_argument("--out", required=True)
    h = sub.add_parser("hf")
    h.add_argument("--jobs", required=True)
    h.add_argument("--vllm", required=True)
    h.add_argument("--adapter", default=str(ROOT / "artifacts" / "contextual_brain_s0b" / "candidate_S0B"))
    h.add_argument("--out", required=True)
    s = sub.add_parser("score")
    s.add_argument("--vllm", required=True)
    s.add_argument("--hf", required=True)
    s.add_argument("--out", default=str(VLLM_DIR / "drift.json"))
    a = ap.parse_args()
    {"vllm": cmd_vllm, "hf": cmd_hf, "score": cmd_score}[a.cmd](a)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
