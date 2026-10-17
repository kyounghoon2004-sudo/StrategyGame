"""One-off generator: tools/cmd_rl/teacher_gx.py -> tools/synth_adv_v1/hybrid_gx.py (two proxies: FAST thinking-off, THINK with budget)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
s = (ROOT / "tools" / "cmd_rl" / "teacher_gx.py").read_text(encoding="utf-8")


def sub(old, new):
    global s
    assert old in s, old[:60]
    s = s.replace(old, new, 1)


sub('"""A local OpenAI-compatible model',
    '"""[hybrid variant of teacher_gx: FAST proxy thinking off + THINK proxy with a large budget; route with\n'
    'tools.synth_adv_v1.hybrid_shim]\nA local OpenAI-compatible model')
sub('    ap.add_argument("--out", default=',
    '    ap.add_argument("--think-port", type=int, default=8124)\n'
    '    ap.add_argument("--think-brain-port", type=int, default=8134)\n'
    '    ap.add_argument("--out", default=')
sub('    if not a.think:\n        extra.append("--local-no-think")',
    '    extra.append("--local-no-think")  # FAST proxy: thinking off (the THINK proxy is started below with a budget)')
sub('''    if not wait_port(a.proxy_port, token, 180):
        raise SystemExit("teacher proxy did not come up")''',
    '''    if not wait_port(a.proxy_port, token, 180):
        raise SystemExit("teacher proxy did not come up")
    capT = run / "captures_think"
    capT.mkdir(exist_ok=True)
    extraT = ["--local-url", a.url, "--local-model", a.model, "--local-answer-tokens", "2000",
              "--local-think-budget", str(a.think_budget), "--local-max-tokens", str(a.max_tokens),
              "--local-top-k", "0", "--local-presence-penalty", "0", "--local-pass"]
    proxyT = subprocess.Popen(
        [RV.PY, "-m", "tools.brain_review.teacher_proxy", "--session", token, "--capture-dir", str(capT),
         "--port", str(a.think_port), "--brain-port", str(a.think_brain_port), "--default-mode", "TEACHER", "--initial-stub"] + extraT,
        cwd=str(ROOT), stdout=open(capT / "proxy.log", "a"), stderr=subprocess.STDOUT)
    if not wait_port(a.think_port, token, 180):
        raise SystemExit("think proxy did not come up")''')
sub('            post(a.proxy_port, "/admin/tags", {win: tag})',
    '            post(a.proxy_port, "/admin/tags", {win: tag})\n            post(a.think_port, "/admin/tags", {win: tag})')
sub('        post(a.proxy_port, "/admin/shutdown", {})\n        proxy.wait(timeout=60)',
    '        post(a.proxy_port, "/admin/shutdown", {})\n        post(a.think_port, "/admin/shutdown", {})\n        proxy.wait(timeout=60)')
(ROOT / "tools" / "synth_adv_v1" / "hybrid_gx.py").write_text(s, encoding="utf-8")
print("hybrid_gx.py written,", len(s.splitlines()), "lines")
