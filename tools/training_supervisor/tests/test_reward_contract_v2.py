"""REWARD_CONTRACT_V2 deterministic fixtures (no GPU, no Godot)."""
from __future__ import annotations

import copy
import glob
import itertools
import json
import os
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from tools.training_supervisor import marathon_wiring as W  # noqa: E402
from tools.training_supervisor import reward_contract as RC  # noqa: E402

V1, V2 = RC.REWARD_CONTRACT_V1, RC.REWARD_CONTRACT_V2


def _plan(**over):
    p1 = {"id": "P1", "name": "FIX", "groups": {"Center": ["R_INF_1", "R_INF_2"]},
          "missions": [{"task": "FIX", "area": "CENTER", "units": ["R_INF_1", "R_INF_2"],
                        "win": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}],
                        "stop": ["HQ_THREATENED"]},
                       {"task": "RECON", "area": "NORTH", "units": ["R_SCT_1"],
                        "win": [{"when": "REGION_REACHED", "region": "NORTH", "mission_id": "M02"}]}],
          "win": [{"when": "MISSION_COMPLETE", "mission_id": "M01"}],
          "lose": [{"when": "FORCE_STRENGTH_BELOW", "fraction": 0.4}],
          "abort": ["HQ_THREATENED"], "next": "P2", "on_fail": "HOLD",
          "reserve": ["R_CAV_1"], "release": [{"when": "TURNS_ELAPSED", "turns": 3, "since": 1}]}
    p2 = {"id": "P2", "name": "BREAK", "groups": {"Reserve": ["R_CAV_1"]},
          "missions": [{"task": "ATTACK", "area": "CENTER", "units": ["R_CAV_1"], "vs": "INFANTRY"}],
          "win": [{"when": "TURNS_ELAPSED", "turns": 6, "since": 1}], "next": "END"}
    doc = {"objective": "Destroy BLUE HQ.", "cadence": 4, "phases": [p1, p2],
           "branches": [{"id": "B1", "when": {"when": "HQ_THREATENED"}, "then": "RELEASE_RESERVE"}]}
    doc.update(over)
    return doc


def _txt(doc):
    return json.dumps(doc)


def _rec(outcome, path="GODOT_RESOLUTION", fault=""):
    r = {"rollout_id": "X", "side": "RED", "general_calls": 1, "retries": 0,
         "fallback_calls": 0, "fallback_plan_adopted": False, "queue_left": 0,
         "status_red": "READY", "fault_red": fault, "validator_code": fault,
         "consume_red": {"ok": True}, "plan_adopted": True, "path": path,
         "candidate_outcome": outcome, "candidate_reward": RC.TERMINAL_REWARDS[outcome]}
    if path == "STRICT_TERMINAL":
        r.update({"offender_side": "RED", "plan_adopted": False, "status_red": "FAILED",
                  "consume_red": {}, "terminal_reason": f"BRAIN_CONTRACT_FAILURE_RED_{fault}"})
    return r


COHERENT = _txt(_plan())
INCOHERENT = _txt(_plan(phases=[dict(_plan()["phases"][0], reserve=["R_INF_1"],),
                                _plan()["phases"][1]]))


# ------------------------------------------------------------------ required fixtures
def test_invalid_strict_output_is_minus_three_no_bonus():
    r = RC.compute_reward(_rec("LOSS", "STRICT_TERMINAL", "VP_INVALID_JSON"), "not json", V2)
    assert r["total_reward"] == -3.0
    assert r["contract_bonus"] == 0.0 and r["plan_coherence_bonus"] == 0.0
    assert r["contract_valid"] is False and r["plan_coherent"] is False
    assert r["strict_failure_type"] == "BRAIN_CONTRACT_FAILURE:VP_INVALID_JSON"


def test_invalid_strict_output_gets_no_bonus_even_if_text_is_clean_json():
    # e.g. VA_UNKNOWN_UNIT: syntactically perfect JSON, rejected by schema.
    r = RC.compute_reward(_rec("LOSS", "STRICT_TERMINAL", "VA_UNKNOWN_UNIT"), COHERENT, V2)
    assert r["total_reward"] == -3.0 and r["contract_bonus"] == 0.0


