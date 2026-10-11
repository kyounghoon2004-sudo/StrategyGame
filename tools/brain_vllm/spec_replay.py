"""BRAIN_VLLM_PHASE1 — replay the s0b/s0c corpus builders to reconstruct the
harness scenario (render_spec output) for every prompt_id in the DEV splits.

The corpus builders keep specs in memory only; sft_rows.jsonl records
prompt_id = "<sid>|base" | "<sid>|v<j>_<family>_<kind>" and the prompts files
store just the messages. This module replays the deterministic builders
(base_battle / variants / teacher are functions of the episode files and fixed
seeds) and then VERIFIES each reconstruction byte-for-byte by re-rendering the
prompt through the production Godot harness and comparing to the stored
messages in s0b_prompts.json / s0c_prompts.json.

One known quirk of the original builders: the control variants pick their
class with `max(set(mine), key=mine.count)`, whose tie-break order depends on
per-process Python hash randomization. For every mismatching control
tiny_attack_nudge pid the replay therefore tries all candidate classes and
keeps the one whose rendered messages equal the stored ones (the stored
messages are the ground truth).

  python -m tools.brain_vllm.spec_replay --out artifacts/brain_pipeline_v1/vllm/specs_replay.json

Never writes into the corpus artifact dirs; never opens sealed probes.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

S0B = ROOT / "artifacts" / "contextual_brain_s0b"
S0C = ROOT / "artifacts" / "contextual_brain_s0c_corpus"


def _build_s0b():
    import tools.contextual_brain.s0b_corpus as C
    from tools.contract_sft import harness as H
    specs = sorted(C.EPIS.glob("*.json"))
    bases = [C.base_battle(p, k, flat=(k == 0)) for p in specs for k in range(3)]
    for i, bt in enumerate(bases):
        bt["sid"] = f"s0bb{i:03d}"
    rendered = H.build_prompts([C.render_spec(bt, bt["sid"]) for bt in bases])
    cand, repair = {}, {}
    for bt, r in zip(bases, rendered):
        assert "error" not in r, r
        pkt = json.loads(r["messages"][1]["content"])
        plan, dec = C.teacher(pkt, bt["rng_seed"])
        if plan is None:
            continue
        bt["dec"] = dec
        cand[f"{bt['sid']}|base"] = C.render_spec(bt, bt["sid"])
        mine = [c for c in bt["rosters"][bt["side"]][0] if c not in ("scout", "hq")]
        for j, (factor, kind, v) in enumerate(C.variants(bt, dec, pkt)):
            pid = f"{bt['sid']}|v{j}_{factor}_{kind}"
            cand[pid] = C.render_spec(v, bt["sid"])
            if factor == "control" and kind == "tiny_attack_nudge":
                repair[pid] = {"bt": bt, "v": v, "mine": mine}
    return cand, repair, C


def _build_s0c():
    import tools.contextual_brain.s0c_corpus as C
    from tools.contract_sft import harness as H
    spec_paths = sorted(C.EPIS.glob("*.json"))
    bases = []
    for spec_idx, p in enumerate(spec_paths):
        for k in range(3):
            bases.append(C.base_battle(p, k, flat=(k == 0), spec_idx=spec_idx))
    for i, bt in enumerate(bases):
        bt["sid"] = f"s0cb{i:03d}"
    rendered = H.build_prompts([C.render_spec(bt, bt["sid"]) for bt in bases])
    cand, repair = {}, {}
    var_specs = []
    for bt, r in zip(bases, rendered):
        assert "error" not in r, r
        pkt = json.loads(r["messages"][1]["content"])
        plan, dec = C.teacher(pkt, bt["rng_seed"])
        if plan is None:
            continue
        bt["plan"], bt["dec"] = plan, dec
        cand[f"{bt['sid']}|base"] = C.render_spec(bt, bt["sid"])
        for j, (family, kind, v) in enumerate(C.variants(bt, dec, pkt)):
            var_specs.append((bt, family, kind, v, f"{bt['sid']}|v{j}_{family}_{kind}"))
    for i in range(0, len(var_specs), 150):
        chunk = var_specs[i:i + 150]
        res = H.build_prompts([C.render_spec(v, bt["sid"]) for bt, _, _, v, _ in chunk])
        for (bt, family, kind, v, pid), r in zip(chunk, res):
            assert "error" not in r, r
            cand[pid] = C.render_spec(v, bt["sid"])
            if family == "H" and kind == "tiny_attack_nudge":
                mine = [c for c in bt["rosters"][bt["side"]][0] if c not in ("scout", "hq")]
                repair[pid] = {"bt": bt, "v": v, "mine": mine}
    return cand, repair, C


def _alts(rep, C):
    """All single-nudge candidates for a control pid. rep['v'] already carries the
    current process's own nudge pick, so reset that class to its base value before
    applying each candidate nudge."""
    mine = rep["mine"]
    own = C.rk(max(set(mine), key=mine.count)) if mine else "infantry"
    out = [(own, copy.deepcopy(rep["v"]))]
    seen = {own}
    for c in sorted(set(mine)):
        k0 = C.rk(c)
        if k0 in seen:
            continue
        seen.add(k0)
        v = copy.deepcopy(rep["v"])
        v["rules"]["class_stats"][own]["attack"] = float(rep["bt"]["rules"]["class_stats"][own]["attack"])
        v["rules"]["class_stats"][k0]["attack"] = float(rep["bt"]["rules"]["class_stats"][k0]["attack"]) + 0.25
        out.append((c, v))
    return out


def _verify(H, to_check, cand, prompts, chunk=200):
    bad = []
    for i in range(0, len(to_check), chunk):
        part = to_check[i:i + chunk]
        rendered = H.build_prompts([cand[p] for p in part])
        for pid, r in zip(part, rendered):
            if "error" in r or r["messages"] != prompts[pid]:
                bad.append(pid)
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--verify-sample", type=int, default=100, help="random TRAIN pids to also verify")
    a = ap.parse_args()
    os.environ["BRAIN_CONTRACT_MODE"] = "unalloc_v1"
    os.environ["BRAIN_CONTEXT_PACK"] = "v0"

    from tools.contract_sft import harness as H

    report, out = {}, {"corpora": {}}
    for name, build_fn, dir_, pfile in (("s0b", _build_s0b, S0B, S0B / "s0b_prompts.json"),
                                        ("s0c", _build_s0c, S0C, S0C / "s0c_prompts.json")):
        print(f"[replay] {name}: rebuilding candidate specs ...", flush=True)
        cand, repair, C = build_fn()
        prompts = {p["prompt_id"]: p["messages"] for p in
                   json.loads(pfile.read_text(encoding="utf-8"))}
        rows = [json.loads(l) for l in open(dir_ / "sft_rows.jsonl", encoding="utf-8") if l.strip()]
        dev_pids = [r["prompt_id"] for r in rows if r["split"] == "dev"]
        train_pids = [r["prompt_id"] for r in rows if r["split"] == "train"]
        sample = train_pids[:: max(1, len(train_pids) // max(1, a.verify_sample))][: a.verify_sample]
        to_check = dev_pids + sample
        missing = [p for p in to_check if p not in cand]
        assert not missing, f"{name}: pids missing from replay: {missing[:5]}"
        print(f"[replay] {name}: candidates={len(cand)} dev={len(dev_pids)} checking={len(to_check)}", flush=True)

        bad = _verify(H, to_check, cand, prompts)
        print(f"[replay] {name}: {len(bad)} mismatches before repair "
              f"({sum(1 for p in bad if p in repair)} repairable control pids)", flush=True)

        fixed = 0
        todo = [p for p in bad if p in repair]
        by_pid = {}
        if todo:
            flat = [(spec_pid, c, v) for spec_pid in todo for (c, v) in _alts(repair[spec_pid], C)]
            rendered = []
            for i in range(0, len(flat), 200):
                chunk = flat[i:i + 200]
                rendered.extend(H.build_prompts([C.render_spec(v, spec_pid.split("|")[0])
                                                 for spec_pid, _, v in chunk]))
            for (spec_pid, c, v), r in zip(flat, rendered):
                if "error" not in r and r["messages"] == prompts[spec_pid]:
                    by_pid.setdefault(spec_pid, (c, v))
            for spec_pid, (c, v) in by_pid.items():
                cand[spec_pid] = C.render_spec(v, spec_pid.split("|")[0])
                fixed += 1
        remaining = [p for p in bad if p not in by_pid]
        bad2 = _verify(H, remaining, cand, prompts)
        print(f"[replay] {name}: repaired={fixed} mismatches_after={len(bad2)}: {bad2[:5]}", flush=True)
        assert not bad2, f"{name}: message mismatch after replay+repair: {bad2[:5]}"
        report[name] = {"checked": len(to_check), "dev": len(dev_pids), "sampled_train": len(sample),
                        "control_repaired": fixed, "mismatches_after_repair": 0}
        out["corpora"][name] = {p: cand[p] for p in dev_pids}

    out["verify"] = report
    out["generated_by"] = "tools/brain_vllm/spec_replay.py"
    p = Path(a.out)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(out), encoding="utf-8")
    print(f"[replay] wrote {p} ({p.stat().st_size} bytes)")
    print(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
