"""ID-remap augmentation for CONTRACT_SFT_V1 (roster binding / exact pointer copy).

  python -m tools.contract_sft.augment_remap [--copies 2]

Sources: production-valid examples already admitted -- dataset/sft_rows.jsonl
(R1) and intake/B03R1_intake_v1.jsonl. For each source row, K independent
copies. Per copy:
  * friendly map: bijective per class tag (INF, CAV, HQ, ...), side + class
    prefix preserved, numeric suffix drawn from 1..16 (each copy has at least
    one suffix >= 10); never merges two units; never the identity.
  * enemy map: only when the target references a fog-VISIBLE enemy id; then
    a bijective per-class map over the visible enemies is applied to the
    prompt and the target alike. Hidden enemies are never invented or added.
  * prompt: generated scenarios -> the remapped scenario spec is rebuilt by
    the PRODUCTION packet builder (tools/contract_sft_harness.gd);
    rl_A (captured live packet) -> exact token substitution in the user
    packet + the same map on its validation fixture. The system prompt is
    never touched (its literal example ids stay as the lure to resist).
  * target: simultaneous token substitution; nothing else changes.
Checks (reject on any failure): inverse-map(new target) == original target
(no old id left, no stray edit); remapped roster == map(original roster) with
identical classes; every own id in the target is in the new roster; visible
enemy ids used by the target are in the new known_enemy_units; real Godot
production PASS first try; exactly one JSON object; coherence P1-P11.
Output: augment/remap_v1_{rows.jsonl,prompts.json,AUDIT.json}. Not merged.
"""
from __future__ import annotations

import argparse
import collections
import copy
import hashlib
import json
import random
import re
from pathlib import Path

from tools.contract_sft import harness as H
from tools.contract_sft import scenarios as S

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame\artifacts\contract_sft_v1")
UID = re.compile(r"\b([RB])_([A-Z]{2,3})_(\d+)\b")
POOL = list(range(1, 17))


def sha(t) -> str:
    return hashlib.sha256((t if isinstance(t, str) else json.dumps(t, sort_keys=True)).encode("utf-8")).hexdigest()


def sub(text: str, m: dict) -> str:
    return UID.sub(lambda g: m.get(g.group(0), g.group(0)), text)


def make_map(ids, rng: random.Random, need_high: bool) -> dict:
    by_tag = collections.defaultdict(list)
    for u in sorted(ids):
        s, t, _ = UID.fullmatch(u).groups()
        by_tag[(s, t)].append(u)
    for _ in range(200):
        m = {}
        for (s, t), us in by_tag.items():
            nums = rng.sample(POOL, len(us))
            for u, n in zip(us, nums):
                m[u] = f"{s}_{t}_{n}"
        if any(m[k] != k for k in m) and (not need_high or any(int(v.rsplit("_", 1)[1]) >= 10 for v in m.values())):
            return m
    raise RuntimeError("could not draw mapping")


