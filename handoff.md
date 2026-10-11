# Handoff: Commander Brain (LLM commands RED units) — state as of 2026-10-08 15:30 KST

Project root: `D:\Game development\Demon slayer\StrategyGame` (Godot 4.2.2 hex wargame, Windows 11, RTX 24 GB GPU).
The previous `handoff.md` (2026-09-01 game-design document, 오대십국 / 將軍) was preserved unchanged as
`handoff_design_2026-09-01.md`.

Legend: **[V]** = verified in this session (logs/files inspected). **[U]** = unverified / assumption / unknown.

---

## 1. Original Goal

### 1.1 Ultimate goal
A local "Brain" that commands the RED army in the game's commander mode, at cloud-LLM quality, small and fast
enough to ship inside the game. The path the user set:
- cloud plans → SFT of a small local model → (later) RL.
- Since 2026-10-08, also a **game-native attention prediction model** ("B all in"; §1.4).

### 1.2 Hard product requirements (user, 2026-10-07/08)
- **Latency:** under 5 s per decision.
- **VRAM:** under 8 GB total in production. Distilling to a smaller model is near certain.
- **Thinking:** thinking text is used for training only; production runs with thinking off.
- **Streaming execution:** the executor starts each unit as soon as its order is emitted (the user likes this).
- **Opponent:** in production BLUE is always a human. Do not rely on GX-specific behaviour.
- **Resident Brain:** one conversation per game, asked every RED turn, with only the delta each turn. The fixed
  "re-ask every 5 turns with a full fresh packet" design was **cancelled by the user (2026-10-06)** and must not
  come back (memory file `strategygame-resident-brain-no-5turn.md`).

### 1.3 Design principles (user rules, do not violate)
- **The LLM plans freely.** Never reduce the Brain to choosing among GX/utility-generated options. GX is only the
  opponent (BLUE) and the deterministic executor of RED orders.
- **Model input = facts a human could see or count:** no hints, rankings or option lists. Enemy troops are shown as
  a band ("150-300").
- **Attacking is solely the Brain's decision:** units attack only under ATTACK / RAID (and ASSAULT). Never add
  automatic or opportunistic attacks to any executor.
- **"plan" = the strategy for winning the battle and why.** It is written on the first turn and again only when the
  strategy is dropped for another. It is not a progress report and not a list of moves; orders are the moves.
- Fix things while optimizing, not patch on patch. Latency matters. Compare token counts, not wall time.
- Debugging must not trust one side: cross-check with independent reviews.

### 1.4 Current direction ("B all in", user 2026-10-08)
- A small transformer over units (one token per unit), trained from scratch.
- It predicts:
  - own next actions (top-K candidates; it may output dozens with probabilities),
  - the outcome of an action (effect on the enemy),
  - the enemy's intent (whom it will attack next),
  - the win probability.
- Use: during BLUE's turn (idle time) it prepares RED's next actions.
- Both sides of every game are learned (data ×2).
- Teacher data must be very diverse and biased toward winning lines, not random.
- Opponent curriculum the user set: GX vs GX → cloud vs GX → cloud vs cloud (the final stage).
- Scoring of multi-candidate predictions must use a proper scoring rule (log-prob), not "hit if anywhere in the
  list" (that is gameable).

### 1.5 Success criteria (stated or implied)
- A local small model wins BASIC and INTER reliably and quickly. ADV is not won by any local model yet.
- Under 5 s per decision and under 8 GB VRAM in production.

### 1.6 User working preferences
- Answer in Korean, plainly and concisely, with minimal reports.
  - Report results, stalls and errors only; do not nag.
- Ask only when the design is genuinely unclear. Never call a design choice a "bug".
- Content must be inline in chat. The user cannot see file-only outputs.
- When asked for a cold prompt, state only what to do, not the method or order.
- Free models only. OpenRouter only `:free`. Ask before anything paid.
- Do not read opencode databases or credential files.
- Freebuff may only be used through its official app, operated by the user (no scripts or headless use).
- The user wants to see work in windows. Specifically the **model building/training**, not the game windows
  (2026-10-08: "아니, attention 만드는걸, not the game").
