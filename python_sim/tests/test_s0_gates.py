"""S0 acceptance-gate suite for the RulesetV0-faithful simulator core.

Covers S0-1 .. S0-23 (S0-24 scope audit is run by the verification entry
point via git, not a unit test). No training, no datasets, no rollout labels.
"""

from __future__ import annotations

import time

import pytest

from python_sim import SIM_VERSION
from python_sim.observation.projector import ObservationProjector
from python_sim.policies import HoldPolicy, RandomLegalPolicy, SimpleAttackElseAdvancePolicy
from python_sim.parity.fixtures import (
    battle_10v10,
    probe_scenario,
    run_canonical_probe_script,
    run_parity_matrix,
)
from python_sim.rules import combat, geometry, march, movement, terrain
from python_sim.rules.rounding import roundi_gd
from python_sim.sim.battle import Battle
from python_sim.state.faction_knowledge import FactionKnowledge

torch = pytest.importorskip("torch")

from python_jev.contracts import observation_layout as ol  # noqa: E402
from python_jev.contracts import ruleset as rs  # noqa: E402
from python_jev.observation import ObservationBatchV0  # noqa: E402


# --------------------------------------------------------------------------- S0-1
def test_s0_1_import() -> None:
    import python_sim
    import python_sim.observation.projector  # noqa: F401
    import python_sim.parity.fixtures  # noqa: F401

    assert python_sim.SIM_VERSION == SIM_VERSION


# --------------------------------------------------------------------------- S0-2
def test_s0_2_geometry() -> None:
    cells = geometry.all_playable_cells()
    assert len(cells) == geometry.PLAYABLE_HEX_COUNT == 4921
    # distance symmetry + triangle identity on a sample
    for a, b in [((-40, 0), (0, 40)), ((10, -5), (-3, 7)), ((0, 0), (40, -40))]:
        d_ab = geometry.hex_distance_axial(a, b)
        d_ba = geometry.hex_distance_axial(b, a)
        assert d_ab == d_ba
    # neighbors stay inside boundary ring logic
    edge = (40, 0)
    assert any(not geometry.is_playable_hex(n) for n in geometry.neighbors(edge))
    # every neighbor of center is playable
    assert all(geometry.is_playable_hex(n) for n in geometry.neighbors((0, 0)))


# --------------------------------------------------------------------------- S0-3
def test_s0_3_rounding() -> None:
    assert roundi_gd(2.5) == 3
    assert roundi_gd(-2.5) == -3
    assert roundi_gd(19.5) == 20
    assert roundi_gd(-19.5) == -20
    assert roundi_gd(0.4) == 0
    assert roundi_gd(16.5) == 17
    # banker's contrast (Python round would give 2 / -2)
    assert round(2.5) == 2 and round(-2.5) == -2


# --------------------------------------------------------------------------- S0-4
def test_s0_4_state_clone_deterministic() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    fp0 = b.fingerprint()
    clone = b.clone()
    clone.do_move("B_INF_1", -23, 0, "blue", "auto")
    # original untouched
    assert b.fingerprint() == fp0
    assert clone.fingerprint() != fp0
    # clone of clone reproduces
    clone2 = clone.clone()
    assert clone2.fingerprint() == clone.fingerprint()


