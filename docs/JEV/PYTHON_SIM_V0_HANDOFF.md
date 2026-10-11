# PYTHON SIM V0 — Implementation Handoff Report

Date: 2026-09-19
Task: RulesetV0-faithful Python tactical simulator core (cold start, additive package)
Authoritative sources: RulesetV0 contract (`python_jev/contracts/ruleset.py`),
ObservationLayoutV0 (`python_jev/contracts/observation_layout.py`, `hex_patch.py`),
live Godot scripts (cited per rule), and an unmodified Godot 4.2.2 headless run
of `scripts/sim/sim_entry.gd` used as the exported cross-runtime parity anchor.

---

## STATUS

**PASS (with cross-runtime parity evidence)** — S0-1 … S0-23 all pass; S0-24 scope
clean. The canonical probe scenario reproduces the exported Godot headless
fingerprint **byte-for-byte** at t=1 (spawn) and t=2 (post move→attack→end turn)
under FULL_PRODUCTION — see P17. Remaining contract gaps are pre-existing and
documented, not simulator defects.

## PROJECT ROOT

D:\Game development\Demon slayer\StrategyGame

## SIMULATOR

version: python_sim_v0.1.0 (`python_sim.SIM_VERSION`)
ruleset: ruleset-v0.1.0 (sha256 42f975cc1a646682…, loaded from contract, not hardcoded)
observation schema: observation-layout-v0.1.0, schema obs-v0 rev 1 (sha256 6e13f0c1caac8cd0…)

## IMPLEMENTED

Additive package `python_sim/` (no Godot gameplay file touched):

- `rules/geometry.py` — pure-axial port: HexUtils.DIRECTIONS order (E,NE,NW,W,SW,SE),
  axial distance, radius-40 boundary = 4,921 cells, outer-ring mountains to radius 85.