def test_valid_incoherent_loss():
    r = RC.compute_reward(_rec("LOSS"), INCOHERENT, V2)
    assert r["contract_valid"] is True and r["plan_coherent"] is False
    assert r["total_reward"] == -2.75
    assert any(v.startswith("P7_RESERVE_ASSIGNED") for v in r["coherence_violations"])


def test_valid_coherent_loss():
    r = RC.compute_reward(_rec("LOSS"), COHERENT, V2)
    assert r["coherence_violations"] == []
    assert r["total_reward"] == -2.50


def test_valid_coherent_draw():
    assert RC.compute_reward(_rec("DRAW"), COHERENT, V2)["total_reward"] == -1.50


def test_valid_coherent_win():
    assert RC.compute_reward(_rec("WIN"), COHERENT, V2)["total_reward"] == 5.50


def test_ordering_exhaustive():
    """Every reachable V2 value: LOSS < DRAW < WIN strictly, for all combos."""
    texts = {"coherent": COHERENT, "incoherent": INCOHERENT,
             "salvaged": COHERENT + "]", "garbage": "{oops"}
    vals = {"LOSS": [], "DRAW": [], "WIN": []}
    for outcome in vals:
        for t in texts.values():
            vals[outcome].append(RC.compute_reward(_rec(outcome), t, V2)["total_reward"])
    vals["LOSS"].append(RC.compute_reward(_rec("LOSS", "STRICT_TERMINAL", "VP_INVALID_JSON"),
                                          "x", V2)["total_reward"])
    assert max(vals["LOSS"]) == -2.5 and min(vals["LOSS"]) == -3.0
    assert max(vals["LOSS"]) < min(vals["DRAW"])
    assert max(vals["DRAW"]) < min(vals["WIN"])
    inv = RC.check_ordering_invariant()
    assert inv == {"best_loss": -2.5, "worst_draw": -2.0, "best_draw": -1.5, "worst_win": 5.0}


def test_repair_withholds_contract_bonus_but_keeps_terminal():
    # Godot's extract_json salvage (trailing ']' / fenced / prose) = repair.
    for t in (COHERENT + "]", "```json\n" + COHERENT + "\n```", "Plan: " + COHERENT):
        r = RC.compute_reward(_rec("DRAW"), t, V2)
        assert r["contract_valid"] is False and r["total_reward"] == -2.0
        assert r["strict_failure_type"] is None


def test_retry_or_fallback_withholds_contract_bonus():
    for patch in ({"retries": 1}, {"fallback_calls": 1}, {"fallback_plan_adopted": True},
                  {"general_calls": 2}, {"consume_red": {"ok": False}}):
        rec = _rec("DRAW")
        rec.update(patch)
        assert RC.compute_reward(rec, COHERENT, V2)["contract_bonus"] == 0.0, patch


# ------------------------------------------------------------------ coherence predicates
@pytest.mark.parametrize("mut,code", [
    (lambda d: d["phases"][0].update(next="P9"), "P2_NEXT_UNKNOWN"),
    (lambda d: d["phases"][1].update(next="P1"), "P3_NEXT_NOT_FORWARD"),
    (lambda d: d["phases"][0].update(next="P1"), "P3_NEXT_NOT_FORWARD"),
    (lambda d: d["phases"][1].update(next=""), "P4_LAST_PHASE_ADVANCES"),
    (lambda d: d["phases"][0].update(win=[{"when": "MISSION_COMPLETE", "mission_id": "M1"}]),
     "P5_MISSION_REF"),
    (lambda d: d["phases"][0]["missions"][1].update(units=["R_SCT_1", "R_INF_1"]), "P6_UNIT_IN_2"),
    (lambda d: d["phases"][0].update(reserve=["R_INF_2"]), "P7_RESERVE_ASSIGNED"),
    (lambda d: d["phases"][0].update(reserve=[]), "P8_RELEASE_WITHOUT_RESERVE"),
    (lambda d: [(p.pop("reserve", None), p.pop("release", None)) for p in d["phases"]],
     "P9_BRANCH_RELEASE_NO_RESERVE"),
    (lambda d: d["phases"][0].update(lose=list(d["phases"][0]["win"])), "P10_SELF_CONTRADICTION"),
    (lambda d: d["phases"][0]["groups"].update(Dup=["R_INF_1"]), "P11_UNIT_IN_2_GROUPS"),
])
def test_each_predicate(mut, code):
    d = _plan()
    mut(d)
    r = RC.compute_reward(_rec("DRAW"), _txt(d), V2)
    assert r["contract_valid"] is True
    assert any(v.startswith(code) for v in r["coherence_violations"]), r["coherence_violations"]
    assert r["total_reward"] == -1.75


