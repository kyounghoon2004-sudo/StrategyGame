"""Resident SFT rows -> multi-turn conversations (2026-10-10).

Rows of one game whose messages extend each other (row j+1 = row j's messages + its answer + the next turn message)
form one conversation: the prompt is encoded once per conversation instead of once per row. A fold of old turns into
the BATTLE DIGEST breaks the chain; a new conversation starts there. The assistant messages inside the conversation are
replaced by the rows' (normalized) completions: in play the history holds the model's own replies, so the trained
model's answers are what it will see there. Every assistant message is a training target.

  python -m tools.cmd_rl.build_sft_multiturn <rows.json> <out.json>
Output rows: {"messages": [... ending with the last assistant answer], "multi": true, "turns": n, "game", "mission"}
"""
from __future__ import annotations

import collections
import json
import sys
from pathlib import Path


def main():
    rows = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    by = collections.defaultdict(list)
    for r in rows:
        by[(r.get("mission", ""), r.get("source", ""), r["game"])].append(r)
    out = []
    for (mission, source, game), rs in by.items():
        rs.sort(key=lambda r: r["turn"])
        seg = []
        for r in rs:
            prev = seg[-1] if seg else None
            m = r["messages"]
            if prev is not None:
                pm = prev["messages"]
                cont = (len(m) == len(pm) + 2 and m[len(pm)]["role"] == "assistant"
                        and all(a == b for a, b in zip(m[:len(pm)], pm) if a["role"] != "assistant")
                        and all(a["role"] == b["role"] for a, b in zip(m[:len(pm)], pm)))
                if not cont:
                    out.append(close(seg, mission, game))
                    seg = []
            seg.append(r)
        if seg:
            out.append(close(seg, mission, game))
    Path(sys.argv[2]).write_text(json.dumps(out), encoding="utf-8")
    print("rows %d -> conversations %d (turns per conversation %.1f)" % (len(rows), len(out), len(rows) / max(1, len(out))))


def close(seg: list, mission: str, game: str) -> dict:
    last = seg[-1]
    msgs = [dict(x) for x in last["messages"]]
    # the assistant messages of this conversation, in order, are the answers of seg[0..n-2]
    a_idx = [i for i in range(len(seg[0]["messages"]), len(msgs)) if msgs[i]["role"] == "assistant"]
    for i, r in zip(a_idx, seg[:-1]):
        msgs[i]["content"] = r["completion"]
    msgs.append({"role": "assistant", "content": last["completion"]})
    first_target = len(seg[0]["messages"])  # assistant messages before this index are context, not targets
    return {"messages": msgs, "multi": True, "first_target": first_target, "turns": len(seg), "game": game, "mission": mission}


if __name__ == "__main__":
    main()
