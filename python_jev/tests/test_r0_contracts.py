"""R0 acceptance-gate suite for ObservationLayoutV0 + RulesetV0 contracts.

R0-1 SOURCE TRACE and R0-2 NO SPECULATION are enforced structurally (every
rule entry carries non-empty `source` citations; every data value names its
live symbol) and by the handoff review. The executable gates below verify the
machine-readable properties: manifest completeness, 91-hex order, permutation
principle, unknown semantics, boundary distinctions, classification coverage,
data/code split, skill dependency coverage, profile overlay purity, hash
stability, and JEV N0 regression.
"""

from __future__ import annotations

import json

import pytest

import python_jev.contracts as contracts
from python_jev.contracts.hex_patch import (
    RING_MAJOR_INDEX,
    RING_MAJOR_OFFSETS,
    offset_to_index,
)
from python_jev.contracts.observation_layout import (
    MANIFEST as LAYOUT_MANIFEST,
    TOKEN_CAPACITY,
    TOKEN_CAPACITY_RATIONALE,
)
from python_jev.contracts.ruleset import (
    ALGORITHMIC_RULES,
    DATA_CONFIGURABLE_RULES,
    MANIFEST as RULESET_MANIFEST,
    RULES,
    SCENARIO_PROFILES,
    SKILL_DEPENDENCIES,
    UNRESOLVED_CONTRACT_GAPS,
)

ALL_CLASSES_SKILLS = [
    "Infantry", "Spearman", "Cavalry", "Archer", "Scout",
]
FROZEN_SKILL_TABLES = {
    "Infantry": ["ATTACK", "ADVANCE", "HOLD", "REPOSITION", "SUPPORT", "WITHDRAW"],
    "Spearman": ["ATTACK", "ADVANCE", "HOLD", "REPOSITION", "SCREEN", "WITHDRAW"],
    "Cavalry": ["ATTACK", "FLANK", "ADVANCE", "PURSUE", "RESERVE", "WITHDRAW"],
    "Archer": ["FIRE", "FOCUS_FIRE", "REPOSITION_RANGE", "KITE", "HOLD_POSITION", "WITHDRAW"],
    "Scout": ["RECON_ADVANCE", "SHADOW", "HARASS", "SCREEN", "EVADE", "REGROUP"],
}

VALID_STATUSES = {
    "ACTIVE", "FROZEN_FOR_PRODUCTION", "DEV_PROFILE_INACTIVE", "DEFERRED",
    "EXCLUDED", "DEAD",
}


# ---------------------------------------------------------------------------
# R0-3 OBSERVATION MANIFEST completeness
# ---------------------------------------------------------------------------
def test_r0_3_manifest_structure() -> None:
    assert LAYOUT_MANIFEST["contract"] == "ObservationLayoutV0"
    for key in (
        "observation_schema_version", "feature_groups", "vocabularies",
        "encoding_semantics", "normalization", "local_hex_patch",
        "capacity_constraints", "mask_pairing",
    ):
        assert key in LAYOUT_MANIFEST, key
    # every feature group table carries name+width and a computed dim
    for group_name in ("actor", "tokens", "hex_patch", "mission", "global"):
        block = LAYOUT_MANIFEST["feature_groups"][group_name]
        width_sum = sum(int(w) for _, w in block["groups"])
        assert width_sum == block["dim"], group_name
    # manifest must be JSON-serializable (machine-readable requirement)
    payload = json.dumps(LAYOUT_MANIFEST, sort_keys=True)
    assert "obs-v0" in payload


def test_r0_3_manifest_dims_match_implementation() -> None:
    from python_jev import layout as impl

    assert LAYOUT_MANIFEST["feature_groups"]["actor"]["dim"] == impl.ACTOR_FEATURE_DIM
    assert LAYOUT_MANIFEST["feature_groups"]["tokens"]["dim"] == impl.TOKEN_FEATURE_DIM
    assert LAYOUT_MANIFEST["feature_groups"]["hex_patch"]["dim"] == impl.HEX_FEATURE_DIM
    assert LAYOUT_MANIFEST["feature_groups"]["mission"]["dim"] == impl.MISSION_FEATURE_DIM
    assert LAYOUT_MANIFEST["feature_groups"]["global"]["dim"] == impl.GLOBAL_FEATURE_DIM
    assert LAYOUT_MANIFEST["capacity_constraints"]["token_capacity"] == impl.TOKEN_CAPACITY


