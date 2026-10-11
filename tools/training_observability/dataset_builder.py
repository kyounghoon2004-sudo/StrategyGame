"""TASK 2 - incremental, self-contained trajectory dataset builder.

Discovered producer schema (read-only; see HANDOFF SCHEMA DISCOVERY):
  rollout/ (per complete iteration)
    rollout_manifest.json / phase1_summary.json : groups_attempted[] with
        group_index, seeds[2], rewards[2], advantages[2], token_lengths[2],
        gen_s[2], texts_sha[2] (sha256[:16] of decoded text), informative
    group{g}.json                : same group entry
    group{g}_s{seed}.txt         : decoded completion text (VictoryPlan JSON)
    rollout_{label}g{g}s{seed}_in.json : Godot request {rollout_id, side,
        seed (= 1000 + generation seed), completion_text, kind, ctx, max_turns}
    rollout_{label}g{g}s{seed}.json    : Godot result + episode_wall_s +
        godot_stdout_tail (the _out.json is the same minus those two keys)
  eval/
    eval_summary.json : matches[] (full match records), W/L/D, strict, decision
    eval_s{seed}_m{k}_in.json : {match_id, seed, red_text, blue_text,
        red_brain, blue_brain, candidate_side, max_turns}
  Prompt: NOT persisted per sample. The producer renders the fixed file
  PROMPT_SRC (bench_prompt_A.json); only prompt_tokens is recorded.

Record contract (schema_version trajectory_record_v1):
  * record_id  = sha256(natural key)[:32]  -> deterministic, rerun-stable
  * content is COPIED (texts, state, parsed plan, result, reward); source
    paths are provenance only
  * records are immutable once written; a rerun never duplicates
  * malformed / incomplete sources -> manifest["issues"] + a record with
    record_status=INCOMPLETE when enough is known to identify the sample
Shards: trajectories-NNNN.jsonl.gz (gzip mtime=0, deterministic bytes);
each build appends NEW shards only.
"""
from __future__ import annotations

import gzip
import hashlib
import io
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from .config import ROLLOUT_EPISODE_SEED_OFFSET, ROLLOUT_OPPONENT, Paths
from .marathon_scan import LiveSnapshot, discover_iterations, make_issue, try_read_json
from .safe_io import OutputWriter, ReadOnlySource, UnreadableJSON

SCHEMA_VERSION = "trajectory_record_v1"
MANIFEST_VERSION = 1
SHARD_MAX_RECORDS = 250
SHARD_RE = re.compile(r"^trajectories-(\d{4})\.jsonl\.gz$")


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def make_id(*parts) -> str:
    return sha256_hex("|".join("" if p is None else str(p) for p in parts))[:32]


def canonical(obj) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def content_sha(rec: dict) -> str:
    body = {k: v for k, v in rec.items() if k not in ("record_id", "content_sha256")}
    return sha256_hex(canonical(body))


def issue(kind: str, path, context: str, detail: str = "") -> dict:
    return make_issue(kind, path, context, detail)


