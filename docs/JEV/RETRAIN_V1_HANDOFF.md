# RETRAIN_V1 HANDOFF — Corrected-Target Supervised Retraining

Date: 2026-09-20 · Task: controlled retraining experiment on mechanically
correct targets (SkillPreflightV0 / observation-safe-skill-mask-v0.2.0).
One factor changed (legality mask); architecture, ValueTargetV0,
PolicyTargetV0 transform, horizon, continuation teacher, optimizer, LR,
batch size, scenario splits, and training seeds all identical to T0.
No Fog training, no RL, no self-play, no architecture change, no Godot change.

---

STATUS: PASS (training experiment complete; policy-quality verdict FAIL —
see §§6,10; all 23 R gates green)

PROJECT ROOT: D:\Game development\Demon slayer\StrategyGame

---

## 1. DATASET CORRECTION (Part A) — jev-fullinfo-dataset-v0.2.0

- old version: jev-fullinfo-dataset-v0.1.0 (15,343 records, byte-unchanged)
- new version: jev-fullinfo-dataset-v0.2.0 (15,325 records; 18 dropped)
- old combined hash: 7b0a80089cf01dc03aa9e5084460dd9b46e2ce85eac16ddea43fc1021ab640c5
- new combined hash: 5e8b2ce24a488008… (full: metrics/training_history.json)
- new target hash: ba923242538610899850901eb39a6d62b43f086cffb5b5f75563663fbf7d5698
- reconstruction wall: 108.0 s single-process (replay + rollouts + assembly)

Replay matched 15,343/15,343 records with 0 state_hash mismatches and
reproduced the F0 audit EXACTLY: 5,643 mask-changed records, 6,947 lost
Q-valid branches, 1,139 gained branches (all SCOUT slot1 SHADOW — asserted).

- records affected: 5,643 (36.8%); 5,625 kept + 18 dropped
- branches removed: 6,947 (6,875 in kept records + 72 in dropped records)
- branches added: 1,139 SHADOW Q via single-branch deterministic rollout
  (frozen ValueTargetV0, SimpleAttackElseAdvance continuation, horizon 8)
- target top-action flips: 1,629 / 15,325 = 10.6% (F0 no-sim estimate 9.8%)
- mean P_target L1 delta: 0.1763 (max 1.6406)
- target entropy: 1.3891 -> 1.2987 (delta -0.0904); legal/state 5.38 -> 5.01

Per-class (total/changed/removed/added/flip_rate/mean_L1):
ARCHER 3010/1519/3083/0/0.191/0.344 · CAVALRY 3311/1243/1486/0/0.242/0.180 ·
INFANTRY 2565/466/542/0/0.019/0.069 · SCOUT 3469/1546/557/1139/0.039/0.154 ·
SPEARMAN 2970/851/1207/0/0.022/0.120.

Spotlight (lost/gained): ARCHER KITE 1454/0 · CAVALRY FLANK 1018/0(+6 in
dropped) · SCOUT EVADE 2/0(+12 in dropped) · SCOUT SHADOW 0/1139.

Dropped (18, all train: SCOUT 12 + CAVALRY 6): states with ZERO executable
branches under the corrected mask — no target distribution exists, so they
are honestly excluded (collection skip-rule analogue), listed by key in
dataset_delta/delta_report.json. Test/val/gen splits keep full counts.

Reused-Q audit: 800 old-legal branches presampled (seed 20260920); 752
remained legal and ALL match stored Q bit-exactly (max_abs_diff 0.0).
10 full-engine cross-checks: stored-vs-full and single-vs-full diffs all 0.0.
No fake low Q anywhere; illegal P exactly 0.

## 2. COVERAGE (Part B)

Train per-action (legal/best/mean_p/mean_q/median_q/q_std), spotlight:
KITE 905/108/0.253/0.036/0.012/0.129 · FLANK 1339/467/0.151/0.012/0.0/0.097 ·
EVADE 2077/1/0.164/0.003/0.0/0.055 · SHADOW 1980/34/0.158/0.004/0.0/0.058 ·
INF ATTACK 801/388/0.275/0.029/0.003/0.137 (minimum legal count, unchanged —
attack bits never move). Dead: none. Rare (<50 or mean_p<0.05): none.
Best-concentration: no dominance >0.9. Decision: KEEP_DISTRIBUTION (no
rebalance; scenario assignments preserved exactly, zero leakage, 0 fog
records). Note: EVADE is argmax-best once in 9,194 train rows — under the
Simple teacher it is nearly never optimal; a target-design observation,
not a mask defect.

## 3. TINY OVERFIT + TRAINING (Part C)

