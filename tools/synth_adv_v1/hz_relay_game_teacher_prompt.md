# Teacher task: one whole lost game. Find where it went wrong, then write the plan for every relay turn

Read this whole file before you write anything. It contains everything you need. Do not open any other file, do not search
the codebase, do not run code. The only tool use allowed: write the answers file named at the very end, then check it parses.

## 1. The project (why you are doing this)
- A small local model, Qwen3.5-9B with a LoRA adapter (called "the student"), commands the RED side of a turn-based hex
  wargame against a scripted BLUE. In real use it must answer within about 5 seconds per turn, on a GPU with 8 GB, mostly
  with thinking turned off. So whatever plan it follows has to be short and concrete enough to be executed turn by turn by
  that model, without long reasoning.
- The student is already good at giving per-turn orders. Its weakness is the PLAN (its strategy for the whole battle):
  across 56 recorded games it never once changed the plan it wrote on turn 1, whatever happened on the board.
- Telling it in the conversation "re-plan now" does not work (asked 26 times: it wrote a plan 3 times, changed one 0 times).
  So we use RELAYS: on turns 10, 20, 30, 40 and 50 the student's conversation is wiped and the current board is shown to it as
  if it were the start of a new battle (same turns left). This "fresh commander" writes a plan and plays on with that short
  conversation until the next relay. The goal is to teach the student, at a relay, to write the right plan for the board in
  front of it: keep a plan that still fits, and replace one that does not.
- Your answers become the training targets. For each relay turn: input = exactly the relay prompt the student saw at that turn
  (shown below), target = your plan. Your plans will also be tested in the real game engine: the game is replayed exactly up
  to that relay turn, your plan is put in as the commander's plan, and the student plays on from there with it. So a plan that
  the student cannot carry out, or that does not win, is a bad target.
- Only games the student did NOT win are given to teachers. This file is one of them.

## 2. The game
The rules the student is given are the system prompt, quoted in full in section 7. Treat it as the complete rule set.
Everything else here only explains the setup:
- 60 turns. RED wins only by destroying the BLUE HQ. RED loses if its own HQ is destroyed. Results you will see:
  RED_WIN / WIN (BLUE HQ destroyed), NOT_ACHIEVED or CAP (turn 60 passed, no HQ fell: a failure for RED), LOSS (RED HQ fell).
- BLUE is a scripted bot, not a model. Two kinds of games:
  - BASIC and INTER: BLUE is the "GX" utility bot at two difficulty settings (INTER is the harder one).
  - BLOCKADE: BLUE is a scripted bot that surrounds its own HQ: it moves defending units onto the 6 hexes touching the BLUE HQ
    and holds them there. The scenario exists to give RED a reason to change its plan during the game.
- Each relay prompt and (in the game's own turn messages) the board carry a FACTS block computed by code: occupancy of the 6
  hexes touching the enemy HQ, which RED ranged units can hit the HQ right now, which melee units are ordered at the HQ but
  cannot reach it, the state of RED's own HQ. FACTS are exact.
- Turn messages: "events" = what happened since the last answer, e.g. "t11 B_ARC_2 attack R_INF_2: dealt 33 took 0" (the
  attacker killed 33 soldiers, lost 0), "fieldworks -N" = damage to fieldworks (dig-in hit points that absorb damage first).
  Then one line per unit with position, soldiers or troops band, fieldworks, eta. RED's own moves are not listed in events.

## 3. The two relay conditions
The header of the game says which one this game used:
- history "no": the relay prompt shows only the board (+FACTS) and the instruction to write a plan and orders.
- history "yes": it also shows the plan standing at that moment and a one-line summary of the last 10 turns, and tells the
  student it may KEEP the plan (start the plan with "KEEP:" and say why it still fits) or REVISE it (start with "REVISE:").

## 4. What you must do
1. Read the whole game from turn 1 to the end. Replay it in your head as the stronger commander you are.
2. Find where it went wrong and why: the plan (wrong for the board, or right once but kept after the board changed), the
   execution (orders that did not carry out the plan, units left idle, empty answers), the short memory after relays, or a
   mix. Name the turn from which it went wrong. Base this on what the log shows, not on guesses.
3. For EVERY relay turn listed in the header, decide what the fresh commander at that turn should have planned, judging from
   the board shown at that turn:
   - "KEEP" when the plan standing at that turn was the right plan for that board. Say why it still fits.
   - "REVISE" when it was not. Say what was wrong with it for this board and what it has to change to.
   Then write the plan. On a "KEEP" the plan restates the standing plan (you may tighten deadlines to the turns left).
   At turn 10 of a history "no" game the standing plan is the one the student wrote on turn 1 (see the log).
4. Self-check every answer against section 5 before writing the file.

## 5. Rules for the answers (code checks these; an answer that breaks one is thrown away)
DO:
- "plan": at most 300 characters (count them), beginning with "KEEP: " or "REVISE: " matching "decision". A whole-battle
  plan ending in the destruction of the BLUE HQ: phases that name RED unit ids, an absolute turn deadline for each phase
  (within the turns left), and what to do if a phase fails.
- "reason": at most 200 characters, about the board at that relay turn.
- Use only RED and BLUE unit ids that are alive on the board of that relay turn.
- Judge each relay turn from its own board. You may use the rest of the log to understand the game, but the reason and
  the plan must stand on what that board shows.
DO NOT:
- Do not write orders. Plans only. (The student writes the orders; we test whether it can follow your plan.)
- Do not write kill quotas ("kill 5 units", "3 of 8 destroyed", "need 6 kills"). Killing units counts only as a step
  toward the BLUE HQ.
- Do not mention the future or the log: no "hindsight", "later", "in the end", "as the game showed", "the student", "as an AI".
  Write as the commander standing at that turn.
- Do not invent rules, unit abilities or numbers that are not in the system prompt or on the board.
- Do not REVISE just to be different. If the standing plan is right for the board and the game was lost for another reason
  (execution, memory), the answer is KEEP.
- Do not paraphrase a failed plan and call it REVISE: a REVISE changes what the units actually do.
- No prose outside the JSON.

## 6. Output
ONE JSON object, written to the file named at the end:
{"game": "<game id exactly as in the GAME header>",
 "what_went_wrong": "<at most 400 characters: plan, execution, memory or a mix; from which turn; why>",
 "relays": [{"turn": <relay turn>, "decision": "KEEP" | "REVISE", "reason": "<...>", "plan": "KEEP: ..." | "REVISE: ..."}, ...]}
One entry per relay turn in the header, in turn order. Shape example (placeholders, not advice):
{"game": "c9/BASIC_histno/t_EXAMPLE_s1", "what_went_wrong": "<...>",
 "relays": [{"turn": 10, "decision": "REVISE", "reason": "<...>", "plan": "REVISE: <phase 1: units, deadline T..> <phase 2 ..> <if phase 1 fails ..>"}]}
