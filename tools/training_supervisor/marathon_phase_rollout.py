"""TRAINING_MARATHON_V1 — PHASE: ROLLOUT (fresh process, terminates on completion).

Derived EXACTLY from the proven MANUAL_RL_LOOP_V1 Phase 1 implementation
(D:\\StrategyAI\\runtimes\\qwen3_8b_rl_v0\\manual_phase1_rollout.py):
same opening/prompt, same sampling, same champion-policy generation,
production validator, real Godot battle (tools/rl_proof_episode.gd),
real terminal reward.

Parameterization vs the manual script (logic unchanged):
  --iteration-dir      per-iteration output root (contains rollout/ subdir)
  --champion-adapter   adapter dir of the current champion ("" = B0, no adapter)
  --candidate-label    rollout_id prefix for this iteration's candidate
  --train-seed-start   first generation seed (consumes 2 per group)
  --max-groups         safety cap (default 8)
  --need-informative   informative groups required (default 2)

Informative = rewards differ AND GRPO advantage != 0.
If <need> informative after <max> groups: exit 3 (BLOCKED_NO_SIGNAL).
Memory guard breach: exit 42 (FAILED_MEMORY_GUARD).

LOCKED CONTRACT (do not change):
  temp 0.7 / top_p 0.8 / top_k 20 / rep 1.0 / 1280 tokens / non-thinking,
  max_turns 6, reward WIN+5/LOSS-3/DRAW-TIMEOUT-2, strict invalid = LOSS -3.

REWARD CONTRACT (--reward-contract, see reward_contract.py):
  REWARD_CONTRACT_V1  GRPO scalar = terminal reward (iterations 1..83)
  REWARD_CONTRACT_V2  GRPO scalar = terminal + contract bonus (<=0.25)
                      + plan coherence bonus (<=0.25); strict invalid = -3.0
  Godot's terminal candidate_reward is never altered. group.rewards is the
  GRPO scalar list; terminal_rewards + reward_components ride alongside.
"""
import argparse
import gc
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

MODEL_DIR = r"D:\StrategyAI\models\Qwen3-8B"
REVISION = "b968826d9c46dd6066d109eabc6255188de91218"
GODOT = r"C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe"
PROJ = r"D:\Game development\Demon slayer\StrategyGame"
EPISODE_TOOL = "res://tools/rl_proof_episode.gd"
PROMPT_SRC = r"D:\StrategyAI\runtimes\sparkx25\bench\raw\bench_prompt_A.json"
SAMPLING = {"temperature": 0.7, "top_p": 0.8, "top_k": 20, "repetition_penalty": 1.0,
            "max_new_tokens": 1280, "enable_thinking": False}
DEVICE_GUARD_GIB = 20.5
HOST_GUARD_GIB = 16.0


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--iteration-dir", required=True)
    p.add_argument("--champion-adapter", default="")
    p.add_argument("--candidate-label", required=True)
    p.add_argument("--train-seed-start", type=int, required=True)
    p.add_argument("--max-groups", type=int, default=8)
    p.add_argument("--need-informative", type=int, default=2)
    p.add_argument("--reward-contract", default="REWARD_CONTRACT_V1")
    return p.parse_args()


ARGS = parse_args()
import reward_contract as RC  # noqa: E402  (same directory as this script)
assert ARGS.reward_contract in RC.REWARD_CONTRACTS, ARGS.reward_contract
REWARD_CONTRACT = ARGS.reward_contract
ITDIR = Path(ARGS.iteration_dir)
RAW = ITDIR / "rollout"
RAW.mkdir(parents=True, exist_ok=True)
LOGF = open(RAW / "phase.log", "a", encoding="utf-8")


def _excepthook(t, v, tb):
    try:
        import traceback
        LOGF.write(f"[FATAL] {t.__name__}: {v}\n")
        LOGF.write("".join(traceback.format_tb(tb)) + "\n")
        LOGF.flush()
    except Exception:
        pass


sys.excepthook = _excepthook


