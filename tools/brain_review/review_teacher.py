"""REVIEW TEACHER v2 — deterministic decision function for VICTORY_REVIEW packets.

v2 (lead QA, 2026-10-01; v1 teacher-mode games won 0/78 and lost the own HQ in
100% of INTER/ADV games):
  * symmetric local ratio: the enemy side is also weighted by its matchup
    multiplier against the own units it faces (v1 weighted only the own side,
    biasing ratios low -> 41% PULL_BACK vs 5% ENGAGE);
  * R1 HQ_DEFENSE always decides: threat radius 5 (was 3); a priority tie is
    broken by packet-visible facts (fewest Hand A units, then farthest from
    contact, then highest mission_id); a nearest-threat class tie by larger
    troop estimate, then unit_id (v1 dropped 319 such rows and the live proxy
    answered KEEP, leaving the HQ undefended);
  * new R2c PLAN_EXHAUSTED: the final phase's success is due (no next) while
    the BLUE HQ stands -> AMEND the main mission: ATTACK vs HQ in the enemy HQ
    sector when the overall visible ratio >= 1.0, else HOLD in the own HQ
    sector; already set -> fall through to R3-R6.
v2b (check run: 6/6 own-HQ losses; the HQ "cover" was a HOLD mission Hand A gave 0 units, and HOLD
units never fight back because Hand B attacks only under ATTACK):
  * R1 reacts at 8 hexes; the HQ counts as covered only by an ATTACK mission with >= 1 Hand A unit
    within 4 hexes of the HQ;
  * R1 converts the mission whose Hand A units are CLOSEST to the HQ (mean hex distance; >= 1 unit;
    ties -> more units -> lower index) to ATTACK vs the nearest threat's class in the HQ region,
    priority high. No unit anywhere -> the lowest-priority rule of v2 (still ATTACK).
v2c: the HQ is covered once any ATTACK mission in the HQ region has >= 1 Hand A unit (re-issuing the same
    AMEND every turn while the defenders walk back was a no-op; v2b corpus was 48% HQ_DEFENSE); and any rule
    whose AMEND would leave the plan unchanged falls through to the next rule.

Pure function: decide(packet) -> {target, rule, subkind, why}. No I/O, no
randomness; it uses ONLY fields present in the review packet v2 (the exact
input the Brain sees). The teacher never repairs a target into the corpus:
when the situation is ambiguous the row is DROPPED (target=None, plus a
machine-readable drop_reason), never decided by an arbitrary tie-break.

Class stats / matchups (documented choice):
  * primary: packet["context"]["rules"] ("classes" with atk/def/mp/rng and
    the per-battle "matchups" list; pairs not listed there multiply by 1.0),
  * fallback (context block absent): the class names in compact_state with
    the base table in scripts/combat/combat_calculator.gd (BASE_STATS /
    MATCHUP_TABLE reproduced below, including sub-1.0 pairs; unlisted pairs
    multiply by 1.0).

Geometry: hex distance is axial (q, r): (|dq| + |dr| + |dq + dr|) / 2.

"Unit in contact": a visible enemy (contact_state current/visible) is within
(the unit's attack range + 1) hexes.

"Local ratio" for a mission M (as defined by the task):
  own   = sum over M's IN-CONTACT units of soldiers * that unit's mean
          matchup multiplier against its contacted enemy classes;
  enemy = sum of troop_estimate midpoints of the visible enemies within
          2 hexes of any of M's in-contact units (each enemy once);
  ratio = own / enemy.  troop_estimate strings such as "약 150~250" parse to
  their band midpoint (200). If any needed estimate is unparseable the row
  is dropped (never guessed).

"Losses on M since the last review": an event in events_since_review of kind
FRIENDLY_UNIT_ATTACKED / FRIENDLY_UNIT_DESTROYED / UNIT_LOST whose detail
names one of M's units (detail.defender_id / detail.unit_id) or names M
(detail.mission_id). Only those detail fields are used (that is what the
event detail actually carries).

Ambiguity (row dropped, never broken arbitrarily):
  * a judged local ratio within +/-0.05 of 0.80 or 1.25 (band 0.75-0.85 /
    1.20-1.30),
  * R1: the lowest mission priority is shared by several missions, or two
    nearest threats tie at different classes,
  * R3: the "most numerous contacted enemy class" is still tied after the
    troop-estimate tie-break,
  * R4: the flank side choice ties between sectors (the "two sectors tied
    for R4" case) / no sector lies away from the main effort,
  * R5: the sector with most visible enemies is tied.

Documented interpretations (spec underspecified; all deterministic):
  * R1 "lowest-priority mission": unique minimum of the mission "priority"
    field over high > medium > low.
  * R1 "that local ratio": the local ratio of the mission being changed;
    undefined ratio (no contact / no enemy mass) means HOLD, never ATTACK.
  * R2 "the active phase has next": phase["next"] naming an existing phase,
    or empty "next" followed by a later phase in order. END / "-" / HOLD /
    dangling ids mean no next. next_phase_id is always the resolved id.
  * R2b "the phase has on_fail": on_fail == "ADVANCE" (transition action
    ADVANCE_ANYWAY, which the production vp_compute_review accepts after a
    failure). HOLD / EMERGENCY cannot be advanced into, so those rows go to
    the R2b fallback (R3-R5 as AMEND; else dropped and counted).
  * R3 rows run over the ACTIVE missions; when several missions qualify the
    one AMEND changes all of them (only the fields each row names).
  * R3 HOLD_FIRE ("KEEP while in contact", per the balance gate): no
    ENGAGE / PULL_BACK matched and at least one active mission is in
    contact; the reason says why not attacking now.
  * R4 sectors: NORTH(0,-2) SOUTH(0,2) WEST(-2,0) EAST(2,0) CENTER(0,0).
    Non-FLANK missions retarget to the enemy sector itself; FLANK missions
    retarget to the sector adjacent to it, excluding the main-effort sector,
    on the side away from the main effort (unique strictly-positive
    projection, else dropped). Main effort = area of the unique
    highest-priority mission of the active phase.
  * R5 stall metric over force_feedback.recent_actions: known points are the
    successful "MOVE q,r" destinations in order plus the current position
    (failed actions move nothing); hexes moved = path over those points
    (the entry leg into the window is not in the packet, so the path is a
    documented lower bound), net progress = hex distance first->last.
    Qualifying unit: path >= 4 and net <= 1. Mission qualifies with >= 2
    such units and no contact. "if already ADVANCE: KEEP" is literal: a
    qualifying mission already on ADVANCE is left unchanged.
  * R2b fallback rows carry rule "R2b" and the subkind of the applied
    R3-R5 sub-rule (so ENGAGE/PULL_BACK/RETARGET/UNSTALL gates count them).
"""
from __future__ import annotations

