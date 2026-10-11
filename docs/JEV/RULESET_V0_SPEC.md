# RulesetV0 & ObservationLayoutV0 — Engineering Specification

Status: **FROZEN CONTRACT (rev 1)** · Date: 2026-09-19
Machine-readable authority: `python_jev/contracts/` (hashes below)
Neural consumer: `python_jev/model.py` (JevPolicyV0, unchanged)
Notion authority: *Research Branch — System-1 Tactical Neural Model / Jev-inspired*
(retrieved 2026-09-19T04:33Z; unchanged since the network handoff)

---

## 1. Purpose and precedence

This document freezes the two contracts the future Python tactical simulator
must reproduce **without guessing**:

- **ObservationLayoutV0** — the byte-level observation contract the Godot
  projector and the Python simulator must both emit.
- **RulesetV0** — the classified inventory of live tactical mechanics, split
  into data-configurable constants and algorithmic semantics, with parity
  rules, scenario-profile overlays, and the 30-skill dependency matrix.

Source precedence used during the audit (per task order):
1. Current Notion frozen contracts (unchanged since retrieval).
2. Current authoritative Godot gameplay code (live symbols cited per rule).
3. JevPolicyV0 implementation (`python_jev/`).
4. Historical docs — context only; nothing here overrides live code.

---

## 2. ObservationLayoutV0

**Version:** `observation-layout-v0.1.0` on schema `obs-v0` (revision 1)
**Content hash (SHA-256, canonical JSON):** `6e13f0c1caac8cd0…`
(full hash from `python_jev.contracts.observation_layout.content_hash()`)

### 2.1 Feature groups and field order

Field order is owned by the `(name, width)` tables in
`python_jev/layout.py` and mirrored machine-readably in
`python_jev/contracts/observation_layout.py` (`feature_groups` block).
Dimensions: actor 67, token 37, hex cell 33, mission 46, global 31, legal mask 6.
Every group has a computed offset map; order cannot drift between the two
manifests (enforced by `test_r0_3_manifest_dims_match_implementation`).

### 2.2 Vocabularies (index = one-hot slot; reorder requires schema bump)

| vocabulary | frozen order |
|---|---|
| unit_class | INFANTRY, SPEARMAN, CAVALRY, ARCHER, SCOUT |
| relation_kind | FRIENDLY, ENEMY_VISIBLE, STALE_CONTACT, PAD |
| knowledge_state | VISIBLE, REMEMBERED, UNEXPLORED |
| occupancy | EMPTY, FRIENDLY, ENEMY_VISIBLE, STALE_MARKER, UNKNOWN |
| terrain | PLAINS, FOREST, MOUNTAIN, WATER, ROAD, UNKNOWN |
| readiness | READY, ACTED, UNKNOWN |
| rout_state | NONE, AT_RISK, ROUTING, UNKNOWN, NA |
| stance | NONE, HOLD, SCREEN, RESERVE, OTHER, UNKNOWN, NA |
| blocking | PASSABLE, BLOCKED, UNKNOWN |
| mission_role | PRIMARY, SUPPORT, RESERVE, SCREEN, RECON, UNKNOWN, NA |
| mission_type | SEEK_BATTLE, HOLD_GROUND, CAPTURE, DEFEND, RECON, UNKNOWN |
| objective_type | ENEMY_ARMY, ENEMY_HQ, HEX_OBJECTIVE, SURVIVE, UNKNOWN |
| objective_status | UNDONE, IN_PROGRESS, ACHIEVED, FAILED, UNKNOWN |
| mission_phase | EARLY, MID, LATE, UNKNOWN, NA |
| battle_phase | MOVEMENT, COMBAT, UNKNOWN, NA |
| objective_possession | OURS, ENEMY, CONTESTED, UNKNOWN, NA |
| engagement_policy | FREE_ENGAGEMENT, PROBE_ONLY, HOLD_FIRE, UNKNOWN, NA |
| doctrine scalars | aggression, caution, cohesion_preservation, initiative, attrition_tolerance, objective_priority |

