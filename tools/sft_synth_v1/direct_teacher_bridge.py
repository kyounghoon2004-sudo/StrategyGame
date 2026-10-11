"""File transport for a native direct teacher. Contains no decision policy.

Only the exact game-owned messages are delivered; hidden audit state stays in
the collector. A fresh native agent owns one resident game conversation.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path
from .astra_runner import install
from . import campaign, validate
from .analyze import OUT

NAME = 'native_direct_teacher'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def install_teacher(directory: Path, replay=False):
    install()
    directory = directory.resolve()
    directory.relative_to(OUT.resolve())
    directory.mkdir(parents=True, exist_ok=True)
    old_evaluate, old_hash = campaign.evaluate, campaign.policy_sha

    def evaluate(messages, name, memory):
        if name != NAME:
            return old_evaluate(messages, name, memory)
        latest = json.loads(next(m['content'] for m in reversed(messages) if m['role'] == 'user'))
        turn = int(latest['turn'])
        request = directory / f'request_t{turn:03d}.json'
        reply = directory / f'reply_t{turn:03d}.json'
        payload = json.dumps({'messages': messages}, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        if request.exists():
            if request.read_bytes() != payload:
                raise ValueError('Resident request mismatch; do not reset or mix games')
        elif replay:
            raise ValueError('Missing played teacher request')
        else:
            temporary = request.with_suffix('.tmp')
            temporary.write_bytes(payload)
            temporary.replace(request)
        deadline = time.monotonic() + (0 if replay else 300)
        while True:
            if reply.exists():
                received = reply.read_bytes()
                try:
                    answer = json.loads(received.decode('utf-8-sig'))
                    if not isinstance(answer.get('orders'), dict):
                        raise ValueError('Teacher reply requires orders object')
                    if len(answer.get('plan', '')) > 300:
                        raise ValueError('Teacher plan exceeds game limit')
                    if turn == 1 and not answer.get('plan'):
                        raise ValueError('Teacher opening requires plan')
                    provenance = json.loads((directory / 'teacher_provenance.json').read_text(encoding='utf-8'))
                    return answer, {'stage': 'direct_teacher', 'turn': turn,
                        'request_sha256': digest(payload), 'reply_sha256': digest(received),
                        'receipt': str(reply), 'model': provenance['model'], 'reasoning': provenance['reasoning']}
                except json.JSONDecodeError:
                    pass  # Final replies should be atomically renamed by the teacher.
            if time.monotonic() >= deadline:
                raise TimeoutError('No complete native teacher receipt; never substitute a policy')
            time.sleep(.2)

    def source_hash(name):
        if name != NAME:
            return old_hash(name)
        return digest(Path(__file__).read_bytes() + (directory / 'teacher_provenance.json').read_bytes())

    campaign.evaluate, campaign.policy_sha = evaluate, source_hash
    validate.evaluate, validate.policy_sha = evaluate, source_hash


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument('--manual-dir', required=True)
    ap.add_argument('--audit')
    args, remaining = ap.parse_known_args()
    install_teacher(Path(args.manual_dir), replay=bool(args.audit))
    if args.audit:
        rows = validate.audit(args.audit)
        (OUT / args.audit / 'validation.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({'games': len(rows), 'passed': sum(r['audit_pass'] for r in rows),
            'wins': sum(r['verified_win'] for r in rows), 'errors': [r['errors'] for r in rows if r['errors']]}))
    else:
        sys.argv = [sys.argv[0], *remaining]
        campaign.main()


if __name__ == '__main__':
    main()
