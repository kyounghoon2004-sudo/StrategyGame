"""Does a code-computed FACTS block let the thinking-OFF model answer correctly? (cold items, no games)"""
import json, re, sys, urllib.request, concurrent.futures as cf
from tools.ckpt_sweep.items import make_cold, dist, nbrs
URL = "http://127.0.0.1:8010/v1/chat/completions"

def facts(it):
    gt = it["truth"]; hq = tuple(gt["hq"]); occ = {tuple(x) for x in gt["occupied"]}
    ring = nbrs(hq)
    lines = ["FACTS (computed by the game, exact):"]
    lines.append("- Hexes touching the enemy HQ: %d occupied, %d free%s." % (
        sum(1 for h in ring if h in occ), sum(1 for h in ring if h not in occ),
        (" (free: %s)" % ", ".join("(%d,%d)" % h for h in ring if h not in occ)) if any(h not in occ for h in ring) else " - melee units cannot reach the HQ"))
    for k, v in gt["my_units"].items():
        d = dist(tuple(v), hq)
        kind = re.sub(r"\d+$", "", k)
        extra = ""
        if kind == "archers":
            extra = " -> CAN shoot the HQ now (range 2-3)" if 2 <= d <= 3 else " -> too far to shoot the HQ (needs distance 2-3)"
        lines.append("- %s at (%d,%d): distance %d from the enemy HQ%s" % (kind, v[0], v[1], d, extra))
    return "\n".join(lines)

def ask(model, prompt, seed=0):
    body = {"model": model, "messages": [{"role": "user", "content": prompt}], "temperature": 0.7, "top_p": 0.9, "seed": seed,
            "max_tokens": 700, "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        return (json.loads(r.read())["choices"][0]["message"].get("content") or "").strip()

if __name__ == "__main__":
    items = make_cold(); out = []
    jobs = [(m, it, f) for m in ("q35", "v3b_536") for it in items for f in (False, True)]
    def run(j):
        m, it, f = j
        p = it["prompt"] + ("\n\n" + facts(it) if f else "")
        return {"model": m, "id": it["id"], "facts": f, "content": ask(m, p)}
    with cf.ThreadPoolExecutor(8) as ex:
        out = list(ex.map(run, jobs))
    open("artifacts/brain_pipeline_v1/ckpt_sweep/facts_probe.jsonl", "w", encoding="utf-8").write("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in out))
    print("done", len(out))
