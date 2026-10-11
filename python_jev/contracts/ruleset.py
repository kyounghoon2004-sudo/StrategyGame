"""RulesetV0 — machine-readable frozen tactical rules contract (rev 1).

Classifies the CURRENT authoritative Godot tactical mechanics for the future
Python simulator. Every rule carries exactly one classification:

  ACTIVE                implemented and authoritative in current game rules
  FROZEN_FOR_PRODUCTION production rule contract-frozen (Notion) even though the
                        DEV sandbox disables it by profile
  DEV_PROFILE_INACTIVE  rule exists in code but DEV_FLAT_FULL_INFO disables it
  DEFERRED              planned / present in code but NOT frozen enough to simulate
  EXCLUDED              explicitly outside the tactical MVP
  DEAD                  historical/unused implementation; do not port

CRITICAL: no numerical gameplay rule is invented here. Every number cites a
live symbol in the current Godot source (path :: symbol) or a frozen Notion
contract paragraph. Where the production behavior is not derivable from either,
the mechanic is DEFERRED and the missing rule is recorded in
`UNRESOLVED_CONTRACT_GAPS`.

The Notion "MVP Deterministic Skill Executor Contracts" freeze is treated as
the authority for the 30 skill semantics; the live Godot source is the
authority for the primitives those skills consume.
"""

from __future__ import annotations

import hashlib
import json

RULESET_VERSION = "ruleset-v0.1.0"
RULESET_REVISION = 1

ACTIVE = "ACTIVE"
FROZEN_FOR_PRODUCTION = "FROZEN_FOR_PRODUCTION"
DEV_PROFILE_INACTIVE = "DEV_PROFILE_INACTIVE"
DEFERRED = "DEFERRED"
EXCLUDED = "EXCLUDED"
DEAD = "DEAD"

# Shorthand citations
H = "scripts/core/hex_utils.gd"
HG = "scripts/core/hex_grid.gd"
WB = "scripts/step2r/step2r_world_boundary.gd"
CFG = "scripts/core/step3_config.gd"
UM = "scripts/step3/step3_unit_manager.gd"
PF = "scripts/step3/step3_pathfinding.gd"
CC = "scripts/combat/combat_calculator.gd"
TM = "scripts/combat/terrain_mods.gd"
MS = "scripts/combat/morale_system.gd"
MC = "scripts/combat/movement_calculator.gd"
TMM = "scripts/core/turn_manager.gd"
SR = "scripts/core/sandbox_rules.gd"
FOG = "scripts/step5/fog_of_war.gd"
S6 = "scripts/step6/step6_config.gd"
S6D = "scripts/step6/step6_decision_layer.gd"
SIM = "scripts/sim/sim_controller.gd"
SFP = "scripts/sim/sim_rules_fingerprint.gd"
PROJ = "scripts/step7/step7_observation_projector.gd"
WT = "scripts/step7/step7_world_truth.gd"
SH = "scripts/core/stronghold.gd"
NOTION = "Notion: Research Branch — System-1 Tactical Neural Model / Jev-inspired"

