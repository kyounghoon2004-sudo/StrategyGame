"""Synthetic commander SFT v2: validate authored answers, build branch batches, judge them, write SFT rows.

  python -m tools.synth_sft_v2.crosscheck validate <authored part .jsonl>      -> prints problems (format check only)
  python -m tools.synth_sft_v2.crosscheck prepare <batch> <authored part .jsonl> -> xcheck/<batch>/branches.jsonl
        (one control per situation = the teacher's answer at T, unless already judged; plus every variant), and
        appends the part to authored_v3.jsonl
  (run: python -m tools.synth_sft_v2.branch xcheck/<batch>/branches.jsonl xcheck/<batch> --windows 6 --slot 6 ...)
  python -m tools.synth_sft_v2.crosscheck judge <batch> [<batch> ...]          -> controls_v3.jsonl, crosscheck_v3.jsonl,
        synth_rows_v3_verified.json (rebuilt from every PASS)

Authored row: {"sid": "<game>__t<T>", "variant": "v1", "pattern": "<tag>", "answer": "<JSON text>"}
Facts at T+H from the branch's own record: snapshot at (T, RED to act) vs the final snapshot.
PASS (rule as given): RED HQ alive, outcome != BLUE_WIN, (kill - loss) >= control's, soldier margin
(BLUE % lost - RED % lost) >= control's - 5; an outcome RED_WIN passes.
"""
from __future__ import annotations

import json
import sys
from functools import lru_cache
from pathlib import Path

from tools.synth_sft_v3.view import OUT as SYN
from tools.synth_sft_v3.grind_bank import decode_answer

H = 5
XC = SYN / "xcheck"
VERBS = {"ATTACK", "MOVE", "HOLD", "RAID", "FORTIFY"}


def situations(ids=None):
    out = {}
    for name in ("situations_grind.jsonl", "situations_late_v3.jsonl"):
        path = SYN / name
        if not path.exists():
            continue
        for line in open(path, encoding="utf-8"):
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
    except (ValueError, TypeError) as e:
        return ["not JSON: %s" % e]
    if not isinstance(a, dict) or set(a) - {"orders", "plan"} or not isinstance(a.get("orders"), dict):
        return ["bad top-level keys"]
    probs = []
    if int(r["turn"]) == 1 and not a.get("plan"):
        probs.append("T1 requires plan")
    if not a["orders"]:
        probs.append("empty candidate")
    if "plan" in a and (not isinstance(a["plan"], str) or len(a["plan"]) > 300):
        probs.append("plan > 300 chars")
    mine, blue = units_at(r)
    op = json.loads(r['opening'])
    radius = op.get('map_radius')
    for u, o in a["orders"].items():
        if not isinstance(o, dict):
            probs.append("%s order is not an object" % u)
            continue
        if u not in mine:
            probs.append("%s not a live RED unit" % u)
            continue
        d = o.get("do")
        if not isinstance(d,str) or d not in VERBS:
            probs.append("%s bad verb %s" % (u, d))
            continue
        allowed = {"do"} | ({"target"} if d == "ATTACK" else {"to"} if d == "MOVE" else {"target", "back_to"} if d == "RAID" else set())
        if set(o) - allowed or (allowed - {"do"}) - set(o):
            probs.append("%s keys %s" % (u, sorted(o)))
        if d == "RAID" and "_CAV_" not in u:
            probs.append("%s RAID by non-cavalry" % u)
        if "target" in o and (not isinstance(o['target'],str) or o["target"] != "ENEMY_HQ" and o["target"] not in blue):
            probs.append("%s target %s not a live BLUE unit" % (u, o["target"]))
        if o.get('target') == 'ENEMY_HQ' and not any('_HQ_' in bid for bid in blue):
            probs.append('%s target ENEMY_HQ is not alive' % u)
        for k in ("to", "back_to"):
            if k in o:
                t = o[k]
                ok = (isinstance(t, list) and len(t) == 2 and all(type(x) is int for x in t)) or (isinstance(t, str) and (t in ("MY_HQ", "ENEMY_HQ") or t in mine or t in blue))
                if not ok:
                    probs.append("%s bad %s %s" % (u, k, t))
                elif isinstance(t,list) and radius is not None and (abs(t[0])+abs(t[1])+abs(t[0]+t[1]))//2 > radius:
                    probs.append('%s %s outside map' % (u,k))
    if json.dumps(a, sort_keys=True) == json.dumps(decode_answer(r["teacher_answer"]), sort_keys=True):
        probs.append("identical to the teacher answer")
    if not probs and not actionable(r, a):
        probs.append("no actionable changed order")
    return probs


