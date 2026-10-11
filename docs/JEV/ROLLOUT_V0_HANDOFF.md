# ROLLOUT_V0 HANDOFF — 30 Skill Executors + Counterfactual Six-Skill Rollout Engine

**Status: PASS (scalar Q blocked by design — see §7 VALUE TARGET)**
**Date: 2026-09-19**
**Scope compliance: no JevPolicyV0 training, no optimizer, no self-play, no production-scale dataset, no Fog oracle labels, no Godot gameplay changes.**

---

## 1. What this task delivered

Three additive packages between the Jev six-way choice and the Python simulator:

```
Jev 6-way tactical choice
        ↓  python_sim.skills      (30 frozen deterministic executors)
deterministic skill execution
        ↓  python_sim.sim         (existing authoritative primitives — unchanged)
Python simulator state transition

frozen decision state + current actor
        ↓  python_sim.rollout     (six-branch counterfactual engine)
        ↓  python_sim.trajectory  (replayable decision records)
raw outcome vectors  (+ scalar Q BLOCKED — no frozen ValueTargetV0 contract)
        ↓  python_jev.dataset     (schema + pilot generator with fog guard)
```

Nothing existing was redesigned. The simulator, observation projector contract,
ruleset, and network packages are untouched except for **two verified bug fixes**
listed in §9 (both pre-existing, both caught by the new J1 test surface).

---

## 2. Package map

| Path | Contents |
|---|---|
| `python_sim/skills/contracts.py` | Version pins, `FailureCode` enum, canonical envelope builders (`success`/`failure`), `CanonicalModes`, `content_hash()` |
| `python_sim/skills/result.py` | Typed `SkillResult` view over the canonical envelope dict |
| `python_sim/skills/context.py` | `MissionContext` (declared anchors) + knowledge-safe anchor resolvers (advance/reposition/withdraw/reserve/regroup/recon-waypoint) |
| `python_sim/skills/common.py` | Target/destination enumeration, `destination_by_anchor` (frozen Notion tie-break chain), `execute_stepwise`, contact classification, `observation_safe_skill_mask` re-export site |
| `python_sim/skills/movement.py` | `commit_destination` (PARTIAL/INTERRUPTED hidden-contact contract), `commit_attack` |
| `python_sim/skills/{infantry,spearman,cavalry,archer,scout}.py` | The 30 executors, six per class module |
| `python_sim/skills/registry.py` | `(class, slot) -> executor` registry, `execute_skill`, `iter_skill_names` |
| `python_sim/rollout/config.py` | `RolloutConfig` (versioned), continuation policies `RandomLegalPolicy` / `SimpleAttackElseAdvancePolicy` / `HoldPolicy` |
| `python_sim/rollout/outcome.py` | Raw outcome vector (10 frozen components), versioned |
| `python_sim/rollout/value_target.py` | Scalar-Q guard: `q_export_status`, `ValueTargetBlocked`, `compute_scalar_q` (hard-blocked) |
| `python_sim/rollout/engine.py` | `CounterfactualEngine`, `state_hash`, `SixWayEvaluation` |
| `python_sim/trajectory/recorder.py` | `TrajectoryRecorder`, `replay_trajectory` |
| `python_jev/dataset/schema.py` | `PilotRecordV0` validation, `assert_no_fog_oracle_labels`, JSONL I/O |
| `python_jev/dataset/pilot_generator.py` | 3 pilot scenarios × 2 full-info profiles × 5 classes, version-pinned records |
| `python_sim/tests/test_j1_skills.py` | 55 tests: 30 success + 14 failure fixtures + interaction/fog A/B tests |
| `python_sim/tests/test_j1_gates.py` | 18 tests: J1-9 … J1-22 |
| `artifacts/j1_pilot_dataset.jsonl` | 20-record pilot dataset (regenerable, deterministic) |

---

## 3. PART A — 30 skill executors

