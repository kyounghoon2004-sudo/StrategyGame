"""30-min Strata teacher check (2026-10-17): per bridge log the turns, timings, forced/fallbacks, plans and a spot-check of
non-plan orders; plus results.log, CURRENT.txt and the age of the newest resp.
  python -m tools.synth_adv_v1.strata_check
"""
import glob, json, os, time

D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "artifacts", "brain_pipeline_v1", "synth_adv_v1",
                 "teacher_play", "strata")


def report(path):
    rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    if not rows:
        return
    print("== %s: %d turns (t%d..t%d)" % (os.path.basename(path), len(rows), rows[0]["turn"], rows[-1]["turn"]))
    sh = [sum(x["s"] for x in r["attempts"]) for r in rows if not r.get("plan_turn")]
    print("   short turns: %d, avg %.0fs, max %.0fs" % (len(sh), sum(sh) / max(1, len(sh)), max(sh or [0])))
    print("   fallbacks: %d %s" % (sum(1 for r in rows if r.get("fallback")),
                                   [r["turn"] for r in rows if r.get("fallback")]))
    for r in rows:
        p = r["answer"].get("plan")
        if r.get("plan_turn") or p:
            print("   t%-2d %-5s %4.0fs forced=%s tries=%d plan(%s): %s" % (
                r["turn"], "PLAN" if r.get("plan_turn") else "short", sum(x["s"] for x in r["attempts"]),
                any(x.get("forced") for x in r["attempts"]), len(r["attempts"]), len(p or ""), (p or "-")[:150]))
    np = [r for r in rows if not r.get("plan_turn")][-3:]
    for r in np:
        print("   spot t%d orders: %s" % (r["turn"], json.dumps(r["answer"]["orders"])[:200]))


def main():
    print("now", time.strftime("%H:%M"))
    rl = os.path.join(D, "results.log")
    if os.path.exists(rl):
        for l in open(rl, encoding="utf-8").read().splitlines():
            if " g0" in l and int(l.split(" g")[1][:3]) >= 4:
                try:
                    g = json.loads(l[l.index("{"):])
                    print("RESULT", l.split(" ")[2], g.get("kind") or g.get("outcome"), "t%s" % g.get("turn"))
                except ValueError:
                    print("RESULT", l[:80])
    cur = open(os.path.join(D, "CURRENT.txt"), encoding="utf-8").read().strip()
    print("CURRENT", cur.split("teacher_play/")[-1])
    if "inbox" in cur and os.path.isdir(cur):
        fs = glob.glob(os.path.join(cur, "resp_*.txt"))
        if fs:
            print("newest resp %.1f min ago" % ((time.time() - max(os.path.getmtime(f) for f in fs)) / 60))
    for p in sorted(glob.glob(os.path.join(D, "bridge_*_v23.jsonl")))[-1:] + glob.glob(os.path.join(D, "bridge.jsonl")):
        report(p)


if __name__ == "__main__":
    main()
