"""CONTRACT_SFT_V1 — bounded QLoRA SFT (fresh process; exits when done). NOT GRPO.

Starts from the T0086 adapter (continues the SAME LoRA r=8, targets
q/k/v/o/gate/up/down), Qwen3-8B NF4 double-quant BF16, SDPA, gradient
checkpointing (use_reentrant=False), use_cache=False — the marathon's proven
memory practice. Completion-only cross-entropy: prompt tokens are context,
the loss covers target tokens + EOS only (logits materialized for the
target span only via logits_to_keep). Memory guard every micro-step:
device > 20.5 GiB or host available < 16 GiB -> abort (exit 42, no save).

The output adapter goes to a NEW directory; T0086 is only read.

  python -m tools.contract_sft.train_sft --init-adapter <T0086 dir>
      --out <candidate dir> [--epochs 2 --lr 1e-4 --accum 8]
"""
from __future__ import annotations

import argparse
import gc
import json
import math
import os
import random
import time
from pathlib import Path

from tools.contract_sft import gpu_common as G

ROOT = G.ARTIFACT_ROOT


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--init-adapter", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rows", default=str(ROOT / "dataset" / "sft_rows.jsonl"))
    ap.add_argument("--epochs", type=int, default=2)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--accum", type=int, default=8)
    ap.add_argument("--warmup", type=int, default=6)
    ap.add_argument("--seed", type=int, default=20260926)
    ap.add_argument("--prompts", default="", help="extra prompt file [{prompt_id, messages}] (e.g. S0 corpus)")
    args = ap.parse_args()
    out = Path(args.out)
    assert Path(args.init_adapter).resolve() != out.resolve(), "never overwrite the init adapter"
    assert not (out / "adapter_model.safetensors").exists(), f"refusing to overwrite {out}"
    out.mkdir(parents=True, exist_ok=True)
    log = G.make_logger(out / "train.log")
    rows = [json.loads(l) for l in open(args.rows, encoding="utf-8")]
    prompts = {}
    for pf in [ROOT / "prompts" / f"{n}.json" for n in ("train_gen", "train_gen2", "train_gen3", "train_gen4", "train_gen5", "rl_A")] + \
            [ROOT / "augment" / "remap_v1_prompts.json", ROOT / "dataset_csft3" / "r3_augment_prompts.json",
             ROOT / "dataset_csft4" / "r4_augment_prompts.json",
             ROOT / "dataset_csft5" / "r5_augment_prompts.json",
             ROOT / "prompts" / "csft5_train_rebuilt_v2.json",
             ROOT / "dataset_r5seq" / "r5_augment_prompts.json"]:
        if pf.exists():
            for p in json.loads(pf.read_text(encoding="utf-8")):
                prompts[p["prompt_id"]] = p
    if args.prompts:
        for p in json.loads(Path(args.prompts).read_text(encoding="utf-8")):
            prompts[p["prompt_id"]] = p
    train = [r for r in rows if r["split"] == "train"]
    dev = [r for r in rows if r["split"] == "dev"]
    log(f"[SFT] rows train={len(train)} dev={len(dev)} epochs={args.epochs} lr={args.lr} "
        f"accum={args.accum} init={args.init_adapter}")

    import torch
    guard = G.Guard(log)
    init_sha = G.file_sha256(os.path.join(args.init_adapter, "adapter_model.safetensors"))
    with G.gpu_lock("contract_sft_train", "SFT_TRAIN"):
        torch.cuda.empty_cache()
        guard.check("init")
        if G.device_used_gib() > 4.0:
            raise G.GuardBreach("GPU not initially clear")
        tok = G.load_tokenizer()

        def encode(r):
            p = tok(G.render_prompt(tok, prompts[r["prompt_id"]]["messages"]), add_special_tokens=False)["input_ids"]
            t = tok(r["target"], add_special_tokens=False)["input_ids"] + [tok.eos_token_id]
            return p, t
        enc_train = [encode(r) for r in train]
        enc_dev = [encode(r) for r in dev]
        log(f"[SFT] max seq={max(len(p) + len(t) for p, t in enc_train)} "
            f"target tokens total={sum(len(t) for _, t in enc_train)}")
        base = G.load_base()
        guard.check("base_loaded")
        from peft import PeftModel
        model = PeftModel.from_pretrained(base, args.init_adapter, is_trainable=True)
        model.config.use_cache = False
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model.config.use_cache = False
        trainable = [(n, p) for n, p in model.named_parameters() if p.requires_grad]
        assert trainable and all("lora_" in n for n, _ in trainable)
        cfg = model.peft_config["default"]
        log(f"[SFT] LoRA r={cfg.r} alpha={cfg.lora_alpha} targets={sorted(cfg.target_modules)} "
            f"trainable tensors={len(trainable)} params={sum(p.numel() for _, p in trainable)}")
        assert cfg.r == 8
        opt = torch.optim.AdamW([p for _, p in trainable], lr=args.lr, weight_decay=0.0)
        steps_per_epoch = math.ceil(len(enc_train) / args.accum)
        total_steps = steps_per_epoch * args.epochs

        def lr_at(step):
            if step < args.warmup:
                return args.lr * (step + 1) / args.warmup
            prog = (step - args.warmup) / max(1, total_steps - args.warmup)
            return args.lr * (0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * prog)))

        def loss_of(p, t):
            ids = torch.tensor([p + t], dtype=torch.long, device="cuda:0")
            with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
                logits = model(input_ids=ids, logits_to_keep=len(t) + 1).logits
            pred = logits[0, :len(t)].float()
            return torch.nn.functional.cross_entropy(pred, torch.tensor(t, device="cuda:0"))

        def dev_loss():
            if not enc_dev:
                return None
            model.eval()
            tot = 0.0
            with torch.no_grad():
                for p, t in enc_dev:
                    tot += float(loss_of(p, t))
            model.train()
            return round(tot / len(enc_dev), 5)

        hist = {"steps": [], "dev_loss": [], "epoch_train_loss": []}
        d0 = dev_loss()
        hist["dev_loss"].append({"epoch": 0, "loss": d0})
        log(f"[SFT] dev loss before={d0}")
        model.train()
        rng = random.Random(args.seed)
        step = 0
        t0 = time.time()
        for ep in range(1, args.epochs + 1):
            order = list(range(len(enc_train)))
            rng.shuffle(order)
            ep_losses = []
            opt.zero_grad(set_to_none=True)
            for k, i in enumerate(order):
                p, t = enc_train[i]
                loss = loss_of(p, t)
                lv = float(loss.detach())
                if not math.isfinite(lv):
                    raise RuntimeError(f"non-finite loss at epoch {ep} item {i}")
                (loss / args.accum).backward()
                ep_losses.append(lv)
                del loss
                if (k + 1) % args.accum == 0 or k == len(order) - 1:
                    gn = float(torch.nn.utils.clip_grad_norm_([q for _, q in trainable], 1.0))
                    for g in opt.param_groups:
                        g["lr"] = lr_at(step)
                    opt.step()
                    opt.zero_grad(set_to_none=True)
                    step += 1
                    rec = {"step": step, "epoch": ep, "lr": round(lr_at(step - 1), 8), "grad_norm": round(gn, 4),
                           "loss": round(sum(ep_losses[-args.accum:]) / len(ep_losses[-args.accum:]), 5),
                           "elapsed_s": round(time.time() - t0, 1)}
                    hist["steps"].append(rec)
                    log(f"[SFT] step {step}/{total_steps} {rec}")
                    guard.check(f"step{step}")
                    gc.collect()
                    torch.cuda.empty_cache()
            hist["epoch_train_loss"].append({"epoch": ep, "loss": round(sum(ep_losses) / len(ep_losses), 5)})
            dl = dev_loss()
            hist["dev_loss"].append({"epoch": ep, "loss": dl})
            log(f"[SFT] epoch {ep} train_loss={hist['epoch_train_loss'][-1]['loss']} dev_loss={dl}")
            ep_dir = out / f"epoch{ep}"
            model.save_pretrained(str(ep_dir))
            log(f"[SFT] saved {ep_dir}")
        model.save_pretrained(str(out))
        summary = {"status": "SFT_DONE", "method": "QLoRA SFT (completion-only CE), not GRPO",
                   "init_adapter": args.init_adapter, "init_adapter_sha256": init_sha,
                   "init_adapter_sha256_after": G.file_sha256(os.path.join(args.init_adapter,
                                                                           "adapter_model.safetensors")),
                   "out_adapter_sha256": G.file_sha256(str(out / "adapter_model.safetensors")),
                   "rows_file": args.rows, "rows_sha256": G.file_sha256(args.rows),
                   "train_rows": len(train), "dev_rows": len(dev), "epochs": args.epochs, "lr": args.lr,
                   "accum": args.accum, "optimizer_steps": step, "lora_r": cfg.r,
                   "wall_s": round(time.time() - t0, 1), "memory": guard.summary(), "history": hist}
        assert summary["init_adapter_sha256"] == summary["init_adapter_sha256_after"]
        G.write_json(out / "SFT_SUMMARY.json", summary)
        log(f"[SFT] done steps={step} memory={guard.summary()}")
        del model, base, opt
        gc.collect()
        torch.cuda.empty_cache()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