- **Contract source:** canonical Notion page, section *MVP Deterministic Skill
  Executor Contracts — Architecture-Only Freeze (30 Skills)*, shared invariants
  I1–I14, canonical result envelope, shared resolution order.
- **Implemented: 30/30.** Tables verified against `python_jev.constants.ACTION_SPACE`
  (frozen six-skill tables) by `test_j1_2_thirty_identities_pinned`.
- **Contract version:** `skill-contract-e0e6-v0.1.1`
  (v0.1.1 = tie-break chain corrected to the exact Notion chain, §9.1).
- **Envelope fields:** status (`SUCCESS | PARTIAL | INVALID | INTERRUPTED | MASKED`),
  skill_class/slot/name (echoed unchanged, I1), actor_id,
  state_version_before/after, failure_code, target_id, destination, path,
  movement_spent, damage/casualty effects, newly_revealed_contact,
  terminal transition, tie_break_trace, partial-contact detail. No prose, no
  chain-of-thought anywhere in the envelope.
- **Failure codes (versioned `failure-codes-v0.1.0`):** NO_TARGET, OUT_OF_RANGE,
  NO_ANCHOR, NO_DESTINATION, NO_SUPPORT_TARGET, NO_SCREEN_ANCHOR, NO_FLANK_TARGET,
  NO_PURSUIT_TARGET, NO_SHADOW_TARGET, NO_EVADE_THREAT, NO_WITHDRAW_ROUTE,
  NO_REGROUP_ANCHOR, NO_RESERVE_ANCHOR, NO_FOCUS_TARGET, NO_KITE_THREAT,
  TARGET_NOT_ELIGIBLE, PRECONDITION_FAILED, STALE_STATE, ENGINE_REJECTED,
  MASKED_ILLEGAL, NONE.
- **Determinism (I6/I7):** target chain = mission designation → weakest →
  nearest → stable ID. Destination chain (anchor-directed skills) = greatest
  anchor-distance reduction → shortest path → forward projection → stable axial
  order — exactly the Notion wording (see §9.1 for the v0.1.1 correction).
  Every success result carries the `tie_break_trace` actually used.
- **Knowledge boundary (I4):** all target/destination candidate sets come from
  `FactionKnowledge` (visible enemies, stale contacts, explored frontier) or
  declared mission anchors. Anchors are never invented from WorldTruth —
  missing declared anchors fail with the specific NO_*_ANCHOR code.
- **Hidden contact (I5, mask rule):** movement legality is knowledge-safe; a
  hidden enemy on the committed path interrupts the move with
  `status=PARTIAL, partial.reason=HIDDEN_CONTACT, partial.newly_revealed_contact=<id>`
  and no pre-leak. The mask never turns a bit off because of hidden WorldTruth.

---

## 4. PART B — counterfactual rollout engine

`CounterfactualEngine.evaluate(battle, actor_id, ctx)`:

- clones the frozen decision state **once per slot** (fresh `Battle.clone()` per
  branch), hashes all six pre-execution clones for equivalence, executes the
  branch skill, then runs the bounded continuation.
- **Clone isolation (J1-10):** all six `initial_state_hash` values are equal and
  equal to the source state hash; the source battle is never mutated.
- **Masks (J1-11):** `legal_mask[6]` / `q_valid_mask[6]` from
  `observation_safe_skill_mask` (knowledge-safe only). Illegal slots are
  `MASKED` with `failure_code=MASKED_ILLEGAL`, empty outcome vector
  (`terminal_result="MASKED"`), and `outcome_scalar=None`. No fake values.
- **Horizon (J1-12):** `horizon_decisions` counts tactical actor decisions after
  the branch skill (blue and red each count), with a turn safety cap
  (`max_turns`), early exit on terminal mission state. Short (2–4) and medium
  (8–12) horizons exercised; horizon is versioned config, never hardcoded.