- Stop no-training eval runs once answered, and free the GPU.

---

## 2. What We Did (completed work and results)

### 2.1 Packet v2 and information audit (2026-10-07) [V]
`scripts/cloud_pipeline/commander_controller.gd`:
- **Rules and reply:** all game rules stated in the system prompt.
- **Facts:**
  - `vs` combat previews over the troop band
  - `eta`, `can_strike_next`, `map_radius`, troop bands
- **Executor:**
  - `_path_move` is a BFS over open hexes.
  - Targets: MY_HQ / ENEMY_HQ / own unit ids.
  - RAID order for cavalry.

### 2.2 Resident Brain (2026-10-07/08) [V]
Implemented in `commander_controller.gd` (header comments describe it):
- **Conversation:**
  - The opening (system prompt + full start state + turn-1 answer) never changes, so it stays cached.
  - After that, one short turn message per turn:
    - `events` since the last answer;
    - one line per unit — own `"<id> <q>,<r> <soldiers>[ fort N][ eta_hq N][ | in-reach vs entries]"`, BLUE
      `"<id> <q>,<r> <troops>[ fort][ seen tN][ eta_my_hq N][ next ids]"`.
- **Memory without reset** (user rejected cut-offs and resets): the game folds older turns into a code-computed
  `BATTLE DIGEST` at the head of the oldest kept turn.
  - Digest content, per unit: moves (from → to, distance to my HQ), attacks with kills and losses, hits taken,
    fieldworks, destroyed. Plus the orders and plan standing at the fold.
  - Fold trigger: when 10 turns are kept (`WATCH_COMPACT_AT`) or right after a plan change, keeping the last
    5 turns word for word (`WATCH_RECENT_TURNS`).
  - Conversation size stayed bounded at about 30–50k characters with the code commander.
- **Reply format:** `{"orders": {only changed units}}`, optional `"plan"` (strategy only). `expect` was removed
  entirely on 2026-10-08 after the A/B below.
- **State:** every request also carries the full packet as `"state"` (outside the messages) for code policies and
  data tools.
- **Sides:** the commander is side-generic. A BLUE commander gets the same prompt with RED and BLUE swapped and the
  turn order "each round BLUE (you) acts first, then RED".
- **Proxy** (`tools/brain_review/teacher_proxy.py`):
  - Local models get the whole conversation (vLLM / Ollama prefix cache).
  - Cloud (opencode) gets one transcript per call from a fixed per-game directory. Prompts over 40k characters are
    split into several attached files (`ask_1.md…`), because opencode reads only about 50 KB per attachment.
  - opencode sessions are NOT used: they keep every earlier thinking and reached about 90k tokens by turn 7.
  - **Local failures:** `--local-pass` skips only the failed turn (orders stand); the collector always sets it.
  - **Forced answers:** after a forced `</think>`, an empty answer is pre-started with `{"orders": ` (fix in
    `tools/plan_search/cloud_brain.py`).

### 2.3 Benchmarks [V]

| Brain | Setting | BASIC | INTER | ADV | Notes |
|---|---|---|---|---|---|
| Qwen3.8-27B INT4, vLLM, effort low, thinking on | resident, 6k think budget, no-expect (b00) | 3/3 | 3/3 | 0/3 | 82–133 s median per turn |
| same | resident, with expect (b01, same seeds) | 3/3 | 3/3 | 0/3 | no meaningful difference, so `expect` was removed |
| same | old 5-turn packet v2 (different seeds) | 2/3 | 3/3 | 0/3 | one BASIC game INVALID: thinking cap |
| Qwen3.8-27B MTP, Ollama, low, resident | 1 BASIC game | WIN at turn 20 | – | – | 14 min. Plan was written only once (prompt fix worked) |
| Haiku (Claude subagent via manual mode) | 1 BASIC game | WIN at turn 20 | – | – | all-in at turn 1, then `{}` |
| **Qwen3.5-9B base, thinking off, FP8, resident** | 7 games | 0/3 | 0/3 | 0/1 | **every game lost its own HQ**; §3 |

