"""Deterministic battle-scenario specs for CONTRACT_SFT_V1.

RLPROOF_RED / RLPROOF_BLUE reproduce the exact validation fixtures of
tools/rl_proof_episode.gd / rl_sym_eval.gd (one-side forces, same map),
so historical prompt-A outputs are re-validated exactly as RL judged them.

generate(seed) builds a varied scenario (roster composition/size, unit
strengths, positions -> regions, mission contract, acting side) that the
PRODUCTION packet builder turns into a real INITIAL prompt via
tools/contract_sft_harness.gd.
"""
from __future__ import annotations

import random
from typing import Any, Dict, List

RLPROOF_BOUNDS = {"q_min": -34, "q_max": -14, "r_min": -8, "r_max": 8}
_RLPROOF = [("R_ARC_1", "archer", -6, 260), ("R_ARC_2", "archer", -5, 260),
            ("R_CAV_1", "cavalry", -4, 300), ("R_CAV_2", "cavalry", -3, 300),
            ("R_HQ_1", "hq", -2, 300), ("R_INF_1", "infantry", -1, 450),
            ("R_INF_2", "infantry", 0, 450), ("R_SCT_1", "scout", 1, 260),
            ("R_SPE_1", "spearman", 2, 400), ("R_SPE_2", "spearman", 3, 400)]


def _rlproof_forces(side: str) -> List[Dict[str, Any]]:
    out = []
    for uid, cls, r, n in _RLPROOF:
        if side == "red":
            out.append({"id": uid, "class": cls, "faction": "red", "q": -29, "r": r, "soldiers": n})
        else:
            out.append({"id": uid.replace("R_", "B_"), "class": cls, "faction": "blue",
                        "q": -31, "r": r, "soldiers": n})
    return out


RLPROOF_RED = {"scenario_id": "rlproof_red", "side": "red", "seed": 29,
               "red_forces": _rlproof_forces("red"), "blue_forces": [],
               "primary_objective": "destroy_all_red", "turn_limit": 12,
               "bounds": RLPROOF_BOUNDS}
RLPROOF_BLUE = {"scenario_id": "rlproof_blue", "side": "blue", "seed": 29,
                "red_forces": [], "blue_forces": _rlproof_forces("blue"),
                "primary_objective": "destroy_all_red", "turn_limit": 12,
                "bounds": RLPROOF_BOUNDS}

CLASS_TAG = {"infantry": "INF", "archer": "ARC", "cavalry": "CAV", "spearman": "SPE",
             "scout": "SCT", "siege": "SIE", "conscript": "CON"}
SOLDIERS = {"infantry": (360, 480), "archer": (180, 280), "cavalry": (240, 320),
            "spearman": (320, 420), "scout": (60, 120), "siege": (140, 220),
            "conscript": (300, 420)}
OBJECTIVES = [("destroy_all_red", 12), ("destroy_all_red", 8), ("survive_turns", 10),
              ("hold_hq", 8)]
BOUNDS = {"q_min": -22, "q_max": 22, "r_min": -10, "r_max": 10}


def _army(rng: random.Random, prefix: str, faction: str, q_lo: int, q_hi: int,
          r_lo: int = -9, r_hi: int = 9, counts=None, sparse: bool = False) -> List[Dict[str, Any]]:
    counts = counts or {"infantry": rng.randint(1, 3), "archer": rng.randint(0, 2),
                        "cavalry": rng.randint(0, 3), "spearman": rng.randint(0, 2),
                        "scout": rng.randint(0, 1), "siege": 1 if rng.random() < 0.15 else 0,
                        "conscript": 1 if rng.random() < 0.2 else 0}
    units = []
    used = set()
    for cls, n in counts.items():
        nums = sorted(rng.sample(range(1, 19), n)) if sparse else range(1, n + 1)
        for k in nums:
            for _ in range(50):
                q, r = rng.randint(q_lo, q_hi), rng.randint(r_lo, r_hi)
                if (q, r) not in used:
                    break
            used.add((q, r))
            lo, hi = SOLDIERS[cls]
            units.append({"id": f"{prefix}_{CLASS_TAG[cls]}_{k}", "class": cls, "faction": faction,
                          "q": q, "r": r, "soldiers": rng.randrange(lo, hi + 1, 10)})
    hq_q = q_hi if prefix == "R" else q_lo
    for _ in range(50):
        hr = rng.randint(-4, 4)
        if (hq_q, hr) not in used:
            break
    units.append({"id": f"{prefix}_HQ_1", "class": "hq", "faction": faction, "q": hq_q,
                  "r": hr, "soldiers": 300})
    return sorted(units, key=lambda u: u["id"])


