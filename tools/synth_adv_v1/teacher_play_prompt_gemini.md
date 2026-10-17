# EXACT PROCEDURE: play RED, one turn at a time, by hand

You are a game player, not a programmer. You will execute the procedure below step by step, by hand, for every turn.
Read this whole file first. Then also read `D:\Game development\Demon slayer\StrategyGame\tools\synth_adv_v1\teacher_play_prompt.md`
once (background and rules). Where the two files differ, THIS file wins.

## 0. ABSOLUTE PROHIBITIONS (breaking any of these makes the whole run worthless and it will be thrown away)
P1. Do NOT write any program, script, loop, batch file, PowerShell/Python/Node/bash file or one-liner that reads requests
    and writes answers. Do NOT start any background process or scheduled job. Every answer file is written by you,
    with your file-writing tool, after you have read that request yourself.
P2. Do NOT generate answers from a template. Do NOT copy an earlier answer and change only the numbers. Every plan must
    name the units, positions and situation of the board in front of you.
P3. Do NOT answer a request you have not opened and read in this same step.
P4. Do NOT read, list or touch any folder except: your CURRENT.txt and the inbox it names. Do not read game code, logs,
    BLUE's files, t1 or t2 folders.
P5. Do NOT create, edit, rename or delete anything except `resp_NNNN.txt.tmp` -> `resp_NNNN.txt` in the inbox.
P6. Do NOT spawn agents or sub-tasks.
Allowed shell commands, and ONLY these: listing the inbox, reading a file, a wait of up to 10 seconds
(`powershell -Command "Start-Sleep -Seconds 10"`), and renaming your .tmp answer file to its final name.

## 1. Variables
- CURRENT = `D:\Game development\Demon slayer\StrategyGame\artifacts\brain_pipeline_v1\synth_adv_v1\teacher_play\gflash\CURRENT.txt`
- INBOX = the path written inside CURRENT (read it in step A).
- PLAN = the plan you are following now (empty at the start, and empty again after every RELAY: see step D).

## 2. Main loop (repeat until step A says stop)
A. Read CURRENT. If it says `none (stopped)`: write one line "answered N requests" and END. Otherwise set INBOX to its content.
B. List INBOX. Find the lowest number NNNN that has `req_NNNN.json` but no `resp_NNNN.txt`.
   - None found: wait 10 seconds (allowed command), then go to A. If you have waited 6 times in a row, still go to A.
C. Open `req_NNNN.json` and read it. Note:
   - TURN = field "turn".
   - RETRY = field "retry" (true means your last answer for this turn was rejected: re-read the system message's reply format).
   - LAST = the content of the LAST message with role "user" in "messages". This is the current turn.
   - The FIRST message (role "system") is the rule book. Read it fully the first time you see a request of a game.
D. Decide what kind of turn this is:
   - RELAY turn: LAST starts with `{"request":"VICTORY_COMMAND"` (a full board, as at the start of a battle). This happens on
     turn 1 and on turns 10, 20, 30, 40, 50. On a RELAY the conversation was wiped: forget PLAN.
   - NORMAL turn: LAST starts with `{"turn":`. It lists "events" (what happened) and one line per unit.
E. Analyse the board in LAST, in this order, and write your notes in your own reasoning (not in a file):
   E1. My units: id, position, soldiers, current order. Which are alive? (A unit missing from the list is dead.)
   E2. Enemy units: id, position, troops; where is B_HQ (the BLUE HQ) and how far is each of my units from it.
   E3. FACTS block (only on RELAY turns and where present): how many of the 6 hexes touching the BLUE HQ are held by BLUE
       units; which of my archers can hit the HQ now; which melee units are ordered at the HQ but cannot reach it.
   E4. Events (NORMAL turns): what did BLUE do, what did my units deal and take? Is my plan on schedule (compare with the
       deadlines in PLAN)? Is any unit idle, stuck, or attacking something that no longer matters?
F. Decide the answer:
   F1. RELAY turn: write a NEW plan for THIS board (at most 300 characters): phases that name RED unit ids, an absolute turn
       deadline for each phase (turn numbers between TURN and 60), what to do if a phase fails, ending with the BLUE HQ
       destroyed. If LAST contains "Your standing plan so far", start the plan with `KEEP: ` when that plan still fits this
       board (say why in the plan), or `REVISE: ` when it does not. If LAST does not contain it, write no prefix.
       Set PLAN to this plan.
   F2. NORMAL turn: keep PLAN unless E4 shows it is failing (a deadline missed, the route blocked, the main group lost).
       If it is failing, write a new plan (rules of F1, no prefix) and set PLAN to it. Otherwise write no "plan" key.
   F3. Orders: only for units whose order must change THIS turn to carry out PLAN (units keep their last order otherwise).
       Use only ids of living units; targets only living BLUE ids or "ENEMY_HQ". Check each order against the rules in the
       system message (e.g. melee cannot strike an HQ whose 6 touching hexes are all occupied; RAID is for CAVALRY only).
       If no order needs to change, orders = {}.
   F4. Never write kill quotas ("kill 3 units"). Never put text outside the JSON.
G. Write the answer: create `INBOX\resp_NNNN.txt.tmp` with exactly one JSON object, e.g.
   `{"plan": "...", "orders": {"R_INF_1": {"do": "ATTACK", "target": "ENEMY_HQ"}}}` or `{"orders": {}}`,
   then rename it to `INBOX\resp_NNNN.txt`. Then go to A.
   G1. Write the .tmp file ONLY with your file-writing tool (write_file). NEVER write it with a shell command (echo, Set-Content,
       Out-File, cmd redirection): the shell strips the double quotes and the game rejects the answer and the whole game is lost.
   G2. After writing the .tmp, READ IT BACK and check character by character: every key and every string value is wrapped in
       straight double quotes ("), there is no backslash (\) anywhere, braces balance. If anything is wrong, write the .tmp again
       with write_file. Only then rename it to resp_NNNN.txt.

## 3. Self-check before every write (G)
- Did I open and read this exact req_NNNN.json in step C of this same iteration? (P3)
- Is this answer written by me now, not produced by a script or copied from an earlier answer? (P1, P2)
- On a RELAY turn: does the answer have a "plan" that mentions this board's units and turn deadlines after TURN?
- Is it ONE valid JSON object and nothing else?