Tiny gate (128 corrected samples, CPU): loss 1.6463 -> 1.2825 vs entropy
floor 1.2809; KL 0.0012; regret 0.00001. PASS.

From-scratch training (AdamW lr 3e-4 wd 1e-4 clip 1.0 batch 256 float32,
30 epochs max, patience 5 on val policy loss, no scheduler, CPU):
seed42 best-ep3 val 1.5474 (9 ep, 31.9 s) · seed43 best-ep3 val 1.5420
(9 ep, 31.5 s) · seed44 best-ep2 val 1.5425 (8 ep, 29.2 s).
SELECTED: seed43 (lowest val loss; seed42 is test-regret-best — reported,
not acted on, per the frozen selection rule).
Checkpoints: jev-policy-v0.2.0-fi, full_information_only, init=from_scratch,
1,014,430 params, state keys/shapes identical to v0.1.0-fi (R1-20).

## 4. CORRECTED HELD-OUT (Part D, v0.2 test shard 3a5f5de5…, 1,531 rows)

OLD seed43: loss 1.5142 · KL 0.2088 · top1 0.352 · top2 0.523 ·
  eps@0.25 0.9967 · eps@0.01 0.8759 · regret 0.00704 · p95 0.03085 ·
  entropy 1.497 · ECE 0.681
NEW seed43: loss 1.5109 · KL 0.2056 · top1 0.411 · top2 0.569 ·
  eps@0.25 0.9961 · eps@0.01 0.8837 · regret 0.00696 · p95 0.02693 ·
  entropy 1.494 · ECE 0.679
NEW seed42: loss 1.5155 · regret 0.00548 · p95 0.02577 · top1 0.372 ·
  eps@0.01 0.8811 (test-regret-best)
NEW seed44: loss 1.5145 · regret 0.00663 · p95 0.03008 · top1 0.315 ·
  eps@0.01 0.8635
Untrained: loss 1.6184 · regret 0.01015 · top1 0.189 · eps@0.01 0.7727

Per-class regret/top1 old->new: INF 0.00822/0.691 -> 0.01079/0.574 (worse) ·
SPR 0.00539/0.455 -> 0.00463/0.632 · CAV 0.00951/0.265 -> 0.00816/0.510 ·
ARC 0.00499/0.252 -> 0.00436/0.213 · SCT 0.00593/0.252 -> 0.00647/0.202.
Aggregate gains are real but modest and class-mixed (reported, not hidden).
Masked-path illegal rate 0.000 everywhere; mechanical selected-INVALID rate
on 2,299 replayed held-out states: NEW 0.0000, OLD 0.0000 (R1-13 PASS).

## 5. CLOSED-LOOP SAME-SEAT BLUE (Part E, 24 matched scenarios, mask v0.2.0)

Blue vs fixed Simple red (vict/def/exp · dM · exchange · turns · invalid):
- NEW JEV: 0.458/0.000/0.542 · +0.4726 · -128.8 · 13.8 · 0.000
- OLD JEV: 0.458/0.000/0.542 · +0.4750 · -114.1 · 13.8 · 0.000
- Simple: 0.458/0.083/0.458 · +0.5809 · +22.0 · 13.5
- Random: 0.458/0.000/0.542 · +0.4583 · -56.5 · 13.8
- Hold: 0.458/0.000/0.542 · +0.4583 · -83.9 · 13.8
Objective progress delta 0.000 everywhere (O=0 live, as in F0).
Baselines bit-identical across both runs (matched-proof True). OLD numbers
reproduce F0 v1_new_mask exactly (dM +0.475, exch -114.1).
Secondary: JEV-vs-Hold-red exch NEW +142.4 vs OLD +104.0; JEV-vs-Random-red
+13.3 vs +17.9; JEV-red descriptive dM +0.5012 vs +0.4997 (no terminal
claims). No side-swapped win-rate claim anywhere (INVALID pinned).

POLICY QUALITY DELTA (NEW-OLD): mission progress -0.0024 (flat) · casualty
exchange -14.75 (worse) · tactical exam regret -0.0041 (slightly better).
The Simple gap is NOT closed (NEW-vs-Simple dM -0.108, exch -150.9).

## 6. VERDICTS

TRAINING SUCCESS: PASS (dataset valid · val loss 1.618->1.542 · held-out
regret beats untrained on all seeds · INVALID = 0).
POLICY QUALITY SUCCESS: FAIL (no material closed-loop improvement over old
seed43 on mission progress or casualty exchange; exam gain is small).
Per Part J this implicates counterfactual-target / continuation-policy
bias — NOT mechanical feasibility (already at zero invalid).

## 7. TACTICAL EXAM (Part G, same 60 cases, mask v0.2.0)