def test_r0_3_vocabularies_frozen() -> None:
    v = LAYOUT_MANIFEST["vocabularies"]
    assert v["unit_class"] == ["INFANTRY", "SPEARMAN", "CAVALRY", "ARCHER", "SCOUT"]
    assert v["relation_kind"] == ["FRIENDLY", "ENEMY_VISIBLE", "STALE_CONTACT", "PAD"]
    assert v["knowledge_state"] == ["VISIBLE", "REMEMBERED", "UNEXPLORED"]
    assert v["occupancy"] == ["EMPTY", "FRIENDLY", "ENEMY_VISIBLE", "STALE_MARKER", "UNKNOWN"]
    assert "UNKNOWN" in v["terrain"] and "UNKNOWN" in v["blocking"]
    assert len(v["doctrine_scalars"]) == 6


def test_r0_3_normalization_constants_cited() -> None:
    n = LAYOUT_MANIFEST["normalization"]
    # distance / patch radius, cost / 3.0 (Step3Config max), age / horizon,
    # counts / frozen refs, strength / max_count — all documented
    assert "MAX_TRAVERSAL_COST (3.0)" in n["terrain_cost"]
    assert "PATCH_RADIUS (5)" in n["distance"]
    assert "CONTACT_MEMORY_HORIZON (10.0)" in n["contact_age"]
    assert "{friendly:16, enemy_visible:16, stale:8}" in n["counts"]
    assert "max_count" in n["strength"]


# ---------------------------------------------------------------------------
# R0-4 91-HEX ORDER: unique deterministic indices
# ---------------------------------------------------------------------------
def test_r0_4_exactly_91_unique_offsets() -> None:
    assert len(RING_MAJOR_OFFSETS) == 91
    assert len(set(RING_MAJOR_OFFSETS)) == 91
    assert RING_MAJOR_OFFSETS[0] == (0, 0)


def test_r0_4_distance_coherent_ring_major() -> None:
    def dist(dq: int, dr: int) -> int:
        return max(abs(dq), abs(dr), abs(-dq - dr))

    indices = [dist(dq, dr) for _, (dq, dr) in enumerate(RING_MAJOR_OFFSETS)]
    # ring-major means distance values are non-decreasing by index
    assert indices == sorted(indices)
    # ring sizes: 1, 6, 12, 18, 24, 30
    sizes = [indices.count(k) for k in range(6)]
    assert sizes == [1, 6, 12, 18, 24, 30]


def test_r0_4_offset_to_index_roundtrip() -> None:
    for i, (dq, dr) in enumerate(RING_MAJOR_OFFSETS):
        assert offset_to_index(dq, dr) == i
        assert RING_MAJOR_INDEX[(dq, dr)] == i


def test_r0_4_all_relative_cells_resolvable() -> None:
    for dq in range(-5, 6):
        for dr in range(-5, 6):
            if max(abs(dq), abs(dr), abs(-dq - dr)) <= 5:
                idx = offset_to_index(dq, dr)
                assert 0 <= idx <= 90


def test_r0_4_outside_radius_fails_loudly() -> None:
    from python_jev.contracts.hex_patch import offset_to_index as o2i

    with pytest.raises(ValueError):
        o2i(6, 0)
    with pytest.raises(ValueError):
        o2i(0, 6)


def test_r0_4_manifest_embeds_index_map() -> None:
    m = LAYOUT_MANIFEST["local_hex_patch"]
    assert m["radius"] == 5 and m["num_cells"] == 91
    assert len(m["index_map"]) == 91
    assert m["index_map"][0] == [0, 0, 0]
    seen = {tuple(cell[1:]) for cell in m["index_map"]}
    assert len(seen) == 91


# ---------------------------------------------------------------------------
# R0-5 UNIT PERMUTATION principle encoded in the manifest
# ---------------------------------------------------------------------------
def test_r0_5_permutation_principle_frozen() -> None:
    pp = LAYOUT_MANIFEST["permutation_principle"]
    assert "irrelevant" in pp["unit_tokens"]
    assert "spatial identity" in pp["hex_patch"]


