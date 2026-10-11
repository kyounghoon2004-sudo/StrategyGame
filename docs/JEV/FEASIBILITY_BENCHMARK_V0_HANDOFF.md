# FEASIBILITY_BENCHMARK_V0 HANDOFF — Execution Feasibility + Benchmark Validation

Date: 2026-09-20 · Task: isolate and repair benchmark/mechanical-feasibility
problems BEFORE any retraining, Fog training, RL, self-play, or architecture
change. The seed43 checkpoint is used exactly as-is; no training occurred.

---

STATUS: PASS (all 20 F0 gates green; 230/230 tests green)

PROJECT ROOT: D:\Game development\Demon slayer\StrategyGame

CHECKPOINT: artifacts\jev_training_v0\checkpoints\seed43.pt
(weights modified: NO — sha256 02d46c8a…ca2b2 pinned by test)

---

## 1. PART A — FAILURE AUDIT (jev-failure-audit-v0.1.0)

Reproduced on pristine mask behavior across 4 state sources (102,040 rows):

| source | rows | mask-legal | INVALID | PARTIAL | SUCCESS | sel-invalid |
|---|---|---|---|---|---|---|
| collection IID (192 scn) | 73,668 | 66,072 | 5,580 | 41 | 60,451 | 0.059 |
| collection OOD (48 scn) | 18,390 | 16,372 | 1,367 | 8 | 14,997 | 0.056 |
| tactical exam (60) | 360 | 297 | 63 | 0 | 234 | 0.100 |
| closed-loop (144 battles) | 9,622 | 9,622 | 3,311 | 1 | 6,310 | **0.344** |
| TOTAL | 102,040 | 92,363 | 10,321 | 50 | 81,992 | 0.168 |

The closed-loop 0.344 selected-invalid rate reproduces the T0 0.33–0.36
finding exactly. Collection-state selections fail far less (0.06): JEV
visits dud-prone states of its own making — the offline→closed-loop gap
mechanism, quantified. INTERRUPTED never appears as an envelope status
(interruption is PARTIAL + interrupted=True, preserved per-row, never merged).

### Classification (no unclassified failures)

- A MASK_UNDERSPECIFIED: **10,321** (100% of INVALID). Full table (34 entries)
  in failure_audit/audit_summary.json. Top: ARCHER KITE/NO_DESTINATION 1,555;
  CAVALRY FLANK/NO_FLANK_DESTINATION 1,281; SCOUT EVADE/NO_SAFE_ROUTE 1,099;
  ARCHER FOCUS_FIRE/OUT_OF_RANGE 961; REPOSITION_RANGE 790; SPEARMAN SCREEN
  706; INFANTRY ADVANCE 607; withdraw/reposition/support tails. Zero ATTACK /
  FIRE / HARASS / HOLD failures anywhere: the mask's attack predicate already
  coincides with the executor's on realistic states.
- B EXECUTOR_BUG: **0** — full-corpus resolver recheck (76,636
  preflight-legal trial executions, 0 INVALID; 15,422 preflight-illegal,
  0 non-INVALID). No valid realization was ever failed by an executor.
- C CONTRACT_MISMATCH: **0 events**. Structural note: mask `in_range_known`
  vs executor `enumerate_targets` coincide exactly for non-garrisoned actors
  (same range fn, same lock checks, no LOS term on either side —
  get_attackable_targets has no LOS/visibility check). Declared latent pairs
  (garrisoned attacker; PURSUE/EVADE stale-eligibility) never triggered in
  102k rows. The SHADOW false-negative direction (mask too narrow) is real
  and quantified in Part D (1,139 gained slots), not here.
- D EXPECTED_WORLDTRUTH_DISCOVERY: **50** (all PARTIAL/HIDDEN_CONTACT).
  Root cause proven for 43/43 checkable states: the contacted unit had drifted
  OUTSIDE the scenario's cell_data, and full-info knowledge is
  scenario-map-scoped (`visible := cell_data keys`), so the out-of-map unit is
  legitimately unseen. Skill-layer handling is exactly per contract (no
  pre-leak, discovery at execution, PARTIAL not INVALID). Sim-level edge for a
  future task; NOT a mask/executor defect; preflight must not "fix" it.
- E STALE_STATE_RACE: **0** — mask/exec state versions recorded equal on all
  102,040 rows (single-threaded, clone-per-branch; no race exists).

Artifacts: artifacts/jev_feasibility_v0/failure_audit/{audit_rows.jsonl,
audit_summary.json} · envelope parity sha256 2ab5ed87… (post-refactor
fingerprint; pre/post equivalence is evidenced by the untouched 73-test J1
suite — exact-code fixtures — green on the refactored code).

---

## 2. PART B — SkillPreflightV0 (skill-preflight-v0.1.0)