- `rules/rounding.py` — Godot numeric parity helpers: `roundi_gd` half-away-from-zero
  (never Python banker's rounding at casualty/fog-band sites), clampf/clampi/max/min ports.
- `rules/march.py` — tiers 1.0/2.0/2.2×, +0.001 tolerances, river→RED, policies
  GREEN_ONLY/ORANGE_ALLOWED/RED_ALLOWED, march morale penalties, Step6 fatigue per class.
- `rules/movement.py` — Dijkstra envelope literal port: array-scan PQ with first-index
  tie-breaking, strict −0.0001 relax, classify→policy-filter ordering, player-known
  occupancy blocking (origin exempt), destination-occupied drop, stronghold-footprint
  avoidance, `find_route` with rejection reasons. Plains probe: 16-cell green ring
  (17 minus occupied hex; its behind-ring neighbor detours at 3.0 → ORANGE).
- `rules/combat.py` — BASE_STATS/MATCHUP_TABLE (reciprocal 1/x), damage ratio
  clamp(0.04,0.60) over (eff_def·4.2+80), retaliation clamp(0.02,0.40) over
  (eff·5.5+110) melee-only, UNGUARDED zeroing, fortress ×12 hard shield + siege ×2.5,
  field-fortification Model B, min-1 casualty clamp, `roundi` casualties,
  morale shock (loss_prop·35+3/+2) gated exactly like SandboxRules.
- `rules/terrain.py` — Step3Config cost tables (standard + scout specials), impassable
  8/9/10, ambush terrain (forest/swamp). Terrain defense & archer range bonus NOT wired
  (contract gaps).
- `rules/turn.py` — evaluate_mission decision core (objectives, turn limit, HQ rule).
- `state/unit_state.py`, `state/world_state.py` — authoritative mutable-but-copied state
  with cheap clone (static terrain shared), `state_version` mutation counter, and the
  Godot-identical fingerprint (lowercase bools, strongholds in REGISTRATION order).
- `state/faction_knowledge.py` — Step5FogOfWar port: vision 2 / scout 4 (provisional),
  LOS blockers (mountain always; forest blocks targets at distance ≥ 3), frozen
  stale-contact snapshots on visible→hidden, rediscovery supersede, combat-assessed
  strength bands, no expiry (gap stale_memory_horizon respected).
- `sim/executor.py` — stepwise mutation authority: validate→remove occupancy→set
  occupancy→consume traversed MP→contact reveal; hidden-contact movement stop; attack
  intents; cavalry post-attack continuation (keeps action, MP intact); death cleanup;
  end-turn reset.
- `sim/battle.py` — headless episode controller: profile overlays on ONE ruleset,
  canonical action seam (do_move/do_attack/do_hold/do_rest/do_fortify/sim_end_turn),
  fog recompute timing (refresh after every mutating action + turn begin), mission
  evaluation, trajectory hashing, cheap battle clone.
- `observation/projector.py` — ObservationLayoutV0 projector: imports the canonical
  contract (no duplicated schema constants), actor-relative 91-hex patch via the frozen
  index map, FRIEND/VISIBLE_ENEMY/STALE_CONTACT tokens within capacity 24, deterministic
  non-tactical id-order overflow with explicit bit, unknown/known-bit/NA/padding
  semantics, observation-safe legality mask, frozen normalizations.
- `policies/` — smoke policies only (RandomLegalPolicy seedable, SimpleAttackElseAdvance,
  Hold). No utility-AI reproduction, no training policy.
- `parity/fixtures.py` — P01–P16 matrix + 10v10 fingerprint + P17 cross-runtime anchor;
  `run_verification.py` — consolidated runner.

## SCENARIO PROFILES

DEV_FLAT_ALL_INFO:      PASS  (sandbox contract: flat terrain, no obstacles, full info, morale off)
TERRAIN_FULL_INFO:      PASS  (terrain costs + scout specials + strongholds active)
FLAT_FOG:               PASS  (fog/stale contacts + ambush, flat ground)
TERRAIN_FOG:            PASS  (both constituent systems complete)
MORALE_COMBAT:          PASS with DEGRADED flag (terrain-defense & archer-range wiring gaps)
FULL_PRODUCTION:        PASS with DEGRADED flag (same gaps); used for the cross-runtime anchor
All profiles are configuration overlays on the single simulator; no profile changes the
meaning of an enabled rule.

## PARITY

P01 geometry_boundary:            PASS
P02 movement_budget:              PASS
P03 dijkstra_destinations:        PASS
P04 march_tiers:                  PASS
P05 occupancy_mutation:           PASS
P06 hidden_contact_stop:          PASS
P07 attack_legality:              PASS
P08 matchup_damage:               PASS (cav→archer 20; reciprocal 1/1.35 exact)
P09 casualty_rounding:            PASS (roundi half-away-from-zero; even battle 16)
P10 retaliation:                  PASS (melee-only, UNGUARDED zero, ranged none)
P11 cavalry_continuation:         PASS
P12 death_cleanup:                PASS
P13 phase_reset:                  PASS
P14 mission_terminal:             PASS
P15 visibility_los:               PASS (mountain block; forest ≥ distance 3)
P16 stale_contact_rediscovery:    PASS (freeze at last-seen; no expiry; rediscovery supersedes)
P17 cross_runtime_godot_probe:    PASS — byte-identical fingerprints vs exported Godot headless run
S0-20 battle_10v10_fingerprint:   PASS (seed-stable Python fingerprint; cross-runtime 10v10
                                  export is future work — Godot gates are probe-scoped)

## OBSERVATION

ObservationLayoutV0: projector output constructs ObservationBatchV0 and passes JevPolicyV0
  forward (S0-14, S0-21) with zero schema adaptation.
Anti-leakage: divergent hidden WorldTruth with identical FactionKnowledge produces
  byte-equal observation vectors (S0-15).
Overflow: >24 known entities → deterministic non-tactical id-order truncation + explicit
  overflow bit in global features (S0-16).

## DETERMINISM

Same scenario + same deterministic policy → identical trajectory hash across runs
(S0-18); battle fingerprint is seed-provenance-only on the canonical path. The canonical
combat path is variance-free; no Python RNG exists anywhere in sim mechanics.

## PERFORMANCE

full 10v10 episode: 12 turns / 240 decisions / 179.7 ms wall (66.8 turns/s, 1335.9 decisions/s)
episode slice (5 turns, 10v10): 94.9 ms — 52.7 turns/s, 1054.2 decisions/s
state clone cost: 0.21–0.23 ms per battle clone (static terrain shared, copy-on-write style)
CPU-only; no NumPy/PyTorch in sim mechanics. Optimization not attempted (correctness first).

## TESTS

python -m python_sim.run_verification → OVERALL PASS
- S0 gate suite: 29 passed (S0-1 … S0-23; includes cross-runtime S0-20)
- parity matrix: 18/18 PASS (P01–P17 + 10v10)
- profile matrix: 6 profiles exercised, MORALE_COMBAT/FULL_PRODUCTION honestly flagged DEGRADED
Full regression: python_jev N0 (34) + R0 (36) + python_sim S0 (29) = 99 passed.

## CONTRACT GAPS (pre-existing, respected — no values invented)

1. terrain_defense_wiring      — TerrainMods defense not consumed by calculate_combat (not wired)
2. archer_range_bonus_wiring   — +1 archer range data present, not wired into range checks
3. scout_vision_provisional    — vision 2/4 are source defaults, not review-frozen
4. godot_hash_parity           — Godot hash()-keyed stateless rolls not reproduced; isolated
5. stale_memory_horizon        — no production expiry; age-10 clipping is normalization only
6. cohesion_rule               — no numeric rule exists; not simulated

## MISMATCHES FOUND AND CLASSIFIED

- Mode discovery (CONTRACT_BUG → resolved by source trace): the headless `-s` boot never
  activates SandboxRules (only the battlefield shell sets the flag), so the canonical
  headless path runs PRODUCTION semantics (morale shock + fatigue), not DEV. The probe
  fingerprint's mor 93.333 / 91.350 and fat 4.000 are therefore production-mode truths.
- PYTHON_BUG (fixed): fingerprint bool formatting (`True/False` → GDScript `true/false`)
  and stronghold ordering (sorted → registration order, matching Godot Dictionary iteration).
- Fixture expectation errors (fixed in tests, not in sim code): scout vision-4 contact at
  init, axial (+1,+1) = distance 2 (not ring-1), RED_ALLOWED mountain reachability,
  forest LOS blocks targets at distance ≥ 3, P02/P08/P12/P14 fixture setups.
- No unresolved Python↔Godot mismatch remains: every numeric field of the canonical probe
  fingerprint matches byte-for-byte.

## CHANGED FILES (this task — all additive)

D:\Game development\Demon slayer\StrategyGame\python_sim\__init__.py
D:\Game development\Demon slayer\StrategyGame\python_sim\run_verification.py
D:\Game development\Demon slayer\StrategyGame\python_sim\rules\__init__.py
D:\Game development\Demon slayer\StrategyGame\python_sim\rules\rounding.py
D:\Game development\Demon slayer\StrategyGame\python_sim\rules\geometry.py
D:\Game development\Demon slayer\StrategyGame\python_sim\rules\march.py
D:\Game development\Demon slayer\StrategyGame\python_sim\rules\terrain.py
D:\Game development\Demon slayer\StrategyGame\python_sim\rules\movement.py
D:\Game development\Demon slayer\StrategyGame\python_sim\rules\combat.py
D:\Game development\Demon slayer\StrategyGame\python_sim\rules\turn.py
D:\Game development\Demon slayer\StrategyGame\python_sim\state\__init__.py
D:\Game development\Demon slayer\StrategyGame\python_sim\state\unit_state.py
D:\Game development\Demon slayer\StrategyGame\python_sim\state\world_state.py
D:\Game development\Demon slayer\StrategyGame\python_sim\state\faction_knowledge.py
D:\Game development\Demon slayer\StrategyGame\python_sim\sim\__init__.py
D:\Game development\Demon slayer\StrategyGame\python_sim\sim\executor.py
D:\Game development\Demon slayer\StrategyGame\python_sim\sim\battle.py
D:\Game development\Demon slayer\StrategyGame\python_sim\observation\__init__.py
D:\Game development\Demon slayer\StrategyGame\python_sim\observation\projector.py
D:\Game development\Demon slayer\StrategyGame\python_sim\policies\__init__.py
D:\Game development\Demon slayer\StrategyGame\python_sim\parity\__init__.py
D:\Game development\Demon slayer\StrategyGame\python_sim\parity\fixtures.py
D:\Game development\Demon slayer\StrategyGame\python_sim\tests\__init__.py
D:\Game development\Demon slayer\StrategyGame\python_sim\tests\test_s0_gates.py

Scope audit (git, vs pre-task baseline): the only untracked additions attributable to this
workstream are `StrategyGame/python_jev/`, `StrategyGame/python_sim/`, and `StrategyGame/docs/JEV/`
(plus the earlier `docs/JEV_NETWORK_V0_HANDOFF.md`). The 244 pre-existing dirty files are
untouched. `StrategyGame/evidence/cloud2_general_forensic/` appeared externally between
sessions and was not touched by this task.

## SCOPE CHECK

JEV training: NOT STARTED
Dataset generation: NOT STARTED
Counterfactual Q generation: NOT STARTED
Self-play training: NOT STARTED
Godot gameplay rewrite: NO (Godot ran read-only, unmodified, for the parity anchor)

JevPolicyV0 was instantiated once on a projector output purely as an interface smoke test
(S0-21); weights remain untrained; no optimizer, no loss, no training loop exists in this task.

## HANDOFF

D:\Game development\Demon slayer\StrategyGame\docs\JEV\PYTHON_SIM_V0_HANDOFF.md

## NEXT

Single next task: dataset/rollout pipeline — wire the 30 skill executors onto the simulator
primitives (RulesetV0 dependency matrix), then generate replay trajectories with
JevPolicyV0 actions + counterfactual rollouts under the frozen contracts.