Speed of Qwen3.5-9B, 3 games concurrent: bf16 about 7 s per turn, FP8 4–6 s per turn.

### 2.4 Code-policy packages (produced by other agents, read-only for us)
1. **`artifacts/brain_pipeline_v1/commander_survivors_20261007/`** [V]
   - 508 LLM-written code policies, about 760 games, robust 5/5 survivors.
   - `sft_robust.json` (3,255 rows, old format, policy-jargon text).
   - Our `sft_refined.json` (677 rows) was made by `tools/cmd_rl/refine_survivors.py`.
2. **`artifacts/brain_pipeline_v1/commander_growth_20261007/`** [V, per its REPORT.md]
   - 729 games. `sft_expanded.json`: 2,754 rows in the **old 5-turn format** (BASIC 1,512 / INTER 1,242), with
     varied grounded wording.
   - Hold-out: all HARRIER games plus 32 reserved seeds (`holdout_definition.json`).
   - The collection was interrupted. **Cause: we started collectors on its slots 0/1 and edited Godot files on
     10-08.** Its INTER hold-out baseline covers only 6 of 16 situations.
   - The user may archive it to Drive for a later Qwen 9B SFT.

### 2.5 Dev modes and full game records (2026-10-08) [V]
`tools/plan_search/cmd_collect.py --mode`:
- `gx_vs_cloud` (default): Brain RED vs GX BLUE.
- `gx_vs_gx`: GX on both sides, every RED style × BLUE style (`--red-styles`). The RED style goes per game via
  `job.red_style`, which sets env `WATCH_RED_GX_STYLE`.
- `cloud_vs_cloud`: both sides are commanders. BLUE uses its own proxy on `proxy_port+50`, calls in `raw_blue/`,
  `--blue-model`.
- `--games <jsonl>`: play exactly a list of games once (replays).

Every game result JSON now contains `"record"` (`tools/rl_arena.gd`):
- `snapshots`: every unit at the start of each phase (`to_act` blue/red), as
  `[id, faction, class, q, r, soldiers, max, fieldworks]`.
- `actions.red` / `actions.blue`: both controllers' `action_log`.

Driver wiring: `scripts/cloud_pipeline/watch_llm_vs_utility.gd` reads env `WATCH_RED_MODE=COMMANDER|GX`,
`WATCH_BLUE_MODE=GX|COMMANDER`, `WATCH_CMD_URL_BLUE`.

Smoke tests passed for both new modes (BASIC games run to the end).

### 2.6 Prediction model ("B") [V code runs; quality unknown]
`tools/predict/`:
- **`data.py`:** samples from game records, from each side's view; the BLUE view is point-mirrored.
  - **Features (19 per unit):**
    - class one-hot (6), own flag
    - q, r; position relative to own HQ and to enemy HQ
    - soldiers share, soldiers, fieldworks HP, turn
    - actor type: LLM, code (GX = both 0)
  - **Labels:**
    - action: HOLD / FORTIFY / OTHER / MOVE in 6 directions / ATTACK, plus the attacked target
    - outcome: share of soldiers lost in this phase, destroyed or not
    - intent: the first own unit this enemy attacks within 5 turns, or none
    - value: win / draw / loss
  - Replays only keep action labels when they ended like the original. Package hold-out games go to validation.
- **`model.py`:** 4-layer transformer with a learned per-head bias for each hex-distance bucket, a pointer head for
  attack targets and intent, and a value head. About 0.8M parameters, about 4 ms per decision on GPU.
  - `torch.backends.mha.set_fastpath_enabled(False)` is required: the eval fast path returned NaN.
- **`train.py`:** trains on all of the above and reports held-out metrics (`--runs`, `--holdout`). Output goes to
  `artifacts/brain_pipeline_v1/predict_v1/` (`metrics.jsonl`, `predictor.pt`).