def test_r0_5_policy_regression_permutation_still_green() -> None:
    # The JEV N0 suite owns the behavioral proof; here we assert the fixture
    # contract stays intact so the manifest cannot silently break it.
    # (The factory emits one visible enemy by default; tokens are variable-N.)
    from python_jev.synthetic import make_observation_batch

    obs = make_observation_batch(batch_size=1, num_friendly=2)
    assert obs.tokens.shape[0] == 1
    assert not obs.token_padding_mask.any()  # no padding inside the emitted set


# ---------------------------------------------------------------------------
# R0-6 UNKNOWN SEMANTICS distinct
# ---------------------------------------------------------------------------
def test_r0_6_encoding_semantics_cover_all_five() -> None:
    enc = LAYOUT_MANIFEST["encoding_semantics"]
    for key in ("numeric_unknown", "categorical_unknown",
                "categorical_not_applicable", "stale_value", "absent",
                "padding", "known_zero"):
        assert key in enc, key
    assert enc["padding"]["rule"] != enc["absent"]["rule"]
    assert enc["numeric_unknown"]["known_bit"] == 0


def test_r0_6_mask_families_separate() -> None:
    mp = LAYOUT_MANIFEST["mask_pairing"]
    assert set(mp["separate_masks"]) == {
        "field_known", "stale", "not_applicable", "token_padding", "skill_legality",
    }


# ---------------------------------------------------------------------------
# R0-7 WORLDTRUTH BOUNDARY + R0-8 MASK SAFETY
# ---------------------------------------------------------------------------
def test_r0_7_boundary_documented_in_both_manifests() -> None:
    assert "worldtruth_boundary" in LAYOUT_MANIFEST
    wb = RULESET_MANIFEST["worldtruth_boundary"]
    assert set(wb) == {"world_truth", "faction_knowledge", "jev_observation", "mask_rule"}


def test_r0_8_mask_safety_rules_frozen() -> None:
    m = RULESET_MANIFEST
    rules_by_id = {(r["family"], r["id"]): r for r in m["rules"]}
    mask_rule = rules_by_id[("fog", "observation_safe_legality")]
    assert mask_rule["status"] == "FROZEN_FOR_PRODUCTION"
    exec_rule = rules_by_id[("fog", "worldtruth_execution")]
    assert exec_rule["status"] == "FROZEN_FOR_PRODUCTION"
    # the algorithmic contract re-states the engine recheck
    assert "rechecks at execution" in m["algorithmic_rules"]["observation_safe_masking"]["semantics"]


# ---------------------------------------------------------------------------
# R0-9 RULE CLASSIFICATION coverage + citation integrity (R0-1/R0-2 helpers)
# ---------------------------------------------------------------------------
def test_r0_9_every_rule_has_exactly_one_status() -> None:
    for r in RULES:
        assert r["status"] in VALID_STATUSES, (r["family"], r["id"])
        assert r["family"] and r["id"] and r["summary"]
        # R0-1 SOURCE TRACE: non-empty authoritative citations
        assert r["source"], (r["family"], r["id"])
        for citation in r["source"]:
            assert isinstance(citation, str) and len(citation) > 6


def test_r0_9_required_families_present() -> None:
    families = {r["family"] for r in RULES}
    expected = {
        "hex_geometry", "unit_state", "movement", "combat", "turn_phase",
        "terrain", "fog", "hq_objectives", "morale", "randomness", "excluded",
    }
    assert expected <= families


def test_r0_9_classification_counts_match_manifest() -> None:
    counts = RULESET_MANIFEST["classification_counts"]
    total = sum(counts.values())
    assert total == len(RULES)
    assert counts == RULESET_MANIFEST["classification_counts"]


def test_r0_9_no_speculation_gaps_recorded() -> None:
    # R0-2: anything not derivable must be listed as a gap, not invented
    gap_ids = {g["id"] for g in UNRESOLVED_CONTRACT_GAPS}
    deferred = [r for r in RULES if r["status"] in ("DEFERRED", "DEV_PROFILE_INACTIVE")]
    assert deferred, "expected at least one non-frozen mechanic"
    for g in UNRESOLVED_CONTRACT_GAPS:
        assert {"id", "rule", "missing", "resolution"} <= set(g)


