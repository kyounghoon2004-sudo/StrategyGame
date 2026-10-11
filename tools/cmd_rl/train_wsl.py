"""COMMANDER RL trainer (runs in WSL, /opt/brain_moe/venv): QLoRA on Qwen3.5-9B (2026-10-05).

  init  --out <dir>                                   zero LoRA (B = 0 -> identical to the base model)
  train --adapter <dir> --samples <json> --out <dir>  one GRPO update: per group, loss = -adv * mean token logprob
                                                      of the completion (thinking + answer), one optimizer step

Samples: [{"group": g, "items": [{"messages": [...], "completion": "<think>..</think>\n\n{..}", "adv": a}]}]
The adapter is saved in the checkpoint's own module names (Qwen3_5ForConditionalGeneration) so vLLM loads it as-is.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import time
from pathlib import Path

# A copy on the WSL disk loads in seconds; /mnt/d (Windows drive) took 1.5+ min per run (2026-10-10).
MODEL = "/opt/models/Qwen3.5-9B" if os.path.isdir("/opt/models/Qwen3.5-9B") else "/mnt/d/StrategyAI/models/Qwen3.5-9B"
TARGET = r".*language_model.*\.(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)$"
RANK, ALPHA, LR, CHUNK = 16, 32, 1e-5, 512


def lora_config():
    from peft import LoraConfig
    return LoraConfig(r=RANK, lora_alpha=ALPHA, lora_dropout=0.0, target_modules=TARGET, task_type="CAUSAL_LM")


def cmd_init(a):
    import torch
    from accelerate import init_empty_weights
    from transformers import AutoConfig, AutoModelForImageTextToText
    from peft import get_peft_model
    cfg = AutoConfig.from_pretrained(MODEL)
    with init_empty_weights():
        m = AutoModelForImageTextToText.from_config(cfg, dtype=torch.bfloat16)
    m = get_peft_model(m, lora_config())
    sd = {}
    for n, mod in m.named_modules():
        if hasattr(mod, "lora_A") and "default" in getattr(mod, "lora_A", {}):
            A, B = mod.lora_A["default"].weight, mod.lora_B["default"].weight
            a_ = torch.empty(A.shape, dtype=torch.float32)
            torch.nn.init.kaiming_uniform_(a_, a=5 ** 0.5)
            key = n.replace(".base_layer", "")
            sd[f"{key}.lora_A.weight"] = a_.to(torch.bfloat16)
            sd[f"{key}.lora_B.weight"] = torch.zeros(B.shape, dtype=torch.bfloat16)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    from safetensors.torch import save_file
    save_file(sd, str(out / "adapter_model.safetensors"))
    m.peft_config["default"].save_pretrained(str(out))
    print("init adapter", out, "tensors", len(sd))


def _logprob_mean(model, ids, n_comp):
    """Mean log-prob of the last n_comp tokens; lm_head applied in checkpointed chunks (vocab 248k)."""
    import torch
    from torch.utils.checkpoint import checkpoint
    core = model.base_model.model
    hid = core.model(input_ids=ids, use_cache=False).last_hidden_state[0]  # [T, H]
    h = hid[-n_comp - 1:-1]
    tgt = ids[0, -n_comp:]
    head = core.lm_head

    def chunk_lp(hc, tc):
        lg = head(hc).float()
        return torch.log_softmax(lg, -1).gather(1, tc[:, None])[:, 0].sum()

    tot = 0.0
    for s in range(0, n_comp, CHUNK):
        tot = tot + checkpoint(chunk_lp, h[s:s + CHUNK], tgt[s:s + CHUNK], use_reentrant=False)
    return tot / n_comp


def _logprob_spans(model, ids, spans):
    """Multi-turn SFT (2026-10-10): one forward over the whole conversation; mean log-prob of each target span
    [s, e) (token positions), lm_head in checkpointed chunks on the target positions only."""
    import torch
    from torch.utils.checkpoint import checkpoint
    core = model.base_model.model
    hid = core.model(input_ids=ids, use_cache=False).last_hidden_state[0]
    head = core.lm_head

    def chunk_lp(hc, tc):
        lg = head(hc).float()
        return torch.log_softmax(lg, -1).gather(1, tc[:, None])[:, 0].sum()

    out = []
    for s0, e0 in spans:
        h, tgt = hid[s0 - 1:e0 - 1], ids[0, s0:e0]
        tot = 0.0
        for c in range(0, e0 - s0, CHUNK):
            tot = tot + checkpoint(chunk_lp, h[c:c + CHUNK], tgt[c:c + CHUNK], use_reentrant=False)
        out.append(tot / (e0 - s0))
    return out


def _multi_encode(tok, msgs, first_target):
    """Token ids of a whole conversation + the token spans of its target assistant answers (each answer and its
    <|im_end|>). Rendered by the chat template as in play: earlier answers as history, the last one after the empty
    think block of a thinking-off generation prompt."""
    text = tok.apply_chat_template(msgs, tokenize=False, enable_thinking=False)
    enc = tok(text, add_special_tokens=False, return_offsets_mapping=True)
    ids, offs = enc["input_ids"], enc["offset_mapping"]
    marker, think, end = "<|im_start|>assistant\n", "<think>\n\n</think>\n\n", "<|im_end|>"
    char_spans, pos = [], 0
    for i, m in enumerate(msgs):
        if m["role"] != "assistant":
            continue
        pos = text.index(marker, pos) + len(marker)
        if text.startswith(think, pos):
            pos += len(think)
        assert text.startswith(m["content"], pos), "assistant content not found where expected"
        cs, ce = pos, pos + len(m["content"]) + len(end)
        pos = ce
        if i >= first_target:
            char_spans.append((cs, ce))
    spans = []
    for cs, ce in char_spans:
        toks = [k for k, (a, b) in enumerate(offs) if a >= cs and b <= ce and b > a]
        spans.append((toks[0], toks[-1] + 1))
    return ids, spans


def _logprob_mean_prefix(model, p_ids, c_ids):
    """Mean log-prob of the completion with the prompt run once WITHOUT gradients (2026-10-08): the prompt's cache
    (attention keys/values and the linear-attention states) is built under no_grad, then only the completion runs
    with gradients on top of it. Memory then follows the completion, not the 20-30k-token resident conversation.
    Approximation: the LoRA's effect on the prompt positions gets no gradient (completion positions do)."""
    import torch
    core = model.base_model.model
    with torch.no_grad():
        out = core.model(input_ids=torch.tensor([p_ids], device="cuda:0"), use_cache=True)
        past = out.past_key_values
        last_h = out.last_hidden_state[0, -1:].detach()  # predicts the first completion token
        del out
    c = torch.tensor([c_ids], device="cuda:0")
    hid = core.model(input_ids=c, past_key_values=past, use_cache=True).last_hidden_state[0]  # [n_comp, H]
    h = torch.cat([last_h, hid[:-1]], 0)
    lg = core.lm_head(h).float()
    lp = torch.log_softmax(lg, -1).gather(1, c[0][:, None])[:, 0]
    return lp.mean()


