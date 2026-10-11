# ValueTargetV0 — Frozen Value-Semantics Specification

Date: 2026-09-19 · Gate: final contract freeze before first supervised training.

This document is the human-readable mirror of five machine-readable contracts
in `python_sim/rollout/`. On any disagreement, the code contracts govern; their
content hashes below pin the frozen semantics.

| Contract | Version | Module | Content SHA-256 |
|---|---|---|---|
| TerminalOutcomeV0 | terminal-outcome-v0.1.0 | `rollout/terminal.py` | `ae083bbdad93ef1d196f1b1e6fd95597232209357eb888aa6cb2d4d9ec5f74c7` |
| MissionProgressV0 | mission-progress-v0.1.0 | `rollout/mission_progress.py` | `d4ef7f9a4d71ee880dc59bfa8ece98d1c1b24368cf41ce1317f4d81c98b68677` |
| ObjectiveProgressV0 | objective-progress-v0.1.0 | `rollout/objective_progress.py` | `fc37fa31706959998f30726a277e41ed1d7a93a8348fe4f602d3f12ae6cd8c0f` |
| BranchStartOutcomeSnapshotV0 | branch-outcome-snapshot-v0.1.0 | `rollout/branch_snapshot.py` | `ecedb199e76bce695e8cda89fc29854deadd3e502d3b239de16e1f43d682b889` |
| ValueTargetV0 | value-target-v0.1.0 | `rollout/value_target.py` | `f1d07788a0f50b247172e3eb75370e47f553d7fa520bba393f5cdf36be2ebeea` |
| Raw outcome schema | raw-outcome-vector-v0.2.0 | `rollout/outcome.py` | (superset of v0.1.0, which is preserved verbatim) |
| Rollout engine | rollout-engine-v0.2.0 | `rollout/engine.py` | (emits v0.2.0 + Q for full-info) |

Authoritative game source: `SimController.evaluate_mission`
(`scripts/sim/sim_controller.gd`), `VALID_OBJECTIVES =
["destroy_all_red", "capture_capital", "survive_turns", "hold_hq"]`, evaluated
in order defeat-first, then per-objective victory, then expired-if-still-ongoing
past `turn_limit`. The Python port (`rules/turn.py`, `sim/battle.py`) is
byte-parity verified (P17 cross-runtime probe).

---

## 1. TerminalOutcomeV0 (Part A)

`T = +1` only on authoritative terminal victory for the acting faction.
`T = -1` only on authoritative terminal defeat for the acting faction.
`T = 0` for every non-terminal state.

EXPIRED is a distinct terminal/no-verdict state in the authoritative evaluator
(assigned only when status stayed `ongoing` past `turn_limit`). It maps to
`T = 0` for both factions. No expiry penalty is invented. Recorded separately:
`expired: bool`, `terminal_reason`, `terminal_verdict`.

Acting-side symmetry (evaluator is blue-centric; projection is explicit):
BLUE victory → BLUE +1 / RED −1 · BLUE defeat → BLUE −1 / RED +1 ·
expired/ongoing → 0 / 0.

## 2. MissionProgressV0 (Part B) — mission audit

`P_mission(state, faction, mission) ∈ [0,1]`; `M = clip(P(post) − P(branch_start), −1, +1)`.
`P_red = 1 − P_blue` (red has no separate contract; red success is blue failure).
Failure never forces `M = −1` (`T` carries terminal failure). `victory ? 1 : 0`
is never used as progress.

| Mission type | Authoritative completion | Authoritative measurable state | P_mission (blue) | Normalization denominator | Terminal interaction | Support |
|---|---|---|---|---|---|---|
| destroy_all_red | red formations empty | red formations alive vs scenario count | destroyed_red / total_red | scenario red formation count | victory ⇒ P=1; defeat precedence, no forced M=−1 | all profiles |
| capture_capital | capital breached OR owner==blue | breach flag + owner (backed by authoritative fortification_hp) | 1 if taken else 1 − hp/hp_max | Capital fortification_hp_max (1500) | victory ⇒ P=1; defeat precedence, no forced M=−1 | strongholds required (unsupported ⇒ P≡0 under DEV_FLAT) |
| survive_turns | turn > turn_limit and hq_alive | current turn + contract turn_limit | (turn−1)/turn_limit clipped | contract turn_limit | victory ⇒ P=1; HQ loss via T, P stays time-based | all profiles |
| hold_hq | turn > turn_limit and hq_alive (same branch) | current turn + contract turn_limit | (turn−1)/turn_limit clipped | contract turn_limit | victory ⇒ P=1; HQ loss via T, P stays time-based | all profiles |

