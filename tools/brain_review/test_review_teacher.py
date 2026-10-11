"""Unit tests for tools/brain_review/review_teacher.py.

>= 30 hand-built packets covering every rule (R1, R2, R2b + fallback, R3
ENGAGE / PULL_BACK / HOLD_FIRE, R4 RETARGET incl. FLANK side, R5 UNSTALL,
R6), every ambiguity drop, and "PHASE_SUCCESS in also_due".

Run:  python -m tools.brain_review.test_review_teacher   (or pytest)
"""
from __future__ import annotations

import copy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.brain_review.review_teacher import (  # noqa: E402
    decide, v2_ok, troop_mid, hexdist, in_ambiguity_band, Teacher,
)


# ------------------------------------------------------------------ builders
def mission(task="FIX", area="CENTER", priority="high", vs=None, target=None, **kw):
    m = {"task": task, "area": area, "intent": "x", "priority": priority, "units": []}
    if vs:
        m["vs"] = vs
    if target:
        m["target"] = target
    m.update(kw)
    return m


def phase(pid="P1", missions=None, nxt="P2", on_fail="HOLD", **kw):
    p = {"id": pid, "name": pid, "purpose": "p", "intent": "i", "groups": {},
         "missions": missions if missions is not None else [mission(), mission("FLANK", "NORTH", "medium"), mission("RECON", "NORTH", "low")],
         "entry": [], "win": [], "lose": [], "abort": [], "next": nxt, "on_fail": on_fail,
         "reserve": [], "release": [], "exploit": ""}
    p.update(kw)
    return p


def unit(uid, cls="INFANTRY", q=16, r=0, region="CENTER", soldiers=400):
    return {"unit_id": uid, "class": cls, "q": q, "r": r, "region": region,
            "status": "ready", "soldiers": soldiers, "condition": "healthy", "can_attack": False}


def enemy(uid, cls="INFANTRY", q=-16, r=0, region="CENTER", est="약 200~300", contact="current_visible"):
    return {"unit_id": uid, "class": cls, "q": q, "r": r, "region": region,
            "contact_state": contact, "troop_estimate": est}


def ff_unit(uid, mid="M01", task="FIX", actions=()):
    return {"unit_id": uid, "mission_id": mid, "task": task, "role": "MAIN",
            "engagement": "MAINTAIN", "recent_actions": list(actions)}


def status(mid, task, area, units):
    return {"mission_id": mid, "task": task, "area": area, "units": list(units),
            "status": "ACTIVE", "status_reason": "HAND_A_ASSIGNED", "units_source": "HAND_A"}


def p2_phase():
    return phase("P2", missions=[mission("ATTACK", "CENTER", "high", vs="HQ"),
                                 mission("ATTACK", "NORTH", "medium"),
                                 mission("HOLD", "CENTER", "low")], nxt="END")


def r4_quiet_missions():
    # no FIX/ATTACK/ADVANCE/FLANK mission with an empty area -> R4 never fires
    return [mission("FIX", "CENTER", "high"), mission("RESERVE", "CENTER", "medium"), mission("RECON", "NORTH", "low")]


def packet(phases=None, active="P1", statuses=None, friendlies=None, enemies=None,
           trigger="FRIENDLY_UNIT_ATTACKED", also_due=None, events=None, ff=None,
           current=None):
    phases = phases if phases is not None else [phase(), p2_phase()]
    current = current if current is not None else phases[0]
    friendlies = friendlies if friendlies is not None else [unit("R_INF_1"), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)]
    enemies = enemies if enemies is not None else [enemy("B_INF_1")]
    statuses = statuses if statuses is not None else [
        status("M01", current["missions"][0]["task"], current["missions"][0]["area"], ["R_INF_1"]),
        status("M02", current["missions"][1]["task"], current["missions"][1]["area"], []),
        status("M03", current["missions"][2]["task"], current["missions"][2]["area"], []),
    ]
    ff = ff if ff is not None else {"note": "n", "units": [ff_unit("R_INF_1")]}
    ad = []
    for a in (also_due or []):
        ad.append({"trigger": a, "reason": "due"})
    return {
        "request": "VICTORY_REVIEW",
        "turn": 7,
        "review_trigger": {"trigger": trigger, "reason": "r", "turn": 7, "also_due": ad},
        "mission": {"objective": "Destroy the BLUE HQ.", "type": "destroy_blue_hq", "status": "ongoing"},
        "plan_authoring": {"objective": "Destroy the BLUE HQ.", "end_state": "e", "cadence": 5,
                           "doctrine": [0.5] * 6, "phases": copy.deepcopy(phases),
                           "abort": [], "branches": [], "hypotheses": []},
        "plan_live": {"revision": 2, "lineage_id": "VL1", "current_phase_id": active,
                      "turns_active": 3, "mission_statuses": copy.deepcopy(statuses),
                      "evaluated": {"entry": [], "success": [], "failure": [], "abort": [], "plan_abort": []},
                      "branches": [], "reserve": {"hold": [], "released_turn": 0}},
        "events_since_review": copy.deepcopy(events or []),
        "compact_state": {"turn": 7, "snapshot_id": "s7", "state_version": 7,
                          "friendly_units": copy.deepcopy(friendlies),
                          "known_enemy_units": copy.deepcopy(enemies),
                          "force_summary": {}},
        "force_feedback": copy.deepcopy(ff),
        "context": {"rules": {"classes": {
            "INFANTRY": {"atk": 9.3, "def": 10, "mp": 1, "rng": 1},
            "ARCHER": {"atk": 12.8, "def": 4, "mp": 2, "rng": 3},
            "CAVALRY": {"atk": 14.1, "def": 6, "mp": 2, "rng": 1},
            "SPEARMAN": {"atk": 8.6, "def": 14, "mp": 3, "rng": 1},
            "SCOUT": {"atk": 1.8, "def": 3, "mp": 5, "rng": 1},
            "HQ": {"atk": 8.2, "def": 12, "mp": 1, "rng": 1},
        }, "matchups": [["INFANTRY", "CAVALRY", 1.18], ["SPEARMAN", "INFANTRY", 1.18],
                        ["CAVALRY", "ARCHER", 1.35], ["ARCHER", "SPEARMAN", 1.35]]},
            "forces": {}, "map": {}, "mode": {}},
    }


