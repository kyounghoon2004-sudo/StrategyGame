"""Isolated integration of Astra-authored policies with existing real-Godot runner.

The adapter does not author orders or rewrite conversations. Historical generators
remain byte-identical. Use --audit STAGE for independent replay/legality checks.
"""
from __future__ import annotations
import hashlib
import json
import sys
import importlib
from pathlib import Path
from . import campaign
from .analyze import ROOT, OUT


def install():
    from .astra_v1 import policy
    policies = {name: policy for name in policy.POLICIES}
    for version in ('astra_v2', 'astra_v3'):
        module_name = f'tools.sft_synth_v1.{version}.policy'
        try:
            module = importlib.import_module(module_name)
            if set(module.POLICIES) & set(policies):
                raise ValueError('Duplicate versioned policy name')
            policies.update({name: module for name in module.POLICIES})
        except ModuleNotFoundError as error:
            if error.name not in (module_name, f'tools.sft_synth_v1.{version}'):
                raise
    old_evaluate, old_hash = campaign.evaluate, campaign.policy_sha

    def evaluate(messages, name, memory):
        if name in policies:
            return policies[name].decide(messages, name, memory)
        return old_evaluate(messages, name, memory)

    def source_hash(name):
        if name not in policies:
            return old_hash(name)
        files = getattr(policies[name], 'SOURCE_FILES', [
            'tools/sft_synth_v1/policy.py',
            'tools/sft_synth_v1/astra_v1/__init__.py',
            'tools/sft_synth_v1/astra_v1/policy.py',
        ])
        h = hashlib.sha256()
        for rel in sorted(files):
            h.update(rel.encode('utf-8') + b'\0')
            h.update((ROOT / rel).read_bytes())
        return h.hexdigest()

    campaign.evaluate, campaign.policy_sha = evaluate, source_hash
    from . import validate
    validate.evaluate, validate.policy_sha = evaluate, source_hash
    return policy


def main():
    policy = install()
    if len(sys.argv) > 1 and sys.argv[1] == '--audit':
        from .validate import audit
        stage = sys.argv[2]
        rows = audit(stage)
        (OUT / stage / 'validation.json').write_text(
            json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({'games': len(rows), 'passed': sum(r['audit_pass'] for r in rows),
            'wins': sum(r['verified_win'] for r in rows),
            'errors': [(r['game'], r['errors'][:5]) for r in rows if r['errors']]}))
    else:
        campaign.main()


if __name__ == '__main__':
    main()
