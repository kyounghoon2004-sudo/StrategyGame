"""Synthetic commander SFT v2: validate authored answers, build branch batches, judge them, write SFT rows.

  python -m tools.synth_sft_v2.crosscheck validate <authored part .jsonl>      -> prints problems (format check only)
  python -m tools.synth_sft_v2.crosscheck prepare <batch> <authored part .jsonl> -> xcheck/<batch>/branches.jsonl
        (one control per situation = the teacher's answer at T, unless already judged; plus every variant), and
        appends the part to authored.jsonl
  (run: python -m tools.synth_sft_v2.branch xcheck/<batch>/branches.jsonl xcheck/<batch> --windows 6 --slot 6 ...)
  python -m tools.synth_sft_v2.crosscheck judge <batch> [<batch> ...]          -> controls.jsonl, crosscheck.jsonl,
        synth_rows.json (rebuilt from every PASS)

Authored row: {"sid": "<game>__t<T>", "variant": "v1", "pattern": "<tag>", "answer": "<JSON text>"}
Facts at T+H from the branch's own record: snapshot at (T, RED to act) vs the final snapshot.
PASS (rule as given): RED HQ alive, outcome != BLUE_WIN, (kill - loss) >= control's, soldier margin
(BLUE % lost - RED % lost) >= control's - 5; an outcome RED_WIN passes.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from tools.synth_sft_v2.bank import OUT as SYN

H = 5
XC = SYN / "xcheck"
VERBS = {"ATTACK", "MOVE", "HOLD", "RAID", "FORTIFY"}


def situations(ids=None):
    out = {}
    for line in open(SYN / "situations.jsonl", encoding="utf-8"):
        r = json.loads(line)
        if ids is None or r["id"] in ids:
            out[r["id"]] = r
    return out


def jl(p: Path):
    return [json.loads(x) for x in p.read_text(encoding="utf-8").splitlines() if x.strip()] if p.exists() else []


def units_at(r):
    op = json.loads(r["opening"])
    if not r["now"]:
        return {u["id"] for u in op["my_units"]}, {u["id"] for u in op["enemy_units"]}
    now = json.loads(r["now"])
    return {x.split()[0] for x in now["my_units"]}, {x.split()[0] for x in now["enemy_units"]}


def check(r, text):
    """-> list of problems ([] = valid)."""
    try:
        a = json.loads(text)
    except ValueError as e:
        return ["not JSON: %s" % e]
    if not isinstance(a, dict) or set(a) - {"orders", "plan"} or not isinstance(a.get("orders"), dict):
        return ["bad top-level keys"]
    probs = []
    if "plan" in a and (not isinstance(a["plan"], str) or len(a["plan"]) > 300):
        probs.append("plan > 300 chars")
    mine, blue = units_at(r)
    for u, o in a["orders"].items():
        if u not in mine:
            probs.append("%s not a live RED unit" % u)
            continue
        d = o.get("do")
        if d not in VERBS:
            probs.append("%s bad verb %s" % (u, d))
            continue
        allowed = {"do"} | ({"target"} if d == "ATTACK" else {"to"} if d == "MOVE" else {"target", "back_to"} if d == "RAID" else set())
        if set(o) - allowed or (allowed - {"do"}) - set(o):
            probs.append("%s keys %s" % (u, sorted(o)))
        if d == "RAID" and "_CAV_" not in u:
            probs.append("%s RAID by non-cavalry" % u)
        if "target" in o and o["target"] != "ENEMY_HQ" and o["target"] not in blue:
            probs.append("%s target %s not a live BLUE unit" % (u, o["target"]))
        for k in ("to", "back_to"):
            if k in o:
                t = o[k]
                ok = (isinstance(t, list) and len(t) == 2 and all(isinstance(x, int) for x in t)) or t in ("MY_HQ", "ENEMY_HQ") \
                    or t in mine or t in blue
                if not ok:
                    probs.append("%s bad %s %s" % (u, k, t))
    if json.dumps(a, sort_keys=True) == json.dumps(json.loads(r["teacher_answer"]), sort_keys=True):
        probs.append("identical to the teacher answer")
    return probs


def cmd_validate(part):
    rows = jl(Path(part))
    sit = situations({x["sid"] for x in rows})
    bad = 0
    for x in rows:
        if x["sid"] not in sit:
            print(x["sid"], x["variant"], "unknown situation")
            bad += 1
            continue
        p = check(sit[x["sid"]], x["answer"])
        if p:
            bad += 1
            print(x["sid"], x["variant"], "; ".join(p))
    print("%d rows, %d with problems" % (len(rows), bad))
    return bad


def bid(sid, variant=None):
    return ("C__%s" % sid) if variant is None else ("V__%s__%s" % (sid, variant))


def cmd_prepare(batch, part):
    if cmd_validate(part):
        sys.exit("fix the problems first")
    rows = jl(Path(part))
    sit = situations({x["sid"] for x in rows})
    done_controls = {c["sid"] for c in jl(SYN / "controls.jsonl")}
    d = XC / batch
    d.mkdir(parents=True, exist_ok=True)
    br, seen = [], set()
    for x in rows:
        s = sit[x["sid"]]
        if x["sid"] not in done_controls and x["sid"] not in seen:
            br.append({"id": bid(x["sid"]), "game": s["game"], "turn": s["turn"], "horizon": H, "answer": s["teacher_answer"]})
            seen.add(x["sid"])
        br.append({"id": bid(x["sid"], x["variant"]), "game": s["game"], "turn": s["turn"], "horizon": H, "answer": x["answer"]})
    (d / "branches.jsonl").write_text("".join(json.dumps(b) + "\n" for b in br), encoding="utf-8")
    have = {(a["sid"], a["variant"]) for a in jl(SYN / "authored.jsonl")}
    with open(SYN / "authored.jsonl", "a", encoding="utf-8") as f:
        for x in rows:
            if (x["sid"], x["variant"]) not in have:
                f.write(json.dumps({"sid": x["sid"], "variant": x["variant"], "pattern": x["pattern"], "answer": x["answer"],
                                    "batch": batch}) + "\n")
    print("batch %s: %d branches (%d controls)" % (batch, len(br), len(seen)))


def facts(gfile: Path, turn: int):
    g = json.loads(gfile.read_text(encoding="utf-8"))
    if g.get("error") or not g.get("record"):
        return None
    snaps = g["record"]["snapshots"]
    s0 = next((s for s in snaps if s.get("turn") == turn and s.get("to_act") == "red"), None)
    s1 = snaps[-1]
    if s0 is None:
        return None

    def side(s, sd):
        us = [u for u in s["units"] if u[1] == sd]
        return {"n": sum(1 for u in us if u[2] != "hq"), "sol": sum(u[5] for u in us), "hq": any(u[2] == "hq" for u in us)}
    a = {sd: side(s0, sd) for sd in ("red", "blue")}
    b = {sd: side(s1, sd) for sd in ("red", "blue")}
    kill, loss = a["blue"]["n"] - b["blue"]["n"], a["red"]["n"] - b["red"]["n"]
    bp = 100.0 * (a["blue"]["sol"] - b["blue"]["sol"]) / max(1, a["blue"]["sol"])
    rp = 100.0 * (a["red"]["sol"] - b["red"]["sol"]) / max(1, a["red"]["sol"])
    attacks = sum(1 for x in g["record"]["actions"]["red"] + g["record"]["actions"]["blue"]
                  if x.get("do") in ("ATTACK", "RAID") and x.get("turn", 0) >= turn)
    return {"kill": kill, "loss": loss, "blue_pct": round(bp, 1), "red_pct": round(rp, 1), "margin": round(bp - rp, 1),
            "red_hq": b["red"]["hq"], "outcome": g.get("outcome"), "end_turn": g.get("turn"), "attacks": attacks}


def verdict(c, v):
    if v["outcome"] == "RED_WIN":
        return True, "red_win"
    if v["outcome"] == "BLUE_WIN" or not v["red_hq"]:
        return False, "blue_win_or_hq"
    if v["kill"] - v["loss"] < c["kill"] - c["loss"]:
        return False, "kill_loss"
    if v["margin"] < c["margin"] - 5:
        return False, "margin"
    return True, "ok"


def cmd_judge(batches):
    controls = {c["sid"]: c for c in jl(SYN / "controls.jsonl")}
    judged = {(c["sid"], c["variant"]) for c in jl(SYN / "crosscheck.jsonl")}
    authored = {(a["sid"], a["variant"]): a for a in jl(SYN / "authored.jsonl")}
    new_c, new_x, missing = [], [], []
    for batch in batches:
        d = XC / batch
        brs = jl(d / "branches.jsonl")
        for b in brs:
            if b["id"].startswith("C__"):
                sid = b["id"][3:]
                if sid in controls:
                    continue
                f = d / "games" / (b["id"] + ".json")
                fx = facts(f, b["turn"]) if f.exists() else None
                if fx is None:
                    missing.append(b["id"])
                    continue
                controls[sid] = dict(fx, sid=sid, batch=batch)
                new_c.append(controls[sid])
        for b in brs:
            if not b["id"].startswith("V__"):
                continue
            sid, var = b["id"][3:].rsplit("__", 1)
            if (sid, var) in judged:
                continue
            f = d / "games" / (b["id"] + ".json")
            fx = facts(f, b["turn"]) if f.exists() else None
            if fx is None or sid not in controls:
                missing.append(b["id"])
                continue
            c = controls[sid]
            ok, why = verdict(c, fx)
            req = d / "requests" / (b["id"] + ".json")
            new_x.append({"sid": sid, "variant": var, "pattern": authored.get((sid, var), {}).get("pattern", ""),
                          "batch": batch, "pass": ok, "why": why, "control": {k: c[k] for k in fx}, "candidate": fx,
                          "no_contact": c["attacks"] == 0 and fx["attacks"] == 0, "request_saved": req.exists()})
            judged.add((sid, var))
    with open(SYN / "controls.jsonl", "a", encoding="utf-8") as f:
        f.writelines(json.dumps(c) + "\n" for c in new_c)
    with open(SYN / "crosscheck.jsonl", "a", encoding="utf-8") as f:
        f.writelines(json.dumps(x) + "\n" for x in new_x)
    allx = jl(SYN / "crosscheck.jsonl")
    print("new controls %d, new judged %d (pass %d), missing %d %s" % (
        len(new_c), len(new_x), sum(x["pass"] for x in new_x), len(missing), missing[:10]))
    build_rows(allx, authored)


def build_rows(allx, authored):
    passed = [x for x in allx if x["pass"]]
    sit = situations({x["sid"] for x in passed})
    rows = []
    for x in passed:
        s, a = sit[x["sid"]], authored[(x["sid"], x["variant"])]
        rows.append({"messages": s["messages"], "completion": a["answer"], "game": s["game"], "turn": s["turn"],
                     "tier": s["tier"], "army_size": s["army_size"], "source": "synthetic_v2", "pattern": a["pattern"],
                     "variant": x["variant"], "crosscheck": {k: x[k] for k in ("why", "control", "candidate", "no_contact")}})
    tmp = SYN / "synth_rows.json.tmp"
    tmp.write_text(json.dumps(rows), encoding="utf-8")
    tmp.replace(SYN / "synth_rows.json")
    print("synth_rows.json: %d rows (all judged %d, pass rate %.1f%%)" % (len(rows), len(allx), 100.0 * len(rows) / max(1, len(allx))))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "validate":
        cmd_validate(sys.argv[2])
    elif cmd == "prepare":
        cmd_prepare(sys.argv[2], sys.argv[3])
    elif cmd == "judge":
        cmd_judge(sys.argv[2:])
