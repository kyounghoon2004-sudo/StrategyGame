"""Relay cycle status from the result files (2026-10-16): per arm the game outcomes (INVALID counted) and the shim request log
(relay / carry / pass / error counts, longest carried context).
  python -m tools.synth_adv_v1.relay_check artifacts/brain_pipeline_v1/synth_adv_v1/relay3
"""
import collections, glob, json, os, sys


def main():
    root = sys.argv[1]
    tot = collections.Counter()
    for c in sorted([p for p in glob.glob(os.path.join(root, "c*")) if os.path.isdir(p) and os.path.basename(p)[1:].isdigit()], key=lambda p: int(os.path.basename(p)[1:] or 0)):
        for g in sorted(glob.glob(os.path.join(c, "*", "games.jsonl")) + glob.glob(os.path.join(c, "*", "*", "games.jsonl"))):
            outs = collections.Counter()
            for line in open(g, encoding="utf-8"):
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                o = str(r.get("kind") or r.get("outcome") or r.get("result") or "?")
                outs[o] += 1
                tot[o] += 1
            print("%-45s %s" % (os.path.relpath(g, root), dict(outs)))
        for f in sorted(glob.glob(os.path.join(c, "*.req.jsonl"))):
            rows = [json.loads(x) for x in open(f, encoding="utf-8") if x.strip()]
            m = collections.Counter(r["mode"] for r in rows)
            mx = max([r["n_out"] or 0 for r in rows if r["mode"] == "carry"] or [0])
            print("%-45s req=%d %s windows=%d err=%d max_carry_msgs=%d" % (
                os.path.relpath(f, root), len(rows), dict(m), len({r["window"] for r in rows}), m["error"], mx))
    n = sum(tot.values())
    inv = sum(v for k, v in tot.items() if "INVALID" in k.upper())
    print("TOTAL games=%d %s INVALID=%d (%.0f%%)" % (n, dict(tot), inv, 100.0 * inv / n if n else 0))


if __name__ == "__main__":
    main()
