# DAGGER_V0 HANDOFF — First Supervised State-Aggregation Round

Date: 2026-09-20 · Task: DAgger-style round 1 (NOT RL) against the
D0-classified COVARIATE_SHIFT failure. Only the training-state
distribution changed; architecture, ruleset, observation layout,
preflight, mask v0.2.0, ValueTargetV0, PolicyTargetV0, skill contracts,
continuation teacher (Simple), and horizon (8) all frozen.

---

STATUS: PASS (all 27 A1 gates green; 298/298 tests green)

PROJECT ROOT: D:\Game development\Demon slayer\StrategyGame

## 1. STATE AGGREGATION (state-aggregation-v0.1.0)

- collection checkpoint: jev-policy-v0.2.0-fi seed43 (df97ca8e…),
  deterministic masked argmax, both seats, no exploration noise
- train scenarios: 144/144 (all TRAIN split; 0 val/test/OOD — gated)
- raw visited states: 6,048 (144 × cap 42; cap set from a 24-scenario
  pilot after measuring dedup rate 1.0)
- unique states: 6,048; duplicates removed: 0 (obs hashes unique per
  visit — turn/soldier counts differ every step; dedup keyed on
  obs_hash × class × mission × legal mask, visit_count recorded,
  mechanism verified structurally by A1-4)
- profiles: TERRAIN_FULL_INFO 3,234 / DEV_FLAT_ALL_INFO 2,814
- classes: SCOUT 1,448 / CAVALRY 1,234 / ARCHER 1,180 / SPEARMAN 1,146 /
  INFANTRY 1,040

## 2. CORRECTIVE SIGNAL (gate PASSED, pre-training)

Policy-vs-teacher top agreement on dagger states: 0.368 (far below the
0.90 no-signal stop). Mean regret of current actions: 0.00491.
SCOUT EVADE: policy 82.5% vs teacher 0.4%. SCOUT RECON_ADVANCE: policy
2.6% vs teacher 95.2%. ARCHER FIRE: 0.4% vs 29.9%. CAVALRY FLANK: 7.8%
vs 28.3%. The teacher demonstrably corrects the passive drift on the
collected states, so DAgger can work here.

## 3. DATASET jev-fullinfo-dataset-v0.3.0

- original train: 9,194 (bit-identical reuse, tensor-equality asserted)
- aggregated train: 6,048 · total train: 15,242 · validation: 1,535 ·
  test: 1,531 (val/test/gen byte-copied from v0.2) · hash 037f0c167f5b65bb…
- leakage: 0 (144 dagger scenario IDs ⊆ TRAIN; ∩ val/test/OOD = ∅)
- v0.2 shards byte-unchanged (pinned). Equal loss weight, no reweighting.

## 4. TINY OVERFIT (64 v0.2 + 64 dagger1): PASS

loss 1.2621 vs floor 1.2601, KL 0.0009.

## 5. TRAINING jev-policy-v0.3.0-fi-dagger1 (from scratch, CPU)

1,014,430 params, architecture-identical. seed42: best-ep6 val 1.5378
(12 ep, 62.7 s). seed43: best-ep4 val 1.5344 (10 ep, 52.1 s).
seed44: best-ep3 val 1.5361 (9 ep, 52.1 s). Selected seed 43 by
original-validation loss only.
Checkpoint: artifacts/jev_dagger_v0/checkpoints/seed43.pt.

## 6. ORIGINAL IID TEST (v0.2 test, 1,531 rows)

OLD v0.2: loss 1.5109, regret 0.00696, p95 0.02693, top1 0.411.
NEW seed43: loss 1.5074, regret 0.00589, p95 0.02522, top1 0.394,
eps@0.01 0.8942. (seed42: reg 0.00514; seed44: reg 0.00721.)
IID competence intact — slightly better on loss/regret, top1 −0.017.

## 7. VISITED VALIDATION (D_VISITED_VALIDATION_V0, 1,536 frozen states)

OLD: regret 0.00653, p95 ~0.034, top1 0.326.
NEW: regret 0.00542 (−17%), top1 0.327. DAgger improved
policy-induced-state performance. (NEW-driver visited-test states are
harder for both: old 0.00945, new 0.00853.)

