# You play RED in a hex wargame, one turn at a time, by answering request files

Read this whole file before you start. Then play continuously until you are told to stop (section 6).

## 1. Why (the project)
- A small local model, Qwen3.5-9B ("the student"), commands RED in this game. It gives decent per-turn orders but has no real
  strategy: it writes a plan on turn 1 and never changes it, whatever happens. In real use it must answer in about 5 seconds per
  turn on an 8 GB GPU, mostly without thinking.
- Your games become its training data: every turn you play = one training example (the exact request you saw -> your answer).
  Only games you WIN are kept. So: play to win, and play the way the student should learn to play: a clear plan, orders that
  carry the plan out, and a fresh judgement of the plan whenever the board changes.
- Every 10 turns (turns 10, 20, 30, 40, 50) your conversation is wiped and the board is shown to you as if the battle were
  starting now (same turns left): a RELAY. Some games also show you your standing plan and a summary of the last 10 turns.
  Between relays you see a short conversation: the relay message, your answer, and the turns since.

## 2. The game
The complete rules are the system message inside every request (`messages[0]`). Read it carefully once; it is the same in
every request of a game. Summary only: 60 turns; RED wins ONLY by destroying the BLUE HQ; RED loses if its HQ is destroyed;
reaching the turn limit without either is a failure. BLUE is a scripted bot. Three kinds of games, played in rotation:
BASIC and INTER (BLUE = a utility bot, INTER is harder) and BLOCKADE (BLUE moves defenders onto the 6 hexes touching its HQ
and holds them). The FACTS block in the messages is computed by the game and exact.

## 3. The protocol (exactly this, nothing else)
1. Read `D:\Game development\Demon slayer\StrategyGame\artifacts\brain_pipeline_v1\synth_adv_v1\teacher_play\<NAME>\CURRENT.txt`.
   It holds the path of the folder of the game being played now (the "inbox").
2. In the inbox, requests appear as `req_0001.json`, `req_0002.json`, ... one per RED turn, in order. A request is open when
   there is no `resp_NNNN.txt` with the same number. The game waits for your answer to it before it goes on.
3. Open the lowest-numbered open request. It is JSON: `"messages"` = the conversation exactly as the commander sees it
   (system rules, then user/assistant turns; the LAST user message is the current turn), `"turn"`, `"state"` (the same board
   as data), `"retry"` (true = your previous answer to this turn could not be used: fix it).
4. Decide your answer and write it to `resp_NNNN.txt` (same number) in the inbox. Write it atomically: first write
   `resp_NNNN.txt.tmp`, then rename it to `resp_NNNN.txt`. The file content is ONE JSON object and nothing else.
5. Wait for the next request (poll the inbox every few seconds). When a game ends, CURRENT.txt changes to the next game's
   inbox: re-read CURRENT.txt whenever no new request has appeared for 30 seconds, and continue there.

## 4. Your answer (follow the reply format in the system message exactly)
- `{"orders": {...}}` with only the units whose order changes; `{"orders": {}}` keeps every order. Orders stand until replaced.
- `"plan"`: at most 300 characters. On turn 1 and on every RELAY turn you MUST include a plan. A plan names the RED units by id,
  has phases with absolute turn deadlines, says what to do if a phase fails, and ends in destroying the BLUE HQ.
  On other turns include `"plan"` only when you change strategy.
- On a RELAY turn whose message shows your standing plan: start the plan with `KEEP: ` (the plan still fits this board; say why
  in the plan text) or `REVISE: ` (it does not; the new plan). Judge it from the board in front of you. Do not change a plan that
  still fits just to change it; do change it the moment the board shows it is not working.
- Give orders that actually carry out your plan this turn.

## 5. Do / do not
DO: play every turn of every game to the end; play to win; keep answers short and concrete.
DO NOT:
- Do not read, open or search any file other than CURRENT.txt and the req files of the current inbox. Do not look at BLUE's
  files, the game code, logs or earlier games.
- Do not create, edit, rename or delete anything except writing your `resp_NNNN.txt` (via its .tmp).
- Do not answer a request twice, do not skip a request, do not answer requests of an old inbox.
- No prose, markdown, code fences or reasoning text in a resp file: ONE JSON object only.
- No kill quotas in a plan ("kill 5 units", "3 of 8"). Units matter only as a way to reach and destroy the BLUE HQ.
- Do not invent rules or unit abilities that are not in the system message.

## 6. Stop
Stop when CURRENT.txt says `none (stopped)`, or when the user tells you to. Never stop on your own between games.
Each game must finish within 4 hours, so answer each request within a few minutes.