import copy
import re
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Fallback tables: scripts/combat/combat_calculator.gd (BASE_STATS, MATCHUP_TABLE)
# ---------------------------------------------------------------------------
BASE_RANGE = {  # normalized class -> attack range (BASE_STATS[class]["range"])
    "CAVALRY": 1, "INFANTRY": 1, "ARCHER": 3, "SPEARMAN": 1, "SCOUT": 1,
    "SIEGE": 2, "CONSCRIPT": 1, "HQ": 1, "SUPPLY": 1,
}
BASE_MATCHUP = {  # (attacker, defender) -> multiplier, defaults 1.0
    ("CAVALRY", "ARCHER"): 1.35,
    ("ARCHER", "SPEARMAN"): 1.35,
    ("SPEARMAN", "CAVALRY"): 1.40,
    ("INFANTRY", "ARCHER"): 1.20,
    ("INFANTRY", "CAVALRY"): 0.85,
    ("INFANTRY", "SPEARMAN"): 0.85,
    ("CONSCRIPT", "INFANTRY"): 0.60,
    ("SCOUT", "INFANTRY"): 0.55,
}
CLASS_ALIAS = {
    "ARCHERS": "ARCHER", "SPEARMEN": "SPEARMAN", "SPEAR": "SPEARMAN",
    "SCOUTS": "SCOUT", "CONSCRIPTS": "CONSCRIPT", "CAV": "CAVALRY",
}
TASKS_ATTACK = ("ATTACK",)
R4_TASKS = ("FIX", "ATTACK", "ADVANCE", "FLANK")
SECTOR_CENTER = {"CENTER": (0, 0), "NORTH": (0, -2), "SOUTH": (0, 2), "WEST": (-2, 0), "EAST": (2, 0)}
PRIORITY_RANK = {"low": 0, "medium": 1, "med": 1, "high": 2}
# v3 (2026-10-03, user: teacher too passive -> stalemates): engage at 0.90, pull back only at 0.60
ENGAGE_AT, PULL_AT = 0.90, 0.60
BANDS = ((0.55, 0.65), (0.85, 0.95))
R1_RADIUS = 8
R1_COVER = 4
R2C_BAND = (0.80, 0.90)  # v3: push the HQ unless clearly outnumbered
NUM_RE = re.compile(r"\d+")
REASON_MAX = 200

# drop reasons (machine readable; also reported in the corpus build)
DROP_MISSING_V2 = "missing_v2_field"
DROP_NO_PLAN = "no_active_phase"
DROP_AMBIG_RATIO = "ambig_ratio"
DROP_AMBIG_PRIORITY = "ambig_priority_tie"
DROP_AMBIG_NEAREST = "ambig_nearest_threat"
DROP_AMBIG_CLASS = "ambig_enemy_class_tie"
DROP_AMBIG_FLANK = "ambig_r4_flank_side"
DROP_AMBIG_SECTOR = "ambig_sector_tie"
DROP_AMBIG_MAIN = "ambig_main_effort"
DROP_BAD_ESTIMATE = "bad_troop_estimate"
DROP_R2B_NONE = "r2b_fallback_none"
DROP_R5_NO_ENEMY = "r5_no_visible_enemy"
DROP_INTERNAL = "internal_incomplete_target"


def hexdist(a: Tuple[int, int], b: Tuple[int, int]) -> int:
    dq = int(a[0]) - int(b[0])
    dr = int(a[1]) - int(b[1])
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def troop_mid(text: Any) -> Optional[float]:
    """'약 150~250' -> 200.0; unparseable -> None (never guessed)."""
    nums = [int(x) for x in NUM_RE.findall(str(text))]
    if not nums:
        return None
    return (min(nums) + max(nums)) / 2.0 if len(nums) >= 2 else float(nums[0])


def _norm_class(c: Any) -> str:
    up = str(c or "").strip().upper()
    return CLASS_ALIAS.get(up, up)


def in_ambiguity_band(ratio: float) -> bool:
    return any(lo <= ratio <= hi for lo, hi in BANDS)


def _clean_reason(text: str) -> str:
    # no Markdown: strip emphasis/fence chars; underscores STAY (unit ids carry them)
    t = re.sub(r"[*`#<>|\n\r]+", " ", str(text))
    t = re.sub(r"\s+", " ", t).strip()
    return t[:REASON_MAX]


