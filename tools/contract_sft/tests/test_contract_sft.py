"""CONTRACT_SFT_V1 unit tests (no GPU, no Godot)."""
from __future__ import annotations

import json
import os
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from tools.contract_sft import harness as H  # noqa: E402
from tools.contract_sft import repair as RP  # noqa: E402
from tools.contract_sft import scenarios as S  # noqa: E402

ART = os.path.join(ROOT, "artifacts", "contract_sft_v1")
ROSTER = ["R_INF_1", "R_INF_2", "R_CAV_1", "R_HQ_1", "R_SCT_1"]


def _plan(**over):
    d = {"objective": "Destroy BLUE HQ.", "phases": [
        {"id": "P1", "groups": {"G": ["R_INF_1"]},
         "missions": [{"task": "FIX", "area": "CENTER", "units": ["R_INF_1"]}],
         "next": "P2", "reserve": ["R_CAV_1"], "release": ["HQ_THREATENED"]},
        {"id": "P2", "missions": [{"task": "ATTACK", "area": "CENTER", "units": ["R_CAV_1"]}],
         "next": "END"}]}
    d.update(over)
    return d


def test_trailing_bracket_is_cut_not_invented():
    raw = json.dumps(_plan()) + "]"
    t, notes = RP.repair(raw, ROSTER)
    assert json.loads(t) == _plan() and "cut_trailing" in notes


def test_fence_and_prose_stripped():
    for raw in ("```json\n" + json.dumps(_plan()) + "\n```", "Here is the plan: " + json.dumps(_plan())):
        t, _ = RP.repair(raw, ROSTER)
        assert json.loads(t) == _plan()


def test_duplicate_phases_key_merged_not_lost():
    p = _plan()
    raw = json.dumps({"objective": "x", "phases": p["phases"][:1]})[:-1] + ',"phases":' + \
        json.dumps(p["phases"][1:]) + "}"
    t, _ = RP.repair(raw, ROSTER)
    assert [x["id"] for x in json.loads(t)["phases"]] == ["P1", "P2"]


def test_unknown_unit_and_trigger_dropped():
    p = _plan()
    p["phases"][0]["missions"][0]["units"] = ["R_INF_1", "R_CAV_9"]
    p["phases"][0]["missions"][0]["stop"] = ["HQ_DESTROYED", "HQ_THREATENED"]
    t, notes = RP.repair(json.dumps(p), ROSTER)
    m = json.loads(t)["phases"][0]["missions"][0]
    assert m["units"] == ["R_INF_1"] and m["stop"] == ["HQ_THREATENED"]
    assert any(n.startswith("drop_unknown_unit") for n in notes)


def test_reserve_plus_mission_fixed_by_unreserving():
    p = _plan()
    p["phases"][0]["reserve"] = ["R_INF_1", "R_CAV_1"]
    t, notes = RP.repair(json.dumps(p), ROSTER)
    assert json.loads(t)["phases"][0]["reserve"] == ["R_CAV_1"]
    assert any(n.startswith("P7_") for n in notes)


def test_double_assignment_is_structural_grade_c():
    p = _plan()
    p["phases"][0]["missions"].append({"task": "ATTACK", "units": ["R_INF_1"]})
    _, notes = RP.repair(json.dumps(p), ROSTER)
    from tools.contract_sft.build_dataset import STRUCTURAL
    assert any(n.split(":")[0].split("@")[0] in STRUCTURAL for n in notes)


def test_mission_ref_normalized_or_dropped():
    p = _plan()
    p["phases"][0]["win"] = [{"when": "MISSION_COMPLETE", "mission_id": "M1"},
                             {"when": "REGION_REACHED", "region": "NORTH", "mission_id": "P1M7"}]
    d = json.loads(RP.repair(json.dumps(p), ROSTER)[0])
    assert d["phases"][0]["win"][0]["mission_id"] == "M01" and "mission_id" not in d["phases"][0]["win"][1]


def test_last_phase_next_closed():
    p = _plan()
    p["phases"][1]["next"] = ""
    assert json.loads(RP.repair(json.dumps(p), ROSTER)[0])["phases"][1]["next"] == "END"


def test_root_close_truncate_is_exact_prefix():
    s = json.dumps(_plan())
    assert H.root_close_truncate(s + "]}") == s
    assert H.root_close_truncate(s) == s
    assert H.root_close_truncate("Plan: " + s) == "Plan: " + s  # not startable -> unchanged
    tricky = '{"objective":"a } b","phases":[]}' + "]"
    assert H.root_close_truncate(tricky) == tricky[:-1]


def test_strict_requires_production_pass_and_direct_json():
    good = {"extract_nonempty": True, "production_pass": True}
    s = json.dumps(_plan())
    assert H.strict_metrics(s, good)["strict_first_pass"] is True
    assert H.strict_metrics(s + "]", good)["strict_first_pass"] is False
    assert H.strict_metrics(s + "]", good)["category"] == "EXTRA_TEXT_SALVAGED"
    bad = {"extract_nonempty": True, "production_pass": False, "fault": "VA_COND"}
    assert H.strict_metrics(s, bad)["category"] == "VALIDATOR:VA_COND"