# ----------------------------------------------------------------- helpers
def ok(row, decision, rule, subkind):
    assert row["target"] is not None, "unexpected drop: %s" % row.get("drop_reason")
    assert row["target"]["decision"] == decision, row
    assert row["rule"] == rule, row
    assert row["subkind"] == subkind, row
    why = row["target"]["reason"]
    assert len(why) <= 200, "reason too long (%d): %s" % (len(why), why)
    for ch in "*`#<>|\n":  # underscores stay: unit ids carry them
        assert ch not in why, "markdown/newline in reason: %s" % why
    assert why == row["why"], (why, row["why"])
    return row["target"]


def dropped(row, code):
    assert row["target"] is None, "expected drop %s, got %s" % (code, row["target"])
    assert row["drop_reason"] == code, row
    return row


def only_changed(pk, tgt, idx, **fields):
    """AMEND must change ONLY the named fields of mission idx in the active phase."""
    orig = pk["plan_authoring"]["phases"]
    new = tgt["phases"]
    assert len(orig) == len(new)
    for po, pn in zip(orig, new):
        assert po["id"] == pn["id"]
        for k in po:
            if k == "missions":
                continue
            assert po[k] == pn[k], "phase field %s changed" % k
        assert len(po["missions"]) == len(pn["missions"])
        for i, (mo, mn) in enumerate(zip(po["missions"], pn["missions"])):
            keys = set(mo) | set(mn)
            for k in keys:
                if po["id"] == pk["plan_live"]["current_phase_id"] and i == idx and k in fields:
                    assert mn.get(k) == fields[k], "mission %d field %s: %r != %r" % (i, k, mn.get(k), fields[k])
                else:
                    assert mo.get(k) == mn.get(k), "mission %d field %s changed unexpectedly" % (i, k)


# --------------------------------------------------------------------- tests
def test_r1_hq_defense_attack_at_ratio():
    # lowest-priority mission itself has ratio >= 1.25 -> ATTACK, not HOLD
    pk = packet(friendlies=[unit("R_INF_1", q=18, r=0, soldiers=450), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=18, r=1, est="약 200~300")],
                statuses=[status("M01", "RECON", "CENTER", ["R_INF_1"]), status("M02", "FIX", "NORTH", []), status("M03", "HOLD", "SOUTH", [])],
                phases=[phase(missions=[mission("RECON", "CENTER", "low"), mission("FIX", "NORTH", "medium"), mission("HOLD", "SOUTH", "high")])])
    # NOTE: M03 is HOLD/SOUTH (not the HQ region CENTER); M01 is the low-priority mission with contact
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R1", "HQ_DEFENSE")
    assert t["phases"][0]["missions"][0]["task"] == "ATTACK"


def test_r1_nearest_threat_class_tie_broken():
    # v2: equal distance, equal estimate -> unit_id order (B_ARC_1 < B_INF_1)
    pk = packet(friendlies=[unit("R_INF_1", q=16), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=18, r=0), enemy("B_ARC_1", "ARCHER", q=20, r=2)])
    tgt = ok(decide(pk), "AMEND_PLAN", "R1", "HQ_DEFENSE")
    changed = [m for m in tgt["phases"][0]["missions"] if m.get("vs")]
    assert changed and changed[0]["vs"] == "ARCHER"


