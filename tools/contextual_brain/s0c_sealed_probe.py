"""CONTEXTUAL_BRAIN_S0C sealed probe set (built + sealed BEFORE S0C training starts).

  python -m tools.contextual_brain.s0c_sealed_probe seal
  <RL venv> -m tools.contract_sft.generate --adapter <A> --label <L> --jobs <SEALED>/jobs.json --out <SEALED>/gen_<L>.json --batch-size 8
  python -m tools.contextual_brain.s0c_sealed_probe analyze <gen file> <out name>

New base battles (not the S0B sealed bases, not any corpus battle):
  F2 = flat 41x19 board, BLUE acting;  T2 = window of VALIDATION map BF06 (never used before), RED acting.
Relevant probes (each on F2 and T2, A vs B, one factor):
  MOB          fastest combat class rotated                    -> maneuver class changes
  NOMAN        no class outpaces the line any more             -> maneuver becomes None (scout stays fastest unit)
  ENEMY        visible enemy recomposed (incl. conscripts)     -> target changes
  TERR_ASYM    wall between the fronts, open rows moved from the north end to the south end -> main N -> S
  TERR_CENTER  wall (open at one end) removed                  -> main moves TO CENTER
Controls: identical resample (T2), +0.25 attack nudge (F2), far-rear forest (T2).
Expected decisions come from the S0C teacher (tools/contextual_brain/s0c_corpus.py); ambiguous ties are
rejected at seal time, so no probe hinges on an arbitrary tie-break.

PRE-REGISTERED GATE (fixed at seal time):
  Decisions are read from STRUCTURED fields only (P1 FIX area = main, P1 FLANK prefer.classes = maneuver,
  P1 FIX vs = target). A relevant probe RESPONDS iff P_B(f==tB) - P_A(f==tB) >= 0.5 AND one-sided Fisher p < 0.01.
  A control FLAGS iff the joint (main, maneuver, target) distribution differs with permutation p < 0.05.
  PASS iff >= 9/10 relevant respond, 0/3 controls flag, strict first-pass >= 0.97, doctrine==prompt-example
  rate < 0.10, class-name rate in prose < 0.10.
"""
from __future__ import annotations

import hashlib
import json
import os
import random
import sys
import time
from pathlib import Path

from tools.contract_sft import harness as H
from tools.contextual_brain import s0b_sealed_probe as SP
from tools.contextual_brain.s0b_sealed_probe import mod, mp, reclass, spec_of, swap_class, validation_terrain
from tools.contextual_brain.s0c_corpus import teacher

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
SEALED = ROOT / "artifacts" / "contextual_brain_s0c" / "sealed_probe"
N = 8
MIN_RELEVANT = 9


def battle(kind):
    if kind == "F2":
        b = {"q_min": -20, "q_max": 20, "r_min": -9, "r_max": 9}
        return {"kind": "F2", "bounds": b, "terr": {(q, r): 0 for q in range(-20, 21) for r in range(-9, 10)}, "side": "blue",
                "fronts": (1, -1), "hq_depth": 7, "rules": {},
                "rosters": {"blue": (["infantry", "archer", "cavalry", "infantry", "scout", "spearman", "infantry", "cavalry"], [420, 240, 300, 400, 90, 380, 410, 290]),
                            "red": (["conscript", "infantry", "archer", "conscript", "scout", "spearman", "infantry", "conscript"], [360, 410, 240, 380, 90, 370, 400, 350])}}
    allt = validation_terrain("bf06_river_crossing.json")  # VALIDATION split map, never used in any corpus or probe
    # Window chosen (before sealing, no model output seen) so all three sectors start open: on the map centre the
    # river/marsh already makes CENTER and SOUTH rough and every walled variant collapses to "all rough".
    b = {"q_min": -19, "q_max": 19, "r_min": -24, "r_max": -4}
    return {"kind": "T2", "bounds": b, "terr": {(q, r): allt.get((q, r), 0) for q in range(-19, 20) for r in range(-24, -3)}, "side": "red",
            "fronts": (1, -1), "hq_depth": 6, "rules": {},
            "rosters": {"red": (["spearman", "cavalry", "infantry", "archer", "scout", "infantry", "spearman", "cavalry"], [380, 300, 420, 240, 90, 400, 370, 290]),
                        "blue": (["infantry", "archer", "infantry", "cavalry", "scout", "conscript", "archer", "infantry"], [410, 240, 400, 300, 90, 360, 250, 420])}}


def wall_open(end, rows=3):
    """Impassable wall between the fronts on every row except `rows` rows at the north (low r) or south end."""
    def f(v):
        rf, bf = v["fronts"]
        lo, hi = v["bounds"]["r_min"], v["bounds"]["r_max"]
        keep = set(range(lo, lo + rows)) if end == "north" else set(range(hi - rows + 1, hi + 1))
        for q in range(bf + 1, rf):
            for r in range(lo, hi + 1):
                if r not in keep:
                    v["terr"][(q, r)] = 8
    return f


