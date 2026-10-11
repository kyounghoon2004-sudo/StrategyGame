# SIGNIFICANCE_GATE_V0 HANDOFF — Gated-Aggregation Ablation

Date: 2026-09-20 · Experiment: significance-gated-aggregation-ablation-v0.1.0

STATUS: PASS — SIGNIFICANCE_GATE_SUCCESS with NARROW threshold robustness.
No new collection, no DAgger4, no production v0.6, no threshold frozen, no
architecture/teacher/ValueTarget/PolicyTarget/optimizer/mask changes. All
regression suites green (357 + 26 SG0).

PROJECT ROOT: D:\Game development\Demon slayer\StrategyGame

## 1. Sources (SG0-1)

v0.4 ckpt `18ec1162…c0cc` (pinned), v0.4 train `4a17aa3a…30d21` (pinned),
v0.5 train 26,698 rows (shard-hash verified, carried prefix bit-equal to
v0.4), v0.5 ckpt `41996a20…1d6ce42`, D3 set verified with 5,408 novel rows.
New states collected: 0. (`summary/sources.json`)

## 2. Gates (Parts A-E)

Frozen horizon-8 Simple-continuation Q, full precision, no argmax gating.
BASE = v0.4 prefix (21,290) for every arm.

| arm | rule | kept/5408 | corr frac | density | tie kept | large kept |
|-----|------|-----------|-----------|---------|----------|------------|
| R25 | reg≥.0025 | 822 (15%) | 0.991 | 0.02030 | 400 | 240/240 |
| M25 | mar≥.0025 | 1056 (20%) | 0.526 | 0.00839 | 0 | 132/240 |
| OR25 | either | 1483 (27%) | 0.991 | 0.01125 | 400 | 240/240 |
| AND25 | both | 395 (7%) | 0.526 | 0.02242 | 0 | 132/240 |
| OR10 | either .001 | 1604 (30%) | 0.998 | 0.01047 | 436 | 240/240 |
| OR50 | either .005 | 1303 (24%) | 0.963 | 0.01245 | 329 | 240/240 |

Scout retained drops to 18–54 of 1,348 (the tie-washout mass is stripped).
M-gates drop tied-top misses (108 large-regret rows have margin<0.0025).
(`manifests/`, `gate_stats/`)

## 3. Training (Part F)

18 runs from scratch, JevPolicyV0 (1,014,430 params), frozen config
(AdamW 3e-4 / wd 1e-4 / clip 1.0 / batch 256 / 30ep / patience 5 / fp32).
Selection: frozen validation CE (model-selection semantics unchanged).
Selected: r25/s44 1.5284, m25/s44 1.5286, or25/s42 1.5292, and25/s43 1.5306,
or10/s44 1.5278, or50/s44 1.5262 (best overall, beats v0.4 1.5273 and v0.5
1.5290). Tiny-overfit passes on all six arms (final≈floor).
Per-epoch metrics saved in `checkpoints/<arm>/training.json`; per-epoch
weights omitted for size (diagnostic selection analysis uses seed spread).

## 4. Offline (Parts H-M)

| model | val | visited | high | agree-top1 | scout-top1 | test reg |
|-------|-----|---------|------|------------|------------|----------|
| v04 | 1.5273 | 0.00409 | 0.02870 | 1.000 | 0.583 | 0.00566 |
| v05 | 1.5290 | 0.00433 | 0.02140 | 0.617 | 0.149 | 0.00650 |
| r25 | 1.5284 | 0.00443 | 0.02039 | 0.621 | 0.103 | 0.00696 |
| m25 | 1.5286 | 0.00465 | 0.01741 | 0.736 | 0.485 | 0.00498 |
| or25 | 1.5292 | 0.00471 | 0.01936 | 0.565 | 0.119 | 0.00561 |
| and25 | 1.5306 | 0.00471 | 0.02085 | 0.544 | 0.035 | 0.00653 |
| or10 | 1.5278 | 0.00412 | 0.01979 | 0.589 | 0.095 | 0.00584 |
| or50 | 1.5262 | 0.00400 | 0.01915 | 0.780 | 0.674 | 0.00575 |