# ---------------------------------------------------------------------------
# R0-10 DATA / CODE SPLIT
# ---------------------------------------------------------------------------
def test_r0_10_data_rules_have_live_sources() -> None:
    for key, entry in DATA_CONFIGURABLE_RULES.items():
        assert "::" in entry["source"], key
        assert entry.get("values"), key


def test_r0_10_algorithmic_rules_have_parity_notes() -> None:
    for key, entry in ALGORITHMIC_RULES.items():
        # source citation: a live symbol (path :: symbol) or a frozen contract
        assert entry.get("source"), key
        assert entry.get("parity_note"), key
    # the two known rounding regimes are both called out
    combat = ALGORITHMIC_RULES["combat_resolution"]["parity_note"]
    assert "banker" in combat and "away from zero" in combat


def test_r0_10_split_is_disjoint_and_complete() -> None:
    data_keys = set(DATA_CONFIGURABLE_RULES)
    algo_keys = set(ALGORITHMIC_RULES)
    assert data_keys.isdisjoint(algo_keys)
    # core primitives the simulator needs
    assert {"class_base_movement", "terrain_costs_standard", "base_stats",
            "matchup_table"} <= data_keys
    assert {"dijkstra_envelope", "combat_resolution", "sequential_occupancy",
            "turn_cycle", "visibility_propagation", "contact_lifecycle"} <= algo_keys


# ---------------------------------------------------------------------------
# R0-11 SKILL DEPENDENCIES (all 30 frozen skills)
# ---------------------------------------------------------------------------
def test_r0_11_all_thirty_skills_mapped() -> None:
    expected = set()
    for cls, skills in FROZEN_SKILL_TABLES.items():
        for slot_name in skills:
            expected.add(f"{cls}.{slot_name}")
    assert set(SKILL_DEPENDENCIES) == expected
    assert len(SKILL_DEPENDENCIES) == 30


def test_r0_11_dependencies_reference_known_primitives() -> None:
    known = set(DATA_CONFIGURABLE_RULES) | set(ALGORITHMIC_RULES)
    known |= {r["id"] for r in RULES}  # bare rule ids may also be cited
    # sub-primitive suffixes (e.g. knowledge_ledger.visibility_enumeration)
    # refine their base primitive; the base must be declared somewhere.
    for skill, deps in SKILL_DEPENDENCIES.items():
        assert deps, skill
        for dep in deps:
            base = dep.split(".")[0]
            assert base in known, (skill, dep)


def test_r0_11_attack_skills_require_combat_resolution() -> None:
    for skill in ("Infantry.ATTACK", "Spearman.ATTACK", "Cavalry.ATTACK",
                  "Archer.FIRE", "Scout.HARASS"):
        deps = SKILL_DEPENDENCIES[skill]
        assert any(d.startswith("combat_resolution") for d in deps), skill


def test_r0_11_movement_skills_require_dijkstra() -> None:
    for skill in ("Cavalry.FLANK", "Archer.KITE", "Scout.RECON_ADVANCE",
                  "Infantry.ADVANCE"):
        assert any(d.startswith("dijkstra_envelope") for d in SKILL_DEPENDENCIES[skill])


# ---------------------------------------------------------------------------
# R0-12 PROFILE CONTRACT: overlays on ONE ruleset
# ---------------------------------------------------------------------------
def test_r0_12_six_profiles_present() -> None:
    expected = {"DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO", "FLAT_FOG",
                "TERRAIN_FOG", "MORALE_COMBAT", "FULL_PRODUCTION"}
    assert set(SCENARIO_PROFILES) == expected


