"""HAND B full fine-tune (clean Laya base -> separate Hand B checkpoint).

  <laya venv python> tools/hand_b/train_hand_b.py --out <dir> [--max_train N] [--epochs E] [--smoke]

Loss: masked soft-target cross entropy over candidate (marker) logits; every
accepted candidate shares target mass equally (never collapsed to one-hot).
Sequence format = laya SDK build_sequence (same as the runtime worker), with
Hand B rendering from tools/hand_b/common.py.
"""
import argparse, hashlib, json, math, os, random, shutil, sys, time

import torch
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

BASE_DIR = r"D:\LayaRuntime\models\laya-multilingual"
BASE_SHA = "9D628FD971B700382AC6F65920A86F149777B2E748E0C955FB3B19695AA8F204"
DATA = r"D:\Game development\Demon slayer\StrategyGame\artifacts\laya_synthetic_v2"
MAX_LEN, HEAD_MAX = 2048, 1024


def sha_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for ch in iter(lambda: f.read(1 << 20), b""):
            h.update(ch)
    return h.hexdigest().upper()


def keys_for(n):
    a = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    return [a[i] if i < 26 else a[i // 26 - 1] + a[i % 26] for i in range(n)]


def encode_row(tok, row):
    """-> item dict for laya.common.collate_items, or None if unplaceable."""
    from laya.common import build_sequence, QTYPES
    state = {"side": row["side"], "bounds": row["bounds"], "ledger": row["ledger"], "turn": row["turn"]}
    ctx = C.build_ctx(state, row["unit"])
    opts = C.render_options(row["unit"], row["candidates"], ctx)
    keys = keys_for(len(opts))
    q = {"t": "choice", "ins": C.HAND_B_INSTRUCTIONS, "crit": dict(zip(keys, opts))}
    st = C.render_state(row["order"], row["unit"], ctx, row["turn"])
    ids, markers = build_sequence(tok, st, q, MAX_LEN, HEAD_MAX)
    if len(markers) != len(opts):
        return None
    acc = set(row["accepted"])
    tgt = [1.0 if c["candidate_id"] in acc else 0.0 for c in row["candidates"]]
    s = sum(tgt)
    if s <= 0:
        return None
    return {"ids": ids, "markers": markers, "qtype": QTYPES["choice"], "target": [t / s for t in tgt]}


def load_rows(path, limit=0, seed=0):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            rows.append(json.loads(line))
    if limit and len(rows) > limit:
        rows = random.Random(seed).sample(rows, limit)
    return rows


def batches(items, max_tokens, max_rows, shuffle, seed):
    idx = list(range(len(items)))
    rnd = random.Random(seed)
    if shuffle:
        rnd.shuffle(idx)
    # length-bucketed within chunks of 2048 to cut padding, then shuffle batches
    out = []
    for i in range(0, len(idx), 2048):
        chunk = sorted(idx[i:i + 2048], key=lambda k: len(items[k]["ids"]))
        cur, mx = [], 0
        for k in chunk:
            L = len(items[k]["ids"])
            if cur and (max(mx, L) * (len(cur) + 1) > max_tokens or len(cur) >= max_rows):
                out.append(cur); cur, mx = [], 0
            cur.append(k); mx = max(mx, L)
        if cur:
            out.append(cur)
    if shuffle:
        rnd.shuffle(out)
    return out


def forward(model, items, bidx, device):
    from laya.common import collate_items
    b = collate_items([[items[k] for k in bidx]], 0)
    with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
        logits, _ = model(b["input_ids"].to(device), b["attention_mask"].to(device), b["marker_pos"].to(device),
                          b["marker_mask"].to(device), b["qtype"].to(device))
    logits = logits.float()
    mask = b["marker_mask"].to(device)
    tgt = b["target"].to(device)
    logp = F.log_softmax(logits.masked_fill(~mask, -1e4), -1)
    loss = -(tgt * logp).sum(-1).mean()
    return loss, logits, mask, tgt


@torch.no_grad()
def evaluate(model, items, device, max_tokens=12000):
    model.eval()
    n = top1 = 0
    mass = loss_sum = 0.0
    for bidx in batches(items, max_tokens, 32, False, 0):
        loss, logits, mask, tgt = forward(model, items, bidx, device)
        p = torch.softmax(logits.masked_fill(~mask, -1e4), -1)
        am = p.argmax(-1)
        top1 += (tgt.gather(1, am[:, None]).squeeze(1) > 0).sum().item()
        mass += (p * (tgt > 0)).sum(-1).sum().item()
        loss_sum += loss.item() * len(bidx)
        n += len(bidx)
    model.train()
    return {"n": n, "top1": top1 / max(1, n), "acc_mass": mass / max(1, n), "loss": loss_sum / max(1, n)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--train", default=os.path.join(DATA, "train.jsonl"))
    ap.add_argument("--val", default=os.path.join(DATA, "val.jsonl"))
    ap.add_argument("--max_train", type=int, default=0)
    ap.add_argument("--max_val", type=int, default=3000)
    ap.add_argument("--epochs", type=float, default=2.0)
    ap.add_argument("--lr", type=float, default=3e-5)
    ap.add_argument("--head_lr", type=float, default=1e-4)
    ap.add_argument("--max_tokens", type=int, default=9000)
    ap.add_argument("--max_rows", type=int, default=16)
    ap.add_argument("--accum", type=int, default=2)
    ap.add_argument("--eval_every", type=int, default=500)
    ap.add_argument("--smoke", action="store_true", help="overfit: eval on the train subset itself")
    ap.add_argument("--seed", type=int, default=1234)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    torch.manual_seed(a.seed); random.seed(a.seed)
    got = sha_file(os.path.join(BASE_DIR, "model.safetensors"))
    assert got == BASE_SHA, "base checkpoint identity mismatch %s" % got
    import laya
    agent = laya.load(BASE_DIR, device="cuda")
    model, tok, dev = agent.model, agent.tok, agent.device
    for p in model.parameters():
        p.requires_grad_(True)
    model.float()
    try:
        model.encoder.gradient_checkpointing_enable()
        gc = True
    except Exception:
        gc = False
    model.train()
    t0 = time.time()
    tr_rows = load_rows(a.train, a.max_train, a.seed)
    va_rows = tr_rows if a.smoke else load_rows(a.val, a.max_val, a.seed)
    tr = [x for x in (encode_row(tok, r) for r in tr_rows) if x]
    va = [x for x in (encode_row(tok, r) for r in va_rows) if x]
    enc_s = time.time() - t0
    head_names = ("head.", "scorer.", "type_emb.", "act_head.")
    groups = [{"params": [p for n, p in model.named_parameters() if not n.startswith(head_names)], "lr": a.lr},
              {"params": [p for n, p in model.named_parameters() if n.startswith(head_names)], "lr": a.head_lr}]
    opt = torch.optim.AdamW(groups, weight_decay=0.01, betas=(0.9, 0.98), eps=1e-6)
    steps_per_epoch = math.ceil(len(batches(tr, a.max_tokens, a.max_rows, True, 0)) / a.accum)
    total = max(1, int(steps_per_epoch * a.epochs))
    warm = max(1, int(0.03 * total))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / warm) * 0.5 * (1 + math.cos(math.pi * min(1.0, s / total))))
    cfg = {"base_dir": BASE_DIR, "base_sha256": BASE_SHA, "train_file": a.train, "train_sha256": sha_file(a.train),
           "val_file": a.val, "val_sha256": sha_file(a.val) if os.path.exists(a.val) else None,
           "n_train_rows": len(tr_rows), "n_train_encoded": len(tr), "n_val": len(va), "epochs": a.epochs, "lr": a.lr,
           "head_lr": a.head_lr, "max_tokens": a.max_tokens, "max_rows": a.max_rows, "accum": a.accum, "optimizer": "AdamW(0.9,0.98,1e-6,wd0.01)",
           "schedule": "linear warmup 3% + cosine", "total_steps": total, "precision": "bf16 autocast, fp32 master", "grad_checkpointing": gc,
           "loss": "masked soft-target CE; accepted share mass equally", "seq": {"max_len": MAX_LEN, "head_max_len": HEAD_MAX},
           "split": "scenario-hash 90/5/5 (gen_v2.split_of)", "full_finetune": True, "seed": a.seed, "smoke": a.smoke,
           "renderer": "tools/hand_b/common.py", "instructions": C.HAND_B_INSTRUCTIONS}
    json.dump(cfg, open(os.path.join(a.out, "TRAIN_CONFIG.json"), "w"), indent=1)
    log = open(os.path.join(a.out, "train_log.jsonl"), "a")
    ev0 = evaluate(model, va, dev)
    log.write(json.dumps({"step": 0, "eval": ev0, "encode_s": round(enc_s, 1)}) + "\n"); log.flush()
    print("step 0", ev0, flush=True)
    best = ev0["top1"]; step = 0; ep = 0; run = 0.0; rn = 0
    torch.cuda.reset_peak_memory_stats()
    while step < total:
        bl = batches(tr, a.max_tokens, a.max_rows, True, a.seed + ep)
        for i, bidx in enumerate(bl):
            loss, *_ = forward(model, tr, bidx, dev)
            (loss / a.accum).backward()
            run += loss.item(); rn += 1
            if (i + 1) % a.accum:
                continue
            gn = torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step(); sched.step(); opt.zero_grad(set_to_none=True); step += 1
            if not math.isfinite(run):
                raise SystemExit("non-finite loss at step %d" % step)
            if step % 50 == 0:
                rec = {"step": step, "loss": round(run / rn, 4), "grad_norm": round(float(gn), 3), "lr": sched.get_last_lr()[0],
                       "peak_gb": round(torch.cuda.max_memory_allocated() / 1e9, 2), "elapsed_s": round(time.time() - t0)}
                log.write(json.dumps(rec) + "\n"); log.flush(); print(rec, flush=True)
                run = 0.0; rn = 0
            if step % a.eval_every == 0 or step >= total:
                ev = evaluate(model, va, dev)
                log.write(json.dumps({"step": step, "eval": ev}) + "\n"); log.flush(); print("eval", step, ev, flush=True)
                if ev["top1"] >= best:
                    best = ev["top1"]
                    save(model, a.out, "best")
            if step >= total:
                break
        ep += 1
    save(model, a.out, "final")
    log.write(json.dumps({"done": True, "best_val_top1": best, "elapsed_s": round(time.time() - t0)}) + "\n"); log.close()


def save(model, out, tag):
    from safetensors.torch import save_file
    d = os.path.join(out, tag)
    os.makedirs(d, exist_ok=True)
    sd = {k: v.detach().to(torch.float16).contiguous().cpu() for k, v in model.state_dict().items()}
    save_file(sd, os.path.join(d, "model.safetensors"))
    for sub in ("tokenizer", "encoder"):
        if not os.path.exists(os.path.join(d, sub)):
            shutil.copytree(os.path.join(BASE_DIR, sub), os.path.join(d, sub))
    shutil.copy(os.path.join(BASE_DIR, "rl_agent_config.json"), os.path.join(d, "rl_agent_config.json"))


if __name__ == "__main__":
    main()