def test_duplicate_key_is_incoherent():
    t = COHERENT[:-1] + ', "phases": ' + json.dumps(_plan()["phases"][1:]) + "}"
    r = RC.compute_reward(_rec("DRAW"), t, V2)
    assert r["contract_valid"] is True
    assert any(v.startswith("P1_DUPLICATE_KEYS") for v in r["coherence_violations"])


def test_coherence_is_not_a_tactics_judge():
    """Tactically opposite plans that are both internally consistent get the
    SAME bonus: passive all-HOLD vs all-out ATTACK on the HQ."""
    passive = _plan()
    for p in passive["phases"]:
        for m in p["missions"]:
            m["task"] = "HOLD"
            m.pop("vs", None)
    aggressive = _plan()
    for p in aggressive["phases"]:
        for m in p["missions"]:
            m["task"] = "ATTACK"
            m["target"] = "B_HQ_1"
    a = RC.compute_reward(_rec("DRAW"), _txt(passive), V2)
    b = RC.compute_reward(_rec("DRAW"), _txt(aggressive), V2)
    assert a["plan_coherence_bonus"] == b["plan_coherence_bonus"] == 0.25


def test_determinism():
    rs = [RC.compute_reward(_rec("LOSS"), INCOHERENT, V2) for _ in range(5)]
    assert all(r == rs[0] for r in rs)


# ------------------------------------------------------------------ versioning / persistence
def test_v1_semantics_unchanged():
    for outcome in ("WIN", "LOSS", "DRAW"):
        r = RC.compute_reward(_rec(outcome), COHERENT, V1)
        assert r["total_reward"] == RC.TERMINAL_REWARDS[outcome]
        assert isinstance(r["total_reward"], int)
        assert r["contract_valid"] is None and r["plan_coherent"] is None


def test_unknown_version_and_bad_terminal_refused():
    with pytest.raises(ValueError):
        RC.compute_reward(_rec("WIN"), COHERENT, "REWARD_CONTRACT_V3")
    bad = _rec("WIN")
    bad["candidate_reward"] = 5.5
    with pytest.raises(ValueError):
        RC.compute_reward(bad, COHERENT, V2)


def test_v2_group_fields_roundtrip_and_reconstruct():
    recs = [RC.compute_reward(_rec("LOSS"), INCOHERENT, V2),
            RC.compute_reward(_rec("DRAW"), COHERENT, V2)]
    g = json.loads(json.dumps(RC.group_reward_fields(recs, V2)))
    assert g["reward_contract_version"] == V2 and g["grpo_reward_field"] == "rewards"
    assert g["rewards"] == [-2.75, -1.5] and g["terminal_rewards"] == [-3, -2]
    for c, total in zip(g["reward_components"], g["rewards"]):
        assert c["terminal_reward"] + c["contract_bonus"] + c["plan_coherence_bonus"] == total
        for k in ("contract_valid", "plan_coherent", "strict_failure_type"):
            assert k in c


def test_wiring_version_boundary_and_rollout_arg():
    assert (W.REWARD_CONTRACT_V1, W.REWARD_CONTRACT_V2) == (V1, V2)
    assert W.reward_contract_for_iteration(W.REWARD_CONTRACT_V2_FIRST_ITERATION - 1) == V1
    assert W.reward_contract_for_iteration(W.REWARD_CONTRACT_V2_FIRST_ITERATION) == V2
    it = W.REWARD_CONTRACT_V2_FIRST_ITERATION
    specs = W.build_phase_specs(W.iteration_dir(it), "", "c", "T0053", "T0084", 1, [9, 10])
    a = specs["ROLLOUT"]["args"]
    assert a[a.index("--reward-contract") + 1] == V2
    old = W.build_phase_specs(W.iteration_dir(it - 1), "", "c", "T0053", "T0083", 1, [9, 10])
    a = old["ROLLOUT"]["args"]
    assert a[a.index("--reward-contract") + 1] == V1


