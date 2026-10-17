"""Checkpoint sweep runner: thinking ON, loop guard (repetition / 'Wait' loops) instead of a token hard cap.
  python -m tools.ckpt_sweep.run_sweep --models q35,v3_100,... --out <dir> [--test]
Each (model, item) -> one JSON line in <out>/gen.jsonl. The guard stops a stream when the reasoning repeats itself or
drifts into a self-check loop, then asks the model to conclude (reasoning so far + </think>, continue_final_message).
"""
import argparse, concurrent.futures as cf, json, re, time, urllib.request
from pathlib import Path
from tools.ckpt_sweep.items import make_cold, make_packets

URL = "http://127.0.0.1:8010/v1/chat/completions"
CEILING = 40000  # chars of reasoning (~11k tokens): a safety ceiling, reported separately


def detect_loop(r):
    if len(r) > CEILING:
        return "ceiling"
    if len(r) >= 6000:
        tail = r[-250:]
        if r[:-250].count(tail) >= 2:
            return "repeat"
        if len(re.findall(r"\bWait\b", r[-6000:])) >= 15:
            return "wait_loop"
    return None


def post(body, stream=False, timeout=1800):
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


def gen(model, messages, seed=0):
    body = {"model": model, "messages": messages, "temperature": 0.7, "top_p": 0.9, "seed": seed, "max_tokens": 14000,
            "stream": True, "chat_template_kwargs": {"enable_thinking": True}}
    reasoning, content, guard, natural = "", "", None, False
    resp = post(body, True)
    since = 0
    try:
        for raw in resp:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            d = json.loads(data)["choices"][0]
            delta = d.get("delta") or {}
            r = delta.get("reasoning_content") or delta.get("reasoning") or ""
            c = delta.get("content") or ""
            reasoning += r
            content += c
            since += len(r)
            if c:
                natural = True
            if d.get("finish_reason"):
                break
            if not content and since >= 500:
                since = 0
                guard = detect_loop(reasoning)
                if guard:
                    break
    finally:
        resp.close()
    if guard or not content.strip():
        # force the conclusion: raw completion on the hand-written chat template (the chat endpoint continue_final_message
        # files the continuation under reasoning_content and leaves content empty)
        NL = chr(10)
        prompt = "".join("<|im_start|>" + m["role"] + NL + m["content"] + "<|im_end|>" + NL for m in messages)
        prompt += ("<|im_start|>assistant" + NL + "<think>" + NL + reasoning.rstrip() + NL + NL +
                   "I have reasoned enough; let me conclude." + NL + "</think>" + NL + NL)
        body2 = {"model": model, "prompt": prompt, "temperature": 0.3, "max_tokens": 1200, "seed": seed}
        try:
            req = urllib.request.Request(URL.replace("/chat/completions", "/completions"), data=json.dumps(body2).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=1800) as r2:
                content = json.loads(r2.read())["choices"][0]["text"].strip()
        except Exception as e:  # noqa: BLE001
            content = "ERR " + str(e)
    return {"reasoning_chars": len(reasoning), "natural_finish": natural and not guard, "guard": guard, "content": content.strip(), "reasoning": reasoning}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--test", action="store_true")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--only-guarded-from", default="", help="rerun only the (model,id) pairs a previous gen.jsonl had guarded")
    ap.add_argument("--nothink", action="store_true", help="thinking OFF (the deployed mode), plain non-stream call")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    items = make_cold()  # cold prompts only (user: no game packets, no games)
    models = a.models.split(",")
    if a.test:
        items, models = items[:2], models[:1]
    done = set()
    gf = out / "gen.jsonl"
    if gf.exists():
        for l in gf.read_text(encoding="utf-8").splitlines():
            if l.strip():
                j = json.loads(l); done.add((j["model"], j["id"]))
    only = None
    if a.only_guarded_from:
        only = {(j["model"], j["id"]) for j in map(json.loads, Path(a.only_guarded_from).read_text(encoding="utf-8").splitlines()) if j.get("guard")}
    jobs = [(m, it) for m in models for it in items if (m, it["id"]) not in done and (only is None or (m, it["id"]) in only)]
    print("jobs", len(jobs), flush=True)

    def run(job):
        m, it = job
        msgs = it["messages"] if it["kind"] == "packet" else [{"role": "user", "content": it["prompt"]}]
        t0 = time.time()
        try:
            if a.nothink:
                body = {"model": m, "messages": msgs, "temperature": 0.7, "top_p": 0.9, "seed": 0, "max_tokens": 700,
                        "chat_template_kwargs": {"enable_thinking": False}}
                with post(body) as r1:
                    c = json.loads(r1.read())["choices"][0]["message"].get("content") or ""
                res = {"reasoning_chars": 0, "natural_finish": True, "guard": None, "content": c.strip()}
            else:
                res = gen(m, msgs)
        except Exception as e:  # noqa: BLE001
            res = {"error": str(e)}
        res.update({"model": m, "id": it["id"], "kind": it["kind"], "s": round(time.time() - t0)})
        return res

    with cf.ThreadPoolExecutor(a.workers) as ex, open(gf, "a", encoding="utf-8") as fh:
        for res in ex.map(run, jobs):
            fh.write(json.dumps(res, ensure_ascii=False) + "\n"); fh.flush()
            print(res["model"], res["id"], "chars", res.get("reasoning_chars"), "guard", res.get("guard"), res.get("s"), "s", flush=True)


if __name__ == "__main__":
    main()