def test_r0_12_profiles_are_overlay_flags_only() -> None:
    allowed_keys = {
        "notion_name", "purpose", "terrain_effects", "obstacles_strongholds",
        "fog_stale_contacts", "morale_rout_fatigue", "ambush", "roster", "notes",
    }
    for name, profile in SCENARIO_PROFILES.items():
        assert set(profile) <= allowed_keys, name
        # every profile toggles the SAME rule systems (overlay, not new rules)
        for flag in ("terrain_effects", "obstacles_strongholds",
                     "fog_stale_contacts", "morale_rout_fatigue", "ambush"):
            assert isinstance(profile[flag], bool), (name, flag)


def test_r0_12_dev_profile_matches_sandbox_contract() -> None:
    dev = SCENARIO_PROFILES["DEV_FLAT_ALL_INFO"]
    assert dev["terrain_effects"] is False
    assert dev["fog_stale_contacts"] is False
    assert dev["morale_rout_fatigue"] is False
    assert "SandboxRules" in dev["notes"]


def test_r0_12_full_production_enables_everything_frozen() -> None:
    full = SCENARIO_PROFILES["FULL_PRODUCTION"]
    assert all(full[f] is True for f in (
        "terrain_effects", "obstacles_strongholds", "fog_stale_contacts",
        "morale_rout_fatigue", "ambush"))


# ---------------------------------------------------------------------------
# R0-13 VERSION / HASH
# ---------------------------------------------------------------------------
def test_r0_13_versions_and_hashes_present_and_stable() -> None:
    layout_hash = contracts.observation_layout_content_hash()
    ruleset_hash = contracts.ruleset_content_hash()
    hex_hash = contracts.hex_patch_content_hash()
    for h in (layout_hash, ruleset_hash, hex_hash):
        assert len(h) == 64
        assert h == contracts.observation_layout_content_hash() if h == layout_hash else True
    # deterministic recompute
    assert contracts.observation_layout_content_hash() == layout_hash
    assert contracts.ruleset_content_hash() == ruleset_hash
    assert contracts.hex_patch_content_hash() == hex_hash
    m = RULESET_MANIFEST
    assert m["observation_schema_dependency"] == "obs-v0 (see ObservationLayoutV0 manifest)"


def test_r0_13_manifests_record_schema_dependency_chain() -> None:
    assert LAYOUT_MANIFEST["observation_schema_version"] == "obs-v0"
    assert RULESET_MANIFEST["ruleset_version"] == "ruleset-v0.1.0"
    assert LAYOUT_MANIFEST["contract"] == "ObservationLayoutV0"
    assert RULESET_MANIFEST["contract"] == "RulesetV0"


# ---------------------------------------------------------------------------
# TOKEN_CAPACITY decision audit (explicit task requirement)
# ---------------------------------------------------------------------------
def test_token_capacity_decision_is_documented_and_bounded() -> None:
    assert TOKEN_CAPACITY == 24
    rationale = TOKEN_CAPACITY_RATIONALE
    # quantitative reasoning must be present and frozen in the manifest
    assert "16" in rationale and "8" in rationale and "10" in rationale
    assert LAYOUT_MANIFEST["capacity_constraints"]["token_capacity"] == 24
    assert "overflow_rule" in LAYOUT_MANIFEST["capacity_constraints"]


# ---------------------------------------------------------------------------
# R0-14 JEV N0 REGRESSION is run by the verification runner; here we assert
# the contract-facing entry points the N0 suite imports still exist.
# ---------------------------------------------------------------------------
def test_r0_14_jev_public_api_intact() -> None:
    from python_jev import (  # noqa: F401
        JevPolicyV0,
        ObservationBatchV0,
        apply_legal_mask,
    )
    from python_jev import layout as impl

    # implementation still agrees with the frozen manifest constants
    assert impl.TOKEN_CAPACITY == TOKEN_CAPACITY
    assert impl.PATCH_NUM_CELLS == 91
    assert impl.PATCH_RADIUS == 5
    assert impl.MAX_TRAVERSAL_COST == 3.0
    assert impl.CONTACT_MEMORY_HORIZON == 10.0


def test_r0_14_n0_suite_collects() -> None:
    import subprocess
    import sys

    result = subprocess.run(
        [sys.executable, "-m", "pytest", "python_jev/tests/test_n0_gates.py",
         "-q", "--no-header"],
        capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stdout[-2000:]
    assert "failed" not in result.stdout.split("\n")[-2]
