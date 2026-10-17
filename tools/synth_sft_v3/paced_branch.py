"""Isolated candidate launcher forwarding an existing proxy polling CLI setting.

No production or branch source mutation. Use for the exact replay gate before
adopting any new pacing value in verified data batches. All branch arguments are
passed unchanged, except this launcher's explicit --manual-poll-s option.

python -m tools.synth_sft_v3.paced_branch branches.jsonl output_dir \
    --manual-poll-s 0.05 --windows 10 --slot 6 --proxy-port 8126 --brain-port 8136
"""
from __future__ import annotations
import subprocess
import sys
from pathlib import Path


def main():
    argv = sys.argv[1:]
    poll = 0.05
    if "--manual-poll-s" in argv:
        position = argv.index("--manual-poll-s")
        poll = float(argv[position + 1])
        del argv[position:position + 2]
    if poll <= 0:
        raise ValueError("manual polling must be positive")
    if len(argv) < 2:
        raise SystemExit("branches.jsonl and output_dir are required")
    out = Path(argv[1]).resolve()
    v3_root = Path(__file__).resolve().parents[2] / "artifacts" / "brain_pipeline_v1" / "synth_sft_v3"
    if not out.is_relative_to(v3_root):
        raise ValueError("This diagnostic launcher permits only V3 artifact output directories")
    original_popen = subprocess.Popen

    def owned_proxy_popen(args, *positional, **kwargs):
        command = list(args) if isinstance(args, (list, tuple)) else args
        if isinstance(command, list) and "tools.brain_review.teacher_proxy" in command and "--manual-dir" in command:
            capture = Path(command[command.index("--capture-dir") + 1]).resolve()
            if capture.is_relative_to(out):
                command += ["--manual-poll-s", str(poll)]
        return original_popen(command, *positional, **kwargs)

    subprocess.Popen = owned_proxy_popen
    try:
        from tools.synth_sft_v3 import branch
        sys.argv = ["paced_branch", *argv]
        branch.main()
    finally:
        subprocess.Popen = original_popen


if __name__ == "__main__":
    main()