- **`watch.py`:** a live matplotlib window of `metrics.jsonl`.
- **Only a smoke run was done.** It ran on 11 GX-vs-GX BASIC games that were all draws, so the metrics are
  meaningless. No real training run yet.

### 2.7 Replays of logged games (to get full records) [V partly]
- **Method** (`tools/predict/replay.py`): `prepare` / `prepare-code` build game lists and answers; `serve` answers
  the collector's manual requests with the logged answer for (game, turn), else `{"orders": {}}`; `check` compares
  results.
- **LLM runs (138 games), `replay_cloud_v1/`:** finished. **Only 4 matched the original**: 2 resident b00 games and
  2 bunny_v2_packet2 games.
  - All 10-06 runs diverge. Executor semantics changed after them (auto-fire removed, path BFS).
- **Code packages (1,489 games), `replay_code_v1/fort1/`:** running. At 15:29: 310 played, **60 matched (46 won)**.
  The match rate fell from 53/81 to 60/310. **[U] cause unknown:** possible execution-source drift since 10-07,
  or non-determinism.

### 2.8 Other experiments [V]
- **Kai gate:** Decision-2.0-Kai-0.6B, at `D:\StrategyAI\models\Decision-2.0-Kai-0.6B`.
  - Question tested: "must any order change this turn?" Zero-shot AUC 0.61. Fine-tuned on 637 Qwen turns,
    held-out AUC 0.45 (overfit). **Failed.**
  - The package's loader breaks on Windows (backslash file-hash paths). The workaround is `load_kai()` in
    `tools/cmd_rl/gate_kai.py`.
- **Upper bound for any gate:** in resident Qwen 27B games, 55% of turns changed nothing and they took 44% of the
  model time.

---

## 3. What We Tried and What Failed (do not repeat)
- **Fixed 5-turn re-asks with fresh full packets.** Cancelled by the user. Slow (the whole context re-read every
  call) and lower quality.
- **Resetting the conversation every N turns.** Rejected: it loses fight details and re-reads everything.
- **opencode `--session` for resident cloud play.** It keeps all earlier thinking (about 90k tokens by turn 7) and
  is slow.
- **Space Bunny and Gemini resident runs (2026-10-08).** Stopped by the user ("something is wrong"). Thinking was
  10–50k tokens per turn, 40–370 s per call. The cloud path with transcript plus split attachments is
  **[U] untested** since that fix.
- **`expect` in the reply.** No gain (A/B, same seeds) and more output. Removed.
- **Kai yes/no gate.** Failed (§2.8).
- **Base Qwen3.5-9B, thinking off.** Flaws found in the 7-game check:
  - sends its own HQ to attack or advance (every loss was HQ destroyed);
  - uses MOVE to the enemy HQ coordinates instead of ATTACK (MOVE never attacks);
  - gives absurd coordinates ([35,7], [-12,33]);
  - nests `"plan"` inside `"orders"`;
  - issues many HOLD orders;
  - re-sends every order every turn.
- **GX vs GX BASIC is passive.** Early games were all 81-turn draws with little contact. Of 621 games at 15:29:
  NOT_ACHIEVED 409, WIN 114, LOSS 94, ERROR 4 (**[U]** cause of the errors not checked).
- **Process-kill mistakes:**
  - Stopping a collector with `Stop-Process` on its pid leaves its arenas and proxy alive (orphans keep playing
    with failing calls). Kill the whole tree with `taskkill /T /F /PID <collector pid>`.
  - Godot arena command lines do NOT contain the arena dir, so pattern-matching `arena_NN` never finds them.
  - Never run `taskkill /FI "WINDOWTITLE eq *"` (it was attempted once by mistake; it failed harmlessly).
- **Slot collisions:** we took slots 0/1 while another agent's growth campaign was running and interrupted it.
  Check `netstat` for listening ports and the running collectors before choosing a slot.

---

## 4. Current State (15:29 KST, 2026-10-08)