def test_scenarios_deterministic_and_valid_shape():
    a, b = S.generate(123), S.generate(123)
    assert a == b
    ids = [u["id"] for u in a["red_forces"] + a["blue_forces"]]
    assert len(ids) == len(set(ids)) and "R_HQ_1" in ids and "B_HQ_1" in ids


@pytest.mark.skipif(not os.path.exists(os.path.join(ART, "prompts", "PROMPTS_MANIFEST.json")),
                    reason="prompts not built")
def test_persisted_prompt_sets_have_no_leakage():
    m = json.load(open(os.path.join(ART, "prompts", "PROMPTS_MANIFEST.json")))
    assert m["leakage"]["heldout_prompts_identical_to_train"] == 0
    assert m["leakage"]["heldout_roster_signatures_in_train"] == 0
    assert m["leakage"]["heldout_rosters_equal_rl_A"] == 0


@pytest.mark.skipif(not os.path.exists(os.path.join(ART, "dataset", "sft_rows.jsonl")),
                    reason="dataset not built")
def test_persisted_dataset_all_targets_production_valid_and_no_heldout():
    held = {p["prompt_id"] for p in json.load(open(os.path.join(ART, "prompts", "heldout.json"),
                                                   encoding="utf-8"))}
    rows = [json.loads(l) for l in open(os.path.join(ART, "dataset", "sft_rows.jsonl"), encoding="utf-8")]
    assert rows
    for r in rows:
        assert r["validation"]["strict_first_pass"] and r["validation"]["plan_coherent"], r["row_id"]
        assert r["grade"] in ("A", "B") and r["prompt_id"] not in held
        assert json.loads(r["target"])  # exactly one JSON object


@pytest.mark.skipif(not os.path.exists(os.path.join(ART, "augment", "remap_v1_rows.jsonl")),
                    reason="augmentation not built")
def test_persisted_remap_augmentation_invariants():
    import re
    uid = re.compile(r"\b[RB]_[A-Z]{2,3}_\d+\b")
    P = {p["prompt_id"]: p for p in json.load(open(os.path.join(ART, "augment", "remap_v1_prompts.json"),
                                                   encoding="utf-8"))}
    held = {p["roster_signature"] for p in json.load(open(os.path.join(ART, "prompts", "heldout.json"),
                                                          encoding="utf-8"))}
    src = {}
    for l in open(os.path.join(ART, "dataset", "sft_rows.jsonl"), encoding="utf-8"):
        r = json.loads(l)
        src["R1:" + r["row_id"]] = r["target"]
    for l in open(os.path.join(ART, "intake", "B03R1_intake_v1.jsonl"), encoding="utf-8"):
        r = json.loads(l)
        src[f"B03R1:{r['provenance']['scenario_id']}_{r['provenance']['variant_id']}"] = r["target"]
    rows = [json.loads(l) for l in open(os.path.join(ART, "augment", "remap_v1_rows.jsonl"), encoding="utf-8")]
    assert rows
    for r in rows:
        fm, em = r["friendly_map"], r["enemy_map"]
        assert len(set(fm.values())) == len(fm) and len(set(em.values())) == len(em)  # bijective
        assert all(k.rsplit("_", 1)[0] == v.rsplit("_", 1)[0] for k, v in {**fm, **em}.items())  # side+class kept
        inv = {v: k for k, v in {**fm, **em}.items()}
        assert uid.sub(lambda m: inv.get(m.group(0), m.group(0)), r["target"]) == src[r["src_id"]]
        p = P[r["prompt_id"]]
        own = p["side"][0]
        roster = set(p["roster"])
        assert all(u in roster for u in uid.findall(r["target"]) if u[0] == own)
        assert p["roster_signature"] not in held


def test_schema_strict_flags_misplaced_and_invented():
    from tools.contract_sft import schema_strict as SS
    p = _plan()
    assert SS.audit(p) == []
    bad = json.loads(json.dumps(p))
    bad["phases"][0]["missions"][0]["next"] = "P2"          # phase key inside a mission
    bad["phases"][0]["missions"][0]["stop"] = ["HQ_DESTROYED"]  # invented trigger
    codes = SS.audit(bad)
    assert "UNKNOWN_KEY:mission.next" in codes and any(c.startswith("BAD_CONDITION") for c in codes)


def test_hoist_moves_without_overwriting():
    from tools.contract_sft import schema_strict as SS
    p = _plan()
    p["phases"][1].pop("next")
    p["phases"][1]["missions"][0]["next"] = "END"            # intended phase transition
    p["phases"][0]["missions"][0]["reserve"] = ["R_INF_2"]   # conflicts with existing phase reserve
    p["branches"] = [{"id": "B1", "when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY", "then": "REQUEST_REVIEW"}]
    d, notes = SS.hoist(p)
    assert d["phases"][1]["next"] == "END"
    assert d["phases"][0]["reserve"] == ["R_CAV_1"]           # existing value kept
    assert d["branches"][0]["when"] == {"when": "ENEMY_CLASS_DETECTED", "class": "CAVALRY"}
    assert SS.audit(d) == [] and "drop_mission_conflict:reserve" in notes