def remap_spec(spec, fmap, emap):
    s = copy.deepcopy(spec)
    for key in ("red_forces", "blue_forces"):
        for u in s[key]:
            u["id"] = fmap.get(u["id"], emap.get(u["id"], u["id"]))
    return s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--copies", type=int, default=2)
    a = ap.parse_args()
    prompts = {}
    for n in ("train_gen", "rl_A"):
        for p in json.loads((ROOT / "prompts" / f"{n}.json").read_text(encoding="utf-8")):
            prompts[p["prompt_id"]] = p
    src = []
    for l in open(ROOT / "dataset" / "sft_rows.jsonl", encoding="utf-8"):
        r = json.loads(l)
        src.append({"src_id": "R1:" + r["row_id"], "prompt_id": r["prompt_id"], "target": r["target"],
                    "split": r["split"]})
    for l in open(ROOT / "intake" / "B03R1_intake_v1.jsonl", encoding="utf-8"):
        r = json.loads(l)
        pv = r["provenance"]
        src.append({"src_id": f"B03R1:{pv['scenario_id']}_{pv['variant_id']}", "prompt_id": r["prompt_id"],
                    "target": r["target"], "split": "train"})
    copies, rebuild = [], []
    for s in src:
        p = prompts[s["prompt_id"]]
        pk = json.loads(p["messages"][1]["content"])
        own = p["side"][0]
        roster = [u["unit_id"] for u in pk["compact_state"]["friendly_units"]]
        visible = [u["unit_id"] for u in pk["compact_state"]["known_enemy_units"]]
        used = {m.group(0) for m in UID.finditer(s["target"])}
        for k in range(a.copies):
            rng = random.Random(int(sha(f"{s['src_id']}|{k}")[:12], 16))
            fmap = make_map(roster, rng, need_high=True)
            # Bijective over ALL enemies of the spec (hidden ones stay hidden:
            # they are not in the prompt), so a visible id can never collide
            # with a hidden unit's id. rl_A fixtures carry no enemies -> the
            # packet's visible list is the whole enemy set there.
            enemy_side = "blue_forces" if own == "R" else "red_forces"
            all_enemy = [u["id"] for u in p["scenario"][enemy_side]] or visible
            emap = make_map(all_enemy, rng, need_high=False) \
                if any(u in visible for u in used if u[0] != own) else {}
            full = {**fmap, **emap}
            c = {"aug_id": f"AUG1:{s['src_id']}#k{k}", "src_id": s["src_id"], "src_prompt_id": s["prompt_id"],
                 "src_split": s["split"], "side": p["side"], "friendly_map": fmap, "enemy_map": emap,
                 "target": sub(s["target"], full), "orig_target": s["target"],
                 "orig_roster": roster, "orig_visible": visible}
            if p["split"] == "rl_A":
                msgs = [p["messages"][0], {"role": "user", "content": sub(p["messages"][1]["content"], full)}]
                c.update(messages=msgs, scenario=remap_spec(p["scenario"], fmap, emap), prompt_method="token_substitution")
            else:
                spec = remap_spec(p["scenario"], fmap, emap)
                spec["scenario_id"] = f"{p['scenario']['scenario_id']}_aug{sha(c['aug_id'])[:8]}"
                c.update(scenario=spec, prompt_method="production_rebuild")
                rebuild.append(c)
            copies.append(c)
    built = H.build_prompts([c["scenario"] for c in rebuild])
    for c, b in zip(rebuild, built):
        c["messages"] = b.get("messages")
        c["build_error"] = b.get("error")
    res = {v["id"]: v for v in H.validate([{"id": c["aug_id"], "text": c["target"], "scenario": c["scenario"]}
                                            for c in copies if c.get("messages")])}
    held_sigs = {p["roster_signature"] for p in json.loads((ROOT / "prompts" / "heldout.json").read_text(encoding="utf-8"))}
    rows, rejects = [], collections.Counter()
    for c in copies:
        codes = []
        own = c["side"][0]
        inv = {v: k for k, v in {**c["friendly_map"], **c["enemy_map"]}.items()}
        if not c.get("messages"):
            codes.append("PROMPT_BUILD_FAILED:" + str(c.get("build_error")))
        else:
            pk = json.loads(c["messages"][1]["content"])
            new_roster = {u["unit_id"]: u["class"] for u in pk["compact_state"]["friendly_units"]}
            old_pk = json.loads(prompts[c["src_prompt_id"]]["messages"][1]["content"])
            old_roster = {u["unit_id"]: u["class"] for u in old_pk["compact_state"]["friendly_units"]}
            if {c["friendly_map"][k]: v for k, v in old_roster.items()} != new_roster:
                codes.append("ROSTER_NOT_BIJECTIVE_IMAGE")
            new_vis = {u["unit_id"] for u in pk["compact_state"]["known_enemy_units"]}
            old_vis = {u["unit_id"] for u in old_pk["compact_state"]["known_enemy_units"]}
            if {c["enemy_map"].get(u, u) for u in old_vis} != new_vis:
                codes.append("VISIBLE_ENEMY_SET_CHANGED")
            if c["prompt_method"] == "token_substitution" and \
                    sub(c["messages"][1]["content"], inv) != prompts[c["src_prompt_id"]]["messages"][1]["content"]:
                codes.append("PROMPT_INVERSE_MISMATCH")
            if S.roster_signature(c["scenario"]) in held_sigs:
                codes.append("HELDOUT_ROSTER_COLLISION")
            used = {m.group(0) for m in UID.finditer(c["target"])}
            if any(u[0] == own and u not in new_roster for u in used):
                codes.append("TARGET_OWN_ID_NOT_IN_ROSTER")
            if any(u[0] != own and u in c["enemy_map"].values() and u not in new_vis for u in used):
                codes.append("TARGET_ENEMY_ID_NOT_VISIBLE")
            if sub(c["target"], inv) != c["orig_target"]:
                codes.append("INVERSE_MAP_MISMATCH")
            if set(c["friendly_map"].values()) & (set(c["orig_roster"]) - set(c["friendly_map"].values())):
                codes.append("OLD_ID_COLLISION")
            v = res[c["aug_id"]]
            if not v["strict_first_pass"]:
                codes.append("PRODUCTION:" + v["category"])
            if not v["plan_coherent"]:
                codes.append("COHERENCE")
        if codes:
            for x in codes:
                rejects[x.split(":")[0]] += 1
            c["reject_codes"] = codes
        rows.append(c)
    ok = [c for c in rows if not c.get("reject_codes")]
    out = ROOT / "augment"
    out.mkdir(exist_ok=True)
    aug_prompts = {}
    with open(out / "remap_v1_rows.jsonl", "w", encoding="utf-8") as f:
        for c in ok:
            pid = "AUGP_" + sha(c["messages"])[:16]
            aug_prompts[pid] = {"prompt_id": pid, "split": "augment_remap_v1", "side": c["side"],
                                "messages": c["messages"], "scenario": c["scenario"],
                                "roster": [u["unit_id"] for u in json.loads(c["messages"][1]["content"])
                                           ["compact_state"]["friendly_units"]],
                                "roster_signature": S.roster_signature(c["scenario"]), "sha256": sha(c["messages"]),
                                "prompt_method": c["prompt_method"], "src_prompt_id": c["src_prompt_id"]}
            f.write(json.dumps({"row_id": c["aug_id"], "prompt_id": pid, "target": c["target"],
                                "target_sha256": sha(c["target"]), "src_id": c["src_id"],
                                "src_prompt_id": c["src_prompt_id"], "src_split": c["src_split"],
                                "friendly_map": c["friendly_map"], "enemy_map": c["enemy_map"],
                                "prompt_method": c["prompt_method"]}, ensure_ascii=False) + "\n")
    (out / "remap_v1_prompts.json").write_text(json.dumps(list(aug_prompts.values()), ensure_ascii=False),
                                               encoding="utf-8")
    suffixes = collections.Counter(int(v.rsplit("_", 1)[1]) for c in ok for v in c["friendly_map"].values())
    tags_lack = sum(1 for c in ok if not {"CAV_1", "INF_2"} <= {v[2:] for v in c["friendly_map"].values()})
    audit = {"version": "CONTRACT_SFT_V1_AUGMENT_REMAP_V1", "sources": len(src), "copies_per_source": a.copies,
             "generated": len(rows), "accepted": len(ok), "rejected": len(rows) - len(ok),
             "reject_code_counts": dict(rejects),
             "rejected_examples": [{k: c[k] for k in ("aug_id", "reject_codes")} for c in rows if c.get("reject_codes")][:40],
             "by_prompt_method": dict(collections.Counter(c["prompt_method"] for c in ok)),
             "by_source": dict(collections.Counter(c["src_id"].split(":")[0] for c in ok)),
             "copies_with_enemy_map": sum(1 for c in ok if c["enemy_map"]),
             "friendly_suffix_distribution": dict(sorted(suffixes.items())),
             "share_suffix_ge_10": round(sum(v for k, v in suffixes.items() if k >= 10) / sum(suffixes.values()), 4),
             "copies_whose_roster_lacks_CAV_1_or_INF_2": tags_lack,
             "copies_with_heldout_roster_signature": sum(1 for p in aug_prompts.values()
                                                          if p["roster_signature"] in held_sigs),
             "distinct_augmented_prompts": len(aug_prompts),
             "system_prompt_modified": False, "merged_into_training": False}
    (out / "remap_v1_AUDIT.json").write_text(json.dumps(audit, indent=1), encoding="utf-8")
    print(json.dumps(audit, indent=1)[:4000])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
