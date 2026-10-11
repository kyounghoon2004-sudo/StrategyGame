"""PLAN SEARCH step 1 — a strong cloud model proposes strategically DIFFERENT opening plans (2026-10-04).

The model (opencode CLI, default opencode-go/muse-spark-1.3-contributor, reasoning variant "max") sees exactly
what the Brain sees (system prompt + opening packet) plus one valid plan as a format example. It must first
write a deep situation analysis, then N candidates, each with its rationale, expected risks and the complete
plan. Analysis / rationale are kept for later study; only `plan` goes to validation (validate_plans.gd) and to
the game (eval_plans.py), which decides which plan is actually good.

  python -m tools.plan_search.gen_candidates --state <opening_state.json> --out <candidates.jsonl> [--calls 3 --per-call 3]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path

MODEL = "opencode-go/muse-spark-1.3-contributor"

ASK = """You are an expert strategy designer for a hex wargame. Take as much time and reasoning as you need:
quality matters far more than speed.

Below are (1) the exact system prompt and (2) the exact battle packet that our small Brain model receives at the
start of a battle, and (3) one VALID plan in the required output format.

The Brain only assigns missions; lower layers allocate units and act; units attack only under ATTACK tasks.
Design {n} COMPLETE opening plans for RED that are strategically DIFFERENT from
each other AND from the example: different main axis (CENTER / NORTH / SOUTH), concentrated vs split effort,
immediate assault vs fix-then-strike, phase end conditions based on battle state rather than fixed turn
counts, how the RED HQ is protected. {extra}

Every plan MUST follow the output contract in the system prompt exactly: same top-level keys as the example,
only tasks / areas / triggers / conditions that the packet's vocabulary allows, no unit ids anywhere.
(Victory itself is automatic when the BLUE HQ falls: there is NO trigger like ENEMY_HQ_DESTROYED.)
Goal: destroy the BLUE HQ; losing the RED HQ loses the battle.

Reply with ONLY one JSON object (no markdown fences, do not use any tools):
{{"candidates": [{{"name": "<short name>", "plan": <complete plan object>}}, ...]}}

KEY FACTS read from the packet (trust these over any assumption): {facts}

=== (1) SYSTEM PROMPT ===
{system}

=== (2) PACKET ===
{packet}