def actionable(r, answer):
    from tools.synth_sft_v3.view import parse_now
    _, mine, enemies = parse_now(r)
    def normalized(order):
        if not isinstance(order, dict):
            return order
        result = dict(order)
        for key in ('target','to','back_to'):
            if result.get(key) == 'MY_HQ':
                result[key] = next((u for u,v in mine.items() if v['cls']=='HQ'),'MY_HQ')
            elif result.get(key) == 'ENEMY_HQ':
                result[key] = next((u for u,v in enemies.items() if v['cls']=='HQ'),'ENEMY_HQ')
        return result
    for uid, order in answer.get("orders", {}).items():
        if uid not in mine or not isinstance(order, dict):
            continue
        if normalized(order) == normalized(r.get("standing_orders", {}).get(uid, {"do": "HOLD"})):
            continue
        verb = order.get("do")
        if verb in ("ATTACK", "RAID") and order.get("target") in enemies:
            if enemies[order["target"]]["cls"] != "HQ":
                return True
        if verb == "MOVE":
            target = order.get("to")
            if isinstance(target, list) and tuple(target) != tuple(mine[uid]["pos"]):
                return True
            if isinstance(target, str) and target in mine | enemies and tuple((mine | enemies)[target]["pos"]) != tuple(mine[uid]["pos"]):
                return True
            hq = next((v for v in mine.values() if v['cls']=='HQ'), None)
            if target == "MY_HQ" and hq and tuple(hq['pos']) != tuple(mine[uid]['pos']):
                return True
        if verb == "FORTIFY" and not mine[uid].get("fort"):
            return True
        if verb == "HOLD":
            prior=r.get("standing_orders", {}).get(uid, {})
            if prior.get('do')=='MOVE':
                return True
            if prior.get('do') in ('ATTACK','RAID') and normalized(prior).get('target') in enemies:
                return True
    return False


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
    done_controls = {c["sid"] for c in jl(SYN / "controls_v3.jsonl")}
    d = XC / batch
    d.mkdir(parents=True, exist_ok=True)
    br, seen = [], set()
    for x in rows:
        s = sit[x["sid"]]
        if x["sid"] not in done_controls and x["sid"] not in seen:
            br.append({"id": bid(x["sid"]), "game": s["game"], "turn": s["turn"], "horizon": (8 if s["turn"] >= 30 else 5), "answer": s["teacher_answer"]})
            seen.add(x["sid"])
        br.append({"id": bid(x["sid"], x["variant"]), "game": s["game"], "turn": s["turn"], "horizon": (8 if s["turn"] >= 30 else 5), "answer": x["answer"]})
    (d / "branches.jsonl").write_text("".join(json.dumps(b) + "\n" for b in br), encoding="utf-8")
    have = {(a["sid"], a["variant"]) for a in jl(SYN / "authored_v3.jsonl")}
    with open(SYN / "authored_v3.jsonl", "a", encoding="utf-8") as f:
        for x in rows:
            if (x["sid"], x["variant"]) not in have:
                f.write(json.dumps(dict(x, batch=batch)) + "\n")
    print("batch %s: %d branches (%d controls)" % (batch, len(br), len(seen)))