Terrain buckets fold Godot's 14-entry `HexCell.TerrainType` (authoritative
enum cited in the manifest): SWAMP/FORTRESS/VILLAGE fold into their cost-class
buckets; WALL + stronghold/capital interiors fold into UNKNOWN with blocking=BLOCKED.
The Godot-aligned fold table is machine-readable in the manifest
(`TERRAIN_VOCAB_GODOT_ALIGNED`). Non-learned Godot classes (siege, conscript,
hq, supply) appearing in world truth are encoded with class=UNKNOWN +
class_known=0; they are never silently mapped onto a learned class slot.

### 2.3 Unknown / NA / stale / absent / padding semantics

Frozen in `ENCODING_SEMANTICS` and unchanged from the network handoff:

- numeric unknown → fill 0.0 + known=0 (a real zero always has known=1)
- categorical unknown → dedicated UNKNOWN bucket; NA has its own bucket/bit
- stale → last retained fact with known=1 + stale bit + age; never rewritten
- absent → no token emitted (variable-N); padding → capacity-filler slots with
  `token_padding_mask=1` and the PAD relation bucket; padding is never an observation
- the five mask families stay separate: field-known, stale, NA, padding, legality

### 2.4 Normalization (frozen constants, never batch/profile statistics)

| family | rule |
|---|---|
| strength | soldier_count / max_count, clip [0,1], known bit preserved |
| movement | remaining/base_mp; spent/blue_limit; capacity 1.0 |
| distance | hex distance / 5 (PATCH_RADIUS); offsets / 5; direction buckets |
| terrain cost | cost / 3.0 (MAX_TRAVERSAL_COST = Step3Config max non-impassable); impassable uses blocking vocab |
| contact age | turns / 10.0 (CONTACT_MEMORY_HORIZON), clipped |
| counts | / 16 friendly, / 16 enemy-visible, / 8 stale, with overflow bits |
| turn progress | turn / mission turn_limit when known, else known=0 |

### 2.5 TOKEN_CAPACITY decision — **24 confirmed, quantitatively**

- Production scenario shells deploy **up to 16 formations per side**
  (step2r shells; `SandboxRules.default_roster()` DEV default is 10/side).
- Stale-contact ledger reference is **8** (`STALE_CONTACT_COUNT_REF`).
- Friendlies and currently-visible enemies share ONE token buffer under the
  relation field, so the buffer must cover friendly + visible-enemy + stale
  worst case. 24 covers the canonical deployment envelope (16 + 8); a
  worst-case 16v16 engagement with a full stale ledger can exceed 24 and then
  hits the **frozen overflow rule**: a deterministic, non-tactical truncation
  policy plus the explicit overflow bit already present in the global summary
  group — never a hidden-truth-driven truncation (Notion: Variable-N handling).
- Keeping a hard, reviewable bound (rather than an unbounded buffer) preserves
  the frozen variable-N semantics with stable memory/attention cost; raising it
  later is a schema revision with a version bump, never a silent change.

### 2.6 91-hex local patch index map — frozen ordering

Rule (frozen in `python_jev/contracts/hex_patch.py`):

- **Ring-major**: index 0 = actor's own cell (0,0); ring k = 1..5 enumerates
  all cells at hex distance k before ring k+1.
- Ring k starts at **(-k, +k)** (the SW-ray far end; Red Blob's canonical ring
  start) and walks the six sides in Godot `HexUtils.DIRECTIONS` order —
  E, NE, NW, W, SW, SE — k steps per side, appending each cell before stepping.

Properties verified by `test_r0_4_*`: 91 unique indices; distance values
non-decreasing by index; ring sizes 1,6,12,18,24,30; `offset_to_index(dq,dr)`
is a pure total function on the patch; outside-radius lookups fail loudly.
Slot index therefore **carries spatial meaning**; the full manifest
(`index_map` = 91 × [index, dq, dr]) is embedded in the ObservationLayoutV0
manifest and hash-pinned.