def probes():
    F, T = battle("F2"), battle("T2")
    return {
        "SP_MOB_F2": ("maneuver", F, F, mod(F, a=mp(cavalry=1.0, archer=4.0))),
        "SP_MOB_T2": ("maneuver", T, T, mod(T, a=mp(cavalry=1.0, spear=4.0))),
        "SP_NOMAN_F2": ("maneuver", F, F, mod(F, a=swap_class("blue", "cavalry", "infantry"))),
        "SP_NOMAN_T2": ("maneuver", T, T, mod(T, a=mp(cavalry=2.0))),
        "SP_ENEMY_F2": ("target", F, mod(F, a=reclass("red", "conscript")), mod(F, a=reclass("red", "cavalry"))),
        "SP_ENEMY_T2": ("target", T, mod(T, a=reclass("blue", "archer")), mod(T, a=reclass("blue", "infantry"))),
        "SP_TERR_ASYM_F2": ("main", F, mod(F, a=wall_open("north")), mod(F, a=wall_open("south"))),
        "SP_TERR_ASYM_T2": ("main", T, mod(T, a=wall_open("north")), mod(T, a=wall_open("south"))),
        "SP_TERR_CENTER_F2": ("main", F, mod(F, a=wall_open("north")), F),
        "SP_TERR_CENTER_T2": ("main", T, mod(T, a=wall_open("south")), T),
        "SC_NOISE_T2": ("control", T, T, T),
        "SC_TINY_F2": ("control", F, F, mod(F, a=lambda v: v["rules"].setdefault("class_stats", {}).update({"infantry": {"attack": 10.25}}))),
        "SC_REAR_T2": ("control", T, T, mod(T, a=lambda v: [v["terr"].__setitem__((q, r), 2) for q in range(17, 20) for r in range(-6, -3)])),
    }


def seal():
    os.environ["BRAIN_CONTRACT_MODE"] = "unalloc_v1"
    os.environ["BRAIN_CONTEXT_PACK"] = "v0"
    SEALED.mkdir(parents=True, exist_ok=True)
    P = probes()
    specs, keys = [], []
    for pid, (_field, base, A, B) in P.items():
        for var, bt in (("A", A), ("B", B)):
            specs.append(spec_of(bt, f"sealed_{base['kind']}"))
            keys.append((pid, var))
    res = H.build_prompts(specs)
    prompts, teach, jobs, report = {}, {}, [], {}
    for (pid, var), r, s in zip(keys, res, specs):
        assert "error" not in r and "context" in json.loads(r["messages"][1]["content"]), r
        prompts[f"{pid}|{var}"] = {"messages": r["messages"], "spec": s}
        plan, dec = teacher(json.loads(r["messages"][1]["content"]), "sealed")
        assert plan is not None, (pid, var, "teacher ambiguous", dec)
        teach[f"{pid}|{var}"] = dec
    for pid, (field, *_r) in P.items():
        ta, tb = teach[f"{pid}|A"], teach[f"{pid}|B"]
        same = prompts[f"{pid}|A"]["messages"] == prompts[f"{pid}|B"]["messages"]
        if field == "control":
            assert ta == tb, (pid, ta, tb)
            report[pid] = {"field": "control", "teacher": ta, "prompt_identical": same}
        else:
            assert ta[field] != tb[field] and not same, (pid, field, ta, tb)
            report[pid] = {"field": field, "tA": ta[field], "tB": tb[field], "teacher_A": ta, "teacher_B": tb}
        for var in "AB":
            for k in range(N):
                jobs.append({"job_id": f"{pid}|CTX|{var}|{k}", "prompt_id": f"{pid}|{var}",
                             "messages": prompts[f"{pid}|{var}"]["messages"], "seed": 9300 + k})
    random.Random(23).shuffle(jobs)
    (SEALED / "prompts.json").write_text(json.dumps(prompts, ensure_ascii=False), encoding="utf-8")
    (SEALED / "jobs.json").write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
    (SEALED / "EXPECTED.json").write_text(json.dumps(report, indent=1, default=str), encoding="utf-8")
    h = lambda m: hashlib.sha256(json.dumps(m).encode()).hexdigest()
    mine = {h(v["messages"]) for v in prompts.values()}
    overlap = {}
    for name, path in (("s0c_corpus", ROOT / "artifacts/contextual_brain_s0c_corpus/s0c_prompts.json"),
                       ("s0b_corpus", ROOT / "artifacts/contextual_brain_s0b/s0b_prompts.json")):
        overlap[name] = len(mine & {h(p["messages"]) for p in json.loads(path.read_text(encoding="utf-8"))})
    man = {"sealed_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "n_probes": len(P), "n_jobs": len(jobs),
           "gate": __doc__.split("PRE-REGISTERED GATE (fixed at seal time):")[1].strip(), "corpus_prompt_overlap": overlap,
           "sha256": {f: hashlib.sha256((SEALED / f).read_bytes()).hexdigest() for f in ("prompts.json", "jobs.json", "EXPECTED.json")},
           "maps": {"F2": "flat 41x19, BLUE acting", "T2": "BF06 (validation split) window q-19..19 r-24..-4, RED acting"}}
    (SEALED / "SEALED_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    print(json.dumps({"expected": {k: (v.get("tA"), v.get("tB")) for k, v in report.items()}, "overlap": overlap, "sha256": man["sha256"]}, indent=1))
    return 0


def analyze():
    SP.SEALED = SEALED  # same structured-decision analysis as the S0B sealed set, on this set's files
    SP.analyze()
    name = sys.argv[3]
    out = json.loads((SEALED / name).read_text(encoding="utf-8"))
    out["checks"].pop("relevant_ge_7_of_8", None)
    out["checks"]["relevant_ge_9_of_10"] = out["n_relevant_responding"] >= MIN_RELEVANT
    out["verdict"] = "PASS" if all(out["checks"].values()) else "BLOCKED"
    (SEALED / name).write_text(json.dumps(out, indent=1, default=str), encoding="utf-8")
    print("S0C_SEALED", out["n_relevant_responding"], "/ 10", out["checks"], out["verdict"])
    return 0


if __name__ == "__main__":
    sys.exit({"seal": seal, "analyze": analyze}[sys.argv[1]]())