RULES: list[dict] = [
    # ------------------------------------------------------------------ 1 HEX
    {"family": "hex_geometry", "id": "axial_coordinates", "status": ACTIVE,
     "summary": "Flat-top axial (q,r), cube s=-q-r; grid storage odd-q offset with authoritative offset<->axial conversion.",
     "source": [f"{H} :: offset_to_axial / axial_to_offset / DIRECTIONS"]},
    {"family": "hex_geometry", "id": "six_neighbor_directions", "status": ACTIVE,
     "summary": "Six axial directions E,NE,NW,W,SW,SE = (1,0),(1,-1),(0,-1),(-1,0),(-1,1),(0,1); parity-aware odd-q offset neighbor tables used by offset A*.",
     "source": [f"{H} :: DIRECTIONS / DIRS_EVEN / DIRS_ODD / get_all_neighbors(_offset)"]},
    {"family": "hex_geometry", "id": "hex_distance", "status": ACTIVE,
     "summary": "Cube distance max(|dq|,|dr|,|ds|); offset inputs converted via offset_to_axial first.",
     "source": [f"{H} :: hex_distance / hex_distance_axial"]},
    {"family": "hex_geometry", "id": "map_boundary", "status": ACTIVE,
     "summary": "Playable field is the exact radius-40 hexagon (4,921 cells) centered at origin; outer impassable mountain field to radius 85; movement and fog both gate on is_playable_hex.",
     "source": [f"{WB} :: HEX_RADIUS=40 / PLAYABLE_HEX_COUNT=4921 / OUTER_HEX_RADIUS=85 / is_playable_hex",
                f"{PF} :: calculate_envelope playable gate"]},
    {"family": "hex_geometry", "id": "pixel_rounding", "status": DEAD,
     "summary": "world<->pixel conversion + cube rounding is presentation/input-picking only; the headless tactical simulator never consumes pixel geometry.",
     "source": [f"{H} :: hex_to_pixel / world_to_axial / hex_round"]},

    # ------------------------------------------------------------ 2 UNIT STATE
    {"family": "unit_state", "id": "unit_classes", "status": ACTIVE,
     "summary": "Field classes: infantry, spearman, archer, cavalry, scout (+ production siege/conscript/HQ; supply retired from spawn). Learned actor classes are the five JEV classes.",
     "source": [f"{CC} :: BASE_STATS / normalize_class_name", f"{UM} :: initialize_from_renderer_units (supply skip)", "Notion: Learned-actor scope"]},
    {"family": "unit_state", "id": "strength", "status": ACTIVE,
     "summary": "Integer soldier_count with per-unit max_count; unit destroyed at soldier_count <= 0.",
     "source": [f"{UM} :: initialize_from_renderer_units / destroy_unit / execute_attack"]},
    {"family": "unit_state", "id": "movement_state", "status": ACTIVE,
     "summary": "Per-unit base_mp, blue/red/black limits (1.0x/2.0x/2.2x base), turn_move_cost_spent, remaining_mp.",
     "source": [f"{CFG} :: get_blue_limit/get_red_limit/get_black_limit", f"{UM} :: execute_move / end_turn"]},
    {"family": "unit_state", "id": "attack_availability", "status": ACTIVE,
     "summary": "has_attacked one-attack-per-turn lock (cavalry included); action_ended lock; routed and supply units cannot attack.",
     "source": [f"{UM} :: execute_attack precondition block; get_attackable_targets"]},
    {"family": "unit_state", "id": "acted_state", "status": ACTIVE,
     "summary": "action_ended / turn_resolved semantics: explicit end, fortify/rest, blue-budget exhaustion (spent >= blue_limit - 0.001), garrisoned, routed auto-resolve.",
     "source": [f"{UM} :: is_unit_data_turn_resolved"]},
    {"family": "unit_state", "id": "guard_state", "status": ACTIVE,
     "summary": "GREEN march -> defense_ready (GUARD); ORANGE/RED march or river crossing -> unguarded; UNGUARDED defender deals no opening reciprocal damage; fortification preserves GUARD across turns.",
     "source": [f"{UM} :: execute_move (march->guard mapping); end_turn (fortified GUARD preservation)", f"{CC} :: retaliation block (defender_unguarded)"]},
    {"family": "unit_state", "id": "morale_value", "status": DEV_PROFILE_INACTIVE,
     "summary": "Per-unit morale 0..100 (init 100) exists on every unit; movement morale penalties and combat morale shocks are gated OFF by the DEV sandbox and by canonical combat variance path.",
     "source": [f"{UM} :: initialize_from_renderer_units (morale=100)", f"{SR} :: morale_rout_enabled()"]},

    # -------------------------------------------------------------- 3 MOVEMENT
    {"family": "movement", "id": "base_movement", "status": ACTIVE,
     "summary": "CLASS_BASE_MOVEMENT: cavalry 3.0, infantry 2.0, archer 2.0, spear 2.0, scout 4.0, siege 1.0, conscript 1.0, hq 1.0.",
     "source": [f"{CFG} :: CLASS_BASE_MOVEMENT"]},
    {"family": "movement", "id": "reachable_area_algorithm", "status": ACTIVE,
     "summary": "Dijkstra expansion from origin over playable hexes to the policy budget; array-scan priority queue; relax when tent_g < existing_g - 0.0001 (float epsilon).",
     "source": [f"{PF} :: calculate_envelope"]},
    {"family": "movement", "id": "march_tiers", "status": ACTIVE,
     "summary": "GREEN <= blue_limit, ORANGE <= red_limit (2x), RED <= black_limit (2.2x), each with +0.001 tolerance; river crossing forces RED.",
     "source": [f"{CFG} :: classify_march_by_cumulative_cost / MARCH_MULTIPLIERS"]},
    {"family": "movement", "id": "march_policy_filter", "status": ACTIVE,
     "summary": "Policy ceiling filters reachable set: GREEN_ONLY blocks ORANGE+RED; ORANGE_ALLOWED blocks RED; RED_ALLOWED allows all. Player default RED_ALLOWED (unit manager init); production RED AI moves with GREEN_ONLY.",
     "source": [f"{CFG} :: is_policy_allowed", f"{UM} :: _current_policy init", f"{SIM} :: do_move (RED uses GREEN_ONLY, line ~404)"]},
    {"family": "movement", "id": "terrain_costs", "status": ACTIVE,
     "summary": "Standard: plains 1.0, mountains 3.0, forest 2.0, swamp 2.0, fortress 1.0, village 1.0, road 0.5, river 1.0, wall/stronghold interior 99 (impassable). Scout: forest 1.0, mountains 1.0, swamp 1.5.",
     "source": [f"{CFG} :: TERRAIN_COSTS_STANDARD / TERRAIN_COSTS_SCOUT"]},
    {"family": "movement", "id": "occupancy_blocking", "status": ACTIVE,
     "summary": "One field formation per hex. Planning blockers = friendly units + currently VISIBLE enemies only (player-known occupancy; hidden enemies never deflect plans; stale markers never block). Destination occupied -> invalid.",
     "source": [f"{PF} :: calculate_envelope occupancy block + STEP-05R3 §6 comment", f"{UM} :: get_player_known_occupied (line 1851)"]},
    {"family": "movement", "id": "stepwise_contact", "status": ACTIVE,
     "summary": "Authoritative BLUE movement walks one hex at a time: STOP before stacking on a first-occupied hex (hidden enemy contact), charge MP only for traversed hexes, return partial-move success with contact info.",
     "source": [f"{UM} :: execute_player_stepwise_move (line 1902)"]},
    {"family": "movement", "id": "action_continuation", "status": ACTIVE,
     "summary": "After a move: action_ended only when the march crossed a river or cumulative spend reached the black limit; otherwise the unit may continue (attack availability persists until used).",
     "source": [f"{UM} :: execute_move (§9/§10 revised R10 block)"]},
    {"family": "movement", "id": "fortified_movement_lock", "status": ACTIVE,
     "summary": "A field-fortified unit cannot move until the fortification is explicitly dismantled (dismantle costs 1.0 MP; remaining MP usable the same turn).",
     "source": [f"{UM} :: execute_move fortified block; FIELD_FORTIFICATION_DISMANTLE_MP_COST"]},

    # ---------------------------------------------------------------- 4 COMBAT
    {"family": "combat", "id": "base_stats", "status": ACTIVE,
     "summary": "attack/defense/range per class: cavalry 14/6/1, infantry 10/10/1, archer 12/4/3, spear 8/14/1, scout 2/3/1, siege 18/2/2, conscript 5/5/1, hq 8/12/1.",
     "source": [f"{CC} :: BASE_STATS / get_attack_range"]},
    {"family": "combat", "id": "matchup_table", "status": ACTIVE,
     "summary": "Direct keys: cav>archer 1.35, archer>spear 1.35, spear>cav 1.40, infantry>archer 1.20, infantry<cav and infantry<spear 0.85, conscript_vs_regular 0.60, scout_vs_regular 0.55; reverse pairs take the reciprocal; same class 1.0.",
     "source": [f"{CC} :: MATCHUP_TABLE / get_matchup_mult"]},
    {"family": "combat", "id": "damage_formula", "status": ACTIVE,
     "summary": "raw = (atk_troops/100)*atk_base_atk; eff_atk = raw * matchup * morale_mod * strategic * variance; eff_def = (def_troops/100)*def_base_def * morale_mod * strategic * variance; damage_ratio = clamp(eff_atk / (max(eff_def,1)*4.2 + 80), 0.04*power_scale, 0.60) with power_scale = clamp(eff_atk/max(eff_def,0.001),0,1); defender_casualties = clamp(max(round(def_troops*ratio), min(def_troops,round(eff_atk*0.60))), 1, def_troops) (LOW_STRENGTH_CONTRACT_V0: relative-power floor + absolute finish).",
     "source": [f"{CC} :: calculate_combat §1-§6"]},
    {"family": "combat", "id": "retaliation", "status": ACTIVE,
     "summary": "Only melee (distance == 1) retaliates: counter_ratio = clamp(eff_counter_atk / (max(eff_counter_def,1)*5.5 + 110), 0.02*counter_scale, 0.40) with counter_scale = clamp(eff_counter_atk/max(eff_counter_def,0.001),0,1); attacker_casualties = clamp(max(round(atk_troops*ratio), min(atk_troops,round(eff_counter_atk*0.40))), 0, atk_troops); UNGUARDED defender deals zero reciprocal. Ranged (distance > 1) receives no return damage.",
     "source": [f"{CC} :: calculate_combat §7"]},
    {"family": "combat", "id": "variance_determinism", "status": ACTIVE,
     "summary": "Canonical battle path executes combat with variance=1.0 (preview paths use 0.95/1.05). No randf/randi on the battle path; combat is deterministic.",
     "source": [f"{UM} :: execute_attack (default variance 1.0)", f"{SIM} :: header + sim_entry.gd :: _g4_seed_report (gate4 assertion)"]},
    {"family": "combat", "id": "cavalry_continuation", "status": ACTIVE,
     "summary": "After an attack, cavalry keeps action_ended=false (may move on); all other classes end their action and remaining_mp=0.",
     "source": [f"{UM} :: execute_attack cavalry continuation block"]},
    {"family": "combat", "id": "death_cleanup", "status": ACTIVE,
     "summary": "Units at 0 soldiers are destroyed immediately (occupancy freed, destruction event); destroyed enemies leave no stale marker.",
     "source": [f"{UM} :: execute_attack / destroy_unit", f"{FOG} :: stale pruning (present_red)"]},
    {"family": "combat", "id": "fortress_shield", "status": ACTIVE,
     "summary": "Attacks against intact fortress/capital walls damage wall HP only (wall_damage = clamp(round(eff_atk * siege_mult * 12), 1, fort_hp); siege mult 2.5), garrison casualties 0 until breach.",
     "source": [f"{CC} :: calculate_combat fortress branch", f"{UM} :: execute_stronghold_assault"]},
    {"family": "combat", "id": "field_fortification", "status": ACTIVE,
     "summary": "Temporary field fortification: 180 HP default, Model B (excess damage passes to troops), absorbs before troops, persists across turns until destroyed/dismantled.",
     "source": [f"{CC} :: FIELD_FORTIFICATION_* consts + standard-combat absorb branch", f"{UM} :: end_turn (preservation comment)"]},
    {"family": "combat", "id": "terrain_defense_bonus", "status": DEV_PROFILE_INACTIVE,
     "summary": "TerrainMods defense multipliers (mountains 1.5, forest 1.3, swamp 1.2, fortress 2.0, village 1.1) exist but are NOT wired into calculate_combat's eff_def; surfaced only via preview/eval layers. FROZEN-CONTRACT-INCOMPLETE for the simulator: wiring point must be specified before simulation.",
     "source": [f"{TM} :: DEFENSE_BONUS", f"{CC} :: calculate_combat (no terrain defense term)", f"{SFP} :: terrain_mods fingerprint entry"]},
    {"family": "combat", "id": "archer_range_bonus", "status": DEV_PROFILE_INACTIVE,
     "summary": "Mountains/fortress give archers +1 range via TerrainMods; not applied inside execute_attack's range check today (attack range uses BASE_STATS only). DEFERRED pending wiring decision.",
     "source": [f"{TM} :: ARCHER_RANGE_BONUS", f"{UM} :: execute_attack (max_range = BASE_STATS only)"]},
    {"family": "combat", "id": "ambush", "status": ACTIVE,
     "summary": "Hidden enemy with a legal adjacent melee attack on a mover's entered hex performs an opening strike: no reciprocal damage for the ambusher, victim's action ends, victim movement stops. Only melee ambush in Step 5.",
     "source": [f"{UM} :: execute_ambush_strike (§22-26)"]},

    # --------------------------------------------------------- 5 TURN / PHASE
    {"family": "turn_phase", "id": "faction_cycle", "status": ACTIVE,
     "summary": "BLUE (player) then RED (enemy) per cycle; TurnManager increments the turn per full cycle and resets phase to RECON on faction switch; headless SimController orders: Step6.end_turn_charges -> UnitManager.end_turn -> Step6.begin_player_turn -> Fog.recompute.",
     "source": [f"{TMM} :: start_player_turn/advance_to_enemy_turn/advance_to_player_turn", f"{SIM} :: sim_end_turn"]},
    {"family": "turn_phase", "id": "battle_phases", "status": ACTIVE,
     "summary": "Per-faction phases RECON(0) -> DEPLOY(1) -> ENGAGE(2) -> RESOLVE(3); phase enum in TurnManager.",
     "source": [f"{TMM} :: BattlePhase / next_phase"]},
    {"family": "turn_phase", "id": "end_turn_reset", "status": ACTIVE,
     "summary": "end_turn(): per unit reset turn_move_cost_spent=0, remaining_mp=base, action_ended=false, turn_resolved=false, has_moved/has_attacked=false, rested/resting_unguarded/reviewed=false; guard reset unless fortified (fortified keep GUARD); fortifications persist.",
     "source": [f"{UM} :: end_turn (line 1416)"]},
    {"family": "turn_phase", "id": "actor_ordering", "status": ACTIVE,
     "summary": "Sequential mutation; BLUE unresolved field units iterate in stable id-string ascending order; NEXT navigation never resolves a unit; NEXT-flow resolution requires per-unit resolve/wait/rest/fortify/attack-end or blue-budget exhaustion.",
     "source": [f"{UM} :: get_unresolved_friendly_field_units_in_stable_order / resolve_unit_via_next / try_resolve_current_via_next", "Notion: Sequential execution assumption"]},
    {"family": "turn_phase", "id": "mission_evaluation", "status": ACTIVE,
     "summary": "evaluate_mission() (BATTLE_TERMINAL_CONTRACT_V0, defeat-first order): defeat when battle lost / BLUE HQ dead (if fielded at start) / BLUE annihilated; victory when RED HQ dead (if fielded at start, all objectives) else per objective (destroy_all_red / capture_capital / survive_turns / hold_hq); ongoing -> expired when turn_limit exceeded without decision. evaluate_battle() projects terminal/winner/loser/reason/turn; terminal freezes all mutation and reviews.",
     "source": [f"{SIM} :: evaluate_mission / evaluate_battle", f"{S6D} :: is_battle_lost"]},

    # --------------------------------------------------------------- 6 TERRAIN
    {"family": "terrain", "id": "terrain_enum", "status": ACTIVE,
     "summary": "HexCell.TerrainType: PLAINS, MOUNTAINS, FOREST, SWAMP, FORTRESS, VILLAGE, ROAD, RIVER, WALL, STRONGHOLD_FOOTPRINT, STRONGHOLD_WALL, CAPITAL_FOOTPRINT, CAPITAL_WALL, OUTER_MOUNTAIN.",
     "source": ["scripts/core/hex_cell.gd :: TerrainType"]},
    {"family": "terrain", "id": "impassability", "status": ACTIVE,
     "summary": "WALL(8), STRONGHOLD_FOOTPRINT(9), STRONGHOLD_WALL(10) and anything >= 99 are impassable; fortress/city interiors never route through (§25); outer mountain field blocks by boundary, not cost.",
     "source": [f"{CFG} :: is_impassable", f"{PF} :: stronghold_cells block"]},
    {"family": "terrain", "id": "river_crossing", "status": ACTIVE,
     "summary": "RIVER terrain is traversable at cost 1.0; any route touching a river cell (or entering terrain 7) is classified RED march and auto-ends the mover's action.",
     "source": [f"{CFG} :: classify_march_by_cumulative_cost(crosses_river)", f"{PF} :: river_flag propagation", f"{UM} :: execute_move end_action rule"]},
    {"family": "terrain", "id": "los_blockers", "status": ACTIVE,
     "summary": "Hex LOS ray trace: any intermediate MOUNTAIN blocks; intermediate FOREST blocks sight to hexes at distance >= 3; target forest hex itself stays visible; off-map gap blocks.",
     "source": [f"{FOG} :: _has_los / _hex_line / TERRAIN_MOUNTAIN=1 / TERRAIN_FOREST=2"]},
    {"family": "terrain", "id": "ambush_terrain", "status": ACTIVE,
     "summary": "Forest and swamp permit ambush triggers (HexCell.can_ambush / TerrainMods.CAN_AMBUSH); the ambush resolution primitive is ACTIVE (see combat.ambush).",
     "source": ["scripts/core/hex_cell.gd :: can_ambush", f"{TM} :: CAN_AMBUSH"]},

    # ------------------------------------------------------ 7 FOG / KNOWLEDGE
    {"family": "fog", "id": "vision_radii", "status": ACTIVE,
     "summary": "Normal vision radius 2; scout vision radius 4 (provisional/configurable value); radius may be tuned without structural change.",
     "source": [f"{FOG} :: normal_vision=2 / scout_vision=4"]},
    {"family": "fog", "id": "visibility_computation", "status": ACTIVE,
     "summary": "Visibility = union of all living, non-garrisoned, non-routed friendly observers' LOS disks; recomputed only on discrete state changes, never per frame.",
     "source": [f"{FOG} :: recompute (garrisoned/routed exclusions)", f"{SIM} :: _refresh_observation"]},
    {"family": "fog", "id": "fog_states", "status": ACTIVE,
     "summary": "Three hex states: UNEXPLORED / EXPLORED (past-seen) / VISIBLE; strategic objective hexes are terrain-known (auto-explored).",
     "source": [f"{FOG} :: FogState / get_fog_state / objective_hexes"]},
    {"family": "fog", "id": "contact_lifecycle", "status": ACTIVE,
     "summary": "Visible -> hidden transition freezes a stale snapshot (turn, q, r, class, scout flag, troop_text band, health ratio only if combat-assessed); frozen records are NEVER updated while hidden; rediscovery supersedes; destroyed enemies leave no stale marker.",
     "source": [f"{FOG} :: recompute stale freeze block / stale_contacts / ever_seen / get_stale_snapshot"]},
    {"family": "fog", "id": "strength_estimation_bands", "status": ACTIVE,
     "summary": "Scout-observed strength uses deterministic hash-keyed bands (±10% band around count, rounded to 50, min width 100) keyed by enemy id+turn; combat-assessed strength rounds to nearest 50 (<500) else nearest 100. Deterministic: same (count, key) -> same band.",
     "source": [f"{FOG} :: estimate_band / combat_approx_troops (static, hash-based)"]},
    {"family": "fog", "id": "command_loss_memory", "status": ACTIVE,
     "summary": "Routed (command-lost) BLUE formations contribute no LOS and leave a frozen friendly last-known marker until recontact/rally.",
     "source": [f"{FOG} :: note_friendly_command_loss / friendly_stale", f"{SIM} :: _apply_rout_fog_notes"]},
    {"family": "fog", "id": "knowledge_ledger", "status": ACTIVE,
     "summary": "FactionKnowledge projection: own forces (complete), currently visible enemies, last-known stale contacts; strongholds projected; per-faction ledgers (blue/red) never cross hidden truth.",
     "source": [f"{PROJ} :: capture_turn / build_blue_knowledge / build_red_knowledge", f"{WT} :: facade (no duplication of state)"]},
    {"family": "fog", "id": "observation_safe_legality", "status": FROZEN_FOR_PRODUCTION,
     "summary": "The six-bit skill mask masks only known impossibility from actor state + authorized knowledge; hidden WorldTruth may never turn a bit off; the engine rechecks legality at execution.",
     "source": ["Notion: Observation-safe six-skill legality mask", f"{UM} :: execute_* precondition recheck"]},
    {"family": "fog", "id": "worldtruth_execution", "status": FROZEN_FOR_PRODUCTION,
     "summary": "Executors validate against authoritative state (I3/I5); hidden obstacles/enemies resolve into canonical contact/stop/failure events instead of pre-masking.",
     "source": ["Notion: Shared executor invariants I3-I5", f"{UM} :: execute_player_stepwise_move contact resolution"]},

    # --------------------------------------------------------- 8 HQ / OBJECTIVES
    {"family": "hq_objectives", "id": "hq_unit", "status": ACTIVE,
     "summary": "HQ exists as a non-learned field unit class (is_hq flag, BASE_STATS hq 8/12/1); HQ alive state feeds mission evaluation; BLUE HQ destruction/loss of all blue => defeat (RED wins), RED HQ destruction => victory (BLUE wins), symmetric and immediate when the side fielded an HQ at scenario start.",
     "source": [f"{UM} :: initialize_from_renderer_units (is_hq)", f"{SIM} :: evaluate_mission (hq_alive/red_hq_alive)"]},
    {"family": "hq_objectives", "id": "strongholds", "status": ACTIVE,
     "summary": "Multi-hex Fortress (3 hexes, 4 slots, 1000 HP) and Capital (3 hexes, 6 slots, 1500 HP) with garrison rosters, one wall-pool shield, breach and multi-garrison targeting; footprint hexes are impassable terrain that route around.",
     "source": [f"{SH} :: StrongholdType / enter_garrison", f"{UM} :: DEFAULT_FORTRESS_*/DEFAULT_CAPITAL_* + execute_stronghold_assault", f"{PF} :: footprint routing block"]},
    {"family": "hq_objectives", "id": "objective_markers", "status": ACTIVE,
     "summary": "Objective hexes are terrain-known through fog (auto-explored) and projected into faction knowledge.",
     "source": [f"{FOG} :: set_objective_hexes / objective_hexes", f"{PROJ} :: _projected_strongholds"]},

    # ----------------------------------------------------- 9 MORALE / COHESION
    {"family": "morale", "id": "morale_combat_modifier", "status": DEV_PROFILE_INACTIVE,
     "summary": "Production morale modifier 0.40 + 0.60*(morale/100) is implemented and fingerprinted but gated to 1.0 by the DEV sandbox (morale_rout_enabled=false).",
     "source": [f"{CC} :: get_morale_modifier", f"{SR} :: morale_rout_enabled"]},
    {"family": "morale", "id": "march_morale_penalty", "status": DEV_PROFILE_INACTIVE,
     "summary": "March morale penalties GREEN 0 / ORANGE -5 / RED -15 applied on move when morale enabled; zero in DEV sandbox.",
     "source": [f"{CFG} :: MORALE_PENALTY / get_morale_penalty", f"{UM} :: execute_move morale application"]},
    {"family": "morale", "id": "casualty_morale_shock", "status": DEV_PROFILE_INACTIVE,
     "summary": "Casualty-to-morale shock (loss_proportion*35 + flat bonus) computed in combat and suppressed to 0 in DEV sandbox.",
     "source": [f"{CC} :: calculate_combat §8", f"{SR} :: morale_rout_enabled"]},
    {"family": "morale", "id": "rout_rally", "status": DEV_PROFILE_INACTIVE,
     "summary": "Rout/rally: morale line 20, base p 0.25 (+0.02/point below line, hungry +0.10, cap 0.80), rally after >=2 turns near HQ with base p 0.50; routed formations lose command/LOS; hash-keyed seeded_roll(key)=abs(hash(key))%1000/1000 is the deterministic RNG.",
     "source": [f"{S6} :: ROUT_* / RALLY_* consts", f"{S6D} :: seeded_roll / _rout_and_rally / _rally_or_flee"]},
    {"family": "morale", "id": "fatigue", "status": DEV_PROFILE_INACTIVE,
     "summary": "Fatigue accumulates per march class (GREEN 4 / ORANGE 18 / RED 32, exhausted at 60) and interacts with combat multipliers.",
     "source": [f"{S6} :: FATIGUE_* consts", f"{UM} :: execute_move fatigue accumulation"]},
    {"family": "morale", "id": "morale_system_legacy", "status": DEAD,
     "summary": "scripts/combat/morale_system.gd thresholds/deltas are a parallel legacy curve not referenced by the canonical combat path (fingerprint lists its state constants only); do not port.",
     "source": [f"{MS} :: whole file", f"{SFP} :: morale_system entry (labels only)"]},
    {"family": "morale", "id": "cohesion", "status": DEFERRED,
     "summary": "Cohesion as a distinct formation-level state does not exist in current code; Notion freezes only that it MAY exist when contract-frozen. No numeric rule to port.",
     "source": ["Notion: Production Tactical Domain Contract (morale/cohesion/rout included when frozen)"]},

    # ----------------------------------------------------------- 10 RANDOMNESS
    {"family": "randomness", "id": "combat_path", "status": ACTIVE,
     "summary": "Combat on the canonical path is deterministic (variance=1.0, no randf/randi). Seed is recorded in provenance only.",
     "source": [f"{SIM} :: header comment", f"{UM} :: execute_attack default variance", "scripts/sim/sim_entry.gd :: _g4_seed_report"]},
    {"family": "randomness", "id": "deterministic_hash_roll", "status": ACTIVE,
     "summary": "Where stochastic rules exist (rout/rally/witness shock), RNG is a stateless hash: seeded_roll(key) = abs(hash(key)) % 1000 / 1000 — replayable without RNG state.",
     "source": [f"{S6D} :: seeded_roll"]},
    {"family": "randomness", "id": "strategic_rng", "status": EXCLUDED,
     "summary": "randf/randi uses live only in campaign (game_director), AI fallback flavor, UI preview and visual seeds — all outside the tactical battle runtime; no parity requirement.",
     "source": ["scripts/campaign/game_director.gd :: randf uses", "scripts/ai/rule_based_fallback.gd :: randf uses", "scripts/ui/ui_preview.gd :: randi uses"]},

    # ------------------------------------------------------ 11 EXCLUDED / DEAD
    {"family": "excluded", "id": "supply_food", "status": EXCLUDED,
     "summary": "Food/supply logistics retired globally (canonical production AND DEV) per SUP-FINAL; Step6Config values remain only as fingerprint/dead code. The simulator must not implement them.",
     "source": [f"{SR} :: supply_enabled/food_enabled (always false)", f"{CFG} :: SUP-FINAL notes", f"{S6} :: supply consts (fingerprint only)"]},
    {"family": "excluded", "id": "campaign_layer", "status": EXCLUDED,
     "summary": "Campaign economy, diplomacy, world politics, dialogue — outside the tactical MVP.",
     "source": ["Notion: Explicit exclusions"]},
    {"family": "excluded", "id": "legacy_battle_map_combat", "status": DEAD,
     "summary": "scripts/core/battle_map.gd's own combat/rout resolution and scripts/combat/movement_calculator.gd's legacy size-based costs are superseded by the Step3/Step4 canonical path (BattleMap is used only by the legacy scene entry); do not port.",
     "source": ["scripts/core/battle_map.gd :: internal combat/rout", f"{MC} :: TERRAIN_COST/size factors", f"{UM} :: canonical path", f"{SIM} :: authoritative path list (header)"]},
]

