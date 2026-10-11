"""CLOUD BRAIN (2026-10-04): a strong cloud model writes the live opening plan / strategic replans in place of
the small Brain, so we can see whether the fixed Hands can beat GX at all and collect plans that win.

It gets everything the Brain gets (system prompt = the output contract, packet = the battle state; replans also
carry replan_context: previous plan, its progress, what changed) plus a geography note, and full freedom in how
it thinks and plans. Only the output must stay the executable contract (the Hands are fixed): one plan object.
"""
from __future__ import annotations

import contextlib
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

from tools.plan_search.gen_candidates import facts_of

MODEL = "opencode-go/deepseek-v4.1-flash"

ASK = """You are the commander ("Brain") of the RED army in a hex wargame. Think as long and as deeply as you
want; winning matters, not speed. Below are (1) your exact instructions and output contract, and (2) the battle
packet with the current state{replan_note}.

How execution works (fixed, you cannot change it): you assign missions; a lower layer allocates units to
missions and moves/attacks; units only attack under ATTACK tasks; at most 3 missions per phase are executed.
KEY FACTS: {facts}

Any strategy is allowed: choose axes, concentration, timing, phase structure and phase end conditions freely.
The output must follow the contract in (1) exactly (only allowed tasks / areas / triggers, no unit ids), because
it is executed as-is. Victory is automatic when the BLUE HQ falls (there is no ENEMY_HQ_DESTROYED trigger).

Reply with ONLY the plan JSON object (no markdown fences, no prose). Do not use any tools.

=== (1) INSTRUCTIONS AND OUTPUT CONTRACT ===
{system}

=== (2) PACKET ===
{packet}
"""


## Work dirs for opencode runs: outside the user's home, whose AGENTS.md (an unrelated agent protocol) opencode
## would otherwise load into the cloud's context.
RUN_TMP = Path(r"D:\StrategyAI\cache\opencode_runs")
## opencode caps a reply (thinking + answer) at 32000 tokens by default; at max effort the thinking alone reached it
## in about half of the opening calls, leaving no answer.
OUTPUT_TOKEN_MAX = "128000"


## opencode reads an attached file only up to about 50 KB (a longer one lost its end, where the current state is), so a
## longer prompt goes in as several files of at most this many characters, split at line ends.
ATTACH_MAX = 40000


def _parts(prompt: str) -> list:
    parts, cur = [], ""
    for line in prompt.splitlines(keepends=True):
        if cur and len(cur) + len(line) > ATTACH_MAX:
            parts.append(cur)
            cur = ""
        cur += line
    return parts + [cur]


