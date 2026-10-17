"""Teacher batches for the LOST relay games only (user, 2026-10-16): every relay segment of a game RED did not win; an external
agent (cold prompt, read from files) writes the plan that wins from that board. Wins are not included.
  python -m tools.synth_adv_v1.hz_relay_items   -> relay2/teacher/items.jsonl + batch_NNN.md (5 items each)
  python -m tools.synth_adv_v1.hz_relay_items --root relay3 --out relay3/teacher_p1 --cycles 1,2,3
relay3 (true relay) logs carry the game window, so a relay row is matched to its game by window + time (state match first).
Never deletes: refuses an --out folder that already has files.
"""
import argparse
import collections
import glob
import hashlib
import json
import os
from pathlib import Path

from tools.synth_adv_v1.hz_pipeline import HZ

R = HZ.parent / "relay2"
OUT = R / "teacher"
N = 5
LOST = {"NOT_ACHIEVED", "LOSS", "CAP", "INVALID"}


def fu(msgs):
    return next((m["content"] for m in msgs if m["role"] == "user"), "")


def key_of(msgs):
    return hashlib.sha1(fu(msgs).encode("utf-8")).hexdigest()[:12]


def digest(rows, T, H=10):
    out = []
    for t in range(T, T + H + 1, 2):
        c = rows.get(t)
        if not c or not c.get("state"):
            continue
        s = c["state"]
        hq = next((e for e in s.get("enemy_units", []) if e.get("class") == "HQ"), None)
        out.append({"turn": t, "red_units": len(s.get("my_units", [])), "blue_units": len(s.get("enemy_units", [])),
                    "blue_hq_fieldworks": int(hq.get("fortified") or 0) if hq else None,
                    "blue_hq_troops": hq.get("troops") if hq else None})
    return out


def main():
    global R, OUT
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="relay2")
    ap.add_argument("--out", default="")
    ap.add_argument("--cycles", default="", help="comma list of cycle numbers (default: all)")
    a = ap.parse_args()
    R = HZ.parent / a.root
    OUT = HZ.parent / a.out if a.out else R / "teacher"
    if OUT.exists() and any(OUT.iterdir()):
        raise SystemExit("refusing: %s already has files (never overwritten); pass a new --out" % OUT)
    OUT.mkdir(parents=True, exist_ok=True)
    want = {x.strip() for x in a.cycles.split(",") if x.strip()}
    items, unmatched = [], 0
    for cyc in sorted((d + os.sep for d in glob.glob(str(R / "c*")) if os.path.isdir(d) and os.path.basename(d)[1:].isdigit()
                       and (not want or os.path.basename(d)[1:] in want)), key=lambda d: int(os.path.basename(d.rstrip("/\\"))[1:])):
        for rf in glob.glob(cyc + "*_relays.jsonl"):
            name = os.path.basename(rf).replace("_relays.jsonl", "")
            arm = cyc + name
            gf = arm + "/games.jsonl"
            if not os.path.exists(gf):
                continue
            outcome = {}
            for line in open(gf, encoding="utf-8"):
                g = json.loads(line)
                outcome[g.get("tag") or "MANUAL_s%s" % g.get("seed")] = (g.get("kind") or g.get("outcome"), g.get("turn"), g.get("units"))
            game_rows = collections.defaultdict(dict)
            by_state = {}
            red_by_win = collections.defaultdict(list)
            for cf in glob.glob(arm + "/captures/red/calls.jsonl") + glob.glob(arm + "/captures/calls.jsonl"):
                for line in open(cf, encoding="utf-8"):
                    c = json.loads(line)
                    if c.get("request") == "VICTORY_COMMAND" and c.get("tag"):
                        if c.get("messages"):
                            game_rows[c["tag"]][int(c["turn"])] = c
                        red_by_win[c.get("window")].append((c["ts"], c["tag"]))
                        if c.get("state") is not None:
                            by_state[(int(c["turn"]), json.dumps(c["state"], sort_keys=True))] = c["tag"]
            for cf in glob.glob(arm + "/captures/red_think/calls.jsonl"):  # think proxy rows carry no tag: window + time -> tag
                for line in open(cf, encoding="utf-8"):
                    c = json.loads(line)
                    if c.get("state") is None or c.get("window") not in red_by_win:
                        continue
                    near = min(red_by_win[c["window"]], key=lambda x: abs(x[0] - c["ts"]))
                    by_state[(int(c["turn"]), json.dumps(c["state"], sort_keys=True))] = near[1]
            for line in open(rf, encoding="utf-8"):
                r = json.loads(line)
                tag = by_state.get((int(r["turn"]), json.dumps(r["state"], sort_keys=True)))
                if not tag and r.get("window") in red_by_win:  # relay3: the latest game of this window that started before
                    prior = [x for x in red_by_win[r["window"]] if x[0] <= r["ts"]]
                    tag = max(prior)[1] if prior else None
                if not tag:
                    unmatched += 1
                oc = outcome.get(tag)
                if not tag or not oc or oc[0] not in LOST:
                    continue
                T = int(r["turn"])
                try:
                    q = json.loads((r["response"] or "").split("</think>")[-1].strip())
                except Exception:  # noqa: BLE001
                    q = None
                u = oc[2]
                res = ("%s at turn %s (RED %s of %s units alive, BLUE %s of %s)" % (
                    oc[0], oc[1], u["red"]["alive"], u["red"]["start"], u["blue"]["alive"], u["blue"]["start"])) if u else str(oc[0])
                items.append({"id": "%s/%s/%s/%d" % (os.path.basename(cyc.rstrip("/\\")), name, tag, T), "tag": tag, "turn": T,
                              "packet": r["relay_messages"][-1]["content"], "qwen": q, "result": res,
                              "future": digest(game_rows[tag], T)})
    (OUT / "items.jsonl").write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items), encoding="utf-8")
    head = open(Path(__file__).with_name("hz_relay_teacher_prompt.md"), encoding="utf-8").read()
    for b in range(0, len(items), N):
        name = "batch_%03d" % (b // N)
        md = [head]
        for it in items[b:b + N]:
            md.append("\n---\n## ITEM %s\n### THE BOARD (what the student commander was shown at this turn)\n%s\n"
                      "### THE STUDENT'S ANSWER AT THIS TURN (JSON; may lack a plan)\n%s\n"
                      "### WHAT HAPPENED NEXT IN THIS GAME (hindsight; the student never sees this)\n"
                      "result of the whole game: %s\nevery 2nd turn from here: %s\n"
                      % (it["id"], it["packet"], json.dumps(it["qwen"], ensure_ascii=False), it["result"],
                         json.dumps(it["future"], ensure_ascii=False)))
        md.append("\n---\nOUTPUT: write the JSON array to answers_%s.json in this same folder, then validate that it parses.\n" % name)
        (OUT / (name + ".md")).write_text("".join(md), encoding="utf-8")
    print("unmatched relay rows", unmatched)
    print("items", len(items), "batches", (len(items) + N - 1) // N,
          dict(collections.Counter(i["id"].split("/")[1].split("_")[0] for i in items)))


if __name__ == "__main__":
    main()