# ----------------------------------------------------------------------------
# prompt
# ----------------------------------------------------------------------------
def build_prompt_record(src: ReadOnlySource, prompt_src: Path, first_run_start: Optional[str],
                        issues: List[dict]) -> Optional[dict]:
    if not src.exists(prompt_src):
        issues.append(issue("PROMPT_SOURCE_MISSING", prompt_src, "prompt"))
        return None
    try:
        bench = src.read_json(prompt_src)
    except (UnreadableJSON, OSError) as e:
        issues.append(issue("PROMPT_SOURCE_MALFORMED", prompt_src, "prompt", str(e)))
        return None
    messages = bench.get("messages") if isinstance(bench, dict) else None
    if not isinstance(messages, list):
        issues.append(issue("PROMPT_SOURCE_MALFORMED", prompt_src, "prompt", "no messages[]"))
        return None
    psha = sha256_hex(canonical(messages))
    sig = src.stat_sig(prompt_src)
    mtime = datetime.fromtimestamp(sig[1] / 1e9, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if sig else None
    if mtime and first_run_start:
        ident = ("UNVERIFIED_BY_PRODUCER (only prompt_tokens persisted); file mtime "
                 f"{mtime} {'precedes' if mtime <= first_run_start else 'IS AFTER'} first "
                 f"iteration start {first_run_start}")
    else:
        ident = "UNVERIFIED_BY_PRODUCER (only prompt_tokens persisted)"
    rec = {"schema_version": SCHEMA_VERSION, "record_type": "prompt", "record_status": "COMPLETE",
           "record_id": make_id("prompt", psha), "prompt_sha256": psha, "side": "RED",
           "messages": messages, "provenance": {"source_paths": [str(prompt_src)],
                                                "source_mtime_utc": mtime,
                                                "identity": ident,
                                                "resolved_at_build_time": True},
           "variants": {"BLUE": "eval BLUE prompt = producer mirror_side(RED messages) "
                                "(marathon_phase_eval.py); not persisted, not re-derived here"}}
    return rec


# ----------------------------------------------------------------------------
# rollout units (marathon iteration / historical run)
# ----------------------------------------------------------------------------
class RolloutUnit:
    def __init__(self, source_run: str, unit_key: str, iteration: Optional[int], rollout_dir: Path,
                 label: Optional[str], groups: List[dict], informative_idx: set,
                 policy: dict, train_done: Optional[bool], prompt_tokens, sampling,
                 group_file_fmt: str, text_fmts: List[str]):
        self.__dict__.update(locals())
        del self.__dict__["self"]


def _find_rollout_file(names: List[str], gi: int, seed: int) -> Optional[str]:
    rx = re.compile(rf"^rollout_(.*g{gi}s{seed})\.json$")
    for n in names:
        m = rx.match(n)
        if m:
            return m.group(1)
    return None


def build_rollout_records(src: ReadOnlySource, u: RolloutUnit, prompt_id: Optional[str],
                          issues: List[dict]) -> List[dict]:
    out = []
    names = src.listdir(u.rollout_dir)
    referenced = set()
    for g in u.groups:
        gi = g.get("group_index")
        seeds = g.get("seeds") or []
        rewards = g.get("rewards") or []
        advs = g.get("advantages")
        for si, seed in enumerate(seeds):
            ctx = f"{u.unit_key} group{gi} sample{si} seed{seed}"
            src_issues: List[dict] = []
            rid = _find_rollout_file(names, gi, seed)
            if rid is None and u.label is not None:
                rid = f"{u.label}g{gi}s{seed}"
            paths = {}
            rec = req = None
            text = None
            if rid:
                referenced.update({f"rollout_{rid}.json", f"rollout_{rid}_in.json", f"rollout_{rid}_out.json"})
                p_rec = u.rollout_dir / f"rollout_{rid}.json"
                p_in = u.rollout_dir / f"rollout_{rid}_in.json"
                rec = try_read_json(src, p_rec, src_issues, ctx)
                req = try_read_json(src, p_in, src_issues, ctx)
                paths["episode"] = str(p_rec)
                paths["request"] = str(p_in)
                if rec is not None and not isinstance(rec, dict):
                    src_issues.append(issue("MALFORMED_RECORD", p_rec, ctx, "not a JSON object"))
                    rec = None
            else:
                src_issues.append(issue("MISSING_FILE", u.rollout_dir / f"rollout_*g{gi}s{seed}.json", ctx))
            for fmt in u.text_fmts:
                tp = u.rollout_dir / fmt.format(g=gi, s=seed, i=si)
                if src.exists(tp):
                    text = src.read_text(tp)
                    paths["completion_text"] = str(tp)
                    referenced.add(tp.name)
                    break
            if text is None and isinstance(req, dict) and isinstance(req.get("completion_text"), str):
                text = req["completion_text"]
                paths["completion_text"] = paths.get("request")
            if text is None:
                src_issues.append(issue("MISSING_COMPLETION_TEXT", u.rollout_dir, ctx))
            rec = rec or {}
            req = req if isinstance(req, dict) else {}
            side = rec.get("side") or req.get("side")
            sl = (side or "").lower()
            sha16 = (g.get("texts_sha") or [None] * len(seeds))[si] if g.get("texts_sha") else None
            text_ok = (sha256_hex(text)[:16] == sha16) if (text is not None and sha16) else None
            if text_ok is False:
                src_issues.append(issue("TEXT_SHA_MISMATCH", paths.get("completion_text"), ctx,
                                        f"recorded {sha16}"))
            if rec.get("completion_sha256") and text is not None and \
                    sha256_hex(text) != rec.get("completion_sha256"):
                src_issues.append(issue("COMPLETION_SHA256_MISMATCH", paths.get("episode"), ctx))
            path_kind = rec.get("path")
            strict = (path_kind == "STRICT_TERMINAL") if path_kind else None
            fault = rec.get(f"fault_{sl}") if sl else None
            status = rec.get(f"status_{sl}") if sl else None
            if rec:
                contract_valid = bool(status == "READY" and rec.get("plan_adopted") is True and not fault)
            else:
                contract_valid = None
            ep_seed = rec.get("seed", req.get("seed"))
            if rec and si < len(rewards) and rec.get("candidate_reward") != rewards[si]:
                src_issues.append(issue("REWARD_MISMATCH", paths.get("episode"), ctx,
                                        f"episode {rec.get('candidate_reward')} vs group {rewards[si]}"))
            complete = bool(rec) and bool(req) and text is not None and not src_issues
            r = {
                "schema_version": SCHEMA_VERSION, "record_type": "rollout_sample",
                "record_id": make_id("rollout", u.source_run, u.iteration, rid or f"g{gi}s{seed}"),
                "record_status": "COMPLETE" if complete else "INCOMPLETE",
                "source_run": u.source_run, "iteration": u.iteration,
                "candidate_label": u.label, "rollout_id": rid,
                "group_index": gi, "sample_index": si,
                "generation_seed": seed, "episode_seed": ep_seed,
                "episode_seed_expected": seed + ROLLOUT_EPISODE_SEED_OFFSET,
                "side": side, "policy": u.policy, "opponent": dict(ROLLOUT_OPPONENT),
                "prompt": {"prompt_record_id": prompt_id, "prompt_tokens": u.prompt_tokens,
                           "sampling": u.sampling, "variant": side},
                "input_state": {"kind": req.get("kind"), "ctx": req.get("ctx"),
                                "max_turns": req.get("max_turns")},
                "output": {"completion_text": text,
                           "completion_chars": rec.get("completion_chars"),
                           "completion_sha256": rec.get("completion_sha256"),
                           "token_length": (g.get("token_lengths") or [None] * len(seeds))[si]
                           if g.get("token_lengths") else None,
                           "gen_s": (g.get("gen_s") or [None] * len(seeds))[si] if g.get("gen_s") else None,
                           "text_sha16_recorded": sha16, "text_sha16_verified": text_ok,
                           "parsed_plan": {"phase_count": rec.get("phase_count"),
                                           "phases_dump": rec.get("phases_dump"),
                                           "mission_tasks": rec.get("mission_tasks"),
                                           "vp_keys": rec.get("vp_keys"),
                                           "plan_revision": rec.get("plan_revision")}},
                "validity": {"contract_valid": contract_valid,
                             "contract_valid_provenance": "DERIVED: status==READY and plan_adopted and no fault",
                             "status": status, "plan_adopted": rec.get("plan_adopted"),
                             "validator_code": rec.get("validator_code"),
                             "validator_detail": rec.get("validator_detail"),
                             "fault_code": fault, "fault_is_brain_code": rec.get("fault_is_brain_code"),
                             "resolution_path": path_kind, "strict_failure": strict,
                             "strict_failure_type": (rec.get("validator_code") or fault) if strict else None},
                "terminal": {"winner": rec.get("winner"), "outcome": rec.get("candidate_outcome"),
                             "terminal_reason": rec.get("terminal_reason"),
                             "battle_turns": rec.get("battle_turns"), "hq_log": rec.get("hq_log"),
                             "red_soldiers_left": rec.get("red_soldiers_left"),
                             "blue_soldiers_left": rec.get("blue_soldiers_left")},
                "reward": {"reward": rec.get("candidate_reward", rewards[si] if si < len(rewards) else None),
                           "reward_group_recorded": rewards[si] if si < len(rewards) else None,
                           "opponent_reward": rec.get("opponent_reward"),
                           "group_rewards": rewards, "advantage": advs[si] if isinstance(advs, list) and si < len(advs) else None,
                           "group_informative": g.get("informative", g.get("signal")),
                           "used_in_training": (gi in u.informative_idx and u.train_done)
                           if u.train_done is not None else None,
                           "used_in_training_provenance": "DERIVED: informative group and TRAIN_DONE"},
                "episode_record": rec or None,
                "provenance": {"source_paths": paths, "unit": u.unit_key},
                "source_issues": [i["issue_id"] for i in src_issues],
            }
            issues.extend(src_issues)
            out.append(r)
    # orphans: rollout files not referenced by any recorded group
    for n in names:
        if n.startswith("rollout_") and n.endswith(".json") and n not in referenced \
                and not n.startswith("rollout_manifest") and not re.match(r"^rollout_group\d+\.json$", n):
            issues.append(issue("ORPHAN_SOURCE_FILE", u.rollout_dir / n, u.unit_key,
                                "rollout file not referenced by any group in the summary"))
    return out


def build_eval_records(src: ReadOnlySource, source_run: str, iteration: Optional[int],
                       eval_dir: Path, summary: Optional[dict], decision: Optional[str],
                       prompt_id: Optional[str], unit_key: str, issues: List[dict]) -> List[dict]:
    if not isinstance(summary, dict):
        return []
    out = []
    for k, m in enumerate(summary.get("matches") or []):
        mid = m.get("match_id") or f"match{k}"
        ctx = f"{unit_key} {mid}"
        src_issues: List[dict] = []
        p_in = eval_dir / f"{mid}_in.json"
        req = try_read_json(src, p_in, src_issues, ctx)
        req = req if isinstance(req, dict) else {}
        texts = {}
        for side in ("red", "blue"):
            t = req.get(f"{side}_text")
            if t is None:
                brain = m.get(f"{side}_brain")
                tp = eval_dir / f"{brain}_{side.upper()}_{m.get('seed')}.txt"
                if src.exists(tp):
                    t = src.read_text(tp)
            if t is not None and m.get(f"{side}_sha") and sha256_hex(t) != m.get(f"{side}_sha"):
                src_issues.append(issue("TEXT_SHA_MISMATCH", p_in, ctx, side))
            texts[side] = t
        cside = m.get("candidate_side")
        cand_id, champ_id = summary.get("candidate"), summary.get("champion")
        ver_prov = "eval_summary"
        if (cand_id is None or champ_id is None) and cside in ("RED", "BLUE"):
            other = "BLUE" if cside == "RED" else "RED"
            cand_id = cand_id or m.get(f"{cside.lower()}_brain")
            champ_id = champ_id or m.get(f"{other.lower()}_brain")
            ver_prov = "DERIVED: brain tag on candidate_side / opposite side"
        complete = bool(req) and all(v is not None for v in texts.values()) and not src_issues
        r = {"schema_version": SCHEMA_VERSION, "record_type": "eval_match",
             "record_id": make_id("eval", source_run, iteration, mid),
             "record_status": "COMPLETE" if complete else "INCOMPLETE",
             "source_run": source_run, "iteration": iteration, "match_id": mid,
             "pair_key": f"{source_run}:{iteration}:{m.get('seed')}",
             "seed": m.get("seed"), "eval_seeds": summary.get("eval_seeds"),
             "candidate": cand_id, "champion": champ_id, "versions_provenance": ver_prov,
             "candidate_side": cside, "red_brain": m.get("red_brain"), "blue_brain": m.get("blue_brain"),
             "prompt": {"prompt_record_id": prompt_id,
                        "variant_red": "RED", "variant_blue": "BLUE_MIRRORED (not persisted)"},
             "input_state": {"max_turns": req.get("max_turns")},
             "output": {"red_text": texts["red"], "blue_text": texts["blue"],
                        "red_sha256": m.get("red_sha"), "blue_sha256": m.get("blue_sha")},
             "validity": {"candidate_contract_valid": m.get("candidate_contract_valid"),
                          "strict_failure_candidate": m.get("strict_failure_candidate"),
                          "strict_failure_type": (m.get(f"fault_{(cside or '').lower()}") or None)
                          if m.get("strict_failure_candidate") else None,
                          "offender_side": m.get("offender_side"),
                          "fault_red": m.get("fault_red"), "fault_blue": m.get("fault_blue"),
                          "resolution_path": m.get("path")},
             "terminal": {"winner": m.get("winner"), "candidate_outcome": m.get("candidate_outcome"),
                          "candidate_result": m.get("candidate_result"),
                          "champion_result": m.get("champion_result"),
                          "terminal_reason": m.get("terminal_reason"), "turns": m.get("turns")},
             "reward": {"candidate_reward": m.get("candidate_reward")},
             "iteration_decision": decision, "match_record": m,
             "provenance": {"source_paths": {"summary": str(eval_dir / "eval_summary.json"),
                                             "request": str(p_in)}, "unit": unit_key},
             "source_issues": [i["issue_id"] for i in src_issues]}
        issues.extend(src_issues)
        out.append(r)
    return out


# ----------------------------------------------------------------------------
# source enumeration
# ----------------------------------------------------------------------------
def marathon_units(src: ReadOnlySource, refs, issues: List[dict]) -> Iterable[Tuple[str, Any, callable]]:
    """Yields (unit_key, sig, builder) for each COMPLETE iteration."""
    for ref in refs:
        if not ref.complete:
            continue
        key = f"training_marathon_v1:iteration_{ref.number:06d}"
        sig = src.stat_sig(ref.path / "ITERATION_RESULT.json")

        def build(prompt_id, ref=ref, key=key):
            res = ref.result
            summ = res.get("summaries") or {}
            man = summ.get("rollout_manifest.json")
            if not isinstance(man, dict):
                man = try_read_json(src, ref.path / "rollout" / "rollout_manifest.json", issues, key)
            recs: List[dict] = []
            if isinstance(man, dict):
                groups = man.get("groups_attempted") or []
                inf = {g.get("group_index") for g in (man.get("informative_groups") or [])}
                train = summ.get("train_summary.json")
                train_done = isinstance(train, dict) and train.get("status") == "TRAIN_DONE"
                champ = res.get("champion_before") or (res.get("champion_after")
                                                       if res.get("decision") == "SKIPPED_NO_SIGNAL" else None)
                policy = {"checkpoint_id": champ,
                          "adapter_path": man.get("champion_adapter"),
                          "provenance": "ITERATION_RESULT.champion_before" if res.get("champion_before")
                          else "DERIVED: champion_after of SKIPPED_NO_SIGNAL (champion unchanged)"}
                u = RolloutUnit("training_marathon_v1", key, ref.number, ref.path / "rollout",
                                man.get("candidate_label") or res.get("candidate_id"), groups, inf, policy,
                                train_done, man.get("prompt_tokens"), man.get("sampling"),
                                "group{g}.json", ["group{g}_s{s}.txt"])
                recs += build_rollout_records(src, u, prompt_id, issues)
            else:
                issues.append(issue("NO_ROLLOUT_SUMMARY", ref.path / "rollout", key))
            ev = summ.get("eval_summary.json")
            if isinstance(ev, dict):
                recs += build_eval_records(src, "training_marathon_v1", ref.number, ref.path / "eval",
                                           ev, res.get("decision"), prompt_id, key, issues)
            return recs
        yield key, sig, build


def _groups_from_files(src, d: Path, rx: str, issues, key) -> List[dict]:
    groups = []
    for n in src.listdir(d):
        m = re.match(rx, n)
        if m:
            g = try_read_json(src, d / n, issues, key)
            if isinstance(g, dict):
                g = dict(g)
                g.setdefault("group_index", int(m.group(1)))
                groups.append(g)
    return sorted(groups, key=lambda g: g["group_index"])


def historical_units(src: ReadOnlySource, paths: Paths, issues: List[dict]):
    root = paths.historical_roots.get("manual_rl_loop_v1")
    if root and src.exists(root):
        key = "manual_rl_loop_v1"
        rdir = Path(root) / "raw" / "rollouts"
        sig = [src.stat_sig(rdir / "phase1_summary.json"),
               src.stat_sig(Path(root) / "raw" / "eval" / "eval_summary.json")]

        def build(prompt_id, rdir=rdir, root=root, key=key):
            summ = try_read_json(src, rdir / "phase1_summary.json", issues, key)
            if isinstance(summ, dict):
                groups = summ.get("groups_attempted") or []
            else:
                groups = _groups_from_files(src, rdir, r"^group(\d+)\.json$", issues, key)
            inf = {g.get("group_index") for g in ((summ or {}).get("informative_groups") or [])} \
                if isinstance(summ, dict) else set()
            u = RolloutUnit(key, key, None, rdir, "m1", groups, inf,
                            {"checkpoint_id": "B0", "adapter_path": None,
                             "provenance": "HANDOFF (manual loop generated with B0)"},
                            None, (summ or {}).get("prompt_tokens") if isinstance(summ, dict) else None,
                            (summ or {}).get("sampling") if isinstance(summ, dict) else None,
                            "group{g}.json", ["group{g}_s{s}.txt"])
            recs = build_rollout_records(src, u, prompt_id, issues)
            edir = Path(root) / "raw" / "eval"
            ev = try_read_json(src, edir / "eval_summary.json", issues, key) if src.exists(edir) else None
            recs += build_eval_records(src, key, None, edir, ev, (ev or {}).get("decision")
                                       if isinstance(ev, dict) else None, prompt_id, key, issues)
            return recs
        yield key, sig, build
    root = paths.historical_roots.get("rl_pipeline_proof_v0")
    if root and src.exists(root):
        key = "rl_pipeline_proof_v0"
        rdir = Path(root) / "raw"
        sig = [src.stat_sig(rdir / "rollout_group1.json"), src.stat_sig(Path(root) / "CLEAN_STEP_RESULT.json")]

        def build(prompt_id, rdir=rdir, root=root, key=key):
            groups = _groups_from_files(src, rdir, r"^rollout_group(\d+)\.json$", issues, key)
            clean = try_read_json(src, Path(root) / "CLEAN_STEP_RESULT.json", issues, key)
            u = RolloutUnit(key, key, None, rdir, "", groups, set(),
                            {"checkpoint_id": "B0", "adapter_path": None,
                             "provenance": "proof run generated with base model"},
                            None, (clean or {}).get("prompt_tokens") if isinstance(clean, dict) else None,
                            None, "rollout_group{g}.json", ["rollout_g{g}_{i}.txt"])
            return build_rollout_records(src, u, prompt_id, issues)
        yield key, sig, build


# ----------------------------------------------------------------------------
# coverage
# ----------------------------------------------------------------------------
def _get(rec, path):
    cur = rec
    for p in path.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(p)
    return cur


COVERAGE_SPEC = [
    # target field, record path, static note (producer gap / derivation)
    ("iteration", "iteration", "historical runs have no iteration"),
    ("group", "group_index", ""),
    ("sample", "sample_index", ""),
    ("seed (generation)", "generation_seed", ""),
    ("seed (episode)", "episode_seed", ""),
    ("side", "side", ""),
    ("champion/policy version", "policy.checkpoint_id", "SKIPPED iterations: derived from champion_after"),
    ("candidate label", "candidate_label", "rl_pipeline_proof_v0 has no candidate label"),
    ("prompt text", "prompt.prompt_record_id",
     "PARTIAL: producer does not persist the prompt; resolved from PROMPT_SRC at build time, identity unverified"),
    ("prompt_tokens", "prompt.prompt_tokens", ""),
    ("input state (ctx)", "input_state.ctx", "ctx is turn/snapshot_id/roster only; full observation not persisted"),
    ("generated VictoryPlan text", "output.completion_text", ""),
    ("parsed plan (Godot phases_dump)", "output.parsed_plan.phases_dump", "only exists when Godot adopted the plan"),
    ("token_length", "output.token_length", ""),
    ("generated token ids", None, "NOT_PERSISTED_BY_PRODUCER (only decoded text)"),
    ("token logprobs (policy/reference)", None, "NOT_PERSISTED_BY_PRODUCER"),
    ("parse/schema validity", "validity.contract_valid", "derived from status/plan_adopted/fault"),
    ("strict failure type", "validity.strict_failure_type", ""),
    ("terminal result", "terminal.outcome", ""),
    ("reward", "reward.reward", ""),
    ("GRPO advantage", "reward.advantage", "rl_pipeline_proof_v0 group files omit advantages"),
    ("used_in_training", "reward.used_in_training", "derived: informative group + TRAIN_DONE"),
    ("opponent", "opponent.id", "PARTIAL: not persisted; derived from producer code (rl_proof_episode.gd)"),
    ("per-turn trajectory", "terminal.hq_log", "only HQ HP per turn; no per-turn observations/actions"),
    ("expert/teacher action (DAgger)", None, "NOT_PERSISTED_BY_PRODUCER"),
    ("source artifact path", "provenance.source_paths", ""),
    ("schema version", "schema_version", ""),
]

EVAL_COVERAGE_SPEC = [
    ("iteration", "iteration", ""), ("seed", "seed", ""), ("side (candidate)", "candidate_side", ""),
    ("candidate version", "candidate", "manual_rl_loop_v1: derived from brain tags"),
    ("champion version", "champion", "manual_rl_loop_v1: derived from brain tags"),
    ("red text", "output.red_text", ""), ("blue text", "output.blue_text", ""),
    ("BLUE prompt", None, "NOT_PERSISTED_BY_PRODUCER (mirror of RED prompt)"),
    ("parse/schema validity", "validity.candidate_contract_valid", ""),
    ("strict failure type", "validity.strict_failure_type", ""),
    ("terminal result", "terminal.candidate_outcome", ""), ("reward", "reward.candidate_reward", ""),
    ("opponent", "champion", "opponent = champion of that iteration"),
    ("source artifact path", "provenance.source_paths", ""), ("schema version", "schema_version", ""),
]

def _is_marathon(r):
    return r.get("source_run") == "training_marathon_v1"


# fields that only exist for a subset of records: coverage is measured over
# the applicable subset (the "applies_to" column in the report)
APPLICABILITY = {
    "iteration": ("marathon records", _is_marathon),
    "reward.used_in_training": ("marathon records", _is_marathon),
    "validity.strict_failure_type": ("strict failures", lambda r: bool(_get(r, "validity.strict_failure"))
                                     or bool(_get(r, "validity.strict_failure_candidate"))),
    "output.parsed_plan.phases_dump": ("plan adopted", lambda r: _get(r, "validity.plan_adopted") is True),
    "terminal.hq_log": ("battle resolved", lambda r: _get(r, "validity.resolution_path") == "GODOT_RESOLUTION"),
}


def coverage(records: List[dict], spec) -> List[dict]:
    rows = []
    for name, path, note in spec:
        applies, pred = APPLICABILITY.get(path, ("all", None))
        subset = [r for r in records if pred(r)] if pred else records
        n = len(subset)
        if path is None:
            rows.append({"field": name, "status": "NOT_PERSISTED_BY_PRODUCER", "present": 0,
                         "total": len(records), "applies_to": applies, "note": note})
            continue
        present = sum(1 for r in subset if _get(r, path) not in (None, "", [], {}))
        if note.startswith("PARTIAL"):
            status = "PARTIAL"
        elif n and present == n:
            status = "RECORDED"
        elif present == 0:
            status = "NOT_PERSISTED_BY_PRODUCER"
        else:
            status = "PARTIAL"
        rows.append({"field": name, "path": path, "status": status, "present": present,
                     "total": n, "applies_to": applies, "note": note})
    return rows


# ----------------------------------------------------------------------------
# shards / manifest
# ----------------------------------------------------------------------------
def gz_jsonl(records: List[dict]) -> bytes:
    raw = "".join(canonical(r) + "\n" for r in records).encode("utf-8")
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as g:
        g.write(raw)
    return buf.getvalue()


def read_shard(path: Path) -> List[dict]:
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def iter_dataset(dataset_dir: Path) -> Iterable[dict]:
    man = json.loads((Path(dataset_dir) / "manifest.json").read_text(encoding="utf-8"))
    for sh in man["shards"]:
        yield from read_shard(Path(dataset_dir) / sh["file"])


def empty_manifest() -> dict:
    return {"manifest_version": MANIFEST_VERSION, "schema_version": SCHEMA_VERSION,
            "shards": [], "records": {}, "units": {}, "issues": {}}


def run_dataset(paths: Paths, src: Optional[ReadOnlySource] = None,
                snapshot: Optional[LiveSnapshot] = None, rebuild: bool = False,
                include_historical: bool = True, now: Optional[str] = None) -> dict:
    src = src or ReadOnlySource()
    writer = OutputWriter(paths.output_root, paths.protected_roots)
    ddir = paths.dataset_dir
    man = None if rebuild else writer.read_own_json(ddir / "manifest.json")
    if rebuild:
        for n in (ddir.iterdir() if ddir.exists() else []):
            if SHARD_RE.match(n.name):
                writer._check(n)
                n.unlink()
    if not man or man.get("manifest_version") != MANIFEST_VERSION:
        man = empty_manifest()

    run_issues: List[dict] = []
    refs = discover_iterations(src, paths.marathon_root)
    incomplete = [{"iteration": r.number, "reason": r.reason} for r in refs if not r.complete]
    units = list(marathon_units(src, refs, run_issues))
    if include_historical:
        units += list(historical_units(src, paths, run_issues))

    starts = [r.result.get("started_at") for r in refs if r.complete and r.result.get("started_at")]
    first_start = min(starts) if starts else None
    new_records: List[dict] = []
    prompt = build_prompt_record(src, paths.prompt_src, first_start, run_issues)
    prompt_id = prompt["record_id"] if prompt else None
    if prompt:
        new_records.append(prompt)

    skipped_units = 0
    conflicts = []
    for key, sig, build in units:
        prev = man["units"].get(key)
        if prev and prev.get("sig") == sig:
            skipped_units += 1
            continue
        unit_issues_before = len(run_issues)
        recs = build(prompt_id)
        man["units"][key] = {"sig": sig, "prompt_id": prompt_id, "n_records": len(recs),
                             "issues": [i["issue_id"] for i in run_issues[unit_issues_before:]]}
        new_records += recs

    to_write = []
    for r in new_records:
        r["content_sha256"] = content_sha(r)
        known = man["records"].get(r["record_id"])
        if known:
            if known["content_sha256"] != r["content_sha256"]:
                conflicts.append(issue("SOURCE_CHANGED_AFTER_INDEXING", r["provenance"].get("source_paths"),
                                       r["record_id"], "existing record kept (immutable); use --rebuild"))
            continue
        to_write.append(r)
    run_issues += conflicts
    order = {"prompt": 0, "rollout_sample": 1, "eval_match": 2}
    to_write.sort(key=lambda r: (r["source_run"] if "source_run" in r else "", r.get("iteration") or 0,
                                 order[r["record_type"]], r.get("group_index") or 0,
                                 r.get("sample_index") or 0, r.get("match_id") or "", r["record_id"]))
    # dedupe inside one batch (defensive)
    seen, batch = set(), []
    for r in to_write:
        if r["record_id"] not in seen:
            seen.add(r["record_id"])
            batch.append(r)

    next_idx = max([int(SHARD_RE.match(s["file"]).group(1)) for s in man["shards"]] or [0]) + 1
    for i in range(0, len(batch), SHARD_MAX_RECORDS):
        chunk = batch[i:i + SHARD_MAX_RECORDS]
        name = f"trajectories-{next_idx:04d}.jsonl.gz"
        data = gz_jsonl(chunk)
        writer.write_bytes(ddir / name, data)
        man["shards"].append({"file": name, "n_records": len(chunk),
                              "sha256": hashlib.sha256(data).hexdigest(),
                              "record_types": sorted({r["record_type"] for r in chunk})})
        for r in chunk:
            man["records"][r["record_id"]] = {"shard": name, "content_sha256": r["content_sha256"],
                                              "record_type": r["record_type"],
                                              "record_status": r["record_status"]}
        next_idx += 1

    for i in run_issues:
        man["issues"].setdefault(i["issue_id"], i)

    # statistics + coverage over the whole dataset (read back own shards)
    all_recs = [r for sh in man["shards"] for r in read_shard(ddir / sh["file"])]
    ro = [r for r in all_recs if r["record_type"] == "rollout_sample"]
    ev = [r for r in all_recs if r["record_type"] == "eval_match"]
    by_run: Dict[str, Dict[str, int]] = {}
    for r in all_recs:
        if r["record_type"] == "prompt":
            continue
        d = by_run.setdefault(r["source_run"], {})
        d[r["record_type"]] = d.get(r["record_type"], 0) + 1
    ids = [r["record_id"] for r in all_recs]
    man["stats"] = {
        "n_records": len(all_recs), "n_rollout_samples": len(ro), "n_eval_matches": len(ev),
        "n_prompts": sum(1 for r in all_recs if r["record_type"] == "prompt"),
        "n_incomplete_records": sum(1 for r in all_recs if r["record_status"] == "INCOMPLETE"),
        "n_duplicate_ids": len(ids) - len(set(ids)),
        "by_source_run": dict(sorted(by_run.items())),
        "marathon_iterations_indexed": sorted({r["iteration"] for r in all_recs
                                               if r.get("source_run") == "training_marathon_v1"}),
        "rollout_strict_failures": sum(1 for r in ro if r["validity"]["strict_failure"]),
        "rollout_outcomes": _count(r["terminal"]["outcome"] for r in ro),
        "rollout_strict_failure_types": _count(r["validity"]["strict_failure_type"] for r in ro
                                               if r["validity"]["strict_failure_type"]),
        "rollout_used_in_training": sum(1 for r in ro if r["reward"]["used_in_training"]),
        "n_issues": len(man["issues"]),
        "issues_by_kind": _count(i["kind"] for i in man["issues"].values()),
    }
    man["field_coverage"] = {"rollout_sample": coverage(ro, COVERAGE_SPEC),
                             "eval_match": coverage(ev, EVAL_COVERAGE_SPEC)}
    man["last_build"] = {"at": now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                         "marathon_iterations_skipped_incomplete": incomplete,
                         "units_skipped_unchanged": skipped_units,
                         "records_added": len(batch), "conflicts": len(conflicts)}
    man["record_contract"] = {
        "record_id": "sha256(natural key)[:32]: rollout|source_run|iteration|rollout_id ; "
                     "eval|source_run|iteration|match_id ; prompt|prompt_sha256",
        "immutability": "records are never rewritten; changed sources are reported as "
                        "SOURCE_CHANGED_AFTER_INDEXING", "shard_format": "gzip JSON lines, canonical JSON"}
    writer.write_json(ddir / "manifest.json", man)
    writer.write_text(ddir / "DATASET_REPORT.md", render_report(man))
    return man


def _count(it) -> Dict[str, int]:
    d: Dict[str, int] = {}
    for x in it:
        d[str(x)] = d.get(str(x), 0) + 1
    return dict(sorted(d.items()))


def render_report(man: dict) -> str:
    s = man["stats"]
    L = ["# DATASET REPORT", "",
         f"- schema_version: `{man['schema_version']}`; shards: {len(man['shards'])} "
         f"({', '.join(x['file'] for x in man['shards'])})",
         f"- records: {s['n_records']} (rollout_sample {s['n_rollout_samples']}, eval_match "
         f"{s['n_eval_matches']}, prompt {s['n_prompts']}); duplicate ids: {s['n_duplicate_ids']}",
         f"- by source run: {s['by_source_run']}",
         f"- marathon iterations indexed: {len(s['marathon_iterations_indexed'])} "
         f"({s['marathon_iterations_indexed'][:1]}..{s['marathon_iterations_indexed'][-1:]})",
         f"- INCOMPLETE records: {s['n_incomplete_records']}; logged issues: {s['n_issues']} {s['issues_by_kind']}",
         f"- rollout outcomes: {s['rollout_outcomes']}; strict failures {s['rollout_strict_failures']} "
         f"{s['rollout_strict_failure_types']}",
         f"- rollout samples used in training (derived): {s['rollout_used_in_training']}",
         f"- last build: {man['last_build']}", "",
         "## Field coverage - rollout_sample", "",
         "| field | status | present/applicable | applies to | note |", "|---|---|---|---|---|"]
    for r in man["field_coverage"]["rollout_sample"]:
        L.append(f"| {r['field']} | {r['status']} | {r['present']}/{r['total']} | {r['applies_to']} | {r['note']} |")
    L += ["", "## Field coverage - eval_match", "",
          "| field | status | present/applicable | applies to | note |", "|---|---|---|---|---|"]
    for r in man["field_coverage"]["eval_match"]:
        L.append(f"| {r['field']} | {r['status']} | {r['present']}/{r['total']} | {r['applies_to']} | {r['note']} |")
    L += ["", "## Issues (malformed / incomplete sources)", ""]
    issues = sorted(man["issues"].values(), key=lambda i: (i["kind"], i["path"]))
    L += [f"- {i['kind']}: `{i['path']}` ({i['context']}) {i['detail']}" for i in issues[:200]] or ["- none"]
    if len(issues) > 200:
        L.append(f"- ... {len(issues) - 200} more in manifest.json")
    L += ["", "## Use", "",
          "- SFT: rollout_sample with validity.contract_valid and terminal.outcome != LOSS "
          "(prompt text from the prompt record).",
          "- Preference: eval_match pairs sharing pair_key (same seed, sides swapped); rollout groups "
          "(same iteration/group_index) with different rewards.",
          "- GRPO analysis: reward.group_rewards / reward.advantage / reward.used_in_training.",
          "- DAgger analysis: limited - no per-turn observations or expert actions are persisted.",
          "", "Read with: `python -m tools.training_observability dataset-cat` or "
          "`dataset_builder.iter_dataset(dir)`."]
    return "\n".join(L) + "\n"