- **Continuation policies (versioned `continuation-policies-v0.1.0`):**
  `RandomLegalPolicy` (seeded), `SimpleAttackElseAdvancePolicy` (scripted,
  default), `HoldPolicy`. JevPolicyV0 is NOT a continuation policy (untrained).
  All three run through the engine; Q_random vs Q_scripted divergence can be
  inspected once scalar targets exist (raw vectors already differ and are
  recorded per policy).
- **Determinism (J1-18):** repeated evaluations (including seeded random
  continuation) produce byte-identical JSON. Pilot regeneration is byte-identical.

### Raw outcome vector (`raw-outcome-vector-v0.1.0`)
Frozen components, inspectable, no weights:
`enemy_casualties, friendly_casualties, objective_delta, mission_delta,
own_hq_alive, enemy_hq_alive, own_strength_ratio,
enemy_visible_strength_ratio, terminal_result, horizon_steps`.
Every legal branch records one; masked branches record the empty vector.

---

## 5. Trajectory recording

`TrajectoryRecorder.record_decision(actor, class, slot)` records: decision
index, turn, actor, legal mask, observation hash (from the authorized
projection only), the full execution envelope, pre/post state hash, and mission
state. `finalize()` adds the terminal state and trajectory hash.
`replay_trajectory(traj, scenario)` re-executes only the recorded
`(actor, class, slot)` sequence from a fresh battle — no policy, no randomness —
and verifies the final state hash (J1-17 PASS, deterministic across replays).

---

## 6. Pilot dataset (`pilot-dataset-v0.1.0`)

**Path:** `artifacts/j1_pilot_dataset.jsonl` — **20 records**, regenerable in
~0.8 s, byte-identical across runs.

- **Profiles:** `DEV_FLAT_ALL_INFO`, `TERRAIN_FULL_INFO` (full-information only).
- **Classes:** all five learned classes; **30/30 (class, slot) pairs** covered
  via the six-branch evaluations (20 distinct skill names because the frozen
  tables share names across classes — coverage unit is the pair, asserted in
  the gate test).
- **Scenarios:** `pilot_even_seek` (even forces, destroy_all_red),
  `pilot_hold_defend` (defend, outnumbered attackers),
  `pilot_mismatch_recon` (outnumbered blue, survive/recon) — force-ratio,
  mission, and position variety sized by verification needs only.
- **Each record pins:** dataset schema version, sim version, ruleset
  version/hash, observation-layout version/hash, hex-patch version/hash, skill
  contract version + modes hash, failure-code + modes versions, rollout-config
  version, continuation-policy version, outcome-vector version,
  value-target version, trajectory-format version, scenario id/seed, state
  hash, actor id/class, mission context, full ObservationLayoutV0 payload +
  payload hash, legal/q_valid masks, per-skill execution results + raw
  outcomes, q_export_status, continuation policy id, horizon,
  `full_information` boolean, `world_truth_in_payload=False`.
- **No hidden WorldTruth** in any payload. Debug WorldTruth fixtures exist only
  inside tests as clearly-marked non-training metadata.

---

## 7. VALUE TARGET — scalar Q is BLOCKED (valid PASS boundary)

- No frozen scalar tactical value weighting exists anywhere (Notion Phase 7
  says only "the exact reward is versioned and auditable"; no coefficient set
  is frozen in any contract or code). Per the task stop condition, **no
  weights were invented**.
- Therefore `VALUE_TARGET_CONTRACT_EXISTS=False`,
  `VALUE_TARGET_VERSION="value-target-v0.0.0-ABSENT"`, and
  `q_export_status(profile)` returns:
  - `BLOCKED_NO_VALUE_TARGET_CONTRACT` for every profile (all full-info ones),
  - `FORBIDDEN_PARTIAL_INFORMATION` for every fog profile, permanently.
- `compute_scalar_q` raises `ValueTargetBlocked` in every path;
  `BranchResult.outcome_scalar` and `record["q_values"]` are `None` everywhere
  and the schema validator + fog guard reject anything else.
