"""EPISODE_TRACEABILITY_V0 verifier: every Brain call + Hands decision carries the
exact installed episode (id + spec path); legacy runs carry neither.

  python tools/episode_traceability_verify.py
"""
import json
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
ART = ROOT / "artifacts" / "episode_traceability_v0"
SPECS = ROOT / "artifacts" / "generalized_episode_env_v0"
RUNS = {"nominal": "samples_0", "broad": "samples_2", "legacy": None}


def rows(path):
    return [json.loads(l) for l in Path(path).read_text(encoding="utf-8").splitlines() if l.strip()]


def main():
    out, ok = {}, True
    for name, sample in RUNS.items():
        fp = json.loads((ART / "runs" / name / "fp_raw.json").read_text(encoding="utf-8"))
        brain = [r for r in rows(ROOT / "artifacts" / "contract_sft_v1" / "human_benchmark" / f"trace_{name}" / "calls.jsonl")
                 if r.get("kind") == "BRAIN_CALL"]
        hands = [r for r in rows(fp["hands_service"]["worker_identity"]["log_path"]) if r.get("kind") in ("HAND_A", "HAND_B")]
        if sample:
            spec = json.loads((SPECS / f"{sample}.json").read_text(encoding="utf-8"))
            want = {"episode_id": spec["episode_id"], "episode_spec_path": str(SPECS / f"{sample}.json").replace("\\", "/")}
            bad = [r.get("call_seq", r.get("t")) for r in brain + hands
                   if {k: r.get(k) for k in want} != want]
        else:
            want = None
            bad = [r.get("call_seq", r.get("t")) for r in brain + hands if "episode_id" in r or "episode_spec_path" in r]
        res = {"expected": want, "brain_calls": len(brain), "hand_a": sum(r["kind"] == "HAND_A" for r in hands),
               "hand_b": sum(r["kind"] == "HAND_B" for r in hands), "rows_wrong": len(bad),
               "pipeline_ok": fp["stop_reason"] == "TARGET_REACHED" and fp["turns"][-1]["fallbacks"] == 0
               and fp["turns"][-1]["exec_failures"] == 0 and not fp["turns"][-1]["brain_contract_units"],
               "hands_log": fp["hands_service"]["worker_identity"]["log_path"]}
        res["pass"] = bool(brain) and bool(hands) and not bad and res["pipeline_ok"]
        ok &= res["pass"]
        out[name] = res
    out["verdict"] = "PASS" if ok else "BLOCKED"
    (ART / "TRACE_RESULTS.json").write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
