"""Find teacher games where the BLUE HQ's fieldworks went back up (old rule: a fortified unit digs in again after its fieldworks were
destroyed). 2026-10-18 (user): the new rule lets a unit fortify only once per game, so those games are dropped from the SFT set and replaced.
A regen event = the HQ "fortified" value rises by at least 40 between two consecutive request turns of the same game.
  python -m tools.synth_adv_v1.regen_audit --dir <teacher_play/strata> --write      write EXCLUDED_regen.json (games are never deleted)
  python -m tools.synth_adv_v1.regen_audit --dir <...> --clean-wins BASIC --after 99   count clean (no regen) BASIC wins with game no. > 99
"""
import argparse, glob, json, os, re

LINE = re.compile(r"^\S+ \S+ (g(\d+)_(\w+?)_hist\w+) .*?(\{.*)$")


def games(d):
    out = {}
    for l in open(os.path.join(d, "results.log"), encoding="utf-8"):
        m = LINE.match(l.rstrip("\n"))
        if not m:
            continue
        try:
            j = json.loads(m.group(4))
        except ValueError:
            continue
        out[m.group(1)] = (int(m.group(2)), m.group(3), j.get("kind"))
    return out


def regen_events(gdir):
    seq = []
    for f in glob.glob(os.path.join(gdir, "inbox", "req_*.json")):
        try:
            q = json.load(open(f, encoding="utf-8"))
        except ValueError:
            continue
        h = [u for u in (q.get("state") or {}).get("enemy_units", []) if u.get("class") == "HQ"]
        if h and h[0].get("fortified") is not None:
            seq.append((int(q["turn"]), int(h[0]["fortified"])))
    seq.sort()
    return sum(1 for a, b in zip(seq, seq[1:]) if b[1] - a[1] >= 40)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--since", type=int, default=20)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--clean-wins", default="", help="tier: print the number of WIN games of this tier without a regen event")
    ap.add_argument("--after", type=int, default=0, help="only game numbers above this")
    ap.add_argument("--max-no", action="store_true", help="print the highest game number in results.log")
    a = ap.parse_args()
    g = games(a.dir)
    if a.max_no:
        print(max([v[0] for v in g.values()] or [0]))
        return
    if a.clean_wins:
        n = sum(1 for k, (no, t, kind) in g.items()
                if no > a.after and t == a.clean_wins and kind == "WIN" and regen_events(os.path.join(a.dir, k)) == 0)
        print(n)
        return
    bad = {}
    for k, (no, t, kind) in sorted(g.items(), key=lambda kv: kv[1][0]):
        if no >= a.since and kind == "WIN":
            ev = regen_events(os.path.join(a.dir, k))
            if ev and t != "COLLAPSE":
                bad[k] = {"tier": t, "regen_events": ev, "reason": "BLUE HQ fieldworks regenerated (old rule); dropped from SFT 2026-10-18"}
    print(len(bad), "games:", ", ".join(bad))
    if a.write:
        p = os.path.join(a.dir, "EXCLUDED_regen.json")
        json.dump(bad, open(p, "w", encoding="utf-8"), indent=1)
        print("wrote", p)


if __name__ == "__main__":
    main()
