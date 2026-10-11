"""Tactical scenario exam (T0, Part G): small deterministic benchmark suite.

Each case is an explicit tactical vignette with fixed geometry. Labels are
NOT human one-hot answers — every case derives legal Q[6] through the frozen
counterfactual engine, and JEV preference is compared against that tactical
structure (regret / epsilon-optimal / per-class). Exam states are never
training data.

Case id: exam_<class>_<theme>_<variant>. Deterministic (seeded jitter only).
"""

from __future__ import annotations

import copy
import random

from python_jev.training.evaluate import Q_EPSILON
from python_jev.training.inference import batch_from_projection, select_slot
from python_jev.training.policy_target import soft_targets_from_q

EXAM_VERSION = "tactical-exam-v0.1.0"
EXAM_SEED = 0xE4A4

BASE_SOLDIERS = {"infantry": 420, "spearman": 380, "cavalry": 300,
                 "archer": 250, "scout": 80, "hq": 280}

# (theme, mission, profile, terrain, enemies, friendlies)
# enemies/friendlies: (class, dq, dr, soldiers_multiplier); actor at origin.
THEMES = (
    ("open_duel", "destroy_all_red", "DEV_FLAT_ALL_INFO", "flat",
     (("infantry", 3, 0, 1.0),), ()),
    ("favored_attack", "destroy_all_red", "DEV_FLAT_ALL_INFO", "flat",
     (("archer", 1, 0, 0.7),), ()),
    ("threatened", "destroy_all_red", "DEV_FLAT_ALL_INFO", "flat",
     (("infantry", 1, 1, 1.2), ("cavalry", 2, -1, 1.2)), ()),
    ("supported", "destroy_all_red", "DEV_FLAT_ALL_INFO", "flat",
     (("infantry", 3, 0, 1.0),), (("spearman", -1, 1, 1.0),)),
    ("objective_push", "destroy_all_red", "DEV_FLAT_ALL_INFO", "flat",
     (("infantry", 5, 0, 1.0), ("archer", 6, 1, 1.0)), (("infantry", -2, 0, 1.0),)),
    ("retreat_ground", "survive_turns", "DEV_FLAT_ALL_INFO", "flat",
     (("cavalry", 2, 0, 1.3), ("infantry", 3, 1, 1.3)), ()),
    ("ranged_threat", "destroy_all_red", "TERRAIN_FULL_INFO", "forest",
     (("archer", 3, 0, 1.0), ("archer", 4, 1, 1.0)), (("infantry", -1, 0, 1.0),)),
    ("exposed_backline", "destroy_all_red", "TERRAIN_FULL_INFO", "forest",
     (("archer", 2, 1, 0.8), ("hq", 5, 0, 1.0)), ()),
    ("screen_line", "hold_hq", "DEV_FLAT_ALL_INFO", "flat",
     (("cavalry", 3, 0, 1.1),), (("archer", -2, 0, 1.0),)),
    ("outnumbered", "survive_turns", "DEV_FLAT_ALL_INFO", "flat",
     (("infantry", 2, 0, 1.0), ("spearman", 3, 1, 1.0), ("archer", 3, -1, 1.0)), ()),
    ("superior", "destroy_all_red", "TERRAIN_FULL_INFO", "forest",
     (("infantry", 3, 0, 0.8),),
     (("infantry", -1, 1, 1.0), ("archer", -2, 0, 1.0))),
    ("flank_opening", "destroy_all_red", "DEV_FLAT_ALL_INFO", "flat",
     (("archer", 1, 2, 0.9), ("infantry", 4, -1, 1.0)), (("cavalry", -2, 1, 1.0),)),
)

EXAM_CLASSES = ("infantry", "spearman", "cavalry", "archer", "scout")
CLS_UPPER = {"infantry": "INFANTRY", "spearman": "SPEARMAN", "cavalry": "CAVALRY",
             "archer": "ARCHER", "scout": "SCOUT"}


