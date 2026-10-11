#!/usr/bin/env python3
"""Phase-2 real-model audit: exact in-game selection context -> Ollama.

Reads tools/.audit_phase2_ctx.json (real packages + prompt), sends both
cases with the game's generation options, writes
tools/.audit_phase2_raw.json for step7_audit_phase2_batch.gd.
"""
import json, os, sys, time
import requests

PROJ = r"D:\Game development\Demon slayer\StrategyGame"
CTX_PATH = os.path.join(PROJ, "tools", ".audit_phase2_ctx.json")
OUT_PATH = os.path.join(PROJ, "tools", ".audit_phase2_raw.json")
ENDPOINT = "http://127.0.0.1:11434/api/chat"
MODEL = "qwen38-jrell-mtp-256k:latest"

def call_one(system, tag, user_text):
    t0 = time.time()
    try:
        r = requests.post(ENDPOINT, json={
            "model": MODEL,
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": user_text}],
            "options": {"temperature": 0.2, "num_predict": 6144,
                        "num_ctx": 12288, "think": False},
            "format": "json", "stream": False,
        }, timeout=300)
        dt = (time.time() - t0) * 1000
        if r.status_code != 200:
            return {"tag": tag, "ok": False,
                    "error": "http %d" % r.status_code, "latency_ms": dt, "raw": ""}
        b = r.json()
        msg = b.get("message", {})
        return {"tag": tag, "ok": True, "latency_ms": dt,
                "raw": msg.get("content", ""),
                "thinking_len": len(msg.get("thinking") or ""),
                "done_reason": b.get("done_reason", ""),
                "eval_count": b.get("eval_count", 0)}
    except Exception as e:
        return {"tag": tag, "ok": False, "error": repr(e)[:200],
                "latency_ms": (time.time() - t0) * 1000, "raw": ""}

def main():
    ctx = json.load(open(CTX_PATH, encoding="utf-8"))
    system = ctx["select_system"]
    results = []
    for tag in ("scout_recon", "multi_advance"):
        print("Phase-2 [%s] sending..." % tag, flush=True)
        res = call_one(system, tag, ctx["cases"][tag]["user_text"])
        st = ("OK %dms think=%d eval=%d reason=%s"
              % (res.get("latency_ms", 0), res.get("thinking_len", 0),
                 res.get("eval_count", 0), res.get("done_reason", "")) if res.get("ok")
              else "ERR %s" % res.get("error", "?"))
        print("  [%s] %s" % (tag, st), flush=True)
        results.append(res)
    json.dump({"model": MODEL, "results": results}, open(OUT_PATH, "w", encoding="utf-8"),
              ensure_ascii=False)
    print("WROTE", OUT_PATH, flush=True)

if __name__ == "__main__":
    main()