### 4.1 Running right now [V]
| What | Process / control | Output |
|---|---|---|
| Qwen3.5-9B SFT, resident v1 (WSL, QLoRA) | started 12:34 by `artifacts/brain_pipeline_v1/cmd_sft/run_sft_resident_v1.sh`; step 130/184, nll 0.059, about 77 s per step; **expected end about 16:40** | adapter → `artifacts/brain_pipeline_v1/cmd_sft/adapters/sft_resident_v1` (created at the end), log `sft_resident_v1.log`, marker `SFT_RESIDENT_V1_DONE` |
| GX vs GX mass collection (slot 0, ports 8096/8106, 10 headless windows, `--cycle`) | collector pid in `artifacts/brain_pipeline_v1/gxgx_mass_v1/collector.pid` (37732) | `gxgx_mass_v1/` (621 results) |
| Code-package replays (slot 3, 8099/8109, 6 windows) | collector pid in `replay_code_v1/collector.pid` (45836) plus a `tools.predict.replay serve` process | `replay_code_v1/fort1/`; 310 of 1,489 done; about 2–4 min per game, so many hours remain |

Stop GX vs GX or the replays: create `<out>/STOP` (running games finish), or kill the collector tree with
`taskkill /T /F /PID <pid>`. Also stop the matching `tools.predict.replay serve` process for the replays.

### 4.2 Not running
- No vLLM server. The 9B benchmark watchdog was stopped and the GPU freed before the SFT started.
- The A/B watchdog was stopped (`cmd_rl/RESIDENT_AB_STOP` exists).

### 4.3 Works [V]
- Resident commander with digest memory, local models (vLLM, Ollama), manual mode and code commanders.
- `gx_vs_gx` and `cloud_vs_cloud` modes, full game records, replays, prediction-model training pipeline, resident
  SFT row builder.

### 4.4 Incomplete, broken or unknown
- **[U]** Cloud (opencode, agy) resident calls after the transcript and split-attachment change: never run.
- **[U]** Why most code-package replays no longer match the original game.
- **[U]** Quality of the prediction model: no real training run yet.
- **[U]** Whether SFT resident v1 improves the 9B: not evaluated yet.
- **Training data for SFT v1:**
  - 738 rows from 40 matched, won survivor games (BASIC 419 / INTER 319; 291 no-change rows).
  - Built by `tools/cmd_rl/build_sft_resident.py`; answers only, thinking off.
  - mean prompt 12,115 tokens, completion 56 tokens.
- **Script compatibility:** some old scripts still pass removed flags or envs.
  - `tools/cmd_rl/loop.py` and `tools/plan_search/cloud_ladder.py` set `WATCH_CMD_EVERY`, which is now ignored.
  - `eval_sft_local.py` had `--local-fresh` removed.
  - `survivor_search.py` sets envs that no longer exist (harmless).
- **Memory file inaccuracy:** `strategygame-production-brain-constraints.md` says "top-3". The user later said
  dozens of candidates scored by probability.

---

## 5. What I Was Doing (role and reasoning)
I was the coordinating engineer: implemented game, proxy and collector changes, ran benchmarks and collections,
and reported in Korean. Main decisions and why:
- **Game-owned conversation.** The game builds the conversation and the proxy only forwards. The game is the
  single source of truth, and local servers cache the prefix.
- **Code digest instead of resets** (user idea). It keeps old information compactly without re-reading
  everything.
- **Replays instead of re-collecting.** The logged answers plus seeds reproduce games (when the executor matches)
  and give full both-side records for free.
- **Resident SFT from replays.** Replayed requests are exactly today's resident conversation, so the SFT format
  matches the game. Answers are cleaned to "changed orders only" and policy jargon is removed.

---