**Permutation principle:** unit/contact token slot index carries NO semantic
meaning (variable-N sets, permutation-invariant pooling). Hex patch slot index
carries frozen spatial identity. Both statements are machine-readable in the
manifest (`permutation_principle`).

---

## 3. RulesetV0

**Version:** `ruleset-v0.1.0` (revision 1)
**Content hash (SHA-256):** `82fc7db8ea976939…`
(`python_jev.contracts.ruleset.content_hash()`; hex-patch manifest hash
`f7683ebc501bc989…` is embedded and separately pinned)

### 3.1 Classification summary (68 rules)

| status | count | meaning |
|---|---|---|
| ACTIVE | 51 | implemented and authoritative in current game rules |
| FROZEN_FOR_PRODUCTION | 2 | observation-safe legality + WorldTruth execution semantics (Notion-frozen, projector-side duty) |
| DEV_PROFILE_INACTIVE | 8 | implemented, fingerprinted, but disabled by the DEV sandbox (morale modifier, march penalty, morale shock, rout/rally, fatigue, morale value, terrain defense bonus, archer range bonus) |
| DEFERRED | 1 | cohesion (no numeric rule exists anywhere) |
| EXCLUDED | 3 | supply/food (retired globally SUP-FINAL), campaign layer, out-of-battle RNG |
| DEAD | 3 | `morale_system.gd` legacy curve, `battle_map.gd`/`movement_calculator.gd` superseded combat/movement, pixel-rounding (presentation only) |

Every entry cites live symbols, e.g.:
`scripts/core/step3_config.gd :: TERRAIN_COSTS_STANDARD`,
`scripts/combat/combat_calculator.gd :: calculate_combat §7`,
`scripts/step3/step3_unit_manager.gd :: execute_player_stepwise_move (line 1902)`,
`scripts/step5/fog_of_war.gd :: recompute stale freeze block`,
`scripts/sim/sim_controller.gd :: evaluate_mission (line 688)`.
No numeric rule in the manifest lacks a citation (R0-1/R0-2).

### 3.2 Data vs algorithm split (R0-10)

**DATA-CONFIGURABLE** (`DATA_CONFIGURABLE_RULES`, values inline + cited):
class base movement (cav 3.0, inf 2.0, arch 2.0, spear 2.0, scout 4.0, …),
standard terrain costs (road 0.5 … mountains 3.0), scout terrain specials,
BASE_STATS (attack/defense/range), MATCHUP_TABLE (1.35/1.40/1.20/0.85/0.60/0.55),
march multipliers (1.0/2.0/2.2), march morale penalties (0/5/15, gated),
combat constants (4.2/80 & 5.5/110 denominators, 0.04–0.60 & 0.02–0.40 clamps,
wall ×12, siege ×2.5, field fort 180 HP), fog vision (2 / 4),
rout/rally constants, fatigue constants, stronghold definitions.

**ALGORITHMIC** (`ALGORITHMIC_RULES`, semantics + parity notes, port literally):
Dijkstra envelope (array-scan PQ, axial neighbor order, −0.0001 relaxation
epsilon, classify-then-filter), march classification (+0.001 tolerances, river
forces RED), combat resolution (exact formula order, `roundi` = half-away-from-zero),
sequential occupancy (erase-then-set, stepwise contact stop), turn cycle
(Step6 charges → manager end_turn → begin_player_turn → fog recompute),
visibility propagation (LOS ray trace: mountain blocks, intermediate forest
blocks ≥ distance 3), contact lifecycle (freeze-never-update-while-hidden),
rout/rally flow (hash-keyed rolls), mission evaluation,
mission-geometry anchors, observation-safe masking.

### 3.3 Verified parity rules (historical hypotheses re-checked against live source)

