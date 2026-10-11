# JEV Network v0 — Implementation Handoff Report

Date: 2026-09-19
Task: untrained Jev-inspired System-1 tactical neural policy skeleton (cold start)
Authoritative contract: Notion — "Research Branch — System-1 Tactical Neural Model / Jev-inspired"
(Production Observation Schema Freeze + MVP six-skill tables), retrieved via the Notion connector before coding.

---

## STATUS

**PASS** — all applicable N0 gates (N0-1 … N0-15) pass; N0-16 scope audit clean.
No blockers.

---

## CHANGED FILES (all additive; absolute paths)

- `D:\Game development\Demon slayer\StrategyGame\python_jev\__init__.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\constants.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\layout.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\observation.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\encoders.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\masking.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\output.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\model.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\synthetic.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\run_verification.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\tests\__init__.py`
- `D:\Game development\Demon slayer\StrategyGame\python_jev\tests\test_n0_gates.py`
- `D:\Game development\Demon slayer\StrategyGame\docs\JEV_NETWORK_V0_HANDOFF.md` (this report)

N0-16 audit: `git status` delta vs. the pre-task baseline (244 pre-existing dirty files, preserved untouched)
is exactly `?? StrategyGame/python_jev/` plus this report. No simulator, no training code, no dataset
generation, no gameplay edits, no unrelated file changes.

---

## ARCHITECTURE ACTUALLY IMPLEMENTED

```
actor features [B,67] ────────────── ActorEncoder ──→ actor_ctx   [B,128]
tokens [B,N≤24,37] (FRIEND / VISIBLE_ENEMY / STALE_CONTACT, shared schema)
        │ TokenEncoder (shared MLP)
        └→ token embeddings [B,N,128]
           UnitContextPool — actor-query attention + additive padding mask
           (all-padded rows route to a learned empty-set vector) → unit_ctx [B,128]
hex patch [B,91,33] ── HexEncoder (shared per-cell MLP → center-query attention
        pool + center-cell embedding; topology via relative geometry) → spatial_ctx [B,128]
mission/doctrine [B,46] ── MissionEncoder → mission_ctx [B,128]
global summary [B,31] ── GlobalEncoder → global_ctx [B,128]

5 contexts ── concat [B,640] ── FusionTrunk (Linear 640→512, LN, GELU, Linear 512→512, LN, GELU)
        → tactical latent [B,512]

latent ── five class-specific heads (Linear 512→6 each, distinct modules) ── raw_logits [B,6]
raw_logits + observation-safe legal_mask ── apply_legal_mask ── masked/probs/selected + telemetry
```

- No recurrence (no GRU/LSTM/recurrent state). Stateless: Observation_t → Policy → Skill_t.
- No WorldTruth input path: `forward(obs: ObservationBatchV0)` is the entire forward contract;
  `ObservationBatchV0` has no hidden-truth fields, and unknown kwargs/fields cannot ride along.
- No prose/rationale/coordinates/target-ID/OperationalCommand outputs — typed tensors + bounded telemetry only.

## OBSERVATION CONTRACT MAPPING (Notion freeze → tensors)

1. Actor features → `actor_features [B,67]` (class one-hot, strength, mobility, action state,
   morale/cohesion/rout/stance with known+NA bits, objective/HQ relative direction+distance,
   board-edge free space, current-cell terrain/occupancy/visibility).
2. Friendly tokens → shared `tokens [B,N,37]` with `relation_kind` one-hot.
3. Visible enemy tokens → same shared token schema.
4. Stale contact tokens → same schema + `age_ratio`, `uncertainty_radius_ratio`, known bits.
5. Local terrain/spatial patch → `hex_patch [B,91,33]`, radius-5, actor cell at index 0,
   per-cell relative offset/direction bucket/distance, terrain+UNKNOWN bucket, traversal cost+known bit,
   blocking, occupancy category, visibility state, objective/HQ markers with known bits.
6. Mission/doctrine → `mission_features [B,46]` (typed mission/objective/status/phase,
   six doctrine scalars + known bits, actor mission role).
7. Faction-authorized global summaries → `global_features [B,31]` (turn/phase, friendly/visible-enemy/
   stale counts with explicit overflow indicators, HQ known flags, objective possession, coverage).
8. Observation-safe legality mask → `legal_mask [B,6]` (bool), consumed as output constraint and
   (per the freeze) as input context by the model.
9. Presence/unknown/stale/NA/padding masks → field-known bits on every optional numeric,
   categorical UNKNOWN buckets, `token_padding_mask [B,N]` (True = padded, zero influence),
   `hex_padding_mask [B,91]`, `legal_mask [B,6]`. Unknown numeric = neutral fill 0.0 + known=0;
   a real zero always has known=1.

Notion freezes group semantics, masks, normalization rules, variable-N and anti-leak invariants; it does not
freeze byte-level field orders or capacities. Those adapter decisions are isolated in
`python_jev/layout.py` (versioned frozen reference constants: MAX_TRAVERSAL_COST=3, CONTACT_MEMORY_HORIZON=10,
count refs 16/16/8, TOKEN_CAPACITY=24, direction buckets 6+1) — the single place a schema revision would touch.
Absolute coordinates appear nowhere; geometry is actor-relative offsets / direction buckets / clipped distance ratios.

## TENSOR SHAPES (summary)

| tensor | shape |
|---|---|
| actor_features | [B, 67] |
| tokens | [B, ≤24, 37] (production projectors emit 24) |
| token_padding_mask | [B, ≤24] bool |
| hex_patch | [B, 91, 33] (exactly; validated loudly) |
| hex_padding_mask | [B, 91] bool |
| mission_features | [B, 46] |
| global_features | [B, 31] |
| legal_mask | [B, 6] bool |
| acting_class_idx | [B] long |
| raw/masked logits, probabilities | [B, 6] |
| selected_slot, all_illegal, selected_prob, norm_entropy | [B] |

