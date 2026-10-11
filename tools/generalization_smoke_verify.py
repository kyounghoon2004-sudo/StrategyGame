"""GENERALIZATION_INTEGRATION_SMOKE_V0 verifier (reads outputs, writes SMOKE_RESULTS.json).

  python tools/generalization_smoke_verify.py [artifact_dir_name]

Inputs (produced by tools/generalization_smoke_probe.gd x2 per episode and
artifacts/cloud_full_pipeline_v0/raw/probe_full_pipeline.gd --episode=...):
  setup/<name>_{a,b}.json|.log, pipeline/<name>/fp_raw.json|godot.log
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(r"D:\Game development\Demon slayer\StrategyGame")
ART = ROOT / "artifacts" / (sys.argv[1] if len(sys.argv) > 1 else "generalization_integration_smoke_v0")
EPISODES = {"nominal": "samples_0", "broad": "samples_2", "heldout": "samples_4"}
FROZEN_HANDS = ROOT / "artifacts" / "cloud_full_pipeline_v0" / "raw" / "runs" / "fp_live_07" / "fp_raw.json"
BAD_LOG = re.compile(r"SCRIPT ERROR|UnitRenderer\] unknown unit class|UtilityBot\] (selection failed|action execution failed|no authorized)"
                     r"|\[Episode\] (invalid|sandbox mode cannot|map failed)|WorkerRefused|SERVER_DISABLED|Traceback")
NORM = {"spearman": "spear", "spearmen": "spear", "archers": "archer", "scouts": "scout", "conscripts": "conscript"}


def norm(c):
    c = str(c).lower()
    return NORM.get(c, c)


def load(p):
    return json.loads(Path(p).read_text(encoding="utf-8"))


def pack_errors(packet, spec):
    bad = []
    ctx = packet.get("context")
    if not ctx:
        return ["no context in the packet sent to CSFT5"]
    rules = spec["rules"]
    if not spec["episode_id"].startswith(ctx["episode"]["id"]) or ctx["episode"]["map"] != spec["map"]["id"]:
        bad.append(["episode", ctx["episode"]])
    for label, row in ctx["rules"]["classes"].items():
        c, st = norm(label), rules["class_stats"][norm(label)]
        if abs(row["mp"] - rules["base_mp"][c]) > .006 or abs(row["atk"] - st["attack"]) > .006 \
                or abs(row["def"] - st["defense"]) > .006 or row["rng"] != st["range"]:
            bad.append([label, row])
    if ctx["mode"]["objective_code"] != spec["objective"]["red"] or ctx["mode"]["episode_mode"] != spec["objective"]["mode"]:
        bad.append(["mode", ctx["mode"]])
    if ctx["map"]["terrain_source"] != "episode_map":
        bad.append("terrain_source")
    return bad


def leaks(packet, spec):
    known = {u["unit_id"] for u in packet["compact_state"]["known_enemy_units"]}
    text = json.dumps(packet, ensure_ascii=False)
    out = [u["id"] for u in spec["armies"] if u["faction"] == "blue" and u["id"] not in known
           and re.search(r"\b%s\b" % re.escape(u["id"]), text)]
    return out + (["armies"] if '"armies"' in text else [])


def main():
    frozen = load(FROZEN_HANDS)["hands_service"]["worker_identity"]
    res = {"episodes": {}, "totals": {}}
    tot = {"setup_checks": 0, "setup_fail": 0, "determinism_fail": 0, "log_errors": 0, "gx_actions": 0,
           "pipeline_red_turns": 0, "hand_b_decisions": 0, "fallbacks": 0, "exec_failures": 0, "pipeline_failures": 0,
           "oob": 0, "dup": 0, "not_in_pool": 0, "brain_alloc_contamination": 0, "pack_mismatch": 0, "leaks": 0,
           "hands_identity_fail": 0, "brain_invalid": 0}
    for name, sample in EPISODES.items():
        spec = load(ROOT / "artifacts" / "generalized_episode_env_v0" / f"{sample}.json")
        e = {"episode_id": spec["episode_id"], "family": spec["family"], "split": spec["split"], "map": spec["map"]["id"],
             "armies": {"red": sum(u["faction"] == "red" for u in spec["armies"]), "blue": sum(u["faction"] == "blue" for u in spec["armies"])}}
        a, b = load(ART / "setup" / f"{name}_a.json"), load(ART / "setup" / f"{name}_b.json")
        e["setup_fails"] = [a["fails"], b["fails"]]
        e["setup_checks"] = {k: v["ok"] for k, v in a["checks"].items()}
        tot["setup_checks"] += len(a["checks"]) + len(b["checks"])
        tot["setup_fail"] += a["fails"] + b["fails"]
        det_keys = ["episode_id", "pack_hash", "state_hash_after_gx", "gx_profile", "gx_phases", "map_units"]
        e["setup_replay_identical"] = all(a.get(k) == b.get(k) for k in det_keys)
        tot["determinism_fail"] += not e["setup_replay_identical"]
        e["gx_actions"] = [p["actions"] for p in a["gx_phases"]]
        tot["gx_actions"] += sum(e["gx_actions"])
        logs = [ART / "setup" / f"{name}_a.log", ART / "setup" / f"{name}_b.log", ART / "pipeline" / name / "godot.log"]
        e["log_errors"] = [m.group(0) for p in logs for m in BAD_LOG.finditer(p.read_text(encoding="utf-8", errors="replace"))]
        tot["log_errors"] += len(e["log_errors"])
        # Pipeline leg: EpisodeSpec -> Godot -> context pack -> CSFT5 -> Hand A -> Hand B -> Godot.
        fp = load(ART / "pipeline" / name / "fp_raw.json")
        rows = fp["turns"]
        hid = fp["hands_service"]["worker_identity"]
        hands_ok = all(hid[k] == frozen[k] for k in ("hand_a_sha256", "hand_b_sha256"))
        tot["hands_identity_fail"] += not hands_ok
        init = [x for x in fp["vp_audit"] if x.get("decision") == "INITIAL"]
        brain_ok = bool(init) and init[0]["outcome"] == "APPLIED" and init[0]["validation"]["ok"] and init[0]["contract"] == "victory_author_v1"
        tot["brain_invalid"] += not brain_ok
        pkt = fp.get("brain_packet_red1", {})
        pe, lk = pack_errors(pkt, spec), leaks(pkt, spec)
        tot["pack_mismatch"] += len(pe)
        tot["leaks"] += len(lk)
        last = rows[-1] if rows else {}
        for k in ("fallbacks", "exec_failures", "pipeline_failures"):  # cumulative counters
            tot[k] += int(last.get(k, 0))
        for r in rows:
            tot["oob"] += len(r["oob"])
            tot["dup"] += len(r["dup_occupancy"])
            tot["brain_alloc_contamination"] += len(r["brain_contract_units"])
        tot["not_in_pool"] += rows[-1]["hand_b_not_in_pool"] if rows else 0  # cumulative counter
        tot["pipeline_red_turns"] += len(rows)
        tot["hand_b_decisions"] += rows[-1]["decisions"] if rows else 0
        e["pipeline"] = {"stop": fp["stop_reason"], "episode_arg": fp.get("episode_arg"), "boot": fp["boot"],
                         "red_turns": len(rows), "hand_b_decisions": rows[-1]["decisions"] if rows else 0,
                         "hand_a_calls": rows[-1]["hand_a_calls"] if rows else 0,
                         "per_turn": [{k: r[k] for k in ("game_turn", "decisions", "fallbacks", "exec_failures", "pipeline_failures",
                                                         "oob", "dup_occupancy", "hand_b_not_in_pool", "brain_contract_units", "moves", "attacks", "waits")} for r in rows],
                         "hands_frozen_identity": hands_ok, "hand_shas": {k: hid[k] for k in ("hand_a_sha256", "hand_b_sha256")},
                         "brain_initial": {k: init[0].get(k) for k in ("outcome", "validation", "contract", "backend", "usage")} if init else None,
                         "packet_request": pkt.get("request"), "packet_has_context": "context" in pkt,
                         "pack_vs_spec_errors": pe, "hidden_leaks": lk, "elapsed_s": fp["elapsed_s"]}
        res["episodes"][name] = e
    res["context_off_identity"] = load(ART / "context_off_identity.json")
    res["totals"] = tot
    fail_keys = [k for k in tot if k not in ("setup_checks", "gx_actions", "pipeline_red_turns", "hand_b_decisions") and tot[k]]
    res["verdict"] = "PASS" if not fail_keys and res["context_off_identity"]["context_off_identical_to_pre_trackC_baseline"] \
        and tot["pipeline_red_turns"] == 2 * len(EPISODES) else "BLOCKED"
    res["failing_counters"] = fail_keys
    (ART / "SMOKE_RESULTS.json").write_text(json.dumps(res, indent=1, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({"verdict": res["verdict"], "totals": tot, "failing": fail_keys}, indent=1))


if __name__ == "__main__":
    main()