| risk | verdict (current source) |
|---|---|
| roundi vs banker's rounding | CONFIRMED relevant: `CombatCalculator` uses `roundi()` (half away from zero) on fractional casualty products; Python `round()` is banker's — the parity layer must emulate half-away-from-zero |
| occupancy mutation order | CONFIRMED: validate → erase old key → set new key (UM.execute_move); stepwise contact stop for hidden enemies (UM.execute_player_stepwise_move) |
| Dijkstra cost + policy filter | CONFIRMED with precision: relax `tent_g < existing_g - 0.0001`, classification **then** policy filter (PF.calculate_envelope) |
| melee retaliation + unguarded gating | CONFIRMED: retaliation only at distance==1; UNGUARDED defender deals zero reciprocal (CC §7) |
| cavalry action continuation | CONFIRMED: cavalry keeps `action_ended=false` after attacking; all others end and zero MP (UM.execute_attack) |
| BLUE auto RED_ALLOWED vs RED GREEN_ONLY | CONFIRMED with corrected attribution: player-side default policy is RED_ALLOWED (UM `_current_policy` init; shell UI buttons), production RED AI marches GREEN_ONLY (SIM.do_move + shell ~2413) |
| float epsilon literals | CONFIRMED: 0.0001 (Dijkstra), 0.001 (march/budget tolerances) |

### 3.4 Randomness contract

- Combat on the canonical path is **deterministic**: `execute_attack` runs at
  `variance=1.0`; no `randf/randi` on the battle path (asserted by
  `sim_entry.gd :: _g4_seed_report`, gate `gate4_seed_differentiation`).
- Stochastic morale rules use a stateless hash roll:
  `seeded_roll(key) = abs(hash(key)) % 1000 / 1000` (Step6DecisionLayer).
- Campaign/AI-flavor/UI RNG exists but is EXCLUDED from the tactical domain.
- **No RNG-state parity is required.** Godot `hash()` function parity is the
  open item tracked as gap `godot_hash_parity`.

### 3.5 Scenario profiles — overlays on ONE ruleset (R0-12)

| profile | terrain | obstacles | fog/stale | morale/rout/fatigue | ambush |
|---|---|---|---|---|---|
| DEV_FLAT_ALL_INFO (Notion: DEV_FLAT_FULL_INFO) | OFF | OFF | OFF | OFF | OFF |
| TERRAIN_FULL_INFO (TERRAIN_ONLY) | ON | ON | OFF | OFF | OFF |
| FLAT_FOG (FOG_ONLY) | OFF | OFF | ON | OFF | ON |
| TERRAIN_FOG | ON | ON | ON | OFF | ON |
| MORALE_COMBAT | ON | ON | ON | ON | ON |
| FULL_PRODUCTION | ON | ON | ON | ON | ON |

No profile changes the meaning of an enabled rule; toggles map 1:1 to
`SandboxRules` gates (DEV profile note cites `SandboxRules.invariants()`).

### 3.6 30-skill dependency matrix (R0-11)

All 30 frozen skills are mapped to required primitives in
`SKILL_DEPENDENCIES` (verified complete against the frozen six-slot tables:
30/30, PASS). Examples of the pattern:

- `Cavalry.FLANK` → dijkstra_envelope, terrain_costs_standard,
  sequential_occupancy, knowledge_ledger.visibility_enumeration,
  mission_geometry.flank_bands
- `Archer.FIRE` → combat_resolution, base_stats, matchup_table,
  knowledge_ledger.visibility_enumeration, los_blockers, observation_safe_masking
- `Scout.RECON_ADVANCE` → dijkstra_envelope, terrain_costs_scout,
  march_classification, sequential_occupancy,
  visibility_propagation.recon_candidates, mission_geometry.waypoint

Every dependency resolves to a declared primitive (data, algorithmic, or rule
id) — enforced by `test_r0_11_dependencies_reference_known_primitives`.

---

## 4. Unresolved contract gaps (do NOT invent; each needs a production decision)

1. **terrain_defense_wiring** — `TerrainMods.DEFENSE_BONUS` (1.5 mountain /
   1.3 forest / 1.2 swamp / 2.0 fortress / 1.1 village) is NOT applied inside
   `CombatCalculator.calculate_combat`; the production wiring point is unfrozen.
2. **archer_range_bonus_wiring** — mountains/fortress +1 archer range exists in
   `TerrainMods` but is not applied in `execute_attack` range checks.
