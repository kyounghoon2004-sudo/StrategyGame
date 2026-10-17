"""Teacher files, one per LOST relay game (user, 2026-10-16): the whole game turn by turn (what the student was shown, what it
answered; relay turns marked with the relay prompt), so the teacher replays it, finds where the plan or its execution went wrong,
and writes KEEP/REVISE + plan + orders for every relay turn. Wins are not included. Never deletes or overwrites.
  python -m tools.synth_adv_v1.hz_relay_games --root relay3 --out relay3/teacher_g1 --cycles 1,2,3
"""
import argparse
import collections
import glob
import json
import os
from pathlib import Path

from tools.synth_adv_v1.hz_pipeline import HZ

LOST = {"NOT_ACHIEVED", "LOSS", "CAP", "INVALID"}


def answer_text(s):
    return str(s or "").split("</think>")[-1].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="relay3")
    ap.add_argument("--out", required=True)
    ap.add_argument("--cycles", default="")
    ap.add_argument("--pick", default="", help="comma list of game ids (cN/arm/tag); default: every lost game")
    a = ap.parse_args()
    pick = {x.strip() for x in a.pick.split(",") if x.strip()}
    R, OUT = HZ.parent / a.root, HZ.parent / a.out
    if OUT.exists() and any(OUT.iterdir()):
        raise SystemExit("refusing: %s already has files; pass a new --out" % OUT)
    OUT.mkdir(parents=True, exist_ok=True)
    want = {x.strip() for x in a.cycles.split(",") if x.strip()}
    head = open(Path(__file__).with_name("hz_relay_game_teacher_prompt.md"), encoding="utf-8").read()
    index, stats = [], collections.Counter()
    for cyc in sorted((d for d in glob.glob(str(R / "c*")) if os.path.isdir(d) and os.path.basename(d)[1:].isdigit()
                       and (not want or os.path.basename(d)[1:] in want)), key=lambda d: int(os.path.basename(d)[1:])):
        for rf in sorted(glob.glob(os.path.join(cyc, "*_relays.jsonl"))):
            name = os.path.basename(rf).replace("_relays.jsonl", "")
            arm = os.path.join(cyc, name)
            gf = os.path.join(arm, "games.jsonl")
            if not os.path.exists(gf):
                continue
            games = {}
            for line in open(gf, encoding="utf-8"):
                g = json.loads(line)
                games[g.get("tag") or "MANUAL_s%s" % g.get("seed")] = g
            turns = collections.defaultdict(dict)  # tag -> turn -> (shown, answered)
            by_win = collections.defaultdict(list)
            sysp = {}
            for cf in glob.glob(arm + "/captures/red/calls.jsonl") + glob.glob(arm + "/captures/calls.jsonl"):
                for line in open(cf, encoding="utf-8"):
                    c = json.loads(line)
                    if c.get("request") != "VICTORY_COMMAND" or not c.get("tag"):
                        continue
                    by_win[c.get("window")].append((c["ts"], c["tag"]))
                    if c.get("messages") and c["messages"][0].get("role") == "system":
                        sysp.setdefault(c["tag"], c["messages"][0]["content"])
                    if c.get("messages") and c.get("turn") is not None:
                        turns[c["tag"]].setdefault(int(c["turn"]), (c["messages"][-1]["content"], answer_text(c.get("raw"))))
            relays = collections.defaultdict(dict)
            for line in open(rf, encoding="utf-8"):
                r = json.loads(line)
                prior = [x for x in by_win.get(r.get("window"), []) if x[0] <= r["ts"]]
                if not prior:
                    stats["relay_unmatched"] += 1
                    continue
                relays[max(prior)[1]][int(r["turn"])] = r
            for tag, g in games.items():
                kind = g.get("kind") or g.get("outcome")
                if kind not in LOST or tag not in turns:
                    continue
                rl = relays.get(tag, {})
                u = g.get("units") or {}
                gid = "%s/%s/%s" % (os.path.basename(cyc), name, tag)
                if pick and gid not in pick:
                    continue
                res = "%s at turn %s (RED %s of %s units alive, BLUE %s of %s)" % (
                    kind, g.get("turn"), u.get("red", {}).get("alive"), u.get("red", {}).get("start"),
                    u.get("blue", {}).get("alive"), u.get("blue", {}).get("start"))
                hist = "yes" if name.endswith("yes") else "no"
                md = [head, "\n## 7. The system prompt the student is given (verbatim)\n```\n%s\n```\n" % sysp.get(tag, "(missing)"),
                      "\n---\n# GAME %s\nresult: %s\nrelay turns: %s (relay prompt with history: %s)\n"
                      % (gid, res, sorted(rl), hist)]
                for t in sorted(set(turns[tag]) | set(rl)):
                    if t in rl:
                        r = rl[t]
                        md.append("\n## TURN %d - RELAY (conversation wiped; the commander was shown only this)\n### shown\n%s\n"
                                  "### answered\n%s\n" % (t, r["relay_messages"][-1]["content"], answer_text(r.get("response"))))
                    else:
                        shown, ans = turns[tag][t]
                        md.append("\n## TURN %d\n### shown\n%s\n### answered\n%s\n" % (t, shown, ans))
                md.append("\n## END: %s\n\n---\nOUTPUT: write the JSON object to answers_%s.json in this same folder, then "
                          "check that it parses.\n" % (res, len(index)))
                fn = "game_%03d.md" % len(index)
                (OUT / fn).write_text("".join(md), encoding="utf-8")
                index.append({"file": fn, "game": gid, "result": res, "relay_turns": sorted(rl), "history": hist,
                              "turns_logged": len(turns[tag])})
                stats[name.split("_")[0]] += 1
    (OUT / "index.jsonl").write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in index), encoding="utf-8")
    print("games", len(index), dict(stats))


if __name__ == "__main__":
    main()
