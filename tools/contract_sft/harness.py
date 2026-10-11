"""Python side of the production harness + strict first-pass metrics.

The VERDICT always comes from Godot (tools/contract_sft_harness.gd running
the production INITIAL path). Python adds only what Godot's pipeline hides:
whether the raw text was itself exactly one JSON object (Godot's
extract_json fence/prose/trailing-junk salvage counts as REPAIR), and the
plan-coherence predicates (reserve+mission etc.) from reward_contract.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from typing import Any, Dict, List

from tools.training_supervisor import reward_contract as RC

PROJ = r"D:\Game development\Demon slayer\StrategyGame"
GODOT = r"C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe"
TOOL = "res://tools/contract_sft_harness.gd"


def _godot(payload: Dict[str, Any], timeout: int = 1800) -> List[Dict[str, Any]]:
    with tempfile.TemporaryDirectory(prefix="csft_") as td:
        pin, pout = os.path.join(td, "in.json"), os.path.join(td, "out.json")
        with open(pin, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        p = subprocess.run([GODOT, "--headless", "--path", PROJ, "-s", TOOL, "--",
                            pin.replace("\\", "/"), pout.replace("\\", "/")],
                           capture_output=True, text=True, timeout=timeout,
                           encoding="utf-8", errors="replace")
        if not os.path.exists(pout):
            raise RuntimeError(f"godot harness produced no output rc={p.returncode} "
                               f"stdout={p.stdout[-1500:]} stderr={p.stderr[-1500:]}")
        with open(pout, encoding="utf-8") as f:
            return json.load(f)["results"]


def build_prompts(specs: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return _godot({"mode": "prompts", "scenarios": specs})


def validate(items: List[Dict[str, Any]], batch: int = 150) -> List[Dict[str, Any]]:
    """items: [{id, text, scenario}] -> Godot verdict + strict metrics."""
    out: List[Dict[str, Any]] = []
    for i in range(0, len(items), batch):
        chunk = items[i:i + batch]
        res = _godot({"mode": "validate", "items": chunk})
        assert [r["id"] for r in res] == [c["id"] for c in chunk]
        for c, r in zip(chunk, res):
            out.append(strict_metrics(c["text"], r))
    return out


def strict_metrics(text: str, g: Dict[str, Any]) -> Dict[str, Any]:
    doc, dups, err = RC._parse_direct(text)
    direct = isinstance(doc, dict)
    rec = dict(g)
    rec["json_extractable"] = bool(g.get("extract_nonempty"))   # syntactic (Godot, incl. salvage)
    rec["no_extra_text"] = direct                                # raw text == one JSON object
    rec["parser_pass"] = bool(g.get("extract_nonempty"))
    rec["validator_pass"] = bool(g.get("production_pass"))
    rec["strict_first_pass"] = bool(g.get("production_pass")) and direct
    coh = RC.coherence_check(doc, dups.paths) if direct else None
    rec["coherence_violations"] = coh
    rec["plan_coherent"] = bool(direct and not coh)
    rec["reserve_mission_fault"] = bool(coh and any(v.startswith("P7_") for v in coh))
    if not rec["parser_pass"]:
        cat = "UNPARSEABLE_JSON"
    elif not rec["validator_pass"]:
        cat = "VALIDATOR:" + (g.get("fault") or g.get("validator_code") or g.get("parse_code") or "UNKNOWN")
    elif not direct:
        cat = "EXTRA_TEXT_SALVAGED"
    else:
        cat = "PASS"
    rec["category"] = cat
    return rec


def root_close_truncate(text: str) -> str:
    """What a structural JSON stop-constraint (end generation the moment the
    root object closes) would have emitted for this SAME sample: sampling up
    to that character is causally identical, so this is exact, not a repair
    of content. Only defined when the output starts with '{' (a constrained
    decoder would force that); otherwise the raw text is returned."""
    s = text.lstrip()
    if not s.startswith("{"):
        return text
    depth, in_str, esc = 0, False, False
    for i, ch in enumerate(s):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
            if depth == 0:
                return s[:i + 1]
    return text


def summarize(rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    n = len(rows)
    if not n:
        return {"n": 0}

    def rate(k):
        c = sum(1 for r in rows if r.get(k))
        return {"n": c, "rate": round(c / n, 4)}
    cats: Dict[str, int] = {}
    for r in rows:
        cats[r["category"]] = cats.get(r["category"], 0) + 1
    parsed = [r for r in rows if r.get("no_extra_text")]
    return {"n": n,
            "strict_first_pass": rate("strict_first_pass"),
            "json_extractable": rate("json_extractable"),
            "no_extra_text": rate("no_extra_text"),
            "parser_pass": rate("parser_pass"),
            "validator_pass": rate("validator_pass"),
            "plan_coherent": rate("plan_coherent"),
            "reserve_mission_fault": rate("reserve_mission_fault"),
            "reserve_mission_fault_among_direct_json": round(
                sum(1 for r in parsed if r["reserve_mission_fault"]) / len(parsed), 4) if parsed else None,
            "categories": dict(sorted(cats.items(), key=lambda kv: -kv[1]))}


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")
