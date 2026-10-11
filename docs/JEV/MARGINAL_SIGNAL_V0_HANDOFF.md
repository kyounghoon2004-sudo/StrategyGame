# MARGINAL_SIGNAL_V0 HANDOFF — Why DAgger Round 3 Hurt v0.5

Date: 2026-09-20 · Experiment: marginal-signal-audit-v0.1.0 (diagnostic only)

STATUS: PASS — root cause isolated with quantitative evidence; no production
training, no dataset v0.6, no DAgger4, no architecture/teacher/ValueTarget/
PolicyTarget changes. All 357 existing tests green; both checkpoints
byte-identical (v0.4 seed44 sha256 `18ec1162…c0cc` re-verified).

PROJECT ROOT: D:\Game development\Demon slayer\StrategyGame

## 1. Verdict

PRIMARY: MARGINAL_SIGNAL_EXHAUSTION

SECONDARY: MODEL_SELECTION_MISMATCH (IID-val selection anti-correlates with
visited/exam within v0.5 seeds); LONG_HORIZON_TARGET_AMBIGUITY (minor: 85%
h8-h12 argmax agreement, 22% low-margin flip).

REJECTED: LABEL_CONFLICT (close neighbors agree; 11/5408 conflicts),
POLICY_TARGET_AMPLIFICATION (true amplification 0.3%; targets diffuse, not
over-confident), REPRESENTATION_LIMIT (both balanced pools reach entropy
floor, KL ~0.011).

MIXED: GRADIENT_INTERFERENCE — the D3-high slice conflicts with all prior
data (cosine -0.14 to -0.39, -0.55 vs D3-low) but holds only 9% of gradient
opportunity; D3-low aligns (+0.35 to +0.66). The harm is dilution/washout,
not a gradient war.

## 2. Mechanism (one paragraph)

Round-3 novel states are 77.1% exact Q-ties (up from ~73%), and 84.6% of the
headline 59% policy/teacher disagreement is argmax coin-flips on those ties.
Soft targets on ties are diffuse (51.8% exactly uniform via the std floor),
so fitting the 4,586 low-signal rows taught v0.5 to break ties diffusely,
washing out v0.4's sharp RECON-leaning scout tie-break: scout argmax went
RECON 777→181, SHADOW 1→464, REGROUP 0→94, while mean probability mass barely
moved (RECON 0.253→0.235, SHADOW 0.123→0.138). Horizon-8 Q cannot see the
difference (S4 scout regret flat 0.0004), but closed loop punishes
SHADOW/REGROUP tie-breaking through contact avoidance (exchange -3.6→-37.1).
The genuine correction (519 meaningful/large-regret rows, 9% of gradient
opportunity) was too diluted to compensate, and IID-val selection picked the
v0.5 seed worst on visited/exam. Note the prior "teacher RECON 94.7%" is
itself a tie artifact: 1,291/1,296 teacher-RECON scout tops are exact ties
resolving to slot 0 (RECON), with mean teacher top-probability only 0.238.

## 3. Evidence by part

A. Margins (D3 novel, n=5408): mean 0.00414, median/p25/p75 = 0, p90 0.0159,
p95 0.028, p99 0.052. Bucket [0,0.001) holds 4,254 states (78.7%) at 64.7%
disagreement, mean regret 0.0018. (`margins/margin_by_round.json`,
`margins/dagger3_buckets.json`)

B. Disagreement value: near-tie 74.3% (2,372), small 9.5% (303), meaningful
8.7% (279), large 7.5% (240). (`margins/disagreement_value.json`,
`margins/tie_conditional.json`)

C. Round decay: mean margin 0.00536→0.00525→0.00414; mean regret
0.00491→0.00397→0.00311; total correction (sum regret) 29.69→24.02→16.84;
meaningful+large rows 822→733→519; tie fraction 73.4%→73.2%→77.1%.

D. Skill signal: only 7 teacher-SHADOW and 1 driver-SHADOW scout states vs
464 v0.5 SHADOW selections; teacher SHADOW margin 0.0024, p 0.48 — the surge
is mass-scatter among near-ties, not teacher support. Cavalry FLANK:
295 teacher states (margin 0.0029) vs 1 driver / 12 v0.5 selections.
(`margins/skill_signal.json`, `margins/scout_mechanism.json`)

E. Target geometry: raw<0.001 with target-gap>0.2 in 18 states (0.33%);
raw<0.0025 with gap>0.2 in 63 (1.2%). High top-p at low raw margin is
tied-top splitting (gap 0), not z-amplification. (`margins/target_geometry.json`)

F. Sensitivity (deterministic ±noise): argmax flip 36.1%/36.7%/38.1% at
±0.0005/0.001/0.0025; mean L1 0.40/0.43/0.49; JS 0.046/0.048/0.054.
Perturbations manufacture winners out of ties — argmax identity is fragile,
soft-target response is honest. (`target_sensitivity/sensitivity.json`)

G. Neighbors (prior 21,290): NN1 median obs distance 2.20 — D3 states are
not near-duplicates. Close set (271, d≤0.22): argmax conflict 3.7%, mean JS
0.0077. 11 conflicts total. (`neighbor_conflicts/`)

H. Aliasing: 3 explained (legal/class differ), 3 near-tie noise, 5 aliasing
candidates; most close pairs are separated in v0.4 latent space
(obs-latent NN agreement 36%). One strong case (J=178: obs 0.12, lat 0.13,
JS 0.34). No systematic aliasing; no WorldTruth exposure.

I. D3 subsets: S1-high (519) v04→v05 regret 0.0287→0.0214, top1 0→0.158
(improved); S3-agreement (2,214) top1 1.0→0.617 (unlearned correct argmaxes);
S4-scout (1,341) top1 0.583→0.149, regret flat. v0.5 loss/KL better on every
subset — the damage is argmax/behavioral, not fit. (`subset_metrics/`)

