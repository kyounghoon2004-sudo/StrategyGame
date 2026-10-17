"""Harness-Zero engine check (user, 2026-10-15): does a correction actually make progress in the real game?

For every curated correction row (hz_rows_clean.json): replay the harvested student game with the student's own recorded
answers up to turn T-1 (bit-exact engine), then at turn T play
   arm "label"   = the correction,      arm "student" = the student's own recorded answer at T,
then {"orders": {}} (orders stand) to the 60-turn cap (the GX bot times its phases from turn_limit, so the cap
must stay 60); measured only over turns T..T+H. Same seed, same opponent; only turn T differs.
Measured from the game record over turns T..T+H (RED attacks): soldiers dealt, fieldworks stripped, kills, enemy HQ
damage; minus soldiers RED lost (counters + BLUE attacks). A label is kept when its net >= the student's.
The request at turn T is compared with the harvested one (prefix_match) to prove the replay reached the same state.

  python -m tools.synth_adv_v1.hz_branch --kind gx       --windows 6 --slot 5   # BASIC + INTER rows (BLUE = GX bot)
  python -m tools.synth_adv_v1.hz_branch --kind blockade --windows 4 --slot 6   # BLOCKADE rows (BLUE = blockade_bot)
  python -m tools.synth_adv_v1.hz_branch --report
"""
import argparse
import json
import queue
import secrets
import subprocess
import sys
import threading
import time
from pathlib import Path

from tools.synth_adv_v1.hz_pipeline import HZ, SOURCES

STAND = '{"orders": {}}'
FAMILY = ["fixed", "mild", "broad", "counterfactual_valid"]
OUT = HZ / "branch"


def recorded():
    """(src, tag) -> {turn: raw served, "_msg": {turn: last user message}}"""
    rec = {}
    for src, path in SOURCES:
        for l in path.read_text(encoding="utf-8").splitlines():
            if not l.strip():
                continue
            c = json.loads(l)
            if c.get("request") != "VICTORY_COMMAND" or c.get("turn") is None or c.get("raw") is None:
                continue
            d = rec.setdefault((src, c["tag"]), {"ans": {}, "msg": {}})
            d["ans"][int(c["turn"])] = c["raw"]
            if c.get("messages"):
                d["msg"][int(c["turn"])] = [m["content"] for m in c["messages"] if m["role"] == "user"][-1]
    return rec


def meta_of(src, tag):
    if src == "BLOCKADE":
        seed = int(tag.rsplit("_s", 1)[1])
        return {"seed": seed, "tier": "BASIC", "style": "BULWARK", "family": FAMILY[seed % 4]}
    for l in (HZ / ("harvest_" + src) / "games.jsonl").read_text(encoding="utf-8").splitlines():
        g = json.loads(l)
        if g["tag"] == tag:
            return {"seed": g["seed"], "tier": g["tier"], "style": g["style"], "family": g["family"]}
    raise KeyError(tag)


def branches(kind, horizon):
    rows = json.loads((HZ / "hz_rows_clean.json").read_text(encoding="utf-8"))
    rec = recorded()
    out = []
    for i, r in enumerate(x for x in rows if x["source"].startswith("hz_replaced")):
        src, tag = r["game"].split("|", 1)
        if (kind == "blockade") != (src == "BLOCKADE"):
            continue
        T = int(r["turn"])
        d = rec[(src, tag)]
        for arm, ans in (("label", r["completion"]), ("student", d["ans"].get(T, STAND))):
            out.append({"id": "hzb%04d_%s" % (i, arm), "row": i, "arm": arm, "src": src, "tag": tag, "T": T, "H": horizon,
                        "answer": ans, **meta_of(src, tag)})
    return out, rec


def serve(md, br, rec, stop, seen):
    from tools.plan_search.brain_io import _resp, _try_claim
    while not stop.is_set():
        for f in sorted(md.glob("req_*.json")):
            if _resp(f).exists() or not _try_claim(f, "HZB"):
                continue
            r = json.loads(f.read_text(encoding="utf-8"))
            text = "{}"
            b = br.get(str(r.get("tag")))
            if r.get("request") == "VICTORY_COMMAND" and b:
                t = int(r.get("turn") or 0)
                d = rec[(b["src"], b["tag"])]
                if t < b["T"]:
                    text = d["ans"].get(t, STAND)
                elif t == b["T"]:
                    msgs = r.get("messages") or []
                    last = [m["content"] for m in msgs if m["role"] == "user"][-1] if msgs else ""
                    seen[b["id"]] = (last == d["msg"].get(t))
                    text = b["answer"]
                else:
                    text = STAND
            _resp(f).write_text(text, encoding="utf-8")
        time.sleep(0.05)