3. **scout_vision_provisional** — `normal_vision=2`, `scout_vision=4` are bare
   (provisional) defaults, not review-frozen constants.
4. **godot_hash_parity** — `seeded_roll`/`estimate_band` key on Godot's
   implementation-defined `hash()`; simulator must reimplement it or the
   contract must pin a substitute key derivation.
5. **stale_memory_horizon** — Godot freezes stale contacts indefinitely until
   rediscovery/destruction; observation clips age at 10 turns. Whether
   production ever expires stale contacts by age is not frozen (current
   behavior = no expiry; the clip is a normalization bound only).
6. **cohesion_rule** — no numeric cohesion rule exists in code or Notion;
   excluded until a production contract exists.

---

## 5. Acceptance gates (R0)

| gate | result |
|---|---|
| R0-1 SOURCE TRACE | PASS — every rule cites path :: symbol (or Notion paragraph) |
| R0-2 NO SPECULATION | PASS — unverifiable mechanics recorded as gaps, not invented |
| R0-3 OBSERVATION MANIFEST | PASS — machine-readable, JSON-serializable, complete |
| R0-4 91-HEX ORDER | PASS — 91 unique indices, ring-major, distance-sorted, pure lookup |
| R0-5 UNIT PERMUTATION | PASS — principle frozen in manifest; N0-5 still green |
| R0-6 UNKNOWN SEMANTICS | PASS — unknown/NA/stale/absent/padding/known-zero distinct |
| R0-7 WORLDTRUTH BOUNDARY | PASS — WorldTruth/FactionKnowledge/JevObservation documented in both manifests |
| R0-8 MASK SAFETY | PASS — observation-safe legality (FROZEN_FOR_PRODUCTION) vs engine recheck separated |
| R0-9 RULE CLASSIFICATION | PASS — 68 rules, every rule exactly one status |
| R0-10 DATA/CODE SPLIT | PASS — disjoint sets, values cited, parity notes present |
| R0-11 SKILL DEPENDENCIES | PASS — 30/30 skills mapped, all deps resolve |
| R0-12 PROFILE CONTRACT | PASS — 6 overlays, flag-only, no rule redefinition |
| R0-13 VERSION HASH | PASS — three deterministic SHA-256 content hashes |
| R0-14 JEV REGRESSION | PASS — 34/34 N0 tests green after layout freeze (no layout change required) |
| R0-15 SCOPE | PASS — contracts/docs only; simulator/training not started; Godot untouched |

Test suites: `python_jev/tests/test_r0_contracts.py` (36) +
`python_jev/tests/test_n0_gates.py` (34) = **70 passed**.

---

## 6. Deliverable map

| artifact | path |
|---|---|
| ObservationLayoutV0 manifest | `python_jev/contracts/observation_layout.py` |
| Hex patch index map | `python_jev/contracts/hex_patch.py` |
| RulesetV0 manifest | `python_jev/contracts/ruleset.py` |
| Contracts package init | `python_jev/contracts/__init__.py` |
| R0 gate tests | `python_jev/tests/test_r0_contracts.py` |
| This specification | `docs/JEV/RULESET_V0_SPEC.md` |
| Handoff report | `docs/JEV/RULESET_V0_HANDOFF.md` |
| (unchanged) neural implementation | `python_jev/layout.py`, `python_jev/model.py`, … |

## 7. Next implementation step

Implement the Python tactical simulator core **in dependency order**:
hex geometry + world boundary → unit state → Dijkstra envelope + march
classification → sequential occupancy (execute_move/stepwise) → combat
resolution (+ retaliation, cavalry continuation) → turn cycle → fog +
contact lifecycle → knowledge projector emitting ObservationLayoutV0 tensors.
Resolve gaps 1–3 (terrain wiring decisions) with the game designer before
enabling MORALE_COMBAT / FULL_PRODUCTION; gaps 4–6 can be pinned
contract-first without blocking DEV/TERRAIN/FOG profiles.
