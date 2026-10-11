"""Qwen3-30B-A3B-Thinking-2507 QLoRA SFT; prepare only until GPU is free.

The corpus has final JSON but no reasoning trace. We provide an empty think block
as *masked context* and calculate loss on final JSON and end-of-turn only. This
does not train the model to emit an immediate </think>; it also cannot teach
the model how to reason. At inference the base model supplies its own thinking.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "artifacts" / "brain_pipeline_v1" / "s2_sft"
MODEL = "/mnt/d/StrategyAI/models/Qwen3-30B-A3B-Thinking-2507-bnb-4bit"
TOKENIZER = "/mnt/d/StrategyAI/models/Qwen3-30B-A3B-Thinking-2507-tokenizer"
# vLLM's Qwen3Moe LoRA path serves attention projections only.
LORA_TARGETS = ("q_proj", "k_proj", "v_proj", "o_proj")


def load_examples(rows_file: Path, prompts_file: Path):
    prompts = {p["prompt_id"]: p["messages"] for p in json.loads(prompts_file.read_text(encoding="utf-8"))}
    with rows_file.open(encoding="utf-8") as f:
        for line in f:
            if line.strip():
                row = json.loads(line)
                yield row, prompts[row["prompt_id"]]


def encode_row(tok, row, messages, max_seq_len):
    # Thinking-2507's template opens <think>. Only the answer after </think>
    # receives labels; the empty block and its close are conditioning context.
    prompt = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    if "<think>" not in prompt:
        raise ValueError("Thinking chat template did not open <think>")
    prefix = prompt + "</think>\n"
    answer = row["target"] + tok.eos_token
    prefix_ids = tok(prefix, add_special_tokens=False)["input_ids"]
    answer_ids = tok(answer, add_special_tokens=False)["input_ids"]
    all_ids = tok(prefix + answer, add_special_tokens=False)["input_ids"]
    if all_ids[:len(prefix_ids)] != prefix_ids:
        raise ValueError(f"token boundary changed for row {row['row_id']}")
    if len(all_ids) > max_seq_len:
        raise ValueError(f"row {row['row_id']} length {len(all_ids)} exceeds {max_seq_len}")
    return {"input_ids": all_ids, "attention_mask": [1] * len(all_ids),
            "labels": [-100] * len(prefix_ids) + all_ids[len(prefix_ids):]}


class Rows:
    def __init__(self, values):
        self.values = values

    def __len__(self):
        return len(self.values)

    def __getitem__(self, index):
        return self.values[index]


def collate(items, pad_id):
    import torch
    width = max(len(x["input_ids"]) for x in items)
    return {k: torch.tensor([x[k] + [fill] * (width - len(x[k])) for x in items], dtype=torch.long)
            for k, fill in (("input_ids", pad_id), ("attention_mask", 0), ("labels", -100))}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--tokenizer", default=TOKENIZER,
                    help="official Thinking-2507 tokenizer, independent of quantized weight repo")
    ap.add_argument("--rows", type=Path, default=DATA / "sft_rows.jsonl")
    ap.add_argument("--prompts", type=Path, default=DATA / "sft_prompts.json")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--init-adapter", type=Path)
    ap.add_argument("--max-seq-len", type=int, default=10240)
    ap.add_argument("--epochs", type=float, default=2)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--accum", type=int, default=8)
    ap.add_argument("--seed", type=int, default=20260926)
    args = ap.parse_args()
    if args.out.exists() and any(args.out.iterdir()):
        raise FileExistsError(f"output must be empty: {args.out}")
    if args.init_adapter and args.out.resolve() == args.init_adapter.resolve():
        raise ValueError("output cannot overwrite init adapter")

    # Unsloth must be imported before transformers/peft so its patches apply.
    from unsloth import FastModel
    import torch
    from peft import PeftModel
    from transformers import AutoTokenizer, Trainer, TrainingArguments

    model, _ = FastModel.from_pretrained(
        model_name=args.model, max_seq_length=args.max_seq_len, dtype=torch.bfloat16,
        load_in_4bit=True, trust_remote_code=False)
    tok = AutoTokenizer.from_pretrained(args.tokenizer, trust_remote_code=False)
    if tok.pad_token_id is None:
        tok.pad_token = tok.eos_token
    if args.init_adapter:
        model = PeftModel.from_pretrained(model, str(args.init_adapter), is_trainable=True)
        cfg = model.peft_config[model.active_adapter]
        if set(cfg.target_modules) != set(LORA_TARGETS):
            raise ValueError(f"init adapter targets {cfg.target_modules} differ from {LORA_TARGETS}")
    else:
        model = FastModel.get_peft_model(
            model, r=8, target_modules=list(LORA_TARGETS), lora_alpha=16,
            lora_dropout=0, bias="none", use_gradient_checkpointing="unsloth",
            random_state=args.seed)
    model.config.use_cache = False
    encoded = {"train": [], "dev": []}
    for row, messages in load_examples(args.rows, args.prompts):
        if row["split"] in encoded:
            encoded[row["split"]].append(encode_row(tok, row, messages, args.max_seq_len))
    if not encoded["train"]:
        raise ValueError("no train rows")
    args.out.mkdir(parents=True, exist_ok=True)
    training = TrainingArguments(
        output_dir=str(args.out / "checkpoints"), num_train_epochs=args.epochs,
        per_device_train_batch_size=1, per_device_eval_batch_size=1,
        gradient_accumulation_steps=args.accum, learning_rate=args.lr,
        bf16=True, optim="adamw_8bit", logging_steps=10, save_strategy="no",
        eval_strategy="epoch" if encoded["dev"] else "no",
        report_to="none", remove_unused_columns=False, seed=args.seed)
    trainer = Trainer(model=model, args=training, train_dataset=Rows(encoded["train"]),
                      eval_dataset=Rows(encoded["dev"]) if encoded["dev"] else None,
                      data_collator=lambda items: collate(items, tok.pad_token_id))
    trainer.train()
    model.save_pretrained(str(args.out), safe_serialization=True)
    tok.save_pretrained(str(args.out))
    print(json.dumps({"adapter": str(args.out), "train_rows": len(encoded["train"]),
                      "dev_rows": len(encoded["dev"]), "targets": LORA_TARGETS}))


if __name__ == "__main__":
    main()