class Drop(Exception):
    def __init__(self, code: str, why: str = ""):
        super().__init__(code)
        self.code = code
        self.why = why or code


class Teacher:
    """Packet-scoped helpers. One instance per decide() call."""

    def __init__(self, packet: Dict[str, Any]):
        self.pk = packet or {}
        rt = self.pk.get("review_trigger", {}) or {}
        self.trigger = str(rt.get("trigger", ""))
        self.also_due = [str(a.get("trigger", "")) for a in (rt.get("also_due", []) or []) if isinstance(a, dict)]
        self.triggers = set([self.trigger] + self.also_due)
        self.plan = self.pk.get("plan_authoring", {}) or {}
        self.phases = [p for p in (self.plan.get("phases", []) or []) if isinstance(p, dict)]
        self.live = self.pk.get("plan_live", {}) or {}
        self.active_id = str(self.live.get("current_phase_id", ""))
        self.active = next((p for p in self.phases if str(p.get("id", "")).upper() == self.active_id.upper()), {})
        self.cs = self.pk.get("compact_state", {}) or {}
        self.ff = self.pk.get("force_feedback", {}) or {}
        self.events = self.pk.get("events_since_review", []) or []
        self.rules_src, self.ranges, self.matchups = self._rules()
        self.friendlies = {str(u.get("unit_id", "")): u for u in (self.cs.get("friendly_units", []) or []) if isinstance(u, dict)}
        self.enemies = {str(e.get("unit_id", "")): e for e in (self.cs.get("known_enemy_units", []) or []) if isinstance(e, dict)}
        self.visible = [e for e in self.enemies.values() if self._is_visible(e)]
        self.statuses = [s for s in (self.live.get("mission_statuses", []) or []) if isinstance(s, dict)]
        self.missions = self._missions()

    # -------------------------------------------------------------- rules
    def _rules(self) -> Tuple[str, Dict[str, int], Dict[Tuple[str, str], float]]:
        ctx = self.pk.get("context", {}) or {}
        rr = ctx.get("rules", {}) or {}
        classes = rr.get("classes", {}) or {}
        ranges: Dict[str, int] = {}
        matchups: Dict[Tuple[str, str], float] = {}
        if classes:
            for c, v in classes.items():
                if isinstance(v, dict) and "rng" in v:
                    ranges[_norm_class(c)] = int(v.get("rng", 1))
            for row in (rr.get("matchups", []) or []):
                if isinstance(row, (list, tuple)) and len(row) >= 3:
                    matchups[(_norm_class(row[0]), _norm_class(row[1]))] = float(row[2])
            return "context.rules", ranges, matchups
        # fallback: compact_state class names + combat_calculator.gd base table
        for u in list((self.cs.get("friendly_units", []) or [])) + list((self.cs.get("known_enemy_units", []) or [])):
            if isinstance(u, dict):
                c = _norm_class(u.get("class", ""))
                if c:
                    ranges[c] = BASE_RANGE.get(c, 1)
        return "combat_calculator.base", ranges, dict(BASE_MATCHUP)

    def rng_of(self, cls: str) -> int:
        return int(self.ranges.get(_norm_class(cls), BASE_RANGE.get(_norm_class(cls), 1)))

    def matchup(self, atk_cls: str, def_cls: str) -> float:
        return float(self.matchups.get((_norm_class(atk_cls), _norm_class(def_cls)), 1.0))

    # ------------------------------------------------------------- geometry
    @staticmethod
    def _pos(u: Dict[str, Any]) -> Tuple[int, int]:
        return (int(u.get("q", 0)), int(u.get("r", 0)))

    @staticmethod
    def _is_visible(e: Dict[str, Any]) -> bool:
        cs = str(e.get("contact_state", "")).lower()
        return cs == "current" or "visible" in cs

    def unit_in_contact(self, u: Dict[str, Any]) -> List[Dict[str, Any]]:
        out = []
        for e in self.visible:
            if hexdist(self._pos(u), self._pos(e)) <= self.rng_of(u.get("class", "")) + 1:
                out.append(e)
        return out

    # ------------------------------------------------------------- missions
    def _missions(self) -> List[Dict[str, Any]]:
        auth = self.active.get("missions", []) or []
        out = []
        for i, st in enumerate(self.statuses):
            mid = str(st.get("mission_id", "M%02d" % (i + 1)))
            a = auth[i] if i < len(auth) and isinstance(auth[i], dict) else {}
            task = str(st.get("task", a.get("task", ""))).upper()
            area = str(st.get("area", a.get("area", "ANY"))).upper()
            units = [str(x) for x in (st.get("units", []) or [])]
            out.append({
                "mission_id": mid, "idx": i, "task": task, "area": area, "units": units,
                "auth": a, "priority": str(a.get("priority", "")),
                "unit_objs": [self.friendlies[x] for x in units if x in self.friendlies],
            })
        # no mission_statuses: fall back to the active phase's authored missions
        if not out:
            for i, a in enumerate(auth):
                if not isinstance(a, dict):
                    continue
                out.append({
                    "mission_id": "M%02d" % (i + 1), "idx": i,
                    "task": str(a.get("task", "")).upper(), "area": str(a.get("area", "ANY")).upper(),
                    "units": [], "auth": a, "priority": str(a.get("priority", "")), "unit_objs": [],
                })
        return out

    def mission_in_contact(self, m: Dict[str, Any]) -> List[Dict[str, Any]]:
        hit = []
        for u in m["unit_objs"]:
            if self.unit_in_contact(u):
                hit.append(u)
        return hit

    def mission_ratio(self, m: Dict[str, Any]) -> Tuple[Optional[float], str]:
        """(ratio, err). err: '' | 'no_contact' | 'no_enemy' | 'bad_estimate'."""
        in_units = self.mission_in_contact(m)
        if not in_units:
            return None, "no_contact"
        own = 0.0
        enemy_ids = set()
        for u in in_units:
            contacts = self.unit_in_contact(u)
            mult = sum(self.matchup(u.get("class", ""), e.get("class", "")) for e in contacts) / max(1, len(contacts))
            own += float(u.get("soldiers", 0)) * mult
            for e2 in self.visible:
                if hexdist(self._pos(u), self._pos(e2)) <= 2:
                    enemy_ids.add(str(e2.get("unit_id", "")))
        enemy = 0.0
        for eid in sorted(enemy_ids):
            e = self.enemies[eid]
            mid = troop_mid(e.get("troop_estimate", ""))
            if mid is None:
                return None, "bad_estimate"
            # v2 symmetric: the enemy is weighted by its matchup against the own units it faces.
            facing = [u for u in in_units if hexdist(self._pos(u), self._pos(e)) <= 2] or in_units
            emult = sum(self.matchup(e.get("class", ""), u.get("class", "")) for u in facing) / len(facing)
            enemy += mid * emult
        if enemy <= 0:
            return None, "no_enemy"
        m["_own"], m["_enemy"] = own, enemy
        return own / enemy, ""

    def contact_desc(self, m: Dict[str, Any]) -> str:
        """'R_INF_1 (12,0) vs B_INF_1 (11,0)' — first contact pair of M (deterministic)."""
        us = self.mission_in_contact(m)
        if not us:
            return "-"
        u = us[0]
        es = self.unit_in_contact(u)
        s = "%s (%d,%d)" % (str(u.get("unit_id", "")), self._pos(u)[0], self._pos(u)[1])
        if es:
            e = es[0]
            s += " vs %s (%d,%d)" % (str(e.get("unit_id", "")), self._pos(e)[0], self._pos(e)[1])
        return s

    def losses_on(self, m: Dict[str, Any]) -> Tuple[bool, str]:
        """(lost?, detail) using only event detail fields (unit_id/defender_id/mission_id)."""
        unit_ids = set(m["units"])
        for e in self.events:
            if not isinstance(e, dict):
                continue
            kind = str(e.get("kind", ""))
            if kind not in ("FRIENDLY_UNIT_ATTACKED", "FRIENDLY_UNIT_DESTROYED", "UNIT_LOST"):
                continue
            d = e.get("detail", {}) or {}
            named = str(d.get("defender_id", "")) or str(d.get("unit_id", ""))
            mid = str(d.get("mission_id", ""))
            if (named and named in unit_ids) or (mid and mid == m["mission_id"]):
                return True, "%s %s" % (kind, named or mid)
        return False, ""

    # ------------------------------------------------------------ targets
    def _phases_copy(self) -> List[Dict[str, Any]]:
        return copy.deepcopy(self.phases)

    @staticmethod
    def _mission_at(phases: List[Dict[str, Any]], active_id: str, idx: int) -> Dict[str, Any]:
        ph = next((p for p in phases if str(p.get("id", "")).upper() == active_id.upper()), None)
        if ph is None:
            raise Drop(DROP_NO_PLAN)
        return ph["missions"][idx]

    def set_mission(self, phases: List[Dict[str, Any]], idx: int, task: Optional[str] = None,
                    area: Optional[str] = None, vs: Optional[str] = None) -> None:
        m = self._mission_at(phases, self.active_id, idx)
        if task is not None:
            m["task"] = task
        if area is not None:
            m["area"] = area
        if vs is not None:
            m["vs"] = vs
            m.pop("target", None)
            m.pop("zone", None)

    # ----------------------------------------------------------- decisions
    def amend_target(self, phases: List[Dict[str, Any]], reason: str) -> Dict[str, Any]:
        return {"decision": "AMEND_PLAN", "reason": _clean_reason(reason), "phases": phases}

    def keep_target(self, reason: str) -> Dict[str, Any]:
        return {"decision": "KEEP", "reason": _clean_reason(reason)}

    def advance_target(self, next_id: str, reason: str) -> Dict[str, Any]:
        return {"decision": "ADVANCE_PHASE", "reason": _clean_reason(reason), "next_phase_id": next_id}

    # --------------------------------------------------------- R1 HQ_DEFENSE
    def r1(self) -> Optional[Dict[str, Any]]:
        hq = next((u for u in self.friendlies.values() if _norm_class(u.get("class", "")) == "HQ"), None)
        if hq is None:
            return None
        hq_pos, hq_region = self._pos(hq), str(hq.get("region", "ANY")).upper()
        threats = [e for e in self.visible if _norm_class(e.get("class", "")) != "HQ"
                   and hexdist(hq_pos, self._pos(e)) <= R1_RADIUS]
        if not threats:
            return None
        for m in self.missions:  # covered by a manned ATTACK mission in the HQ region (Hands move them in)
            if m["task"] == "ATTACK" and m["area"] == hq_region and any(
                    _norm_class(u.get("class", "")) != "HQ" for u in m["unit_objs"]):
                return None
        m = self._closest_mission_to(hq_pos)
        near = self._nearest_threat(hq_pos, threats)
        vs = _norm_class(near.get("class", ""))
        phases = self._phases_copy()
        self.set_mission(phases, m["idx"], task="ATTACK", area=hq_region, vs=vs)
        self._mission_at(phases, self.active_id, m["idx"])["priority"] = "high"
        dist = [hexdist(hq_pos, self._pos(u)) for u in m["unit_objs"]]
        why = ("HQ %s (%d,%d) %s threatened: %s %s at %d hexes (%d threats within %d). %s %s/%s (%d units, nearest %s hexes) "
               "-> ATTACK %s vs %s, priority high.") % (
            str(hq.get("unit_id", "")), hq_pos[0], hq_pos[1], hq_region, str(near.get("unit_id", "")), vs,
            hexdist(hq_pos, self._pos(near)), len(threats), R1_RADIUS, m["mission_id"], m["task"], m["area"],
            len(m["units"]), (min(dist) if dist else "-"), hq_region, vs)
        return {"target": self.amend_target(phases, why), "rule": "R1", "subkind": "HQ_DEFENSE", "why": why}

    def _closest_mission_to(self, pos: Tuple[int, int]) -> Dict[str, Any]:
        manned = [m for m in self.missions if m["unit_objs"]]
        if not manned:
            return self._lowest_priority_mission()
        def key(m):
            d = [hexdist(pos, self._pos(u)) for u in m["unit_objs"]]
            return (sum(d) / len(d), -len(d), m["idx"])
        return sorted(manned, key=key)[0]

    def _contact_distance(self, m: Dict[str, Any]) -> int:
        """Hexes from M's closest unit to the closest visible enemy (99 = no units / no enemy)."""
        ds = [hexdist(self._pos(u), self._pos(e)) for u in m["unit_objs"] for e in self.visible]
        return min(ds) if ds else 99

    def _lowest_priority_mission(self) -> Dict[str, Any]:
        """v2: lowest priority; ties -> fewest Hand A units -> farthest from contact -> highest mission_id."""
        ranked = []
        for m in self.missions:
            r = PRIORITY_RANK.get(m["priority"].strip().lower())
            if r is None:
                raise Drop(DROP_AMBIG_PRIORITY, "R1 unknown mission priority %r" % m["priority"])
            ranked.append(((r, len(m["units"]), -self._contact_distance(m)), m))
        ranked.sort(key=lambda x: (x[0], [-ord(ch) for ch in x[1]["mission_id"]]))
        return ranked[0][1]

    def _nearest_threat(self, hq_pos: Tuple[int, int], threats: List[Dict[str, Any]]) -> Dict[str, Any]:
        dmin = min(hexdist(hq_pos, self._pos(e)) for e in threats)
        near = [e for e in threats if hexdist(hq_pos, self._pos(e)) == dmin]
        # v2: tie -> larger troop estimate, then unit_id (both visible in the packet)
        near.sort(key=lambda e: (-(troop_mid(e.get("troop_estimate", "")) or 0.0), str(e.get("unit_id", ""))))
        return near[0]

    # ----------------------------------------------------- R2 / R2b phases
    def resolve_next(self) -> Optional[str]:
        ids = [str(p.get("id", "")).upper() for p in self.phases]
        nxt = str(self.active.get("next", "")).strip().upper()
        if nxt in ids and nxt != self.active_id.upper():
            return nxt
        if nxt == "":
            i = ids.index(self.active_id.upper()) if self.active_id.upper() in ids else -1
            if 0 <= i + 1 < len(ids):
                return ids[i + 1]
        return None

    def r2(self) -> Optional[Dict[str, Any]]:
        if "PHASE_SUCCESS" not in self.triggers:
            return None
        nxt = self.resolve_next()
        if not nxt:
            return None
        why = "Phase %s success condition met (trigger %s); advancing to %s; %d missions unchanged." % (
            self.active_id, self.trigger or "also_due", nxt, len(self.missions))
        return {"target": self.advance_target(nxt, why), "rule": "R2", "subkind": "PHASE_DONE", "why": why}

    def _main_mission(self) -> Dict[str, Any]:
        """Highest priority; ties -> most Hand A units -> lowest mission index."""
        ranked = []
        for m in self.missions:
            r = PRIORITY_RANK.get(m["priority"].strip().lower(), 1)
            ranked.append(((-r, -len(m["units"]), m["idx"]), m))
        ranked.sort(key=lambda x: x[0])
        return ranked[0][1]

    def r2c(self) -> Optional[Dict[str, Any]]:
        """PLAN_EXHAUSTED: final phase done, BLUE HQ alive -> push on the HQ or consolidate."""
        if "PHASE_SUCCESS" not in self.triggers or self.resolve_next():
            return None
        ehq = next((e for e in self.enemies.values() if _norm_class(e.get("class", "")) == "HQ"), None)
        ohq = next((u for u in self.friendlies.values() if _norm_class(u.get("class", "")) == "HQ"), None)
        if ehq is None or ohq is None or not self.missions:
            return None
        own = float(sum(int(u.get("soldiers", 0)) for u in self.friendlies.values() if _norm_class(u.get("class", "")) != "HQ"))
        enemy = 0.0
        for e in self.visible:
            mid = troop_mid(e.get("troop_estimate", ""))
            if mid is None:
                raise Drop(DROP_BAD_ESTIMATE, "R2c troop_estimate unparseable")
            if _norm_class(e.get("class", "")) != "HQ":
                enemy += mid
        ratio = own / enemy if enemy > 0 else 99.0
        if R2C_BAND[0] <= ratio <= R2C_BAND[1]:
            raise Drop(DROP_AMBIG_RATIO, "R2c overall ratio %.2f in ambiguity band" % ratio)
        m = self._main_mission()
        if ratio > R2C_BAND[1]:
            task, area, vs = "ATTACK", str(ehq.get("region", "ANY")).upper(), "HQ"
        else:
            task, area, vs = "HOLD", str(ohq.get("region", "ANY")).upper(), None
        cur_vs = _norm_class((m["auth"] or {}).get("vs", ""))
        if m["task"] == task and m["area"] == area and (vs is None or cur_vs == vs):
            return None  # already set: per-contact rules decide
        phases = self._phases_copy()
        self.set_mission(phases, m["idx"], task=task, area=area, vs=vs)
        why = ("Plan exhausted: %s done, no next phase; BLUE HQ %s at (%d,%d) %s stands. Overall own %d vs visible est %d "
               "(ratio %.2f): %s %s/%s -> %s %s%s.") % (
            self.active_id, str(ehq.get("unit_id", "")), self._pos(ehq)[0], self._pos(ehq)[1],
            str(ehq.get("region", "")), int(own), int(enemy), ratio, m["mission_id"], m["task"], m["area"],
            task, area, (" vs " + vs) if vs else "")
        return {"target": self.amend_target(phases, why), "rule": "R2c",
                "subkind": "PUSH_HQ" if task == "ATTACK" else "CONSOLIDATE", "why": why}

    def r2b(self) -> Optional[Dict[str, Any]]:
        if not self.triggers & {"PHASE_FAILED", "PHASE_ABORT"}:
            return None
        on_fail = str(self.active.get("on_fail", "HOLD")).strip().upper()
        if on_fail == "ADVANCE":
            nxt = self.resolve_next()
            if nxt:
                why = "Phase %s failed/aborted (trigger %s) with on_fail ADVANCE; advancing to %s." % (
                    self.active_id, self.trigger or "also_due", nxt)
                return {"target": self.advance_target(nxt, why), "rule": "R2b", "subkind": "PHASE_FAIL", "why": why}
        # R2b fallback: R3-R5 as an AMEND on the active phase; else drop.
        for maker in (self.r3_engage, self.r3_pull_back, self.r4, self.r5):
            row = maker(quiet=True)
            if row is not None and row["target"].get("decision") == "AMEND_PLAN":
                row = dict(row)
                row["rule"] = "R2b"
                row["why"] = "Phase %s failed/aborted, no usable on_fail; %s" % (self.active_id, row["why"])
                row["target"] = self.amend_target(row["target"]["phases"], row["why"])
                return row
        raise Drop(DROP_R2B_NONE, "R2b fallback: no R3-R5 amendment applies")

    # ------------------------------------------------------------- R3
    def _in_contact_rows(self) -> List[Tuple[Dict[str, Any], Optional[float], str]]:
        rows = []
        for m in self.missions:
            if self.mission_in_contact(m):
                rows.append((m, *self.mission_ratio(m)))
        return rows

    def _check_band(self, rows: List[Tuple[Dict[str, Any], Optional[float], str]]) -> None:
        for m, ratio, err in rows:
            if err == "bad_estimate":
                raise Drop(DROP_BAD_ESTIMATE, "R3 troop_estimate unparseable on %s" % m["mission_id"])
            if ratio is not None and in_ambiguity_band(ratio):
                raise Drop(DROP_AMBIG_RATIO, "R3 %s ratio %.2f in ambiguity band" % (m["mission_id"], ratio))

    def r3_engage(self, quiet: bool = False) -> Optional[Dict[str, Any]]:
        rows = self._in_contact_rows()
        if not rows:
            return None
        self._check_band(rows)
        qual = [(m, r) for m, r, _ in rows if m["task"] not in TASKS_ATTACK and r is not None and r >= ENGAGE_AT]
        if not qual:
            return None
        phases = self._phases_copy()
        why_bits = []
        for m, r in qual:
            vs, _n_by = self._most_numerous_class(m)
            self.set_mission(phases, m["idx"], task="ATTACK", vs=vs)
            why_bits.append("%s %s/%s -> ATTACK vs %s; %s; ratio %.2f, own %d vs est %d" % (
                m["mission_id"], m["task"], m["area"], vs, self.contact_desc(m), r,
                int(m.get("_own", 0)), int(m.get("_enemy", 0))))
        why = _clean_reason("; ".join(why_bits))
        return {"target": self.amend_target(phases, why), "rule": "R3", "subkind": "ENGAGE", "why": why}

    def r3_pull_back(self, quiet: bool = False) -> Optional[Dict[str, Any]]:
        rows = self._in_contact_rows()
        if not rows:
            return None
        self._check_band(rows)
        qual = []
        for m, r, _ in rows:
            if r is not None and r <= PULL_AT:
                lost, det = self.losses_on(m)
                if lost:
                    qual.append((m, r, det))
        if not qual:
            return None
        phases = self._phases_copy()
        why_bits = []
        for m, r, det in qual:
            self.set_mission(phases, m["idx"], task="WITHDRAW")
            why_bits.append("%s %s/%s -> WITHDRAW; %s; ratio %.2f, own %d vs est %d; lost %s" % (
                m["mission_id"], m["task"], m["area"], self.contact_desc(m), r,
                int(m.get("_own", 0)), int(m.get("_enemy", 0)), det))
        why = _clean_reason("; ".join(why_bits))
        return {"target": self.amend_target(phases, why), "rule": "R3", "subkind": "PULL_BACK", "why": why}

    def r3_hold_fire(self) -> Optional[Dict[str, Any]]:
        rows = self._in_contact_rows()
        if not rows:
            return None
        self._check_band(rows)
        bits = []
        non_attack = False
        for m, r, _ in rows:
            n_contact = len(self.mission_in_contact(m))
            rt = "%.2f" % r if r is not None else "n/a"
            non_attack = non_attack or m["task"] not in TASKS_ATTACK
            bits.append("%s %s/%s: %s (%d units, ratio %s, own %d vs est %d)" % (
                m["mission_id"], m["task"], m["area"], self.contact_desc(m), n_contact, rt,
                int(m.get("_own", 0)), int(m.get("_enemy", 0))))
        if non_attack:
            tail = "Not attacking now: no engage margin (need ratio %.2f); holding avoids own losses." % ENGAGE_AT
        else:
            tail = "ATTACK missions engaged; pressing per plan."
        why = _clean_reason("Holding: %s. %s" % ("; ".join(bits), tail))
        return {"target": self.keep_target(why), "rule": "R3", "subkind": "HOLD_FIRE", "why": why}

    def _most_numerous_class(self, m: Dict[str, Any]) -> Tuple[str, int]:
        """Most numerous contacted enemy class of M: formations first, troop mass
        as the deterministic tie-break; a residual tie is ambiguous (dropped)."""
        counts: Dict[str, List[float]] = {}
        for u in self.mission_in_contact(m):
            for e in self.unit_in_contact(u):
                c = _norm_class(e.get("class", ""))
                counts.setdefault(c, []).append(troop_mid(e.get("troop_estimate", "")) or 0.0)
        if not counts:
            raise Drop(DROP_AMBIG_CLASS, "R3 no contacted enemy for vs")
        best_n = max(len(v) for v in counts.values())
        tied = sorted([c for c, v in counts.items() if len(v) == best_n])
        if len(tied) == 1:
            return tied[0], best_n
        masses = {c: sum(counts[c]) for c in tied}
        best_m = max(masses.values())
        tied2 = sorted([c for c in tied if masses[c] == best_m])
        if len(tied2) != 1:
            raise Drop(DROP_AMBIG_CLASS, "R3 most numerous enemy class tied %s" % tied2)
        return tied2[0], best_n

    # ------------------------------------------------------------- R4
    def r4(self, quiet: bool = False) -> Optional[Dict[str, Any]]:
        if not self.visible:
            return None
        total = len(self.visible)
        counts: Dict[str, int] = {}
        for e in self.visible:
            counts[str(e.get("region", "")).upper()] = counts.get(str(e.get("region", "")).upper(), 0) + 1
        best_n = max(counts.values())
        if best_n < 0.6 * total:
            return None
        sector = sorted([s for s, n in counts.items() if n == best_n])[0]
        qual = [m for m in self.missions
                if m["task"] in R4_TASKS and m["area"] != "ANY" and counts.get(m["area"], 0) == 0]
        if not qual:
            return None
        main_area = self._main_effort_area()
        phases = self._phases_copy()
        why_bits = []
        for m in qual:
            if m["task"] == "FLANK":
                new_area = self._flank_sector(sector, main_area)
            else:
                new_area = sector
            self.set_mission(phases, m["idx"], area=new_area)
            why_bits.append("%s %s %s -> %s (%d/%d visible enemies in %s)" % (
                m["mission_id"], m["task"], m["area"], new_area, best_n, total, sector))
        why = _clean_reason("Retarget: " + "; ".join(why_bits))
        return {"target": self.amend_target(phases, why), "rule": "R4", "subkind": "RETARGET", "why": why}

    def _main_effort_area(self) -> str:
        ranked = []
        for m in self.missions:
            r = PRIORITY_RANK.get(m["priority"].strip().lower())
            if r is None:
                raise Drop(DROP_AMBIG_MAIN, "R4 unknown mission priority %r" % m["priority"])
            ranked.append((r, m))
        best = max(r[0] for r in ranked)
        tied = [m for r, m in ranked if r == best]
        areas = sorted({m["area"] for m in tied})
        if len(areas) != 1:
            raise Drop(DROP_AMBIG_MAIN, "R4 main effort areas tied %s" % areas)
        return areas[0]

    def _flank_sector(self, sector: str, main_area: str) -> str:
        if sector not in SECTOR_CENTER or main_area not in SECTOR_CENTER:
            raise Drop(DROP_AMBIG_FLANK, "R4 sector geometry undefined for %s/%s" % (sector, main_area))
        sx, sy = SECTOR_CENTER[sector]
        dx, dy = sx - SECTOR_CENTER[main_area][0], sy - SECTOR_CENTER[main_area][1]
        if (dx, dy) == (0, 0):
            raise Drop(DROP_AMBIG_FLANK, "R4 flank side undefined: main effort at %s" % sector)
        cands = []
        for a, (ax, ay) in SECTOR_CENTER.items():
            if a == sector or a == main_area:
                continue
            if abs(ax - sx) + abs(ay - sy) == 0:
                continue
            d2 = (ax - sx) ** 2 + (ay - sy) ** 2
            if d2 > 8.1:  # adjacent: center distance <= 2.83 hexes
                continue
            cands.append((float((ax - sx) * dx + (ay - sy) * dy), a))
        if not cands:
            raise Drop(DROP_AMBIG_FLANK, "R4 no sector adjacent to %s" % sector)
        cands.sort()
        best = cands[-1][0]
        tied = sorted([a for s, a in cands if s == best])
        if best <= 0 or len(tied) != 1:
            raise Drop(DROP_AMBIG_FLANK, "R4 flank side tied %s for %s" % (tied, sector))
        return tied[0]

    # ------------------------------------------------------------- R5
    def unit_stalled(self, u: Dict[str, Any]) -> bool:
        rows = []
        for ff in (self.ff.get("units", []) or []):
            if isinstance(ff, dict) and str(ff.get("unit_id", "")) == str(u.get("unit_id", "")):
                rows = [str(a) for a in (ff.get("recent_actions", []) or [])]
        pts: List[Tuple[int, int]] = []
        for a in rows:
            if "(failed)" in a:
                continue  # execution failed: the unit did not move
            parts = a.split()
            if len(parts) >= 3 and parts[1] == "MOVE" and "," in parts[2]:
                try:
                    q, r = parts[2].split(",")[:2]
                    pts.append((int(q), int(r)))
                except ValueError:
                    continue
        if not pts:
            return False
        seq = pts + [self._pos(u)]
        path = sum(hexdist(seq[i], seq[i + 1]) for i in range(len(seq) - 1))
        net = hexdist(seq[0], seq[-1])
        return path >= 4 and net <= 1

    def r5(self, quiet: bool = False) -> Optional[Dict[str, Any]]:
        stalled = []
        for m in self.missions:
            if self.mission_in_contact(m):
                continue
            units = [u for u in m["unit_objs"] if self.unit_stalled(u)]
            if len(units) >= 2:
                stalled.append((m, units))
        if not stalled:
            return None
        if not self.visible:
            raise Drop(DROP_R5_NO_ENEMY, "R5 no visible enemy to advance toward")
        counts: Dict[str, int] = {}
        for e in self.visible:
            counts[str(e.get("region", "")).upper()] = counts.get(str(e.get("region", "")).upper(), 0) + 1
        best_n = max(counts.values())
        tied = sorted([s for s, n in counts.items() if n == best_n])
        if len(tied) != 1:
            raise Drop(DROP_AMBIG_SECTOR, "R5 most-visible sector tied %s" % tied)
        sector = tied[0]
        cand = [(m, units) for m, units in stalled if m["task"] != "ADVANCE"]
        if not cand:
            why = _clean_reason("Units of %s wander with no progress (path >= 4, net <= 1) but already ADVANCE toward %s; plan stands." % (
                ",".join(m["mission_id"] for m, _ in stalled), sector))
            return {"target": self.keep_target(why), "rule": "R5", "subkind": "UNSTALL", "why": why}
        phases = self._phases_copy()
        why_bits = []
        for m, units in cand:
            self.set_mission(phases, m["idx"], task="ADVANCE", area=sector)
            why_bits.append("%s %s/%s -> ADVANCE %s (stalled %s at (%d,%d))" % (
                m["mission_id"], m["task"], m["area"], sector,
                ",".join(str(u.get("unit_id", "")) for u in units),
                self._pos(units[0])[0], self._pos(units[0])[1]))
        why = _clean_reason("Unstall: " + "; ".join(why_bits) + "; %d enemies visible in %s." % (best_n, sector))
        return {"target": self.amend_target(phases, why), "rule": "R5", "subkind": "UNSTALL", "why": why}

    # ------------------------------------------------------------- R6
    def r6(self) -> Dict[str, Any]:
        n_vis = len(self.visible)
        why = _clean_reason("Plan stands: active %s (%s); %d visible enemies; no rule fired; %d missions unchanged." % (
            self.active_id, self.trigger or "review", n_vis, len(self.missions)))
        return {"target": self.keep_target(why), "rule": "R6", "subkind": "NONE", "why": why}

    # ----------------------------------------------------------- dispatch
    def _noop(self, row: Dict[str, Any]) -> bool:
        t = row.get("target") or {}
        return t.get("decision") == "AMEND_PLAN" and t.get("phases") == self.phases

    def run(self) -> Dict[str, Any]:
        if not self.phases or not self.active:
            raise Drop(DROP_NO_PLAN, "packet has no active phase in plan_authoring")
        for maker in (self.r1, self.r2, self.r2b, self.r2c, self.r3_engage, self.r3_pull_back,
                      self.r3_hold_fire, self.r4, self.r5):
            row = maker()
            if row is not None and not self._noop(row):  # an AMEND that changes nothing falls through
                return row
        return self.r6()


