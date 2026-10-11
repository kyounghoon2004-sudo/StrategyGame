"""TRAINING_MARATHON_V1 — PHASE: EVAL (fresh process, terminates on completion).

Derived EXACTLY from the proven MANUAL_RL_LOOP_V1 Phase 3 held-out eval
(D:\\StrategyAI\\runtimes\\qwen3_8b_rl_v0\\manual_phase3_eval.py):
fresh process, no training, same symmetric env (production validator +
Godot battle via tools/rl_sym_eval.gd), frozen hands, same sampling.
Candidate vs current frozen champion. Exactly 4 matches per iteration
(2 held-out seeds x side swap).

Parameterization vs the manual script (logic unchanged):
  --iteration-dir      iteration root (eval/ subdir written underneath)
  --champion-adapter   adapter dir of the current champion ("" = B0)
  --candidate-adapter  adapter dir of the candidate under test (required)
  --eval-seeds         two held-out generation seeds (never training seeds)
  --champion-label     brain tag recorded for the champion side
  --candidate-label    brain tag recorded for the candidate side

Promotion rule (deterministic, operational for this marathon version):
  PROMOTE only if candidate strict failures == 0 AND wins > losses,
  else REJECT. Recorded in eval_summary.json; the supervisor applies it.

LOCKED CONTRACT (do not change): sampling temp 0.7 / top_p 0.8 / top_k 20 /
rep 1.0 / 1280 tokens / non-thinking; max_turns 6; frozen Laya.
"""
import argparse
import gc
import json
import os
import subprocess
import sys
import time
from pathlib import Path

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--iteration-dir", required=True)
    p.add_argument("--champion-adapter", default="")
    p.add_argument("--candidate-adapter", required=True)
    p.add_argument("--eval-seeds", nargs=2, type=int, required=True)
    p.add_argument("--champion-label", required=True)
    p.add_argument("--candidate-label", required=True)
    return p.parse_args()


ARGS = parse_args()
ITDIR = Path(ARGS.iteration_dir)
EVALDIR = ITDIR / "eval"
EVALDIR.mkdir(parents=True, exist_ok=True)
LOGF = open(EVALDIR / "phase.log", "a", encoding="utf-8")


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


MODEL_DIR = r"D:\StrategyAI\models\Qwen3-8B"
REVISION = "b968826d9c46dd6066d109eabc6255188de91218"
GODOT = r"C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe"
PROJ = r"D:\Game development\Demon slayer\StrategyGame"
SYM_TOOL = "res://tools/rl_sym_eval.gd"
PROMPT_SRC = r"D:\StrategyAI\runtimes\sparkx25\bench\raw\bench_prompt_A.json"
SAMPLING = {"temperature": 0.7, "top_p": 0.8, "top_k": 20, "repetition_penalty": 1.0,
            "max_new_tokens": 1280, "enable_thinking": False}
EVAL_SEEDS = [int(ARGS.eval_seeds[0]), int(ARGS.eval_seeds[1])]
CHAMPION_ADAPTER = (ARGS.champion_adapter or "").strip()
CANDIDATE_ADAPTER = str(Path(ARGS.candidate_adapter))
CHAMPION_LABEL = ARGS.champion_label
CANDIDATE_LABEL = ARGS.candidate_label

assert (Path(CANDIDATE_ADAPTER) / "adapter_model.safetensors").exists(), \
    f"candidate adapter missing: {CANDIDATE_ADAPTER}"
if CHAMPION_ADAPTER:
    assert (Path(CHAMPION_ADAPTER) / "adapter_model.safetensors").exists(), \
        f"champion adapter missing: {CHAMPION_ADAPTER}"

log("[EVAL] TRAINING_MARATHON_V1 eval start")
log(f"[EVAL] iteration_dir={ITDIR} champion={CHAMPION_LABEL} "
    f"({CHAMPION_ADAPTER or 'B0'}) candidate={CANDIDATE_LABEL} "
    f"({CANDIDATE_ADAPTER}) seeds={EVAL_SEEDS}")

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

assert torch.cuda.is_available()
torch.cuda.empty_cache()
gc.collect()

tok = AutoTokenizer.from_pretrained(MODEL_DIR, trust_remote_code=False)
if tok.pad_token_id is None:
    tok.pad_token_id = tok.eos_token_id
tok.padding_side = "left"

bench = json.loads(Path(PROMPT_SRC).read_text(encoding="utf-8"))
MESSAGES_RED = bench["messages"]


def mirror_side(text):
    t = text.replace("RED", "__TMP_RED__").replace("BLUE", "RED").replace(
        "__TMP_RED__", "BLUE")
    t = t.replace("R_", "__TMP_R__").replace("B_", "R_").replace(
        "__TMP_R__", "B_")
    t = t.replace("red", "__tmp_red__").replace("blue", "red").replace(
        "__tmp_red__", "blue")
    return t


MESSAGES_BLUE = [{"role": m["role"], "content": mirror_side(m["content"])}
                 for m in MESSAGES_RED]
assert "BLUE general" in MESSAGES_BLUE[0]["content"], \
    MESSAGES_BLUE[0]["content"][:300]