def test_symmetric_ratio_pull_back():
    # own INFANTRY 250 vs enemy SPEARMAN 300; SPEARMAN->INFANTRY 1.18 weights the ENEMY side:
    # v3 ratio = 180 / (300*1.18) = 0.51 -> PULL_BACK (asymmetric would be 180/300 = 0.60 -> ambiguity drop)
    pk = packet(friendlies=[unit("R_INF_1", q=16, soldiers=180), unit("R_HQ_1", "HQ", 30, 0, "SOUTH", 300)],
                enemies=[enemy("B_SPE_1", "SPEARMAN", q=15, r=0, est="약 300~300")],
                events=[{"kind": "FRIENDLY_UNIT_ATTACKED", "turn": 7, "detail": {"defender_id": "R_INF_1"}}])
    tgt = ok(decide(pk), "AMEND_PLAN", "R3", "PULL_BACK")
    assert tgt["phases"][0]["missions"][0]["task"] == "WITHDRAW"


def _r2c_packet(enemies, missions=None):
    ph = phase("P1", missions=missions, nxt="END")
    friendlies = [unit("R_INF_1", q=16, soldiers=400), unit("R_INF_2", q=16, r=2, soldiers=400),
                  unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)]
    st = [status("M01", ph["missions"][0]["task"], ph["missions"][0]["area"], ["R_INF_1", "R_INF_2"]),
          status("M02", ph["missions"][1]["task"], ph["missions"][1]["area"], []),
          status("M03", ph["missions"][2]["task"], ph["missions"][2]["area"], [])]
    return packet(phases=[ph], statuses=st, friendlies=friendlies, enemies=enemies, trigger="PHASE_SUCCESS",
                  ff={"note": "n", "units": [ff_unit("R_INF_1"), ff_unit("R_INF_2")]})


def test_r2c_push_hq_when_stronger():
    pk = _r2c_packet([enemy("B_HQ_1", "HQ", q=-20, r=0, est="약 300~300"), enemy("B_INF_1", q=-16, r=0)])
    tgt = ok(decide(pk), "AMEND_PLAN", "R2c", "PUSH_HQ")
    m = tgt["phases"][0]["missions"][0]
    assert (m["task"], m["area"], m["vs"]) == ("ATTACK", "CENTER", "HQ")


def test_r2c_consolidate_when_weaker():
    pk = _r2c_packet([enemy("B_HQ_1", "HQ", q=-20, r=0, est="약 300~300"),
                      enemy("B_INF_1", q=-16, r=0, est="약 900~1000"), enemy("B_INF_2", q=-16, r=2, est="약 900~1000")])
    tgt = ok(decide(pk), "AMEND_PLAN", "R2c", "CONSOLIDATE")
    m = tgt["phases"][0]["missions"][0]
    assert (m["task"], m["area"]) == ("HOLD", "CENTER")


def test_r2c_already_set_falls_through():
    ms = [mission("ATTACK", "CENTER", "high", vs="HQ"), mission("RESERVE", "CENTER", "medium"), mission("RECON", "NORTH", "low")]
    pk = _r2c_packet([enemy("B_HQ_1", "HQ", q=-20, r=0, est="약 300~300"), enemy("B_INF_1", q=-16, r=0)], missions=ms)
    row = decide(pk)
    assert row["rule"] != "R2c" and row["target"] is not None


def test_r2c_ambiguous_ratio_dropped():
    pk = _r2c_packet([enemy("B_HQ_1", "HQ", q=-20, r=0, est="약 300~300"), enemy("B_INF_1", q=-16, r=0, est="약 900~960")])  # 800/930 = 0.86
    dropped(decide(pk), "ambig_ratio")


def test_r1_beats_phase_success():
    pk = packet(friendlies=[unit("R_INF_1", q=16), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=18, r=0)], trigger="PHASE_SUCCESS")
    row = decide(pk)
    ok(row, "AMEND_PLAN", "R1", "HQ_DEFENSE")


def test_r2_phase_success_trigger():
    pk = packet(trigger="PHASE_SUCCESS")
    row = decide(pk)
    t = ok(row, "ADVANCE_PHASE", "R2", "PHASE_DONE")
    assert t["next_phase_id"] == "P2"


