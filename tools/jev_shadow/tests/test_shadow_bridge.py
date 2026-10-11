"""Committed tests for the JEV shadow bridge (SHADOW ONLY).

The fixture/fail-open batteries in tools.jev_shadow.parity are the single
verification path: these tests import and assert them, so `pytest
tools/jev_shadow/tests` reproduces the gate evidence (FIXTURE_PARITY.json /
FAIL_OPEN_TESTS.json) without duplicating assertions.
"""

from __future__ import annotations

import pytest

from tools.jev_shadow.parity import (
    run_failopen_battery,
    run_static_battery,
)
from tools.jev_shadow.slotmap import SlotMap


@pytest.fixture(scope="module")
def static_report():
    return run_static_battery()


@pytest.fixture(scope="module")
def failopen_report():
    return run_failopen_battery()


def test_slot_map_invariants():
    sm = SlotMap()  # raises SlotMapError on any invariant violation
    assert sm.dead_slots("INFANTRY") == {3, 4}
    assert sm.dead_slots("ARCHER") == {1}
    assert sm.dead_slots("SCOUT") == {2, 5}


def test_static_battery_passes(static_report):
    assert static_report["failures"] == []
    assert static_report["passed"] is True
    assert static_report["fixture_cases"] >= 200
    assert static_report["helper_cross_checks"] >= 300


def test_all_classes_and_tasks_covered(static_report):
    assert static_report["classes"] == [
        "INFANTRY", "SPEARMAN", "CAVALRY", "ARCHER", "SCOUT"]
    assert static_report["tasks"] == [
        "HOLD", "ADVANCE", "FIX", "ATTACK", "FLANK", "RECON", "RESERVE",
        "WITHDRAW"]


def test_live_replay_bit_identical(static_report):
    replay = static_report["live_replay"]
    if "note" in replay:
        pytest.skip("REQUESTS.jsonl absent; live battle not run yet")
    assert replay["checked"] > 0
    assert replay["logits_equal"] == replay["eligible"]
    assert replay["hash_equal"] == replay["eligible"]
    assert replay["slot_equal"] == replay["checked"]


def test_failopen_battery_passes(failopen_report):
    assert failopen_report["failures"] == []
    assert failopen_report["passed"] is True
    names = {r["check"] for r in failopen_report["results"]}
    assert {"bad_hash_refuses_startup", "missing_checkpoint_refuses_startup",
            "health_ok", "http_infer_ok", "http_malformed_json_envelope",
            "http_schema_mismatch_envelope", "http_unknown_path_404"} <= names
