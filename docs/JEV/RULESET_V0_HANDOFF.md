# RulesetV0 — Handoff Report

Date: 2026-09-19 · Task: freeze ObservationLayoutV0 + RulesetV0 contracts (no simulator)

## STATUS

**PASS** — all applicable R0 gates pass (R0-1 … R0-15); 70/70 tests green
(36 R0 contract tests + 34 pre-existing N0 network tests, regression intact).

## AUTHORITATIVE SOURCES INSPECTED

1. **Notion** (via connector, re-fetched this task): *Research Branch —
   System-1 Tactical Neural Model / Jev-inspired* — page unchanged
   (last edited 2026-09-19T04:33Z; identical content to the network-task fetch).
   Authoritative for: six-skill tables, executor contracts, production domain,
   observation schema freeze, profiles, anti-leak invariants.
2. **Current Godot source** (live symbols, cited per rule in the manifest):
   - Geometry/boundary: `scripts/core/hex_utils.gd`, `scripts/core/hex_cell.gd`,
     `scripts/step2r/step2r_world_boundary.gd` (radius-40 / 4,921 cells)
   - Movement: `scripts/core/step3_config.gd`, `scripts/step3/step3_pathfinding.gd`,
     `scripts/step3/step3_unit_manager.gd` (execute_move / execute_player_stepwise_move /
     execute_attack / end_turn / is_unit_data_turn_resolved / get_player_known_occupied)
   - Combat/terrain/morale: `scripts/combat/combat_calculator.gd`,
     `scripts/combat/terrain_mods.gd`, `scripts/combat/morale_system.gd`
   - Turns/phases: `scripts/core/turn_manager.gd`, `scripts/core/sandbox_rules.gd`
   - Fog/knowledge: `scripts/step5/fog_of_war.gd`,
     `scripts/step7/step7_observation_projector.gd`, `scripts/step7/step7_world_truth.gd`
   - Morale/rout layer: `scripts/step6/step6_config.gd`,
     `scripts/step6/step6_decision_layer.gd` (seeded_roll, rout/rally)
   - Headless authority: `scripts/sim/sim_controller.gd`,
     `scripts/sim/sim_rules_fingerprint.gd`, `scripts/sim/sim_entry.gd`
3. **JEV implementation**: `python_jev/` (network handoff), incl.
   `docs/JEV_NETWORK_V0_HANDOFF.md`.

Traceability notes: file names from the task brief were treated as hypotheses;
live reference tracing confirmed the authoritative owners (e.g. fog lives in
`scripts/step5/fog_of_war.gd`, not a step7 file; the sim controller wires the
same authorities as the live shell — its header documents the verified call
equivalence). `step7_blue_knowledge_service.gd` is a 10-line forwarder to the
projector; `sim_rules_fingerprint.gd` already fingerprints the live tables the
manifest cites.

## OBSERVATION CONTRACT DECISIONS

- **version:** `observation-layout-v0.1.0` on `obs-v0` schema **revision 1**
- **hash:** SHA-256 `6e13f0c1caac8cd0…` (full: `content_hash()` in
  `python_jev/contracts/observation_layout.py`; embedded in the manifest)
- Field orders: unchanged from `python_jev/layout.py` (dims 67/37/33/46/31/6);
  now mirrored machine-readably with computed offsets in both places
  (drift-proof, test-enforced).
- Vocabularies frozen with Godot-aligned fold tables (14-entry HexCell enum →
  6-bucket obs terrain; non-learned classes → UNKNOWN + known=0, never remapped).
- Encoding semantics frozen: numeric unknown = fill 0.0 + known=0; categorical
  UNKNOWN/NA buckets; stale = retained fact + age; absent = no token;
  padding = mask=1 + PAD bucket; five mask families separate.
- Normalization table frozen with cited constants (cost/3.0, age/10.0,
  counts/16-16-8, distance/5, strength/max_count, movement/base_mp).
- **token capacity:** 24 **confirmed** with quantitative reasoning: 16
  friendly (production shells deploy ≤16/side; DEV roster default 10) + 8
  stale slots; visible enemies share the buffer (one relation field); worst
  case beyond 24 hits the frozen overflow rule (deterministic non-tactical
  truncation + explicit overflow bit), raising the bound is a versioned schema
  revision. Not silently inherited — audited and documented.