def test_r2_beats_hold_fire_on_mission_list():
    # contact exists but PHASE_SUCCESS (also_due) has priority over R3
    pk = packet(trigger="PHASE_SUCCESS",
                friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 350~450")])
    row = decide(pk)
    ok(row, "ADVANCE_PHASE", "R2", "PHASE_DONE")


def test_r2_phase_success_in_also_due():
    pk = packet(trigger="FRIENDLY_UNIT_ATTACKED", also_due=["PHASE_SUCCESS"])
    row = decide(pk)
    t = ok(row, "ADVANCE_PHASE", "R2", "PHASE_DONE")
    assert t["next_phase_id"] == "P2"


def test_r2_also_due_beats_hold_fire():
    # in-contact mid ratio would be HOLD_FIRE, but a due PHASE_SUCCESS wins
    pk = packet(trigger="FRIENDLY_UNIT_ATTACKED", also_due=["PHASE_SUCCESS"],
                friendlies=[unit("R_INF_1", q=10, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=9, r=0, est="약 350~450")])
    row = decide(pk)
    ok(row, "ADVANCE_PHASE", "R2", "PHASE_DONE")


def test_r2_no_next_end():
    pk = packet(trigger="PHASE_SUCCESS", phases=[phase(nxt="END", missions=r4_quiet_missions())])
    row = decide(pk)
    ok(row, "KEEP", "R6", "NONE")


def test_r2_next_empty_advances_in_order():
    p2 = phase("P2", missions=[mission("ATTACK", "CENTER"), mission("HOLD", "WEST", "medium"), mission("RESERVE", "CENTER", "low")], nxt="END")
    pk = packet(trigger="PHASE_SUCCESS", phases=[phase(nxt=""), p2])
    row = decide(pk)
    t = ok(row, "ADVANCE_PHASE", "R2", "PHASE_DONE")
    assert t["next_phase_id"] == "P2"


def test_r2_dangling_next_no_fire():
    pk = packet(trigger="PHASE_SUCCESS", phases=[phase(nxt="P9", missions=r4_quiet_missions())])
    row = decide(pk)
    ok(row, "KEEP", "R6", "NONE")


def test_r2b_failed_on_fail_advance():
    pk = packet(trigger="PHASE_FAILED", phases=[phase(on_fail="ADVANCE"), p2_phase()])
    row = decide(pk)
    t = ok(row, "ADVANCE_PHASE", "R2b", "PHASE_FAIL")
    assert t["next_phase_id"] == "P2"


def test_r2b_abort_in_also_due_on_fail_advance():
    pk = packet(trigger="FRIENDLY_UNIT_ATTACKED", also_due=["PHASE_ABORT"],
                phases=[phase(on_fail="ADVANCE"), p2_phase()])
    row = decide(pk)
    ok(row, "ADVANCE_PHASE", "R2b", "PHASE_FAIL")


def test_r2b_fallback_applies_retarget():
    # on_fail HOLD: cannot advance; R4 applies (80% of enemies at WEST, M01 FIX/CENTER empty)
    ph = [phase(on_fail="HOLD", missions=[mission("FIX", "CENTER", "high"), mission("FLANK", "WEST", "medium"), mission("RECON", "EAST", "low")])]
    pk = packet(trigger="PHASE_FAILED", phases=ph,
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "WEST", []), status("M03", "RECON", "EAST", [])],
                friendlies=[unit("R_INF_1", q=16), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=-10, region="WEST"), enemy("B_CAV_1", "CAVALRY", q=-12, region="WEST"),
                         enemy("B_SCT_1", "SCOUT", q=-8, region="WEST"), enemy("B_ARC_1", "ARCHER", q=-14, region="WEST"),
                         enemy("B_SPE_1", "SPEARMAN", q=2, region="EAST")])
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R2b", "RETARGET")
    assert row["rule"] == "R2b"
    assert t["phases"][0]["missions"][0]["area"] == "WEST"


def test_r2b_fallback_none_drops():
    pk = packet(trigger="PHASE_ABORT", phases=[phase(on_fail="HOLD", missions=r4_quiet_missions())])
    dropped(decide(pk), "r2b_fallback_none")


def test_r3_engage():
    # R_INF_1 400 at (12,0) vs B_INF_1 est 200~300 at (11,0): ratio 400/250 = 1.60
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 200~300")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])])
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R3", "ENGAGE")
    assert t["phases"][0]["missions"][0]["task"] == "ATTACK"
    assert t["phases"][0]["missions"][0]["vs"] == "INFANTRY"
    assert t["phases"][0]["missions"][0]["area"] == "CENTER"


def test_r3_engage_clears_old_target_key():
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 200~300")],
                phases=[phase(missions=[mission("FIX", "CENTER", "high", vs=None, target="B_SCT_1"),
                                        mission("FLANK", "NORTH", "medium"), mission("RECON", "NORTH", "low")])])
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R3", "ENGAGE")
    m0 = t["phases"][0]["missions"][0]
    assert m0["vs"] == "INFANTRY" and "target" not in m0


def test_r3_engage_ignores_attack_task():
    # in contact at ratio 1.6 but the mission already ATTACKs -> HOLD_FIRE path not ENGAGE
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 200~300")],
                phases=[phase(missions=[mission("ATTACK", "CENTER", "high"), mission("FLANK", "NORTH", "medium"), mission("RECON", "NORTH", "low")])],
                statuses=[status("M01", "ATTACK", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])])
    row = decide(pk)
    ok(row, "KEEP", "R3", "HOLD_FIRE")


def test_r3_engage_multi_mission():
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_SPE_1", "SPEARMAN", q=-11, r=0, soldiers=380),
                            unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 200~300"), enemy("B_INF_2", q=-12, r=0, est="약 200~300")],
                phases=[phase(missions=[mission("FIX", "CENTER", "high"), mission("FLANK", "WEST", "medium"), mission("RECON", "NORTH", "low")])],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "WEST", ["R_SPE_1"]), status("M03", "RECON", "NORTH", [])])
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R3", "ENGAGE")
    assert t["phases"][0]["missions"][0]["task"] == "ATTACK"
    assert t["phases"][0]["missions"][1]["task"] == "ATTACK"
    assert t["phases"][0]["missions"][2]["task"] == "RECON"