def facts(gfile: Path, turn: int, horizon=None):
    try:
        g = json.loads(gfile.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if g.get("error") or g.get('fault') or g.get('strict_fault') or g.get('outcome') not in ('RED_WIN','BLUE_WIN','CAP') or not g.get("record"):
        return None
    record = g['record']
    if not isinstance(record,dict) or not isinstance(record.get('actions'),dict):
        return None
    if any(not isinstance(record['actions'].get(side),list) for side in ('red','blue')):
        return None
    snaps = record.get("snapshots", [])
    if not snaps:
        return None
    if any(not isinstance(s,dict) or not isinstance(s.get('units'),list) or any(not isinstance(u,list) or len(u)<6 for u in s['units']) for s in snaps):
        return None
    s0 = next((s for s in snaps if s.get("turn") == turn and s.get("to_act") == "red"), None)
    s1 = snaps[-1]
    horizon_outcome = g.get('outcome')
    if s0 is None:
        return None
    # V2 cap semantics execute RED at T+H and record the final snapshot at
    # the following BLUE-to-act turn. Early actual victories are valid endpoints.
    if horizon is not None:
        cap=min(60,int(turn)+int(horizon))
        endpoint=cap+1
        if int(g.get('turn',0)) >= endpoint:
            # A native60 game still running after this endpoint was ongoing at H.
            # Select BLUE-to-act immediately after RED at T+H (V2 cap endpoint).
            boundary=next((s for s in snaps if s.get('turn')==endpoint and s.get('to_act')=='blue'),None)
            after_horizon_actions=any(x.get('turn',0)>cap for side in ('red','blue') for x in record['actions'][side])
            if boundary is None:
                # A genuine terminal immediately after RED at cap may have only
                # the final snapshot. Beyond-H actions require a real boundary.
                if int(g.get('turn',0))!=endpoint or after_horizon_actions:
                    return None
            else:
                s1=boundary
            terminal_within_horizon=(int(g.get('turn',0))==endpoint and not after_horizon_actions
                                     and sorted(snaps[-1]['units'])==sorted(s1['units']))
            horizon_outcome=g.get('outcome') if terminal_within_horizon else 'CAP'
        elif g.get('outcome')=='CAP' and (g.get('turn_cap')!=cap or g.get('turn')!=endpoint):
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
                  if x.get("do") in ("ATTACK", "RAID") and x.get("turn", 0) >= turn
                  and (horizon is None or x.get('turn',0)<=cap))
    return {"kill": kill, "loss": loss, "blue_pct": round(bp, 1), "red_pct": round(rp, 1), "margin": round(bp - rp, 1),
            "red_hq": b["red"]["hq"], "outcome": horizon_outcome, "end_turn": s1.get('turn'), "attacks": attacks}


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


@lru_cache(maxsize=4096)
def original_units(game_file, turn):
    """Immutable source snapshot cache; hidden facts only validate execution."""
    try:
        g=json.loads(Path(game_file).read_text(encoding='utf-8'))
        s=next(s for s in g['record']['snapshots'] if s.get('turn')==turn and s.get('to_act')=='red')
        return tuple(tuple(u) for u in sorted(s['units'],key=lambda u:u[0]))
    except (OSError,ValueError,KeyError,StopIteration,TypeError):
        return None


def source_state_exact(bank, game, turn, replay_file):
    try:
        original=original_units(bank[game]['game_file'],turn)
        r=json.loads(Path(replay_file).read_text(encoding='utf-8'))
        s=next(s for s in r['record']['snapshots'] if s.get('turn')==turn and s.get('to_act')=='red')
        actual=tuple(tuple(u) for u in sorted(s['units'],key=lambda u:u[0]))
        return original is not None and original==actual
    except (OSError,ValueError,KeyError,StopIteration,TypeError):
        return False