- **hex patch:** radius 5 / 91 cells confirmed; slot order frozen as
  ring-major, ring k starting at (-k,+k), six sides walked in Godot
  HexUtils.DIRECTIONS order; full [index, dq, dr] manifest embedded and
  hash-pinned; `offset_to_index` is a pure lookup; index 0 = actor cell.

## RULESET CONTRACT DECISIONS

- **version:** `ruleset-v0.1.0`; **hash:** SHA-256 `82fc7db8ea976939…`
- 68 rules classified with per-rule live-source citations; every number traced
  to a symbol (`path :: symbol`) or a frozen Notion paragraph — nothing invented.

## MECHANICS (classification outcome)

- **ACTIVE (51):** axial geometry & cube distance; radius-40 playable boundary;
  Dijkstra envelope (−0.0001 relax); march tiers GREEN/ORANGE/RED (1.0/2.0/2.2×,
  +0.001 tolerance) with river→RED; policy ceiling filter (GREEN_ONLY /
  ORANGE_ALLOWED / RED_ALLOWED); terrain costs incl. scout specials; player-known
  occupancy blocking; stepwise hidden-contact stop; fortified movement lock;
  BASE_STATS; MATCHUP_TABLE incl. reciprocal rule; damage formula (4.2/80,
  0.04–0.60); melee-only retaliation (5.5/110, 0.02–0.40) with UNGUARDED zeroing;
  march→GUARD/UNGUARDED mapping; fortress wall shield (×12, siege ×2.5);
  field fortification (180 HP, Model B); ambush opening strike; cavalry attack
  continuation; death cleanup; one-attack-per-turn lock; turn cycle
  (BLUE→RED, Step6 charges → end_turn → begin_player_turn → fog recompute);
  RECON/DEPLOY/ENGAGE/RESOLVE phases; end-turn reset semantics; stable-id actor
  ordering; mission evaluation (4 objectives, defeat/expired rules); terrain enum;
  impassability (wall/stronghold interiors); river crossing; LOS blockers
  (mountain; forest ≥ distance 3); ambush terrain; vision radii (2 / scout 4);
  fog tri-state (UNEXPLORED/EXPLORED/VISIBLE); contact lifecycle (freeze-while-
  hidden, rediscovery, destroy-purge); hash-banded strength estimates;
  command-loss memory; faction knowledge ledgers; HQ unit + defeat rule;
  strongholds (Fortress 1000 HP / Capital 1500 HP, garrisons, breach);
  objective markers auto-explored; deterministic combat path; hash-keyed rolls.
- **FROZEN_FOR_PRODUCTION (2):** observation-safe legality masking; WorldTruth
  execution resolution (Notion executor invariants I3–I5).
- **DEV_PROFILE_INACTIVE (8):** morale value, morale combat modifier
  (0.40+0.60×m/100), march morale penalties (0/5/15), casualty morale shock,
  rout/rally (line 20, p 0.25+0.02·Δ, cap 0.80; rally ≥2 turns, p 0.50),
  fatigue (4/18/32, exhausted 60), terrain defense bonus (not wired into
  combat), archer range bonus (not wired into attack range).
- **DEFERRED (1):** cohesion (no numeric rule exists).
- **EXCLUDED (3):** supply/food (retired globally, SUP-FINAL — always-false
  gates in `sandbox_rules.gd`), campaign/diplomacy/dialogue layer, out-of-battle
  RNG (campaign director, AI flavor, UI preview).
- **DEAD (3):** `scripts/combat/morale_system.gd` legacy curve (not on the
  canonical path), `scripts/core/battle_map.gd` + `scripts/combat/movement_calculator.gd`
  superseded combat/movement (legacy scene entry only), pixel↔hex rounding
  (presentation only).

## KEY PARITY RULES (verified against current source, not copied from history)

1. **Rounding:** Godot `roundi()` = half away from zero; Python `round()` =
   banker's. Casualty products use `roundi` — the simulator must emulate
   half-away-from-zero (verified: `combat_calculator.gd`, unit manager).
2. **Dijkstra:** array-scan PQ, axial neighbor order, strict relax with −0.0001
   epsilon, march classification THEN policy filter.
3. **Occupancy mutation:** validate → erase old key → set new key; stepwise
   move stops before the first occupied hex (hidden contact), charges MP only
   for traversed hexes, returns partial success.
4. **Tolerances:** +0.001 in march/budget classification, −0.0001 in Dijkstra —
   both load-bearing.