# ---------------------------------------------------------------------------
# Data-configurable rules vs algorithmic rules
# ---------------------------------------------------------------------------
DATA_CONFIGURABLE_RULES = {
    "class_base_movement": {"source": f"{CFG} :: CLASS_BASE_MOVEMENT", "values": {"cavalry": 3.0, "infantry": 2.0, "archer": 2.0, "spear": 2.0, "scout": 4.0, "siege": 1.0, "conscript": 1.0, "hq": 1.0}},
    "terrain_costs_standard": {"source": f"{CFG} :: TERRAIN_COSTS_STANDARD", "values": {"PLAINS": 1.0, "MOUNTAINS": 3.0, "FOREST": 2.0, "SWAMP": 2.0, "FORTRESS": 1.0, "VILLAGE": 1.0, "ROAD": 0.5, "RIVER": 1.0, "WALL": 99.0, "STRONGHOLD_FOOTPRINT": 99.0, "STRONGHOLD_WALL": 99.0}},
    "terrain_costs_scout": {"source": f"{CFG} :: TERRAIN_COSTS_SCOUT", "values": {"PLAINS": 1.0, "MOUNTAINS": 1.0, "FOREST": 1.0, "SWAMP": 1.5, "FORTRESS": 1.0, "VILLAGE": 1.0, "ROAD": 0.5, "RIVER": 1.0, "WALL": 99.0}},
    "base_stats": {"source": f"{CC} :: BASE_STATS (normalized names)", "values": {"cavalry": {"attack": 14.0, "defense": 6.0, "range": 1}, "infantry": {"attack": 10.0, "defense": 10.0, "range": 1}, "archer": {"attack": 12.0, "defense": 4.0, "range": 3}, "spear": {"attack": 8.0, "defense": 14.0, "range": 1}, "scout": {"attack": 2.0, "defense": 3.0, "range": 1}, "siege": {"attack": 18.0, "defense": 2.0, "range": 2}, "conscript": {"attack": 5.0, "defense": 5.0, "range": 1}, "hq": {"attack": 8.0, "defense": 12.0, "range": 1}}},
    "matchup_table": {"source": f"{CC} :: MATCHUP_TABLE", "values": {"cavalry_vs_archer": 1.35, "archer_vs_spear": 1.35, "spear_vs_cavalry": 1.40, "infantry_vs_archer": 1.20, "infantry_vs_cavalry": 0.85, "infantry_vs_spear": 0.85, "conscript_vs_regular": 0.60, "scout_vs_regular": 0.55}},
    "march_multipliers": {"source": f"{CFG} :: MARCH_MULTIPLIERS / limit functions", "values": {"blue": 1.0, "red": 2.0, "black": 2.2}},
    "march_morale_penalty": {"source": f"{CFG} :: MORALE_PENALTY", "values": {"GREEN": 0.0, "ORANGE": 5.0, "RED": 15.0}, "profile_gate": "morale_rout_enabled"},
    "combat_constants": {"source": f"{CC} :: damage/retaliation formula literals", "values": {"defender_denom_m": 4.2, "defender_denom_b": 80.0, "ratio_min": 0.04, "ratio_max": 0.60, "counter_denom_m": 5.5, "counter_denom_b": 110.0, "counter_ratio_min": 0.02, "counter_ratio_max": 0.40, "wall_damage_mult": 12.0, "siege_wall_mult": 2.5, "field_fort_default_hp": 180}},
    "fog_vision": {"source": f"{FOG} :: normal_vision / scout_vision", "values": {"normal": 2, "scout": 4}, "note": "scout value is provisional/configurable in source"},
    "rout_rally": {"source": f"{S6} :: ROUT_*/RALLY_*", "values": {"morale_line": 20.0, "base_p": 0.25, "scale": 0.02, "hungry_p": 0.10, "cap": 0.80, "rally_min_turns": 2, "rally_near_hq": 6, "rally_base_p": 0.50}, "profile_gate": "morale_rout_enabled"},
    "fatigue": {"source": f"{S6} :: FATIGUE_*", "values": {"green": 4.0, "orange": 18.0, "red": 32.0, "exhausted": 60.0}},
    "strongholds": {"source": f"{UM} :: DEFAULT_* consts", "values": {"fortress_hexes": 3, "fortress_slots": 4, "fortress_hp": 1000, "capital_hexes": 3, "capital_slots": 6, "capital_hp": 1500}},
}