def cmd_judge(batches, completed_only=False):
    controls = {c["sid"]: c for c in jl(SYN / "controls_v3.jsonl")}
    judged = {(c["sid"], c["variant"]) for c in jl(SYN / "crosscheck_v3.jsonl") if c.get("status") != "TECHNICAL"}
    authored = {(a["sid"], a["variant"]): a for a in jl(SYN / "authored_v3.jsonl")}
    source_situations = situations({sid for sid,var in authored})
    bank=json.loads((SYN/'bank_all_v3.json').read_text(encoding='utf-8'))
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
                fx = facts(f, b["turn"], b['horizon']) if f.exists() else None
                situation=source_situations.get(sid)
                req=d/'requests'/(b['id']+'.json')
                try:
                    control_messages=json.loads(req.read_text(encoding='utf-8'))
                except (OSError,ValueError):
                    control_messages=None
                if situation is None or control_messages!=situation['messages']:
                    fx=None
                if fx is not None and not source_state_exact(bank,b['game'],b['turn'],f):
                    fx=None
                if fx is None:
                    if completed_only:
                        continue
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
            fx = facts(f, b["turn"], b['horizon']) if f.exists() else None
            if fx is None or sid not in controls:
                if completed_only:
                    continue
                missing.append(b["id"])
                new_x.append({"sid": sid, "variant": var, "pattern": authored.get((sid, var), {}).get("pattern", ""), "batch": batch, "status": "TECHNICAL", "pass": False, "why": "missing_or_invalid_game_or_control", "game_file": str(f)})
                continue
            c = controls[sid]
            a = authored.get((sid,var))
            situation = source_situations.get(sid)
            req = d / "requests" / (b["id"] + ".json")
            try:
                replay_messages = json.loads(req.read_text(encoding='utf-8'))
            except (OSError, ValueError):
                replay_messages = None
            if situation is None or replay_messages != situation['messages']:
                if completed_only:
                    continue
                missing.append(b['id'])
                new_x.append({'sid': sid, 'variant': var, 'pattern': a.get('pattern','') if a else '', 'batch': batch,
                              'status': 'TECHNICAL', 'pass': False, 'why': 'replay_prompt_mismatch', 'request_file': str(req)})
                continue
            if not source_state_exact(bank,b['game'],b['turn'],f):
                if completed_only:
                    continue
                missing.append(b['id'])
                new_x.append({'sid':sid,'variant':var,'pattern':a.get('pattern','') if a else '',
                              'batch':batch,'status':'TECHNICAL','technical_class':'TECHNICAL_SOURCE_STATE',
                              'pass':False,'why':'replay_source_state_mismatch','game_file':str(f)})
                continue
            problems = check(situation,a['answer']) if a is not None and situation is not None else ['missing authored candidate or situation']
            ok, why = (False,'invalid_or_noop_answer') if problems else verdict(c, fx)
            new_x.append({"sid": sid, "variant": var, "pattern": authored.get((sid, var), {}).get("pattern", ""),
                          "batch": batch, "pass": ok, "why": why, "control": {k: c[k] for k in fx}, "candidate": fx,
                          "no_contact": c["attacks"] == 0 and fx["attacks"] == 0, "request_saved": req.exists()})
            if problems:
                new_x[-1]['answer_problems'] = problems
            new_x[-1]["status"] = "PASS" if ok else "FAIL"
            judged.add((sid, var))
    with open(SYN / "controls_v3.jsonl", "a", encoding="utf-8") as f:
        f.writelines(json.dumps(c) + "\n" for c in new_c)
    with open(SYN / "crosscheck_v3.jsonl", "a", encoding="utf-8") as f:
        f.writelines(json.dumps(x) + "\n" for x in new_x)
    allx = jl(SYN / "crosscheck_v3.jsonl")
    print("new controls %d, new judged %d (pass %d), missing %d %s" % (
        len(new_c), len(new_x), sum(x["pass"] for x in new_x), len(missing), missing[:10]))
    build_rows(allx, authored)


def build_rows(allx, authored):
    latest = {(x["sid"], x["variant"]): x for x in allx}
    passed = [x for x in latest.values() if x["pass"] and not x.get("no_contact") and x.get("status") != "TECHNICAL"]
    sit = situations({x["sid"] for x in passed})
    rows = []
    seen = set()
    for x in passed:
        s, a = sit[x["sid"]], authored[(x["sid"], x["variant"])]
        answer = json.loads(a["answer"])
        key = (s["id"], json.dumps(answer, sort_keys=True))
        if key in seen or check(s, a["answer"]):
            continue
        seen.add(key)
        rows.append({"messages": s["messages"], "completion": answer, "game": s["game"], "turn": s["turn"],
                     "mission": "collapse70", "tier": s["tier"], "army_size": s["army_size"], "source": "synth_v3", "pattern": a["pattern"],
                     "variant": x["variant"], "crosscheck": {k: x[k] for k in ("why", "control", "candidate", "no_contact")}})
    tmp = SYN / "synth_rows_v3_verified.json.tmp"
    tmp.write_text(json.dumps(rows), encoding="utf-8")
    tmp.replace(SYN / "synth_rows_v3_verified.json")
    print("synth_rows_v3_verified.json: %d rows (all judged %d, pass rate %.1f%%)" % (len(rows), len(allx), 100.0 * len(rows) / max(1, len(allx))))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "validate":
        cmd_validate(sys.argv[2])
    elif cmd == "prepare":
        cmd_prepare(sys.argv[2], sys.argv[3])
    elif cmd == "judge":
        cmd_judge(sys.argv[2:])

