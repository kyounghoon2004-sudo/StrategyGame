# DAgger Round 3 Handoff — jev-policy-v0.5.0-fi-dagger3 (v0.5)

STATUS: PARTIAL — round executed cleanly, all 32 A3 gates pass, but the
round-3 policy REGRESSED vs v0.4 on every primary metric except the D0
depth trend. Do NOT run round 4 until the regression cause is isolated.

## Baseline

- Driver: jev-policy-v0.4.0-fi-dagger2, `artifacts/jev_dagger_v1/checkpoints/seed44.pt`
  (sha256 `18ec1162…c0cc`, verified before collection)
- Dataset in: jev-fullinfo-dataset-v0.4.0 (21,290 train; sha256 `4a17aa3a…30d21`)
- Frozen: JevPolicyV0 (1,014,430 params), mask v0.2.0, ValueTargetV0,
  PolicyTargetV0, Simple-continuation teacher (horizon 8), optimizer,
  train/val/test split, v0.2 bytes.

## What was done

One supervised aggregation round, nothing else:

1. Collected v0.4-visited states on the 144 frozen TRAIN scenarios
   (deterministic masked argmax, cap 42/scenario): 6,048 raw / 6,048 unique.
2. Cross-deduped against the v0.4 TRAIN corpus with the
   training-canonical key (float32 obs bytes + class + mission + legal),
   join-verified bit-exact on all 12,096 carried dagger1/dagger2 rows:
   5,408 NEW_UNIQUE, 640 ALREADY_IN_V04, 0 within-round duplicates.
   (The D0 pre-rounding obs_hash cannot be recomputed from shard
   tensors — verified 0/12,096 — hence the tensor-key method.)
3. Labeled with the frozen teacher pipeline; recovery gate passed
   (agreement 0.416, SCOUT boundary both sides, coherent separation).
4. Built jev-fullinfo-dataset-v0.5.0: 21,290 carried (bit-identical
   prefix) + 5,408 novel dagger3 = 26,698 train; val/test byte-identical.
5. Mixed 4×32 overfit gate passed (1.1329 vs floor 1.1327).
6. Trained 3 seeds from scratch; seed44 selected by validation only
   (val 1.5290 @ epoch 3; seeds 42/43: 1.5373/1.5303).
7. Full eval chain: IID, D_VISITED_VALIDATION_V04 (1,536 states, v0.4
   driver, pre-train) + post-selection v0.5 visited TEST, depth,
   closed-loop 4-way, drift/shift/latent, SCOUT, disagreement, exam, oracle.

## Results (v0.4 -> v0.5)

| metric | v0.4 | v0.5 | delta |
|---|---|---|---|
| IID regret / top1 | 0.00566 / 0.434 | 0.00650 / 0.383 | WORSE |
| visited_v04 regret | 0.00409 | 0.00433 | WORSE |
| frozen visited regret | 0.00488 | 0.00489 | flat |
| depth trend (D0 / A1 set) | 0.00439 / 0.00263 | 0.00420 / 0.00270 | mixed |
| closed-loop dM / exchange | +0.4726 / -3.6 | +0.4750 / -37.1 | dM flat, ex -33.5 |
| oracle gap closed | 78.5% | 36.8% | reopened |
| exam regret | 0.0377 | 0.0449 | WORSE |
| SCOUT RECON (teacher 94.7%) | 53.7% | 20.8% (SHADOW 7->320) | AWAY from teacher |
| R3-state teacher agreement | 0.416 | 0.394 | unconsumed (-0.021) |
| latent NN distance | 1.711 | 1.726 | WORSE |
| INVALID | 0 | 0 | hold |

All three v0.5 seeds regress IID regret vs v0.4 (0.00616/0.00675/0.00650
vs 0.00566): systematic, not selection noise. v0.4 closed-loop -3.6
reproduced exactly as the control arm (deterministic benchmark).

## Verdicts

- TRAINING_SUCCESS: PASS (stable, normal selection, INVALID=0; mild IID slip noted)
- DISTRIBUTION_SUCCESS: PARTIAL (D0 depth trend improved; visited/latent/SCOUT regressed)
- POLICY_QUALITY_SUCCESS: FAIL (exchange delta -33.5, dM flat)
- COVERAGE_CONVERGENCE: NOT_CONVERGED (89.4% novel, ~60% disagreement, distribution moving)
- Diagnosis: teacher-signal exhaustion — mean teacher regret on round-3
  states is only 0.0030, i.e. the remaining disagreement is mostly
  near-tie signal; fitting it hurt. Coverage is not saturated but is no
  longer the binding constraint.

## Artifacts

`artifacts/jev_dagger_v2/`: round3_collection/ dataset_v05/ audit/
checkpoints/ metrics/ (incl. success.json) visited_validation/
closedloop/ (comparison_4way.json) scout/ depth/ drift/ exam/ oracle/.

Code: `python_jev/aggregate/{dataset_v05,run_dagger3}.py`,
`gather.py` (+cross_dedup_report/shard_tkey), `data_v03.py`
(+JevFullInfoDatasetV5), `diagnose/collect.py` (+4 SOURCE_POLICY labels),
`python_jev/tests/test_a3_dagger3.py` (32 gates).

## Next (exactly one)

Before any round 4: audit dagger3 label quality (teacher-margin
distribution and near-duplicate label conflicts on the 5,408 novel
states) to separate teacher-signal exhaustion from
representation/optimization failure as the cause of the v05 regression;
do not aggregate further until the cause is isolated.