def v2_ok(packet: Dict[str, Any]) -> bool:
    """Every v2 field the corpus requires must be present (and usable)."""
    cs = packet.get("compact_state", {}) or {}
    ff = packet.get("force_feedback", {}) or {}
    live = packet.get("plan_live", {}) or {}
    statuses = live.get("mission_statuses", []) or []
    if not isinstance(cs, dict) or not cs.get("friendly_units"):
        return False
    if not isinstance(ff, dict) or not ff.get("units"):
        return False
    if not isinstance(statuses, list) or not statuses:
        return False
    return all(isinstance(s, dict) and str(s.get("units_source", "")) == "HAND_A" for s in statuses)


def decide(packet: Dict[str, Any]) -> Dict[str, Any]:
    """Deterministic teacher decision for one VICTORY_REVIEW packet.

    Returns {target, rule, subkind, why, drop_reason}. target is the exact
    JSON object for the production review contract (unalloc_v1), or None
    when the row must be dropped (drop_reason names why).
    """
    if not v2_ok(packet):
        return {"target": None, "rule": "DROP", "subkind": "DROP",
                "why": "packet missing a v2 field", "drop_reason": DROP_MISSING_V2}
    try:
        row = Teacher(packet).run()
        row["drop_reason"] = ""
        if row["target"] is None:  # never happens; be loud if it does
            row["drop_reason"] = DROP_INTERNAL
        else:
            row["why"] = row["target"]["reason"]  # the reason IS the emitted one (<= 200 chars)
        return row
    except Drop as d:
        return {"target": None, "rule": "DROP", "subkind": "DROP", "why": _clean_reason(d.why),
                "drop_reason": d.code}