ALGORITHMIC_RULES = {
    "dijkstra_envelope": {
        "source": f"{PF} :: calculate_envelope",
        "semantics": "array-scan priority queue; neighbor order = axial DIRECTIONS; relax strict tent_g < existing_g - 0.0001; policy filter applied AFTER classification; occupied/destination checks use player-known occupancy; origin exempt from blocking",
        "parity_note": "port the relaxation epsilon (-0.0001), the neighbor order, and the classify-then-filter sequence literally",
    },
    "march_classification": {
        "source": f"{CFG} :: classify_march_by_cumulative_cost",
        "semantics": "river forces RED; else GREEN if spent <= blue+0.001; ORANGE if spent <= red+0.001; else RED; policy filter (is_policy_allowed) applied to the classified tier",
        "parity_note": "the +0.001 tolerances are load-bearing; keep them",
    },
    "combat_resolution": {
        "source": f"{CC} :: calculate_combat",
        "semantics": "exact formula order: raw force -> matchup -> morale modifier -> strategic -> variance -> relative-power scale clamp(eff_dealer/max(eff_victim,0.001),0,1) -> clamp ratio (4.2/80, 0.04*scale..0.60) -> max(percent roundi casualties, absolute finish min(troops,roundi(eff*0.60))) (Godot roundi = half away from zero) -> retaliation only at distance 1 with counter constants (5.5/110, 0.02*scale..0.40), finish min(troops,roundi(eff*0.40)), and unguarded zeroing -> casualty clamp [.., troops]",
        "parity_note": "Godot roundi() rounds half away from zero; Python round() is banker's rounding — use decimal/exact half-up emulation for .5 cases",
    },
    "sequential_occupancy": {
        "source": f"{UM} :: execute_move / execute_player_stepwise_move",
        "semantics": "one unit per hex; erase old key then set new key after validation; stepwise stop-before-contact for hidden enemies; MP charged only for traversed hexes",
        "parity_note": "mutation order matters: erase-then-set on validated destination; contact stop returns partial success",
    },
    "turn_cycle": {
        "source": f"{UM} :: end_turn + {SIM} :: sim_end_turn",
        "semantics": "BLUE phase resolves unit-by-unit (stable id order) -> end_turn resets per-unit budgets/locks -> Step6 charges -> begin_player_turn -> fog recompute; RED phase then BLUE...",
        "parity_note": "Step6 end_turn_charges precede the manager end_turn in the headless path",
    },
    "visibility_propagation": {
        "source": f"{FOG} :: recompute / _has_los / _hex_line",
        "semantics": "per friendly observer: disk of radius (2 or 4) gated by hex LOS ray trace; routed/garrisoned observers excluded; objective hexes auto-explored; recompute only on discrete changes",
        "parity_note": "LOS: intermediate mountain blocks; intermediate forest blocks beyond distance >= 3; cube_round tie-breaking must match (larger-diff axis adjusted)",
    },
    "contact_lifecycle": {
        "source": f"{FOG} :: recompute stale block",
        "semantics": "visible->hidden freezes the last record (never updated while hidden); rediscovery supersedes; destroyed enemies purge stale markers; first-discovery edge detectable",
        "parity_note": "freezing uses the OBSERVED record, never current truth",
    },
    "rout_rally_flow": {
        "source": f"{S6D} :: _rout_and_rally / _rally_or_flee / seeded_roll",
        "semantics": "hash-keyed deterministic roll per (unit:turn:purpose); routed flee/rally transitions; command-loss fog notes",
        "parity_note": "Godot hash() is a specific 32-bit string hash; for parity, either reimplement Godot's hash or pin the algorithm as part of the contract (see UNRESOLVED_CONTRACT_GAPS)",
    },
    "mission_evaluation": {
        "source": f"{SIM} :: evaluate_mission / evaluate_battle",
        "semantics": "defeat-first order: defeat on battle lost / BLUE HQ dead (if fielded at start) / blue annihilated; victory on RED HQ dead (if fielded at start, all objectives) else per objective contract; expired on turn_limit; terminal freezes mutation/reviews/turns",
        "parity_note": "evaluation is explicit and ordered; do not short-circuit differently",
    },
    "mission_geometry": {
        "source": f"{NOTION} :: Shared resolution order step 4 (declared mission target/anchor)",
        "semantics": "resolve the declared mission target/anchor/envelope (advance anchor, withdraw anchor, reserve/regroup envelope, screen corridor, shadow band, flank bands, waypoints) from the General mission context; never infer an anchor from the battlefield when the contract requires a declared one; stability comes from designation priority then canonical geometry",
        "parity_note": "anchors are mission facts, not WorldTruth inferences; sub-primitives (anchor, corridor, flank_bands, pursue_target, reserve_envelope, waypoint, shadow_band, regroup_envelope, withdraw_anchor) refine this family",
    },
    "observation_safe_masking": {
        "source": "Notion: Observation-safe six-skill legality mask",
        "semantics": "mask from actor state + authorized knowledge only; engine rechecks at execution",
        "parity_note": "simulator computes the mask from FactionKnowledge, never WorldTruth",
    },
}