def test_r3_drop_ratio_band_low():
    # ratio 400/667 = 0.60 -> inside 0.55-0.65 band
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 617~717")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])])
    dropped(decide(pk), "ambig_ratio")


def test_r3_drop_ratio_band_high():
    # ratio 400/444 = 0.90 -> inside 0.85-0.95 band
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 394~494")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])])
    dropped(decide(pk), "ambig_ratio")


def test_r3_pull_back_with_losses():
    events = [{"kind": "FRIENDLY_UNIT_ATTACKED", "turn": 6,
               "detail": {"defender_id": "R_INF_1", "mission_id": "M01", "attacker_id": "B_CAV_1"}}]
    # ratio 400/800 = 0.50 with losses -> WITHDRAW
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 750~850")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])],
                events=events)
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R3", "PULL_BACK")
    assert t["phases"][0]["missions"][0]["task"] == "WITHDRAW"


def test_r3_pull_back_needs_losses():
    # same bad ratio but no loss event -> HOLD_FIRE
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 750~850")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])])
    row = decide(pk)
    ok(row, "KEEP", "R3", "HOLD_FIRE")


def test_r3_losses_by_mission_id():
    events = [{"kind": "UNIT_LOST", "turn": 6, "detail": {"unit_id": "R_SCT_1", "class": "SCOUT"}}]
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 750~850")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1", "R_SCT_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])],
                events=events)
    row = decide(pk)
    ok(row, "AMEND_PLAN", "R3", "PULL_BACK")


def test_r3_hold_fire_mid_ratio():
    # 400 vs 533 -> ratio 0.75 (between PULL_AT and ENGAGE_AT)
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 483~583")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])])
    row = decide(pk)
    t = ok(row, "KEEP", "R3", "HOLD_FIRE")
    assert "Not attacking now" in t["reason"]


def test_r3_vs_troop_mass_tie_break():
    # two contacted classes with 1 formation each: troop mass decides (SPEARMAN heavier)
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0, soldiers=800), unit("R_HQ_1", "HQ", 30, 0, "SOUTH", 300)],
                enemies=[enemy("B_CAV_1", "CAVALRY", q=11, r=0, est="약 150~250"),
                         enemy("B_SPE_1", "SPEARMAN", q=13, r=0, est="약 300~450")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])])
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R3", "ENGAGE")
    assert t["phases"][0]["missions"][0]["vs"] == "SPEARMAN"


def test_r3_vs_true_tie_drops():
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0, soldiers=800), unit("R_HQ_1", "HQ", 30, 0, "SOUTH", 300)],
                enemies=[enemy("B_CAV_1", "CAVALRY", q=11, r=0, est="약 150~250"),
                         enemy("B_SPE_1", "SPEARMAN", q=13, r=0, est="약 150~250")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])])
    dropped(decide(pk), "ambig_enemy_class_tie")


def test_r3_bad_estimate_drops():
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="unknown")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])])
    dropped(decide(pk), "bad_troop_estimate")


def test_r4_retarget_simple():
    ph = [phase(missions=[mission("FIX", "CENTER", "high"), mission("FLANK", "WEST", "medium"), mission("RECON", "NORTH", "low")])]
    pk = packet(phases=ph,
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "WEST", []), status("M03", "RECON", "NORTH", [])],
                friendlies=[unit("R_INF_1", q=16), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=-8, region="WEST"), enemy("B_CAV_1", "CAVALRY", q=-10, region="WEST"),
                         enemy("B_SCT_1", "SCOUT", q=-6, region="WEST"), enemy("B_ARC_1", "ARCHER", q=-12, region="WEST"),
                         enemy("B_INF_2", q=2, region="EAST")])
    # 4/5 visible enemies in WEST (80%): M01 FIX/CENTER (0 enemies in CENTER) -> WEST
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R4", "RETARGET")
    assert t["phases"][0]["missions"][0]["area"] == "WEST"


def test_r4_flank_side_away_from_main_effort():
    # enemies all CENTER (100%); main effort NORTH (M03 high at NORTH); FLANK/WEST -> the
    # sector adjacent to CENTER away from NORTH is SOUTH (unique positive projection).
    ph = [phase(missions=[mission("FIX", "EAST", "medium"), mission("FLANK", "WEST", "medium"), mission("RECON", "NORTH", "high")])]
    pk = packet(phases=ph,
                statuses=[status("M01", "FIX", "EAST", ["R_INF_1"]), status("M02", "FLANK", "WEST", []), status("M03", "RECON", "NORTH", [])],
                friendlies=[unit("R_INF_1", q=16), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=-8, region="CENTER"), enemy("B_CAV_1", "CAVALRY", q=-10, region="CENTER"),
                         enemy("B_SCT_1", "SCOUT", q=-6, region="CENTER")])
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R4", "RETARGET")
    # M01 FIX/EAST also qualifies (0 enemies EAST) -> retargets into CENTER itself
    assert t["phases"][0]["missions"][0]["area"] == "CENTER"
    assert t["phases"][0]["missions"][1]["area"] == "SOUTH"