- **Raw outcome vectors are fully exported** — a future `ValueTargetV0`
  contract can derive scalar targets from the existing dataset **without any
  re-simulation**.
- The flip point is documented in `value_target.py`: a future task sets
  `VALUE_TARGET_CONTRACT_EXISTS=True` together with the frozen coefficient
  implementation.

---

## 8. FOG SAFETY (labels never generated; skill layer fully tested)

- Fog profiles appear in tests only: skill execution under FLAT_FOG,
  knowledge lifecycle, mask anti-oracle equality, and the explicit A/B pair:
  - World A: no unit on the path; World B: infantry at (-21,0), outside every
    blue unit's vision (cavalry MP 4 > NORMAL_VISION 2 makes genuine
    beyond-vision contact possible).
  - Identical FactionKnowledge, identical observation, identical mask; the SAME
    ADVANCE skill yields `SUCCESS [-21,0]` in A and
    `PARTIAL/HIDDEN_CONTACT/R_INF_HID` in B. Correct: the neural input cannot
    differ before discovery.
- Fog oracle Q export is structurally impossible: guard in schema validator,
  guard in `q_export_status`, guard at record build time, plus the gate tests.
- J1-16c/J1-7-style tests clone the state, mutate hidden truth, and assert
  observation/mask byte-equality.

---

## 9. Bug fixes made to existing code (both verified, both contract-backed)

### 9.1 Destination tie-break chain (skills/common.py, v0.1.1)
The first implementation ranked destinations
`reduction-flag → march tier → cost → axial`. The frozen Notion chain for
anchor-directed movement is **"greatest objective-distance reduction, then
shortest path, then most forward projection on the declared vector, then stable
axial hex order"** — no march-tier term. The unfrozen deviation neuters ADVANCE
to one-step hops (cheapest GREEN step always wins) and broke the Fog A/B test.
Corrected to the exact frozen chain; trace updated to
`["anchor_distance_reduction", "shortest_path", "forward_projection",
"axial_order"]`; skill-contract version bumped to v0.1.1; pilot dataset
regenerated.

### 9.2 Observation projector hidden-occupancy leak (observation/projector.py)
Pre-existing S0-era bug: for a patch cell occupied by a **hidden** enemy, the
projector set occupancy to EMPTY *and downgraded the occupancy sub-vector to
UNKNOWN*. Two WorldTruths differing only by a hidden unit inside the radius-5
patch therefore produced **different observations** — presence leaked through
the "unknown" encoding (anti-leakage invariant 5: unknown must never become
negative evidence of absence; the patch is a factual local map where
"known empty" is the only EMPTY semantics). Fixed by emitting the canonical
EMPTY occupancy with no knowledge downgrade. Caught by the new A/B test; the
old S0-15 probe missed it because its divergent unit sat outside the patch.
No version change needed for projector constants (behavior now matches the
already-frozen observation contract; S0-14/S0-15 remain green).

---

## 10. VERIFICATION RESULTS