J. Corpus slices: v0.5 fits every slice better on loss/KL/regret including
D3 (loss 1.3882→1.3790, KL 0.1328→0.1237, regret 0.00311→0.00291) but top1
drops on ALL slices (D3 0.409→0.378; orig 0.456→0.446; D1 0.431→0.408; D2
0.427→0.400). The handoff's "worse on added data" is NOT supported for fit
metrics — refuted and replaced by the tie-break washout account.

K. Gradient cosines at v0.4 (512-row batches, no steps): B3-high vs
B0/B1/B2/B4 = -0.39/-0.21/-0.14/-0.55; B4-low vs B0/B1/B2 =
+0.56/+0.66/+0.35. Norms: B3 1.30 vs 0.21-0.28. (`gradients/interference.json`)

L. Conflict is broad (shared trunk + all heads), not head-specific. Scout
head: B4 norm 0.090 > B3 0.051; B4-vs-B3 cosine +0.64 (agree) — the SHADOW
surge is a diffuse-target mass effect, not a gradient conflict.

M. Mix: rows orig 34.4 / D1 22.7 / D2 22.7 / D3 20.3 (high 1.9, low 17.2 % of
train). Gradient opportunity: orig 35.8 / D1 17.3 / D2 20.3 / D3-high 9.3 /
D3-low 17.4. (`gradients/dataset_mix.json`)

N. Selection: per-epoch weights NOT saved (best_state only) — evaluated the
4 saved checkpoints. Val loss: v04 1.5273 < v05 1.5290/1.5303/1.5373. Within
v0.5, val-loss rank anti-correlates with exam (seed44 best val → worst exam
0.0449; seed42 worst val → best exam 0.0417) and D3-high (seed44 worst
0.0214). Visited: v04 0.00409 best; exam: v04 0.0377 best.
(`model_selection/selection.json`)

O. Representation: 50-epoch isolated fits, 1,600-row balanced pools —
high-pool 1.2637 vs floor 1.2517 (KL 0.011); low-pool 1.2808 vs 1.2694 (KL
0.011). Capacity sufficient; no weights saved. (`representation/`)

P. Horizon (150 stratified replays, bit-deterministic h8: max diff 7e-09):
argmax agreement h4-h8 77%, h8-h12 85% (tie 90 / low 78 / high 88);
mean|ΔQ| 0.016/0.093. Low-margin h12 flip 22%. (`horizon/stability.json`)

Q. Weighted counts: D3 rows 5408; ≥0.0025: 822; ≥0.01: 519; ≥0.025: 240.
Sum regret D1 29.69 / D2 24.02 / D3 16.84. (`summary/signal_weighted_counts.json`)

## 4. Acceptance gates

M0-1 margin distributions D1/D2/D3: DONE. M0-2 regret-stratified
disagreement: DONE. M0-3 amplification measured (refuted as harm): DONE.
M0-4 perturbation sensitivity: DONE. M0-5 near-duplicate search: DONE.
M0-6 aliasing audit: DONE. M0-7 subset metrics: DONE. M0-8 corpus slices:
DONE. M0-9 cosine matrix: DONE. M0-10 group norms: DONE. M0-11 mix
quantified: DONE. M0-12 selection audit (per-epoch weights unavailable,
documented): DONE. M0-13 representation fits, no arch change: DONE. M0-14
horizon on D3 subset: DONE. M0-15 weighted counts: DONE. M0-16 one primary
cause: DONE. M0-17 exactly one next experiment (§5): DONE. M0-18 checkpoints
unchanged (v0.4 hash re-verified): DONE. M0-19 regressions green (357
passed): DONE. M0-20 no DAgger4/Fog/RL/production: DONE.

## 5. NEXT (exactly one evidence-driven experiment)

CASE 1 — significance-gated aggregation retrain on existing data (no new
collection): freeze an inclusion rule over the 5,408 D3 rows (candidate
family justified by §3B/Q: keep rows with driver regret ≥0.0025 or teacher
margin ≥0.0025, ~822-1,154 rows; ablate the boundary, do not freeze a
production threshold yet), retrain from scratch on original+D1+D2+gated-D3
with the identical frozen protocol/seeds, and compare against v0.5 on
visited regret, D3-high regret, scout tie-break distribution, exam, and the
4-way closed-loop exchange. If the gated run recovers v0.4-level exchange
while holding S1 gains, the tie-washout account is confirmed and the rule
graduates to a frozen DAgger4 contract; if not, the failure is in the
high-signal slice itself (interference/ambiguity) and the next step becomes
a target-confidence redesign (Case 7), not more aggregation.

## 6. Scope check

DAgger4: NOT STARTED · Production training: NOT STARTED · Weights changed:
NO · Architecture changed: NO · Teacher changed: NO · ValueTarget changed:
NO · PolicyTarget changed: NO · Fog training: NOT STARTED · RL/self-play:
NOT STARTED. Diagnostic fits (Part O) saved metrics only, no weights.

## 7. Artifacts

artifacts/jev_marginal_signal_v0/: margins/ (margin_by_round,
dagger3_buckets, disagreement_value, tie_conditional, ties_and_legal,
skill_signal, scout_mechanism, target_geometry), target_sensitivity/
(sensitivity), neighbor_conflicts/ (summary, top_conflicts), subset_metrics/
(corpus_slices, d3_subsets), gradients/ (interference, dataset_mix),
model_selection/ (selection), horizon/ (stability), representation/
(balanced_fits), summary/ (signal_weighted_counts, root_cause).

HANDOFF: D:\Game development\Demon slayer\StrategyGame\docs\JEV\MARGINAL_SIGNAL_V0_HANDOFF.md