def cmd_train(a):
    import torch
    from transformers import AutoModelForImageTextToText, AutoTokenizer, BitsAndBytesConfig
    from peft import PeftModel
    t0 = time.time()
    groups = json.loads(Path(a.samples).read_text(encoding="utf-8"))
    tok = AutoTokenizer.from_pretrained(MODEL)
    qc = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_use_double_quant=True,
                            bnb_4bit_compute_dtype=torch.bfloat16, llm_int8_skip_modules=["visual", "lm_head"])
    base = AutoModelForImageTextToText.from_pretrained(MODEL, quantization_config=qc, dtype=torch.bfloat16,
                                                       device_map={"": 0})
    model = PeftModel.from_pretrained(base, a.adapter, is_trainable=True)
    if not a.prefix_nograd:
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model.enable_input_require_grads()
        model.config.use_cache = False
    model.train()
    params = [p for n, p in model.named_parameters() if p.requires_grad]
    assert params and all("lora_" in n for n, p in model.named_parameters() if p.requires_grad)
    opt = torch.optim.AdamW(params, lr=LR, weight_decay=0.0)
    load_s = round(time.time() - t0, 1)
    steps = []
    for g in groups:
        opt.zero_grad(set_to_none=True)
        total, ntok, ts = 0.0, 0, time.time()
        for it in g["items"]:
            p_txt = tok.apply_chat_template(it["messages"], tokenize=False, add_generation_prompt=True)
            p_ids = tok(p_txt, add_special_tokens=False)["input_ids"]
            c_ids = tok(it["completion"] + "<|im_end|>", add_special_tokens=False)["input_ids"]
            # the chat template may already open "<think>\n" in the generation prompt; drop a duplicate
            pre = tok("<think>\n", add_special_tokens=False)["input_ids"]
            if p_ids[-len(pre):] == pre and c_ids[:len(pre)] == pre:
                c_ids = c_ids[len(pre):]
            ids = torch.tensor([list(p_ids) + c_ids], device="cuda:0")
            with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
                lp = _logprob_mean_prefix(model, list(p_ids), c_ids) if a.prefix_nograd else                     _logprob_mean(model, ids, len(c_ids))
            loss = -(float(it["adv"]) * lp) / len(g["items"])
            loss.backward()
            total += float(loss.detach())
            ntok += ids.shape[1]
            del ids, lp, loss
            torch.cuda.empty_cache()
        gn = float(torch.nn.utils.clip_grad_norm_(params, 1.0))
        opt.step()
        opt.zero_grad(set_to_none=True)
        steps.append({"group": g["group"], "items": len(g["items"]), "loss": round(total, 6), "grad_norm": round(gn, 4),
                      "tokens": ntok, "s": round(time.time() - ts, 1),
                      "peak_gib": round(torch.cuda.max_memory_allocated() / 2 ** 30, 2)})
        print("[TRAIN] step", json.dumps(steps[-1]), flush=True)
    out = Path(a.out)
    model.save_pretrained(str(out))
    (out / "TRAIN_STEPS.json").write_text(json.dumps({"steps": steps, "load_s": load_s, "init_adapter": a.adapter,
                                                      "total_s": round(time.time() - t0, 1)}, indent=1), encoding="utf-8")
    print("[TRAIN] saved", out, flush=True)