assert "B_INF_1" in MESSAGES_BLUE[1]["content"] \
    and "acting_side" in MESSAGES_BLUE[1]["content"]
log("[EVAL] BLUE prompt mirrored OK")

rendered_red = tok.apply_chat_template(MESSAGES_RED, tokenize=False,
                                       add_generation_prompt=True,
                                       enable_thinking=False)
rendered_blue = tok.apply_chat_template(MESSAGES_BLUE, tokenize=False,
                                        add_generation_prompt=True,
                                        enable_thinking=False)
pids_red = tok(rendered_red, add_special_tokens=False)["input_ids"]
pids_blue = tok(rendered_blue, add_special_tokens=False)["input_ids"]
log(f"[EVAL] prompt_tokens red={len(pids_red)} blue={len(pids_blue)}")

qconf = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                           bnb_4bit_use_double_quant=True,
                           bnb_4bit_compute_dtype=torch.bfloat16,
                           bnb_4bit_quant_storage="uint8")


def gen_with(model, pids, seed):
    import torch as T
    model.eval()
    try:
        model.config.use_cache = True
    except Exception:
        pass
    T.manual_seed(seed)
    if T.cuda.is_available():
        T.cuda.manual_seed_all(seed)
    inp = {"input_ids": T.tensor([pids], device="cuda:0"),
           "attention_mask": T.ones(1, len(pids), device="cuda:0")}
    t0 = time.time()
    with T.inference_mode():
        out = model.generate(**inp, max_new_tokens=SAMPLING["max_new_tokens"],
                             do_sample=True,
                             temperature=SAMPLING["temperature"],
                             top_p=SAMPLING["top_p"], top_k=SAMPLING["top_k"],
                             repetition_penalty=SAMPLING["repetition_penalty"],
                             pad_token_id=tok.pad_token_id,
                             eos_token_id=tok.eos_token_id)
    dt = round(time.time() - t0, 1)
    gen = out[0][len(pids):].tolist()
    try:
        model.config.use_cache = False
    except Exception:
        pass
    return gen, dt


def load_policy(adapter_dir, tag):
    t0 = time.time()
    base = AutoModelForCausalLM.from_pretrained(
        MODEL_DIR, revision=REVISION, trust_remote_code=False,
        attn_implementation="sdpa", quantization_config=qconf,
        device_map={"": 0})
    if adapter_dir:
        from peft import PeftModel
        model = PeftModel.from_pretrained(base, str(adapter_dir))
    else:
        model = base
        base = None
    model.eval()
    log(f"[EVAL] {tag} loaded in {round(time.time() - t0, 1)}s")
    return model, base


log(f"[EVAL] load champion {CHAMPION_LABEL}")
champ_model, champ_base = load_policy(CHAMPION_ADAPTER or None,
                                      f"champion {CHAMPION_LABEL}")
champ_texts = {}
for s in EVAL_SEEDS:
    c, dt = gen_with(champ_model, pids_red, s)
    tx = tok.decode(c, skip_special_tokens=True)
    champ_texts[f"RED_{s}"] = tx
    (EVALDIR / f"{CHAMPION_LABEL}_RED_{s}.txt").write_text(tx, encoding="utf-8")
    log(f"[EVAL] {CHAMPION_LABEL} RED seed={s} tokens={len(c)} t={dt}s")
    c2, dt2 = gen_with(champ_model, pids_blue, s)
    tx2 = tok.decode(c2, skip_special_tokens=True)
    champ_texts[f"BLUE_{s}"] = tx2
    (EVALDIR / f"{CHAMPION_LABEL}_BLUE_{s}.txt").write_text(tx2,
                                                           encoding="utf-8")
    log(f"[EVAL] {CHAMPION_LABEL} BLUE seed={s} tokens={len(c2)} t={dt2}s")

del champ_model
if champ_base is not None:
    del champ_base
gc.collect()
try:
    torch.cuda.empty_cache()
except Exception:
    pass
log("[EVAL] champion unloaded")

log(f"[EVAL] load candidate {CANDIDATE_LABEL}")
cand_model, cand_base = load_policy(CANDIDATE_ADAPTER,
                                    f"candidate {CANDIDATE_LABEL}")
cand_texts = {}
for s in EVAL_SEEDS:
    c, dt = gen_with(cand_model, pids_red, s)
    tx = tok.decode(c, skip_special_tokens=True)
    cand_texts[f"RED_{s}"] = tx
    (EVALDIR / f"{CANDIDATE_LABEL}_RED_{s}.txt").write_text(tx, encoding="utf-8")
    log(f"[EVAL] {CANDIDATE_LABEL} RED seed={s} tokens={len(c)} t={dt}s")
    c2, dt2 = gen_with(cand_model, pids_blue, s)
    tx2 = tok.decode(c2, skip_special_tokens=True)
    cand_texts[f"BLUE_{s}"] = tx2
    (EVALDIR / f"{CANDIDATE_LABEL}_BLUE_{s}.txt").write_text(tx2,
                                                            encoding="utf-8")
    log(f"[EVAL] {CANDIDATE_LABEL} BLUE seed={s} tokens={len(c2)} t={dt2}s")

