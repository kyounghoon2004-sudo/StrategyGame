# Blockade teacher games on a second computer

Goal: collect BLOCKADE games (BLUE = scripted ring-the-HQ bot) on a laptop, because the first computer is full (Strata server).
Blockade so far: cloud teachers 0 wins, Strata 0/4 (see handoff). This setup only makes the games runnable; the teacher choice is open.

## What a game needs
| part | where | note |
|---|---|---|
| Godot 4.2.2 headless game | `project.godot` (repo) | any CPU, set `SG_GODOT` to the *console* exe |
| game-side Python | `SG_PY` (default `python`) | needs only what `tools.synth_adv_v1.spar_teacher` imports; install what a smoke run reports missing |
| Hands A/B worker (CPU) | `tools/cloud_pipeline/hands_worker.py`, started by `tools/cmd_rl/spar.py` with `--device cpu` | no GPU; ~1.3 GB weights, loads in ~20 s; **the game refuses to start without it** (see below) |
| relay shim + blockade bot | `tools/synth_adv_v1/relay_shim.py`, `tools/cmd_rl/blockade_bot.py` | stdlib only |
| the teacher (answers `req_NNNN.json` -> `resp_NNNN.txt`) | another process | see below |

## Files that are NOT in git (copy by hand)
`StrategyGame_hands_bundle_2026-10-17.zip` (Hands A + B weights and renderer, sha-pinned in hands_worker.py): unzip into the repo root so that
`artifacts/laya_hand_a_v1/run1/checkpoints/best/model.safetensors`, `artifacts/laya_hand_a_v1/run1/hand_a_render.py` and
`artifacts/laya_hand_b_v1/run1/final/model.safetensors` exist. The worker checks their sha256 at start; a mismatch means a wrong file.
Also `assets/` (see StrategyGame_assets_2026-10-17.zip).
`laya-multilingual` (322M) is loaded by `tools/laya/worker.py` from the Hugging Face hub (`convaiinnovations/laya-multilingual`);
offline, copy `D:\LayaRuntime\models\laya-multilingual` from the first computer and point to it. Not tested on a clean machine.

## Why Hands is still needed
Hand A/B are retired as a design: in a whole INTER game the worker log shows only READY and two health checks, zero inference requests.
But the game mounts the "full pipeline" (`Cloud2Mount ... red=CLOUD+HAND_AB`) and its watch aborts on turn 1 when the worker is off
(`ABORT SERVER DISABLED: brain= hands=EXPLICIT_OFF`, tried with `LAYA_ENABLE=0`: every game ABORTED within 10 s).
So the worker must answer its health handshake. Removing that dependency means changing the Godot mount, not done.

## Hands venv (CPU is enough)
```
python -m venv C:\LayaRuntimeenv
C:\LayaRuntimeenv\Scripts\pip install -r tools/synth_adv_v1/laya_requirements.txt
```
(`torch==2.9.0`, the default CPU wheel on Windows. The file is a freeze of the first computer's venv, whose torch is +cu129; the CPU path was not tried on a clean machine.)

## Run
```
export SG_PY=/c/path/to/python.exe SG_GODOT=/c/path/Godot_v4.2.2-stable_win64_console.exe SG_LAYA_PY=/c/LayaRuntime/venv/Scripts/python.exe
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
`tools/contextual_brain/rl_vs_utility.py` (`SG_ROOT`, `SG_GODOT`, `SG_PY`, `SG_LAYA_PY`) and `tools/brain_review/harvest.py` (`SG_ROOT`).
Not yet run end to end on a second machine: the first smoke game there will show what is still missing.
Merge the collected games back by copying the `blockade_lt/` folder to the first computer's `teacher_play/`.