def cmd_sft(a):
    """Supervised distillation: rows [{messages, completion}] -> LoRA. Thinking OFF (the cloud's reasoning was not
    captured), loss = mean CE over the completion tokens, AdamW, grad accumulation, a few epochs."""
    import random
    import torch
    from transformers import AutoModelForImageTextToText, AutoTokenizer, BitsAndBytesConfig
    from peft import PeftModel
    t0 = time.time()
    rows = json.loads(Path(a.data).read_text(encoding="utf-8"))
    tok = AutoTokenizer.from_pretrained(MODEL)
    qc = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_use_double_quant=True,
                            bnb_4bit_compute_dtype=torch.bfloat16, llm_int8_skip_modules=["visual", "lm_head"])
    base = AutoModelForImageTextToText.from_pretrained(MODEL, quantization_config=qc, dtype=torch.bfloat16,
                                                       device_map={"": 0})
    model = PeftModel.from_pretrained(base, a.adapter, is_trainable=True)
    nograd = bool(getattr(a, "prefix_nograd", False))  # 2026-10-10: 11k-token resident prompts ran out of memory
    if not nograd:
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model.enable_input_require_grads()
        model.config.use_cache = False
    model.train()
    params = [p for p in model.parameters() if p.requires_grad]
    opt = torch.optim.AdamW(params, lr=a.lr, weight_decay=0.0)
    enc = []  # (token ids, target spans): a plain row has one span (its completion), a multi-turn row several
    for r in rows:
        if r.get("multi"):
            enc.append(_multi_encode(tok, r["messages"], int(r.get("first_target", 0))))
            continue
        p_txt = tok.apply_chat_template(r["messages"], tokenize=False, add_generation_prompt=True,
                                      enable_thinking=bool(getattr(a, "think", False)))  # think: prompt opens a think block
        p_ids = tok(p_txt, add_special_tokens=False)["input_ids"]
        c_ids = tok(r["completion"] + "<|im_end|>", add_special_tokens=False)["input_ids"]
        enc.append((p_ids + c_ids, [(len(p_ids), len(p_ids) + len(c_ids))]))
    if getattr(a, "max_tokens", 0):  # 2026-10-10: a ~49k-token row ran the 24 GB GPU out of memory even with --offload
        before = len(enc)
        enc = [e for e in enc if len(e[0]) <= a.max_tokens]
        print("[SFT] skipped %d sequences longer than %d tokens" % (before - len(enc), a.max_tokens), flush=True)
    if getattr(a, "max_rows", 0):
        enc = sorted(enc, key=lambda e: -len(e[0]))[:a.max_rows]
    n_turns = sum(len(sp) for _, sp in enc)
    print("[SFT] sequences", len(enc), "target answers", n_turns, "tokens mean", sum(len(x) for x, _ in enc) // len(enc),
          "max", max(len(x) for x, _ in enc), flush=True)
    rng = random.Random(0)
    total_steps = (n_turns * a.epochs) // a.accum  # one optimizer step per `accum` answers, as with plain rows
    # Chunked runs (2026-10-10): --start-step skips the rows already trained (same seeded order), --max-steps stops
    # early, --save-every writes <out>/ckpt_step<N>; the next chunk starts from that checkpoint (--adapter).
    start = int(getattr(a, "start_step", 0))
    step, log = start, []
    out = Path(a.out)

    def save(path):
        model.save_pretrained(str(path))
        (path / "SFT_LOG.json").write_text(json.dumps({"log": log, "rows": len(enc), "epochs": a.epochs, "lr": a.lr,
                                                       "accum": a.accum, "step": step, "total_steps": total_steps,
                                                       "total_s": round(time.time() - t0, 1)}, indent=1), encoding="utf-8")
        print("[SFT] saved", path, "step", step, "peak %.2fGiB" % (torch.cuda.max_memory_allocated() / 2 ** 30),
              "%.0fs" % (time.time() - t0), flush=True)

    seen, pending = 0, 0
    for ep in range(a.epochs):
        order = list(range(len(enc)))
        rng.shuffle(order)
        run, n = 0.0, 0
        for k, i in enumerate(order):
            tok_ids, spans = enc[i]
            done_before = seen  # answers seen so far (all epochs), for resuming at --start-step
            seen += len(spans)
            if done_before < start * a.accum:
                continue
            ids = torch.tensor([tok_ids], device="cuda:0")
            # --offload (2026-10-10): exact full-prompt gradients; the tensors saved for backward (checkpoint inputs)
            # live in pinned CPU RAM instead of the GPU, so long resident prompts fit.
            offload = torch.autograd.graph.save_on_cpu(pin_memory=True) if getattr(a, "offload", False) else contextlib.nullcontext()
            with torch.autocast(device_type="cuda", dtype=torch.bfloat16), offload:
                if nograd:
                    (s0, e0), = spans
                    lps = [_logprob_mean_prefix(model, tok_ids[:s0], tok_ids[s0:e0])]
                else:
                    lps = _logprob_spans(model, ids, spans)
            loss = -sum(lps) / a.accum
            loss.backward()
            run += sum(float(-x.detach()) for x in lps)
            n += len(lps)
            pending += len(lps)
            del ids, lps, loss
            if pending >= a.accum:
                pending = 0
                for g in opt.param_groups:  # linear decay to 10%
                    g["lr"] = a.lr * (1 - 0.9 * step / max(1, total_steps))
                torch.nn.utils.clip_grad_norm_(params, 1.0)
                opt.step()
                opt.zero_grad(set_to_none=True)
                step += 1
                if step % 10 == 0:
                    print(f"[SFT] ep{ep} step {step}/{total_steps} nll {run / n:.4f} "
                          f"peak {torch.cuda.max_memory_allocated() / 2 ** 30:.2f}GiB {time.time() - t0:.0f}s", flush=True)
                    log.append({"epoch": ep, "step": step, "nll": round(run / n, 4)})
                    run, n = 0.0, 0
                if getattr(a, "save_every", 0) and step % a.save_every == 0:
                    save(out / ("ckpt_step%d" % step))
                if getattr(a, "max_steps", 0) and step >= a.max_steps:
                    save(out / ("ckpt_step%d" % step))
                    return
    save(out / ("ckpt_step%d" % step))
    save(out)
    (out / "TRAIN_DONE").write_text(str(step), encoding="utf-8")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("init")
    i.add_argument("--out", required=True)
    t = sub.add_parser("train")
    t.add_argument("--adapter", required=True)
    t.add_argument("--samples", required=True)
    t.add_argument("--out", required=True)
    t.add_argument("--full-grad", dest="prefix_nograd", action="store_false",
                   help="backprop through the whole prompt too (exact; runs out of memory on long resident games)")
    s = sub.add_parser("sft")
    s.add_argument("--adapter", required=True)
    s.add_argument("--data", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--epochs", type=int, default=3)
    s.add_argument("--lr", type=float, default=1e-4)
    s.add_argument("--accum", type=int, default=8)
    s.add_argument("--max-tokens", type=int, default=0, help="skip sequences longer than this (0 = keep all)")
    s.add_argument("--offload", action="store_true", help="exact gradients, saved activations offloaded to CPU RAM")
    s.add_argument("--max-rows", type=int, default=0, help="test: train only the N longest rows (memory / speed probe)")
    s.add_argument("--prefix-nograd", action="store_true",
                   help="prompt under no_grad, gradients through the completion only (memory follows the completion)")
    s.add_argument("--start-step", type=int, default=0, help="resume: optimizer steps already trained (same row order)")
    s.add_argument("--max-steps", type=int, default=0, help="stop after this optimizer step (0 = all epochs)")
    s.add_argument("--save-every", type=int, default=0, help="save <out>/ckpt_step<N> every N steps")
    s.add_argument("--think", action="store_true", help="completion = short thinking + </think> + answer (thinking-on prompt)")
    a = ap.parse_args()
    {"init": cmd_init, "train": cmd_train, "sft": cmd_sft}[a.cmd](a)
