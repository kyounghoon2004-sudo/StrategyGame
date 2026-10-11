"""CONTEXTUAL_BRAIN_S0B sealed probe set (built + sealed BEFORE any S0B output exists).

  python -m tools.contextual_brain.s0b_sealed_probe seal                 # build prompts, teacher check, jobs, seal
  <RL venv> -m tools.contract_sft.generate --adapter <A> --label <L> --jobs <SEALED>/jobs.json --out <SEALED>/gen_<L>.json --batch-size 8
  python -m tools.contextual_brain.s0b_sealed_probe analyze <gen file> <out name>

Two NEW base battles, unlike the old probe battle and unlike the S0/S0B corpus:
  F = flat 37x17 board, RED acting, 9-slot fronts 2 apart, hand-picked rosters;
  T = window of VALIDATION map BF05 (never in any training corpus), BLUE acting.
Probes (A vs B, one factor): mobility (F,T), visible enemy composition (F,T), friendly composition (F,T),
terrain/pathing = impassable wall between the fronts with only the outermost rows open (F,T); controls: identical resample (F), +0.25 attack nudge (T), far-rear forest (F).
No combat / game-mode probes (no learnable teacher signal for mode; combat not in scope of this gate).

PRE-REGISTERED GATE (fixed at seal time):
  Decisions are read from STRUCTURED fields only (P1 FIX area = main, P1 FLANK prefer.classes = maneuver,
  P1 FIX vs = target). For each relevant probe the teacher gives tA != tB on field f (verified at seal time).
  A relevant probe RESPONDS iff  P_B(f==tB) - P_A(f==tB) >= 0.5  AND one-sided Fisher exact p < 0.01.
  A control FLAGS iff the joint (main, maneuver, target) distribution differs with permutation p < 0.05.
  PASS iff >= 7/8 relevant respond, 0/3 controls flag, strict first-pass >= 0.97, doctrine==prompt-example
  rate < 0.10, class-name rate in prose (objective/purpose/intents) < 0.10.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import random
import re
import sys
from collections import Counter
from pathlib import Path

from tools.contract_sft import harness as H
from tools.contextual_brain.s0_corpus import LEGEND, army, region
from tools.contextual_brain.s0b_corpus import decisions, teacher

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
SEALED = ROOT / "artifacts" / "contextual_brain_s0b" / "sealed_probe"
N = 8
EXAMPLE_DOCTRINE = [0.6, 0.5, 0.6, 0.6, 0.7, 0.2]
CLASS_WORD = re.compile(r"\b(infantry|archers?|cavalry|spear\w*|scouts?|siege|conscripts?)\b", re.I)


def validation_terrain(fname):
    d = json.loads((ROOT / "data" / "battlefields" / "rl_canonical_v1" / fname).read_text(encoding="utf-8"))
    return {(d["q_min"] + i, d["r_min"] + j): LEGEND[ch] for i, row in enumerate(d["rows"]) for j, ch in enumerate(row) if ch != " "}


def battle(kind):
    if kind == "F":
        b = {"q_min": -18, "q_max": 18, "r_min": -8, "r_max": 8}
        terr = {(q, r): 0 for q in range(-18, 19) for r in range(-8, 9)}
        return {"kind": "F", "bounds": b, "terr": terr, "side": "red", "fronts": (1, -1), "hq_depth": 6,
                "rosters": {"red": (["cavalry", "infantry", "archer", "infantry", "scout", "spearman", "infantry", "archer", "cavalry"], [300, 420, 240, 400, 90, 380, 410, 250, 290]),
                            "blue": (["infantry", "spearman", "archer", "infantry", "scout", "infantry", "spearman", "archer", "infantry"], [410, 370, 240, 420, 90, 400, 360, 250, 400])},
                "rules": {}}
    allt = validation_terrain("bf05_ridge_valley.json")  # VALIDATION split map (Track B), never trained on
    b = {"q_min": -20, "q_max": 20, "r_min": -9, "r_max": 9}
    terr = {(q, r): allt.get((q, r), 0) for q in range(-20, 21) for r in range(-9, 10)}
    return {"kind": "T", "bounds": b, "terr": terr, "side": "blue", "fronts": (1, -1), "hq_depth": 6,
            "rosters": {"blue": (["archer", "cavalry", "infantry", "spearman", "scout", "infantry", "cavalry", "archer"], [240, 300, 410, 380, 90, 400, 290, 250]),
                        "red": (["cavalry", "infantry", "infantry", "archer", "spearman", "scout", "infantry", "cavalry"], [300, 420, 400, 240, 380, 90, 410, 290])},
            "rules": {}}


def spec_of(bt, sid):
    taken = set()
    rf, bf = bt["fronts"]
    red = army("R", "red", *bt["rosters"]["red"], rf, rf + bt["hq_depth"], bt["terr"], bt["bounds"], taken, +1)
    blue = army("B", "blue", *bt["rosters"]["blue"], bf, bf - bt["hq_depth"], bt["terr"], bt["bounds"], taken, -1)
    return {"scenario_id": sid, "side": bt["side"], "seed": 29, "red_forces": red, "blue_forces": blue,
            "primary_objective": "destroy_all_red", "turn_limit": 12, "bounds": bt["bounds"], "default_terrain": 0,
            "terrain_overrides": {f"{q},{r}": t for (q, r), t in bt["terr"].items() if t != 0},
            "rule_deltas": bt["rules"], "episode_meta": {"episode_id": f"sealed_{bt['kind']}", "family": "sealed", "split": "sealed"}}


def mod(bt, **kw):
    import copy
    v = copy.deepcopy(bt)
    for k, f in kw.items():
        f(v)
    return v


def reclass(fac, new, keep=("hq", "scout")):
    return lambda v: v["rosters"].__setitem__(fac, ([new if c not in keep else c for c in v["rosters"][fac][0]], v["rosters"][fac][1]))


def swap_class(fac, old, new):
    return lambda v: v["rosters"].__setitem__(fac, ([new if c == old else c for c in v["rosters"][fac][0]], v["rosters"][fac][1]))


def mp(**m):
    return lambda v: v["rules"].setdefault("base_mp", {}).update(m)


def wall_with_edge_gaps(v):
    """Impassable wall between the fronts on every row except the outermost row at each end."""
    rf, bf = v["fronts"]
    for q in range(bf + 1, rf):
        for r in range(v["bounds"]["r_min"] + 1, v["bounds"]["r_max"]):
            v["terr"][(q, r)] = 8


def probes():
    F, T = battle("F"), battle("T")
    return {  # id: (field, base, A, B)
        "SP_MOB_F": ("maneuver", F, F, mod(F, a=mp(cavalry=1.0, spear=4.0))),
        "SP_MOB_T": ("maneuver", T, T, mod(T, a=mp(cavalry=1.0, archer=4.0))),
        "SP_ENEMY_F": ("target", F, mod(F, a=reclass("blue", "infantry")), mod(F, a=reclass("blue", "cavalry"))),
        "SP_ENEMY_T": ("target", T, mod(T, a=reclass("red", "archer")), mod(T, a=reclass("red", "spearman"))),
        "SP_FRIEND_F": ("maneuver", F, F, mod(F, a=swap_class("red", "cavalry", "infantry"))),
        "SP_FRIEND_T": ("maneuver", T, T, mod(T, a=swap_class("blue", "cavalry", "spearman"))),
        "SP_TERR_F": ("main", F, F, mod(F, a=wall_with_edge_gaps)),
        "SP_TERR_T": ("main", T, T, mod(T, a=wall_with_edge_gaps)),
        "SC_NOISE_F": ("control", F, F, F),
        "SC_TINY_T": ("control", T, T, mod(T, a=lambda v: v["rules"].setdefault("class_stats", {}).update({"infantry": {"attack": 10.25}}))),
        "SC_REAR_F": ("control", F, F, mod(F, a=lambda v: [v["terr"].__setitem__((q, r), 2) for q in range(16, 19) for r in range(6, 9)])),
    }


def seal():
    os.environ["BRAIN_CONTRACT_MODE"] = "unalloc_v1"
    os.environ["BRAIN_CONTEXT_PACK"] = "v0"
    SEALED.mkdir(parents=True, exist_ok=True)
    P = probes()
    specs, keys = [], []
    for pid, (field, base, A, B) in P.items():
        sid = f"sealed_{base['kind']}"
        for var, bt in (("A", A), ("B", B)):
            specs.append(spec_of(bt, sid))
            keys.append((pid, var))
    res = H.build_prompts(specs)
    prompts, teach, jobs = {}, {}, []
    for (pid, var), r, s in zip(keys, res, specs):
        assert "error" not in r and "context" in json.loads(r["messages"][1]["content"]), r
        prompts[f"{pid}|{var}"] = {"messages": r["messages"], "spec": s}
        teach[f"{pid}|{var}"] = teacher(json.loads(r["messages"][1]["content"]), "sealed")[1]
    report = {}
    for pid, (field, *_rest) in P.items():
        ta, tb = teach[f"{pid}|A"], teach[f"{pid}|B"]
        same_prompt = prompts[f"{pid}|A"]["messages"] == prompts[f"{pid}|B"]["messages"]
        if field == "control":
            assert ta == tb, (pid, ta, tb)
            report[pid] = {"field": "control", "teacher": ta, "prompt_identical": same_prompt}
        else:
            assert ta[field] != tb[field] and not same_prompt, (pid, field, ta, tb)
            report[pid] = {"field": field, "tA": ta[field], "tB": tb[field], "teacher_A": ta, "teacher_B": tb}
        for var in "AB":
            for k in range(N):
                jobs.append({"job_id": f"{pid}|CTX|{var}|{k}", "prompt_id": f"{pid}|{var}",
                             "messages": prompts[f"{pid}|{var}"]["messages"], "seed": 9100 + k})
    random.Random(17).shuffle(jobs)
    (SEALED / "prompts.json").write_text(json.dumps(prompts, ensure_ascii=False), encoding="utf-8")
    (SEALED / "jobs.json").write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
    (SEALED / "EXPECTED.json").write_text(json.dumps(report, indent=1, default=str), encoding="utf-8")
    corpus = ROOT / "artifacts" / "contextual_brain_s0b" / "s0b_prompts.json"
    man = {"sealed_at": __import__("time").strftime("%Y-%m-%dT%H:%M:%S"), "n_probes": len(P), "n_jobs": len(jobs),
           "gate": __doc__.split("PRE-REGISTERED GATE (fixed at seal time):")[1].strip(),
           "sha256": {f: hashlib.sha256((SEALED / f).read_bytes()).hexdigest() for f in ("prompts.json", "jobs.json", "EXPECTED.json")},
           "maps": {"F": "flat 37x17", "T": "BF05 (validation split) window q-20..20 r-9..9"}}
    if corpus.exists():
        ch = {hashlib.sha256(json.dumps(p["messages"]).encode()).hexdigest() for p in json.loads(corpus.read_text(encoding="utf-8"))}
        man["corpus_prompt_overlap"] = len(ch & {hashlib.sha256(json.dumps(v["messages"]).encode()).hexdigest() for v in prompts.values()})
    (SEALED / "SEALED_MANIFEST.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
    print(json.dumps({"expected": {k: (v.get("tA"), v.get("tB")) for k, v in report.items()}, "manifest": man["sha256"]}, indent=1))
    return 0


# ------------------------------------------------------------------ analysis
def fisher_one_sided(a1, n1, b1, n2):
    """P(X >= b1) for the B group count under the hypergeometric null (B more often == tB than A)."""
    K, N_ = a1 + b1, n1 + n2
    return sum(math.comb(K, x) * math.comb(N_ - K, n2 - x) for x in range(b1, min(K, n2) + 1)) / math.comb(N_, n2)


def perm_joint(da, db, iters=4000):
    def dist(x, y):
        keys = {json.dumps(d, sort_keys=True) for d in x + y}
        cx, cy = Counter(json.dumps(d, sort_keys=True) for d in x), Counter(json.dumps(d, sort_keys=True) for d in y)
        return sum(abs(cx[k] / len(x) - cy[k] / len(y)) for k in keys)
    obs, pool, rng, hits = dist(da, db), da + db, random.Random(3), 0
    for _ in range(iters):
        rng.shuffle(pool)
        hits += dist(pool[:len(da)], pool[len(da):]) >= obs - 1e-12
    return (hits + 1) / (iters + 1)


def analyze():
    gen = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    name = sys.argv[3]
    exp = json.loads((SEALED / "EXPECTED.json").read_text(encoding="utf-8"))
    prompts = json.loads((SEALED / "prompts.json").read_text(encoding="utf-8"))
    seen, rows = set(), []
    for r in gen["rows"]:
        if r["job_id"] not in seen:
            seen.add(r["job_id"])
            rows.append(r)
    os.environ["BRAIN_CONTRACT_MODE"] = "unalloc_v1"
    val = {v["id"]: v for v in H.validate([{"id": r["job_id"], "text": r["text"], "scenario": prompts[r["prompt_id"]]["spec"]} for r in rows])}
    cells, docs = {}, []
    for r in rows:
        pid, _, var, _ = r["job_id"].split("|")
        try:
            d = json.loads(r["text"])
            dec = decisions(d)
            docs.append(d)
        except Exception:  # noqa: BLE001 - unparseable output counts as no decision
            dec = {"main": None, "maneuver": None, "target": None}
        cells.setdefault((pid, var), []).append(dec)
    out = {"model": gen.get("label"), "adapter_sha256": gen.get("adapter_sha256"), "relevant": {}, "controls": {}}
    for pid, e in exp.items():
        A, B = cells[(pid, "A")], cells[(pid, "B")]
        if e["field"] == "control":
            p = perm_joint(A, B)
            out["controls"][pid] = {"p": round(p, 4), "flagged": p < 0.05,
                                    "A": Counter(json.dumps(d, sort_keys=True) for d in A).most_common(2),
                                    "B": Counter(json.dumps(d, sort_keys=True) for d in B).most_common(2)}
            continue
        f, tb = e["field"], e["tB"]
        a1, b1 = sum(d[f] == tb for d in A), sum(d[f] == tb for d in B)
        p = fisher_one_sided(a1, len(A), b1, len(B))
        delta = b1 / len(B) - a1 / len(A)
        out["relevant"][pid] = {"field": f, "tA": e["tA"], "tB": tb, "P_A(tB)": round(a1 / len(A), 3), "P_B(tB)": round(b1 / len(B), 3),
                                "P_A(tA)": round(sum(d[f] == e["tA"] for d in A) / len(A), 3), "delta": round(delta, 3), "fisher_p": round(p, 5),
                                "responds": delta >= 0.5 and p < 0.01,
                                "A_values": Counter(str(d[f]) for d in A).most_common(3), "B_values": Counter(str(d[f]) for d in B).most_common(3)}
    strict = sum(v["strict_first_pass"] for v in val.values())
    prose = lambda d: " ".join([str(d.get("objective", ""))] + [str(p.get(k, "")) for p in d.get("phases") or [] for k in ("name", "purpose", "intent")]
                               + [str(m.get("intent", "")) for p in d.get("phases") or [] for m in p.get("missions") or []])
    out["strict_first_pass"] = [strict, len(val)]
    out["doctrine_example_rate"] = round(sum(d.get("doctrine") == EXAMPLE_DOCTRINE for d in docs) / max(1, len(docs)), 3)
    out["class_name_prose_rate"] = round(sum(bool(CLASS_WORD.search(prose(d))) for d in docs) / max(1, len(docs)), 3)
    out["n_relevant_responding"] = sum(v["responds"] for v in out["relevant"].values())
    out["n_controls_flagged"] = sum(v["flagged"] for v in out["controls"].values())
    out["checks"] = {"relevant_ge_7_of_8": out["n_relevant_responding"] >= 7, "controls_0": out["n_controls_flagged"] == 0,
                     "strict_ge_0.97": strict / max(1, len(val)) >= 0.97, "doctrine_copy_lt_0.10": out["doctrine_example_rate"] < 0.10,
                     "class_name_prose_lt_0.10": out["class_name_prose_rate"] < 0.10}
    (SEALED / name).write_text(json.dumps(out, indent=1, default=str), encoding="utf-8")
    print(json.dumps({k: out[k] for k in ("n_relevant_responding", "n_controls_flagged", "strict_first_pass", "doctrine_example_rate",
                                           "class_name_prose_rate", "checks")}, indent=1))
    for pid, v in out["relevant"].items():
        print(pid, v["field"], v["tA"], "->", v["tB"], "P_A(tB)", v["P_A(tB)"], "P_B(tB)", v["P_B(tB)"], "p", v["fisher_p"], "OK" if v["responds"] else "--")
    for pid, v in out["controls"].items():
        print(pid, "p", v["p"], "FLAG" if v["flagged"] else "ok")
    return 0


if __name__ == "__main__":
    sys.exit({"seal": seal, "analyze": analyze}[sys.argv[1]]())