BINARY_ONLY_PROGRESS: false for all four (every mission has shaped intermediate
progress from evaluator-consumed state). Degenerate configs (zero denominators,
absent Capital entity, unknown objective) fall back to explicit 0 rather than
invented shaping. No mission's SUCCESS condition is ambiguous — all four map
1:1 onto evaluator branches — so nothing blocks training.

## 3. ObjectiveProgressV0 (Part C) — objective audit

`P_objective ∈ [0,1]`; `O = clip(P(post) − P(branch_start), −1, +1)`, mission-relevant only.
Frozen denominator class: branch-start relevant-set durability fraction
(`1 − relevant_hp / relevant_hp_max`), binary fallback `breached/total`.
No invented constants (wall HP/maxima/breach are pre-existing semantics).

| Mission type | Objective component? | Denominator | Live selection (double-count review) |
|---|---|---|---|
| destroy_all_red | no (annihilation; strongholds irrelevant) | none — P=0, O=0 | O=0 |
| capture_capital | yes (Capital_* set) | branch-start Capital durability total; fallback breached/total | **O=0 — M carries the capital signal** |
| survive_turns | no (time survival) | none — P=0, O=0 | O=0 |
| hold_hq | no (HQ survival over time) | none — P=0, O=0 | O=0 |

The denominator machinery is implemented and tested on synthetic views; the
live term is 0 for all current missions per the overlap rule above.

## 4. BranchStartOutcomeSnapshotV0 (Part D)

Captured ONCE before the candidate skill; all six branches share byte-identical
snapshot: both factions' total live soldiers, faction-relative P baselines,
terminal baseline (verdict/reason/expired/T), red formation IDs, relevant
Capital IDs.

Casualty exchange: `enemy_fraction = enemy_cas_since_branch_start /
max(enemy_live_at_branch_start, 1)`, likewise friendly;
`E = clip(enemy_fraction − friendly_fraction, −1, +1)`.
Branch-start totals only — never scenario-start, never visible-only.
Full-information target generation.

## 5. ValueTargetV0 (Part E)

`Q = 16*T + 4*M + 2*O + E`, `T ∈ {−1,0,+1}`, `M/O/E ∈ [−1,+1]`.
Zero direct weight for: `own_hq_alive`, `enemy_hq_alive` (in T),
`own_strength_ratio`, `enemy_visible_strength_ratio` (in E; raw ratios kept for
traceability), `horizon_steps` (budget, not reward).

Dominance: non-terminal Q ∈ [−7,+7]; victory Q ∈ [+9,+23]; defeat Q ∈ [−23,−9].
Every victory > every non-terminal > every defeat. Verified analytically and
battle-level in `test_v0_13`.

## 6. Raw outcome schema (Part F)

v0.1.0 preserved verbatim (legacy `mission_delta` indicator and absolute
`objective_delta` count keep their names/semantics). v0.2.0 = v0.1.0 fields +
`terminal_reason`, `expired`, `acting_faction`, branch-start casualty baselines
+ fractions, `mission_progress_before/after`, `M`, `objective_progress_before/
after`, `O`, `T`, `E`, `scalar_Q`, version pins.

## 7. Fog rule (unchanged)

Q evaluated/exported only for `DEV_FLAT_ALL_INFO`, `TERRAIN_FULL_INFO`.
All fog-bearing profiles: `FORBIDDEN_PARTIAL_INFORMATION` permanently
(guard in `value_target.py` + dataset validator + `q_valid_mask` all-False).

## 8. J1 migration note (honest delta)

J1-14/J1-15 previously pinned the ABSENT contract (the documented flip point).
They now pin `value-target-v0.1.0` (full-info OK, fog forbidden, pilot Q
present). J1-13 additionally pins the v0.2.0 derived section. No other
N0/R0/S0/J1 test was modified.