## MODEL

- parameters: **1,014,430 trainable** (token_encoder 43,136; unit_pool 141,568; hex_encoder 83,584;
  actor_encoder 50,816; mission_encoder 45,440; global_encoder 41,600; trunk 592,896; class_heads 15,390)
  — inside the 1M–5M target family with dimensions in the prescribed ranges
  (embeddings 128, hidden 256, fusion latent 512).
- device: CUDA — NVIDIA GeForce RTX 5090 Laptop GPU (torch 2.9.0+cu129, CUDA available)
- dtype: float32
- model version: `jev-policy-v0.0.0-untrained`

## TESTS (gate-by-gate)

Runner: `python -m python_jev.run_verification` (StrategyGame root) — **34 passed**.

- N0-1 IMPORT — clean `python_jev` import + public API — PASS
- N0-2 FORWARD — [B,6] raw/masked logits, probs, selection for all five classes — PASS (5 param cases)
- N0-3 CLASS HEADS — five distinct head modules over one shared trunk; distinct logits per class — PASS (2 tests)
- N0-4 VARIABLE-N — (0,0,0), (1,0,0), (0,3,0), (2,1,1), (10,8,6)=capacity all forward; over-capacity fails loudly — PASS (6 tests)
- N0-5 PERMUTATION SAFETY — permuted token order ⇒ logits equal within 1e-5 — PASS
- N0-6 PADDING SAFETY — padding 4→24 slots with masked slots ⇒ max |Δlogit| < 1e-4 — PASS
- N0-7 UNKNOWN SEMANTICS — known-zero vs unknown distinguished via (fill, known-bit) pairs;
  categorical UNKNOWN is a dedicated bucket — PASS
- N0-8 HEX PATCH — exactly 91 cells accepted; 90/92/49/169 all fail loudly at construction (schema-level) — PASS (6 tests)
- N0-9 MASKING — illegal slots -inf / prob 0 / unselectable, incl. [1,1,0,1,0,1]; direct `apply_legal_mask` unit test
  (masked global max at slot 4 not chosen) — PASS (4 tests)
- N0-10 ALL-ILLEGAL — explicit sentinel `ALL_ILLEGAL_SLOT=-1`, zero probability row, `skill_name → None`,
  no NaN — PASS
- N0-11 ANTI-LEAKAGE — differing hidden WorldTruth in metadata + byte-equal observation tensors ⇒
  torch.equal logits/selection; forward signature and dataclass fields contain no WorldTruth field — PASS (2 tests)
- N0-12 DETERMINISTIC EVAL — fixed seed + eval + identical obs ⇒ bit-identical logits — PASS
- N0-13 GRADIENT — dummy scalar loss per class head backprops; every parameter receives grad
  (except expected no-op `unit_pool.empty_set` for non-empty sets) — PASS
- N0-14 PARAMETER COUNT — 1,014,430 ∈ [1M, 5M] — PASS
- N0-15 LATENCY — warm forward, CUDA: batch 1 ≈ 2.4 ms, batch 64 ≈ 2.5 ms (float32) — PASS
- N0-16 NO SCOPE CREEP — git audit above — PASS

## LATENCY

- batch 1: 2.40 ms (gate suite) / 3.68 ms (consolidated benchmark, RTX 5090 Laptop, float32, warm)
- batch N: batch 32 ≈ 4.74 ms, batch 64 ≈ 3.71–2.54 ms (consolidated/gate runs)
- No GPU measurements were faked; CUDA was available and synchronized around timing.

## ENVIRONMENT

- Windows, Python 3.13.15, pytest 9.0.2, numpy 2.2.6, torch 2.9.0+cu129 (CUDA)
- Godot 4.2.2 executable present at the documented path (not exercised — not required for this task)
- No new dependencies installed; no ML frameworks beyond the existing torch.

## UNRESOLVED ISSUES / NOTES

1. Adapter-level (Notion-unfrozen) choices isolated in `layout.py`: field orders, TOKEN_CAPACITY=24,
   normalization reference constants, direction-bucket construction, role/terrain vocabularies.
   These need a schema review before training data exists (changing them is a schema bump, per the freeze).
2. `HexEncoder` implements Option B (shared per-cell encoder + relative-geometry + center-query attention),
   explicitly chosen over message passing to keep the skeleton clean; a message-passing variant can replace it
   behind the same 91×33 interface without touching the contract.
3. The legality mask is taken as given upstream (observation-safe generation is the engine/projector's duty);
   this package only consumes and applies it. This matches the frozen boundary (D0-5, O-8).
4. Known-zero vs unknown is enforced at tensor/schema level (fill+known-bit pairs, dedicated UNKNOWN buckets);
   no game-rule semantics were invented.

## EXPLICIT SCOPE CONFIRMATION

- Python battle simulator: **NOT STARTED**
- Training / RL / self-play / distillation / checkpoint work: **NOT STARTED**
- Dataset or rollout generation: **NOT STARTED**
- Godot gameplay code: **NO** modifications (no `.gd`/`.tscn` files touched; Godot not invoked)
- ONNX export / inference server / Godot integration: **NOT STARTED**

## NEXT ARCHITECTURAL STEP (for the separately-issued next task)

RulesetV0 / skill-executor contract work per the Notion gate order (Gates E0–E6 review, then DEV_FLAT_FULL_INFO
plumbing), plus a schema review of the `layout.py` adapter constants against the first production projector.
