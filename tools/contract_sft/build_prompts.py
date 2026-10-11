"""Build the versioned CONTRACT_SFT_V1 prompt sets (production packet builder).

  train_gen : 128 generated scenarios (seeds 0..), sides alternate
  heldout   : 48 generated scenarios (seeds 50000..) whose ROSTER SIGNATURE
              (side + unit id set) never appears in train_gen, plus no
              identical prompt text; balanced 24 RED / 24 BLUE
  rl_A      : the real RL prompt (bench_prompt_A, RED) and the eval BLUE
              mirror (identical mirror_side() transform as marathon eval)

Writes artifacts/contract_sft_v1/prompts/{train_gen,heldout,rl_A}.json and
PROMPTS_MANIFEST.json (sha256 per prompt + leakage report).
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from tools.contract_sft import harness as H
from tools.contract_sft import scenarios as S

OUT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1\prompts")
PROMPT_A = Path(r"D:\StrategyAI\runtimes\sparkx25\bench\raw\bench_prompt_A.json")
N_TRAIN, N_HELD = 128, 48


def mirror_side(text: str) -> str:  # verbatim transform of marathon_phase_eval.py
    t = text.replace("RED", "__TMP_RED__").replace("BLUE", "RED").replace("__TMP_RED__", "BLUE")
    t = t.replace("R_", "__TMP_R__").replace("B_", "R_").replace("__TMP_R__", "B_")
    t = t.replace("red", "__tmp_red__").replace("blue", "red").replace("__tmp_red__", "blue")
    return t


def sha(messages) -> str:
    return hashlib.sha256(json.dumps(messages, sort_keys=True).encode("utf-8")).hexdigest()


def pack(p, spec, split):
    return {"prompt_id": p["scenario_id"] + "_" + p["side"], "split": split, "side": p["side"],
            "messages": p["messages"], "roster": p["roster"], "snapshot_id": p["snapshot_id"],
            "n_known_enemies": p["n_known_enemies"], "scenario": spec,
            "roster_signature": S.roster_signature(spec), "sha256": sha(p["messages"])}


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    tr_specs = [S.generate(k) for k in range(N_TRAIN)]
    train = [pack(p, s, "train_gen") for p, s in zip(H.build_prompts(tr_specs), tr_specs)]
    tr_sigs = {x["roster_signature"] for x in train}
    tr_sha = {x["sha256"] for x in train}
    cands = [S.generate(k) for k in range(50000, 50400)]
    banned = tr_sigs | {S.roster_signature(S.RLPROOF_RED), S.roster_signature(S.RLPROOF_BLUE)}
    cands = [s for s in cands if S.roster_signature(s) not in banned]
    red = [s for s in cands if s["side"] == "red"][:N_HELD // 2]
    blue = [s for s in cands if s["side"] == "blue"][:N_HELD // 2]
    h_specs = red + blue
    held = [pack(p, s, "heldout") for p, s in zip(H.build_prompts(h_specs), h_specs)]
    # The RL prompt A mirrors what marathon rollout/eval send.
    msgs_red = json.loads(PROMPT_A.read_text(encoding="utf-8"))["messages"]
    msgs_blue = [{"role": m["role"], "content": mirror_side(m["content"])} for m in msgs_red]
    assert "BLUE general" in msgs_blue[0]["content"] and "B_INF_1" in msgs_blue[1]["content"]
    rl = [{"prompt_id": "A_RED", "split": "rl_A", "side": "RED", "messages": msgs_red,
           "roster": [u["id"] for u in S.RLPROOF_RED["red_forces"]], "scenario": S.RLPROOF_RED,
           "roster_signature": S.roster_signature(S.RLPROOF_RED), "sha256": sha(msgs_red)},
          {"prompt_id": "A_BLUE", "split": "rl_A", "side": "BLUE", "messages": msgs_blue,
           "roster": [u["id"] for u in S.RLPROOF_BLUE["blue_forces"]], "scenario": S.RLPROOF_BLUE,
           "roster_signature": S.roster_signature(S.RLPROOF_BLUE), "sha256": sha(msgs_blue)}]
    assert all("error" not in x for x in train + held)
    leak = {"heldout_prompts_identical_to_train": sum(1 for x in held if x["sha256"] in tr_sha),
            "heldout_roster_signatures_in_train": sum(1 for x in held if x["roster_signature"] in tr_sigs),
            "heldout_rosters_equal_rl_A": sum(1 for x in held if x["roster_signature"] in
                                              {r["roster_signature"] for r in rl}),
            "distinct_train_prompts": len(tr_sha), "distinct_heldout_prompts": len({x["sha256"] for x in held})}
    assert leak["heldout_prompts_identical_to_train"] == 0 and leak["heldout_roster_signatures_in_train"] == 0
    assert leak["heldout_rosters_equal_rl_A"] == 0
    for name, rows in (("train_gen", train), ("heldout", held), ("rl_A", rl)):
        (OUT / f"{name}.json").write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
    manifest = {"version": "CONTRACT_SFT_V1_PROMPTS", "builder": "cloud2_general_packet.build_victory_initial "
                "+ VictoryResponse.initial_prompt_for via tools/contract_sft_harness.gd",
                "counts": {"train_gen": len(train), "heldout": len(held), "rl_A": len(rl)},
                "heldout_sides": {"RED": sum(1 for x in held if x["side"] == "RED"),
                                  "BLUE": sum(1 for x in held if x["side"] == "BLUE")},
                "heldout_with_enemy_contact": sum(1 for x in held if x["n_known_enemies"] > 0),
                "train_with_enemy_contact": sum(1 for x in train if x["n_known_enemies"] > 0),
                "leakage": leak,
                "sha256": {x["prompt_id"]: x["sha256"] for x in train + held + rl}}
    (OUT / "PROMPTS_MANIFEST.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    print(json.dumps({k: manifest[k] for k in ("counts", "heldout_sides", "heldout_with_enemy_contact",
                                                "train_with_enemy_contact", "leakage")}, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