def measure(res, T, H):
    acts = ((res.get("record") or {}).get("actions") or {})
    m = {"dealt": 0, "fw": 0, "kills": 0, "hq_dmg": 0, "lost": 0}
    for x in acts.get("red") or []:
        if x.get("do") in ("ATTACK", "RAID") and T <= int(x.get("turn", 0)) <= T + H:
            m["dealt"] += int(x.get("dealt") or 0)
            m["fw"] += int(x.get("fieldworks") or 0)
            m["kills"] += bool(x.get("destroyed"))
            m["lost"] += int(x.get("took") or 0)
            if str(x.get("target", "")).startswith("B_HQ"):
                m["hq_dmg"] += int(x.get("dealt") or 0) + int(x.get("fieldworks") or 0)
    for x in acts.get("blue") or []:
        if x.get("do") in ("ATTACK", "RAID") and T <= int(x.get("turn", 0)) <= T + H:
            m["lost"] += int(x.get("dealt") or 0)
    m["net"] = m["dealt"] + m["fw"] + 100 * m["kills"] - m["lost"]
    m["outcome"] = res.get("outcome")
    return m


def run(a):
    from tools.brain_review.harvest import post, wait_port
    from tools.contextual_brain import rl_vs_utility as RV
    from tools.plan_search.eval_plans import Hands
    out = OUT / a.kind
    out.mkdir(parents=True, exist_ok=True)
    br, rec = branches(a.kind, a.horizon)
    done = set()
    resf = out / "results.jsonl"
    if resf.exists():
        done = {json.loads(l)["id"] for l in resf.read_text(encoding="utf-8").splitlines() if l.strip()}
    br = [b for b in br if b["id"] not in done]
    if a.limit:
        br = br[:a.limit]
    lock = threading.Lock()

    def log(m):
        line = time.strftime("%m-%d %H:%M:%S ") + m
        with lock:
            print(line, flush=True)
            with open(out / "branch.log", "a", encoding="utf-8") as fh:
                fh.write(line + "\n")

    log("branches to play %d (done %d)" % (len(br), len(done)))
    if not br:
        return
    hands = Hands(a.slot, out, log, "cpu")
    hands.start()
    token = secrets.token_hex(8)
    rp, bp = 8120 + 10 * a.slot, 8125 + 10 * a.slot
    md = out / ("manual_%d" % int(time.time()))
    procs = []

    def proxy(port, cap, mdir):
        cap.mkdir(parents=True, exist_ok=True)
        return subprocess.Popen([RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token, "--capture-dir", str(cap),
                                 "--port", str(port), "--brain-port", str(port + 1000), "--default-mode", "TEACHER",
                                 "--initial-stub", "--manual-dir", str(mdir), "--manual-poll-s", "0.1"],
                                cwd=str(RV.ROOT), stdout=open(cap / "proxy.log", "a"), stderr=subprocess.STDOUT)

    procs.append(proxy(rp, out / "captures" / "red", md / "red"))
    env = {"LAYA_URL": hands.url, "BRAIN_CONTRACT_MODE": "unalloc_v1", "SELFPLAY_GENERAL_TIMEOUT_SEC": "7200",
           "WATCH_STRATEGIC_REPLAN_TURNS": "0", "WATCH_RED_MODE": "COMMANDER", "WATCH_CMD_FACTS": "1", "FIELD_FORTIFY": "1",
           "WATCH_ROUT_MIN": "17", "WATCH_NO_HQ_WIN": "0", "WATCH_CMD_URL": "http://127.0.0.1:%d/v1/chat/completions" % rp,
           "WATCH_BRAIN_PORT": str(rp)}
    bot = None
    if a.kind == "blockade":
        procs.append(proxy(bp, out / "captures" / "blue", md / "blue"))
        (md / "blue").mkdir(parents=True, exist_ok=True)
        bot = subprocess.Popen([RV.PY, "-m", "tools.cmd_rl.blockade_bot", "--dir", str(md / "blue")], cwd=str(RV.ROOT),
                               stdout=open(out / "bot.out", "a"), stderr=subprocess.STDOUT)
        env.update({"WATCH_BLUE_MODE": "COMMANDER", "WATCH_CMD_URL_BLUE": "http://127.0.0.1:%d/v1/chat/completions" % bp})
    else:
        env["WATCH_BLUE_MODE"] = "GX"
    for p in [rp] + ([bp] if a.kind == "blockade" else []):
        if not wait_port(p, token, 180):
            raise SystemExit("proxy %d did not come up" % p)
    bmap = {b["id"]: b for b in br}
    seen = {}
    stop = threading.Event()
    (md / "red").mkdir(parents=True, exist_ok=True)
    threading.Thread(target=serve, args=(md / "red", bmap, rec, stop, seen), daemon=True).start()
    q = queue.Queue()
    for b in br:
        q.put(b)
    arenas = [RV.Arena(log, 10 + 10 * a.slot + i, dict(env), None, headless=True) for i in range(a.windows)]

    def worker(i, ar):
        win = "w%d" % (10 + 10 * a.slot + i)
        while True:
            try:
                b = q.get_nowait()
            except queue.Empty:
                return
            job = {"family": b["family"], "seed": b["seed"], "tier": b["tier"], "style": b["style"],
                   "turn_cap": 60, "session": token, "random_roster": False, "roster_sizes": ""}
            post(rp, "/admin/tags", {win: b["id"]})
            if a.kind == "blockade":
                post(bp, "/admin/tags", {win: b["id"]})
            o = out / "games" / ("%s.json" % b["id"])
            o.parent.mkdir(exist_ok=True)
            g0 = time.time()
            err = ar.play(job, o, 3600)
            res = json.loads(o.read_text(encoding="utf-8")) if o.exists() else {"error": err or "no result"}
            m = measure(res, b["T"], b["H"])
            row = {"id": b["id"], "row": b["row"], "arm": b["arm"], "src": b["src"], "tag": b["tag"], "T": b["T"],
                   "prefix_match": seen.get(b["id"]), "error": res.get("error"), "s": round(time.time() - g0), **m}
            with lock:
                with open(resf, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(row) + "\n")
            log("%s %s T%d match=%s net=%s outcome=%s (%ds)" % (b["id"], b["src"], b["T"], row["prefix_match"], m["net"],
                                                              m["outcome"], row["s"]))

    threads = [threading.Thread(target=worker, args=(i, ar), daemon=True) for i, ar in enumerate(arenas)]
    try:
        for t in threads:
            t.start()
            time.sleep(3)
        for t in threads:
            t.join()
    finally:
        stop.set()
        for p in [rp] + ([bp] if a.kind == "blockade" else []):
            try:
                post(p, "/admin/shutdown", {})
            except Exception:  # noqa: BLE001
                pass
        for pr in procs:
            try:
                pr.wait(timeout=30)
            except Exception:  # noqa: BLE001
                pr.kill()
        if bot:
            bot.kill()
        for ar in arenas:
            ar.quit()
        hands.stop()
        log("done")


