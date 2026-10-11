# TARGET_DIAGNOSTIC_V0 HANDOFF — Bias vs Shift Read-Only Diagnosis

Date: 2026-09-20 · Task: determine WHY corrected-target retraining
succeeds offline (regret 0.00696, exam 0.0390) but fails closed-loop
(dM +0.473 vs +0.475, exchange -129 vs -114, Simple +22). No weight
updates, no new training corpus, no Fog labels, no RL, no contract
changes. The label below is the engineer's call from computed criteria
(metrics/criteria.json); no threshold was fitted.

---

STATUS: PASS (all 20 D0 gates green; 271/271 tests green)

PROJECT ROOT: D:\Game development\Demon slayer\StrategyGame

CHECKPOINTS (bytes pinned, unchanged): NEW
artifacts/jev_training_v1/checkpoints/seed43.pt (df97ca8e…),
OLD artifacts/jev_training_v0/checkpoints/seed43.pt (02d46c8a…).

---

## 1. STATE DISTRIBUTIONS (Part A)

60 matched scenarios (24 test + 24 train + 12 OOD), 12-turn / 64-state
caps, mask v0.2.0, both seats driven by the source policy:

- simple: 3,835 · random: 3,840 · hold: 3,840 · jev_old: 3,840 ·
  jev_new: 3,840 · iid_test: 1,531 (test-only simple rows, own file)
- iid_test state hashes match the v0.2 test shard EXACTLY in order
  (1,531/1,531, zero diffs both directions).
- Every row pins scenario seed, turn, actor, state hash, obs hash,
  source policy, trajectory step, plus full obs, 3-teacher Q, both
  models' selections, and interpretable features (hashed .pt sets).

## 2. CROSS-DISTRIBUTION REGRET, NEW JEV under Q_simple (Parts B/C)

| set | top1 | eps@0.01 | mean | median | p95 | max | entropy |
|---|---|---|---|---|---|---|---|
| iid_test | 0.411 | 0.884 | 0.00696 | 0 | 0.02701 | 0.8002 | 1.494 |
| simple | 0.417 | 0.904 | 0.00585 | 0 | 0.02493 | 0.8002 | 1.502 |
| random | 0.444 | 0.943 | 0.00203 | 0 | 0.01313 | 0.1215 | 1.352 |
| hold | 0.489 | 0.980 | 0.00064 | 0 | 0.00056 | 0.0558 | 1.315 |
| jev_old-visited | 0.369 | 0.863 | 0.00523 | 0 | 0.03408 | 0.1761 | 1.370 |
| jev_new-visited | 0.329 | 0.848 | 0.00579 | 0 | 0.03599 | 0.2237 | 1.406 |

OLD model is worse than NEW on every set (e.g. iid 0.00704/0.352,
jev_new-visited 0.00621/0.335): target correction helped on the
policy's own distribution too. Mean regret does NOT rise on
JEV-visited states (0.00579 vs 0.00696 IID, ratio 0.83) — but top1
falls 0.411→0.329, p95 rises 0.027→0.036, eps@0.01 falls 0.884→0.848.
Reason: 71–89% of states are EXACT Q ties, so mean regret is blind;
decision-relevant statistics all degrade.

## 3. TRAJECTORY DEPTH (Part J, NEW-JEV regret under Q_simple)

jev_new: 0–4: 0.00124 · 5–9: 0.00235 · 10–19: 0.00601 · 20+: 0.00665
(trend +0.00541). simple control: 0.00158 → 0.00705 (trend +0.00547).
Regret rises with depth in ALL distributions (contact develops over
time), so depth alone does not isolate JEV — but combined with the
contact-avoidance drift (§4) it shows errors accumulate where it matters.

## 4. COVARIATE SHIFT (Part I)

