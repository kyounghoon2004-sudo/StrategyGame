# Teacher batch — write the plan that WINS from this board

Read this whole file before answering. Do not read any other file. Do not search the codebase. Use no tools except writing the
answers file named at the end and checking that it parses.

## Background (what you are looking at)
A small student model (Qwen 9B) commands the RED side of a hex wargame as a commander. RED wins ONLY by destroying the BLUE
HQ (there are no kill quotas; killing units matters only as a means to reach and break the HQ). RED loses if the RED HQ
falls. The game has 60 turns. Each ITEM below is one moment of one game that the student did NOT win. At that moment the game
was restarted for the student as a "fresh battle start" from the current board: the student wrote a plan and orders from scratch.
You see that board, the student's answer, and (as hindsight) how that game continued and ended.

The student is already good at per-turn execution of orders. What it lacks is a plan that survives contact with the board:
it picks the wrong objective, fixates on killing units instead of the HQ, ignores that the six hexes around the enemy HQ are
held by enemy units (melee units cannot strike the HQ through them), forgets the deadline, or has no fallback.

## What to produce for each ITEM
You are a much stronger commander. Decide what the student should have planned at THIS turn so that RED actually wins this game.
Produce exactly these fields:
- "diagnosis": at most 200 characters. What was wrong with the student's plan/answer for this board, and what the board
  (FACTS and unit positions) really demands. Write it as an analysis of the board, never mention hindsight or "the next turns".
- "plan": at most 300 characters. The whole-battle plan to win from this board. It must have: phases that name unit ids, a turn
  deadline per phase (absolute turn numbers), and what to do if a phase fails. Its final objective is the BLUE HQ.
- "orders": the orders that START this plan this turn, only for units whose order changes (others keep their standing order).
  Schema per unit id: {"do": "ATTACK", "target": "<BLUE unit id>" or "ENEMY_HQ"}, {"do": "MOVE", "to": [q, r]}, {"do": "HOLD"},
  {"do": "FORTIFY"}, {"do": "RAID", "target": "<BLUE unit id>", "back_to": [q, r]}.
- "keeps_student_plan": true only if the student's plan was already the right plan and the game was lost for another reason
  (then still write the plan as above, restating it with the deadline you would set); otherwise false.

## Rules that must hold (they are checked by code; an item that breaks one is thrown away)
1. Use ONLY unit ids that appear in this item's board. Numbers in "plan" must come from the board or be turn deadlines you set.
2. No kill quotas ("need 5 kills", "3 of 8"). No words like "hindsight", "next turns", "the student", "as an AI".
3. A melee unit (infantry, cavalry, scout, spearman) can strike the enemy HQ only from a hex touching it. If all six hexes
   touching it are occupied, ATTACK ENEMY_HQ by a melee unit cannot execute: the plan must first break ONE ring unit (focus
   fire on the weakest, one at a time; fortified units soak earthwork points first) and then step in. Archers within distance
   2-3 of the enemy HQ shoot it over other units: order them ATTACK ENEMY_HQ.
4. Orders on dead or unknown targets do nothing; never order them.
5. Keep your RED HQ safe (FORTIFY) when enemy units can reach it.
6. The plan must differ in STRATEGY from a failed plan (different main target / order of targets / use of archers / timing), not
   be a paraphrase of it.
7. At most 300 characters in "plan" and 200 in "diagnosis". Count them.

## Procedure (follow it for every item, in order)
1. Read the FACTS lines on the board: ring occupancy of the enemy HQ, archers in range, my HQ danger.
2. Read the student's answer: what is it attacking, is it a unit-kill plan, does it have a fallback, is the plan empty?
3. Read the hindsight: where did the game stall (units lost? HQ fieldworks not falling? time ran out?).
4. Write the plan that fixes exactly that, with deadlines that fit the turns left, then the first-phase orders.
5. Self-check rules 1-7. Only then write the item.

## Output format
ONE JSON array, one object per item, in the order of the items:
[{"item": "<id exactly as in the ITEM header>", "diagnosis": "...", "plan": "...", "orders": {"R_ARC_1": {"do": "ATTACK", "target": "ENEMY_HQ"}}, "keeps_student_plan": false}]

## Worked example (fictional ids)
Board: turn 20 of 60; ring of B_HQ_9 held by B_INF_1, B_INF_2, B_SPE_1, B_SPE_2, B_CAV_1, B_CAV_2 (6/6), all fortified;
R_ARC_1 distance 3, R_ARC_2 distance 4 from the HQ; R_INF_1/R_INF_2/R_SPE_1 adjacent to B_INF_1 with dealt 0.
Student answer: orders R_INF_1 ATTACK ENEMY_HQ, plan "Kill 3 enemy units then take the HQ".
Hindsight: HQ fieldworks stayed 180; the game ended at the turn cap.
Correct item:
{"item": "...", "diagnosis": "Ring is 6/6 held, melee cannot reach the HQ and the plan chases kills; archers are idle.", "plan": "T20-26: R_INF_1, R_INF_2, R_SPE_1 focus B_CAV_1 (weakest ring unit); R_ARC_1 shells the HQ. T27-34: step into the freed hex and strike. If B_CAV_1 holds past T26, switch to B_SPE_2.", "orders": {"R_INF_1": {"do": "ATTACK", "target": "B_CAV_1"}, "R_INF_2": {"do": "ATTACK", "target": "B_CAV_1"}, "R_SPE_1": {"do": "ATTACK", "target": "B_CAV_1"}, "R_ARC_1": {"do": "ATTACK", "target": "ENEMY_HQ"}}, "keeps_student_plan": false}
