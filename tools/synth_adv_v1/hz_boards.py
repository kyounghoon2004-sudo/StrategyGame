"""Fresh-plan baseline (user, 2026-10-15): mid-game boards of the harvested student games presented as a NEW battle start
(reset_shim format: system prompt + opening-format user message, turns_left as it is) + the FACTS block; Qwen (v3b_536, thinking ON)
writes the plan and orders. This is Qwen's own baseline of 'planning from scratch on a board it has been playing'.
Cold prompts only: vLLM, no games.
  python -m tools.synth_adv_v1.hz_boards build          # boards.jsonl (CPU)
  python -m tools.synth_adv_v1.hz_boards run [--think]  # baseline.jsonl
"""
import argparse, collections, concurrent.futures as cf, json, random, time, urllib.request
from tools.synth_adv_v1.hz_pipeline import HZ
from tools.synth_adv_v1.hz_plan_items import games, outcome_of
from tools.synth_adv_v1.reset_shim import fresh_opening
from tools.synth_adv_v1.facts_shim import facts_block
from tools.synth_adv_v1.stall_shim import progress

OUT = HZ / "boards"
NOTE = ("It is turn %s of %s. Write the plan for winning this battle from this board (key \"plan\", at most 300 chars: phases that "
        "name unit ids, a turn deadline per phase, what to do if a phase fails) and the orders that start it.")


def build(per_game=5):
    OUT.mkdir(exist_ok=True)
    rng = random.Random(9)
    rows = []
    for src, tag, turns in games():
        ts = sorted(turns)
        cand = [t for t in ts if 6 <= t <= ts[-1] - 4]
        rng.shuffle(cand)
        pick, got = [], []
        for t in sorted(cand):
            pass
        step = max(5, (ts[-1] - 6) // per_game)
        t = 7
        while t <= ts[-1] - 4 and len(pick) < per_game:
            if t in turns:
                pick.append(t)
            t += step
        for T in pick:
            c = turns[T]
            st = c["state"]
            sysm = next(m for m in c["messages"] if m["role"] == "system")
            user = fresh_opening(st) + "\n\n" + NOTE % (T, st.get("turn_limit", 60)) + "\n\n" + facts_block(st)
            prog, n = progress(c["messages"], T, 5)
            rows.append({"id": "%s|%s|%d" % (src, tag, T), "src": src, "tag": tag, "turn": T, "progress5": prog,
                         "messages": [sysm, {"role": "user", "content": user}], "result": outcome_of(src, tag)})
    (OUT / "boards.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    print("boards", len(rows), dict(collections.Counter(r["src"] for r in rows)))


def run(a):
    rows = [json.loads(l) for l in (OUT / "boards.jsonl").read_text(encoding="utf-8").splitlines()]
    outf = OUT / ("baseline_%s.jsonl" % ("think" if a.think else "nothink"))
    done = set()
    if outf.exists():
        done = {json.loads(l)["id"] for l in outf.read_text(encoding="utf-8").splitlines() if l.strip()}
    todo = [r for r in rows if r["id"] not in done and (not a.src or r["src"] in a.src.split(","))]
    if a.limit:
        todo = todo[:a.limit]

    def ask(r):
        body = {"model": "v3b_536", "messages": r["messages"], "max_tokens": 9000 if a.think else 1500, "temperature": 0.6,
                "chat_template_kwargs": {"enable_thinking": a.think}}
        t0 = time.time()
        try:
            req = urllib.request.Request("http://127.0.0.1:8010/v1/chat/completions", json.dumps(body).encode(),
                                         {"Content-Type": "application/json"})
            o = json.loads(urllib.request.urlopen(req, timeout=1800).read())["choices"][0]["message"]
            return {"id": r["id"], "content": o.get("content"), "reasoning": o.get("reasoning_content") or o.get("reasoning"),
                    "s": round(time.time() - t0)}
        except Exception as e:  # noqa: BLE001
            return {"id": r["id"], "error": str(e)[:200], "s": round(time.time() - t0)}

    with cf.ThreadPoolExecutor(a.workers) as ex, open(outf, "a", encoding="utf-8") as fh:
        for i, o in enumerate(ex.map(ask, todo)):
            fh.write(json.dumps(o, ensure_ascii=False) + "\n"); fh.flush()
            if i % 20 == 0:
                print(i, "done", flush=True)


def loop(a):
    """Endless collection until <boards>/STOP exists: every cycle draws new random mid-game boards from every harvested game and asks
    Qwen at high temperature (more diverse plans); thinking ON only for BLOCKADE boards (user, 2026-10-15)."""
    import os, threading
    allg = [(s, t, turns) for s, t, turns in games()]
    rng = random.Random(int(time.time()))
    outf = OUT / "baseline_loop.jsonl"
    stop = OUT / "STOP"
    lock = threading.Lock()
    cycle = 0
    while not stop.exists():
        cycle += 1
        jobs = []
        for src, tag, turns in allg:
            ts = sorted(turns)
            cand = [t for t in ts if 6 <= t <= ts[-1] - 4]
            for T in rng.sample(cand, min(len(cand), a.per_game)):
                c = turns[T]
                st = c["state"]
                sysm = next(m for m in c["messages"] if m["role"] == "system")
                user = fresh_opening(st) + "\n\n" + NOTE % (T, st.get("turn_limit", 60)) + "\n\n" + facts_block(st)
                jobs.append({"id": "%s|%s|%d" % (src, tag, T), "src": src, "cycle": cycle,
                             "messages": [sysm, {"role": "user", "content": user}]})
        rng.shuffle(jobs)

        def ask(r):
            think = r["src"] == "BLOCKADE"
            body = {"model": "v3b_536", "messages": r["messages"], "max_tokens": 9000 if think else 1500,
                    "temperature": a.temperature, "top_p": 0.95, "chat_template_kwargs": {"enable_thinking": think}}
            t0 = time.time()
            try:
                req = urllib.request.Request("http://127.0.0.1:8010/v1/chat/completions", json.dumps(body).encode(),
                                             {"Content-Type": "application/json"})
                o = json.loads(urllib.request.urlopen(req, timeout=1800).read())["choices"][0]["message"]
                return {"id": r["id"], "cycle": r["cycle"], "think": think, "temperature": a.temperature, "content": o.get("content"),
                        "reasoning": o.get("reasoning_content") or o.get("reasoning"), "s": round(time.time() - t0)}
            except Exception as e:  # noqa: BLE001
                return {"id": r["id"], "cycle": r["cycle"], "error": str(e)[:200]}

        with cf.ThreadPoolExecutor(a.workers) as ex:
            futs = [ex.submit(ask, j) for j in jobs]
            for i, f in enumerate(cf.as_completed(futs)):
                with lock, open(outf, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(f.result(), ensure_ascii=False) + "\n")
                if stop.exists():
                    for g in futs:
                        g.cancel()
                    break
        print("cycle", cycle, "done", len(jobs), flush=True)
    print("STOP seen", flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["build", "run", "loop"])
    ap.add_argument("--think", action="store_true")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--per-game", type=int, default=6)
    ap.add_argument("--temperature", type=float, default=1.0)
    ap.add_argument("--src", default="", help="comma list of BASIC,INTER,BLOCKADE")
    a = ap.parse_args()
    {"build": lambda: build(), "run": lambda: run(a), "loop": lambda: loop(a)}[a.cmd]()
