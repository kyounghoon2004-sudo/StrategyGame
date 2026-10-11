"""Rollout diagnostics (T0, Part B): horizon + continuation sensitivity.

On a SMALL diagnostic subset only, compare the primary training target
(horizon 8, SimpleAttackElseAdvancePolicy) against alternate horizons
(4, 12) and the seeded RandomLegalPolicy continuation. Alternate labels
never enter training data — this only measures ranking stability:
top-action agreement, Spearman rank correlation, mean |dQ|, and
preference divergence KL(P_primary || P_alt).
"""

from __future__ import annotations

import copy
import json
import math

from python_jev.training.dataset_gen import _eligible_actor_ids
from python_jev.training.policy_target import soft_targets_from_q
from python_jev.training.scenarios import generate_scenario, mission_context_for_side

DIAG_CONFIGS = (
    ("h4_simple", 4, "SimpleAttackElseAdvancePolicy", 7),
    ("h12_simple", 12, "SimpleAttackElseAdvancePolicy", 7),
    ("h8_random", 8, "RandomLegalPolicy", 7),
)
DIAG_VERSION = "rollout-diagnostics-v0.1.0"


def _ranks(values: list[float]) -> list[float]:
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def spearman(a: list[float], b: list[float]) -> float:
    n = len(a)
    if n < 2 or len(b) != n:
        return float("nan")
    ra, rb = _ranks(a), _ranks(b)
    ma, mb = sum(ra) / n, sum(rb) / n
    cov = sum((x - ma) * (y - mb) for x, y in zip(ra, rb))
    va = sum((x - ma) ** 2 for x in ra)
    vb = sum((y - mb) ** 2 for y in rb)
    if va <= 0 or vb <= 0:
        return float("nan")
    return cov / math.sqrt(va * vb)


def _kl(p: list[float], q: list[float]) -> float:
    total = 0.0
    for pi, qi in zip(p, q):
        if pi > 0:
            total += pi * (math.log(pi) - math.log(max(qi, 1e-12)))
    return total


def run_rollout_diagnostics(scenario_indices: list[int], profiles: dict[int, str],
                            max_states: int = 160) -> dict:
    """Replay collection on the given scenarios; compare target configs."""
    from python_sim.policies import SimpleAttackElseAdvancePolicy
    from python_sim.rollout.engine import CounterfactualEngine
    from python_sim.sim.battle import Battle
    from python_sim.skills.context import MissionContext

    primary = CounterfactualEngine.from_name("SimpleAttackElseAdvancePolicy", 8, 7)
    alts = {name: CounterfactualEngine.from_name(pol, h, seed)
            for name, h, pol, seed in DIAG_CONFIGS}
    driver = SimpleAttackElseAdvancePolicy()

    agg: dict[str, dict] = {name: {"agree": 0, "n": 0, "spearman": [],
                                  "abs_dq": [], "kl": []} for name, _, _, _ in DIAG_CONFIGS}
    states = 0
    for index in scenario_indices:
        if states >= max_states:
            break
        gen = generate_scenario(index)
        scenario = gen["scenario"]
        profile = profiles[index]
        battle = Battle(json.loads(json.dumps(scenario)), profile, seed=scenario["seed"])
        ctxs = {"blue": MissionContext(**mission_context_for_side(scenario, "blue")),
                "red": MissionContext(**mission_context_for_side(scenario, "red"))}
        for _turn in range(12):
            if states >= max_states or battle.evaluate_mission()["mission_status"] != "ongoing":
                break
            blue_ids, red_ids = _eligible_actor_ids(battle)
            for side, ids in (("blue", blue_ids), ("red", red_ids)):
                for actor_id in ids:
                    if states >= max_states:
                        break
                    u = battle.world.units.get(actor_id)
                    if u is None or u.action_ended:
                        continue
                    ev0 = primary.evaluate(battle, actor_id, ctxs[side])
                    if not any(ev0.legal_mask):
                        (driver.blue_action if side == "blue" else driver.red_action)(battle, actor_id)
                        continue
                    q0 = [ev0.branches[s].outcome_scalar for s in range(6)]
                    p0 = soft_targets_from_q(q0, list(ev0.legal_mask))
                    top0 = max((s for s in range(6) if ev0.legal_mask[s]),
                               key=lambda s: p0[s])
                    for name, _, _, _ in DIAG_CONFIGS:
                        ev = alts[name].evaluate(battle, actor_id, ctxs[side])
                        qa = [ev.branches[s].outcome_scalar for s in range(6)]
                        pa = soft_targets_from_q(qa, list(ev.legal_mask))
                        topa = max((s for s in range(6) if ev.legal_mask[s]),
                                   key=lambda s: pa[s])
                        shared = [s for s in range(6)
                                  if ev0.legal_mask[s] and ev.legal_mask[s]]
                        a = agg[name]
                        a["n"] += 1
                        a["agree"] += (topa == top0)
                        if shared:
                            a["abs_dq"].append(
                                sum(abs(qa[s] - q0[s]) for s in shared) / len(shared))
                            r = spearman([q0[s] for s in shared], [qa[s] for s in shared])
                            if not math.isnan(r):
                                a["spearman"].append(r)
                        a["kl"].append(_kl(p0, pa))
                    states += 1
                    (driver.blue_action if side == "blue" else driver.red_action)(battle, actor_id)
            battle.sim_end_turn()

    report = {"diagnostics_version": DIAG_VERSION, "states": states, "configs": {}}
    for name, a in agg.items():
        n = max(1, a["n"])
        report["configs"][name] = {
            "states": a["n"],
            "top_action_agreement": a["agree"] / n,
            "spearman_mean": (sum(a["spearman"]) / len(a["spearman"])) if a["spearman"] else None,
            "spearman_n": len(a["spearman"]),
            "mean_abs_dq": (sum(a["abs_dq"]) / len(a["abs_dq"])) if a["abs_dq"] else None,
            "mean_preference_kl": sum(a["kl"]) / n,
        }
    return report


__all__ = ["DIAG_CONFIGS", "DIAG_VERSION", "run_rollout_diagnostics", "spearman"]
