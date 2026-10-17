"""Behaviour metrics of an eval run (cmd_collect out dir): wins, empty-order rate on turns >= 2, plan rewrites after T1.
  python -m tools.synth_adv_v1.eval_metrics <eval dir> [<eval dir> ...]
"""
import collections, json, sys
from pathlib import Path


def parse(raw):
    if not isinstance(raw, str):
        return None
    t = raw.split("</think>", 1)[-1].strip()
    try:
        return json.loads(t)
    except ValueError:
        i, j = t.find("{"), t.rfind("}")
        try:
            return json.loads(t[i:j + 1]) if i >= 0 and j > i else None
        except ValueError:
            return None


def main():
    for d in map(Path, sys.argv[1:]):
        rf = d / "results.jsonl" if (d / "results.jsonl").exists() else d / "games.jsonl"  # cmd_collect / teacher_gx
        res = [json.loads(l) for l in rf.read_text(encoding="utf-8").splitlines() if l.strip()]
        cf = d / "raw" / "calls.jsonl" if (d / "raw" / "calls.jsonl").exists() else d / "captures" / "calls.jsonl"
        out = collections.Counter(r.get("outcome") for r in res)
        kinds = collections.Counter(r.get("kind") for r in res)
        last = {}
        for l in cf.read_text(encoding="utf-8").splitlines():
            if not l.strip():
                continue
            c = json.loads(l)
            if c.get("request") == "VICTORY_COMMAND" and c.get("turn") is not None:
                last[(c.get("tag"), int(c["turn"]))] = c
        n2 = e2 = bad = 0; plans = collections.Counter(); calls = 0
        wins_turn = [r.get("turn") for r in res if r.get("kind") == "WIN"]
        for (tag, t), c in last.items():
            a = parse(c.get("raw"))
            calls += 1
            if a is None:
                bad += 1; continue
            if t >= 2:
                n2 += 1
                if not a.get("orders"):
                    e2 += 1
                if a.get("plan"):
                    plans[tag] += 1
        games = len({k[0] for k in last})
        print(d.name, "games", len(res), dict(kinds), dict(out))
        print("  win turns", sorted(wins_turn))
        print("  empty-order rate (turn>=2): %.1f%% of %d calls; unparsable %d; plan rewrites after T1: %d total, %.2f/game over %d games"
              % (100 * e2 / max(1, n2), n2, bad, sum(plans.values()), sum(plans.values()) / max(1, games), games))


if __name__ == "__main__":
    main()
