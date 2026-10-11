"""Liberation V1: L2 group-coordinator worker render check (no model).

Verifies validate_group_request + build_group_state_text render the rich
mission intent, blackboard commitments, and known foes into bounded,
factual state text with no tactics-dictionary leakage.

Run:  python tools/laya/test_render_l2.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import worker


def main() -> int:
    req = {
        "schema_version": "laya-group-choice-v1", "side": "red",
        "group_id": "G1", "mission_id": "M01",
        "mission": {"mission_id": "M01", "task": "EXECUTE",
                    "intent": "Pressure the ranged line; preserve mobility."},
        "group_units": [
            {"id": "R_INF_1", "class": "infantry", "soldiers": 80, "morale": 90},
            {"id": "R_ARC_1", "class": "archer", "soldiers": 60, "morale": 85}],
        "known_foes": [{"id": "B_ARC_1", "class": "archer", "soldiers": 50}],
        "blackboard": "COMMIT R_INF_1 -> HOLD RIDGE (pin B_ARC_1).",
        "candidates": [
            {"candidate_id": "A", "option_text": "Focus fire B_ARC_1 x1.50."},
            {"candidate_id": "B", "option_text": "Reposition to treeline."}],
    }
    v = worker.validate_group_request(req)
    text = worker.build_group_state_text(v)
    checks = {
        "intent_rendered": "preserve mobility" in text,
        "blackboard_rendered": "COMMIT R_INF_1" in text,
        "foe_rendered": "B_ARC_1" in text,
        "no_forbidden_dict": "TACTICS_DICTIONARY" not in text,
        "bounded": len(text) < 6000,
    }
    for name, ok in checks.items():
        print("%s: %s" % (name, "PASS" if ok else "FAIL"))
    print("chars: %d" % len(text))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