All arms beat v0.5 on D3-high (Part K ✓). or50 is best on val/visited and
recovers agreement (0.780) and scout (0.674) far beyond v0.5. Scout argmax
(S4, n=1341; teacher RECON 1296 is the slot-0 tie artifact): v04 RECON 777 /
v05 180 / or50 909 / m25 641 / or10 EVADE 1205 / or25 EVADE 1137 / r25 EVADE
1039 / and25 scattered — mass barely moves anywhere (RECON 0.23–0.25,
SHADOW 0.12–0.14), argmax is knife-edge. Part I satisfied (or50 competitive
with v0.4 on val+visited); test reported research-only, unused for ranking.

## 5. Closed-loop (Part N)

Same V1 24-job bench, same red, INVALID=0 everywhere, baselines reproduced:

v04 +0.4726/-3.6 · v05 +0.4750/-37.1 · r25 -57.0 · m25 -19.7 · or25 -108.9 ·
and25 -19.4 · or10 -24.8 · or50 +0.4667/+35.2 · Simple +0.5809/+22.0.

or50 beats v0.4 and the Simple baseline on exchange with flat mission
progress. Seed diagnostic (non-selected seeds): or25 -45.3/-60.9 (all seeds
worse than v0.5 — gate-level failure), r25 -32.2/-66.4. Large within-arm
seed spread confirms tie-breaking is knife-edge at fixed offline metrics.

## 6. Oracle / exam (Parts O-P)

Oracle subset (noisy 6-scenario slice; or50 dragged by two -156/-350
battles): oracle -2.83, v04 -37.7 (0.785), v05 -105.0 (0.368), r25 -78.5
(0.532), m25 -51.5 (0.699), or25 -117.8 (0.289), and25 -71.8 (0.573), or10
-53.3 (0.688), or50 -55.3 (0.675). Full-bench exchange (§5) is the reliable
ordering. Exam (60 cases): v04 0.0377, r25 0.0373, or50 0.0389, and25 0.0424,
or25 0.0433, m25 0.0449, v05 0.0449, or10 0.0455.

## 7. Gradients (Part Q)

Retained-subset grads at v0.4 (512-rows, no steps): r25 norm 1.265 cos
-0.44/-0.25/-0.24 (still conflicting); and25 1.143, -0.15/-0.02/+0.23;
m25 0.772, +0.50/+0.42/+0.48; or25 0.402, +0.22/+0.26/+0.38; or10 0.434,
+0.06/+0.29/+0.21; or50 0.378, +0.24/+0.31/+0.21. OR/M-gated mass aligns
with prior data (vs M0 B3-high which conflicted at -0.14..-0.55).

## 8. Robustness + classification (Parts R-T)

OR10 -24.8 / OR25 -108.9 / OR50 +35.2: both neighbors beat CONTROL_ALL but
the middle collapses at gate level — non-smooth => THRESHOLD_ROBUSTNESS:
NARROW. SUCCESS criteria met: 4/6 arms beat CONTROL_ALL (m25, and25, or10,
or50) and or50 recovers beyond the v0.4 region while retaining high-signal
gains (0.01915 < v0.5 0.02140). => SIGNIFICANCE_GATE_SUCCESS.
PRODUCTION THRESHOLD: NOT FROZEN (Part U).

## 9. Gates SG0-1…SG0-27

All pass (26 tests; SG0-24 is the suite itself). Per-epoch weights
unavailable by design (metrics saved); proximity secondaries (attack
opportunity, enemy distance) omitted to honor SG0-2 — skill distribution
and invalid rate come from benchmark reports instead.

## 10. Scope

New collection: NO · DAgger4: NOT STARTED · Architecture/teacher/
ValueTarget/PolicyTarget/weights unchanged · Fog/RL: NOT STARTED · Godot
gameplay: NO.

## 11. NEXT (exactly one)

Freeze a production DAgger inclusion contract from this ablation: strict-OR
significance gating (regret-or-margin at the or50 end of the tested family)
PLUS a frozen visited-distribution checkpoint-selection criterion (M0's
secondary mismatch is now the binding constraint — or25's val-winner was
its worst closed-loop seed), validated by one confirmatory from-scratch
retrain on BASE + gated-D3 with dual-criterion selection and the full
offline/closed-loop/oracle/exam chain before any Round-4 collection.

HANDOFF: D:\Game development\Demon slayer\StrategyGame\docs\JEV\SIGNIFICANCE_GATE_V0_HANDOFF.md
