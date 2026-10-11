# VALUETARGET_V0 HANDOFF — Frozen Value-Semantics Contracts (pre-training gate)

Date: 2026-09-19 · Status: PASS · Scope: contracts only (no training).

Specification: `docs/JEV/VALUE_TARGET_V0_SPEC.md` (audit tables, semantics,
overlap decisions, J1 migration note). This report follows the mandated
final-response format.

---

STATUS: PASS

PROJECT ROOT: D:\Game development\Demon slayer\StrategyGame

TERMINAL OUTCOME:
version: terminal-outcome-v0.1.0 (ae083bbd…)
expired semantics: EXPIRED is a distinct no-verdict terminal → T=0 both sides,
  expired=True recorded separately with terminal_reason/terminal_verdict.
  No invented expiry penalty. Victory/defeat project faction-relatively
  (BLUE victory → BLUE +1 / RED −1; BLUE defeat → BLUE −1 / RED +1).

MISSION PROGRESS:
version: mission-progress-v0.1.0 (d4ef7f9a…)
mission types: destroy_all_red, capture_capital, survive_turns, hold_hq
  (== VALID_OBJECTIVES, all classified; all derived from evaluator-consumed state)
binary-only types: none (all four have shaped intermediate progress)
continuous types: destroy_all_red (destroyed/total formations),
  capture_capital (1 − capital_hp/capital_hp_max; unsupported ⇒ 0 when
  strongholds disabled), survive_turns + hold_hq ((turn−1)/turn_limit).
  Failure never forces M=−1 (T carries terminal failure).

OBJECTIVE PROGRESS:
version: objective-progress-v0.1.0 (fc37fa31…)
objective-bearing mission types: capture_capital only (Capital_* set)
normalization: branch-start relevant-set durability fraction
  (1 − relevant_hp/relevant_hp_max), binary fallback breached/total.
  Live O=0 for ALL current missions per double-count review (M carries the
  capital signal; other missions have no relevant set). Machinery frozen,
  implemented, and tested on synthetic views.

BRANCH SNAPSHOT:
version: branch-outcome-snapshot-v0.1.0 (ecedb199…)
casualty baseline: branch-start total live soldiers per faction
  (never scenario-start, never visible-only); E = clip(enemy_frac −
  friendly_frac, −1, +1). Captured once, shared byte-identically by all six
  branches (V0-9 tested).

VALUE TARGET:
version: value-target-v0.1.0 (f1d07788…)
hash: f1d07788a0f50b247172e3eb75370e47f553d7fa520bba393f5cdf36be2ebeea
formula: Q = 16*T + 4*M + 2*O + E (T∈{−1,0,+1}, M/O/E∈[−1,+1]).
  Dominance: non-terminal Q∈[−7,+7] < victory Q≥+9; defeat Q≤−9.
  Zero direct weight for HQ flags, strength ratios, horizon (in T / E / budget).

MISSION/OBJECTIVE OVERLAP:
destroy_all_red: formation elimination (M) vs soldier attrition (E) vs no
  objective set (O=0) — genuinely distinct, all live.
capture_capital: M carries the capital signal; O=0 (no double count).
survive_turns / hold_hq: time survival (M) vs attrition (E) vs O=0 — distinct.
Full table: VALUE_TARGET_V0_SPEC.md §2–§3.

PILOT Q:
records: 20 (existing pilot scenarios/profiles only — no 10k dataset)
legal branches: 98 of 120 (22 masked, Q=None per V0-17)
Q range: [−0.024, 0.55] (short-horizon non-terminal states; terminal extremes
  proven battle-level in V0-13: victory Q≥+9, defeat Q≤−9)
determinism: byte-identical across two pilot generations
  (regen sha256 c19d72ccf6e34515…; artifact artifacts/v0_value_audit.json)

TESTS:
N0 34/34 · R0 36/36 · S0 29/29 · J1 73/73 (J1-13/14/15 migrated from the ABSENT
  flip point to v0.1.0 expectations — the single documented contract flip; all
  other N0/R0/S0/J1 tests byte-untouched) · V0 19/19 (V0-1…V0-18, V0-20).
  Total: 191 passed.

REGRESSION:
N0: 34 green · R0: 36 green · S0: 29 green · J1: 73 green · V0: 19 green

SCOPE CHECK:
Training: NOT STARTED
Optimizer: NOT CREATED
Production dataset: NOT GENERATED (20 pilot records only)
Self-play: NOT STARTED
Fog oracle labels: NOT GENERATED (FORBIDDEN_PARTIAL_INFORMATION + q_valid all-False + validator)
Godot gameplay rewrite: NO (no .gd/.tscn touched)

CHANGED FILES:
D:\Game development\Demon slayer\StrategyGame\python_sim\rollout\terminal.py (NEW)
D:\Game development\Demon slayer\StrategyGame\python_sim\rollout\mission_progress.py (NEW)
D:\Game development\Demon slayer\StrategyGame\python_sim\rollout\objective_progress.py (NEW)
D:\Game development\Demon slayer\StrategyGame\python_sim\rollout\branch_snapshot.py (NEW)
D:\Game development\Demon slayer\StrategyGame\python_sim\rollout\value_target.py (REWRITE: contract activation)
D:\Game development\Demon slayer\StrategyGame\python_sim\rollout\outcome.py (ADDITIVE: raw-outcome-vector-v0.2.0)
D:\Game development\Demon slayer\StrategyGame\python_sim\rollout\engine.py (rollout-engine-v0.2.0 wiring)
D:\Game development\Demon slayer\StrategyGame\python_sim\rollout\__init__.py (exports)
D:\Game development\Demon slayer\StrategyGame\python_jev\dataset\pilot_generator.py (Q fill + v0.2.0 pin)
D:\Game development\Demon slayer\StrategyGame\python_jev\dataset\schema.py (Q consistency validator)
D:\Game development\Demon slayer\StrategyGame\python_sim\tests\test_v0_value.py (NEW: 19 gates)
D:\Game development\Demon slayer\StrategyGame\python_sim\tests\test_j1_gates.py (J1-13/14/15 migration only)
D:\Game development\Demon slayer\StrategyGame\docs\JEV\VALUE_TARGET_V0_SPEC.md (NEW)
D:\Game development\Demon slayer\StrategyGame\docs\JEV\VALUE_TARGET_V0_HANDOFF.md (this report)
D:\Game development\Demon slayer\StrategyGame\artifacts\v0_value_audit.json (NEW: small audit artifact)
D:\Game development\Demon slayer\StrategyGame\artifacts\j1_pilot_dataset.jsonl (REGENERATED: 20 records with Q)

HANDOFF:
D:\Game development\Demon slayer\StrategyGame\docs\JEV\VALUE_TARGET_V0_HANDOFF.md

NEXT:
First supervised PyTorch training run using ValueTargetV0.