def test_r4_flank_tie_drops():
    # enemies WEST (100%); main effort CENTER -> flank side NORTH/SOUTH tie -> drop
    ph = [phase(missions=[mission("FIX", "CENTER", "high"), mission("FLANK", "NORTH", "medium"), mission("RECON", "SOUTH", "low")])]
    pk = packet(phases=ph,
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "SOUTH", [])],
                friendlies=[unit("R_INF_1", q=16), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=-8, region="WEST"), enemy("B_CAV_1", "CAVALRY", q=-10, region="WEST")])
    dropped(decide(pk), "ambig_r4_flank_side")


def test_r4_no_fire_below_60pct():
    ph = [phase(missions=[mission("FIX", "CENTER", "high"), mission("FLANK", "NORTH", "medium"), mission("RECON", "SOUTH", "low")])]
    pk = packet(phases=ph,
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "SOUTH", [])],
                friendlies=[unit("R_INF_1", q=16), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=-8, region="WEST"), enemy("B_CAV_1", "CAVALRY", q=-10, region="EAST")])
    row = decide(pk)
    ok(row, "KEEP", "R6", "NONE")


def test_r4_skips_recon_task():
    # only RECON missions have empty areas -> no FIX/ATTACK/ADVANCE/FLANK qualifier
    ph = [phase(missions=[mission("RECON", "CENTER", "high"), mission("RESERVE", "CENTER", "medium"), mission("RECON", "NORTH", "low")])]
    pk = packet(phases=ph,
                statuses=[status("M01", "RECON", "CENTER", ["R_INF_1"]), status("M02", "RESERVE", "CENTER", []), status("M03", "RECON", "NORTH", [])],
                friendlies=[unit("R_INF_1", q=16), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=-8, region="WEST"), enemy("B_CAV_1", "CAVALRY", q=-10, region="WEST")])
    row = decide(pk)
    ok(row, "KEEP", "R6", "NONE")


def test_r5_unstall_amend():
    acts = ["t3 MOVE 12,0", "t4 MOVE 10,0", "t4 MOVE 12,0", "t5 MOVE 11,0"]
    acts2 = ["t3 MOVE 12,1", "t4 MOVE 10,1", "t4 MOVE 12,1", "t5 MOVE 11,1"]
    ff = {"note": "n", "units": [ff_unit("R_INF_1", "M01", actions=acts),
                                 ff_unit("R_SPE_1", "M01", actions=acts2),
                                 ff_unit("R_HQ_1", "M03", actions=[])]}
    # 2 visible enemies CENTER + 1 NORTH: R4 stays quiet (no empty R4-task area),
    # most-visible sector CENTER is unique -> R5 retargets there
    pk = packet(friendlies=[unit("R_INF_1", q=11, r=0), unit("R_SPE_1", "SPEARMAN", q=11, r=1), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=0), enemy("B_INF_2", q=-2), enemy("B_CAV_1", "CAVALRY", q=0, r=-8, region="NORTH")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1", "R_SPE_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])],
                ff=ff)
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R5", "UNSTALL")
    assert t["phases"][0]["missions"][0]["task"] == "ADVANCE"
    assert t["phases"][0]["missions"][0]["area"] == "CENTER"


def test_r5_already_advance_keeps():
    acts = ["t3 MOVE 12,0", "t4 MOVE 10,0", "t4 MOVE 12,0", "t5 MOVE 11,0"]
    acts2 = ["t3 MOVE 12,1", "t4 MOVE 10,1", "t4 MOVE 12,1", "t5 MOVE 11,1"]
    ff = {"note": "n", "units": [ff_unit("R_INF_1", "M01", actions=acts),
                                 ff_unit("R_SPE_1", "M01", actions=acts2),
                                 ff_unit("R_HQ_1", "M03", actions=[])]}
    pk = packet(friendlies=[unit("R_INF_1", q=11, r=0), unit("R_SPE_1", "SPEARMAN", q=11, r=1), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=0), enemy("B_INF_2", q=-2), enemy("B_CAV_1", "CAVALRY", q=0, r=-8, region="NORTH")],
                phases=[phase(missions=[mission("ADVANCE", "CENTER", "high"), mission("FLANK", "NORTH", "medium"), mission("RECON", "NORTH", "low")])],
                statuses=[status("M01", "ADVANCE", "CENTER", ["R_INF_1", "R_SPE_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])],
                ff=ff)
    row = decide(pk)
    ok(row, "KEEP", "R5", "UNSTALL")


def test_r5_failed_actions_do_not_move():
    acts = ["t3 MOVE 12,0 (failed)", "t4 MOVE 10,0 (failed)", "t4 MOVE 12,0 (failed)", "t5 MOVE 11,0 (failed)"]
    ff = {"note": "n", "units": [ff_unit("R_INF_1", "M01", actions=acts),
                                 ff_unit("R_SPE_1", "M01", actions=acts),
                                 ff_unit("R_HQ_1", "M03", actions=[])]}
    # nothing actually moved (every action failed) -> R5 stays quiet
    pk = packet(friendlies=[unit("R_INF_1", q=11, r=0), unit("R_SPE_1", "SPEARMAN", q=11, r=1), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=0), enemy("B_INF_2", q=-2), enemy("B_CAV_1", "CAVALRY", q=0, r=-8, region="NORTH")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1", "R_SPE_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])],
                ff=ff)
    row = decide(pk)
    ok(row, "KEEP", "R6", "NONE")


