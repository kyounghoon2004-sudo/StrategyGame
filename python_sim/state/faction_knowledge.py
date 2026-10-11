"""Faction knowledge + contact memory — faithful port of Step5FogOfWar.

This layer owns PERSISTENT AUTHORIZED KNOWLEDGE for one side: visibility,
explored terrain, frozen stale-contact snapshots, combat-assessed strength.
It never receives WorldTruth except through the recompute() call contract,
exactly like the Godot authority (scripts/step5/fog_of_war.gd).

Key frozen semantics:
- stale snapshots freeze on visible->hidden transition and are NEVER updated
  while hidden (freeze-never-update-while-hidden); rediscovery supersedes;
- destroyed enemies purge stale markers (no marker behind);
- scout/normal vision radii (4 / 2 — provisional source defaults, recorded
  as gap scout_vision_provisional);
- LOS: intermediate MOUNTAIN blocks; intermediate FOREST blocks at
  distance >= 3; the target forest hex itself stays visible; off-map gap
  blocks;
- strength bands: scout-observed uses deterministic hash bands keyed on
  id+turn (contract-limited godot hash stand-in, gap godot_hash_parity);
  combat-assessed rounds to nearest 50 (<500) else 100;
- NO production expiry for stale contacts: age is only clipped at the
  observation normalization horizon; contacts are NOT deleted by age
  (gap stale_memory_horizon — current behavior frozen as no-expiry).
"""

from __future__ import annotations

from python_sim.rules import geometry
from python_sim.rules.geometry import Hex
from python_sim.rules.rounding import clampf_gd, round_to_step_gd

NORMAL_VISION: int = 2   # provisional source default (gap scout_vision_provisional)
SCOUT_VISION: int = 4    # provisional source default (gap scout_vision_provisional)


def estimate_band(true_count: int, seed_key: str) -> tuple[int, int]:
    """Fog.estimate_band without the Korean text: returns (lo, hi).

    Deterministic coarse estimate: +/-10% band around count rounded to 50,
    min width 100. seed_key makes the SAME (count, key) map to the SAME band.
    """
    from python_sim.rules.rounding import godot_hash

    half = max(50, int(round(float(max(0, true_count)) * 0.20)))
    h = abs(godot_hash(seed_key))
    shift = (h % 21) - 10  # -10..+10
    center = true_count + int(round(float(half) * float(shift) / 10.0))
    lo = max(0, round_to_step_gd(center - half, 50))
    hi = max(lo + 50, round_to_step_gd(center + half, 50))
    if hi - lo < 100:
        hi = lo + 100
    return lo, hi


def combat_approx_troops(true_count: int) -> int:
    """Fog.combat_approx_troops — nearest 50 (<500) else nearest 100."""
    c = max(0, true_count)
    if c < 500:
        return round_to_step_gd(c, 50)
    return round_to_step_gd(c, 100)