5. **Retaliation:** melee-only (distance==1); UNGUARDED defender deals zero.
6. **Cavalry continuation:** cavalry keeps the action after attacking.
7. **Policy asymmetry:** player default RED_ALLOWED; production RED AI
   GREEN_ONLY (corrected attribution vs the historical hypothesis).
8. **RNG:** battle path deterministic (variance=1.0); morale stochasticity uses
   stateless `abs(hash(key))%1000/1000`; no RNG-state parity needed.

## 30-SKILL DEPENDENCY AUDIT

**PASS** — 30/30 skills mapped in `SKILL_DEPENDENCIES`; every dependency
resolves to a declared primitive (data-configurable, algorithmic, or rule id),
enforced by test. This is a dependency map only — no executor implementation.

## TESTS

- New: `python_jev/tests/test_r0_contracts.py` — 36 tests covering R0-3 …
  R0-14 executable assertions (manifest structure + JSON serializability,
  dims-match-implementation, vocabularies, normalization citations, 91-hex
  uniqueness/order/ring-sizes/roundtrip/parity, permutation principle,
  encoding semantics, mask families, boundary, mask safety, per-rule citation
  integrity, classification coverage, data/code split with rounding-rule callout,
  30/30 dependency resolution, six overlay profiles, DEV/FULL toggle checks,
  hash stability, TOKEN_CAPACITY rationale, JEV public-API intactness, and a
  subprocess run of the full N0 suite).
- Regression: `python_jev/tests/test_n0_gates.py` — 34/34 green.
- Combined: **70 passed** (`python -m pytest python_jev/tests/`).

## CHANGED FILES (all additive)

- `D:\Game development\Demon slayer\StrategyGame\python_jev\contracts\__init__.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\contracts\observation_layout.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\contracts\hex_patch.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\contracts\ruleset.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\tests\test_r0_contracts.py`
- `D:\Game development\Demon slayer\StrategyGame\docs\JEV\RULESET_V0_SPEC.md`
- `D:\Game development\Demon slayer\StrategyGame\docs\JEV\RULESET_V0_HANDOFF.md` (this report)

`python_jev/layout.py` was audited but **not modified**: all constants survived
the audit (cost 3.0, horizon 10.0, refs 16/16/8, capacity 24, radius 5/91);
the freeze therefore required zero schema changes and N0-14/N0-2 remain valid
without re-tuning the model. Git audit: the only delta vs. the pre-task
baseline (246 dirty entries, preserved untouched) is the seven new files above.

## SCOPE CHECK

Simulator: NOT STARTED · Training: NOT STARTED · Dataset generation:
NOT STARTED · Godot gameplay rewrite: NO (no `.gd`/`.tscn` touched; Godot
executable not invoked)

## UNRESOLVED CONTRACT GAPS

(recorded machine-readably in `UNRESOLVED_CONTRACT_GAPS`; detail in the spec §4)
1. `terrain_defense_wiring` — TerrainMods defense multipliers not wired into
   `calculate_combat`; production wiring point unfrozen (blocks
   MORALE_COMBAT/FULL_PRODUCTION fidelity, not DEV).
2. `archer_range_bonus_wiring` — +1 range (mountains/fortress) not applied in
   attack-range checks.
3. `scout_vision_provisional` — vision 2/4 are provisional source defaults.
4. `godot_hash_parity` — Godot `hash()` parity for hash-keyed rolls/bands.
5. `stale_memory_horizon` — production has no stale-contact expiry; observation
   clips age at 10; whether expiry should exist is unfrozen.
6. `cohesion_rule` — no rule exists anywhere; excluded until contract-frozen.

## HANDOFF

`D:\Game development\Demon slayer\StrategyGame\docs\JEV\RULESET_V0_HANDOFF.md`
(this file) · Specification: `docs/JEV/RULESET_V0_SPEC.md` ·
Contracts: `python_jev/contracts/`

## NEXT

Single next implementation task: **Python tactical simulator core (RulesetV0-faithful)**
in dependency order — hex geometry/boundary → unit state → Dijkstra envelope +
march classification → sequential occupancy → combat resolution (retaliation,
cavalry continuation) → turn cycle → fog + contact lifecycle →
ObservationLayoutV0 projector — with the parity layer (half-away-from-zero
rounding, epsilon literals, mutation order) ported literally and gap decisions
1–3 obtained from the game designer before enabling morale/terrain-combat profiles.