Untrained regret 0.0768 (p95 0.3126) · old 0.0431 (p95 0.2543) · new 0.0390
(p95 0.2543). Per-class old->new: INF 0.0813->0.0631 · SCT 0.0442->0.0421 ·
ARC/CAV/SPR unchanged (0.0327/0.0275/0.0296). Selections changed 12/60,
10 of them SCOUT (the SHADOW-corrected class). Old-on-new-mask reproduces
the F0 exam rerun exactly (0.0431).

## 8. CONTINUATION SENSITIVITY (Part F, corrected mask, 320 states)

Q-rank diagnostic: Simple-vs-Random agree 0.803 / Spearman 0.478 / |dQ|
0.0171 (F0 old-mask: 0.791/0.497/0.0170) · Simple-vs-Hold 0.872/0.431/0.0224
(F0: 0.822/0.426/0.0225) · Random-vs-Hold 0.813/0.505/0.0140. ARCHER still
most teacher-sensitive (Simple-vs-Random 0.66); CAVALRY 0.79-0.82.
New-policy alignment with each teacher's top-Q: Simple 0.419, Random 0.394,
Hold 0.434 — FLAT, no disproportionate Simple mimicry. By class: CAV/INF
~0.65-0.70, ARC ~0.32, SCT ~0.10 (scout selections match no teacher).

## 9. ACCEPTANCE GATES R1-1…R1-23 — ALL PASS (21 tests)

R1-1 v0.1 bytes pinned+verified · R1-2 v0.2 shards verified · R1-3 5,625
kept-changed + 18 dropped = 5,643 · R1-4 6,875 + 72 = 6,947 removed ·
R1-5 1,139 SHADOW added · R1-6 audit max_diff 0.0 + live spot re-sim ·
R1-7 targets renormalize, transform hash pinned · R1-8 illegal P = 0 ·
R1-9 coverage adequate, KEEP · R1-10 overfit PASS · R1-11 3 from-scratch
seeds · R1-12 one shared corrected held-out · R1-13 INVALID = 0 ·
R1-14 same-seat used · R1-15 no side-swap claim · R1-16/17 dM+exchange ·
R1-18 exam · R1-19 sensitivity+alignment · R1-20 suite green +
architecture-identical · R1-21/22 no Fog/RL (0 partial records, source scan,
ValueTarget frozen) · R1-23 no .gd/.tscn markers.

TESTS: 251 passed (N0 34, R0 36, S0 29, J1 73, V0 19, T0 17, F0 22, R1 21).

## 10. SCOPE CHECK

RL: NOT STARTED · Self-play: NOT STARTED · Fog training: 0 samples,
0 oracle labels · Architecture change: NO (1,014,430 params, keys/shapes
identical) · ValueTarget: UNCHANGED (v0.1.0, hash-verified) · Godot
gameplay rewrite: NO. v0.1.0 source shards + seed43 checkpoint bytes intact.

## 11. CHANGED FILES

NEW python_jev/retrain/: __init__.py, dataset_v2.py, rebuild_v2.py,
data_v2.py, eval_v1.py, closedloop_v1.py, run_retrain.py
NEW python_jev/tests/test_r1_retrain.py (21 gates)
EDIT (additive optional hooks only): python_jev/training/{train,
overfit_gate, evaluate, coverage, checkpoint}.py,
python_jev/feasibility/{sensitivity, epsilon_audit}.py
NEW artifacts/jev_training_v1/: dataset/{train,validation,test,
generalization_test}.pt + manifest.json, dataset_delta/{delta_report,
new_branch_rollouts}.json, audit/{reused_q_audit.json, audit_sample.jsonl,
v01_immutability.json}, metrics/{coverage_report, tiny_overfit,
training_history, offline, offline_invalid}.json, closedloop/{v1_new_model,
v1_old_model, same_seat_comparison}.json, exam/exam.json,
sensitivity/sensitivity.json
NEW docs/JEV/RETRAIN_V1_HANDOFF.md (this file)
(All paths under D:\Game development\Demon slayer\StrategyGame.)

HANDOFF: D:\Game development\Demon slayer\StrategyGame\docs\JEV\RETRAIN_V1_HANDOFF.md

## 12. NEXT (one evidence-driven task)

**Redesign rollout targets for continuation robustness:** mechanical
feasibility is solved (INVALID = 0) yet corrected-target retraining yields
only small offline gains and zero closed-loop gain, with Q-rankings still
~20% teacher-sensitive and scout preferences matching no teacher. Next:
build continuation-robust targets (e.g. multi-continuation agreement
filtering or regret-vs-ensemble teachers) and re-run this same controlled
protocol — without touching mask v0.2.0, ValueTargetV0, or the architecture.
