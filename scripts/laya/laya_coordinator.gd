class_name LayaCoordinator
extends RefCounted

## LIBERATION V1 — dynamic group-plan candidate generator (Godot side).
##
## Pure + deterministic: same inputs -> same candidates, byte-identical.
## Builds group-plan skeletons ONLY from current legality + known entities:
## per-unit ATTACK targets (legal now), MOVE regions (reachable now),
## HOLD (legal now). NO tactical preference anywhere: ordering is canonical
## (kind rank, then target id), overflow is dropped in that order, and the
## Laya ranking call decides which approach is good.
##
## A skeleton binds WHAT KIND of action each unit attempts (attack WHICH
## target / reposition / hold); the exact hex is still chosen per-unit by
## Laya from fresh legal sets. Candidates are descriptive, never orders.

const MAX_SKELETONS_PER_UNIT := 8
const MAX_GROUP_CANDIDATES := 12

const KIND_RANK := {"ATTACK": 0, "ASSAULT": 1, "HOLD": 2, "REPOSITION": 3, "MOVE": 4}


## Per-unit skeletons from its CURRENT legal pool. region_of: Callable(dest
## [q,r]) -> region name, or an invalid Callable to skip region variants.
static func skeletons_for_unit(uid: String, pool_cands: Array, region_of: Callable = Callable()) -> Array:
	var skels: Array = []
	var seen := {}
	for c_val in pool_cands:
		if not c_val is Dictionary:
			continue
		var c: Dictionary = c_val
		if str(c.get("unit_id", "")) != uid:
			continue
		var t := str(c.get("action_type", ""))
		if t == "ATTACK":
			var tid := str(c.get("target_id", ""))
			if tid.is_empty() or seen.has("A|" + tid):
				continue
			seen["A|" + tid] = true
			skels.append({"unit": uid, "kind": "ATTACK", "target": tid,
				"target_class": str(c.get("target_class", "?")),
				"note": "attack %s" % tid})
		elif t == "ASSAULT":
			var sid := str(c.get("stronghold_id", ""))
			var gid := str(c.get("garrison_target_id", ""))
			var key := "S|%s|%s" % [sid, gid]
			if sid.is_empty() or seen.has(key):
				continue
			seen[key] = true
			skels.append({"unit": uid, "kind": "ASSAULT", "target": sid,
				"target_class": "STRONGHOLD",
				"note": "assault %s" % sid if gid.is_empty() else "assault %s via %s" % [sid, gid]})
	skels.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("target", "")) < str(b.get("target", "")))
	var holds := false
	var moves: Array = []
	for c_val in pool_cands:
		if not c_val is Dictionary:
			continue
		var c: Dictionary = c_val
		if str(c.get("unit_id", "")) != uid:
			continue
		var t := str(c.get("action_type", ""))
		if t in ["WAIT", "REST", "FORTIFY", "ENTER_GARRISON", "DISMANTLE"]:
			holds = true
		elif t == "MOVE":
			moves.append(c)
	if holds:
		skels.append({"unit": uid, "kind": "HOLD", "target": "",
			"target_class": "", "note": "hold position"})
	if not moves.is_empty():
		if region_of.is_valid():
			var by_region := {}
			for mv in moves:
				var d: Array = (mv as Dictionary).get("destination", [])
				if d.size() != 2:
					continue
				var r := str(region_of.call([int(d[0]), int(d[1])]))
				if r.is_empty():
					continue
				by_region[r] = int(by_region.get(r, 0)) + 1
			var regions: Array = by_region.keys()
			regions.sort()
			for r in regions:
				skels.append({"unit": uid, "kind": "MOVE", "target": str(r),
					"target_class": "", "note": "reposition to %s (%d hexes)" % [str(r), int(by_region[r])]})
		else:
			skels.append({"unit": uid, "kind": "REPOSITION", "target": "",
				"target_class": "", "note": "reposition (%d legal hexes)" % moves.size()})
	skels.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := int(KIND_RANK.get(str(a.get("kind", "")), 9))
		var rb := int(KIND_RANK.get(str(b.get("kind", "")), 9))
		if ra != rb:
			return ra < rb
		return str(a.get("target", "")) < str(b.get("target", "")))
	return skels.slice(0, MAX_SKELETONS_PER_UNIT)


## Group candidates = cartesian over units' skeletons, deduped by tactical
## shape (sorted kind+target multiset), capped in canonical order.
## pools: {unit_id: [candidate dicts]}. Returns [{candidate_id, option_text,
## assignments {uid: {kind, target, note}}}].
static func generate(mission_id: String, group_units: Array, pools: Dictionary,
		region_of: Callable = Callable()) -> Array:
	var units: Array = []
	for u in group_units:
		var uid := str(u).strip_edges().to_upper()
		if not uid.is_empty() and not uid in units:
			units.append(uid)
	units.sort()
	if units.size() < 2:
		return []
	var per_unit: Array = []
	for uid in units:
		var sk := skeletons_for_unit(uid, pools.get(uid, []) as Array, region_of)
		if sk.is_empty():
			return [] # a unit with no skeleton voids group planning
		per_unit.append(sk)
	var combos: Array = [[]]
	for sk in per_unit:
		var next: Array = []
		for prefix in combos:
			for s in (sk as Array):
				next.append((prefix as Array) + [s])
				if next.size() >= 4096:
					break
			if next.size() >= 4096:
				break
		combos = next
	combos.sort_custom(func(a: Array, b: Array) -> bool:
		return _shape_key(a) < _shape_key(b))
	var out: Array = []
	var seen := {}
	var n := 0
	for combo in combos:
		var key := _shape_key(combo as Array)
		if seen.has(key):
			continue # duplicated equivalent shape
		seen[key] = true
		n += 1
		var assigns := {}
		var parts: Array = []
		for s in (combo as Array):
			var sd: Dictionary = s
			assigns[str(sd.get("unit", ""))] = {"kind": str(sd.get("kind", "")),
				"target": str(sd.get("target", "")),
				"target_class": str(sd.get("target_class", "")),
				"note": str(sd.get("note", ""))}
			parts.append("%s:%s%s" % [str(sd.get("unit", "")), str(sd.get("kind", "")),
				(" " + str(sd.get("target", ""))) if not str(sd.get("target", "")).is_empty() else ""])
		out.append({"candidate_id": "G%d" % n, "mission_id": mission_id,
			"option_text": "; ".join(parts), "assignments": assigns})
		if out.size() >= MAX_GROUP_CANDIDATES:
			break
	return out


static func _shape_key(combo: Array) -> String:
	var parts: Array = []
	for s in combo:
		var sd: Dictionary = s
		parts.append("%s|%s|%s" % [str(sd.get("unit", "")), str(sd.get("kind", "")),
			str(sd.get("target", ""))])
	parts.sort()
	return "+".join(parts)