# ---------------------------------------------------------------------------
# Scenario profiles: configuration overlays on ONE ruleset
# ---------------------------------------------------------------------------
SCENARIO_PROFILES = {
    "DEV_FLAT_ALL_INFO": {
        "notion_name": "DEV_FLAT_FULL_INFO",
        "purpose": "First integration / behavior validation",
        "terrain_effects": False,
        "obstacles_strongholds": False,
        "fog_stale_contacts": False,
        "morale_rout_fatigue": False,
        "ambush": False,
        "roster": "10v10 default (SandboxRules.default_roster)",
        "notes": "Maps 1:1 to SandboxRules.invariants() when SANDBOX_ACTIVE=true (terrain/fog/stale/morale OFF, full information ON).",
    },
    "TERRAIN_FULL_INFO": {
        "notion_name": "TERRAIN_ONLY",
        "purpose": "Terrain-sensitive tactical behavior",
        "terrain_effects": True,
        "obstacles_strongholds": True,
        "fog_stale_contacts": False,
        "morale_rout_fatigue": False,
        "ambush": False,
    },
    "FLAT_FOG": {
        "notion_name": "FOG_ONLY",
        "purpose": "Partial-information behavior",
        "terrain_effects": False,
        "obstacles_strongholds": False,
        "fog_stale_contacts": True,
        "morale_rout_fatigue": False,
        "ambush": True,
    },
    "TERRAIN_FOG": {
        "notion_name": "TERRAIN_FOG",
        "purpose": "Combined spatial + epistemic behavior",
        "terrain_effects": True,
        "obstacles_strongholds": True,
        "fog_stale_contacts": True,
        "morale_rout_fatigue": False,
        "ambush": True,
    },
    "MORALE_COMBAT": {
        "notion_name": "MORALE_COMBAT",
        "purpose": "Behavior under cohesion / rout pressure",
        "terrain_effects": True,
        "obstacles_strongholds": True,
        "fog_stale_contacts": True,
        "morale_rout_fatigue": True,
        "ambush": True,
        "notes": "Includes rout/rally/fatigue; production morale constants are frozen in source; suppression lifted.",
    },
    "FULL_PRODUCTION": {
        "notion_name": "FULL_PRODUCTION",
        "purpose": "Final tactical-domain evaluation",
        "terrain_effects": True,
        "obstacles_strongholds": True,
        "fog_stale_contacts": True,
        "morale_rout_fatigue": True,
        "ambush": True,
        "notes": "All contract-frozen tactical mechanics enabled; no speculative systems.",
    },
}