## 8. TRAJECTORY DEPTH (regret 0–4 → 20+)

Frozen jev_new set — OLD trend +0.00541, NEW trend +0.00459 (flatter).
Visited-validation — OLD +0.00324, NEW +0.00296 (flatter). Degradation
with depth reduced on both sets.

## 9. CLOSED LOOP, same-seat BLUE vs Simple red (24 matched scenarios)

OLD v0.2: dM +0.4726, exchange −128.8. NEW v0.3: dM +0.4786 (+0.006),
exchange −53.7 (+75.1). Simple +0.5809/+22.0, Random +0.4583/−56.5,
Hold +0.4583/−83.9. NEW now beats Random and Hold on exchange with no
mission-progress regression. Baselines bit-identical across runs. No
side-swapped claims. INVALID 0, partial 0.0006.

## 10. CONTACT DRIFT + SCOUT BEHAVIOR (scenario-matched 60, driver sels)

Attack-opportunity 0.148→0.155; attack-legal 0.320→0.326;
nearest-enemy 6.60→5.63; local enemies 1.68→1.77; visible 4.86→5.17;
friendly dispersion 9.53→7.99; legal count 4.48→4.55. SCOUT (n≈1033):
EVADE 80.5%→49.9%, RECON_ADVANCE 1.8%→9.2%, SHADOW 3→339 picks.
Behavior moved toward engagement; RECON still far from teacher (95%).

## 11. DISTRIBUTION SHIFT (fixed v0.2 latent space)

Latent NN-to-train: IID 1.458, OLD-visited 1.734, NEW-visited 1.739 —
NOT pulled closer; the round worked through better selections within
a similar visitation envelope plus modest contact recovery, not
through latent-space return. Largest new-vs-old feature moves:
friendly dispersion −1.5, visible enemies +0.3, plains fraction −0.06.

## 12. TACTICAL EXAM (same 60): untrained 0.0768 · old 0.0390 · new 0.0377.

## 13. ORACLE GAP (6-scenario subset, rerun bit-identical to D0)

Oracle −2.8 · old −164.5 · new −44.7 → 74.1% of the oracle exchange
gap closed, dM tied at +0.333.

## 14. SUCCESS: TRAINING_SUCCESS PASS · DISTRIBUTION_SUCCESS PASS
(visited regret −17% + flatter depth ×2; latent flat, reported) ·
POLICY_QUALITY_SUCCESS PASS (exchange +75.1 with dM +0.006).

TESTS: 298 passed (N0 34, R0 36, S0 29, J1 73, V0 19, T0 17, F0 22,
R1 21, D0 20, A1 27). Prior chain (v0.2, R1, D0 artifacts) intact.

SCOPE: RL NOT STARTED · Self-play NOT STARTED · Fog 0 samples ·
Architecture/teacher/ValueTarget/mask unchanged · Godot untouched.

CHANGED FILES (all under project root; additive + 2 A1 hooks in D0):
NEW python_jev/aggregate/: __init__.py, gather.py, dataset_v03.py,
data_v03.py, drift.py, run_aggregate.py
EDIT python_jev/diagnose/collect.py (driver_ckpt/max_states/visit_count
hooks; D0 behavior default-identical)
NEW python_jev/tests/test_a1_aggregate.py (27 gates)
NEW artifacts/jev_dagger_v0/: collected_train_states, dataset_v03,
visited_validation, checkpoints, metrics, closedloop, drift, exam,
audit, oracle_closedloop
NEW docs/JEV/DAGGER_V0_HANDOFF.md (this file)

HANDOFF: D:\Game development\Demon slayer\StrategyGame\docs\JEV\DAGGER_V0_HANDOFF.md

NEXT (exactly one): DAgger round 2 — collect v0.3-visited states on
TRAIN scenarios, label with the same frozen Simple-continuation
teacher, append, retrain from scratch; targets the residual SCOUT
RECON gap (9% vs 95%) and remaining exchange gap (−54 vs Simple +22).