class FactionKnowledge:
    """Per-side authorized knowledge (fog storage + contact ledgers).

    Mirrors Step5FogOfWar storage exactly: hex-keyed dicts, frozen stale
    snapshots, discovery edge tracking, combat-assessment memory.
    """

    def __init__(self, side: str) -> None:
        if side not in ("blue", "red"):
            raise ValueError(f"side must be blue|red, got {side!r}")
        self.side = side
        self.reset()

    def reset(self) -> None:
        # "q,r" -> True
        self.explored: dict[str, bool] = {}
        self.visible: dict[str, bool] = {}
        self.visible_by_scout: dict[str, bool] = {}
        # Strategic objectives stay terrain-known through fog.
        self.objective_hexes: dict[str, bool] = {}
        # enemy_id -> snapshot dict (frozen-capable last-seen record)
        self.last_seen: dict[str, dict] = {}
        # enemy_id -> True for enemies visible at the previous recompute
        self._prev_visible_enemies: dict[str, bool] = {}
        # contact memory
        self.combat_assessed: dict[str, bool] = {}
        self.assessed_health: dict[str, float] = {}
        self.stale_contacts: dict[str, dict] = {}
        self.ever_seen: dict[str, bool] = {}
        # friendly command-loss memory (rout layer)
        self.friendly_stale: dict[str, dict] = {}

    # -- objective markers ---------------------------------------------------
    def set_objective_hexes(self, hexes: list[Hex]) -> None:
        self.objective_hexes = {geometry.key_of(h): True for h in hexes}
        for key in self.objective_hexes:
            self.explored[key] = True

    # -- combat assessment (Step5R1) ------------------------------------------
    def mark_combat_engaged(self, enemy_id: str, health_ratio: float) -> None:
        if enemy_id == "":
            return
        self.combat_assessed[enemy_id] = True
        self.assessed_health[enemy_id] = clampf_gd(health_ratio, 0.0, 1.0)

    def is_combat_assessed(self, enemy_id: str) -> bool:
        return bool(self.combat_assessed.get(enemy_id, False))

    def get_assessed_ratio(self, enemy_id: str) -> float:
        return float(self.assessed_health.get(enemy_id, -1.0))

    def get_stale_snapshot(self, enemy_id: str) -> dict:
        return dict(self.stale_contacts.get(enemy_id, {}))

    def get_all_stale(self) -> dict[str, dict]:
        return dict(self.stale_contacts)

    def was_ever_seen(self, enemy_id: str) -> bool:
        return enemy_id in self.ever_seen

    # -- friendly command loss (Step6R1 §4-6) ----------------------------------
    def note_friendly_command_loss(self, unit_id: str, q: int, r: int, uclass: str, turn: int) -> None:
        if unit_id == "":
            return
        if unit_id in self.friendly_stale:
            return  # frozen — never overwrite while hidden
        self.friendly_stale[unit_id] = {
            "unit_id": unit_id, "turn": turn, "q": q, "r": r, "class": uclass,
        }

    def clear_friendly_command_loss(self, unit_id: str) -> None:
        self.friendly_stale.pop(unit_id, None)

    def is_friendly_command_lost(self, unit_id: str) -> bool:
        return unit_id in self.friendly_stale

    def get_all_friendly_stale(self) -> dict[str, dict]:
        return dict(self.friendly_stale)

    # -- hex queries ------------------------------------------------------------
    def is_hex_visible(self, q: int, r: int) -> bool:
        return geometry.key_of((q, r)) in self.visible

    def is_hex_explored(self, q: int, r: int) -> bool:
        return geometry.key_of((q, r)) in self.explored

    def is_hex_scout_observed(self, q: int, r: int) -> bool:
        return geometry.key_of((q, r)) in self.visible_by_scout

    def fog_state(self, q: int, r: int) -> int:
        """0=UNEXPLORED 1=EXPLORED 2=VISIBLE (FogState order)."""
        key = geometry.key_of((q, r))
        if key in self.visible:
            return 2
        if key in self.explored or key in self.objective_hexes:
            return 1
        return 0

    def is_enemy_visible(self, enemy: dict) -> bool:
        if not enemy:
            return False
        return self.is_hex_visible(int(enemy.get("q", -999)), int(enemy.get("r", -999)))

    def is_enemy_scout_observed(self, enemy: dict) -> bool:
        if not enemy:
            return False
        return self.is_hex_scout_observed(int(enemy.get("q", -999)), int(enemy.get("r", -999)))

    def get_last_seen(self, enemy_id: str) -> dict:
        return dict(self.last_seen.get(enemy_id, {}))

    # -- recompute --------------------------------------------------------------
    def recompute(
        self,
        friendly_units: list[dict],
        all_units: list[dict],
        cell_data: dict[str, dict],
        turn: int,
    ) -> dict:
        """Literal port of Fog.recompute. Returns discovery report.

        friendly_units: this side's field units (alive).
        all_units: every field unit (needed for contact bookkeeping).
        """
        self.visible.clear()
        self.visible_by_scout.clear()
        for key in self.objective_hexes:
            self.explored[key] = True

        enemy_faction = "red" if self.side == "blue" else "blue"

        for u in friendly_units:
            if int(u.get("soldier_count", 0)) <= 0:
                continue
            if bool(u.get("garrisoned", False)):
                continue
            if bool(u.get("routed", False)):
                continue  # command-lost: no LOS from hidden true position
            origin = (int(u.get("q", 0)), int(u.get("r", 0)))
            uclass = str(u.get("class", ""))
            scout = uclass.lower() in ("scout", "scouts")
            radius = SCOUT_VISION if scout else NORMAL_VISION
            for dq in range(-radius, radius + 1):
                for dr in range(-radius, radius + 1):
                    cand = (origin[0] + dq, origin[1] + dr)
                    if geometry.hex_distance_axial(origin, cand) > radius:
                        continue
                    key = geometry.key_of(cand)
                    if key not in cell_data:
                        continue
                    if not self._has_los(origin, cand, cell_data):
                        continue
                    self.visible[key] = True
                    if scout:
                        self.visible_by_scout[key] = True
                    self.explored[key] = True

        # Contact bookkeeping + discovery edges.
        newly: list[dict] = []
        now_visible: dict[str, bool] = {}
        present_enemy: dict[str, bool] = {}
        for e in all_units:
            if str(e.get("faction", "")) != enemy_faction:
                continue
            if int(e.get("soldier_count", 0)) <= 0:
                continue
            if bool(e.get("garrisoned", False)):
                continue
            eid = str(e.get("id", ""))
            present_enemy[eid] = True
            if self.is_enemy_visible(e):
                now_visible[eid] = True
                is_first = eid not in self.ever_seen
                self.ever_seen[eid] = True
                escout = self.is_enemy_scout_observed(e)
                ecount = int(e.get("soldier_count", 0))
                # Combat-assessed approx wins over scout range; frozen on loss.
                ecombat = bool(self.combat_assessed.get(eid, False))
                if ecombat:
                    approx = combat_approx_troops(ecount)
                elif escout:
                    approx = None  # band stored as (lo,hi) below
                else:
                    approx = None
                erh = -1.0
                if bool(self.combat_assessed.get(eid, False)):
                    emax = max(1, int(e.get("max_count", ecount)))
                    erh = clampf_gd(float(ecount) / float(emax), 0.0, 1.0)
                    self.assessed_health[eid] = erh
                record = {
                    "turn": turn,
                    "q": int(e.get("q", 0)),
                    "r": int(e.get("r", 0)),
                    "class": str(e.get("class", "")),
                    "scout": escout,
                    "combat_approx": approx,
                    "combat_assessed": ecombat,
                    "scout_band": estimate_band(ecount, f"{eid}:{turn}") if (escout and not ecombat) else None,
                    "health_ratio": erh,
                    "has_health": erh >= 0.0,
                }
                self.last_seen[eid] = record
                self.stale_contacts.pop(eid, None)
                if eid not in self._prev_visible_enemies:
                    newly.append(dict(e, first_discovery=is_first))
            elif eid in self._prev_visible_enemies:
                # Fresh loss of contact — freeze the last OBSERVED record as-is.
                frozen = dict(self.last_seen.get(eid, {}))
                if frozen:
                    self.stale_contacts[eid] = {
                        "enemy_id": eid,
                        "turn": int(frozen.get("turn", turn)),
                        "q": int(frozen.get("q", 0)),
                        "r": int(frozen.get("r", 0)),
                        "class": str(frozen.get("class", "")),
                        "scout": bool(frozen.get("scout", False)),
                        "combat_approx": frozen.get("combat_approx"),
                        "combat_assessed": bool(frozen.get("combat_assessed", self.combat_assessed.get(eid, False))),
                        "scout_band": frozen.get("scout_band"),
                        "health_ratio": float(frozen.get("health_ratio", -1.0)),
                        "has_health": bool(frozen.get("has_health", False)),
                    }

        # Destroyed enemies leave no stale marker.
        for eid in list(self.stale_contacts.keys()):
            if not present_enemy.get(eid, False):
                del self.stale_contacts[eid]

        # Destroyed/rallied friendlies leave no friendly stale marker.
        own_faction = self.side
        present_own: dict[str, bool] = {}
        for e in all_units:
            if str(e.get("faction", "")) != own_faction:
                continue
            if int(e.get("soldier_count", 0)) <= 0:
                continue
            if bool(e.get("garrisoned", False)):
                continue
            present_own[str(e.get("id", ""))] = not bool(e.get("routed", False))
        for fid in list(self.friendly_stale.keys()):
            if not present_own.get(fid, False) or present_own[fid]:
                self.friendly_stale.pop(fid, None)

        self._prev_visible_enemies = now_visible
        return {"visible_hexes": len(self.visible), "newly_visible_enemies": newly}

    # -- observation API (never exposes hidden truth) -----------------------------
    def get_enemy_observation(self, enemy: dict, turn: int) -> dict:
        """Fog.get_enemy_observation: authorized-only enemy facts."""
        base = {
            "visible": False,
            "scout_observed": False,
            "troop_text": "unknown",
            "combat_assessed": False,
            "health_ratio": -1.0,
            "has_health": False,
        }
        if not enemy or not self.is_enemy_visible(enemy):
            return base
        eid = str(enemy.get("id", ""))
        scout = self.is_enemy_scout_observed(enemy)
        base["visible"] = True
        base["scout_observed"] = scout
        ecount = int(enemy.get("soldier_count", 0))
        if self.is_combat_assessed(eid):
            lo_hi = (combat_approx_troops(ecount), combat_approx_troops(ecount))
            base["troop_text"] = f"~{lo_hi[0]}"
            base["combat_assessed"] = True
            emax = max(1, int(enemy.get("max_count", enemy.get("soldier_count", 1))))
            base["health_ratio"] = clampf_gd(float(ecount) / float(emax), 0.0, 1.0)
            base["has_health"] = True
        elif scout:
            lo, hi = estimate_band(ecount, f"{eid}:{turn}")
            base["troop_text"] = f"~{lo}~{hi}"
            base["combat_assessed"] = False
        else:
            base["troop_text"] = "???"
            base["combat_assessed"] = False
        return base

    # -- LOS -----------------------------------------------------------------
    def _has_los(self, origin: Hex, target: Hex, cell_data: dict[str, dict]) -> bool:
        if origin == target:
            return True
        dist = geometry.hex_distance_axial(origin, target)
        line = geometry.hex_line(origin, target)
        # Intermediate hexes exclude origin (index 0) and target (last).
        for h in line[1:-1]:
            cell = cell_data.get(geometry.key_of(h))
            if cell is None:
                return False  # off-map gap blocks
            t = int(cell["terrain"])
            if t == geometry.TERRAIN_MOUNTAIN:
                return False
            if t == geometry.TERRAIN_FOREST and dist >= 3:
                return False
        return True


__all__ = [
    "NORMAL_VISION",
    "SCOUT_VISION",
    "FactionKnowledge",
    "combat_approx_troops",
    "estimate_band",
]
