"""TRAINING_MARATHON_V1 — PHASE: TRAIN (fresh process, terminates on completion).

Derived EXACTLY from the proven MANUAL_RL_LOOP_V1 Phase 2 clean method
(D:\\StrategyAI\\runtimes\\qwen3_8b_rl_v0\\manual_phase2_train.py):
no trainer.train(), no generate, no Godot, no recompute.
For each of the 2 informative groups: sample A _compute_loss ->
backward(loss/2) -> free; sample B _compute_loss -> backward(loss/2) ->
optimizer.step() ONCE -> zero_grad -> cleanup. EXACTLY 2 optimizer steps.

Parameterization vs the manual script (logic unchanged):
  --iteration-dir      iteration root (rollout/manifest lives underneath)
  --champion-adapter   adapter dir of the current champion ("" = B0 fresh LoRA)
  --candidate-out      versioned output dir for the trained candidate adapter
  --learning-rate      locked 5e-6 (override refused unless exact default)

Memory guard breach: exit 42 (FAILED_MEMORY_GUARD).

LOCKED CONTRACT (do not change):
  Qwen3-8B NF4 double-quant BF16, LoRA r=8 alpha=16 dropout=0,
  targets q/k/v/o/gate/up/down, SDPA, grad-checkpoint ON use_reentrant=False,
  use_cache=False, TRL 1.13.0 GRPO _compute_loss, LR 5e-6.
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
os.environ["TRL_EXPERIMENTAL_SILENCE"] = "1"

LOCKED_LR = 5e-6


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--iteration-dir", required=True)
    p.add_argument("--champion-adapter", default="")
    p.add_argument("--candidate-out", required=True)
    p.add_argument("--learning-rate", type=float, default=LOCKED_LR)
    return p.parse_args()


ARGS = parse_args()
assert abs(float(ARGS.learning_rate) - LOCKED_LR) < 1e-12, \
    f"learning rate locked at {LOCKED_LR}"
LR = LOCKED_LR

ITDIR = Path(ARGS.iteration_dir)

# OPERATOR PAUSE GUARD: if the marathon root holds PAUSE_RL_BEFORE_TRAIN,
# refuse to start BEFORE any model load / optimizer creation / step. The
# supervisor records a TRAIN_BRAIN phase failure (resumable via --resume
# once the marker is removed); the proven rollout is left untouched.
_PAUSE_MARKER = ITDIR.parent.parent / "PAUSE_RL_BEFORE_TRAIN"
if _PAUSE_MARKER.exists():
    (ITDIR / "train").mkdir(parents=True, exist_ok=True)
    (ITDIR / "train" / "TRAIN_PAUSED.json").write_text(json.dumps({
        "status": "PAUSED_BY_OPERATOR", "marker": str(_PAUSE_MARKER),
        "marker_text": _PAUSE_MARKER.read_text(encoding="utf-8")[:500],
        "optimizer_steps": 0, "model_loaded": False,
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, indent=1),
        encoding="utf-8")
    print("[TRAIN] PAUSED_BY_OPERATOR: PAUSE_RL_BEFORE_TRAIN present; "
          "0 optimizer steps", flush=True)
    sys.stdout.flush()
    os._exit(44)
ROLLOUTS = ITDIR / "rollout"
TRAINDIR = ITDIR / "train"
TRAINDIR.mkdir(parents=True, exist_ok=True)
ADAPTER_OUT = Path(ARGS.candidate_out)
ADAPTER_OUT.mkdir(parents=True, exist_ok=True)
LOGF = open(TRAINDIR / "phase.log", "a", encoding="utf-8")


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


import psutil
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model
from datasets import Dataset
from trl import GRPOConfig, GRPOTrainer

MODEL_DIR = r"D:\StrategyAI\models\Qwen3-8B"
REVISION = "b968826d9c46dd6066d109eabc6255188de91218"
PROMPT_SRC = r"D:\StrategyAI\runtimes\sparkx25\bench\raw\bench_prompt_A.json"
DEVICE_GUARD_GIB = 20.5
HOST_GUARD_GIB = 16.0

peak_device = 0.0
min_host_avail = float("inf")
last_device = None
phase_log = []


def gib(n):
    return round(n / 2**30, 3)


def device_used_gib():
    try:
        p = subprocess.run(["nvidia-smi", "--query-gpu=memory.used",
                            "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=15)
        return round(float(p.stdout.strip().splitlines()[0]) / 1024, 3)
    except Exception:
        return round(torch.cuda.memory_reserved() / 2**30, 3) \
            if torch.cuda.is_available() else -1.0


def host_avail_gib():
    return gib(psutil.virtual_memory().available)


def proc_rss_gib():
    try:
        return gib(psutil.Process().memory_info().rss)
    except Exception:
        return -1.0


RAPID_CHECK_PHASES = {"g1_post_forward0", "g1_post_backward0",
                      "g1_post_forward1", "g1_post_backward1",
                      "g2_post_forward0", "g2_post_backward0",
                      "g2_post_forward1", "g2_post_backward1"}


def snap(phase):
    global peak_device, min_host_avail, last_device
    d = device_used_gib()
    h = host_avail_gib()
    ta = gib(torch.cuda.memory_allocated()) if torch.cuda.is_available() else 0.0
    tr = gib(torch.cuda.memory_reserved()) if torch.cuda.is_available() else 0.0
    rss = proc_rss_gib()
    peak_device = max(peak_device, d)
    min_host_avail = min(min_host_avail, h)
    rapid = ""
    last_host = phase_log[-1]["host_avail_gib"] if phase_log else h
    if phase in RAPID_CHECK_PHASES and last_device is not None \
            and d >= 0 and last_device >= 0:
        if d - last_device > 10.0:
            rapid = f" RAPID_JUMP +{round(d - last_device, 2)}GiB"
        elif last_host - h > 8.0:
            rapid = f" RAPID_HOST_DROP -{round(last_host - h, 2)}GiB"
    last_device = d
    log(f"[MEM:{phase}] device={d}GiB torch_alloc={ta}GiB torch_res={tr}GiB "
        f"host_avail={h}GiB rss={rss}GiB{rapid}")
    phase_log.append({"phase": phase, "device_gib": d,
                      "torch_alloc_gib": ta, "torch_res_gib": tr,
                      "host_avail_gib": h, "rss_gib": rss})
    if d > DEVICE_GUARD_GIB:
        abort(f"ABORT_DEVICE_GUARD at {phase}: device {d} GiB > "
              f"{DEVICE_GUARD_GIB}", phase)
    if h < HOST_GUARD_GIB:
        abort(f"ABORT_HOST_GUARD at {phase}: host avail {h} GiB < "
              f"{HOST_GUARD_GIB}", phase)
    if rapid:
        abort(f"ABORT_RAPID_GROWTH at {phase}: {rapid.strip()}", phase)
    return d, h


def abort(msg, phase):
    log(f"[ABORT] {msg}")
    try:
        payload = {"status": "FAILED_MEMORY_GUARD", "failed_phase": phase,
                   "error": msg, "peak_device_vram_gib": peak_device,
                   "minimum_available_system_ram_gib": None
                   if min_host_avail == float("inf")
                   else round(min_host_avail, 3),
                   "phase_log": phase_log}
        (TRAINDIR / "TRAIN_ABORT.json").write_text(json.dumps(payload, indent=1),
                                                   encoding="utf-8")
    except Exception as e:
        log(f"[ABORT] write fail: {e}")
    try:
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    except Exception:
        pass
    try:
        LOGF.close()
    except Exception:
        pass
    os._exit(42)


log("[TRAIN] TRAINING_MARATHON_V1 train start")
log(f"[TRAIN] iteration_dir={ITDIR} champion_adapter={ARGS.champion_adapter or '(B0)'} "
    f"out={ADAPTER_OUT}")
log("[TRAIN] verify GPU initially clear")
assert torch.cuda.is_available(), "CUDA required"
torch.cuda.empty_cache()
gc.collect()
d0 = device_used_gib()
h0 = host_avail_gib()
log(f"[TRAIN] device={d0}GiB host_avail={h0}GiB")
if d0 > 4.0:
    abort(f"GPU not initially clear: {d0} > 4.0", "init_gpu_clear")
snap("init")
if h0 < HOST_GUARD_GIB:
    abort(f"Host RAM unhealthy: {h0}", "init_ram")

log("[TRAIN] load tokenizer")
tok = AutoTokenizer.from_pretrained(MODEL_DIR, trust_remote_code=False)
if tok.pad_token_id is None:
    tok.pad_token_id = tok.eos_token_id
tok.padding_side = "left"
snap("tokenizer")

bench = json.loads(Path(PROMPT_SRC).read_text(encoding="utf-8"))
MESSAGES = bench["messages"]
rendered = tok.apply_chat_template(MESSAGES, tokenize=False,
                                   add_generation_prompt=True,
                                   enable_thinking=False)
prompt_ids_list = tok(rendered, add_special_tokens=False)["input_ids"]
log(f"[TRAIN] prompt_tokens={len(prompt_ids_list)}")

manifest = json.loads((ROLLOUTS / "rollout_manifest.json").read_text(encoding="utf-8"))
assert manifest.get("status") == "ROLLOUT_DONE", manifest.get("status")
# GRPO scalar = group["rewards"] under every reward contract (V1: terminal;
# V2: terminal + contract + coherence bonuses). Training mechanics unchanged.
REWARD_CONTRACT = manifest.get("reward_contract_version", "REWARD_CONTRACT_V1")
assert REWARD_CONTRACT in ("REWARD_CONTRACT_V1", "REWARD_CONTRACT_V2"), REWARD_CONTRACT
log(f"[TRAIN] reward_contract={REWARD_CONTRACT} grpo_reward_field=rewards")
inf = [g for g in manifest["groups_attempted"] if g.get("informative")]
assert len(inf) >= 2, "need 2 informative groups"
inf = inf[:2]
groups = []
for k, g in enumerate(inf):
    gi = g["group_index"]
    seeds = g["seeds"]
    rewards = [float(r) for r in g["rewards"]]
    texts = [(ROLLOUTS / f"group{gi}_s{seeds[0]}.txt").read_text(encoding="utf-8"),
             (ROLLOUTS / f"group{gi}_s{seeds[1]}.txt").read_text(encoding="utf-8")]
    groups.append({"name": f"g{k + 1}", "seeds": seeds, "rewards": rewards,
                   "texts": texts, "group_index": gi})
log(f"[TRAIN] informative groups: "
    f"g1 seeds={groups[0]['seeds']} rewards={groups[0]['rewards']}; "
    f"g2 seeds={groups[1]['seeds']} rewards={groups[1]['rewards']}")


def adv_of(rewards):
    rt = torch.tensor(rewards, dtype=torch.float64)
    mean = rt.mean()
    var = ((rt - mean) ** 2).mean() * (len(rt) / (len(rt) - 1))
    std = float(torch.sqrt(var))
    adv = [float((r - float(mean)) / (std + 1e-4)) for r in rewards]
    return adv


for g in groups:
    g["advantages"] = adv_of(g["rewards"])
    log(f"[TRAIN] {g['name']} adv={g['advantages']}")
    assert g["advantages"][0] != g["advantages"][1] \
        and any(abs(a) > 1e-9 for a in g["advantages"])
    g["comp_ids"] = [tok(t, add_special_tokens=False)["input_ids"]
                     + [tok.eos_token_id] for t in g["texts"]]
    log(f"[TRAIN] {g['name']} complen={[len(c) for c in g['comp_ids']]}")

log("[TRAIN] load Qwen3-8B NF4")
qconf = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                           bnb_4bit_use_double_quant=True,
                           bnb_4bit_compute_dtype=torch.bfloat16,
                           bnb_4bit_quant_storage="uint8")
t0 = time.time()
base = AutoModelForCausalLM.from_pretrained(
    MODEL_DIR, revision=REVISION, trust_remote_code=False,
    attn_implementation="sdpa", quantization_config=qconf,
    device_map={"": 0})
log(f"[TRAIN] loaded in {round(time.time() - t0, 1)}s")
snap("base_loaded")

CHAMPION_ADAPTER = (ARGS.champion_adapter or "").strip()
targets = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj",
           "up_proj", "down_proj"]
if CHAMPION_ADAPTER:
    apath = Path(CHAMPION_ADAPTER) / "adapter_model.safetensors"
    assert apath.exists(), f"champion adapter missing: {apath}"
    assert Path(CHAMPION_ADAPTER).resolve() != ADAPTER_OUT.resolve(), \
        "candidate output must not overwrite the champion"
    from peft import PeftModel
    log(f"[TRAIN] clone champion policy from {CHAMPION_ADAPTER}")
    model = PeftModel.from_pretrained(base, str(Path(CHAMPION_ADAPTER)))
    # from_pretrained loads adapters FROZEN in this PEFT version (proven by
    # probe: 0 trainable params). The marathon contract requires the
    # champion clone to be a TRAINABLE candidate: re-arm grads on LoRA
    # weights only; the 4-bit base stays frozen.
    n_armed = 0
    for _n, _p in model.named_parameters():
        if "lora_" in _n and not _p.requires_grad:
            _p.requires_grad_(True)
            n_armed += 1
    log(f"[TRAIN] champion adapter loaded as trainable candidate (continues "
        f"from promoted champion; re-armed {n_armed} LoRA params)")
else:
    log("[TRAIN] attach fresh LoRA r=8 (champion is B0)")
    model = get_peft_model(base, LoraConfig(r=8, lora_alpha=16,
                                            lora_dropout=0.0, bias="none",
                                            task_type="CAUSAL_LM",
                                            target_modules=targets))
model.config.use_cache = False
try:
    model.gradient_checkpointing_enable(
        gradient_checkpointing_kwargs={"use_reentrant": False})
except TypeError:
    model.gradient_checkpointing_enable()
model.config.use_cache = False
trainable = [(n, p) for n, p in model.named_parameters() if p.requires_grad]
assert trainable and all("lora_" in n for n, _ in trainable)
log(f"[TRAIN] LoRA tensors={len(trainable)} "
    f"params={sum(p.numel() for _, p in trainable)}")
snap("lora")


def lora_snapshot(m):
    out = {}
    for n, p in m.named_parameters():
        if p.requires_grad:
            b = p.detach().float().cpu().numpy().tobytes()
            out[n] = {"sha256": hashlib.sha256(b).hexdigest(),
                      "numel": p.numel(),
                      "mean": float(p.detach().float().mean().cpu()),
                      "amax": float(p.detach().float().abs().max().cpu())}
    return out


log("[TRAIN] snapshot LoRA BEFORE")
before = lora_snapshot(model)

log("[TRAIN] instantiate MINIMAL GRPOTrainer")


def _dummy_reward(prompts, completions, **kw):
    return [0.0 for _ in completions]


ds = Dataset.from_dict({"prompt": ["dummy"]})
args = GRPOConfig(output_dir=str(ADAPTER_OUT / "grpo_out"),
                  run_name="training_marathon_v1",
                  max_steps=1, per_device_train_batch_size=2,
                  gradient_accumulation_steps=1, num_generations=2,
                  max_completion_length=2048, beta=0.0, num_iterations=1,
                  loss_type="grpo", scale_rewards="group", epsilon=0.2,
                  learning_rate=LR, lr_scheduler_type="constant",
                  warmup_ratio=0.0, optim="adamw_torch", max_grad_norm=1.0,
                  gradient_checkpointing=True, bf16=True, logging_steps=1,
                  save_strategy="no", report_to="none", log_completions=False,
                  seed=7, dataloader_num_workers=0)
trainer = GRPOTrainer(model=model, args=args, train_dataset=ds,
                      processing_class=tok, reward_funcs=_dummy_reward)
log(f"[TRAIN] loss={trainer.loss_type} beta={trainer.beta} "
    f"vllm={trainer.use_vllm}")
assert trainer.beta == 0.0 and trainer.loss_type == "grpo" \
    and trainer.use_vllm is False
assert trainer.off_policy_mask_threshold is None
try:
    trainer.current_gradient_accumulation_steps = 1
except Exception as e:
    log(f"[TRAIN] grad-accum force: {e}")
snap("trainer")

log("[TRAIN] create optimizer")
trainer.create_optimizer()
opt = trainer.optimizer
assert opt is not None
for grp in opt.param_groups:
    grp["lr"] = LR
log(f"[TRAIN] {type(opt).__name__} lr={LR}")
opt.zero_grad(set_to_none=True)
snap("optimizer")

model.train()
trainer.model.train()
device = str(trainer.accelerator.device) \
    if hasattr(trainer, "accelerator") else "cuda:0"
log(f"[TRAIN] device={device}")


def make_inputs(comp_ids, adv):
    return {"prompt_ids": torch.tensor([prompt_ids_list], dtype=torch.long,
                                       device=device),
            "prompt_mask": torch.ones(1, len(prompt_ids_list),
                                      dtype=torch.long, device=device),
            "completion_ids": torch.tensor([comp_ids], dtype=torch.long,
                                           device=device),
            "completion_mask": torch.ones(1, len(comp_ids), dtype=torch.long,
                                          device=device),
            "advantages": torch.tensor([adv], dtype=torch.float32,
                                       device=device)}


optimizer_steps = 0
group_losses = []
group_grad_norms = []

for gi, g in enumerate(groups):
    tag = g["name"]
    log(f"[TRAIN] === {tag} sample0 forward ===")
    snap(f"{tag}_pre_sample0")
    inputs0 = make_inputs(g["comp_ids"][0], g["advantages"][0])
    with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
        loss0 = trainer._compute_loss(trainer.model, inputs0)
    loss0_val = float(loss0.detach().float().cpu())
    log(f"[TRAIN] {tag} loss_sample_0={loss0_val}")
    assert loss0_val == loss0_val and abs(loss0_val) != float("inf")
    snap(f"{tag}_post_forward0")
    log(f"[TRAIN] {tag} backward sample0 (loss/2)")
    (loss0 / 2).backward()
    snap(f"{tag}_post_backward0")
    del inputs0, loss0
    gc.collect()
    torch.cuda.empty_cache()
    snap(f"{tag}_freed0")

    log(f"[TRAIN] === {tag} sample1 forward ===")
    inputs1 = make_inputs(g["comp_ids"][1], g["advantages"][1])
    with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
        loss1 = trainer._compute_loss(trainer.model, inputs1)
    loss1_val = float(loss1.detach().float().cpu())
    log(f"[TRAIN] {tag} loss_sample_1={loss1_val}")
    assert loss1_val == loss1_val and abs(loss1_val) != float("inf")
    snap(f"{tag}_post_forward1")
    log(f"[TRAIN] {tag} backward sample1 (loss/2)")
    (loss1 / 2).backward()
    snap(f"{tag}_post_backward1")
    del inputs1, loss1
    gc.collect()
    torch.cuda.empty_cache()
    snap(f"{tag}_freed1")

    log(f"[TRAIN] {tag} verify grads finite")
    tsq = 0.0
    ngrad = 0
    for n, p in model.named_parameters():
        if p.requires_grad and p.grad is not None:
            ngrad += 1
            if not torch.isfinite(p.grad).all():
                abort(f"non-finite grad in {n} at {tag}", f"{tag}_grad")
            tsq += float(torch.sum(p.grad.float() ** 2).cpu())
    grad_norm = float(tsq ** 0.5)
    log(f"[TRAIN] {tag} grad_tensors={ngrad} grad_norm={grad_norm}")
    assert ngrad > 0 and grad_norm == grad_norm and grad_norm > 0.0
    group_grad_norms.append(grad_norm)
    group_losses.append([loss0_val, loss1_val])

    log(f"[TRAIN] {tag} memory guard before step")
    snap(f"{tag}_pre_step")
    log(f"[TRAIN] {tag} optimizer.step() (step {optimizer_steps + 1}/2)")
    opt.step()
    optimizer_steps += 1
    log(f"[TRAIN] {tag} zero_grad")
    opt.zero_grad(set_to_none=True)
    snap(f"{tag}_post_step")
    gc.collect()
    torch.cuda.empty_cache()

assert optimizer_steps == 2, f"expected EXACTLY 2 steps, got {optimizer_steps}"

log("[TRAIN] snapshot AFTER + prove change")
after = lora_snapshot(model)
changed = sum(1 for n in before if before[n]["sha256"] != after[n]["sha256"])
log(f"[TRAIN] changed {changed}/{len(before)}")
assert changed > 0, "LoRA did not change"

log(f"[TRAIN] save candidate adapter -> {ADAPTER_OUT}")
for f in ADAPTER_OUT.iterdir():
    if f.is_file() and f.name.startswith("adapter"):
        f.unlink()
model.save_pretrained(str(ADAPTER_OUT))
tok.save_pretrained(str(ADAPTER_OUT))
adapter_files = sorted(f.name for f in ADAPTER_OUT.iterdir())
adapter_saved = (ADAPTER_OUT / "adapter_model.safetensors").exists() \
    or any("adapter" in f for f in adapter_files)
log(f"[TRAIN] files={adapter_files} saved={adapter_saved}")
assert adapter_saved

result = {"status": "TRAIN_DONE", "optimizer_steps": optimizer_steps,
          "group_losses": group_losses, "group_grad_norms": group_grad_norms,
          "lora_total_tensors": len(before),
          "lora_changed_tensors": changed,
          "peak_device_vram_gib": round(peak_device, 3),
          "minimum_available_system_ram_gib": round(min_host_avail, 3),
          "adapter_saved": bool(adapter_saved),
          "training_rewards": [groups[0]["rewards"], groups[1]["rewards"]],
          "training_advantages": [groups[0]["advantages"],
                                  groups[1]["advantages"]],
          "champion_adapter": CHAMPION_ADAPTER or None,
          "reward_contract_version": REWARD_CONTRACT,
          "grpo_reward_field": "rewards",
          "phase_log": phase_log}
(TRAINDIR / "train_summary.json").write_text(json.dumps(result, indent=1),
                                             encoding="utf-8")
log(json.dumps({k: result[k] for k in
                ("status", "optimizer_steps", "lora_changed_tensors",
                 "peak_device_vram_gib",
                 "minimum_available_system_ram_gib")}, indent=1))

try:
    del model, base, trainer, opt, tok
except Exception:
    pass
gc.collect()
try:
    torch.cuda.empty_cache()
except Exception:
    pass
snap("unloaded")
try:
    LOGF.close()
except Exception:
    pass
sys.stdout.flush()
os._exit(0)