# ---------------------------------------------------------------------------
# 30-skill dependency matrix (skill -> required rule primitives)
# Primitives reference ALGORITHMIC_RULES/DATA_CONFIGURABLE_RULES keys or
# rule ids in RULES. This maps what the simulator must have before each skill
# can execute. NO executor implementation is authorized by this table.
# ---------------------------------------------------------------------------
SKILL_DEPENDENCIES = {
    "Infantry.ATTACK": ["combat_resolution", "base_stats", "matchup_table", "retaliation", "knowledge_ledger.visibility_enumeration", "observation_safe_masking"],
    "Infantry.ADVANCE": ["dijkstra_envelope", "terrain_costs_standard", "march_classification", "sequential_occupancy", "mission_geometry.anchor"],
    "Infantry.HOLD": ["turn_cycle.resolve_confirmation"],
    "Infantry.REPOSITION": ["dijkstra_envelope", "terrain_costs_standard", "sequential_occupancy", "mission_geometry.anchor"],
    "Infantry.SUPPORT": ["dijkstra_envelope", "sequential_occupancy", "mission_geometry.anchor", "actor_ordering.nearest_ally_tiebreak"],
    "Infantry.WITHDRAW": ["dijkstra_envelope", "terrain_costs_standard", "sequential_occupancy", "mission_geometry.withdraw_anchor"],
    "Spearman.ATTACK": ["combat_resolution", "base_stats", "matchup_table", "retaliation", "knowledge_ledger.visibility_enumeration", "observation_safe_masking"],
    "Spearman.ADVANCE": ["dijkstra_envelope", "terrain_costs_standard", "march_classification", "sequential_occupancy", "mission_geometry.anchor"],
    "Spearman.HOLD": ["turn_cycle.resolve_confirmation"],
    "Spearman.REPOSITION": ["dijkstra_envelope", "terrain_costs_standard", "sequential_occupancy", "mission_geometry.anchor"],
    "Spearman.SCREEN": ["dijkstra_envelope", "sequential_occupancy", "mission_geometry.corridor", "knowledge_ledger.threat_vector"],
    "Spearman.WITHDRAW": ["dijkstra_envelope", "terrain_costs_standard", "sequential_occupancy", "mission_geometry.withdraw_anchor"],
    "Cavalry.ATTACK": ["combat_resolution", "base_stats", "matchup_table", "retaliation", "cavalry_continuation", "knowledge_ledger.visibility_enumeration", "observation_safe_masking"],
    "Cavalry.FLANK": ["dijkstra_envelope", "terrain_costs_standard", "sequential_occupancy", "knowledge_ledger.visibility_enumeration", "mission_geometry.flank_bands"],
    "Cavalry.ADVANCE": ["dijkstra_envelope", "terrain_costs_standard", "march_classification", "sequential_occupancy", "mission_geometry.anchor"],
    "Cavalry.PURSUE": ["dijkstra_envelope", "sequential_occupancy", "knowledge_ledger.visibility_enumeration", "mission_geometry.pursue_target"],
    "Cavalry.RESERVE": ["dijkstra_envelope", "sequential_occupancy", "mission_geometry.reserve_envelope"],
    "Cavalry.WITHDRAW": ["dijkstra_envelope", "terrain_costs_standard", "sequential_occupancy", "mission_geometry.withdraw_anchor"],
    "Archer.FIRE": ["combat_resolution", "base_stats", "matchup_table", "knowledge_ledger.visibility_enumeration", "los_blockers", "observation_safe_masking"],
    "Archer.FOCUS_FIRE": ["combat_resolution", "base_stats", "los_blockers", "knowledge_ledger.focus_marker"],
    "Archer.REPOSITION_RANGE": ["dijkstra_envelope", "sequential_occupancy", "base_stats.range_envelope", "los_blockers"],
    "Archer.KITE": ["dijkstra_envelope", "sequential_occupancy", "base_stats.range_envelope", "knowledge_ledger.visibility_enumeration"],
    "Archer.HOLD_POSITION": ["turn_cycle.resolve_confirmation"],
    "Archer.WITHDRAW": ["dijkstra_envelope", "terrain_costs_standard", "sequential_occupancy", "mission_geometry.withdraw_anchor"],
    "Scout.RECON_ADVANCE": ["dijkstra_envelope", "terrain_costs_scout", "march_classification", "sequential_occupancy", "visibility_propagation.recon_candidates", "mission_geometry.waypoint"],
    "Scout.SHADOW": ["dijkstra_envelope", "terrain_costs_scout", "knowledge_ledger.visibility_enumeration", "mission_geometry.shadow_band"],
    "Scout.HARASS": ["combat_resolution.harass_effect", "knowledge_ledger.visibility_enumeration", "los_blockers"],
    "Scout.SCREEN": ["dijkstra_envelope", "terrain_costs_scout", "sequential_occupancy", "mission_geometry.corridor"],
    "Scout.EVADE": ["dijkstra_envelope", "terrain_costs_scout", "sequential_occupancy", "knowledge_ledger.threat_vector"],
    "Scout.REGROUP": ["dijkstra_envelope", "terrain_costs_scout", "sequential_occupancy", "mission_geometry.regroup_envelope"],
}

