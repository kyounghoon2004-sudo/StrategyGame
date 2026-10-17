# Plan review batch — you are the TEACHER

## The situation
A small student model (Qwen) commands the RED side of a hex wargame. RED wins only by destroying the BLUE HQ (there are no kill
quotas). The student writes a one-sentence PLAN (its strategy for winning, max 300 chars) on turn 1 and then almost NEVER changes
it, whether or not the plan still fits the battle. Its per-turn orders are already good. What it must learn is JUDGING ITS OWN
PLAN: keep it when it is still right (and say why), replace it when the battle no longer fits it (and say why, and what instead).

You are a much stronger commander than the student. For every ITEM below you are shown:
1. the student's current standing plan,
2. the game packet the student sees this turn,
3. HINDSIGHT: what happened over the next turns of this same game and how the game ended. The student will NOT have this when
   it is trained; you use it to know whether the plan was working. Never mention "hindsight", "the next turns" or future facts in
   your text: write as if you judged from the board at this turn.

## What you must decide for each item
VERDICT = "keep" or "revise".
- keep: the standing plan is still the right way to win from THIS board. Typical reasons: the plan's phase is progressing (units
  are closing, the enemy HQ fieldworks are falling, the enemy is not blocking), or the board changed but the plan already covers it.
  A plan that is null/missing counts as a bad plan (verdict revise: write the opening plan).
- revise: the plan no longer fits. Typical reasons: the objective it names is dead/blocked/unreachable (e.g. all six hexes around
  the enemy HQ are held so melee cannot strike it; the plan sends everyone at the HQ), units are being spent for no damage
  (dealt 0 against fortified targets), a threat to the RED HQ appeared that the plan ignores, the plan chases kill counts, or no
  progress was made for many turns. Then write the plan that would actually win from this board.

Balance matters. Do NOT revise just because a revision is possible, and do NOT keep just because the plan once worked. Use
the hindsight honestly: if the next turns show steady progress under the standing plan, the answer is keep; if they show a long
stall, wasted attacks, or a loss of units for nothing, the answer is revise.

## What you write (ONE field, "text", at most 300 characters, English)
- keep:   "KEEP: <one clause: what the board shows and why the plan still wins>. <the plan restated, with the next phase and the turn by which it should be done>"
- revise: "REVISE: <one clause: what the board shows and why the old plan fails>. <the new whole-battle plan: phases that name unit ids, a turn deadline per phase, what to do if a phase fails>"

Hard rules for "text":
- starts with exactly "KEEP:" or "REVISE:"; at most 300 characters in total (count them);
- uses only RED/BLUE unit ids that appear in this item's packet; numbers only from the packet or the turn deadline you set;
- no kill quotas ("need 5 kills"), no mention of hindsight, no mention of the student, no "as an AI";
- a revise must change the STRATEGY (what is attacked, in which order, what is held), not just repeat the old plan in other words;
- a keep must contain a real reason tied to this board, not "the plan is good".

## Output
Write ONE JSON array to the answers file named at the end of the batch, one object per item, in order:
`[{"item": "<id exactly as in the ITEM header>", "verdict": "keep"|"revise", "text": "<KEEP:/REVISE: ... max 300 chars>"}]`
Use only this file's content; do not read other files, do not search the codebase, do not use tools other than writing the answers
file and validating that it parses.

## Worked examples (ids fictional)
Standing plan: "Archers shell the HQ while the infantry marches and breaks it." Board: ring of B_HQ_9 full (6 units fortified),
R_INF_1/R_INF_2 stand adjacent with dealt 0, nothing changed for 8 turns; hindsight: stall to turn cap.
-> {"verdict":"revise","text":"REVISE: all six hexes around B_HQ_9 are held and the infantry deal 0 to fortified units. Phase 1 by T30: all melee focus B_ARC_1 (weakest ring unit); phase 2 by T38: step into the freed hex and strike the HQ; archers keep shelling; if B_ARC_1 holds past T30, switch to B_SPE_2."}
Standing plan: "Archers strip the HQ fieldworks while spearmen screen; strike with cavalry when fieldworks are gone." Board: B_HQ fieldworks 132 -> 60 over 5 turns, no ring blocking; hindsight: HQ destroyed at turn 31.
-> {"verdict":"keep","text":"KEEP: the HQ fieldworks are falling about 14 a turn with no ring unit in the way, so the screen-and-strip plan is working. Archers keep shelling; R_CAV_1 and R_CAV_2 strike by T26, when fieldworks reach 0."}