RANK = {"RED_WIN": 2, "CAP": 1}


def goal_key(r):
    """The goal decides (user, 2026-10-15): win first, then how far the enemy HQ was brought down by the end of the game
    (HQ hp + its fieldworks never reported apart: hq.blue.end), troop exchange over T..T+H only as the tie-break."""
    k = "blockade" if r["src"] == "BLOCKADE" else "gx"
    g = json.loads((OUT / k / "games" / ("%s.json" % r["id"])).read_text(encoding="utf-8"))
    hq = ((g.get("hq") or {}).get("blue") or {}).get("end", 999)
    return (RANK.get(g.get("outcome"), 0), -int(hq if hq is not None else 999), r["net"])


def report():
    import collections
    rows = []
    for k in ("gx", "blockade"):
        f = OUT / k / "results.jsonl"
        if f.exists():
            rows += [json.loads(l) for l in f.read_text(encoding="utf-8").splitlines() if l.strip()]
    by = collections.defaultdict(dict)
    for r in rows:
        by[r["row"]][r["arm"]] = r
    st = collections.Counter()
    keep = []
    for i, d in sorted(by.items()):
        if "label" not in d or "student" not in d:
            continue
        L, S = d["label"], d["student"]
        st[L["src"] + "_pairs"] += 1
        if not (L["prefix_match"] and S["prefix_match"]):
            st[L["src"] + "_prefix_mismatch"] += 1
            continue
        better = goal_key(L) >= goal_key(S)
        st[L["src"] + ("_label_ge" if better else "_label_worse")] += 1
        if better:
            keep.append(i)
    (OUT / "keep_rows.json").write_text(json.dumps(keep), encoding="utf-8")
    print(dict(sorted(st.items())))
    print("kept", len(keep))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", choices=["gx", "blockade"])
    ap.add_argument("--windows", type=int, default=6)
    ap.add_argument("--slot", type=int, default=5)
    ap.add_argument("--horizon", type=int, default=6)
    ap.add_argument("--limit", type=int, default=0, help="test: only the first N branches")
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()
    if a.report:
        report()
    else:
        run(a)
