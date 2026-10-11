"""Combat — literal port of CombatCalculator.calculate_combat.

Formula order is authoritative (CC §1-§8): raw force -> matchup -> morale
modifier -> strategic -> variance -> clamp ratio -> roundi casualties ->
melee-only retaliation with unguarded zeroing. Godot roundi (half away from
zero) is used at every casualty rounding site.

NOT wired (frozen contract gaps — RulesetV0):
- terrain defense bonus (TerrainMods.DEFENSE_BONUS): not applied by the live
  calculate_combat; wiring point unfrozen (gap terrain_defense_wiring).
- archer range bonus: not applied in range checks (gap archer_range_bonus_wiring).
"""

from __future__ import annotations

from python_sim.rules import march
from python_sim.rules.rounding import clampf_gd, clampi_gd, maxi_gd, maxf_gd, mini_gd, roundi_gd

# CC.BASE_STATS (normalized names; supply entry kept for completeness but
# supply-class units are retired from spawn per SUP-1).
BASE_STATS: dict[str, dict] = {
    "cavalry": {"attack": 14.0, "defense": 6.0, "range": 1},
    "infantry": {"attack": 10.0, "defense": 10.0, "range": 1},
    "archer": {"attack": 12.0, "defense": 4.0, "range": 3},
    "spear": {"attack": 8.0, "defense": 14.0, "range": 1},
    "scout": {"attack": 2.0, "defense": 3.0, "range": 1},
    "siege": {"attack": 18.0, "defense": 2.0, "range": 2},
    "conscript": {"attack": 5.0, "defense": 5.0, "range": 1},
    "hq": {"attack": 8.0, "defense": 12.0, "range": 1},
    "supply": {"attack": 1.0, "defense": 2.0, "range": 1},
}

# CC.MATCHUP_TABLE (direct keys; reverse pairs take the reciprocal)
MATCHUP_TABLE: dict[str, float] = {
    "cavalry_vs_archer": 1.35,
    "archer_vs_spear": 1.35,
    "spear_vs_cavalry": 1.40,
    "infantry_vs_archer": 1.20,
    "infantry_vs_cavalry": 0.85,
    "infantry_vs_spear": 0.85,
    "conscript_vs_regular": 0.60,
    "scout_vs_regular": 0.55,
}

# CC field fortification (Model B: excess damage passes to troops)
FIELD_FORTIFICATION_DEFAULT_HP: int = 180
FIELD_FORTIFICATION_ABSORB_EXCESS_DAMAGE: bool = False

# CC formula literals (data-configurable, RulesetV0 combat_constants)
DEFENDER_DENOM_M: float = 4.2
DEFENDER_DENOM_B: float = 80.0
RATIO_MIN: float = 0.04
RATIO_MAX: float = 0.60
COUNTER_DENOM_M: float = 5.5
COUNTER_DENOM_B: float = 110.0
COUNTER_RATIO_MIN: float = 0.02
COUNTER_RATIO_MAX: float = 0.40
WALL_DAMAGE_MULT: float = 12.0
SIEGE_WALL_MULT: float = 2.5


def normalize_class_name(cname: str) -> str:
    n = cname.lower().strip()
    if n == "archers":
        return "archer"
    if n in ("spearman", "spearmen"):
        return "spear"
    if n == "scouts":
        return "scout"
    if n == "conscripts":
        return "conscript"
    return n


def get_matchup_mult(attacker_class: str, defender_class: str) -> float:
    """CC.get_matchup_mult — direct key, reciprocal rule, class fallbacks."""
    atk = normalize_class_name(attacker_class)
    dfn = normalize_class_name(defender_class)

    if atk == dfn:
        return 1.0

    direct_key = f"{atk}_vs_{dfn}"
    if direct_key in MATCHUP_TABLE:
        return float(MATCHUP_TABLE[direct_key])

    rev_key = f"{dfn}_vs_{atk}"
    if rev_key in MATCHUP_TABLE:
        return 1.0 / float(MATCHUP_TABLE[rev_key])

    if atk == "conscript" and dfn != "conscript":
        return float(MATCHUP_TABLE["conscript_vs_regular"])
    if dfn == "conscript" and atk != "conscript":
        return 1.0 / float(MATCHUP_TABLE["conscript_vs_regular"])

    if atk == "scout" and dfn != "scout":
        return float(MATCHUP_TABLE["scout_vs_regular"])
    if dfn == "scout" and atk != "scout":
        return 1.0 / float(MATCHUP_TABLE["scout_vs_regular"])

    return 1.0


def get_attack_range(unit_class: str) -> int:
    n = normalize_class_name(unit_class)
    if n in BASE_STATS:
        return int(BASE_STATS[n]["range"])
    return 1


def get_morale_modifier(morale: float, morale_rout_enabled: bool) -> float:
    """CC.get_morale_modifier — DEV sandbox keeps morale neutral (1.0)."""
    if not morale_rout_enabled:
        return 1.0
    m = clampf_gd(morale, 0.0, 100.0)
    return 0.40 + 0.60 * (m / 100.0)


