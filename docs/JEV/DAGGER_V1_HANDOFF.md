# DAGGER_V1 HANDOFF — Second Supervised State-Aggregation Round

Date: 2026-09-20 · Task: DAgger round 2 (NOT RL) with the v0.3 policy as
behavior policy. Only the training-state distribution changed; every
contract (architecture, ruleset, observation, preflight, mask v0.2.0,
ValueTargetV0, PolicyTargetV0, Simple teacher, horizon 8) frozen.

---

STATUS: PASS (27 A2 gates green; 325/325 tests green)

PROJECT ROOT: D:\Game development\Demon slayer\StrategyGame

## 1. ROUND-2 COLLECTION

- driver: jev-policy-v0.3.0-fi-dagger1 seed43, argmax, TRAIN-only (144/144)
- raw states: 6,048 (cap 42, pilot rate 1.0) · unique: 6,048 ·
  duplicates: 0 (same unique-obs mechanism as round 1)
- classes: SCOUT 1449 / CAVALRY 1233 / ARCHER 1180 / SPEARMAN 1146 /
  INFANTRY 1040; profiles TERRAIN 3234 / DEV_FLAT 2814
- depth: 0–4: 720 · 5–9: 720 · 10–19: 1440 · 20+: 3168
- missions: destroy_all_red 2688 / hold_hq 2142 / survive_turns 672 /
  capture_capital 546

## 2. SCOUT DECISION-BOUNDARY ANALYSIS (diagnostic only, existing features)

SCOUT states 1,449: teacher EVADE 13 / RECON_ADVANCE 1,363 (both sides
covered); policy EVADE 709 / RECON 134 / SHADOW 526. Strongest
EVADE-vs-RECON feature gaps: strength_ratio d=+1.19 (0.74 vs 1.09),
turn d=−1.12, patch_friendly d=+1.01, blue_live d=+0.88,
trajectory_step d=−0.88 — the teacher EVADEs when losing, late, and
isolated, RECONs otherwise. Policy/teacher agreement on dagger2: 0.334
(corrective signal still large; gate PASSED). Notable dynamics: v0.3
overcorrected round-1's lesson toward SHADOW (36% vs teacher 1%), and
CAVALRY FLANK collapsed to 0.2% vs teacher 28.8% — both addressed by
round-2 labels.

## 3. DATASET jev-fullinfo-dataset-v0.4.0

- v0.2 originals 9,194 + dagger1 6,048 + dagger2 6,048 = 21,290 train
  (carried rows bit-identical, tensor-equality asserted)
- val 1,535 / test 1,531 byte-copies · hash fb0a6dbf04acb4e4… · leakage 0
- v0.3 train bytes pinned and unchanged.

## 4. TINY OVERFIT (43+43+42 incl. dagger2): PASS

loss 1.1348 vs floor 1.1344.

## 5. TRAINING jev-policy-v0.4.0-fi-dagger2 (from scratch, CPU)

1,014,430 params. seed42: ep4 val 1.5339 · seed43: ep5 val 1.5297 ·
seed44: ep3 val 1.5273 (selected, best val across all rounds).
Checkpoint: artifacts/jev_dagger_v1/checkpoints/seed44.pt.

## 6. IID TEST (v0.2 test): v0.2 reg 0.00696/top1 0.411 ·
v0.3 reg 0.00589/top1 0.394 · v0.4 reg 0.00566/top1 0.434.
Monotone regret decline; no collapse.

## 7. VISITED VALIDATION (frozen A1 set): v0.2 0.00653/0.326 ·
v0.3 0.00542/0.327 · v0.4 0.00488/0.376. Monotone, top1 jumps in round 2.

## 8. DEPTH TRENDS (frozen jev_new): v0.2 +0.00541 · v0.3 +0.00459 ·
v0.4 +0.00439. Monotone flattening.

## 9. CLOSED LOOP (same-seat BLUE, 24 scenarios, baselines reproduced)

v0.2 dM +0.4726/ex −128.8 · v0.3 dM +0.4786/ex −53.7 ·
v0.4 dM +0.4726/ex −3.6 · Simple +0.5809/+22.0. Exchange improved
+125.2 over two rounds with mission progress flat. INVALID 0.
v0.4 essentially matches the full-bench oracle scale (−2.8 subset).

## 10. CONTACT + SCOUT (scenario-matched 60, driver selections)

Attack-opp: 0.148 → 0.155 → 0.133. Nearest-enemy: 6.60 → 5.63 → 7.48
(contact proximity partially reverted while selections improved).
SCOUT: EVADE 80.5% → 49.9% → 44.0%; RECON 1.8% → 9.2% → 53.7%;
SHADOW overcorrection unwound (339 → 7). Latent NN (fixed v0.2 space):
1.734 → 1.739 → 1.711 (slight pull-in).

## 11. EXAM (same 60): untrained 0.0768 · v0.2 0.0390 · v0.3 0.0377 ·
v0.4 0.0377 (identical to v0.3 — exam states are IID-like, unaffected).

## 12. ORACLE GAP (frozen 6-subset): oracle −2.8 · v0.2 −164.5 ·
v0.3 −44.7 · v0.4 −37.7 → closed 74.1% → 78.5%.

## 13. SUCCESS: TRAINING PASS · DISTRIBUTION PASS (visited −26% over
two rounds, depth flatter, no contact collapse) · POLICY_QUALITY PASS
(exchange −53.7→−3.6, dM −0.006 immaterial, RECON 9.2%→53.7%,
EVADE 49.9%→44.0%, oracle gap 74%→79%, no class regressions).

TESTS: 325 passed (A2 27 new). Chain (v0.2/R1/D0/A1) intact.

SCOPE: RL NOT STARTED · self-play NOT STARTED · Fog 0 · no
architecture/teacher/ValueTarget/mask/Godot changes.

CHANGED FILES (under project root): EDIT
python_jev/diagnose/collect.py (A2 set labels), EDIT
python_jev/aggregate/{gather, dataset_v03, data_v03, drift}.py
(version/diagnostic parameters, defaults identical), NEW
python_jev/aggregate/{dataset_v04, run_dagger2}.py, NEW
python_jev/tests/test_a2_dagger2.py, NEW artifacts/jev_dagger_v1/
(collected_train_states, dataset_v04, checkpoints, metrics,
closedloop, drift, exam, audit), NEW docs/JEV/DAGGER_V1_HANDOFF.md.

HANDOFF: D:\Game development\Demon slayer\StrategyGame\docs\JEV\DAGGER_V1_HANDOFF.md

## 14. DIAGNOSIS: A — on-policy coverage error (evidence: monotone
visited/depth/exchange/SCOUT gains across both rounds; teacher still
disagrees at 0.334 on dagger2 states; overfit/val healthy, so not
optimization; no representation change was needed for these gains;
residual RECON 54% vs 95% and exchange −3.6 vs +22 remain).

NEXT (one): DAgger round 3 — v0.4 driver on TRAIN, same frozen
teacher, append, retrain from scratch.