def _run(model: str, variant: str, prompt: str, timeout_s: int, workdir: str = ""):
    """-> (answer text, token usage, thinking text, session id). The thinking is the model's reasoning parts, kept
    for SFT. workdir = that game's fixed directory (opencode puts it in its system prompt, so it keeps the prefix).
    stdin is closed: with an open stdin, opencode waits for it and never answers."""
    if model.startswith("agy/"):
        return _run_agy(model[4:], variant, prompt, timeout_s, workdir)
    RUN_TMP.mkdir(parents=True, exist_ok=True)
    if workdir:
        Path(workdir).mkdir(parents=True, exist_ok=True)
    with (contextlib.nullcontext(workdir) if workdir else tempfile.TemporaryDirectory(dir=RUN_TMP)) as td:
        for old in Path(td).glob("ask*.md"):
            old.unlink()
        parts = _parts(prompt)
        files = []
        for i, part in enumerate(parts, 1):
            pf = Path(td) / ("ask.md" if len(parts) == 1 else "ask_%d.md" % i)
            pf.write_text(part, encoding="utf-8")
            files.append(pf)
        msg = ("Follow the instructions in the attached file ask.md exactly." if len(files) == 1 else
               "The attached files ask_1.md to ask_%d.md are one document split in parts; read them in order, then "
               "follow its instructions exactly." % len(files))
        cmd = ["opencode", "run", msg, "--pure", "-m", model]
        if variant:
            cmd += ["--variant", variant]
        cmd += ["--format", "json", "--thinking", "--dir", td]
        for pf in files:
            cmd += ["-f", str(pf)]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                                text=True, encoding="utf-8", errors="replace", shell=True,
                                env=dict(os.environ, OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=OUTPUT_TOKEN_MAX))
        try:
            stdout, _ = proc.communicate(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            # shell=True: killing the shell alone leaves opencode running and holding the pipes; kill the whole tree
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
            try:
                proc.communicate(timeout=15)
            except Exception:  # noqa: BLE001
                pass
            raise
    text, usage, thinking, sid = [], {}, [], ""
    for line in stdout.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        sid = sid or str(e.get("sessionID") or "")
        part = e.get("part") or {}
        if part.get("type") == "text":
            text.append(str(part.get("text", "")))
        elif part.get("type") == "reasoning" and part.get("text"):
            thinking.append(str(part.get("text", "")))
        if e.get("type") == "step_finish":
            usage = part.get("tokens") or usage
    return "".join(text), usage, "\n".join(thinking), sid


AGY_RUN_TMP = Path(r"D:\StrategyAI\cache\agy_runs")


def _run_agy(model: str, effort: str, prompt: str, timeout_s: int, workdir: str = ""):
    """Same contract as _run, through the agy CLI (e.g. model "gemini-3.8-flash-low"). The prompt goes in on stdin
    as one stream-json user message (a 30k-char packet does not fit a Windows command line)."""
    wd = Path(workdir.replace(str(RUN_TMP), str(AGY_RUN_TMP))) if workdir else AGY_RUN_TMP / "default"
    wd.mkdir(parents=True, exist_ok=True)
    cmd = ["agy", "--input-format", "stream-json", "--output-format", "stream-json", "--model", model, "--print="]
    if effort:
        cmd += ["--effort", effort]
    msg = json.dumps({"event": "user", "message": {"role": "user", "content": prompt}}, ensure_ascii=False) + "\n"
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            encoding="utf-8", errors="replace", cwd=str(wd))
    try:
        stdout, _ = proc.communicate(msg, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
        try:
            proc.communicate(timeout=15)
        except Exception:  # noqa: BLE001
            pass
        raise
    text, usage, thinking, sid = "", {}, [], ""
    for line in stdout.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        su = e.get("step_update") or {}
        for k in ("thinking_delta", "thought_delta", "reasoning_delta"):
            if su.get(k):
                thinking.append(str(su[k]))
        if e.get("event") == "result":
            r = e.get("result") or {}
            text, usage, sid = str(r.get("response") or ""), dict(r.get("usage") or {}), str(r.get("conversation_id") or "")
        elif e.get("event") == "init":
            sid = str((e.get("init") or {}).get("conversation_id") or sid)
    return text, usage, "".join(thinking), sid


def fmt_packet(packet: str) -> str:
    """One unit per line. The attached file is read with a 2000-character line limit, so a one-line JSON packet
    reached the cloud cut short (it then decided on a partial state)."""
    try:
        d = json.loads(packet)
    except ValueError:
        return packet
    if not isinstance(d, dict):
        return packet
    lines, keys = ["{"], list(d)
    for i, k in enumerate(keys):
        v, tail = d[k], ("," if i < len(keys) - 1 else "")
        if isinstance(v, list) and v and all(isinstance(x, (dict, str)) for x in v):
            lines.append(json.dumps(k) + ": [")
            lines += ["  " + json.dumps(x, ensure_ascii=False) + ("," if j < len(v) - 1 else "") for j, x in enumerate(v)]
            lines.append("]" + tail)
        else:
            lines.append(json.dumps(k) + ": " + json.dumps(v, ensure_ascii=False) + tail)
    lines.append("}")
    if max(len(x) for x in lines) > 1900:
        return json.dumps(d, ensure_ascii=False, indent=1)
    return "\n".join(lines)


def extract_plan(text: str):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    dec = json.JSONDecoder()
    for m in re.finditer(r"\{", text):
        try:
            doc, _ = dec.raw_decode(text, m.start())
        except ValueError:
            continue
        if isinstance(doc, dict) and isinstance(doc.get("phases"), list):
            return doc
    return None


def cloud_plan(messages: list, model: str = MODEL, variant: str = "", timeout_s: int = 840, tries: int = 2):
    """-> (plan_json_text or "", meta). meta keeps the raw replies and token usage for the dataset."""
    system = next((str(m.get("content", "")) for m in messages if m.get("role") == "system"), "")
    packet = next((str(m.get("content", "")) for m in reversed(messages) if m.get("role") == "user"), "")
    try:
        is_replan = "replan_context" in json.loads(packet)
    except ValueError:
        is_replan = False
    prompt = ASK.format(system=system, packet=packet, facts=facts_of(packet),
                        replan_note=(" (this is a MID-BATTLE REPLAN: see replan_context in the packet)" if is_replan else ""))
    meta = {"model": model, "variant": variant, "replan": is_replan, "attempts": []}
    for t in range(tries):
        t0 = time.time()
        try:
            text, usage, thinking, _ = _run(model, variant, prompt, timeout_s // tries)
        except subprocess.TimeoutExpired:
            meta["attempts"].append({"timeout": True, "s": round(time.time() - t0)})
            continue
        plan = extract_plan(text)
        meta["attempts"].append({"s": round(time.time() - t0), "usage": usage, "raw": text, "thinking": thinking,
                                 "parsed": plan is not None})
        if plan is not None:
            return json.dumps(plan, ensure_ascii=False), meta
    return "", meta


CMD_WRAP = """Think as long and as deeply as you want before answering; winning matters, not speed.
Read the instructions (system) and the battle state (user) below, then reply with ONLY the JSON object they ask
for (no markdown fences, no prose). Do not use any tools.

=== INSTRUCTIONS ===
{system}

=== BATTLE STATE ===
{packet}
"""


def extract_orders(text: str):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    dec = json.JSONDecoder()
    for m in re.finditer(r"\{", text):
        try:
            doc, _ = dec.raw_decode(text, m.start())
        except ValueError:
            continue
        if isinstance(doc, dict) and isinstance(doc.get("orders"), dict):
            return doc
    # A complete answer that only misses its closing brace(s) (seen from the local 9B without thinking).
    tail = text.rstrip()
    if tail.endswith("}") and not tail.endswith("}}}"):
        for extra in ("}", "}}"):
            doc = extract_orders(tail + extra) if not tail.endswith(extra * 3) else None
            if doc is not None:
                return doc
    return None


## Resident Brain (user decision 2026-10-06, applied 2026-10-07): the game holds one conversation per battle and sends
## it whole with every turn (system, first message = full state, then turn messages and the Brain's answers, answers
## only). A local server reads it as is; its prefix cache keeps everything already read. A cloud runner gets the same
## conversation as one transcript from a fixed per-game directory, so the prompt prefix repeats and the provider's cache
## serves it. (An opencode session is not used: it also keeps every earlier thinking, and a resident game reached about
## 90k tokens of context by turn 7 on 2026-10-08.)
TURN_HEAD = "=== TURN MESSAGE ==="
ANSWER_HEAD = "=== YOUR ANSWER ==="
TURN_NOTE = "Reply to the last turn message with ONLY the JSON object, as before (no markdown fences, no prose). Do not use any tools."


def _transcript(messages: list) -> str:
    """The whole conversation as one prompt; every earlier turn keeps exactly the same text, so the prefix caches."""
    system = next((str(m.get("content", "")) for m in messages if m.get("role") == "system"), "")
    turns = [m for m in messages if m.get("role") in ("user", "assistant")]
    out = CMD_WRAP.format(system=system, packet=fmt_packet(str(turns[0].get("content", "")) if turns else ""))
    for m in turns[1:]:
        body = str(m.get("content", ""))  # turn messages one item per line (the file reader cuts lines at 2000 chars)
        out += "\n%s\n%s\n" % ((ANSWER_HEAD, body) if m.get("role") == "assistant" else (TURN_HEAD, fmt_packet(body)))
    return out + ("\n" + TURN_NOTE if len(turns) > 1 else "")


_PROVIDER_PREF: dict = {}


def cloud_command(messages: list, model: str = MODEL, variant: str = "", timeout_s: int = 1800,
                  session: dict | None = None, workdir: str = "", pass_on_fail: bool = False):
    """COMMANDER: the cloud model's answer to the game's conversation -> (json text or "", meta).
    session (one dict per game, kept by the caller): "dir" = the game's fixed run directory (a stable prompt prefix).
    timeout_s is the whole budget of the request; an unparsable answer is retried while at least 30 s remain.
    "a|b|c" = the same model through several providers: stay on the one that last worked, move on when it times out,
    errors or answers nothing usable. pass_on_fail (data collection): if no usable answer arrives in time, the Brain
    passes this turn ({"orders": {}, "skipped": why}: every order stands) instead of failing the game."""
    sess = session if session is not None else {}
    deadline = time.time() + timeout_s
    meta = {"model": model, "variant": variant, "budget_s": timeout_s, "attempts": []}
    providers = model.split("|")
    cap = timeout_s // len(providers) if len(providers) > 1 else timeout_s
    reason = "no answer"
    while time.time() < deadline - 30 or not meta["attempts"]:
        t0 = time.time()
        idx = _PROVIDER_PREF.get(model, 0) % len(providers)
        prov = providers[idx]
        prompt = _transcript(messages)
        try:
            text, usage, thinking, _ = _run(prov, variant, prompt, max(30, min(cap, int(deadline - t0))),
                                            workdir=sess.get("dir", "") or workdir)
        except Exception as e:  # time-out or provider error: try the next provider while time remains
            meta["attempts"].append({"timeout": isinstance(e, subprocess.TimeoutExpired), "error": str(e)[:200],
                                     "provider": prov, "s": round(time.time() - t0)})
            reason = "time limit %ds" % timeout_s
            _PROVIDER_PREF[model] = idx + 1
            if len(providers) == 1:
                break
            continue
        doc = extract_orders(text)
        meta["attempts"].append({"s": round(time.time() - t0), "usage": usage, "raw": text, "thinking": thinking,
                                 "parsed": doc is not None, "provider": prov, "prompt_bytes": len(prompt.encode("utf-8"))})
        if doc is not None:
            return json.dumps(doc, ensure_ascii=False), meta
        reason = "unusable answer"
        if len(providers) > 1:
            _PROVIDER_PREF[model] = idx + 1
    if not pass_on_fail:
        return "", meta
    meta["skipped"] = reason
    return json.dumps({"orders": {}, "skipped": reason}, ensure_ascii=False), meta


def _post_chat(url: str, body: dict, timeout_s: int) -> dict:
    import urllib.request
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s) as r:
        return json.loads(r.read())


def local_command(messages: list, url: str = "http://127.0.0.1:8000/v1/chat/completions", model: str = "q38",
                  max_tokens: int = 12000, temperature: float = 0.6, timeout_s: int = 1800, tries: int = 2,
                  think_budget: int = 0, answer_tokens: int = 1500, no_think: bool = False,
                  top_k: int = 0, presence_penalty: float = 0.0, reasoning_effort: str = ""):
    """COMMANDER v1 on a local vLLM server (OpenAI API, reasoning parsed out by vLLM) -> (json text or "", meta).

    think_budget > 0 (budget forcing): think at most that many tokens; if the thinking is cut, close it
    ("</think>") and let the model write the answer as a continuation. meta["completion"] keeps the exact
    assistant text (thinking + answer) of the accepted attempt for RL."""
    meta = {"model": model, "url": url, "think_budget": think_budget, "attempts": []}
    base = {"model": model, "temperature": temperature, "top_p": 0.95}
    if top_k > 0:
        base["top_k"] = top_k
    if presence_penalty:
        base["presence_penalty"] = presence_penalty  # Qwen guidance against repetition loops in thinking
    if reasoning_effort:  # chat-template effort level (Qwen3.8: low / medium / xhigh): Ollama reads the top-level
        base["reasoning_effort"] = reasoning_effort  # field, vLLM hands chat_template_kwargs to the template
        base["chat_template_kwargs"] = {**base.get("chat_template_kwargs", {}), "reasoning_effort": reasoning_effort}
    if no_think:  # thinking OFF (SFT student trained without reasoning)
        base["chat_template_kwargs"] = {"enable_thinking": False}
        think_budget = 0
        max_tokens = min(max_tokens, answer_tokens)
    for _ in range(tries):
        t0 = time.time()
        try:
            resp = _post_chat(url, {**base, "messages": messages,
                                    "max_tokens": think_budget if think_budget > 0 else max_tokens}, timeout_s)
            ch = (resp.get("choices") or [{}])[0]
            msg = ch.get("message") or {}
            text = str(msg.get("content") or "")
            reasoning = str(msg.get("reasoning_content") or msg.get("reasoning") or "")
            usage, finish, forced = dict(resp.get("usage") or {}), ch.get("finish_reason"), False
            if think_budget > 0 and finish == "length":
                forced = True
                # The answer is started for it: right after a forced "</think>" the model sometimes ended at once
                # (an empty answer, 3 of the first 74 resident turns on 2026-10-08).
                if not text.strip():
                    text = '{"orders": '
                prefix = "<think>\n" + reasoning.strip() + "\n</think>\n\n" + text
                r2 = _post_chat(url, {**base, "messages": messages + [{"role": "assistant", "content": prefix}],
                                      "max_tokens": answer_tokens, "add_generation_prompt": False,
                                      "continue_final_message": True}, timeout_s)
                c2 = (r2.get("choices") or [{}])[0]
                m2 = c2.get("message") or {}
                text = text + str(m2.get("content") or "") + str(m2.get("reasoning_content") or m2.get("reasoning") or "")
                finish = c2.get("finish_reason")
                usage["completion_tokens"] = int(usage.get("completion_tokens") or 0) + \
                    int((r2.get("usage") or {}).get("completion_tokens") or 0)
        except Exception as e:  # noqa: BLE001
            meta["attempts"].append({"error": str(e)[:300], "s": round(time.time() - t0, 1)})
            continue
        doc = extract_orders(text)
        meta["attempts"].append({"s": round(time.time() - t0, 1), "usage": usage, "finish": finish, "forced": forced,
                                 "raw": text, "reasoning": reasoning, "parsed": doc is not None})
        if doc is not None:
            meta["completion"] = "<think>\n" + reasoning.strip() + "\n</think>\n\n" + text.strip()
            return json.dumps(doc, ensure_ascii=False), meta
    return "", meta