def build_exam_cases() -> list[dict]:
    """All exam cases: 5 classes x 12 themes = 60 deterministic vignettes."""
    cases = []
    for ci, cls in enumerate(EXAM_CLASSES):
        for ti, (theme, mission, profile, terrain, enemies, friendlies) in enumerate(THEMES):
            rng = random.Random(EXAM_SEED + ci * 100 + ti)
            aq = -22 + rng.randint(-1, 1)
            ar = rng.randint(-1, 1)
            forces = [
                {"id": "B_HQ_1", "class": "hq", "faction": "blue",
                 "q": aq - 4, "r": ar, "soldiers": BASE_SOLDIERS["hq"]},
                {"id": "B_ACT_1", "class": cls, "faction": "blue",
                 "q": aq, "r": ar, "soldiers": BASE_SOLDIERS[cls]},
                {"id": "R_HQ_1", "class": "hq", "faction": "red",
                 "q": aq + 7, "r": ar, "soldiers": BASE_SOLDIERS["hq"]},
            ]
            for i, (c, dq, dr, mult) in enumerate(enemies):
                if c == "hq":
                    continue
                forces.append({"id": f"R_E_{i}", "class": c, "faction": "red",
                               "q": aq + dq, "r": ar + dr,
                               "soldiers": max(40, int(BASE_SOLDIERS[c] * mult))})
            for i, (c, dq, dr, mult) in enumerate(friendlies):
                forces.append({"id": f"B_F_{i}", "class": c, "faction": "blue",
                               "q": aq + dq, "r": ar + dr,
                               "soldiers": max(40, int(BASE_SOLDIERS[c] * mult))})
            bounds = {"q_min": aq - 6, "q_max": aq + 9, "r_min": ar - 5, "r_max": ar + 5}
            overrides: dict[str, int] = {}
            if terrain == "forest":
                for _ in range(8):
                    fq, fr = rng.randint(aq - 3, aq + 5), rng.randint(ar - 4, ar + 4)
                    if (fq, fr) != (aq, ar):
                        overrides[f"{fq},{fr}"] = 2
            scenario = {
                "scenario_id": f"exam_{cls}_{theme}",
                "scenario_version": "0.1.0",
                "seed": EXAM_SEED + ci * 100 + ti,
                "mission_contract": {"primary_objective": mission, "turn_limit": 12},
                "map": {"bounds": bounds, "default_terrain": 0,
                        "terrain_overrides": overrides, "river_cells": []},
                "forces": forces,
            }
            cases.append({
                "case_id": f"exam_{cls}_{theme}",
                "actor_class": CLS_UPPER[cls],
                "theme": theme,
                "profile": profile,
                "actor_id": "B_ACT_1",
                "side": "blue",
                "scenario": scenario,
            })
    return cases


def run_exam(model, device, cases: list[dict] | None = None, mask_fn=None) -> dict:
    """Score the model on the exam (simulator-grounded Q comparison).

    mask_fn (F0 hook, additive): overrides the legality mask inside the
    counterfactual engine; None keeps the frozen exam path bit-identical.
    """
    from python_jev.training.projection import project_for_training
    from python_sim.observation.projector import ObservationProjector
    from python_sim.rollout.engine import CounterfactualEngine
    from python_sim.sim.battle import Battle
    from python_sim.skills import observation_safe_skill_mask
    from python_sim.skills.context import MissionContext

    cases = cases if cases is not None else build_exam_cases()
    engine = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 8, 11)
    per_case = []
    for case in cases:
        scenario = copy.deepcopy(case["scenario"])
        battle = Battle(scenario, case["profile"], seed=scenario["seed"])
        mc = scenario["mission_contract"]
        ctx = MissionContext(scenario_id=scenario["scenario_id"],
                             primary_objective=mc["primary_objective"],
                             turn_limit=mc["turn_limit"],
                             advance_anchor=(scenario["forces"][2]["q"],
                                             scenario["forces"][2]["r"]),
                             withdraw_anchor=(scenario["forces"][0]["q"],
                                              scenario["forces"][0]["r"]))
        ev = engine.evaluate(battle, case["actor_id"], ctx, mask_fn=mask_fn)
        legal = list(ev.legal_mask)
        if not any(legal):
            continue
        q = [ev.branches[s].outcome_scalar for s in range(6)]
        p_t = soft_targets_from_q(q, legal)
        proj = project_for_training(
            ObservationProjector(battle), case["side"], case["actor_id"], ctx)
        sel = select_slot(model, batch_from_projection(proj, legal), device)
        slot = sel["selected_slot"][0]
        q_best = max(q[s] for s in range(6) if legal[s])
        regret = max(0.0, q_best - q[slot])
        per_case.append({
            "case_id": case["case_id"],
            "actor_class": case["actor_class"],
            "theme": case["theme"],
            "profile": case["profile"],
            "selected_slot": slot,
            "selected_prob": sel["selected_prob"][0],
            "q_selected": q[slot],
            "q_best": q_best,
            "regret": regret,
            "epsilon_optimal": bool(q[slot] >= q_best - Q_EPSILON),
            "q_values": q,
        })
    return {"exam_version": EXAM_VERSION, "cases": per_case,
            "summary": summarize_exam(per_case)}


def summarize_exam(per_case: list[dict]) -> dict:
    import statistics

    def agg(rows):
        if not rows:
            return {"cases": 0}
        regrets = sorted(r["regret"] for r in rows)
        return {
            "cases": len(rows),
            "mean_regret": sum(regrets) / len(regrets),
            "median_regret": statistics.median(regrets),
            "p95_regret": regrets[min(len(regrets) - 1, int(0.95 * len(regrets)))],
            "epsilon_optimal_rate": sum(1 for r in rows if r["epsilon_optimal"]) / len(rows),
        }

    out = {"overall": agg(per_case), "per_class": {}, "per_theme": {}}
    for c in sorted({r["actor_class"] for r in per_case}):
        out["per_class"][c] = agg([r for r in per_case if r["actor_class"] == c])
    for t in sorted({r["theme"] for r in per_case}):
        out["per_theme"][t] = agg([r for r in per_case if r["theme"] == t])
    return out


__all__ = ["CLS_UPPER", "EXAM_CLASSES", "EXAM_SEED", "EXAM_VERSION", "THEMES",
           "build_exam_cases", "run_exam", "summarize_exam"]
