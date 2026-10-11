"""ObservationLayoutV0 projector — production-capable tensor emitter.

Contract source: python_jev/contracts/observation_layout.py (imported, never
duplicated) + python_jev/layout.py feature tables. The projector consumes
WorldState ONLY through the explicit recompute/project contract and each
side's FactionKnowledge; hidden truth has no other path in.

Token overflow: frozen contract rule — deterministic NON-TACTICAL truncation
in stable unit-id order (faction-authorized buffer order), never by distance
or strength, with the explicit overflow bit set in the global summary group.

Emitting order matches python_jev/layout.py tables exactly; the S0-14 test
validates output through python_jev.observation.ObservationBatchV0.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from python_jev.constants import LEARNED_CLASSES, TokenKind
from python_jev.layout import (
    ACTOR_FEATURE_DIM,
    ACTOR_GROUP_OFFSETS,
    CONTACT_MEMORY_HORIZON,
    ENEMY_VISIBLE_COUNT_REF,
    FRIENDLY_COUNT_REF,
    GLOBAL_FEATURE_DIM,
    GLOBAL_GROUP_OFFSETS,
    HEX_FEATURE_DIM,
    HEX_GROUP_OFFSETS,
    LEGAL_MASK_DIM,
    MAX_TRAVERSAL_COST,
    MISSION_FEATURE_DIM,
    MISSION_GROUP_OFFSETS,
    NUM_DIRECTION_BUCKETS,
    PATCH_NUM_CELLS,
    PATCH_RADIUS,
    STALE_CONTACT_COUNT_REF,
    TOKEN_CAPACITY,
    TOKEN_FEATURE_DIM,
    TOKEN_GROUP_OFFSETS,
)

from python_jev.contracts.hex_patch import RING_MAJOR_OFFSETS

from python_sim.rules import geometry, march, terrain as terrain_rules
from python_sim.rules.geometry import Hex
from python_sim.sim.battle import Battle

# Vocabulary tables (frozen in python_jev.contracts.observation_layout)
TERRAIN_VOCAB = ("PLAINS", "FOREST", "MOUNTAIN", "WATER", "ROAD", "UNKNOWN")
READINESS_VOCAB = ("READY", "ACTED", "UNKNOWN")
BLOCKING_VOCAB = ("PASSABLE", "BLOCKED", "UNKNOWN")
OCCUPANCY_VOCAB = ("EMPTY", "FRIENDLY", "ENEMY_VISIBLE", "STALE_MARKER", "UNKNOWN")
VIS_VOCAB = ("VISIBLE", "REMEMBERED", "UNEXPLORED")
ROUT_VOCAB = ("NONE", "AT_RISK", "ROUTING", "UNKNOWN", "NA")
STANCE_VOCAB = ("NONE", "HOLD", "SCREEN", "RESERVE", "OTHER", "UNKNOWN", "NA")
MISSION_TYPES = ("SEEK_BATTLE", "HOLD_GROUND", "CAPTURE", "DEFEND", "RECON", "UNKNOWN")
OBJECTIVE_TYPES = ("ENEMY_ARMY", "ENEMY_HQ", "HEX_OBJECTIVE", "SURVIVE", "UNKNOWN")
OBJ_STATUS = ("UNDONE", "IN_PROGRESS", "ACHIEVED", "FAILED", "UNKNOWN")
PHASES = ("EARLY", "MID", "LATE", "UNKNOWN", "NA")
BATTLE_PHASES = ("MOVEMENT", "COMBAT", "UNKNOWN", "NA")
POSSESSION = ("OURS", "ENEMY", "CONTESTED", "UNKNOWN", "NA")
ACTOR_MISSION_ROLES = ("PRIMARY", "SUPPORT", "RESERVE", "SCREEN", "RECON", "UNKNOWN", "NA")

# Godot terrain int -> obs terrain bucket (TERRAIN_VOCAB_GODOT_ALIGNED fold)
_GODOT_TERRAIN_TO_OBS: dict[int, str] = {
    0: "PLAINS",    # PLAINS
    1: "MOUNTAIN",  # MOUNTAINS
    2: "FOREST",
    3: "PLAINS",    # SWAMP folds into cost-class bucket (plains bucket, cost carries it)
    4: "PLAINS",    # FORTRESS interior approach (cost 1.0 class)
    5: "PLAINS",    # VILLAGE
    6: "ROAD",
    7: "WATER",     # RIVER
    8: "UNKNOWN",   # WALL (BLOCKED)
    9: "UNKNOWN",   # STRONGHOLD_FOOTPRINT (BLOCKED)
    10: "UNKNOWN",  # STRONGHOLD_WALL (BLOCKED)
    11: "UNKNOWN",  # CAPITAL_FOOTPRINT
    12: "UNKNOWN",  # CAPITAL_WALL
    13: "MOUNTAIN", # OUTER_MOUNTAIN
}


def _onehot(width: int, index: int) -> list[float]:
    v = [0.0] * width
    if 0 <= index < width:
        v[index] = 1.0
    return v


def _cat(table: tuple[str, ...], name: str) -> int:
    return table.index(name)


def _axial_distance(dq: int, dr: int) -> int:
    ds = -dq - dr
    return (abs(dq) + abs(dr) + abs(ds)) // 2


def _direction_bucket(dq: int, dr: int) -> int:
    """Synthetic-factory direction bucket convention (6 rays + center)."""
    if dq == 0 and dr == 0:
        return NUM_DIRECTION_BUCKETS - 1  # center bucket
    angle = math.degrees(math.atan2(dr, dq)) % 360.0
    return int(angle // 60.0) % 6


def _dir_unit(dq: int, dr: int) -> tuple[float, float]:
    d = math.hypot(dq, dr)
    if d == 0.0:
        return (0.0, 0.0)
    return (dq / d, dr / d)


@dataclass
class ProjectedObservation:
    """Dense numpy-free projection (lists of floats; S0-14 wraps into tensors)."""

    actor_features: list[float]
    tokens: list[list[float]]
    token_padding_mask: list[bool]
    hex_patch: list[list[float]]
    mission_features: list[float]
    global_features: list[float]
    legal_mask: list[bool]
    acting_class_idx: int
    metadata: dict[str, str]

    def dims_check(self) -> None:
        if len(self.actor_features) != ACTOR_FEATURE_DIM:
            raise RuntimeError(f"actor dim {len(self.actor_features)} != {ACTOR_FEATURE_DIM}")
        if len(self.tokens) != TOKEN_CAPACITY:
            raise RuntimeError(f"token count {len(self.tokens)} != capacity {TOKEN_CAPACITY}")
        for t in self.tokens:
            if len(t) != TOKEN_FEATURE_DIM:
                raise RuntimeError(f"token dim {len(t)} != {TOKEN_FEATURE_DIM}")
        if len(self.hex_patch) != PATCH_NUM_CELLS:
            raise RuntimeError(f"hex patch count {len(self.hex_patch)} != {PATCH_NUM_CELLS}")
        for h in self.hex_patch:
            if len(h) != HEX_FEATURE_DIM:
                raise RuntimeError(f"hex dim {len(h)} != {HEX_FEATURE_DIM}")
        if len(self.mission_features) != MISSION_FEATURE_DIM:
            raise RuntimeError(f"mission dim {len(self.mission_features)} != {MISSION_FEATURE_DIM}")
        if len(self.global_features) != GLOBAL_FEATURE_DIM:
            raise RuntimeError(f"global dim {len(self.global_features)} != {GLOBAL_FEATURE_DIM}")
        if len(self.legal_mask) != LEGAL_MASK_DIM:
            raise RuntimeError(f"legal mask dim {len(self.legal_mask)} != {LEGAL_MASK_DIM}")


class ObservationProjector:
    """Projects (Battle, side, actor_id, mission context) -> ProjectedObservation."""

    def __init__(self, battle: Battle) -> None:
        self.battle = battle

    # ------------------------------------------------------------------ main entry
    def project(
        self,
        side: str,
        actor_id: str,
        mission_context: dict | None = None,
    ) -> ProjectedObservation:
        w = self.battle.world
        knowledge = self.battle.blue_knowledge if side == "blue" else self.battle.red_knowledge
        actor = w.units.get(actor_id)
        if actor is None or actor.faction != side:
            raise ValueError(f"actor {actor_id!r} not found on side {side!r}")
        mission_context = mission_context or {}

        actor_dict = actor.to_dict()
        turn = w.current_turn

        # ---- token sets from FactionKnowledge (never raw truth) --------------
        enemy_faction = "red" if side == "blue" else "blue"
        own: list[dict] = []
        visible_enemies: list[dict] = []
        for uid in sorted(w.units.keys()):
            u = w.units[uid]
            if u.soldier_count <= 0 or u.garrisoned:
                continue
            if u.faction == side:
                own.append(u.to_dict())
            elif knowledge.is_enemy_visible(u.to_dict()):
                visible_enemies.append(u.to_dict())

        # ---- actor-relative helpers -----------------------------------------
        aq, ar = actor.q, actor.r

        def rel(u: dict) -> tuple[int, int, int, int]:
            dq, dr = int(u["q"]) - aq, int(u["r"]) - ar
            return dq, dr, _axial_distance(dq, dr), _direction_bucket(dq, dr)

        def strength_of(u: dict, known_default: bool) -> tuple[float, float]:
            sc = int(u.get("soldier_count", 0))
            mc = max(1, int(u.get("max_count", sc)))
            return (min(1.0, sc / mc), 1.0) if known_default else (0.0, 0.0)

        # ---- tokens -----------------------------------------------------------
        tokens: list[list[float]] = []
        token_pad: list[bool] = []

        def emit_token(kind: TokenKind, u: dict | None = None, stale: dict | None = None) -> None:
            feats = [0.0] * TOKEN_FEATURE_DIM
            if kind == TokenKind.PAD:
                feats[TOKEN_GROUP_OFFSETS["relation_kind"][0] + int(kind)] = 1.0
                tokens.append(feats)
                token_pad.append(True)
                return
            token_pad.append(False)
            # relation
            feats[TOKEN_GROUP_OFFSETS["relation_kind"][0] + int(kind)] = 1.0
            if u is not None:
                cls = str(u.get("class", ""))
                try:
                    cls_norm = {"spearman": "SPEARMAN", "spearmen": "SPEARMAN", "spear": "SPEARMAN",
                                "infantry": "INFANTRY", "cavalry": "CAVALRY", "archer": "ARCHER",
                                "archers": "ARCHER", "scout": "SCOUT", "scouts": "SCOUT"}[cls.lower()]
                    cls_idx = LEARNED_CLASSES.index(cls_norm)
                except (KeyError, ValueError):
                    cls_idx = len(LEARNED_CLASSES)  # UNKNOWN bucket (+ class_known=0)
                feats[TOKEN_GROUP_OFFSETS["unit_class"][0] + cls_idx] = 1.0
                s_ratio, s_known = strength_of(u, True)
                o0 = TOKEN_GROUP_OFFSETS["strength_ratio"][0]
                feats[o0], feats[o0 + 1] = s_ratio, s_known
                acted = bool(u.get("action_ended", False))
                r_idx = _cat(READINESS_VOCAB, "ACTED" if acted else "READY") if kind == TokenKind.FRIENDLY else _cat(READINESS_VOCAB, "UNKNOWN")
                r0 = TOKEN_GROUP_OFFSETS["readiness"][0]
                feats[r0:r0 + 3] = _onehot(3, r_idx)
                feats[TOKEN_GROUP_OFFSETS["readiness_known"][0]] = 1.0 if kind == TokenKind.FRIENDLY else 0.0
                dq, dr, dist, bucket = rel(u)
                self._write_geometry(feats, dq, dr, dist, bucket)
                # age: current observations are fresh
                a0 = TOKEN_GROUP_OFFSETS["age_ratio"][0]
                feats[a0], feats[a0 + 1] = 0.0, 0.0
                feats[TOKEN_GROUP_OFFSETS["uncertainty_radius_ratio"][0]] = 0.0
            else:
                assert stale is not None
                cls = str(stale.get("class", ""))
                try:
                    cls_norm = {"spearman": "SPEARMAN", "spearmen": "SPEARMAN", "spear": "SPEARMAN",
                                "infantry": "INFANTRY", "cavalry": "CAVALRY", "archer": "ARCHER",
                                "archers": "ARCHER", "scout": "SCOUT", "scouts": "SCOUT"}[cls.lower()]
                    cls_idx = LEARNED_CLASSES.index(cls_norm)
                except (KeyError, ValueError):
                    cls_idx = len(LEARNED_CLASSES)
                feats[TOKEN_GROUP_OFFSETS["unit_class"][0] + cls_idx] = 1.0
                # stale: class known (frozen fact), strength NOT updated while hidden
                # unless combat-assessed snapshot carries an approx.
                s0 = TOKEN_GROUP_OFFSETS["strength_ratio"][0]
                if stale.get("combat_assessed") and stale.get("combat_approx") is not None:
                    feats[s0] = min(1.0, int(stale["combat_approx"]) / 500.0)
                    feats[s0 + 1] = 1.0
                else:
                    feats[s0], feats[s0 + 1] = 0.0, 0.0
                r0 = TOKEN_GROUP_OFFSETS["readiness"][0]
                feats[r0:r0 + 3] = _onehot(3, _cat(READINESS_VOCAB, "UNKNOWN"))
                feats[TOKEN_GROUP_OFFSETS["readiness_known"][0]] = 0.0
                dq, dr = int(stale.get("q", 0)) - aq, int(stale.get("r", 0)) - ar
                dist = _axial_distance(dq, dr)
                bucket = _direction_bucket(dq, dr)
                self._write_geometry(feats, dq, dr, dist, bucket)
                age = float(turn - int(stale.get("turn", turn)))
                a0 = TOKEN_GROUP_OFFSETS["age_ratio"][0]
                feats[a0] = min(1.0, max(0.0, age / CONTACT_MEMORY_HORIZON))
                feats[a0 + 1] = 1.0
                feats[TOKEN_GROUP_OFFSETS["uncertainty_radius_ratio"][0]] = min(1.0, 0.5 * (dist / PATCH_RADIUS) + 0.1)
            # mission role: UNKNOWN + known=0 (no role ledger on this contract)
            m0 = TOKEN_GROUP_OFFSETS["mission_role"][0]
            feats[m0:m0 + len(ACTOR_MISSION_ROLES)] = _onehot(len(ACTOR_MISSION_ROLES), _cat(ACTOR_MISSION_ROLES, "UNKNOWN"))
            feats[TOKEN_GROUP_OFFSETS["mission_role_known"][0]] = 0.0
            tokens.append(feats)

        # Emission order: own forces (stable id), visible enemies (stable id),
        # stale contacts (stable id) — the contract's deterministic non-tactical
        # buffer order. Overflow truncates in THIS order and sets the bit.
        overflow = False
        for u in own:
            if len(tokens) >= TOKEN_CAPACITY:
                overflow = True
                break
            emit_token(TokenKind.FRIENDLY, u=u)
        for u in visible_enemies:
            if len(tokens) >= TOKEN_CAPACITY:
                overflow = True
                break
            emit_token(TokenKind.ENEMY_VISIBLE, u=u)
        for eid in sorted(knowledge.stale_contacts.keys()):
            if len(tokens) >= TOKEN_CAPACITY:
                overflow = True
                break
            emit_token(TokenKind.STALE_CONTACT, stale=knowledge.stale_contacts[eid])
        while len(tokens) < TOKEN_CAPACITY:
            emit_token(TokenKind.PAD)

        # ---- hex patch --------------------------------------------------------
        hex_patch: list[list[float]] = []
        for dq, dr in RING_MAJOR_OFFSETS:
            feats = [0.0] * HEX_FEATURE_DIM
            dist = _axial_distance(dq, dr)
            bucket = _direction_bucket(dq, dr)
            self._write_geometry(feats, dq, dr, dist, bucket)
            cell_q, cell_r = aq + dq, ar + dr
            cell = w.cell_data.get(f"{cell_q},{cell_r}")
            if cell is not None:
                terrain_int = int(cell["terrain"])
                obs_terrain = _GODOT_TERRAIN_TO_OBS.get(terrain_int, "UNKNOWN")
                cost = terrain_rules.get_terrain_cost(terrain_int, actor.unit_class)
                impassable = terrain_int in (8, 9, 10) or terrain_int >= 99
            else:
                obs_terrain = "UNKNOWN"
                cost = 1.0
                impassable = True  # outside map bounds: blocked
            t0 = HEX_GROUP_OFFSETS["terrain"][0]
            feats[t0:t0 + 6] = _onehot(6, _cat(TERRAIN_VOCAB, obs_terrain))
            c0 = HEX_GROUP_OFFSETS["traversal_cost_ratio"][0]
            feats[c0] = min(1.0, (99.0 if impassable else cost) / MAX_TRAVERSAL_COST if not impassable else 1.0)
            feats[c0 + 1] = 1.0 if cell is not None else 0.0
            b0 = HEX_GROUP_OFFSETS["blocking"][0]
            feats[b0:b0 + 3] = _onehot(3, _cat(BLOCKING_VOCAB, "BLOCKED" if impassable else "PASSABLE")) if cell is not None else _onehot(3, _cat(BLOCKING_VOCAB, "UNKNOWN"))
            # occupancy: authorized only (own, visible enemy, stale marker)
            key = f"{cell_q},{cell_r}"
            occ = "EMPTY"
            occ_known = cell is not None
            if cell is not None and key in w.occupied_map:
                occ_id = w.occupied_map[key]
                occ_u = w.units.get(occ_id)
                if occ_u is not None and occ_u.soldier_count > 0 and not occ_u.garrisoned:
                    if occ_u.faction == side:
                        occ = "FRIENDLY"
                    elif knowledge.is_enemy_visible(occ_u.to_dict()):
                        occ = "ENEMY_VISIBLE"
                    else:
                        # Hidden enemy: NOT-A-CONTACT in this projection.
                        # Never leak presence as UNKNOWN-occupancy — two
                        # WorldTruths differing only by a hidden unit inside
                        # the patch would otherwise produce different
                        # observations (anti-leakage invariant 5: unknown
                        # must never become negative evidence of absence).
                        occ = "EMPTY"
            if occ == "EMPTY" and knowledge.stale_contacts:
                for snap in knowledge.stale_contacts.values():
                    if int(snap.get("q", 99999)) == cell_q and int(snap.get("r", 99999)) == cell_r:
                        occ = "STALE_MARKER"
                        break
            o0 = HEX_GROUP_OFFSETS["occupancy"][0]
            feats[o0:o0 + 5] = _onehot(5, _cat(OCCUPANCY_VOCAB, occ))
            if not occ_known:
                feats[o0:o0 + 5] = _onehot(5, _cat(OCCUPANCY_VOCAB, "UNKNOWN"))
            # visibility state
            v_idx = knowledge.fog_state(cell_q, cell_r) if cell is not None else 0
            v0 = HEX_GROUP_OFFSETS["visibility_state"][0]
            feats[v0:v0 + 3] = _onehot(3, _cat(VIS_VOCAB, VIS_VOCAB[min(2, v_idx)]))
            # objective / HQ markers (authorized knowledge)
            obj_present = 1.0 if key in knowledge.objective_hexes else 0.0
            feats[HEX_GROUP_OFFSETS["objective_marker"][0]] = obj_present
            feats[HEX_GROUP_OFFSETS["objective_marker_known"][0]] = 1.0 if cell is not None else 0.0
            hq_present = 0.0
            hq_u = next((u for u in w.units.values() if u.unit_class == "hq" and u.faction == side), None)
            if hq_u is not None and hq_u.q == cell_q and hq_u.r == cell_r:
                hq_present = 1.0
            feats[HEX_GROUP_OFFSETS["hq_marker"][0]] = hq_present
            feats[HEX_GROUP_OFFSETS["hq_marker_known"][0]] = 1.0 if cell is not None else 0.0
            hex_patch.append(feats)

        # ---- actor ------------------------------------------------------------
        actor_feats = [0.0] * ACTOR_FEATURE_DIM
        cls_norm = {"spearman": "SPEARMAN", "spearmen": "SPEARMAN", "spear": "SPEARMAN",
                    "infantry": "INFANTRY", "cavalry": "CAVALRY", "archer": "ARCHER",
                    "archers": "ARCHER", "scout": "SCOUT", "scouts": "SCOUT"}.get(actor.unit_class.lower())
        class_idx = LEARNED_CLASSES.index(cls_norm) if cls_norm in LEARNED_CLASSES else 0
        acting_class_idx = class_idx
        o0 = ACTOR_GROUP_OFFSETS["unit_class"][0]
        actor_feats[o0:o0 + len(LEARNED_CLASSES)] = _onehot(len(LEARNED_CLASSES), class_idx)
        s_ratio, _ = strength_of(actor_dict, True)
        actor_feats[ACTOR_GROUP_OFFSETS["strength_ratio"][0]] = s_ratio
        actor_feats[ACTOR_GROUP_OFFSETS["strength_known"][0]] = 1.0
        base_mp = actor.base_mp if actor.base_mp > 0 else 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["movement_remaining_ratio"][0]] = min(1.0, max(0.0, actor.remaining_mp / base_mp))
        actor_feats[ACTOR_GROUP_OFFSETS["movement_capacity_ratio"][0]] = 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["movement_spent_ratio"][0]] = min(1.0, actor.turn_move_cost_spent / max(1e-9, actor.blue_limit))
        actor_feats[ACTOR_GROUP_OFFSETS["movement_available"][0]] = 1.0 if not actor.action_ended else 0.0
        actor_feats[ACTOR_GROUP_OFFSETS["movement_known"][0]] = 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["attack_available"][0]] = 0.0 if (actor.has_attacked or actor.action_ended) else 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["attack_known"][0]] = 1.0
        rd0 = ACTOR_GROUP_OFFSETS["readiness"][0]
        actor_feats[rd0:rd0 + 3] = _onehot(3, _cat(READINESS_VOCAB, "ACTED" if actor.action_ended else "READY"))
        # morale/cohesion: known for own units (morale ratio), cohesion NA (no rule)
        actor_feats[ACTOR_GROUP_OFFSETS["morale_ratio"][0]] = min(1.0, actor.morale / 100.0)
        actor_feats[ACTOR_GROUP_OFFSETS["morale_known"][0]] = 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["morale_not_applicable"][0]] = 0.0
        actor_feats[ACTOR_GROUP_OFFSETS["cohesion_ratio"][0]] = 0.0
        actor_feats[ACTOR_GROUP_OFFSETS["cohesion_known"][0]] = 0.0
        actor_feats[ACTOR_GROUP_OFFSETS["cohesion_not_applicable"][0]] = 1.0
        rout_idx = _cat(ROUT_VOCAB, "ROUTING" if actor.routed else "NONE")
        r0 = ACTOR_GROUP_OFFSETS["rout_state"][0]
        actor_feats[r0:r0 + 5] = _onehot(5, rout_idx)
        stance = "HOLD" if actor.defense_ready and actor.action_ended else "NONE"
        st0 = ACTOR_GROUP_OFFSETS["stance"][0]
        actor_feats[st0:st0 + 7] = _onehot(7, _cat(STANCE_VOCAB, stance))
        # objective / HQ direction (mission context overrides; else known enemy HQ)
        obj_dir, obj_dist, obj_known = self._objective_vector(actor, mission_context)
        dx, dy = _dir_unit(obj_dir[0], obj_dir[1])
        actor_feats[ACTOR_GROUP_OFFSETS["objective_dir_x"][0]] = dx
        actor_feats[ACTOR_GROUP_OFFSETS["objective_dir_y"][0]] = dy
        actor_feats[ACTOR_GROUP_OFFSETS["objective_distance_ratio"][0]] = min(1.0, obj_dist / PATCH_RADIUS)
        actor_feats[ACTOR_GROUP_OFFSETS["objective_known"][0]] = 1.0 if obj_known else 0.0
        hq_dir, hq_dist, hq_known = self._hq_vector(actor)
        hx, hy = _dir_unit(hq_dir[0], hq_dir[1])
        actor_feats[ACTOR_GROUP_OFFSETS["hq_dir_x"][0]] = hx
        actor_feats[ACTOR_GROUP_OFFSETS["hq_dir_y"][0]] = hy
        actor_feats[ACTOR_GROUP_OFFSETS["hq_distance_ratio"][0]] = min(1.0, hq_dist / PATCH_RADIUS)
        actor_feats[ACTOR_GROUP_OFFSETS["hq_known"][0]] = 1.0 if hq_known else 0.0
        # board edge free space (authorized: own map knowledge)
        free = self._board_edge_free(aq, ar)
        be0 = ACTOR_GROUP_OFFSETS["board_edge_free_nesw"][0]
        actor_feats[be0:be0 + 4] = free
        actor_feats[ACTOR_GROUP_OFFSETS["board_edge_known"][0]] = 1.0
        # own cell facts
        own_cell = w.cell_data.get(f"{aq},{ar}")
        own_terrain_int = int(own_cell["terrain"]) if own_cell else 0
        obs_t = _GODOT_TERRAIN_TO_OBS.get(own_terrain_int, "UNKNOWN")
        ct0 = ACTOR_GROUP_OFFSETS["cell_terrain"][0]
        actor_feats[ct0:ct0 + 6] = _onehot(6, _cat(TERRAIN_VOCAB, obs_t))
        own_cost = terrain_rules.get_terrain_cost(own_terrain_int, actor.unit_class) if own_cell else 1.0
        actor_feats[ACTOR_GROUP_OFFSETS["cell_traversal_cost_ratio"][0]] = min(1.0, own_cost / MAX_TRAVERSAL_COST)
        actor_feats[ACTOR_GROUP_OFFSETS["cell_traversal_known"][0]] = 1.0 if own_cell else 0.0
        cb0 = ACTOR_GROUP_OFFSETS["cell_blocking"][0]
        actor_feats[cb0:cb0 + 3] = _onehot(3, _cat(BLOCKING_VOCAB, "PASSABLE" if own_cell else "UNKNOWN"))
        co0 = ACTOR_GROUP_OFFSETS["cell_occupancy"][0]
        actor_feats[co0:co0 + 5] = _onehot(5, _cat(OCCUPANCY_VOCAB, "FRIENDLY"))
        cv0 = ACTOR_GROUP_OFFSETS["cell_visibility_state"][0]
        actor_feats[cv0:cv0 + 3] = _onehot(3, _cat(VIS_VOCAB, "VISIBLE"))

        # ---- mission ------------------------------------------------------------
        mission_feats = [0.0] * MISSION_FEATURE_DIM
        mc = mission_context
        mission_feats[MISSION_GROUP_OFFSETS["mission_type"][0]:MISSION_GROUP_OFFSETS["mission_type"][0] + 6] = _onehot(6, _cat(MISSION_TYPES, str(mc.get("mission_type", "SEEK_BATTLE"))))
        mission_feats[MISSION_GROUP_OFFSETS["objective_type"][0]:MISSION_GROUP_OFFSETS["objective_type"][0] + 5] = _onehot(5, _cat(OBJECTIVE_TYPES, str(mc.get("objective_type", "ENEMY_ARMY"))))
        mission_feats[MISSION_GROUP_OFFSETS["objective_status"][0]:MISSION_GROUP_OFFSETS["objective_status"][0] + 5] = _onehot(5, _cat(OBJ_STATUS, str(mc.get("objective_status", "IN_PROGRESS"))))
        m_obj_dir = mc.get("objective_dir", obj_dir)
        m_dx, m_dy = _dir_unit(int(m_obj_dir[0]), int(m_obj_dir[1]))
        mission_feats[MISSION_GROUP_OFFSETS["objective_dir_x"][0]] = m_dx
        mission_feats[MISSION_GROUP_OFFSETS["objective_dir_y"][0]] = m_dy
        mission_feats[MISSION_GROUP_OFFSETS["objective_distance_ratio"][0]] = min(1.0, float(mc.get("objective_distance", obj_dist)) / PATCH_RADIUS)
        mission_feats[MISSION_GROUP_OFFSETS["objective_known"][0]] = 1.0 if mc.get("objective_known", obj_known) else 0.0
        mission_feats[MISSION_GROUP_OFFSETS["mission_phase"][0]:MISSION_GROUP_OFFSETS["mission_phase"][0] + 5] = _onehot(5, _cat(PHASES, str(mc.get("mission_phase", self._mission_phase(turn)))))
        mission_feats[MISSION_GROUP_OFFSETS["urgency_ratio"][0]] = float(mc.get("urgency", 0.5))
        mission_feats[MISSION_GROUP_OFFSETS["urgency_known"][0]] = 1.0 if mc.get("urgency_known", True) else 0.0
        doctrine = mc.get("doctrine", {})
        d0 = MISSION_GROUP_OFFSETS["doctrine_scalars"][0]
        for i, name in enumerate(("aggression", "caution", "cohesion_preservation", "initiative", "attrition_tolerance", "objective_priority")):
            mission_feats[d0 + i] = float(doctrine.get(name, 0.5))
        dk0 = MISSION_GROUP_OFFSETS["doctrine_known"][0]
        for i, name in enumerate(("aggression", "caution", "cohesion_preservation", "initiative", "attrition_tolerance", "objective_priority")):
            mission_feats[dk0 + i] = 1.0 if name in doctrine else 0.0
        role = str(mc.get("actor_mission_role", "PRIMARY"))
        a0m = MISSION_GROUP_OFFSETS["actor_mission_role"][0]
        mission_feats[a0m:a0m + len(ACTOR_MISSION_ROLES)] = _onehot(len(ACTOR_MISSION_ROLES), _cat(ACTOR_MISSION_ROLES, role if role in ACTOR_MISSION_ROLES else "UNKNOWN"))

        # ---- global summary ------------------------------------------------------
        glob = [0.0] * GLOBAL_FEATURE_DIM
        turn_limit = int(self.battle.scenario.get("mission_contract", {}).get("turn_limit", 0))
        if turn_limit > 0:
            glob[GLOBAL_GROUP_OFFSETS["turn_progress_ratio"][0]] = min(1.0, turn / turn_limit)
        glob[GLOBAL_GROUP_OFFSETS["battle_phase"][0]:GLOBAL_GROUP_OFFSETS["battle_phase"][0] + 4] = _onehot(4, _cat(BATTLE_PHASES, "MOVEMENT"))
        n_own = len(own)
        n_enemy = len(visible_enemies)
        n_stale = len(knowledge.stale_contacts)
        own_overflow = n_own > FRIENDLY_COUNT_REF
        enemy_overflow = n_enemy > ENEMY_VISIBLE_COUNT_REF
        stale_overflow = n_stale > STALE_CONTACT_COUNT_REF
        glob[GLOBAL_GROUP_OFFSETS["friendly_count_ratio"][0]] = min(1.0, n_own / FRIENDLY_COUNT_REF)
        glob[GLOBAL_GROUP_OFFSETS["friendly_count_overflow"][0]] = 1.0 if own_overflow else 0.0
        own_strength = sum(min(1.0, u.soldier_count / max(1, u.max_count)) for u in w.units.values() if u.faction == side and u.soldier_count > 0 and not u.garrisoned)
        glob[GLOBAL_GROUP_OFFSETS["friendly_strength_ratio"][0]] = own_strength / max(1.0, float(n_own))
        ready = sum(1 for u in own if not u.get("action_ended", False))
        glob[GLOBAL_GROUP_OFFSETS["friendly_ready_ratio"][0]] = ready / max(1.0, float(n_own))
        glob[GLOBAL_GROUP_OFFSETS["friendly_acted_ratio"][0]] = (n_own - ready) / max(1.0, float(n_own))
        glob[GLOBAL_GROUP_OFFSETS["visible_enemy_count_ratio"][0]] = min(1.0, n_enemy / ENEMY_VISIBLE_COUNT_REF)
        glob[GLOBAL_GROUP_OFFSETS["visible_enemy_count_overflow"][0]] = 1.0 if enemy_overflow else 0.0
        enemy_strength = sum(min(1.0, int(u.get("soldier_count", 0)) / max(1, int(u.get("max_count", 1)))) for u in visible_enemies)
        glob[GLOBAL_GROUP_OFFSETS["visible_enemy_strength_ratio"][0]] = enemy_strength / max(1.0, float(n_enemy))
        glob[GLOBAL_GROUP_OFFSETS["stale_count_ratio"][0]] = min(1.0, n_stale / STALE_CONTACT_COUNT_REF)
        glob[GLOBAL_GROUP_OFFSETS["stale_count_overflow"][0]] = 1.0 if stale_overflow else 0.0
        if n_stale:
            mean_age = sum(turn - int(s.get("turn", turn)) for s in knowledge.stale_contacts.values()) / n_stale
            glob[GLOBAL_GROUP_OFFSETS["mean_contact_age_ratio"][0]] = min(1.0, max(0.0, mean_age / CONTACT_MEMORY_HORIZON))
        own_hq = next((u for u in w.units.values() if u.unit_class == "hq" and u.faction == side), None)
        glob[GLOBAL_GROUP_OFFSETS["own_hq_alive"][0]] = 1.0 if own_hq is not None and own_hq.soldier_count > 0 else 0.0
        glob[GLOBAL_GROUP_OFFSETS["own_hq_known"][0]] = 1.0
        enemy_hq = next((u for u in w.units.values() if u.unit_class == "hq" and u.faction == enemy_faction), None)
        enemy_hq_known = enemy_hq is not None and knowledge.is_enemy_visible(enemy_hq.to_dict())
        glob[GLOBAL_GROUP_OFFSETS["enemy_hq_alive"][0]] = 1.0 if (enemy_hq_known and enemy_hq.soldier_count > 0) else 0.0
        glob[GLOBAL_GROUP_OFFSETS["enemy_hq_known"][0]] = 1.0 if enemy_hq_known else 0.0
        glob[GLOBAL_GROUP_OFFSETS["objective_possession"][0]:GLOBAL_GROUP_OFFSETS["objective_possession"][0] + 5] = _onehot(5, _cat(POSSESSION, str(mc.get("objective_possession", "CONTESTED"))))
        mission_progress = float(mc.get("mission_progress", 0.0))
        glob[GLOBAL_GROUP_OFFSETS["mission_progress_ratio"][0]] = min(1.0, max(0.0, mission_progress))
        glob[GLOBAL_GROUP_OFFSETS["mission_progress_known"][0]] = 1.0 if mc.get("mission_progress_known", True) else 0.0
        total = max(1, len(w.cell_data))
        vis_n = len(knowledge.visible)
        expl_n = len(knowledge.explored)
        glob[GLOBAL_GROUP_OFFSETS["coverage_visible_ratio"][0]] = vis_n / total
        glob[GLOBAL_GROUP_OFFSETS["coverage_explored_ratio"][0]] = expl_n / total
        glob[GLOBAL_GROUP_OFFSETS["coverage_unknown_ratio"][0]] = max(0.0, 1.0 - expl_n / total)
        glob[GLOBAL_GROUP_OFFSETS["coverage_known"][0]] = 1.0

        # token-buffer overflow bit rides the friendly-count overflow flag slot
        # only when the buffer itself overflowed (contract: explicit indicator).
        if overflow:
            glob[GLOBAL_GROUP_OFFSETS["friendly_count_overflow"][0]] = 1.0
            glob[GLOBAL_GROUP_OFFSETS["friendly_count_ratio"][0]] = 1.0

        # ---- legality mask (observation-safe; engine rechecks at execution) ----
        legal = self._observation_safe_mask(actor, knowledge)

        obs = ProjectedObservation(
            actor_features=actor_feats,
            tokens=tokens,
            token_padding_mask=token_pad,
            hex_patch=hex_patch,
            mission_features=mission_feats,
            global_features=glob,
            legal_mask=legal,
            acting_class_idx=acting_class_idx,
            metadata={
                "projector": "python_sim.observation.projector",
                "side": side,
                "actor_id": actor_id,
                "turn": str(turn),
            },
        )
        obs.dims_check()
        return obs

    # ------------------------------------------------------------------ helpers
    def _write_geometry(self, feats: list[float], dq: int, dr: int, dist: int, bucket: int) -> None:
        offsets = TOKEN_GROUP_OFFSETS if len(feats) == TOKEN_FEATURE_DIM else HEX_GROUP_OFFSETS
        o0 = offsets["rel_offset_dq_dr"][0]
        feats[o0] = dq / PATCH_RADIUS
        feats[o0 + 1] = dr / PATCH_RADIUS
        feats[offsets["hex_distance_ratio"][0]] = min(1.0, dist / PATCH_RADIUS)
        d0 = offsets["direction_bucket"][0]
        feats[d0:d0 + NUM_DIRECTION_BUCKETS] = _onehot(NUM_DIRECTION_BUCKETS, bucket)

    def _objective_vector(self, actor, mission_context: dict) -> tuple[tuple[int, int], int, bool]:
        """Declared mission target first; else known enemy HQ; else unknown."""
        target = mission_context.get("target_hex")
        if target:
            dq, dr = int(target[0]) - actor.q, int(target[1]) - actor.r
            return (dq, dr), _axial_distance(dq, dr), True
        enemy_faction = "red" if actor.faction == "blue" else "blue"
        knowledge = self.battle.blue_knowledge if actor.faction == "blue" else self.battle.red_knowledge
        for u in sorted(self.battle.world.units.values(), key=lambda x: x.id):
            if u.unit_class == "hq" and u.faction == enemy_faction and u.soldier_count > 0:
                if knowledge.is_enemy_visible(u.to_dict()):
                    dq, dr = u.q - actor.q, u.r - actor.r
                    return (dq, dr), _axial_distance(dq, dr), True
        return (0, -1), 5, False

    def _hq_vector(self, actor) -> tuple[tuple[int, int], int, bool]:
        for u in sorted(self.battle.world.units.values(), key=lambda x: x.id):
            if u.unit_class == "hq" and u.faction == actor.faction and u.soldier_count > 0:
                if u.id == actor.id:
                    return (0, 0), 0, True
                dq, dr = u.q - actor.q, u.r - actor.r
                return (dq, dr), _axial_distance(dq, dr), True
        return (0, 0), 0, False

    def _board_edge_free(self, q: int, r: int) -> list[float]:
        """Free-space ratio toward N/E/S/W within the playable hexagon."""
        total = []
        for dq, dr in ((0, -1), (1, 0), (0, 1), (-1, 0)):
            free = 0
            steps = 0
            cq, cr = q, r
            for _ in range(5):
                cq += dq
                cr += dr
                steps += 1
                if geometry.is_playable_hex((cq, cr)) and f"{cq},{cr}" in self.battle.world.cell_data:
                    free += 1
                else:
                    break
            total.append(free / 5.0)
        return total

    def _mission_phase(self, turn: int) -> str:
        turn_limit = int(self.battle.scenario.get("mission_contract", {}).get("turn_limit", 10))
        frac = turn / max(1, turn_limit)
        if frac <= 0.33:
            return "EARLY"
        if frac <= 0.66:
            return "MID"
        return "LATE"

    def _observation_safe_mask(self, actor, knowledge) -> list[bool]:
        """Observation-safe six-bit legality from actor state + authorized knowledge.

        Classes map to their frozen six-skill tables (python_jev.constants).
        Mask uses only what the acting side can know; the engine rechecks at
        execution (Notion I3/I5). All-illegal is possible and is surfaced as
        an all-False mask (the caller decides per the frozen safe-failure).
        """
        cls_norm = {"spearman": "SPEARMAN", "spearmen": "SPEARMAN", "spear": "SPEARMAN",
                    "infantry": "INFANTRY", "cavalry": "CAVALRY", "archer": "ARCHER",
                    "archers": "ARCHER", "scout": "SCOUT", "scouts": "SCOUT"}.get(actor.unit_class.lower())
        if cls_norm not in LEARNED_CLASSES:
            return [False] * 6
        can_attack = (not actor.has_attacked) and (not actor.action_ended)
        visible_enemies = []
        enemy_faction = "red" if actor.faction == "blue" else "blue"
        for u in self.battle.world.units.values():
            if u.faction == enemy_faction and u.soldier_count > 0 and not u.garrisoned:
                if knowledge.is_enemy_visible(u.to_dict()):
                    visible_enemies.append(u)
        # attack legality: an in-range target the side can see (range from BASE_STATS)
        from python_sim.rules.combat import get_attack_range

        rng = get_attack_range(actor.unit_class)
        attack_legal = can_attack and any(
            0 < geometry.hex_distance_axial((actor.q, actor.r), (e.q, e.r)) <= rng
            for e in visible_enemies
        )
        can_move = not actor.action_ended
        can_withdraw = can_move
        if cls_norm == "INFANTRY":
            return [attack_legal, can_move, True, can_move, can_move, can_withdraw]
        if cls_norm == "SPEARMAN":
            return [attack_legal, can_move, True, can_move, can_move, can_withdraw]
        if cls_norm == "CAVALRY":
            return [attack_legal, can_move, can_move, bool(visible_enemies) and can_move, can_move, can_withdraw]
        if cls_norm == "ARCHER":
            return [attack_legal, can_move, can_move, can_move, True, can_withdraw]
        return [can_move, bool(visible_enemies), attack_legal, can_move, can_move, can_move]


__all__ = ["ObservationProjector", "ProjectedObservation"]