=== (3) VALID EXAMPLE PLAN ===
{example}
"""


def ask(model: str, variant: str, prompt: str, workdir: Path):
    pf = workdir / "ask.md"
    pf.write_text(prompt, encoding="utf-8")
    # the message must precede -f (an array flag that would swallow it); json events give token usage
    out = subprocess.run(["opencode", "run", "Follow the instructions in the attached file ask.md exactly.",
                          "--pure", "-m", model] + (["--variant", variant] if variant else []) + ["--format", "json", "--dir", str(workdir),
                          "-f", str(pf)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600, shell=True)
    text, usage = [], {}
    for line in out.stdout.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        part = e.get("part") or {}
        if part.get("type") == "text":
            text.append(str(part.get("text", "")))
        if e.get("type") == "step_finish":
            usage = part.get("tokens") or e.get("tokens") or usage
    return "".join(text), usage, out.stderr[-2000:]


def _jstr(text: str, key: str, start: int = 0, end: int | None = None) -> str:
    m = re.compile(r'"%s"\s*:\s*"((?:[^"\\]|\\.)*)"' % key).search(text, start, end if end is not None else len(text))
    return json.loads('"%s"' % m.group(1)) if m else ""


def extract(text: str):
    """Full JSON first; else recover candidate by candidate (the model tends to emit one stray '}' per plan)."""
    text = re.sub(r"\[[0-9;]*m", "", text)
    i = text.find("{")
    if i < 0:
        return None
    try:
        doc = json.loads(text[i:text.rfind("}") + 1])
        if isinstance(doc, dict) and isinstance(doc.get("candidates"), list):
            return doc
    except ValueError:
        pass
    dec = json.JSONDecoder()
    cands, prev = [], 0
    for m in re.finditer(r'"plan"\s*:\s*\{', text):
        try:
            plan, _end = dec.raw_decode(text, m.end() - 1)
        except ValueError:
            continue
        head = text.rfind('"name"', prev, m.start())
        seg_start = head if head >= 0 else prev
        cands.append({"name": _jstr(text, "name", seg_start, m.start()),
                      "rationale": _jstr(text, "rationale", seg_start, m.start()),
                      "expected_risks": _jstr(text, "expected_risks", seg_start, m.start()), "plan": plan})
        prev = m.end()
    return {"situation_analysis": _jstr(text, "situation_analysis"), "candidates": cands} if cands else None


def reparse(raw_dir: Path, out: Path, model: str, variant: str):
    rows = []
    for f in sorted(raw_dir.glob("call_*.txt")):
        doc = extract(f.read_text(encoding="utf-8").split("\n\n--- stderr ---")[0])
        for cand in (doc or {}).get("candidates", []):
            rows.append({"id": "C%02d" % (len(rows) + 1), "model": model, "variant": variant, "source": f.name,
                         "name": cand.get("name", ""), "rationale": cand.get("rationale", ""),
                         "expected_risks": cand.get("expected_risks", ""),
                         "situation_analysis": (doc or {}).get("situation_analysis", ""), "plan": cand["plan"]})
    out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    print("[GEN] reparsed %d candidates from %s" % (len(rows), raw_dir))


def facts_of(packet_text: str) -> str:
    pk = json.loads(packet_text)
    cs = pk.get("compact_state") or {}
    bits = []
    for u in cs.get("friendly_units") or []:
        if str(u.get("class", "")).upper() == "HQ":
            bits.append("RED HQ %s at (%s,%s) region %s" % (u.get("unit_id"), u.get("q"), u.get("r"), u.get("region")))
    for e in cs.get("known_enemy_units") or []:
        if str(e.get("class", "")).upper() == "HQ":
            bits.append("BLUE HQ %s at (%s,%s) region %s, est %s" % (e.get("unit_id"), e.get("q"), e.get("r"), e.get("region"), e.get("troop_estimate")))
    bits.append(
        "GEOGRAPHY (how mission areas are executed): mission areas are compass sectors of the whole map, NOT the "
        "unit 'region' tags. The lower layer converts them relative to the RED HQ: WEST = the western third of the "
        "map, the BLUE side, where the BLUE HQ actually lies -> executed as FORWARD (toward the enemy); EAST = the "
        "eastern third, RED's own rear where the RED HQ sits -> executed as BACK (away from the enemy, almost never "
        "useful for attack); NORTH / SOUTH = the flanks (left / right of the RED HQ-to-map-center axis); CENTER = "
        "the central axis. Unit 'region' tags only use NORTH/CENTER/SOUTH bands, which is why the BLUE HQ is "
        "tagged CENTER even though it sits in the WEST sector. To strike the BLUE HQ, use task ATTACK with "
        "vs \"HQ\" and an area that leads to it (WEST, or CENTER / a flank for the approach)")
    return "; ".join(bits)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--variant", default="")
    ap.add_argument("--calls", type=int, default=3)
    ap.add_argument("--per-call", type=int, default=3)
    ap.add_argument("--reparse", action="store_true", help="rebuild --out from saved gen_raw responses only")
    a = ap.parse_args()
    if a.reparse:
        reparse(Path(a.out).parent / "gen_raw", Path(a.out), a.model, a.variant)
        return
    st = json.loads(Path(a.state).read_text(encoding="utf-8"))
    system = next(m["content"] for m in st["messages"] if m["role"] == "system")
    packet = next(m["content"] for m in st["messages"] if m["role"] == "user")
    out = Path(a.out)
    rows = [json.loads(l) for l in out.read_text(encoding="utf-8").splitlines() if l.strip()] if out.exists() else []
    raw_dir = out.parent / "gen_raw"
    raw_dir.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        for c in range(a.calls):
            extra = ""
            if rows:
                extra = ("Already proposed (do NOT repeat these): "
                         + "; ".join("%s: %s" % (r["name"], r["rationale"][:160]) for r in rows[-12:]))
            t0 = time.time()
            prompt = ASK.format(n=a.per_call, extra=extra, system=system, packet=packet, facts=facts_of(packet),
                                example=st["example_plan"])
            text, usage, err = "", {}, ""
            for attempt in range(2):  # opencode occasionally hangs: 10 min cap per call, one retry
                try:
                    text, usage, err = ask(a.model, a.variant, prompt, Path(td))
                    break
                except subprocess.TimeoutExpired:
                    print("[GEN] call %d attempt %d timed out" % (c + 1, attempt + 1), flush=True)
            stamp = time.strftime("%Y%m%d_%H%M%S")
            (raw_dir / ("call_%s.txt" % stamp)).write_text(text + "\n\n--- stderr ---\n" + err, encoding="utf-8")
            doc = extract(text)
            n = 0
            if doc:
                with open(out, "a", encoding="utf-8") as f:
                    for cand in doc["candidates"]:
                        if not isinstance(cand, dict) or not isinstance(cand.get("plan"), dict):
                            continue
                        row = {"id": "C%02d" % (len(rows) + 1), "model": a.model, "variant": a.variant,
                               "name": str(cand.get("name", "")), "rationale": str(cand.get("rationale", "")),
                               "expected_risks": str(cand.get("expected_risks", "")),
                               "situation_analysis": str(doc.get("situation_analysis", "")),
                               "usage": usage, "plan": cand["plan"]}
                        f.write(json.dumps(row, ensure_ascii=False) + "\n")
                        rows.append(row)
                        n += 1
            print("[GEN] call %d: %d candidates in %.0fs usage=%s" % (c + 1, n, time.time() - t0, usage), flush=True)
    print("[GEN] total candidates:", len(rows))


if __name__ == "__main__":
    main()