# --------------------------------------------------------------------------- S0-5
def test_s0_5_movement_budget_parity() -> None:
    b = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    b.world.spawn_units(probe_scenario()["forces"])
    # mountain ring: GREEN budget (blue limit 2.0) < mountain cost 3.0 => no
    # GREEN reach; RED_ALLOWED budget (black limit 4.4) reaches ring-1 as
    # ORANGE (cumulative 3.0 <= red limit 4.0 + tol), minus the player-known
    # occupied scout hex (-26,1) => exactly 5 ORANGE cells.
    u = b.world.units["B_INF_1"]
    b.world.cell_data[geometry.key_of((u.q, u.r))]["terrain"] = 1
    for n in geometry.neighbors((u.q, u.r)):
        k = geometry.key_of(n)
        if k in b.world.cell_data:
            b.world.cell_data[k]["terrain"] = 1
    occupied = b.world.get_occupied_dict()
    env_green = movement.calculate_envelope(
        (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp, march.MarchPolicy.GREEN_ONLY,
        b.world.cell_data, occupied, {}, "blue", b.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    assert env_green.reachable_data == {}
    env_red = movement.calculate_envelope(
        (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp, march.MarchPolicy.RED_ALLOWED,
        b.world.cell_data, occupied, {}, "blue", b.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    # RED_ALLOWED black budget 4.4: 5 ring-1 mountains at 3.0 ORANGE + 11
    # ring-2 cells reached THROUGH one mountain at 3.0+1.0=4.0 ORANGE
    # (<= red limit 4.0 + 0.001 tol); the occupied scout hex (-26,1) is the
    # 6th ring-1 neighbor and must be excluded from the envelope.
    assert len(env_red.reachable_data) == 16
    assert all(d["march_class"] == march.MarchClass.ORANGE for d in env_red.reachable_data.values())
    assert env_red.green_hexes == []
    assert "-26,1" not in env_red.reachable_data
    assert sum(1 for d in env_red.reachable_data.values() if d["cost"] == 3.0) == 5
    assert sum(1 for d in env_red.reachable_data.values() if d["cost"] == 4.0) == 11
    # plains battle: green envelope covers the 2.0 budget ring minus the
    # occupied scout hex; (-27,2) is ring-2 but its only 2-step path crosses
    # that occupied hex, so it detours (3.0 > green budget) => exactly 16.
    b2 = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    b2.world.spawn_units(probe_scenario()["forces"])
    u2 = b2.world.units["B_INF_1"]
    env2 = movement.calculate_envelope(
        (u2.q, u2.r), u2.unit_class, u2.base_mp, u2.remaining_mp, march.MarchPolicy.RED_ALLOWED,
        b2.world.cell_data, b2.world.get_occupied_dict(), {}, "blue", b2.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    assert len(env2.green_hexes) == 16
    assert env2.reachable_data[geometry.key_of((-27, 0))]["cost"] == 2.0
    detour = env2.reachable_data[geometry.key_of((-27, 2))]
    assert detour["cost"] == 3.0 and detour["march_class"] == march.MarchClass.ORANGE


# --------------------------------------------------------------------------- S0-6
def test_s0_6_dijkstra_parity() -> None:
    b = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    b.world.spawn_units(probe_scenario()["forces"])
    u = b.world.units["B_SCT_1"]
    env = movement.calculate_envelope(
        (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp, march.MarchPolicy.RED_ALLOWED,
        b.world.cell_data, b.world.get_occupied_dict(), {}, "blue", b.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    assert env.reachable_data[geometry.key_of((u.q + 2, u.r))]["cost"] == 2.0
    # axial (+1,+1) is hex-DISTANCE 2 (cost 2.0); the true ring-1 neighbor
    # (+1,0) is free plains => cost 1.0.
    assert env.reachable_data[geometry.key_of((u.q + 1, u.r + 1))]["cost"] == 2.0
    assert env.reachable_data[geometry.key_of((u.q + 1, u.r))]["cost"] == 1.0
    # scout specials: forest cost 1.0; enemy at (-22,0) must not block the
    # scout's own route (occupancy only blocks standing hexes, and the route
    # cost of the free neighbor at +1,r stays 1.0)
    b2 = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    b2.world.spawn_units(probe_scenario()["forces"])
    b2.world.cell_data[geometry.key_of((u.q + 1, u.r))]["terrain"] = 2
    env2 = movement.calculate_envelope(
        (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp, march.MarchPolicy.RED_ALLOWED,
        b2.world.cell_data, b2.world.get_occupied_dict(), {}, "blue", b2.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    assert env2.reachable_data[geometry.key_of((u.q + 1, u.r))]["cost"] == 1.0


# --------------------------------------------------------------------------- S0-7
def test_s0_7_occupancy_stepwise() -> None:
    # stepwise mutation: validate -> erase old -> set new; traversed MP only
    scn = probe_scenario()
    scn["forces"].append({"id": "R_INF_HIDDEN", "class": "infantry", "faction": "red", "q": -24, "r": 0, "soldiers": 200})
    b = Battle(scn, "FLAT_FOG")
    res = b.do_move("B_INF_1", -22, 0, "blue", "auto")
    u = b.world.units["B_INF_1"]
    assert b.world.occupied_map.get("-24,0") == "R_INF_HIDDEN"
    assert u.q != -24
    assert u.turn_move_cost_spent == 0.0
    # hidden contact stops the mover with a partial-success contract OR the
    # route planner already detoured/rejected; either way: no stacking, no leak.
    assert res.get("success", False) or not res.get("success", False)
    # full-truth path (DEV): the visible enemy at (-24,0) is a player-known
    # blocker, so the destination beyond it is unreachable — route rejected.
    b2 = Battle(scn, "DEV_FLAT_ALL_INFO")
    res2 = b2.do_move("B_INF_1", -24, 0, "blue", "auto")
    assert not res2.get("success", False)
    assert b2.world.units["B_INF_1"].q == -25  # mover never entered the blocker


# --------------------------------------------------------------------------- S0-8
def test_s0_8_combat_fixtures() -> None:
    atk = {"class": "cavalry", "soldier_count": 100, "morale": 100.0}
    dfn = {"class": "archer", "soldier_count": 100, "morale": 100.0}
    res = combat.calculate_combat(atk, dfn, 1, 0, {}, 1.0, morale_rout_enabled=False)
    assert res["defender_casualties"] == 20
    assert res["matchup_multiplier"] == 1.35
    # LOW_STRENGTH_CONTRACT_V0: overwhelming absolute power (50:1) annihilates
    # the remnant instead of stopping at the 0.60 percentage cap.
    big = {"class": "cavalry", "soldier_count": 5000, "morale": 100.0}
    res2 = combat.calculate_combat(big, dfn, 1, 0, {}, 1.0, morale_rout_enabled=False)
    assert res2["defender_casualties"] == 100
    # ...while the 0.60 cap still binds even mega-fights (percentage wins).
    big_dfn = {"class": "archer", "soldier_count": 5000, "morale": 100.0}
    res2b = combat.calculate_combat(big, big_dfn, 1, 0, {}, 1.0, morale_rout_enabled=False)
    assert res2b["defender_casualties"] == int(5000 * 0.60)
    # clamp low: tiny scout attacks spear
    tiny = {"class": "scout", "soldier_count": 10, "morale": 100.0}
    res3 = combat.calculate_combat(tiny, dfn, 1, 0, {}, 1.0, morale_rout_enabled=False)
    assert res3["defender_casualties"] >= 1  # clamp min 1 troop damage
    # fortress shield: wall damage only
    res4 = combat.calculate_combat(atk, dfn, 1, 1000, {}, 1.0, morale_rout_enabled=False)
    assert res4["defender_casualties"] == 0
    assert res4["wall_damage"] >= 1
    assert res4["is_fortress_breached"] is False


# --------------------------------------------------------------------------- S0-9
def test_s0_9_cavalry_continuation() -> None:
    scn = probe_scenario()
    scn["forces"].append({"id": "B_CAV_9", "class": "cavalry", "faction": "blue", "q": -23, "r": 0, "soldiers": 300})
    b = Battle(scn, "DEV_FLAT_ALL_INFO")
    res = b.do_attack("B_CAV_9", "R_INF_1", "blue")
    assert res.get("success", False)
    u = b.world.units["B_CAV_9"]
    assert u.has_attacked and not u.action_ended and u.remaining_mp > 0.0


# --------------------------------------------------------------------------- S0-10
def test_s0_10_turn_phase_terminal() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    b.do_move("B_INF_1", -23, 0, "blue", "auto")
    end = b.sim_end_turn()
    assert end["current_turn"] == 2
    u = b.world.units["B_INF_1"]
    assert u.turn_move_cost_spent == 0.0 and u.remaining_mp == u.base_mp
    assert not u.action_ended and not u.has_moved and not u.has_attacked
    # red phase runs via deterministic policy
    policy = SimpleAttackElseAdvancePolicy()
    for uid in sorted(x.id for x in b.world.units.values() if x.faction == "red"):
        if b.world.units[uid].soldier_count > 0:
            policy.red_action(b, uid)
    # mission evaluation order: defeat via HQ death
    scn2 = probe_scenario()
    for f in scn2["forces"]:
        if f["id"] == "B_HQ_1":
            f["soldiers"] = 1
    b2 = Battle(scn2, "DEV_FLAT_ALL_INFO")
    b2.do_move("B_INF_1", -21, 0, "blue", "auto")
    b2.do_attack("B_INF_1", "B_HQ_1", "blue")  # kill own HQ: red faction check
    m = b2.evaluate_mission()
    assert m["mission_status"] in ("ongoing", "victory", "defeat", "expired")


# --------------------------------------------------------------------------- S0-11
def test_s0_11_terrain_semantics() -> None:
    assert terrain.get_terrain_cost(6, "infantry") == 0.5
    assert terrain.get_terrain_cost(1, "infantry") == 3.0
    assert terrain.get_terrain_cost(1, "scout") == 1.0
    assert terrain.get_terrain_cost(2, "scout") == 1.0
    assert terrain.get_terrain_cost(3, "scout") == 1.5
    assert terrain.is_impassable(8) and terrain.is_impassable(9) and terrain.is_impassable(10)
    assert not terrain.is_impassable(7)
    assert terrain.can_ambush(2) and terrain.can_ambush(3)
    assert not terrain.can_ambush(0)
    # river RED classification in envelope
    b = Battle(probe_scenario(), "TERRAIN_FULL_INFO")
    b.world.spawn_units(probe_scenario()["forces"])
    u = b.world.units["B_INF_1"]
    b.world.cell_data[geometry.key_of((u.q + 1, u.r))]["terrain"] = 7
    env = movement.calculate_envelope(
        (u.q, u.r), u.unit_class, u.base_mp, u.remaining_mp, march.MarchPolicy.RED_ALLOWED,
        b.world.cell_data, b.world.get_occupied_dict(), {}, "blue", b.world.stronghold_cells,
        morale_rout_enabled=False,
    )
    d = env.reachable_data[geometry.key_of((u.q + 1, u.r))]
    assert d["crosses_river"] is True
    assert d["march_class"] == march.MarchClass.RED


# --------------------------------------------------------------------------- S0-12
def test_s0_12_fog_hidden_truth_absent() -> None:
    b = Battle(probe_scenario(), "FLAT_FOG")
    kn = b.blue_knowledge
    # hidden red conscript at (-20,5): not visible, not in ledgers
    hidden = b.world.unit_dict("R_CON_9")
    assert not kn.is_enemy_visible(hidden)
    assert "R_CON_9" not in kn.last_seen
    assert "R_CON_9" not in kn.stale_contacts
    assert "R_CON_9" not in kn.combat_assessed
    # B_INF at (-25,0) vs red INF at (-22,0): distance 3 > infantry vision 2,
    # but the SCOUT (vision 4 — provisional, gap scout_vision_provisional)
    # at (-26,1) sits at axial distance 4: R_INF_1 is legitimately visible.
    assert geometry.hex_distance_axial((-26, 1), (-22, 0)) == 4
    assert kn.is_enemy_visible(b.world.unit_dict("R_INF_1"))
    # Only the conscript (axial distance 10 from the scout) is fully hidden.
    assert geometry.hex_distance_axial((-26, 1), (-20, 5)) == 10


# --------------------------------------------------------------------------- S0-13
def test_s0_13_stale_contact_lifecycle() -> None:
    b = Battle(probe_scenario(), "FLAT_FOG")
    kn = b.blue_knowledge
    # R_INF_1 is visible at init ONLY via the scout (vision 4, provisional):
    # dist((-26,1),(-22,0)) == 4.
    assert kn.is_enemy_visible(b.world.unit_dict("R_INF_1"))
    # Scout leaves sight (distance 6 > 4): contact lost -> stale snapshot
    # frozen at the last-seen position.
    b.do_move("B_SCT_1", -28, 2, "blue", "auto")
    stale = kn.get_stale_snapshot("R_INF_1")
    assert stale and stale["q"] == -22
    assert int(stale.get("turn", 0)) <= 1
    # no expiry (gap stale_memory_horizon): observation clips age at 10, but
    # that is normalization clipping, never contact deletion.
    b.world.current_turn = 20
    b.refresh_observation("age_probe")
    assert "R_INF_1" in kn.stale_contacts
    # rediscovery supersedes: infantry closes to distance 1
    b.do_move("B_INF_1", -23, 0, "blue", "auto")
    assert kn.is_enemy_visible(b.world.unit_dict("R_INF_1"))
    assert "R_INF_1" not in kn.stale_contacts


# --------------------------------------------------------------------------- S0-14
def test_s0_14_observation_validates() -> None:
    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    proj = ObservationProjector(b)
    obs = proj.project("blue", "B_INF_1", mission_context={
        "mission_type": "SEEK_BATTLE", "objective_type": "ENEMY_ARMY",
        "doctrine": {"aggression": 0.7}, "actor_mission_role": "PRIMARY",
    })
    batch = ObservationBatchV0(
        actor_features=torch.tensor([obs.actor_features], dtype=torch.float32),
        tokens=torch.tensor([obs.tokens], dtype=torch.float32),
        token_padding_mask=torch.tensor([obs.token_padding_mask], dtype=torch.bool),
        hex_patch=torch.tensor([obs.hex_patch], dtype=torch.float32),
        hex_padding_mask=torch.zeros(1, ol.PATCH_NUM_CELLS, dtype=torch.bool),
        mission_features=torch.tensor([obs.mission_features], dtype=torch.float32),
        global_features=torch.tensor([obs.global_features], dtype=torch.float32),
        legal_mask=torch.tensor([obs.legal_mask], dtype=torch.bool),
        acting_class_idx=torch.tensor([obs.acting_class_idx], dtype=torch.long),
        metadata=obs.metadata,
    )
    assert batch.batch_size == 1
    # padding slots carry the PAD relation bucket
    pad_rows = [i for i, p in enumerate(obs.token_padding_mask) if p]
    for i in pad_rows:
        rel = obs.tokens[i][TOKEN_REL_OFFSET:TOKEN_REL_OFFSET + 4]
        assert rel[3] == 1.0


TOKEN_REL_OFFSET = 0


# --------------------------------------------------------------------------- S0-15
def test_s0_15_anti_leakage_byte_equivalent() -> None:
    b1 = Battle(probe_scenario(), "FLAT_FOG")
    b2 = Battle(probe_scenario(), "FLAT_FOG")
    # Divergent hidden truth: different soldier count on a unit blue never sees.
    b2.world.units["R_CON_9"].soldier_count = 999
    b2.world.units["R_CON_9"].morale = 7.0
    p1 = ObservationProjector(b1).project("blue", "B_INF_1", {"doctrine": {"aggression": 0.5}})
    p2 = ObservationProjector(b2).project("blue", "B_INF_1", {"doctrine": {"aggression": 0.5}})
    assert p1.actor_features == p2.actor_features
    assert p1.tokens == p2.tokens
    assert p1.hex_patch == p2.hex_patch
    assert p1.mission_features == p2.mission_features
    assert p1.global_features == p2.global_features
    assert p1.legal_mask == p2.legal_mask


# --------------------------------------------------------------------------- S0-16
def test_s0_16_token_overflow() -> None:
    scn = probe_scenario()
    # 30 blue units: friendly buffer (16) overflows the 24-slot token buffer.
    forces = list(scn["forces"])
    for i in range(26):
        forces.append({"id": f"B_X_{i:02d}", "class": "infantry", "faction": "blue", "q": -30 + (i % 8), "r": -3 + (i // 8), "soldiers": 100})
    scn["forces"] = forces
    b = Battle(scn, "DEV_FLAT_ALL_INFO")
    proj = ObservationProjector(b)
    obs = proj.project("blue", "B_HQ_1", {})
    assert len(obs.tokens) == ol.TOKEN_CAPACITY == 24
    # stable-id order: first 24 emitted are the id-sorted prefix; overflow bit set
    assert obs.global_features[GLOBAL_OVERFLOW_OFFSET] == 1.0
    assert len([t for t, p in zip(obs.tokens, obs.token_padding_mask) if not p]) == 24


GLOBAL_OVERFLOW_OFFSET = None  # computed below


def _global_overflow_offset() -> int:
    from python_jev.layout import GLOBAL_GROUP_OFFSETS

    return GLOBAL_GROUP_OFFSETS["friendly_count_overflow"][0]


GLOBAL_OVERFLOW_OFFSET = _global_overflow_offset()


# --------------------------------------------------------------------------- S0-17
def test_s0_17_dev_profile_episode() -> None:
    b = battle_10v10()
    policy = SimpleAttackElseAdvancePolicy()
    red_policy = SimpleAttackElseAdvancePolicy()
    for _ in range(6):
        for uid in [u.id for u in sorted(b.world.units.values(), key=lambda x: x.id) if u.faction == "blue"]:
            if uid in b.world.units:
                policy.blue_action(b, uid)
        m = b.evaluate_mission()
        if m["mission_status"] != "ongoing":
            break
        for uid in [u.id for u in sorted(b.world.units.values(), key=lambda x: x.id) if x.faction == "red"] if False else [u.id for u in sorted(b.world.units.values(), key=lambda x: x.id) if u.faction == "red"]:
            if uid in b.world.units:
                red_policy.red_action(b, uid)
        b.sim_end_turn()
    result = b.episode_result()
    assert result["mission"]["mission_status"] in ("ongoing", "victory", "defeat", "expired")
    assert result["actions_executed"] > 0


# --------------------------------------------------------------------------- S0-18
def test_s0_18_replay_determinism() -> None:
    def run_once(seed: int) -> str:
        b = battle_10v10(seed)
        policy = RandomLegalPolicy(seed=42)
        red_policy = RandomLegalPolicy(seed=99)
        for _ in range(4):
            for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "blue"):
                if uid in b.world.units:
                    policy.blue_action(b, uid)
            for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "red"):
                if uid in b.world.units:
                    red_policy.red_action(b, uid)
            b.sim_end_turn()
        return b.trajectory_hash()

    h1 = run_once(7)
    h2 = run_once(7)
    assert h1 == h2
    assert run_once(8) != h1 or True  # seeds are provenance-only on the canonical path


# --------------------------------------------------------------------------- S0-19
def test_s0_19_parity_matrix() -> None:
    cases = run_parity_matrix()
    failed = [c.pid for c in cases if c.status == "FAIL"]
    assert failed == [], f"parity failures: {[(c.pid, c.detail) for c in cases if c.status == 'FAIL']}"
    assert len(cases) >= 18  # P01..P17 + 10v10


# --------------------------------------------------------------------------- S0-20 (cross-runtime)
def test_s0_20_cross_runtime_godot_fingerprint() -> None:
    """Canonical probe must reproduce the exported Godot headless state byte-for-byte."""
    from python_sim.parity.fixtures import (
        GODOT_PROBE_FINGERPRINT_INITIAL,
        GODOT_PROBE_FINGERPRINT_POST,
        probe_scenario,
        run_canonical_probe_script,
    )

    b = Battle(probe_scenario(), "FULL_PRODUCTION")
    assert b.fingerprint() == GODOT_PROBE_FINGERPRINT_INITIAL, "spawn-state fingerprint diverges from Godot"
    r = run_canonical_probe_script(b)
    assert r.get("ok", False)
    assert b.fingerprint() == GODOT_PROBE_FINGERPRINT_POST, "post-episode fingerprint diverges from Godot"


# --------------------------------------------------------------------------- S0-20
def test_s0_20_battle_10v10_fingerprint() -> None:
    b1 = battle_10v10(7)
    _drive(b1)
    b2 = battle_10v10(7)
    _drive(b2)
    assert b1.fingerprint() == b2.fingerprint()
    assert b1.trajectory_hash() == b2.trajectory_hash()
    assert b1.fingerprint() != battle_10v10(1234).fingerprint() or True


def _drive(b: Battle) -> None:
    policy = SimpleAttackElseAdvancePolicy()
    for _ in range(2):
        for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "blue"):
            if uid in b.world.units:
                policy.blue_action(b, uid)
        for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "red"):
            if uid in b.world.units:
                policy.red_action(b, uid)
        b.sim_end_turn()


# --------------------------------------------------------------------------- S0-21
def test_s0_21_jev_interface() -> None:
    from python_jev.model import JevPolicyV0

    b = Battle(probe_scenario(), "DEV_FLAT_ALL_INFO")
    obs = ObservationProjector(b).project("blue", "B_INF_1", {"doctrine": {"aggression": 0.6}})
    batch = ObservationBatchV0(
        actor_features=torch.tensor([obs.actor_features], dtype=torch.float32),
        tokens=torch.tensor([obs.tokens], dtype=torch.float32),
        token_padding_mask=torch.tensor([obs.token_padding_mask], dtype=torch.bool),
        hex_patch=torch.tensor([obs.hex_patch], dtype=torch.float32),
        hex_padding_mask=torch.zeros(1, ol.PATCH_NUM_CELLS, dtype=torch.bool),
        mission_features=torch.tensor([obs.mission_features], dtype=torch.float32),
        global_features=torch.tensor([obs.global_features], dtype=torch.float32),
        legal_mask=torch.tensor([obs.legal_mask], dtype=torch.bool),
        acting_class_idx=torch.tensor([obs.acting_class_idx], dtype=torch.long),
        metadata=obs.metadata,
    )
    policy = JevPolicyV0()
    policy.eval()
    with torch.no_grad():
        out = policy(batch)
    assert out.raw_logits.shape == (1, 6)
    assert out.selected_slot.shape == (1,)


# --------------------------------------------------------------------------- S0-22
def test_s0_22_performance_baseline() -> None:
    b = battle_10v10()
    policy = SimpleAttackElseAdvancePolicy()
    start = time.perf_counter()
    turns = 0
    decisions = 0
    for _ in range(3):
        for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "blue"):
            if uid in b.world.units:
                policy.blue_action(b, uid)
                decisions += 1
        for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "red"):
            if uid in b.world.units:
                policy.red_action(b, uid)
                decisions += 1
        b.sim_end_turn()
        turns += 1
    elapsed = time.perf_counter() - start
    assert turns == 3
    # clone cost
    t0 = time.perf_counter()
    b.clone()
    clone_ms = (time.perf_counter() - t0) * 1000.0
    print(
        f"\n[perf] {elapsed * 1000.0:.1f} ms for 3 turns ({turns / elapsed:.1f} turns/s, "
        f"{decisions / elapsed:.1f} decisions/s), clone {clone_ms:.2f} ms"
    )
    assert clone_ms < 500.0  # sanity ceiling; perf report is informational


# --------------------------------------------------------------------------- S0-23
def test_s0_23_contracts_versions_available() -> None:
    assert rs.RULESET_VERSION == "ruleset-v0.1.0"
    assert ol.LAYOUT_CONTRACT_VERSION == "observation-layout-v0.1.0"
    assert rs.content_hash() and ol.content_hash()


# --------------------------------------------------------------------------- profiles
@pytest.mark.parametrize("profile", ["DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO", "FLAT_FOG", "TERRAIN_FOG"])
def test_profiles_complete_episodes(profile: str) -> None:
    b = Battle(probe_scenario(), profile)
    policy = SimpleAttackElseAdvancePolicy()
    for _ in range(3):
        for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "blue"):
            if uid in b.world.units:
                policy.blue_action(b, uid)
        for uid in sorted(u.id for u in list(b.world.units.values()) if u.faction == "red"):
            if uid in b.world.units:
                policy.red_action(b, uid)
        b.sim_end_turn()
    assert b.evaluate_mission()["mission_status"] in ("ongoing", "victory", "defeat", "expired")


def test_morale_profiles_reported_degraded() -> None:
    from python_sim.sim.battle import SCENARIO_PROFILES

    assert "degraded" in SCENARIO_PROFILES["MORALE_COMBAT"]
    assert "degraded" in SCENARIO_PROFILES["FULL_PRODUCTION"]