def _write_manifest(itdir, version, rewards):
    ro = os.path.join(itdir, "rollout")
    os.makedirs(ro, exist_ok=True)
    groups = []
    for gi, rw in enumerate(rewards, start=1):
        seeds = [gi * 2, gi * 2 + 1]
        for s in seeds:
            open(os.path.join(ro, f"group{gi}_s{s}.txt"), "w").write("{}")
        g = {"group_index": gi, "seeds": seeds, "rewards": rw,
             "advantages": [0.7, -0.7], "informative": True}
        if version:
            g["reward_contract_version"] = version
        groups.append(g)
    man = {"status": "ROLLOUT_DONE", "groups_attempted": groups, "n_attempted": len(groups)}
    if version:
        man["reward_contract_version"] = version
    json.dump(man, open(os.path.join(ro, "rollout_manifest.json"), "w"))


def test_check_rollout_enforces_active_version(tmp_path):
    it = W.REWARD_CONTRACT_V2_FIRST_ITERATION
    d = str(tmp_path / f"iteration_{it:06d}")
    _write_manifest(d, V2, [[-2.75, -2.5], [-2.0, -1.75]])
    assert W.check_rollout(d)[0]
    _write_manifest(d, V1, [[-3, -2], [-2, -3]])
    ok, why = W.check_rollout(d)
    assert not ok and "reward_contract" in why
    _write_manifest(d, None, [[-3, -2], [-2, -3]])  # unversioned at/after V2 start
    assert not W.check_rollout(d)[0]
    d1 = str(tmp_path / f"iteration_{it - 1:06d}")
    _write_manifest(d1, None, [[-3, -2], [-2, -3]])  # V1-era manifests stay valid
    assert W.check_rollout(d1)[0]


# ------------------------------------------------------------------ promotion unchanged
@pytest.mark.parametrize("w,l,d,s,expect", [
    (3, 1, 0, 0, "PROMOTE"), (3, 1, 0, 1, "REJECT"), (2, 2, 0, 0, "REJECT"),
    (0, 0, 4, 0, "REJECT"), (1, 0, 3, 0, "PROMOTE"),
])
def test_promotion_rule_unchanged(tmp_path, w, l, d, s, expect):
    ev = tmp_path / "eval"
    ev.mkdir()
    json.dump({"wins": w, "losses": l, "draws": d, "strict_failures": s},
              open(ev / "eval_summary.json", "w"))
    assert W.build_eval_decision(str(tmp_path), "C", "K", "e")["decision"] == expect


def test_eval_check_still_requires_unshaped_terminal_reward(tmp_path):
    ev = tmp_path / "eval"
    ev.mkdir()
    m = {"winner": "DRAW", "candidate_result": "DRAW", "champion_result": "DRAW",
         "candidate_contract_valid": True, "terminal_reason": "TURN_CAP_6", "turns": 6,
         "seed": 1, "candidate_side": "RED", "candidate_reward": -1.5}
    json.dump({"status": "EVAL_DONE", "matches": [m] * 4, "decision": "REJECT"},
              open(ev / "eval_summary.json", "w"))
    ok, why = W.check_eval(str(tmp_path))
    assert not ok and "bad reward" in why


# ------------------------------------------------------------------ V1 artifacts readable
V1_IT = os.path.join(W.MARATHON_ROOT, "iterations", "iteration_000083")


@pytest.mark.skipif(not os.path.isdir(V1_IT), reason="live V1 artifacts not present")
def test_real_v1_artifacts_still_readable_and_v1_equivalent():
    ok, detail = W.check_rollout(V1_IT)
    assert ok, detail
    man = json.load(open(os.path.join(V1_IT, "rollout", "rollout_manifest.json"), encoding="utf-8"))
    assert "reward_contract_version" not in man  # V1 data is never rewritten
    for g in man["groups_attempted"]:
        for s, r in zip(g["seeds"], g["rewards"]):
            rec = json.load(open(glob.glob(os.path.join(
                V1_IT, "rollout", f"rollout_T*g{g['group_index']}s{s}.json"))[0], encoding="utf-8"))
            txt = open(os.path.join(V1_IT, "rollout", f"group{g['group_index']}_s{s}.txt"),
                       encoding="utf-8").read()
            assert RC.compute_reward(rec, txt, V1)["total_reward"] == r
            v2 = RC.compute_reward(rec, txt, V2)  # retro-analysis only; never persisted
            assert v2["terminal_reward"] == r
