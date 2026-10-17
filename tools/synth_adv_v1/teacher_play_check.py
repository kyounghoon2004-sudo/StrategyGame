"""Quick inspection of a cloud teacher's games (2026-10-16): per game the result, answers given, unparsable answers, empty
orders, plans written (turn 1 / relay turns / other turns) and the relay plans with their KEEP/REVISE prefix.
  python -m tools.synth_adv_v1.teacher_play_check t1 [t2 ...]
"""
import glob, json, os, sys

BASE = os.path.join(os.path.dirname(__file__), "..", "..", "artifacts", "brain_pipeline_v1", "synth_adv_v1", "teacher_play")


def main():
    for name in sys.argv[1:]:
        print("=====", name)
        for g in sorted(glob.glob(os.path.join(BASE, name, "g[0-9]*"))):
            res = ""
            for f in glob.glob(os.path.join(g, "game", "games.jsonl")):
                r = json.loads(open(f, encoding="utf-8").read().splitlines()[-1])
                res = "%s t%s" % (r.get("kind") or r.get("outcome"), r.get("turn"))
            n = bad = empty = 0
            plans, relay = [], []
            for q in sorted(glob.glob(os.path.join(g, "inbox", "req_*.json"))):
                rp = q.replace("req_", "resp_").replace(".json", ".txt")
                if not os.path.exists(rp):
                    continue
                req = json.load(open(q, encoding="utf-8"))
                t = req.get("turn")
                txt = open(rp, encoding="utf-8").read().strip()
                n += 1
                try:
                    a = json.loads(txt)
                except ValueError:
                    bad += 1
                    continue
                if not a.get("orders"):
                    empty += 1
                if a.get("plan"):
                    plans.append(t)
                    if t in (1, 10, 20, 30, 40, 50):
                        relay.append("t%s %s" % (t, a["plan"][:140]))
                elif t in (1, 10, 20, 30, 40, 50):
                    relay.append("t%s (NO PLAN)" % t)
            print("%s  result=%s answers=%d unparsable=%d empty_orders=%d plan_turns=%s" % (
                os.path.basename(g), res or "(playing)", n, bad, empty, plans))
            for x in relay:
                print("   ", x)


if __name__ == "__main__":
    main()