def test_r5_single_unit_no_fire():
    acts = ["t3 MOVE 12,0", "t4 MOVE 10,0", "t4 MOVE 12,0", "t5 MOVE 11,0"]
    ff = {"note": "n", "units": [ff_unit("R_INF_1", "M01", actions=acts),
                                 ff_unit("R_SPE_1", "M01", actions=["t5 WAIT"]),
                                 ff_unit("R_HQ_1", "M03", actions=[])]}
    pk = packet(friendlies=[unit("R_INF_1", q=11, r=0), unit("R_SPE_1", "SPEARMAN", q=11, r=1), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=0), enemy("B_INF_2", q=-2), enemy("B_CAV_1", "CAVALRY", q=0, r=-8, region="NORTH")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1", "R_SPE_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])],
                ff=ff)
    row = decide(pk)
    ok(row, "KEEP", "R6", "NONE")


def test_r5_sector_tie_drops():
    acts = ["t3 MOVE 12,0", "t4 MOVE 10,0", "t4 MOVE 12,0", "t5 MOVE 11,0"]
    acts2 = ["t3 MOVE 12,1", "t4 MOVE 10,1", "t4 MOVE 12,1", "t5 MOVE 11,1"]
    ff = {"note": "n", "units": [ff_unit("R_INF_1", "M01", actions=acts),
                                 ff_unit("R_SPE_1", "M01", actions=acts2),
                                 ff_unit("R_HQ_1", "M03", actions=[])]}
    pk = packet(friendlies=[unit("R_INF_1", q=11, r=0), unit("R_SPE_1", "SPEARMAN", q=11, r=1), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=-8, region="WEST"), enemy("B_CAV_1", "CAVALRY", q=-10, region="EAST")],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1", "R_SPE_1"]), status("M02", "FLANK", "NORTH", []), status("M03", "RECON", "NORTH", [])],
                ff=ff)
    dropped(decide(pk), "ambig_sector_tie")


def test_r6_keep_baseline():
    # no contact, no empty R4-task area, no stalled units -> plain KEEP
    pk = packet(phases=[phase(missions=[mission("FIX", "CENTER", "high"), mission("RESERVE", "CENTER", "medium"), mission("RECON", "NORTH", "low")])],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "RESERVE", "CENTER", []), status("M03", "RECON", "NORTH", [])])
    row = decide(pk)
    ok(row, "KEEP", "R6", "NONE")


def test_missing_v2_field_dropped():
    pk = packet()
    pk.pop("force_feedback")
    dropped(decide(pk), "missing_v2_field")
    pk2 = packet()
    pk2["plan_live"]["mission_statuses"][0].pop("units_source")
    dropped(decide(pk2), "missing_v2_field")
    pk3 = packet()
    pk3.pop("compact_state")
    dropped(decide(pk3), "missing_v2_field")


def test_amend_changes_only_named_fields():
    ph = [phase(missions=[mission("FIX", "CENTER", "high", vs="CAVALRY", win=[{"when": "TURNS_ELAPSED", "turns": 3}]),
                          mission("FLANK", "NORTH", "medium"), mission("RECON", "NORTH", "low")])]
    pk = packet(phases=ph,
                friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 200~300")])
    row = decide(pk)
    t = ok(row, "AMEND_PLAN", "R3", "ENGAGE")
    orig = pk["plan_authoring"]["phases"]
    assert len(t["phases"]) == len(orig)
    for po, pn in zip(orig, t["phases"]):
        for k in po:
            if k == "missions":
                continue
            assert po[k] == pn[k], "phase key %s changed" % k
    for i, (mo, mn) in enumerate(zip(orig[0]["missions"], t["phases"][0]["missions"])):
        for k in set(mo) | set(mn):
            if i == 0 and k in ("task", "vs"):
                continue
            assert mo.get(k) == mn.get(k), "mission %d key %s changed" % (i, k)
    assert t["phases"][0]["missions"][0]["win"] == [{"when": "TURNS_ELAPSED", "turns": 3}]


def test_targets_are_json_objects_and_deterministic():
    for build in (packet, lambda: packet(trigger="PHASE_SUCCESS"), lambda: packet(trigger="PHASE_FAILED", phases=[phase(on_fail="ADVANCE")])):
        pk = build()
        a, b = decide(copy.deepcopy(pk)), decide(copy.deepcopy(pk))
        assert a == b, "decide() is not deterministic"


def test_troop_mid_and_hexdist():
    assert troop_mid("약 150~250") == 200.0
    assert troop_mid("약 350~450") == 400.0
    assert troop_mid("unknown") is None
    assert hexdist((12, 0), (10, 0)) == 2
    assert hexdist((0, 0), (1, -1)) == 1
    assert in_ambiguity_band(0.60) and in_ambiguity_band(0.90) and not in_ambiguity_band(1.6)


def test_reason_cites_ids_positions_counts_ratio():
    pk = packet(friendlies=[unit("R_INF_1", q=12, r=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=11, r=0, est="약 200~300")])
    row = decide(pk)
    why = row["why"]
    assert "R_INF_1" in why and "M01" in why and "1.6" in why and "400" in why


def test_v2_ok_gate():
    assert v2_ok(packet())
    bad = packet()
    bad["compact_state"]["friendly_units"] = []
    assert not v2_ok(bad)


ALL = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]


