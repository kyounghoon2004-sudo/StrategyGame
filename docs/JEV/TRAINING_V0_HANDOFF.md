# TRAINING_V0 HANDOFF — First Supervised JevPolicyV0 Run

Date: 2026-09-20 · Task: first real supervised training of JevPolicyV0 from
six-way counterfactual rollout values (ValueTargetV0 Q → PolicyTargetV0 soft
targets). No RL, no self-play, no Fog training, no Godot changes.

---

STATUS: PASS (with evidence-driven caveats — see §§8–9; all 28 T Gates green)

PROJECT ROOT: D:\Game development\Demon slayer\StrategyGame

---

## 1. POLICY TARGET (Part A)

- version: policy-target-v0.1.0
- hash: e509c79bc21bf4ecc80168025abac4458678498ba75125ebf07aa4a50b41d7d3
- temperature: 1.0 · std_epsilon: 1e-6 · z_clip: [-3,+3]
- procedure: center legal Q by legal mean → divide by legal std (0 if
  std ≤ 1e-6) → clip → softmax; illegal slots exactly 0.0; legal mass
  renormalized to 1. Equal legal Q → uniform over legal. No one-hot collapse.
- loss: masked soft-target cross entropy over legal slots only.
- module: `python_jev/training/policy_target.py`

## 2. DATASET (Part B)

- version: jev-fullinfo-dataset-v0.1.0
- records: 12,278 primary (train 9,212 / validation 1,535 / test 1,531)
  + 3,065 generalization_test (OOD families, test-only)
- scenarios: 192 (144/24/24) + 48 OOD; split is scenario-first, zero leakage
- class distribution (train): INFANTRY 1615, SPEARMAN 1850, CAVALRY 1909,
  ARCHER 1749, SCOUT 2089 (17.5–22.7%, no severe imbalance)
- profile distribution (train): DEV_FLAT_ALL_INFO 4288, TERRAIN_FULL_INFO 4924
- missions (train): destroy_all_red 4096, hold_hq 3260, survive_turns 1024,
  capture_capital 832 (TERRAIN-only family)
- ratio groups (train): inferior 2876, parity 2880, superior 3456
- spacing: close 2880, standard 2876, far 3456 · turns 1–11 · 12 IID families
- generation: 48.0 s wall, 319.6 states/s (12 workers, 24-core CPU)
- hashes: dataset 51dd4c3b…; shards train 48beb94e…, validation 0aba5d92…,
  test 04c393a1…, generalization_test c3a8bd05…
- format: .pt shards (float32 tensors + provenance) + manifest.json +
  audit/audit_sample.jsonl (40 human-readable records)
- continuation (canonical v0 training): SimpleAttackElseAdvancePolicy,
  continuation-policies-v0.1.1 (see §10 bugfix), horizon 8 decisions

TARGET DIAGNOSTICS (train):
- Q range [-0.370, +1.337], mean 0.0096, std 0.083 — all non-terminal
  (no T=±1 reached within horizon 8 of sampled states; signal is M/E/O shaped)
- target entropy mean 1.387 nats (uniform-over-5.38 would be 1.68)
- legal/state mean 5.38 · non-tied states ≈ 61% · tied (uniform) ≈ 39%
  (honest pre-contact ties, not collapse)
- all 30 class-slot identities: min legal count 801 (INF ATTACK); every
  identity mean_p_target ≥ 0.089 (full table: metrics/coverage_report.json)
- best-slot concentration per class 0.31–0.65 (no dominance collapse)
- horizon stability (160 diagnostic states): h4 top-agree 0.863 / h12 0.888
  vs primary h8; Spearman 0.615 / 0.856; mean|ΔQ| 0.0205 / 0.0054
- continuation sensitivity: RandomLegal top-agree 0.713, Spearman 0.477,
  mean|ΔQ| 0.0190, preference KL 0.315 (alternate labels never trained on)

## 3. TINY OVERFIT (Part C) — T0-11 PASS

128 examples, 150 epochs: loss 1.7428 → 1.4073, landing exactly on the
target-entropy floor (1.4072); KL 0.3356 → 0.0001; regret 0.01309 → 0.00002.
Criterion note: the first gate run "failed" only because its pass threshold
(loss < 0.25) ignored the soft-target entropy floor — the model had already
fit the tiny set (KL≈0). The gate now asserts KL→~0 + regret→~0 + loss→floor.

## 4. TRAINING (Part D)

- model: JevPolicyV0, 1,014,430 params (architecture untouched)
- device: CUDA, NVIDIA GeForce RTX 5090 Laptop GPU · dtype float32
- optimizer: AdamW, lr 3e-4, wd 1e-4, grad-clip 1.0, no scheduler
- batch 256 · max 30 epochs · patience 5 on validation policy loss
- multi-seed: 42 (best ep 2, val 1.6434, 8 ep, 8.5 s),
  43 (best ep 3, val 1.6422, 9 ep, 8.9 s),
  44 (best ep 2, val 1.6453, 8 ep, 7.5 s)