# ---------------------------------------------------------------------------
# Unresolved contract gaps (FROZEN-CONTRACT-INCOMPLETE — do NOT invent)
# ---------------------------------------------------------------------------
UNRESOLVED_CONTRACT_GAPS = [
    {
        "id": "terrain_defense_wiring",
        "rule": "combat.terrain_defense_bonus",
        "missing": "TerrainMods.DEFENSE_BONUS multipliers exist but are not applied inside CombatCalculator.calculate_combat; the production wiring point (eff_def multiplier? casualties reduction? preview-only?) is not frozen.",
        "resolution": "requires an explicit production decision before MORALE_COMBAT/FULL_PRODUCTION simulation",
    },
    {
        "id": "archer_range_bonus_wiring",
        "rule": "combat.archer_range_bonus",
        "missing": "ARCHER_RANGE_BONUS (mountains/fortress +1) not applied in execute_attack range checks; whether production keeps it and at which check point is not frozen.",
        "resolution": "requires production decision; DEV profile unaffected",
    },
    {
        "id": "scout_vision_provisional",
        "rule": "fog.vision_radii",
        "missing": "scout_vision=4 is marked provisional/configurable in source; normal_vision=2 likewise a bare default, not a review-frozen constant.",
        "resolution": "pin both values (or a tuning table) in the observation/ruleset review",
    },
    {
        "id": "godot_hash_parity",
        "rule": "rout_rally_flow / fog strength bands",
        "missing": "seeded_roll and estimate_band key on Godot's built-in hash(); the 32-bit hash function itself is implementation-defined for parity purposes.",
        "resolution": "either reimplement Godot's hash() in the simulator or freeze a substitute PRNG-derived key derivation in the contract",
    },
    {
        "id": "stale_memory_horizon",
        "rule": "observation normalization",
        "missing": "Godot freezes stale snapshots indefinitely until rediscovery/destruction; the observation contract clips contact age at CONTACT_MEMORY_HORIZON=10. Whether production ever expires (drops) stale contacts by age is not frozen.",
        "resolution": "freeze a no-expiry rule (current behavior) or an explicit expiry rule before training data generation",
    },
    {
        "id": "cohesion_rule",
        "rule": "morale.cohesion",
        "missing": "no numeric cohesion rule exists in code or Notion; only the placeholder that it MAY exist when contract-frozen.",
        "resolution": "excluded from simulation until a production contract exists",
    },
]

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
def _rules_block() -> list[dict]:
    return [
        {"family": r["family"], "id": r["id"], "status": r["status"],
         "summary": r["summary"], "source": r["source"]}
        for r in RULES
    ]