### Gate summary
| Gate | Result |
|---|---|
| J1-1 import | PASS |
| J1-2 all 30 skills | PASS (30/30 identities pinned to ACTION_SPACE) |
| J1-3 contract ownership | PASS (identity echo, no-substitution, no-mutation-on-failure) |
| J1-4 success fixtures | PASS (30 success fixtures) |
| J1-5 failure fixtures | PASS (14 failure fixtures with exact codes + no-mutation assert) |
| J1-6 deterministic tiebreak | PASS (stable across builds, trace equality) |
| J1-7 observation safety | PASS (mask equality under divergent hidden truth) |
| J1-8 hidden contact | PASS (PARTIAL + reveal, no pre-leak, mover never enters hidden hex) |
| J1-9 six-way branch | PASS |
| J1-10 clone isolation | PASS (six identical initial hashes; source unmutated) |
| J1-11 legal/Q mask | PASS (MASKED slots carry no values) |
| J1-12 multi-step | PASS (horizon 2/4/8/12 budget checks) |
| J1-13 raw outcome | PASS (all 10 components in every legal branch; all 3 policies) |
| J1-14 value target safety | PASS (guard raises everywhere; no scalar anywhere) |
| J1-15 full-info Q | PASS-with-report: no frozen ValueTargetV0 exists → scalar Q blocked for all profiles; raw vectors exported |
| J1-16 fog label guard | PASS (permanent FORBIDDEN + validator + build-time guard) |
| J1-17 trajectory replay | PASS (same final hash, twice) |
| J1-18 determinism | PASS (byte-identical evaluations and regeneration) |
| J1-19 pilot dataset | PASS (20 records, 30/30 (class,slot) pairs, schema-clean) |
| J1-20 versioning | PASS (every pin non-empty in every record) |
| J1-21 JEV forward | PASS (pilot observation → ObservationBatchV0 → JevPolicyV0 → raw_logits[1,6], no schema adaptation) |
| J1-22 performance | PASS (measured, below) |
| J1-23 regression | PASS (N0 + R0 + S0 + J1: **172 passed**) |
| J1-24 scope | PASS (no optimizer/training/self-play/fog labels/production scale — see §12) |

### Performance (CPU only, probe scenario, horizon 8)
| Profile | six-branch evaluation | rollouts/sec | decision states/sec | clone share |
|---|---|---|---|---|
| DEV_FLAT_ALL_INFO | ~54 ms | ~110 | ~18.5 | ~0.3% |
| TERRAIN_FULL_INFO | ~52 ms | ~114 | ~19.1 | ~0.3% |

Clone cost on this scenario is ~19 µs (the 0.21–0.23 ms figure from the
simulator handoff is for production-scale states); clone share of counterfactual
runtime is negligible — continuation simulation dominates. No optimization was
done or needed at pilot scale.

---

## 11. Known gaps carried forward (not resolved here, per task rule)

- `terrain_defense_wiring` — terrain defense bonuses not wired (RulesetV0 gap).
- `archer_range_bonus_wiring` — archer range bonus not wired (RulesetV0 gap).
- `scout_vision_provisional` — NORMAL_VISION=2 / SCOUT_VISION=4 are provisional.
- `godot_hash_parity` — no Godot executor exists for the 30 Jev skills (they
  are Jev-specific; verified against the frozen Notion contract + RulesetV0
  primitives instead of a pretended Godot parity target; underlying movement/
  combat primitives remain parity-proven P01–P17).
- `stale_memory_horizon` — contacts never expire (frozen current behavior).
- `cohesion_rule` — not frozen; not simulated.

`MORALE_COMBAT` / `FULL_PRODUCTION` profiles retain their
`degraded` metadata flag and are surfaced in records via
`profile_degraded` / `PARTIAL_INFO_PROFILES`.

---

## 12. SCOPE CHECK

- JevPolicyV0 training: **NOT STARTED**
- Optimizer: **NOT CREATED**
- Self-play: **NOT STARTED**
- Production-scale dataset: **NOT GENERATED** (20 engineering-validation records)
- Fog hidden-truth Q labels: **NOT GENERATED** (structurally impossible)
- Godot gameplay rewrite: **NO**

---

## 13. NEXT

**Freeze `ValueTargetV0`:** define the versioned coefficient set over the
already-exported raw outcome components (mission / force preservation / enemy
attrition / objective / terminal), then scalar Q[6] for full-information
profiles can be derived from the existing dataset without re-simulation, and
the `VALUE_TARGET_CONTRACT_EXISTS` flip point in
`python_sim/rollout/value_target.py` is the single change required.

---

*Generated by the ROLLOUT_V0 task (J1). Simulation/observation/ruleset/network
packages otherwise untouched.*