def generate_variant(seed: int, mode: str) -> Dict[str, Any]:
    """Round-3 / OOD families (base generate() stays byte-identical for R1).

    mode:
      no_cav    friendly side has ZERO cavalry (the CAV_1 lure has no referent)
      no_inf2   friendly side has exactly one infantry
      thin      3-5 friendly formations
      sparse    non-sequential numbering (e.g. INF_4, INF_11, CAV_7)
      big       11-15 friendly formations incl. siege/conscript, sparse numbering
    """
    rng = random.Random(seed * 104729 + 911)
    half = rng.choice([1, 1, 1, 2, 3, 5, 8])
    depth = rng.randint(1, 4)
    rc, rs = rng.randint(-3, 3), rng.randint(3, 8)
    r_lo, r_hi = max(-10, rc - rs), min(10, rc + rs)
    side = "red" if seed % 2 == 0 else "blue"

    def counts_for(friendly: bool):
        c = {"infantry": rng.randint(1, 3), "archer": rng.randint(0, 2), "cavalry": rng.randint(0, 3),
             "spearman": rng.randint(0, 2), "scout": rng.randint(0, 1),
             "siege": 1 if rng.random() < 0.15 else 0, "conscript": 1 if rng.random() < 0.2 else 0}
        if not friendly:
            return c
        if mode == "no_cav":
            c["cavalry"] = 0
            c["spearman"] = max(c["spearman"], 1)
        elif mode == "no_inf2":
            c["infantry"] = 1
        elif mode == "thin":
            c = {"infantry": 1, "archer": rng.randint(0, 1), "cavalry": rng.randint(0, 1),
                 "spearman": rng.randint(0, 1), "scout": rng.randint(0, 1), "siege": 0, "conscript": 0}
        elif mode == "big":
            c = {"infantry": rng.randint(3, 4), "archer": rng.randint(2, 3), "cavalry": rng.randint(1, 3),
                 "spearman": rng.randint(2, 3), "scout": 1, "siege": 1, "conscript": rng.randint(0, 1)}
        return c
    if mode == "no_cav_sparse":  # round 4: same failure trigger, larger roster space
        mode = "no_cav"
        sparse = True
    else:
        sparse = mode in ("sparse", "big") or (mode == "thin" and rng.random() < 0.5)
    rf = counts_for(side == "red")
    bf = counts_for(side == "blue")
    red = _army(rng, "R", "red", half, min(20, half + depth), r_lo, r_hi, rf, sparse and side == "red")
    blue = _army(rng, "B", "blue", max(-20, -half - depth), -half, r_lo, r_hi, bf, sparse and side == "blue")
    obj, limit = OBJECTIVES[rng.randrange(len(OBJECTIVES))]
    return {"scenario_id": f"csft3_{mode}_s{seed:05d}", "side": side, "seed": seed,
            "red_forces": red, "blue_forces": blue, "primary_objective": obj, "turn_limit": limit,
            "bounds": dict(BOUNDS), "family": mode}


def generate(seed: int) -> Dict[str, Any]:
    rng = random.Random(seed * 7919 + 17)
    # Formation lines; front distance 2..3 gives fog contact (vision ~2-4
    # hexes), larger distances give a fogged opening. ~half in contact.
    half = rng.choice([1, 1, 1, 2, 3, 5, 8])
    depth = rng.randint(1, 4)
    rc, rs = rng.randint(-3, 3), rng.randint(3, 8)
    r_lo, r_hi = max(-10, rc - rs), min(10, rc + rs)
    red = _army(rng, "R", "red", half, min(20, half + depth), r_lo, r_hi)
    blue = _army(rng, "B", "blue", max(-20, -half - depth), -half, r_lo, r_hi)
    obj, limit = OBJECTIVES[rng.randrange(len(OBJECTIVES))]
    return {"scenario_id": f"csft_s{seed:05d}", "side": "red" if seed % 2 == 0 else "blue",
            "seed": seed, "red_forces": red, "blue_forces": blue,
            "primary_objective": obj, "turn_limit": limit, "bounds": dict(BOUNDS)}


def roster_signature(spec: Dict[str, Any]) -> str:
    side = spec["side"]
    units = spec["red_forces"] if side == "red" else spec["blue_forces"]
    return side + ":" + ",".join(sorted(u["id"] for u in units))