def to_manifest() -> dict:
    return {
        "contract": "RulesetV0",
        "ruleset_version": RULESET_VERSION,
        "ruleset_revision": RULESET_REVISION,
        "observation_schema_dependency": "obs-v0 (see ObservationLayoutV0 manifest)",
        "classification_counts": _classification_counts(),
        "rules": _rules_block(),
        "data_configurable_rules": DATA_CONFIGURABLE_RULES,
        "algorithmic_rules": ALGORITHMIC_RULES,
        "scenario_profiles": SCENARIO_PROFILES,
        "skill_dependencies": SKILL_DEPENDENCIES,
        "unresolved_contract_gaps": UNRESOLVED_CONTRACT_GAPS,
        "worldtruth_boundary": {
            "world_truth": "authoritative state owned by the engine (unit manager, hex grid, fog storage)",
            "faction_knowledge": "per-side projection (own forces complete, visible enemies, frozen stale contacts)",
            "jev_observation": "typed tensors defined by ObservationLayoutV0; no hidden-truth field",
            "mask_rule": "observation-safe mask from FactionKnowledge; engine rechecks at execution",
        },
        "parity_risks_verified": {
            "rounding": "Godot roundi() is half-away-from-zero; Python round() is banker's rounding. Combat uses roundi on fractional casualties — parity layer must emulate half-away-from-zero. VERIFIED in CC.calculate_combat + UM.execute_attack.",
            "occupancy_mutation_order": "erase old key then set new key after all validation gates (UM.execute_move). VERIFIED.",
            "dijkstra_epsilon": "strict relaxation with -0.0001 epsilon and policy filter after classification (PF.calculate_envelope). VERIFIED.",
            "retaliation_gating": "melee-only (distance==1), zero when defender unguarded (CC §7). VERIFIED.",
            "cavalry_continuation": "cavalry keeps the action after attacking; others end it and zero MP (UM.execute_attack). VERIFIED.",
            "policy_asymmetry": "player default RED_ALLOWED; production RED AI marches with GREEN_ONLY (UM._current_policy init vs SIM.do_move). VERIFIED — historic 'BLUE auto RED_ALLOWED vs RED GREEN_ONLY' hypothesis confirmed with corrected attribution.",
            "float_epsilon_literals": "0.0001 (Dijkstra relax), 0.001 (march/budget tolerances). VERIFIED in PF + CFG.",
        },
        "randomness_contract": {
            "combat": "deterministic (variance=1.0; no randf/randi on battle path)",
            "rout_rally_bands": "stateless hash-keyed rolls: abs(hash(key))%1000/1000",
            "outside_battle": "campaign/AI-flavor/UI RNG exists but is EXCLUDED from the tactical domain",
            "parity_requirement": "no RNG-state parity needed; hash-function parity is tracked as gap godot_hash_parity",
        },
    }


def _classification_counts() -> dict[str, int]:
    counts: dict[str, int] = {}
    for r in RULES:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    return counts


MANIFEST = to_manifest()


def content_hash() -> str:
    payload = json.dumps(MANIFEST, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


__all__ = [
    "ACTIVE", "ALGORITHMIC_RULES", "DATA_CONFIGURABLE_RULES", "DEFERRED", "DEAD",
    "DEV_PROFILE_INACTIVE", "EXCLUDED", "FROZEN_FOR_PRODUCTION", "MANIFEST",
    "RULES", "RULESET_REVISION", "RULESET_VERSION", "SCENARIO_PROFILES",
    "SKILL_DEPENDENCIES", "UNRESOLVED_CONTRACT_GAPS", "content_hash", "to_manifest",
]