- ~9k samples/s · peak VRAM 0.24 GB
- SELECTED: seed 43 (lowest validation policy loss; near-tie ±0.003 noted,
  val/test rank flips — seed42 is best on test — reported, not acted on)

## 5. OFFLINE BENCHMARK (Part E) — selected seed43, held-out test

| | loss | KL | top1 | top2 | eps-opt | regret mean/med/p95 | rawIll | maskIll | H | ECE |
|---|---|---|---|---|---|---|---|---|---|---|
| untrained | 1.7117 | 0.3154 | 0.176 | 0.368 | 0.997 | 0.01042/0/0.04608 | 0.159 | 0.000 | 1.615 | 0.725 |
| seed43 test | 1.6150 | 0.2188 | 0.338 | 0.499 | 0.997 | 0.00712/0/0.03137 | 0.332 | 0.000 | 1.595 | 0.716 |

- T0-15/16: val loss 1.736→1.642 and val regret 0.0110→0.0073 improve materially.
- T0-17: masked-path illegal rate = 0.000 exactly (all splits, all seeds).
  Raw-logit argmax illegality rises with training (0.16→0.33) — a known
  masked-softmax artifact (illegal logits get no gradient); the deployed
  masked path is unaffected. Reported as a diagnostic, not the gate.
- eps-optimal ≈ 0.997 for trained AND untrained: q_epsilon=0.25 (frozen)
  dwarfs realized non-terminal Q gaps (~0.01), saturating the metric. Kept
  frozen; regret and top-k carry the signal instead.
- per-class (test): INF top1 0.687 reg 0.0083 · SPR 0.437/0.0056 ·
  CAV 0.232/0.0096 · ARC 0.240/0.0050 · SCT 0.252/0.0059 (all classes learn;
  untrained INF top1 0.62 is modal-action luck — ADVANCE is best 63%).
- per-profile (test): DEV loss 1.6031/top1 0.349 vs TERRAIN 1.6252/0.328 —
  terrain representation yields no measurable offline edge yet.
- full tables: metrics/offline.json

## 6. CLOSED-LOOP (Part F) — seed43, 24 scenarios × 3 baselines × side-swap

- vs Random: JEV win 0.23 · vs Simple: 0.25 · vs Hold: 0.23
- JEV-blue wins 0.46 in every pairing; JEV-red wins 0.00–0.04
- mission completed 0.46–0.48, expired 0.52–0.54, turns ≈ 13.8
- invalid execution rate 0.33–0.36 (mostly scout EVADE NO_SAFE_ROUTE and
  ADVANCE NO_DESTINATION — consequences of top1≈0.34 argmax error, not a
  driver bug; training branches fail only ≈7%)
- Structural finding: RED-side victories are nearly impossible in this
  scenario/mission mix (blue HQ never dies; 3 of 4 mission types are
  blue-favoring; defeat occurred once in 144 battles), so side-swap
  comparisons measure JEV-blue ≈ baseline-blue (both 0.46).
- HEADLINE: offline top1 0.34 does not yet convert to a closed-loop edge.
  This is the evidence for NEXT (§11).
- full rows: benchmark/closedloop.json

## 7. GENERALIZATION + EXAM (Part G)

- OOD offline (seed43): loss 1.6157 vs IID test 1.6150 (Δ +0.0007);
  regret 0.00604 vs 0.00712 (OOD better); top1 0.329 vs 0.338 — no
  distribution-shift degradation at this competence level.
- closed-loop OOD: win 0.17–0.21 vs IID 0.29 (small gap; same red-cant-win
  structure); expired higher (0.62–0.67).
- Tactical exam (60 cases): trained regret 0.0441 vs untrained 0.0758
  (42% cut); median 0 vs 0.057; eps-opt 0.95 both; per-class all ≤ 0.091
  (INF highest); weakest themes: retreat_ground/screen_line/threatened (0.80).
- benchmark/exam.json

## 8. CHECKPOINTS / CALIBRATION / PERFORMANCE (Part H)

- checkpoints/seed{42,43,44}.pt — jev-policy-v0.1.0-fi, full_information_only,
  all contract pins (ruleset/obs/skill/rollout/terminal/mission/objective/
  branch-snapshot/value/policy-target/training-config/dataset hashes)
- T0-26: reload bit-identical (torch.equal, committed test + real checkpoint)
- calibration (measured only): ECE 0.716 (frozen eps-correctness, saturated);
  confidence concentrates 0.2–0.35 and tracks top-1 accuracy
  (0.26→0.83 across bins — bins: metrics/calibration_bins.json). No rescaling.
- perf: dataset 48 s / 320 states/s · training ~9 s/seed / ~9k samples/s ·
  peak VRAM 0.24 GB · inference batch1 3.01 ms / batch32 2.83 ms (CUDA)