def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    LOGF.write(line + "\n")
    LOGF.flush()


def device_used_gib():
    try:
        p = subprocess.run(["nvidia-smi", "--query-gpu=memory.used",
                            "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=15)
        return round(float(p.stdout.strip().splitlines()[0]) / 1024, 3)
    except Exception:
        return -1.0


def host_avail_gib():
    try:
        import psutil
        return round(psutil.virtual_memory().available / 2**30, 3)
    except Exception:
        return -1.0


def mem_guard(phase):
    d = device_used_gib()
    h = host_avail_gib()
    log(f"[MEM:{phase}] device={d}GiB host_avail={h}GiB")
    if d >= 0 and d > DEVICE_GUARD_GIB:
        finish({"status": "FAILED_MEMORY_GUARD", "failed_phase": phase,
                "error": f"device {d} GiB > {DEVICE_GUARD_GIB}"}, 42)
    if h >= 0 and h < HOST_GUARD_GIB:
        finish({"status": "FAILED_MEMORY_GUARD", "failed_phase": phase,
                "error": f"host avail {h} GiB < {HOST_GUARD_GIB}"}, 42)
    return d, h


def finish(payload, code):
    try:
        (RAW / "rollout_manifest.json").write_text(
            json.dumps(payload, indent=1), encoding="utf-8")
    except Exception as e:
        log(f"[finish] manifest write fail: {e}")
    try:
        LOGF.close()
    except Exception:
        pass
    sys.stdout.flush()
    os._exit(code)


log("[P1] TRAINING_MARATHON_V1 ROLLOUT start")
log(f"[P1] iteration_dir={ITDIR} label={ARGS.candidate_label} "
    f"seed_start={ARGS.train_seed_start} max_groups={ARGS.max_groups}")
log(f"[P1] model={MODEL_DIR} rev={REVISION}")
log(f"[P1] reward_contract={REWARD_CONTRACT}")

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

assert torch.cuda.is_available(), "CUDA required"
torch.cuda.empty_cache()
gc.collect()
d0, h0 = mem_guard("init")
if d0 >= 0 and d0 > 4.0:
    log(f"[P1] GPU not initially clear: {d0} GiB")
    finish({"status": "FAILED_MEMORY_GUARD", "failed_phase": "init_gpu_clear",
            "error": f"GPU not initially clear: {d0} > 4.0"}, 42)

tok = AutoTokenizer.from_pretrained(MODEL_DIR, trust_remote_code=False)
if tok.pad_token_id is None:
    tok.pad_token_id = tok.eos_token_id
tok.padding_side = "left"
bench = json.loads(Path(PROMPT_SRC).read_text(encoding="utf-8"))
MESSAGES = bench["messages"]
rendered = tok.apply_chat_template(MESSAGES, tokenize=False,
                                   add_generation_prompt=True,
                                   enable_thinking=False)
prompt_ids = tok(rendered, add_special_tokens=False)["input_ids"]
log(f"[P1] prompt_tokens={len(prompt_ids)}")

qconf = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                           bnb_4bit_use_double_quant=True,
                           bnb_4bit_compute_dtype=torch.bfloat16,
                           bnb_4bit_quant_storage="uint8")
t0 = time.time()
base = AutoModelForCausalLM.from_pretrained(
    MODEL_DIR, revision=REVISION, trust_remote_code=False,
    attn_implementation="sdpa", quantization_config=qconf,
    device_map={"": 0})

CHAMPION_ADAPTER = (ARGS.champion_adapter or "").strip()
gen_model = base
if CHAMPION_ADAPTER:
    apath = Path(CHAMPION_ADAPTER) / "adapter_model.safetensors"
    assert apath.exists(), f"champion adapter missing: {apath}"
    from peft import PeftModel
    gen_model = PeftModel.from_pretrained(base, str(Path(CHAMPION_ADAPTER)))
    log(f"[P1] champion adapter loaded from {CHAMPION_ADAPTER}")
else:
    log("[P1] champion = B0 (official Qwen3-8B, NO adapter)")
gen_model.eval()
try:
    gen_model.config.use_cache = True
except Exception:
    pass
log(f"[P1] policy loaded in {round(time.time() - t0, 1)}s")


def gen_one(pids, seed):
    import torch as T
    gen_model.eval()
    try:
        gen_model.config.use_cache = True
    except Exception:
        pass
    T.manual_seed(seed)
    if T.cuda.is_available():
        T.cuda.manual_seed_all(seed)
    inp = {"input_ids": T.tensor([pids], device="cuda:0"),
           "attention_mask": T.ones(1, len(pids), device="cuda:0")}
    t0 = time.time()
    with T.inference_mode():
        out = gen_model.generate(
            **inp, max_new_tokens=SAMPLING["max_new_tokens"],
            do_sample=True, temperature=SAMPLING["temperature"],
            top_p=SAMPLING["top_p"], top_k=SAMPLING["top_k"],
            repetition_penalty=SAMPLING["repetition_penalty"],
            pad_token_id=tok.pad_token_id, eos_token_id=tok.eos_token_id)
    dt = round(time.time() - t0, 1)
    gen = out[0][len(pids):].tolist()
    return gen, dt


def run_godot_episode(rollout_id, seed, completion_text, tag):
    rin = RAW / f"{tag}_in.json"
    rout = RAW / f"{tag}_out.json"
    req = {"rollout_id": rollout_id, "side": "RED", "seed": seed,
           "completion_text": completion_text, "kind": "INITIAL",
           "ctx": {"turn": 1,
                   "snapshot_id": "step1_cloud_step1_neutral_skirmish_t1_RED_v0_80bcd142078a",
                   "roster": ["R_ARC_1", "R_ARC_2", "R_CAV_1", "R_CAV_2",
                              "R_HQ_1", "R_INF_1", "R_INF_2", "R_SCT_1",
                              "R_SPE_1", "R_SPE_2"]},
           "max_turns": 6}
    rin.write_text(json.dumps(req), encoding="utf-8")
    t0 = time.time()
    p = subprocess.run([GODOT, "--headless", "--path", PROJ, "-s",
                        EPISODE_TOOL, "--", rin.as_posix(), rout.as_posix()],
                       capture_output=True, text=True, timeout=600)
    dt = round(time.time() - t0, 1)
    if not rout.exists():
        raise RuntimeError(f"godot no output tag={tag} "
                           f"stdout={p.stdout[-1500:]} stderr={p.stderr[-1500:]}")
    rec = json.loads(rout.read_text(encoding="utf-8"))
    rec["episode_wall_s"] = dt
    rec["godot_stdout_tail"] = p.stdout[-600:]
    return rec


def advantages_of(rewards):
    rt = torch.tensor(rewards, dtype=torch.float64)
    mean = rt.mean()
    var = ((rt - mean) ** 2).mean() * (len(rt) / (len(rt) - 1))
    std = float(torch.sqrt(var))
    adv = [float((r - float(mean)) / (std + 1e-4)) for r in rewards]
    return adv


groups_attempted = []
informative = []
seed_cursor = int(ARGS.train_seed_start)
for gi in range(int(ARGS.max_groups)):
    if len(informative) >= int(ARGS.need_informative):
        break
    seeds = [seed_cursor, seed_cursor + 1]
    seed_cursor += 2
    log(f"[P1] GROUP {gi + 1} seeds={seeds}")
    t0 = time.time()
    comps, dts = [], []
    for s in seeds:
        c, dt = gen_one(prompt_ids, s)
        comps.append(c)
        dts.append(dt)
        log(f"[P1] gen seed={s} tokens={len(c)} t={dt}s")
    texts = tok.batch_decode(comps, skip_special_tokens=True)
    recs, rewards, rrecs = [], [], []
    for i, (c, tx, s) in enumerate(zip(comps, texts, seeds)):
        rid = f"{ARGS.candidate_label}g{gi + 1}s{s}"
        rec = run_godot_episode(rid, 1000 + s, tx, f"rollout_{rid}")
        assert rec["general_calls"] == 1 and rec["retries"] == 0 \
            and rec["queue_left"] == 0, rec
        assert rec["fallback_plan_adopted"] is False, rec
        term = rec["candidate_reward"]
        assert term in (5, -3, -2) and isinstance(term, int), rec
        rr = RC.compute_reward(rec, tx, REWARD_CONTRACT)
        rec["reward"] = rr  # reconstructible per-episode reward record
        r = rr["total_reward"]
        recs.append(rec)
        rewards.append(r)
        rrecs.append(rr)
        log(f"[P1] {rid} winner={rec['winner']} terminal={term} "
            f"contract={rr['contract_valid']} coherent={rr['plan_coherent']} "
            f"reward={r} ({REWARD_CONTRACT}) reason={rec['terminal_reason']}")
    adv = advantages_of(rewards)
    finite = all(isinstance(r, (int, float)) and r == r
                 and abs(r) != float("inf") for r in rewards)
    signal = finite and len(set(rewards)) > 1 \
        and any(abs(a) > 1e-9 for a in adv)
    entry = {"group_index": gi + 1, "seeds": seeds, "rewards": rewards,
             "advantages": adv,
             "token_lengths": [len(c) for c in comps], "gen_s": dts,
             "texts_sha": [hashlib.sha256(t.encode("utf-8")).hexdigest()[:16]
                           for t in texts],
             "signal": signal, "informative": bool(signal),
             "wall_s": round(time.time() - t0, 1)}
    if REWARD_CONTRACT != RC.REWARD_CONTRACT_V1:
        entry.update(RC.group_reward_fields(rrecs, REWARD_CONTRACT))
        assert entry["rewards"] == rewards
    groups_attempted.append(entry)
    (RAW / f"group{gi + 1}.json").write_text(json.dumps(entry, indent=1),
                                             encoding="utf-8")
    for i, tx in enumerate(texts):
        (RAW / f"group{gi + 1}_s{seeds[i]}.txt").write_text(tx,
                                                            encoding="utf-8")
    for rec in recs:
        (RAW / f"rollout_{rec['rollout_id']}.json").write_text(
            json.dumps(rec, indent=1), encoding="utf-8")
    log(f"[P1] GROUP{gi + 1} rewards={rewards} adv={adv} informative={signal}")
    if signal:
        informative.append(entry)
        log(f"[P1] informative count={len(informative)}/"
            f"{ARGS.need_informative}")
    gc.collect()
    try:
        torch.cuda.empty_cache()
    except Exception:
        pass
    mem_guard(f"post_group{gi + 1}")

ok = len(informative) >= int(ARGS.need_informative)
summary = {"status": "ROLLOUT_DONE" if ok else "BLOCKED_NO_SIGNAL",
           "groups_attempted": groups_attempted,
           "informative_groups": informative,
           "n_attempted": len(groups_attempted),
           "n_informative": len(informative),
           "prompt_tokens": len(prompt_ids), "sampling": SAMPLING,
           "train_seed_start": int(ARGS.train_seed_start),
           "seeds_consumed": [int(ARGS.train_seed_start), seed_cursor - 1],
           "champion_adapter": CHAMPION_ADAPTER or None,
           "candidate_label": ARGS.candidate_label}
if REWARD_CONTRACT != RC.REWARD_CONTRACT_V1:
    summary["reward_contract_version"] = REWARD_CONTRACT
    summary["grpo_reward_field"] = "rewards"
(RAW / "phase1_summary.json").write_text(json.dumps(summary, indent=1),
                                         encoding="utf-8")
log(json.dumps({k: summary[k] for k in
                ("status", "n_attempted", "n_informative")}, indent=1))

try:
    del gen_model, base, tok
except Exception:
    pass
gc.collect()
try:
    torch.cuda.empty_cache()
except Exception:
    pass
finish(summary, 0 if ok else 3)
