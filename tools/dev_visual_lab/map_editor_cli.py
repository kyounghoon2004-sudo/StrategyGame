#!/usr/bin/env python3
"""Read-only validation of StrategyGame DEV visual map JSON for people and agents."""
import argparse
import json
import os
import re
from pathlib import Path

BUILDINGS = {'building_small_house', 'building_medium_house', 'building_workshop',
             'building_granary', 'building_hall', 'building_gate', 'building_farm_granary'}
CASTLES = {f'castle_v{i}' for i in range(1, 5)}


def number_is_int(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and int(value) == value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('map', type=Path)
    parser.add_argument('--outputs', type=Path, default=os.environ.get('SG_VISUAL_OUTPUT_ROOT'))
    args = parser.parse_args()
    errors = []
    try:
        doc = json.loads(args.map.read_text(encoding='utf-8-sig'))
        if not isinstance(doc, dict): raise ValueError('document must be an object')
        if doc.get('schema_version') != 1: errors.append('unsupported schema_version')
        ident = doc.get('id')
        if not isinstance(ident, str) or not re.fullmatch(r'map_[a-z0-9_]{1,76}', ident): errors.append('invalid id')
        elif args.map.name != ident + '.json': errors.append('filename must equal id + .json')
        if not isinstance(doc.get('name'), str) or not doc['name'].strip() or len(doc['name']) > 100: errors.append('invalid name')
        radius = doc.get('radius')
        if not number_is_int(radius) or not 2 <= radius <= 40: errors.append('radius must be an integer between 2 and 40'); radius = 0
        if doc.get('hex_radius') != 18: errors.append('hex_radius must be 18')
        objects = doc.get('objects')
        if not isinstance(objects, list): raise ValueError('objects must be an array')
        mountains = None
        if args.outputs:
            output = Path(args.outputs)
            catalog = json.loads((output / 'scenery-scale-massif/massif25/catalog.json').read_text(encoding='utf-8-sig'))
            mountains = {v['id'] for v in catalog['catalog']}
        occupied = set()
        for i, item in enumerate(objects):
            if not isinstance(item, dict): errors.append(f'object {i}: must be an object'); continue
            kind, variant = item.get('kind'), item.get('variant')
            q, r, rotation = item.get('q'), item.get('r'), item.get('rotation', 0)
            if kind not in {'forest','mountain','castle','building'}: errors.append(f'object {i}: unknown kind')
            if not isinstance(variant,str) or not variant or len(variant)>80: errors.append(f'object {i}: invalid variant')
            elif kind == 'forest' and variant not in {'mixed','pine'}: errors.append(f'object {i}: unknown forest')
            elif kind == 'castle' and variant not in CASTLES: errors.append(f'object {i}: unknown castle')
            elif kind == 'building' and variant not in BUILDINGS: errors.append(f'object {i}: unknown building')
            elif kind == 'mountain' and mountains is not None and variant not in mountains: errors.append(f'object {i}: unknown mountain')
            if not number_is_int(q) or not number_is_int(r): errors.append(f'object {i}: coordinates must be integers')
            elif max(abs(q),abs(r),abs(q+r)) > radius: errors.append(f'object {i}: outside map')
            elif (q,r) in occupied: errors.append(f'object {i}: duplicate anchor')
            else: occupied.add((q,r))
            if not number_is_int(rotation) or not 0 <= rotation <= 5: errors.append(f'object {i}: rotation must be 0..5')
        if mountains is None: print('Note: pass --outputs to validate mountain IDs against the local catalog.')
        if errors:
            print('\n'.join(errors)); return 1
        print(f'PASS name={doc["name"]!r} radius={radius} objects={len(objects)}')
        return 0
    except (OSError, ValueError, KeyError, TypeError, OverflowError) as exc:
        print(f'INVALID: {exc}'); return 1


if __name__ == '__main__':
    raise SystemExit(main())