## 9. ACCEPTANCE GATES T0-1…T0-28

ALL PASS. T0-1/2/3 PolicyTarget tests · T0-4 zero leakage (144/24/24) ·
T0-5 12,278 ∈ [10k,15k] · T0-6 five classes, max/min < 3 ·
T0-7 30/30 identities ≥ 800 legal (gate asserts ≥ 50 + mean_p > 0.05) ·
T0-8 determinism (byte-identical recollection) · T0-9 no NaN/Inf, masks exact ·
T0-10 fog records 0 · T0-11 overfit PASS · T0-12 untrained baseline captured ·
T0-13/14 three seeds complete · T0-15/16 val loss+regret improve ·
T0-17 masked illegal rate 0 · T0-18 test used only post-selection ·
T0-19/20 per-class/per-profile tables · T0-21/22 closed-loop + side-swap ·
T0-23 OOD benchmark · T0-24 exam · T0-25 calibration measured ·
T0-26 reload PASS · T0-27 208 green (N0 34, R0 36, S0 29, J1 73, V0 19,
T0 17; V0-20 scope-migrated, see §10) · T0-28 scope clean (no RL/self-play/
Fog/Godot; V0-20 guard enforces it in-tree).

## 10. BUGFIXES TO EXISTING CODE (both verified, J1-§9 precedent)

1. **Continuation flee bug** (`python_sim/policies/__init__.py` +
   `CONTINUATION_POLICY_VERSION` → continuation-policies-v0.1.1):
   `_best_step` minimized (-dist, cost, key), maximizing enemy distance —
   every unit fled to the world edge, no battle ever made contact, 98.6%
   of counterfactual Q tied, ATTACK legal in 0/9215 states. Now minimizes
   (dist, cost, key) per its own docstring. Post-fix: contact turn 2,
   attack-legal 61%, non-tied 61%, Q ∈ [-0.37,+1.34]. All 191 regressions
   green without modification (no test depended on flee direction).
2. **V0-20 scope migration** (`python_sim/tests/test_v0_value.py`, test-only):
   the "no training exists" guard now authorizes `python_jev/training/` +
   T0 tests while still forbidding training elsewhere and RL/self-play
   identifiers in all non-test sources. Analogous to the V0 J1-13/14/15 flip.
3. `shard_hash` element-wise `bytes(UntypedStorage)` → numpy bulk path
   (61 s → ms; new file, no contract impact).
4. Pilot artifact `artifacts/j1_pilot_dataset.jsonl` regenerated under the
   fixed continuation (20 records, all classes/skills; no test pins it).

## 11. SCOPE CHECK

RL: NOT STARTED · Self-play: NOT STARTED · PPO/DQN: NOT USED ·
Fog training: NOT STARTED (0 partial-info samples; guard in-tree) ·
Godot gameplay rewrite: NO (15 pre-existing .gd/.tscn modifications untouched,
all dated before this session; git trees otherwise additive-only).

## 12. CHANGED FILES (task-attributable; repo trees are untracked-held)

NEW `python_jev/training/`: __init__.py, policy_target.py, scenarios.py,
dataset_gen.py, data.py, train.py, evaluate.py, checkpoint.py, inference.py,
closedloop.py, diagnostics.py, exam.py, coverage.py, overfit_gate.py,
run_training.py, run_benchmarks.py
NEW `python_jev/tests/test_t0_training.py` (17 gates)
EDIT `python_sim/policies/__init__.py` (flee fix),
`python_sim/rollout/config.py` (v0.1.1),
`python_sim/tests/test_v0_value.py` (V0-20 migration)
NEW artifacts/jev_training_v0/{dataset/{train,validation,test,
generalization_test}.pt,manifest.json},audit/audit_sample.jsonl,
metrics/{coverage_report.json,rollout_diagnostics.json,tiny_overfit.json,
training_history.json,offline.json,calibration_bins.json},
checkpoints/seed{42,43,44}.pt,benchmark/{exam.json,closedloop.json}}
REGEN artifacts/j1_pilot_dataset.jsonl
NEW docs/JEV/TRAINING_V0_HANDOFF.md (this file)

HANDOFF: D:\Game development\Demon slayer\StrategyGame\docs\JEV\TRAINING_V0_HANDOFF.md

## 13. NEXT (one evidence-driven task)

**Close the offline→closed-loop gap before any Fog/RL work:** offline top1
0.34 with 33% failing argmax picks yields JEV-blue 0.46 = baseline-blue —
the model cannot yet convert Q-matching into battle wins. Next task:
(1) add an execution-aware Q audit (which mask-legal skills fail, by
class/slot/state), (2) test whether training on executable-subset targets
or a small invalid-avoidance auxiliary head restores closed-loop edge,
(3) rebalance the mission mix so RED can win (red-offensive missions),
without touching frozen ruleset/observation/skill contracts.
