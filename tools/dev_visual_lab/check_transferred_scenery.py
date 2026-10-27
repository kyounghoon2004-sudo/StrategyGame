#!/usr/bin/env python3
"""Check a transferred DEV scenery output tree without changing it."""
import argparse
import hashlib
import json
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('outputs', type=Path, help='Transferred outputs directory')
    args = parser.parse_args()
    inventory = Path(__file__).parent / 'scenery_scale_massif' / 'LOCAL_ASSET_INVENTORY.json'
    data = json.loads(inventory.read_text(encoding='utf-8'))
    root = args.outputs / 'scenery-scale-massif'
    missing, mismatches = [], []
    for item in data['files']:
        path = root / item['relative_path']
        if not path.is_file():
            missing.append(item['relative_path'])
        elif path.stat().st_size != item['bytes'] or sha256(path).lower() != item['sha256'].lower():
            mismatches.append(item['relative_path'])
    dependencies = [Path(item).name for item in data['additional_local_dependencies']]
    dependencies += ['all-ranges-world', 'river-shoreline', 'waterway-lab']
    missing_dirs = [name for name in dependencies if not (args.outputs / name).is_dir()]
    result = {'outputs': str(args.outputs.resolve()), 'inventory_entries': len(data['files']),
              'verified': len(data['files']) - len(missing) - len(mismatches),
              'missing': missing, 'mismatches': mismatches, 'missing_dependency_directories': missing_dirs,
              'note': 'Directory presence does not verify dependency contents or renderer behavior.'}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if missing or mismatches or missing_dirs else 0


if __name__ == '__main__':
    raise SystemExit(main())