Largest standardized shifts, IID→JEV_NEW (Cohen's d): mean friendly
distance +0.861 (5.7→9.5), patch friendlies −0.734, min friendly
distance +0.479, mean enemy distance +0.405 (7.5→10.3), legal count
−0.390, patch enemies −0.368, min enemy distance +0.329. SIMPLE→JEV_NEW
is nearly identical. JEV visits dispersed, low-contact states with
fewer options. Attack-opportunity rate (greedy-top is ATTACK/FIRE/
HARASS): 25.9% IID → 14.8% JEV_NEW. Latent NN distance to 2,000 train
latents (512-d trunk, read-only hook, shared pool): hold 1.20 <
simple 1.27 < random 1.43 < iid 1.46 < jev_old 1.67 < jev_new 1.73;
within-train reference 1.52 — JEV latents exceed train diversity.
Shift classification: REAL distributional drift (contact + latent),
invisible to mean regret.

## 5. TEACHER DISAGREEMENT (Part D/E, 20,726 pooled states)

Simple-vs-Random: agree 0.833, Spearman 0.578, |dQ| 0.0136.
Simple-vs-Hold: agree 0.850, Spearman 0.527, |dQ| 0.0216.
Random-vs-Hold: agree 0.845, Spearman 0.567, |dQ| 0.0129.
Per-slot sign agreement only 0.34–0.57. Most sensitive classes:
ARCHER (S-vs-R 0.761) and CAVALRY (0.771–0.806); SCOUT most stable
(0.901–0.926). Most sensitive mission: hold_hq (0.792); most stable:
capture_capital (0.938). BUT cross-teacher regret means are
0.0013–0.0040 — SMALLER than JEV's own regret (0.0058–0.0070):
following a different teacher's argmax costs less than JEV's
deviations. Rankings differ; the cost does not. Teacher dependence
is real but NOT the dominant lever.

## 6. JEV ROBUSTNESS (Part F, NEW-JEV selection regret per teacher)

On jev_new: under-Simple 0.00579, under-Random 0.00552, under-Hold
0.00286; worst-teacher 0.00960, mean-of-teachers 0.00472. No teacher
makes JEV look good or bad — the policy is equally (im)precise under
all three, confirming the failure is not teacher-relative.

## 7. TARGET CANDIDATES (Part G/H, frozen PolicyTargetV0, no fitting)

Per-set entropy A/B/C ≈ 1.24–1.31 / 1.27–1.36 / 1.30–1.38 (mild
uniformization). Top-action change A→B: 0.104 jev_new, 0.143 iid,
0.147 simple (near-tie flips). JSD mean: iid 0.0824, simple 0.0837,
jev_new 0.0668, hold 0.0245. Full teacher agreement (3/3): 69–92%
of states. High-disagreement share (JSD>0.10): 29% jev_new, 33% iid.
Disagreement is measurable and concentrated off-HOLD — yet §8 shows
averaging it away does NOT help closed-loop, so no candidate is
declared superior here.

## 8. COUNTERFACTUAL ORACLE CLOSED LOOP (Parts K/L, 6 matched scenarios)

Blue vs Simple red, means (dM / exchange): GreedySimple +0.333 / −2.8 ·
Greedy2Teacher +0.333 / −52.5 · NEW JEV +0.333 / −164.5 · Simple
+0.457 / −129.2. Greedy-Q beats JEV on exchange 6/6 battles with
identical mission progress; the 2-teacher oracle is worse than the
Simple oracle. INVALID executions: 0 everywhere. The current
Simple-Q target's argmax contains GOOD closed-loop signal — the
trained policy fails to realize it. Robust aggregation is disproven
as the fix before any retraining run.

## 9. ROOT CAUSE: COVARIATE_SHIFT

Systematic passive-selection bias → contact-avoiding drift →
attrition, invisible to mean regret because 71–89% of states are
exact Q ties:

1. JEV-visited regret is NOT elevated in the mean (0.0058 vs 0.0070),
   but top1 (0.41→0.33), p95 (0.027→0.036), and eps@0.01 degrade.
2. JEV drifts where contact is scarce: attack-opportunity 26%→15%,
   enemies +0.4σ farther, latent NN 1.46→1.73 (beyond train ref 1.52).
3. Errors are SYSTEMATIC, not noise: on JEV-visited SCOUT states JEV
   plays EVADE 81% vs greedy 1%, RECON_ADVANCE 2% vs greedy 95%;
   it misses ~47% of greedy attacks on its own states.
4. The teacher knows the recovery: greedy's top picks ON JEV-VISITED
   states are engaging actions (RECON_ADVANCE/ADVANCE/ATTACK), and
   greedy closed-loop beats JEV 6/6 on exchange (−3 vs −165).
5. Continuation bias ruled out as dominant: cross-teacher regret
   (≤0.004) < JEV regret, and the robust oracle underperforms the
   Simple oracle (−53 vs −3).

EVIDENCE (all in metrics/criteria.json + §2–§8 artifacts):
visited/IID regret ratio 0.83; depth trend +0.0054 (control +0.0055);
cross-teacher means 0.0013–0.0040; JSD 0.067/0.082; oracle exchange
−2.8 vs JEV −164.5, dM tied; INVALID 0.

## 10. ACCEPTANCE GATES D0-1…D0-20 — ALL PASS (20 tests)

D0-1 six sets pinned+verified · D0-2 bytes pinned, no weight-update
identifiers · D0-3/4 old+new on all sets · D0-5 3-teacher Q, finite on
legal, NaN off legal · D0-6 six directed cross-regrets · D0-7
robustness + worst/mean · D0-8 A/B/C constructed · D0-9 JSD +
agreement counts · D0-10 27 features + Cohen's d ×2 pairs · D0-11
latent NN + reference · D0-12 four depth buckets + trend · D0-13/14
both oracles + matched references · D0-15 zero INVALID (20,726 trial
executions + oracle battles) · D0-16 prior artifacts verify ·
D0-17 all rows full-info, Q present · D0-18 no RL identifiers ·
D0-19 classification emitted, evidence == criteria.json · D0-20
exactly one NEXT.

TESTS: 271 passed (N0 34, R0 36, S0 29, J1 73, V0 19, T0 17, F0 22,
R1 21, D0 20).

## 11. SCOPE CHECK

Training: NOT STARTED · Weights changed: NO (both seed43 bytes
pinned) · Dataset aggregation: NOT STARTED · Fog training: NOT
STARTED (0 partial rows) · RL: NOT STARTED · Self-play: NOT STARTED ·
Godot gameplay rewrite: NO.

## 12. CHANGED FILES (all under the project root; additive only)

NEW python_jev/diagnose/: __init__.py, collect.py, teachers.py,
shift.py, oracles.py, run_diagnostic.py
NEW python_jev/tests/test_d0_diagnostic.py
NEW artifacts/jev_target_diagnostic_v0/: distributions/{simple,
random, hold, jev_old, jev_new, iid_test}.pt + manifest.json,
teacher_matrix/{matrix, cross_regret, robustness}.json,
candidate_targets/candidates.json, covariate_shift/{features,
latent}.json, trajectory_depth/depth.json,
oracle_closedloop/report.json,
metrics/{cross_dist, criteria, classification}.json
NEW docs/JEV/TARGET_DIAGNOSTIC_V0_HANDOFF.md (this file)

HANDOFF: D:\Game development\Demon slayer\StrategyGame\docs\JEV\TARGET_DIAGNOSTIC_V0_HANDOFF.md

## 13. NEXT (exactly one evidence-driven task)

DAgger-style supervised state aggregation: run JEV closed-loop,
collect the states it actually visits, label them with
Simple-continuation counterfactual Q under mask v0.2.0, append to
the supervised corpus, and retrain from scratch. No
continuation-robust relabeling (disproven by the oracle test), no
reward-gradient RL.