## 6. What I Was Just Working On
- **Active:** waiting for SFT resident v1 to finish (step 130/184 at 15:29).
- **Planned next, not done:** evaluate the adapter in the same 9-game resident setting as the 0/7 baseline.
  - vLLM: `cmd_rl/run_vllm_q35_32k_fp8.sh <WSL adapter path>` serves LoRA as model name `policy`.
  - Collector flags: `--local-model policy --local-no-think --local-answer-tokens 2000`, BASIC 3 / INTER 3 /
    ADV 3, same seeds as `cmd_collect_resident_q35_nothink` (seed0 800000).
  - **[U] Check whether the FP8 vLLM script accepts LoRA together with `--quantization fp8`; it was never tried.**
- No file was mid-edit. The last code edits were `tools/cmd_rl/build_sft_resident.py` (new) and the
  `watchdog_q35_resident.ps1` stop fix (tree kill).

---

## 7. Files and Environment

### 7.1 Key code
| File | Purpose |
|---|---|
| `scripts/cloud_pipeline/commander_controller.gd` | resident commander: prompt, packet, turn message, digest, executor |
| `scripts/cloud_pipeline/watch_llm_vs_utility.gd` | match driver; RED/BLUE modes |
| `tools/rl_arena.gd` | arena loop; result JSON incl. `record` |
| `tools/plan_search/cmd_collect.py` | collector (modes, slots, `--games`, `--cycle`, STOP file) |
| `tools/brain_review/teacher_proxy.py` | Brain endpoint (local / cloud / manual), `calls.jsonl` logging (full messages + state) |
| `tools/plan_search/cloud_brain.py` | local_command (vLLM/Ollama, think budget, forced answer), cloud_command (opencode/agy transcript) |
| `tools/plan_search/brain_io.py` | manual-mode agent CLI (next / answer / status) |
| `tools/plan_search/synth_commander.py`, `survivor_policy.py`, `survivor_search.py` | code commanders (read `state`) |
| `tools/predict/{data,model,train,watch,replay}.py` | prediction model + replays |
| `tools/cmd_rl/build_sft_resident.py` | resident SFT rows from matched replays |
| `tools/cmd_rl/train_wsl.py`, `wsl_run.sh` | QLoRA trainer (WSL venv `/opt/brain_moe/venv`) |
| `tools/cmd_rl/gate_kai.py`, `train_gate_kai.py` | Kai gate experiment (failed) |

### 7.2 Key artifacts (under `artifacts/brain_pipeline_v1/`)
| Path | Content |
|---|---|
| `gxgx_mass_v1/` | GX vs GX (running) |
| `replay_cloud_v1/` | LLM-game replays (done): `originals.json`, `answers.json`, `fort0/`, `fort1/` |
| `replay_code_v1/` | code-package replays (running) |
| `cmd_collect_resident_ab/b00_noexpect`, `b01_expect`, `b02_noexpect` (partial) | Qwen 27B resident A/B |
| `cmd_collect_resident_q35_nothink/` | base 9B benchmark (7 games, 0/7) |
| `cmd_sft/sft_resident_v1.json`, `adapters/` (`init`, `sft_v2`, `sft_v3_think`, soon `sft_resident_v1`) | SFT data and adapters |
| `jev_gate/` | Kai gate reports |
| `predict_smoke/` | prediction smoke model |
| `info_audit/prompt_D_refine_scale_survivors.md` | cold prompt D (resident version) given to another agent; its output is `commander_growth_20261007` (that run used the old 5-turn format) |
| `cmd_rl/watchdog_*.ps1` | detached watchdogs; `run_vllm_*.sh` = vLLM launchers |

### 7.3 Environment
- **Godot:** `C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe`.
  - Parse check: `--headless --path . --check-only --script <file.gd>`.
- **Python:**
  - collectors: `D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe` (or system Python 3.13)
  - prediction model: system Python 3.13 with torch 2.9 + CUDA, matplotlib, transformers 5.17, peft 0.21
- **vLLM:** WSL `/opt/brain_vllm/venv`.
  - Qwen3.5-9B: `run_vllm_q35_32k.sh` (bf16) and `run_vllm_q35_32k_fp8.sh`; served as `q35`, adapter as `policy`.
  - Qwen3.8-27B INT4: `run_vllm_q38_policy_32k.sh` (3 sequences), `_6seq.sh`.
  - Log: `cmd_rl/vllm.log` or `q38_eval/vllm.log`.