def calculate_combat(
    attacker_data: dict,
    defender_data: dict,
    distance: int = 1,
    fortification_hp: int = 0,
    strategic_modifiers: dict | None = None,
    variance: float = 1.0,
    morale_rout_enabled: bool = False,
) -> dict:
    """Literal port of CC.calculate_combat (§1-§8). Returns the full result dict.

    variance defaults to 1.0 — the canonical battle path is deterministic.
    """
    if strategic_modifiers is None:
        strategic_modifiers = {}
    atk_class = normalize_class_name(str(attacker_data.get("class", "infantry")))
    def_class = normalize_class_name(str(defender_data.get("class", "infantry")))

    atk_troops = int(attacker_data.get("soldier_count", 100))
    def_troops = int(defender_data.get("soldier_count", 100))

    atk_morale = float(attacker_data.get("morale", 100.0))
    def_morale = float(defender_data.get("morale", 100.0))

    atk_base_stat = BASE_STATS.get(atk_class, {"attack": 10.0, "defense": 10.0, "range": 1})
    def_base_stat = BASE_STATS.get(def_class, {"attack": 10.0, "defense": 10.0, "range": 1})

    atk_base_atk = float(atk_base_stat["attack"])
    def_base_def = float(def_base_stat["defense"])
    def_base_atk = float(def_base_stat["attack"])
    atk_base_def = float(atk_base_stat["defense"])

    # §1 Raw force strength
    raw_force_strength = (float(atk_troops) / 100.0) * atk_base_atk

    # §2 Matchup
    matchup_mult = get_matchup_mult(atk_class, def_class)

    # §3 Morale modifiers
    atk_morale_mod = get_morale_modifier(atk_morale, morale_rout_enabled)
    def_morale_mod = get_morale_modifier(def_morale, morale_rout_enabled)

    # §4 Strategic modifiers
    strat_atk_mult = float(strategic_modifiers.get("attacker_bonus", 1.0))
    strat_def_mult = float(strategic_modifiers.get("defender_bonus", 1.0))

    # §5 Effective strengths
    eff_atk = raw_force_strength * matchup_mult * atk_morale_mod * strat_atk_mult * variance
    eff_def = (float(def_troops) / 100.0) * def_base_def * def_morale_mod * strat_def_mult * variance

    # §6 Fortress hard shield vs field fortification vs standard combat
    wall_damage = 0
    new_fortification_hp = fortification_hp
    def_casualties = 0

    init_field_fort_hp = int(defender_data.get("field_fortification_hp", 0))
    is_field_fortified = bool(
        defender_data.get("field_fortified", False)
        or defender_data.get("fortified", False)
        or init_field_fort_hp > 0
    )
    if is_field_fortified and init_field_fort_hp <= 0 and (
        "fortified" in defender_data or "field_fortified" in defender_data
    ):
        if bool(defender_data.get("field_fortified", False)) or bool(defender_data.get("fortified", False)):
            init_field_fort_hp = FIELD_FORTIFICATION_DEFAULT_HP

    field_fort_damage = 0
    rem_field_fort_hp = init_field_fort_hp
    is_field_fort_destroyed = False

    if fortification_hp > 0:
        # Fortress hard shield: wall HP only, garrison casualties 0.
        siege_mult = 2.5 if atk_class == "siege" else 1.0
        raw_wall_dmg = eff_atk * siege_mult * WALL_DAMAGE_MULT
        wall_damage = clampi_gd(roundi_gd(raw_wall_dmg), 1, fortification_hp)
        new_fortification_hp = maxi_gd(0, fortification_hp - wall_damage)
        def_casualties = 0
    else:
        # Standard troop combat (LOW_STRENGTH_CONTRACT_V0, literal mirror of
        # CC.calculate_combat): relative-power floor scaling + absolute finish
        # power reusing RATIO_MIN/RATIO_MAX. Healthy-vs-healthy numbers unchanged.
        power_scale = clampf_gd(eff_atk / maxf_gd(eff_def, 0.001), 0.0, 1.0)
        damage_ratio = clampf_gd(eff_atk / (maxf_gd(eff_def, 1.0) * DEFENDER_DENOM_M + DEFENDER_DENOM_B), RATIO_MIN * power_scale, RATIO_MAX)
        percent_damage = roundi_gd(float(def_troops) * damage_ratio)
        finish_damage = mini_gd(def_troops, roundi_gd(eff_atk * RATIO_MAX))
        raw_troop_damage = clampi_gd(max(percent_damage, finish_damage), 1, def_troops)

        if init_field_fort_hp > 0:
            field_fort_damage = mini_gd(raw_troop_damage, init_field_fort_hp)
            rem_field_fort_hp = maxi_gd(0, init_field_fort_hp - field_fort_damage)
            is_field_fort_destroyed = rem_field_fort_hp <= 0

            if FIELD_FORTIFICATION_ABSORB_EXCESS_DAMAGE:
                def_casualties = 0
            else:
                excess_damage = raw_troop_damage - field_fort_damage
                def_casualties = clampi_gd(excess_damage, 0, def_troops)
        else:
            def_casualties = raw_troop_damage

    # §7 Retaliation — melee only; UNGUARDED defender deals zero.
    atk_casualties = 0
    defender_unguarded = bool(defender_data.get("unguarded", False))
    if distance == 1 and def_troops > 0 and not defender_unguarded:
        counter_matchup = 1.0 / matchup_mult
        raw_def_atk = (float(def_troops) / 100.0) * def_base_atk
        eff_counter_atk = raw_def_atk * counter_matchup * def_morale_mod * variance
        eff_counter_def = (float(atk_troops) / 100.0) * atk_base_def * atk_morale_mod * variance
        counter_scale = clampf_gd(eff_counter_atk / maxf_gd(eff_counter_def, 0.001), 0.0, 1.0)
        counter_ratio = clampf_gd(eff_counter_atk / (maxf_gd(eff_counter_def, 1.0) * COUNTER_DENOM_M + COUNTER_DENOM_B), COUNTER_RATIO_MIN * counter_scale, COUNTER_RATIO_MAX)
        counter_percent = roundi_gd(float(atk_troops) * counter_ratio)
        counter_finish = mini_gd(atk_troops, roundi_gd(eff_counter_atk * COUNTER_RATIO_MAX))
        atk_casualties = clampi_gd(max(counter_percent, counter_finish), 0, atk_troops)
    elif defender_unguarded and distance == 1:
        atk_casualties = 0

    # §8 Casualty-to-morale shock (suppressed when morale disabled)
    def_loss_prop = float(def_casualties) / float(maxi_gd(1, def_troops))
    atk_loss_prop = float(atk_casualties) / float(maxi_gd(1, atk_troops))

    def_morale_shock = 0.0
    if fortification_hp > 0:
        def_morale_shock = float(wall_damage) / 1000.0 * 5.0
    elif init_field_fort_hp > 0 and def_casualties == 0:
        def_morale_shock = float(field_fort_damage) / 500.0 * 2.0
    else:
        def_morale_shock = def_loss_prop * 35.0 + (3.0 if def_casualties > 0 else 0.0)

    atk_morale_shock = 0.0
    if atk_casualties > 0:
        atk_morale_shock = atk_loss_prop * 35.0 + 2.0

    new_def_morale = clampf_gd(def_morale - def_morale_shock, 0.0, 100.0)
    new_atk_morale = clampf_gd(atk_morale - atk_morale_shock, 0.0, 100.0)
    if not morale_rout_enabled:
        # DEV sandbox: combat cannot degrade morale.
        def_morale_shock = 0.0
        atk_morale_shock = 0.0
        new_def_morale = def_morale
        new_atk_morale = atk_morale

    return {
        "attacker_class": atk_class,
        "defender_class": def_class,
        "attacker_initial_troops": atk_troops,
        "defender_initial_troops": def_troops,
        "attacker_casualties": atk_casualties,
        "defender_casualties": def_casualties,
        "attacker_remaining_troops": maxi_gd(0, atk_troops - atk_casualties),
        "defender_remaining_troops": maxi_gd(0, def_troops - def_casualties),
        "wall_damage": wall_damage,
        "initial_fortification_hp": fortification_hp,
        "remaining_fortification_hp": new_fortification_hp,
        "is_fortress_breached": fortification_hp > 0 and new_fortification_hp <= 0,
        "initial_field_fortification_hp": init_field_fort_hp,
        "remaining_field_fortification_hp": rem_field_fort_hp,
        "field_fortification_damage": field_fort_damage,
        "is_field_fortification_destroyed": is_field_fort_destroyed,
        "attacker_initial_morale": atk_morale,
        "defender_initial_morale": def_morale,
        "attacker_final_morale": new_atk_morale,
        "defender_final_morale": new_def_morale,
        "attacker_morale_delta": -atk_morale_shock,
        "defender_morale_delta": -def_morale_shock,
        "matchup_multiplier": matchup_mult,
        "effective_attack": eff_atk,
        "effective_defense": eff_def,
        "distance": distance,
        "is_ranged": distance > 1,
        "retaliation_occurred": distance == 1,
        "is_defender_field_fortified": rem_field_fort_hp > 0,
        "is_defender_fortified": rem_field_fort_hp > 0,
        "fortification_casualty_mult": 1.0,
    }


__all__ = [
    "BASE_STATS",
    "COUNTER_DENOM_B",
    "COUNTER_DENOM_M",
    "COUNTER_RATIO_MAX",
    "COUNTER_RATIO_MIN",
    "DEFENDER_DENOM_B",
    "DEFENDER_DENOM_M",
    "FIELD_FORTIFICATION_ABSORB_EXCESS_DAMAGE",
    "FIELD_FORTIFICATION_DEFAULT_HP",
    "MATCHUP_TABLE",
    "RATIO_MAX",
    "RATIO_MIN",
    "SIEGE_WALL_MULT",
    "WALL_DAMAGE_MULT",
    "calculate_combat",
    "get_attack_range",
    "get_morale_modifier",
    "get_matchup_mult",
    "normalize_class_name",
]
