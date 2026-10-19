# Blockade teacher games on a second computer

Goal: collect BLOCKADE games (BLUE = scripted ring-the-HQ bot) on a laptop, because the first computer is full (Strata server).
Blockade so far: cloud teachers 0 wins, Strata 0/4 (see handoff). This setup only makes the games runnable; the teacher choice is open.

## What a game needs
| part | where | note |
|---|---|---|
| Godot 4.2.2 headless game | `project.godot` (repo) | any CPU, set `SG_GODOT` to the *console* exe |
| game-side Python | `SG_PY` (default `python`) | needs only what `tools.synth_adv_v1.spar_teacher` imports; install what a smoke run reports missing |
| Hands A/B worker | not needed | retired; `SG_NO_HANDS=1` (set by the launcher) skips it, see "Hands removed" below |
| relay shim + blockade bot | `tools/synth_adv_v1/relay_shim.py`, `tools/cmd_rl/blockade_bot.py` | stdlib only |
| the teacher (answers `req_NNNN.json` -> `resp_NNNN.txt`) | another process | see below |

## Files that are NOT in git (copy by hand)
`assets/` (StrategyGame_assets_2026-10-17.zip, unzip into the repo root). Nothing else: no Hands weights, no torch, no GPU.
Install Godot 4.2.2 and a Python 3.12 with whatever `tools.synth_adv_v1.spar_teacher` reports missing on the first smoke run.

## Hands removed
Hand A/B are retired: in a full INTER game their worker got 0 inference requests, but the game still waited for the worker and
aborted at turn 1 without it. `scripts/cloud_pipeline/watch_llm_vs_utility.gd` now skips that wait when `WATCH_NO_HANDS=1`, and
`tools/cmd_rl/spar.py` sets it (plus `LAYA_ENABLE=0`, no worker process) when `SG_NO_HANDS` is set. The launcher sets `SG_NO_HANDS=1`.
Tested on the first computer: a blockade game started with no Hands worker and ran turns 1-6 (requests answered, no abort).
Default behaviour (variable unset) is unchanged, so the first computer's collection is untouched.

## Ports (all on 127.0.0.1; a slot = one concurrent game)
For slot S (use 15..19 on the laptop; the first computer uses 14; two computers never clash, two slots on one machine never clash):
| what | port | slot 15 | slot 16 |
|---|---|---|---|
| relay shim (the commander talks to this) | 8240+S | 8255 | 8256 |
| teacher proxy (writes req_/reads resp_) | 8250+S | 8265 | 8266 |
| red brain port | 8260+S | 8275 | 8276 |
| BLUE manual proxy (+0 for the one game) | 8270+S | 8285 | 8286 |
Seeds are 9995000 + S*1000 + game number, the Godot arena folder is `artifacts/rl_vs_utility_v0/arena_(10+10*S)`.
A teacher model server of your own (not part of the game) can use any free port, e.g. 8080.

## Run
```
export SG_PY=/c/path/to/python.exe SG_GODOT=/c/path/Godot_v4.2.2-stable_win64_console.exe
bash tools/synth_adv_v1/blockade_laptop.sh blockade_lt 16        # name, slot (15..19; the first computer uses 14)
```
It writes `artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play/blockade_lt/CURRENT.txt` (the inbox of the game being played) and
`results.log`; `touch .../blockade_lt/STOP` ends it after the running game. The slot sets the ports (8240+slot ... 8270+slot) and the seeds
(9995000 + slot*1000 + n), so use a different slot than the first computer to keep seeds distinct.

## The teacher (pick one)
1. Another Claude session as teacher: give it `tools/synth_adv_v1/teacher_play_prompt.md` with `<NAME>` = `blockade_lt` and the paths of this laptop.
2. A model behind an OpenAI-style endpoint (local or cloud): `python -m tools.synth_adv_v1.teacher_play_llm --name blockade_lt --url <endpoint>/v1/chat/completions --model <name> --effort low --effort-plan medium --aid --think-on short --think-budget 20000 --think-budget-other 1500`
   (the Strata flags; run it after `CURRENT.txt` names an inbox). API keys are yours to set; none are stored in the repo.

## Changed for portability (defaults unchanged on the first computer)
`tools/contextual_brain/rl_vs_utility.py` (`SG_ROOT`, `SG_GODOT`, `SG_PY`, `SG_LAYA_PY`), `tools/brain_review/harvest.py` (`SG_ROOT`),
`tools/cmd_rl/spar.py` (`SG_NO_HANDS`), `scripts/cloud_pipeline/watch_llm_vs_utility.gd` (`WATCH_NO_HANDS`).
Not yet run on a second machine: its first smoke game will show what is still missing.
Merge the collected games back by copying the `blockade_lt/` folder to the first computer's `teacher_play/`.