def main():
    for fn in ALL:
        fn()
        print("PASS", fn.__name__)
    print("ALL %d TESTS PASS" % len(ALL))
    assert len(ALL) >= 30, "need >= 30 test packets, have %d" % len(ALL)


if __name__ == "__main__":
    main()


# ------------------------------------------------------------------ R1 v2b
def test_r1b_attacks_with_closest_mission():
    # HQ (20,0) CENTER; threat at 6 hexes; M01 unit at q=16 (4 from HQ), M02 unit at q=0 (20 from HQ)
    pk = packet(friendlies=[unit("R_INF_1", q=16), unit("R_INF_2", q=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_CAV_1", "CAVALRY", q=14, r=0)],
                statuses=[status("M01", "FIX", "CENTER", ["R_INF_1"]), status("M02", "FLANK", "NORTH", ["R_INF_2"]),
                          status("M03", "RECON", "NORTH", [])])
    t = ok(decide(pk), "AMEND_PLAN", "R1", "HQ_DEFENSE")
    m = t["phases"][0]["missions"][0]
    assert (m["task"], m["area"], m["vs"], m["priority"]) == ("ATTACK", "CENTER", "CAVALRY", "high")


def test_r1b_unmanned_hold_is_not_cover():
    # a HOLD mission in the HQ region with 0 units no longer counts as cover
    pk = packet(friendlies=[unit("R_INF_1", q=8), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=15, r=0)],
                phases=[phase(missions=[mission("HOLD", "CENTER", "high"), mission("RESERVE", "CENTER", "medium"), mission("RECON", "NORTH", "low")])],
                statuses=[status("M01", "HOLD", "CENTER", []), status("M02", "RESERVE", "CENTER", ["R_INF_1"]),
                          status("M03", "RECON", "NORTH", [])])
    t = ok(decide(pk), "AMEND_PLAN", "R1", "HQ_DEFENSE")
    assert t["phases"][0]["missions"][1]["task"] == "ATTACK"  # the only manned mission


def test_r1b_covered_by_manned_attack():
    # v2c: any manned ATTACK mission in the HQ region covers the HQ (unit may still be walking back) -> R1 quiet
    pk = packet(friendlies=[unit("R_INF_1", q=8), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=8, r=0)],
                phases=[phase(missions=[mission("ATTACK", "CENTER", "high"), mission("RESERVE", "CENTER", "medium"), mission("RECON", "NORTH", "low")])],
                statuses=[status("M01", "ATTACK", "CENTER", ["R_INF_1"]), status("M02", "RESERVE", "CENTER", []),
                          status("M03", "RECON", "NORTH", [])])
    assert decide(pk)["rule"] != "R1"


def test_r1b_radius_is_8():
    base = dict(friendlies=[unit("R_INF_1", q=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)])
    assert decide(packet(enemies=[enemy("B_INF_1", q=12, r=0)], **base))["rule"] == "R1"
    assert decide(packet(enemies=[enemy("B_INF_1", q=11, r=0)], **base))["rule"] != "R1"


def test_noop_amend_falls_through():
    # R1 would rewrite the plan with the mission it already has (ATTACK CENTER vs INFANTRY, high, but unmanned)
    ms = [mission("ATTACK", "CENTER", "high", vs="INFANTRY"), mission("RESERVE", "CENTER", "medium"), mission("RECON", "NORTH", "low")]
    pk = packet(friendlies=[unit("R_INF_1", q=0), unit("R_HQ_1", "HQ", 20, 0, "CENTER", 300)],
                enemies=[enemy("B_INF_1", q=15, r=0)], phases=[phase(missions=ms)],
                statuses=[status("M01", "ATTACK", "CENTER", []), status("M02", "RESERVE", "CENTER", []),
                          status("M03", "RECON", "NORTH", [])])
    row = decide(pk)
    if row["target"] and row["target"]["decision"] == "AMEND_PLAN":
        assert row["target"]["phases"] != pk["plan_authoring"]["phases"]