- **Ollama:** `qwen38-jrell-mtp-128k`. Unload with
  `curl http://127.0.0.1:11434/api/generate -d '{"model":"…","keep_alive":0}'`.
- **Models:** `D:\StrategyAI\models\` (Qwen3.5-9B, Qwen3.8-27B-INT4, Decision-2.0-Kai-0.6B, `kai_gate_v1.pt`).
- **Slots:** collector slot s → arenas `10+10s…`, Hands worker port `11460+s`, proxy/brain ports as given.
  - In use now: slot 0 (gxgx, 8096/8106) and slot 3 (code replay, 8099/8109).
  - Do not reuse them while running.
- **Headless flag:** `artifacts/rl_vs_utility_v0/HEADLESS`. The collector writes it unless `--visible`, and a
  visible run deletes it at the end. With collectors running, mixing visible and headless runs is racy.
- **Git Bash quirks:**
  - `kill -0` cannot see Windows PIDs: use `tasklist`.
  - `cd` before running Python on `/d/...` paths.
  - Do not use `taskkill /PID` inside the PowerShell tool (its sandbox misparsed `/PID`). Use `Stop-Process`
    plus a CIM parent/child lookup, or `& taskkill.exe` inside a `.ps1` script.

### 7.4 Validation procedures
| What | How |
|---|---|
| GDScript | parse check (above) |
| Resident loop | manual-mode game with a code commander: `synth_commander` on the manual dir + `cmd_collect --manual-dir … --tier-games BASIC=1 --windows 1` |
| Replays | `python -m tools.predict.replay check <replay dir>` |
| SFT rows | inspect assistant messages (cleaned) and digest lines (no "Your plan") |
| Prediction model | `python -m tools.predict.train --epochs N --holdout 0.2`; compare held-out metrics against trivial baselines (always "HOLD", always "none", always "draw") |

---

## 8. Next Actions (priority order)
1. **When SFT resident v1 finishes** (`SFT_RESIDENT_V1_DONE`): serve the adapter (vLLM 9B; check LoRA + FP8) and
   play the same 9 games (thinking off, resident).
   - Compare with the 0/7 baseline.
   - Check the specific flaws: HQ sorties, MOVE-instead-of-ATTACK, nested plan, full re-orders.
   - Report briefly in Korean. Stop the eval after the answer and free the GPU.
2. **Investigate the replay mismatches** (60/310 matched).
   - Compare one mismatched replay's record with the original game's per-call packets to find the first
     diverging turn.
   - Check execution-source drift against `commander_growth_20261007/execution_source_drift.json`.
   - Only matched games may give action or SFT labels.
3. **Train the prediction model for real** on `gxgx_mass_v1` + `replay_cloud_v1` + `replay_code_v1`.
   - Show it in windows: training console + `python -m tools.predict.watch` (the user wants to watch the model
     being built).
   - Report held-out metrics against trivial baselines.
   - Consider dropping passive GX-vs-GX BASIC draws or down-weighting them.
4. **SFT v2** with more rows once more replays are matched. Consider adding grounded thinking text for training
   only (user decision: thinking in training, off in production).
5. **Cloud stages of the curriculum:** cloud vs GX, then cloud vs cloud, with a free cloud model.
   - Verify the transcript + split-attachment path on one game first.
   - Expect slow calls (10–50k thinking tokens per turn).
6. Fix the "top-3" wording in the memory file (user: dozens of candidates with proper scoring).

**Preserve / avoid:**
- Never reintroduce the 5-turn re-ask or conversation resets.
- Never feed option lists or hints to the LLM.
- Never add automatic attacks.
- Do not edit or delete the other agents' package folders (`commander_survivors_20261007`,
  `commander_growth_20261007`).
- Do not use paid models without asking.
- Kill collectors by process tree.
- Check slots and ports before starting anything.