del cand_model
if cand_base is not None:
    del cand_base
gc.collect()
try:
    torch.cuda.empty_cache()
except Exception:
    pass
log("[EVAL] candidate unloaded, models freed; running 4 symmetric matches")


def run_sym_match(match_id, seed, red_text, blue_text, red_brain, blue_brain,
                  candidate_side):
    rin = EVALDIR / f"{match_id}_in.json"
    rout = EVALDIR / f"{match_id}_out.json"
    req = {"match_id": match_id, "seed": seed, "red_text": red_text,
           "blue_text": blue_text, "red_brain": red_brain,
           "blue_brain": blue_brain, "candidate_side": candidate_side,
           "max_turns": 6}
    rin.write_text(json.dumps(req), encoding="utf-8")
    t0 = time.time()
    p = subprocess.run([GODOT, "--headless", "--path", PROJ, "-s", SYM_TOOL,
                        "--", rin.as_posix(), rout.as_posix()],
                       capture_output=True, text=True, timeout=600)
    dt = round(time.time() - t0, 1)
    if not rout.exists():
        raise RuntimeError(f"sym eval no output {match_id} "
                           f"stdout={p.stdout[-1500:]} stderr={p.stderr[-1500:]}")
    rec = json.loads(rout.read_text(encoding="utf-8"))
    rec["match_wall_s"] = dt
    rec["godot_stdout_tail"] = p.stdout[-600:]
    # Normalize champion/candidate result fields for the supervisor contract.
    if rec.get("candidate_outcome") == "WIN":
        rec["champion_result"] = "LOSS"
    elif rec.get("candidate_outcome") == "LOSS":
        rec["champion_result"] = "WIN"
    else:
        rec["champion_result"] = rec.get("candidate_outcome")
    rec["candidate_result"] = rec.get("candidate_outcome")
    (EVALDIR / f"{match_id}.json").write_text(json.dumps(rec, indent=1),
                                              encoding="utf-8")
    return rec


s1, s2 = EVAL_SEEDS
matches = []
matches.append(run_sym_match(f"eval_s{s1}_m1", s1, cand_texts[f"RED_{s1}"],
                             champ_texts[f"BLUE_{s1}"], CANDIDATE_LABEL,
                             CHAMPION_LABEL, "RED"))
matches.append(run_sym_match(f"eval_s{s1}_m2", s1, champ_texts[f"RED_{s1}"],
                             cand_texts[f"BLUE_{s1}"], CHAMPION_LABEL,
                             CANDIDATE_LABEL, "BLUE"))
matches.append(run_sym_match(f"eval_s{s2}_m3", s2, cand_texts[f"RED_{s2}"],
                             champ_texts[f"BLUE_{s2}"], CANDIDATE_LABEL,
                             CHAMPION_LABEL, "RED"))
matches.append(run_sym_match(f"eval_s{s2}_m4", s2, champ_texts[f"RED_{s2}"],
                             cand_texts[f"BLUE_{s2}"], CHAMPION_LABEL,
                             CANDIDATE_LABEL, "BLUE"))

assert len(matches) == 4
for m in matches:
    log(f"[EVAL] {m['match_id']} seed={m['seed']} cand={m['candidate_side']} "
        f"winner={m['winner']} outcome={m['candidate_outcome']} "
        f"reward={m['candidate_reward']} valid={m['candidate_contract_valid']} "
        f"strict_fail={m['strict_failure_candidate']} "
        f"reason={m['terminal_reason']} turns={m['turns']}")
    assert m["candidate_reward"] in (5, -3, -2)
    for k in ("winner", "candidate_result", "champion_result",
              "candidate_contract_valid", "terminal_reason", "turns", "seed",
              "candidate_side"):
        assert k in m, f"match {m['match_id']} missing {k}"

wins = sum(1 for m in matches if m["candidate_outcome"] == "WIN")
losses = sum(1 for m in matches if m["candidate_outcome"] == "LOSS")
draws = sum(1 for m in matches if m["candidate_outcome"] == "DRAW")
strict_fails = sum(1 for m in matches
                   if m.get("strict_failure_candidate") is True)
decision = "PROMOTE" if (strict_fails == 0 and wins > losses) else "REJECT"

summary = {"status": "EVAL_DONE", "eval_seeds": EVAL_SEEDS, "matches": matches,
           "wins": wins, "losses": losses, "draws": draws,
           "strict_failures": strict_fails, "decision": decision,
           "champion": CHAMPION_LABEL, "candidate": CANDIDATE_LABEL}
(EVALDIR / "eval_summary.json").write_text(json.dumps(summary, indent=1),
                                           encoding="utf-8")
log(json.dumps({k: summary[k] for k in
                ("status", "wins", "losses", "draws", "strict_failures",
                 "decision")}, indent=1))
try:
    del tok
except Exception:
    pass
gc.collect()
try:
    torch.cuda.empty_cache()
except Exception:
    pass
try:
    LOGF.close()
except Exception:
    pass
sys.stdout.flush()
os._exit(0)