- Shared resolvers: python_sim/skills/candidates.py (skill-candidates-v0.1.0,
  17 resolve_* functions + shared predicates). All 5 executor modules and
  preflight call the SAME functions (F0-4 source + behavior enforced).
- Preflight: python_sim/skills/preflight.py — thin 30/30 dispatch returning
  (executable, reason_code, candidate_count, detail, sub). Hash 80cf82d0….
- No tactical logic (F0-3): ×3 soldier scaling leaves every bit identical
  (behavioral); sources contain no tactical/ML vocabulary (static guard).
- Executor refactor preserved every envelope literal, trace, effect, and
  failure wording (frozen details mapped by (reason, sub), incl. J1-era empty
  strings and quirks: KITE's unused min-band, REPOSITION_RANGE's stale-
  designation fallthrough, SUPPORT's reachability-before-shortcut order).
- Legal mask v0.2.0 (observation-safe-skill-mask-v0.2.0): "mechanically
  executable according to authorized knowledge". Six slots preserved;
  JevPolicyV0 untouched. Old mask function untouched (v0.1.0 behavior).
- Invariants: full-info preflight-legal → INVALID = **0.000000** (0/76,636
  corpus-wide; F0-5); fog A/B identical bits + TRUE→PARTIAL/HIDDEN_CONTACT
  allowed (F0-6).

---

## 3. PART C — OLD vs NEW REEVALUATION (2,299 identical states, seed43 frozen)

| | old mask | new mask |
|---|---|---|
| mean regret | 0.00647 | 0.00639 |
| invalid-selection rate | 0.052 | **0.000** |
| partial-selection rate | 0.0004 | 0.0004 |
| mean entropy | 1.592 | 1.500 |
| selection agreement | — | 0.947 |
| shrink / expand states | — | 695 / 183 |

Per-class invalid selections → 0 in all classes (ARCHER 45, CAVALRY 62,
INFANTRY 4, SCOUT 3, SPEARMAN 6 — all eliminated). Regret is unchanged:
feasibility filtering removes duds without distorting preferences on
Simple-driver states. Artifact: mask_comparison/old_vs_new.json (2,299 rows).

---

## 4. PART D — DATASET AUDIT (read-only; v0.1.0 shards immutable, hashes verify)

- 15,343/15,343 records matched by (scenario_id, decision_index) with
  **0 state_hash mismatches** (exact-state proof).
- 5,643 records (**36.8%**) change masks. Lost Q-valid branches: 6,947/82,444
  (8.4%). Gained unscored slots: 1,139 — **all SCOUT/SHADOW** (old mask too
  narrow: actor-band vs dest-band). No ATTACK/FIRE/HARASS/HOLD bit ever
  changes. Most-shrunk: ARCHER KITE 1,454; CAVALRY FLANK 1,024; ARCHER
  FOCUS_FIRE 927; SPEARMAN SCREEN 659.
- Target impact: mean old P mass on removed (dud) slots = **7.7%**;
  shared-support KL = 0.0018 (renormalization negligible — Q gaps tiny);
  top-action flips = **9.8%**.
- VERDICT: **target regeneration REQUIRED** — 36.8% of records mislabel
  availability, 7.7% of preference mass points at impossible actions, 9.8% of
  argmax labels change, and 1,139 SHADOW gains need branch Q. Scope: recompute
  P_target/q_valid from STORED Q for shrink-only records (no re-simulation)
  + deterministic branch rollouts for the 1,139 gained slots only. Full
  corpus re-simulation NOT required. Nothing was mutated.
- Artifact: mask_comparison/dataset_audit.json.

---

## 5. PART E — MISSION SYMMETRY AUDIT

Finding from the frozen T0 benchmark (Simple pairing, 48 battles):

- ALL 22 victories are `turn_limit_survived` on hold_hq/survive_turns, won
  IDENTICALLY by JEV-blue and baseline-blue battles (same scenarios, same
  turns, red armies intact). destroy_all_red: 21 expired + 1 defeat,
  0 victories (3–8 red formations alive at every expiry — never close).
  capture_capital: 4 expired, 0 victories. The single defeat: an
  extreme-odds OOD scenario (blue outnumbered ~8:1, HQ overrun turn 14).
- `_battle_lost` is never set (always False): defeat ⟺ blue HQ dead or blue
  annihilated, period. Only the BLUE HQ matters (battle.py); red HQ is
  verdict-irrelevant. Turn limits (8–20) bind before the 30-turn bench cap.

Root cause: **MISSION_CONTRACT_ASYMMETRY (primary)** — the authoritative
evaluator (turn.py, faithful Godot port) scores the BLUE mission contract
only; RED has no offensive victory condition (no destroy_all_blue, no
capital/HQ objective). **SCENARIO_GENERATOR_BIAS (contributing)** —
back-corner HQ spawns, no red-offensive missions, survive-by-default
objectives. Partly **EXPECTED_GAME_DESIGN** (blue-command experience is
intentional). NOT a benchmark translation bug (run_pair mapping is
arithmetically faithful) and NOT combat-ruleset asymmetry.

RED terminal semantics: none exist in production. Per the task rule NOTHING
was invented: **SIDE_SWAPPED_TERMINAL_BENCHMARK = INVALID** (pinned in
benchmark.py MISSION_SEAT_SEMANTICS + scenario_comparability, fail-closed
for unknown missions).

---

## 6. PART F/I — BENCHMARK V1 + CORRECTED RE-RUN (closed-loop-benchmark-v0.1.0)

Protocol: same-seat BLUE terminal comparisons (each policy as blue vs fixed
Simple red, 24 matched scenarios — VALID) + JEV-blue vs Random/Hold red
(within-condition) + JEV-red descriptive actor-relative metrics (NO terminal
claims). 168 battles × OLD/NEW masks. Artifacts: benchmark/v1_old_mask.json,
v1_new_mask.json.

Invalid rates (JEV seats): blue-vs-Simple 0.467→**0.000**; vs Random
0.501→**0.000**; vs Hold 0.536→**0.000**; JEV-red 0.216→**0.000**. (JEV picks
more duds against passive reds — pre-contact states dominate.) PARTIALs: 4
total (out-of-map contacts, class D).

Same-seat BLUE terminal (NEW mask): JEV = Simple = Random = Hold =
**0.458 victory / expired rest** — terminal outcomes are 100%
scenario-determined (11 auto-victories) and do not discriminate policies.
Simple-blue takes 2 defeats (0.083); all others 0.000.

Actor-relative (NEW mask, vs Simple red): mission-progress Δ —
Simple +0.581 > JEV +0.475 > Random/Hold +0.458; casualty exchange —
Simple +22 > Random −57 > Hold −84 > **JEV −114**; objective Δ = 0
everywhere (O=0 live, per overlap review). JEV-red descriptive: exchange
−150 from red's view, red HQ survival 0.958, no terminal claims.

Headline: removing 34–54% dud actions changed NO terminal outcome and left
JEV-blue ≈ Hold on progress and LAST on exchange. The offline→closed-loop
gap is therefore dominated by **target/policy quality (incl.
continuation bias), NOT mechanical invalidity** — the binding constraint the
next task must address (retrain on corrected targets). Skill shift under the
new mask (same weights): ATTACK picks 126→332, dud movement collapses —
feasibility filtering works; preferences need retraining.

OLD-vs-NEW benchmark: terminal/verdict/turn/HQ cells identical; casualties
±5% (more real actions → more contact); invalid 0.34–0.54 → 0.000.

---

## 7. PART G — EPSILON AUDIT (frozen metric intact: q_epsilon=0.25)

Test shard, trained vs untrained: @0.25: 0.9967/0.9967 (Δ 0.000, saturated);
@0.05: 0.9726/0.9595 (Δ 0.013); @0.02: 0.9138/0.8478 (Δ 0.066);
@0.01: 0.8733/0.7668 (Δ 0.106); @0.005: 0.8341/0.7113 (Δ 0.123).
Q-gap distribution: median 0.000, mean 0.0063, p90 0.0153; 83.6% of gaps
< 0.005. RECOMMENDATION: **regret stays the primary metric** (most decisions
are ties, so any epsilon mostly measures tie-luck); eps@0.01 may serve as a
secondary diagnostic (≈p90, Δ 0.106). No canonical change made.
Artifact: benchmark/epsilon_audit.json.

---

## 8. PART H — CONTINUATION SENSITIVITY (both factions varied, 320 states)

Overall: Simple-vs-Random agree 0.791 / Spearman 0.497 / mean|ΔQ| 0.0170;
Simple-vs-Hold 0.822 / 0.426 / 0.0225; Random-vs-Hold 0.788 / 0.492 / 0.0142.
(T0 blue-only figures 0.713/0.477/0.0190 are the same order; the delta is
sample + red-side variation.) By class: ARCHER most sensitive (0.62 agree),
then CAVALRY (0.79/0.74); SPEARMAN/SCOUT/INFANTRY robust (0.82–0.95). By
mission: capture_capital strikingly stable (0.93/1.00 — pre-contact approach
states); destroy/hold/survive 0.73–0.79. Interpretation: teacher dependence
is real (~20% top-action flips) but SECONDARY to the removed mechanical
confounder (34–54% dud selections); it is now the leading target-design
question for the next task. No ensembles built.
Artifact: continuation_sensitivity/sensitivity.json.

---

## 9. TACTICAL EXAM RERUN (cases untouched)

Old (reproduces handoff): regret 0.0441, invalid 6/60 — all 6 SPEARMAN
(SCREEN with no declared anchor in exam ctx). New: regret 0.0431, invalid
**0/60**. Per-class new regret: INF 0.081 (was 0.091), ARC 0.033, CAV 0.028,
SCT 0.044, SPR 0.030 (was 0.025; ±noise on n=12).
Artifact: benchmark/exam_rerun.json.

---

## 10. ACCEPTANCE GATES F0-1…F0-20

F0-1 classify-all PASS (10,321 A / 0 B / 0 C / 50 D / 0 E + proofs) ·
F0-2 30/30 PASS (typed, tagged, ACTION_SPACE-pinned) · F0-3 no-tactics PASS
(behavioral + static) · F0-4 shared-module PASS (source + agreement) ·
F0-5 0.000 PASS (0/76,636 + 0/15,422 reverse) · F0-6 fog PASS (A/B + hidden
contact) · F0-7 checkpoint PASS (hash-pinned, deterministic) · F0-8 old/new
PASS (2,299 rows) · F0-9 dataset audit PASS (15,343/15,343, 0 mismatches,
shards verify) · F0-10 asymmetry classified PASS (contract + generator bias)
· F0-11 no invented RED rules PASS (INVALID pinned) · F0-12 V1 contract PASS
· F0-13 no red win claims PASS · F0-14 epsilon PASS · F0-15 sensitivity PASS
(5 classes × 4 missions) · F0-16 V1 rerun PASS (336 battles) · F0-17 exam
PASS · F0-18 230/230 green PASS (N0 34, R0 36, S0 29, J1 73, V0 19, T0 17,
F0 22) · F0-19 no training PASS (scope test + no optimizer/backward/RL
identifiers; checkpoint + shards hash-verified) · F0-20 no gameplay rewrite
PASS (no .gd/.tscn markers; edits are .py/.md/.json only).

---

## 11. SCOPE CHECK

Training: NOT STARTED · Optimizer: NOT CREATED · Weights changed: NO ·
Production dataset regenerated: NO (read-only audit; shards verify against
T0 hashes 48beb94e/0aba5d92/04c393a1/c3a8bd05) · Fog training: NOT STARTED ·
RL/self-play: NOT STARTED · Godot gameplay rewrite: NO.

Environment note: CUDA device transfers wedge indefinitely on this
workstation while Unreal/Godot editors hold the GPU (observed: audit stuck
40+ min in ObservationBatchV0.to(); stack-proved via py-spy). All F0
inference runs on CPU (F0_DEVICE override available); identical weights,
float32, argmax-stable.

## 12. CHANGED FILES

NEW python_sim/skills/candidates.py · NEW python_sim/skills/preflight.py ·
EDIT python_sim/skills/{infantry,spearman,cavalry,archer,scout}.py (shared-
resolver refactor; J1 green, envelopes preserved) · EDIT
python_sim/skills/__init__.py (exports) · EDIT python_sim/rollout/engine.py
(additive mask_fn hook) · NEW python_sim/tests/test_f0_preflight.py (11) ·
NEW python_jev/feasibility/{__init__,audit,run_audit,reeval,benchmark,
epsilon_audit,sensitivity,run_feasibility}.py · EDIT
python_jev/training/closedloop.py (additive on_decision + mask_fn hooks) ·
EDIT python_jev/training/exam.py (additive mask_fn hook) · NEW
python_jev/tests/test_f0_feasibility.py (11) · NEW
artifacts/jev_feasibility_v0/{failure_audit,mask_comparison,benchmark,
continuation_sensitivity}/*.json{,l} · NEW this handoff.

(All paths under D:\Game development\Demon slayer\StrategyGame.)

HANDOFF: D:\Game development\Demon slayer\StrategyGame\docs\JEV\FEASIBILITY_BENCHMARK_V0_HANDOFF.md

## 13. NEXT (one evidence-driven task)

**Regenerate targets + supervised retrain (option A, scoped):** recompute
P_target/q_valid_mask from STORED Q under mask v0.2.0 for all 15,343 records
(no re-simulation except 1,139 SHADOW-gain branch rollouts), then retrain
JevPolicyV0 from scratch on corrected targets (same architecture, same
splits). Pre-register the decision rule: the retrain wins iff corrected
closed-loop (Benchmark V1, same-seat blue) shows JEV-blue beating
Simple-blue on casualty exchange and mission progress — the two actor-
relative metrics where seed43 currently trails (dM +0.475 vs +0.581,
exchange −114 vs +22) with mechanical invalidity already at zero. If the gap
persists after the retrain, the follow-up is rollout-target redesign
(continuation-bias robust targets, Part H evidence), not another mask pass.
