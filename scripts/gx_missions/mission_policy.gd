extends RefCounted

## GX MISSIONS v1 — MissionPolicy: one data-driven policy per mission family (M1..M5) on top of the
## existing GX (same executor, same scoring core). Reads ONLY the side-authorized observation:
## mission block + read-only mission_state + friendly/visible enemy rows. Decides nothing about victory.
##
## evaluate(obs, rs, commit) -> mctx: per-unit objective targets (replace "enemy HQ" in the objective /
## pressure features), mission intents (added to the V2 intent set), family multipliers, HQ opportunity.
## candidate_bonus(c, mctx, own) -> additive mission terms for one candidate (all tiers).

const CfgCls = preload("res://scripts/gx_missions/mission_config.gd")
const RulesetViewCls = preload("res://scripts/utility_bot/utility_ruleset_view.gd")


static func _pt(u: Dictionary) -> Vector2i:
	return Vector2i(int(u.get("q", 0)), int(u.get("r", 0)))


static func _arr_pt(v: Variant) -> Vector2i:
	if v is Array and (v as Array).size() >= 2:
		return Vector2i(int(v[0]), int(v[1]))
	return Vector2i.ZERO


static func hexd(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), maxi(absi(a.y - b.y), absi((a.x + a.y) - (b.x + b.y))))


static func _cls(u: Dictionary) -> String:
	var n := str(u.get("class", "")).strip_edges().to_lower()
	return "spear" if n in ["spearman", "spearmen"] else n


static func _soldiers(u: Dictionary) -> float:
	if u.has("soldiers"):
		return maxf(0.0, float(u["soldiers"]))
	var raw := str(u.get("troop_estimate", ""))
	return float(raw.to_int()) if raw.is_valid_int() else 0.0


static func _centroid(units: Array) -> Dictionary:
	var sum := Vector2.ZERO
	var w := 0.0
	for u in units:
		var s := maxf(1.0, _soldiers(u))
		sum += Vector2(_pt(u)) * s
		w += s
	if w <= 0.0:
		return {"found": false, "point": Vector2i.ZERO}
	var c := sum / w
	return {"found": true, "point": Vector2i(roundi(c.x), roundi(c.y))}


## Point `dist` hexes from `from` toward `to` (axial lerp, rounded).
static func _toward(from: Vector2i, to: Vector2i, dist: int) -> Vector2i:
	var d := hexd(from, to)
	if d <= dist or d == 0:
		return to
	var t := float(dist) / float(d)
	return Vector2i(roundi(lerpf(from.x, to.x, t)), roundi(lerpf(from.y, to.y, t)))


static func _nearest(p: Vector2i, pts: Array) -> Vector2i:
	var best: Vector2i = pts[0]
	for q in pts:
		if hexd(p, q) < hexd(p, best):
			best = q
	return best


## Stable order by hex distance to p (ascending, or descending when far_first), then unit id.
static func _sorted_by_distance(units: Array, p: Vector2i, far_first: bool) -> Array:
	var rows: Array = []
	for u in units:
		var d := hexd(_pt(u), p)
		rows.append([-d if far_first else d, str(u["unit_id"]), u])
	rows.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	return rows.map(func(r): return r[2])


static func _eta(u: Dictionary, target: Vector2i, rs: Dictionary) -> int:
	var cls := _cls(u)
	var rng := RulesetViewCls.get_range(rs, cls)
	var march := RulesetViewCls.march_allowance(rs, cls)
	return int(ceil(float(maxi(0, hexd(_pt(u), target) - rng)) / float(maxi(1, march))))


static func evaluate(obs: Dictionary, rs: Dictionary, commit: float) -> Dictionary:
	var m: Dictionary = obs.get("mission", {})
	var ms: Dictionary = obs.get("mission_state", {})
	var fam := str(m.get("family", ""))
	if fam.is_empty():
		return {"on": false}
	var pol := CfgCls.section("policy")
	var side := str(obs.get("side", "")).to_lower()
	var foe := "blue" if side == "red" else "red"
	var role := str(m.get("role", "none"))
	var friends: Array = []
	var own_hq: Dictionary = {}
	for raw in obs.get("friendly_units", []):
		if raw is Dictionary and int((raw as Dictionary).get("soldiers", 0)) > 0 and not bool((raw as Dictionary).get("garrisoned", false)):
			if _cls(raw) == "hq":
				own_hq = raw
			else:
				friends.append(raw)
	var enemies: Array = []
	var enemy_hq: Dictionary = {}
	for raw in obs.get("known_enemy_units", []):
		if raw is Dictionary and str((raw as Dictionary).get("contact_state", "")) == "current_visible":
			if _cls(raw) == "hq":
				enemy_hq = raw
			else:
				enemies.append(raw)
	var own_c := _centroid(friends)
	var en_c := _centroid(enemies)
	var mctx := {"on": true, "family": fam, "role": role, "side": side,
		"targets": {}, "reserve": {}, "hold": {}, "leash": {}, "intents": [],
		"own_centroid": own_c["point"], "enemy_centroid": en_c["point"],
		"mult": (CfgCls.section("family_multipliers").get(fam, {}) as Dictionary),
		"garrison_wanted": false, "assault_mode": "", "fort_footprint": [],
		"enemy_near_collapse": false, "own_line": [], "own_cut": [], "enemy_line": [], "protectors": {},
		"site_hexes": [], "hq_target": null, "own_base_count": 0, "enemy_bases": [],
		"own_hq_point": _pt(own_hq) if not own_hq.is_empty() else null}
	# --- supply (public in the full-information mission_state) ---
	var sup: Dictionary = ms.get("supply", {})
	for h in ((sup.get(side, {}) as Dictionary).get("line", []) as Array):
		mctx["own_line"].append(_arr_pt(h))
	for h in ((sup.get(side, {}) as Dictionary).get("cut_hexes", []) as Array):
		mctx["own_cut"].append(_arr_pt(h))
	for h in ((sup.get(foe, {}) as Dictionary).get("line", []) as Array):
		mctx["enemy_line"].append(_arr_pt(h))
	for b in (ms.get("bases", []) as Array):
		if str(b.get("owner", "")) == side:
			mctx["own_base_count"] = int(mctx["own_base_count"]) + 1
		else:
			mctx["enemy_bases"].append(_arr_pt(b.get("hex", [])))
	var intents: Array = mctx["intents"]
	# --- family objective targets ---
	match fam:
		"M1":
			var village: Array = []
			for h in (m.get("village_hexes", []) as Array):
				village.append(_arr_pt(h))
			var vc := _centroid(village.map(func(p): return {"q": p.x, "r": p.y, "soldiers": 1}))["point"] as Vector2i
			if role == "attacker":
				for u in friends:
					mctx["targets"][str(u["unit_id"])] = _nearest(_pt(u), village)
					if _pt(u) in village:
						mctx["hold"][str(u["unit_id"])] = _pt(u)
				_add_intent(intents, "TAKE_AREA", vc, commit)
			else:
				# Threat = enemies weighted by strength and proximity to the village.
				var tsum := Vector2.ZERO
				var tw := 0.0
				for e in enemies:
					var w := _soldiers(e) / float(1 + hexd(_pt(e), vc))
					tsum += Vector2(_pt(e)) * w
					tw += w
				var block := vc
				if tw > 0.0:
					var threat := Vector2i(roundi(tsum.x / tw), roundi(tsum.y / tw))
					block = _toward(vc, threat, int(pol["m1_block_dist"]))
				var by_dist := _sorted_by_distance(friends, vc, false)
				for i in range(by_dist.size()):
					var uid := str(by_dist[i]["unit_id"])
					if i < int(pol["m1_reserve_units"]):
						mctx["reserve"][uid] = true
						mctx["targets"][uid] = vc
						mctx["hold"][uid] = vc
					else:
						mctx["targets"][uid] = block
				mctx["leash"] = {"center": vc, "radius": int(pol["m1_pursuit_leash"])}
				_add_intent(intents, "DEFEND_AREA", block, commit)
		"M2", "M5":
			var st: Dictionary = ms.get("stronghold", {})
			var fp: Array = []
			for h in (st.get("footprint", []) as Array):
				fp.append(_arr_pt(h))
			mctx["fort_footprint"] = fp
			if not fp.is_empty():
				var anchor: Vector2i = fp[0]
				var own_fort := str(st.get("owner", "")) == side
				if role == "defender":
					var threat_pt := anchor
					if bool(en_c["found"]):
						threat_pt = _nearest(en_c["point"], fp)
					for u in friends:
						mctx["targets"][str(u["unit_id"])] = threat_pt
					mctx["leash"] = {"center": anchor, "radius": int(pol["fort_threat_radius"])}
					mctx["garrison_wanted"] = own_fort and int(st.get("garrison", 0)) < 99
					_add_intent(intents, "HOLD_FORTRESS", threat_pt, commit)
				else:
					var breached := bool(st.get("breached", false))
					mctx["assault_mode"] = "breach" if breached else "wall"
					var home: Vector2i = _pt(own_hq) if not own_hq.is_empty() else (own_c["point"] as Vector2i)
					var reserve_pt := _toward(anchor, home, int(pol["fort_reserve_dist"]))
					var by_far := _sorted_by_distance(friends, anchor, true)
					for i in range(by_far.size()):
						var uid := str(by_far[i]["unit_id"])
						if not breached and i < int(pol["fort_reserve_units"]):
							mctx["reserve"][uid] = true
							mctx["targets"][uid] = reserve_pt
							mctx["hold"][uid] = reserve_pt
						else:
							mctx["targets"][uid] = anchor
					_add_intent(intents, "EXPLOIT_BREACH" if breached else "SIEGE_WALL", anchor, commit)
		"M3":
			var tgt: Vector2i = en_c["point"] if bool(en_c["found"]) else (_pt(enemy_hq) if not enemy_hq.is_empty() else own_c["point"])
			for u in friends:
				mctx["targets"][str(u["unit_id"])] = tgt
			var line := int((ms.get("collapse_line", {}) as Dictionary).get(foe, 0))
			var now := int(((ms.get("soldiers", {}) as Dictionary).get(foe, {}) as Dictionary).get("now", 1 << 30))
			mctx["enemy_near_collapse"] = float(now) <= float(line) * (1.0 + float(pol["m3_push_margin"]))
			_add_intent(intents, "FIELD_CONCENTRATE", tgt, commit)
		"M4":
			var sites: Array = []
			for row in (ms.get("sites", []) as Array):
				sites.append({"hex": _arr_pt(row.get("hex", [])), "owner": str(row.get("owner", "none"))})
			mctx["site_hexes"] = sites.map(func(s): return s["hex"])
			var hq_pt: Vector2i = _pt(own_hq) if not own_hq.is_empty() else (own_c["point"] as Vector2i)
			var free_sites: Array = sites.filter(func(s): return s["owner"] == "none").map(func(s): return s["hex"])
			var not_own: Array = sites.filter(func(s): return s["owner"] != side).map(func(s): return s["hex"])
			var foe_sites: Array = sites.filter(func(s): return s["owner"] == foe).map(func(s): return s["hex"])
			if not free_sites.is_empty():
				mctx["hq_target"] = _nearest(hq_pt, free_sites)
				_add_intent(intents, "BUILD_BASE", mctx["hq_target"], commit)
			var median_mp := RulesetViewCls.get_base_mp(rs, "infantry")
			for u in friends:
				var uid := str(u["unit_id"])
				var fast := RulesetViewCls.get_base_mp(rs, _cls(u)) > median_mp
				if fast and not (mctx["enemy_bases"] as Array).is_empty():
					mctx["targets"][uid] = _nearest(_pt(u), mctx["enemy_bases"])
				elif mctx["hq_target"] != null and not fast:
					mctx["targets"][uid] = mctx["hq_target"]
				elif not not_own.is_empty():
					mctx["targets"][uid] = _nearest(_pt(u), not_own)
				elif not sites.is_empty():
					mctx["targets"][uid] = _nearest(_pt(u), mctx["site_hexes"])
			if not foe_sites.is_empty():
				_add_intent(intents, "CONTEST_SITE", _nearest(own_c["point"], foe_sites), commit)
			if not (mctx["enemy_bases"] as Array).is_empty():
				_add_intent(intents, "RAID_BASE", _nearest(own_c["point"], mctx["enemy_bases"]), commit)
	# --- all families: protect own supply (cut_hexes always empty under the base-count rule) ---
	if not (mctx["own_cut"] as Array).is_empty():
		var cut_pt: Vector2i = mctx["own_cut"][0]
		var near := _sorted_by_distance(friends, cut_pt, false)
		for i in range(mini(int(pol["supply_protectors"]), near.size())):
			var uid := str(near[i]["unit_id"])
			mctx["protectors"][uid] = true
			mctx["targets"][uid] = cut_pt
		_add_intent(intents, "PROTECT_SUPPLY", cut_pt, commit)
	mctx["hq"] = hq_opportunity(own_hq, enemy_hq, friends, enemies, rs)
	if bool(mctx["hq"]["open"]):
		var cfg_i: Array = CfgCls.section("intents")["HQ_STRIKE"]
		intents.append({"type": "HQ_STRIKE", "locus": _pt(enemy_hq), "focus_target_id": str(enemy_hq.get("unit_id", "")),
			"score": float(cfg_i[0]) + float(cfg_i[1]) * float(mctx["hq"]["opportunity"]), "note": "hq opportunity"})
	return mctx


static func _add_intent(intents: Array, kind: String, locus: Vector2i, commit: float) -> void:
	var cfg_i: Array = CfgCls.section("intents")[kind]
	intents.append({"type": kind, "locus": locus, "focus_target_id": "",
		"score": float(cfg_i[0]) + float(cfg_i[1]) * commit, "note": "mission"})


## HQ opportunity layer (all families). opportunity = kill margin x (1 - guard/strike) x (1 - own risk).
static func hq_opportunity(own_hq: Dictionary, enemy_hq: Dictionary, friends: Array, enemies: Array, rs: Dictionary) -> Dictionary:
	var hc := CfgCls.section("hq")
	var eta_win := int(hc["strike_eta"])
	var out := {"opportunity": 0.0, "open": false, "strike_set": [], "own_risk": 0.0, "enemy_hq_point": null}
	# own HQ risk = max over enemies of power / max(floor, ETA to own HQ), relative to own HQ soldiers
	if not own_hq.is_empty():
		var hp := _pt(own_hq)
		var worst := 0.0
		for e in enemies:
			worst = maxf(worst, _soldiers(e) / float(maxi(int(hc["own_risk_eta_floor"]), _eta(e, hp, rs))))
		out["own_risk"] = clampf(worst / maxf(1.0, _soldiers(own_hq)), 0.0, 1.0)
	if enemy_hq.is_empty():
		return out
	var ep := _pt(enemy_hq)
	out["enemy_hq_point"] = ep
	var dmg := 0.0
	var strike := 0.0
	for u in friends:
		var eta := _eta(u, ep, rs)
		if eta <= eta_win:
			(out["strike_set"] as Array).append(str(u["unit_id"]))
			dmg += _soldiers(u) * float(hc["dmg_frac_per_turn"]) * float(maxi(1, eta_win - eta))
			strike += _soldiers(u)
	if strike <= 0.0:
		return out
	var hq_s := maxf(1.0, _soldiers(enemy_hq))
	var guard := 0.0
	for e in enemies:
		if hexd(_pt(e), ep) <= int(hc["guard_radius"]):
			guard += _soldiers(e)
	var opp := clampf((dmg - hq_s) / hq_s, 0.0, 1.0) * clampf(1.0 - guard / strike, 0.0, 1.0) * (1.0 - float(out["own_risk"]))
	out["opportunity"] = opp
	out["open"] = opp >= float(hc["hq_open"])
	return out


static func mult(mctx: Dictionary, key: String) -> float:
	return float((mctx.get("mult", {}) as Dictionary).get(key, 1.0))


## Additive mission terms for one candidate. Returns {score, terms}.
static func candidate_bonus(c: Dictionary, mctx: Dictionary, own: Dictionary, visible_by_id: Dictionary) -> Dictionary:
	var terms := {}
	if not bool(mctx.get("on", false)) or own.is_empty():
		return {"score": 0.0, "terms": terms}
	var w := CfgCls.section("weights")
	var pol := CfgCls.section("policy")
	var kind := str(c.get("action_type", "")).to_upper()
	var uid := str(c.get("unit_id", ""))
	var fam := str(mctx["family"])
	var role := str(mctx["role"])
	var origin := _pt(own)
	var is_hq := _cls(own) == "hq"
	var hq: Dictionary = mctx["hq"]
	var target: Variant = (mctx["targets"] as Dictionary).get(uid, null)
	var hold: Variant = (mctx["hold"] as Dictionary).get(uid, null)
	var leash: Dictionary = mctx["leash"]
	var hold_r := int(pol["hold_radius"])
	if kind == "MOVE":
		var dest := _arr_pt(c.get("destination", []))
		if is_hq:
			if fam == "M4" and mctx["hq_target"] != null:
				var site: Vector2i = mctx["hq_target"]
				var prog := clampf(float(hexd(origin, site) - hexd(dest, site)), -2.0, 2.0)
				terms["m_hq_site_progress"] = float(w["hq_site_progress"]) * prog
			elif int(mctx["own_base_count"]) > 0 and not (mctx["own_line"] as Array).is_empty():
				var base_pt: Vector2i = (mctx["own_line"] as Array).back()
				var stretch := float(hexd(dest, base_pt) - hexd(origin, base_pt))
				if stretch > 0.0:
					terms["m_hq_line_stretch"] = -float(w["hq_line_stretch"]) * stretch
		else:
			if target != null:
				var t: Vector2i = target
				var prog := clampf(float(hexd(origin, t) - hexd(dest, t)), -2.0, 2.0)
				terms["m_progress"] = float(w["progress"]) * mult(mctx, "progress") * prog
			if hold != null and hexd(origin, hold) <= hold_r and hexd(dest, hold) > hold_r:
				terms["m_hold_leave"] = -float(w["hold_leave"])
			if not leash.is_empty():
				var excess := hexd(dest, leash["center"]) - int(leash["radius"])
				if excess > 0:
					terms["m_leash"] = -float(w["leash"]) * float(excess)
			if fam == "M3":
				var excess2 := hexd(dest, mctx["own_centroid"]) - int(pol["m3_concentrate_radius"])
				if excess2 > 0:
					terms["m_cohesion"] = -float(w["cohesion"]) * float(excess2)
			if dest in (mctx["enemy_line"] as Array) and _cheap_cut(dest, own, visible_by_id, pol):
				terms["m_cut_supply"] = float(w["cut_supply"])
			if bool(hq["open"]) and uid in (hq["strike_set"] as Array) and hq["enemy_hq_point"] != null:
				var ep: Vector2i = hq["enemy_hq_point"]
				terms["m_hq_strike_move"] = float(w["hq_strike_move"]) * float(hq["opportunity"]) \
					* clampf(float(hexd(origin, ep) - hexd(dest, ep)), -2.0, 2.0)
	elif kind in ["WAIT", "FORTIFY", "REST", "DISMANTLE"] and is_hq and fam == "M4" and mctx["hq_target"] != null 			and origin != mctx["hq_target"]:
		# The occupation HQ is the builder: idling or digging in away from the next site stalls the mission.
		terms["m_hq_site_idle"] = float(w["hq_site_idle"]) * (1.0 if kind == "DISMANTLE" else -1.0)
	elif kind in ["WAIT", "FORTIFY", "REST"]:
		if hold != null and hexd(origin, hold) <= hold_r:
			terms["m_hold_idle"] = float(w["hold_idle"])
		elif (mctx["reserve"] as Dictionary).has(uid) and target != null and hexd(origin, target) <= hold_r:
			terms["m_reserve_hold"] = float(w["reserve_hold"])
	elif kind == "ATTACK":
		var tid := str(c.get("target_id", ""))
		var tgt: Dictionary = visible_by_id.get(tid, {})
		var tp := _pt(tgt) if not tgt.is_empty() else Vector2i(int(c.get("target_q", 0)), int(c.get("target_r", 0)))
		var t_hq := _cls(tgt) == "hq" or str(c.get("target_class", "")) == "hq"
		if t_hq and bool(hq["open"]):
			terms["m_hq_strike_attack"] = float(w["hq_strike_attack"]) * float(hq["opportunity"])
		if tp in (mctx["own_line"] as Array):
			terms["m_protect_supply"] = float(w["protect_supply"])
		if not t_hq:
			if not leash.is_empty() and hexd(tp, leash["center"]) > int(leash["radius"]):
				terms["m_leash_attack"] = -float(w["leash_attack"])
			if fam == "M1" and role == "attacker" and target != null and hexd(tp, target) <= hold_r:
				terms["m_village_fight"] = float(w["village_fight"])
			if fam == "M3":
				var e_loss := 0.5 * (float(c.get("expected_enemy_casualties_min", 0)) + float(c.get("expected_enemy_casualties_max", 0)))
				var f_loss := 0.5 * (float(c.get("expected_friendly_casualties_min", 0)) + float(c.get("expected_friendly_casualties_max", 0)))
				if e_loss >= f_loss * float(pol["m3_trade_ratio"]):
					terms["m_trade"] = float(w["trade"]) * mult(mctx, "trade")
				if bool(mctx["enemy_near_collapse"]):
					terms["m_push"] = float(w["push"])
			if fam == "M4":
				var relevant := tp in (mctx["enemy_line"] as Array) or tp in (mctx["own_line"] as Array)
				for s in (mctx["site_hexes"] as Array):
					if hexd(tp, s) <= int(pol["m4_site_radius"]):
						relevant = true
				terms["m_site_fight" if relevant else "m_irrelevant_fight"] = float(w["site_fight"]) if relevant else -float(w["irrelevant_fight"])
	elif kind == "ASSAULT":
		if role == "attacker" and fam in ["M2", "M5"]:
			if str(mctx["assault_mode"]) == "breach" or not str(c.get("garrison_target_id", "")).is_empty():
				terms["m_assault_breach"] = float(w["assault_breach"])
			else:
				terms["m_assault_wall"] = float(w["assault_wall"]) * mult(mctx, "assault_wall")
	elif kind == "ENTER_GARRISON":
		if bool(mctx["garrison_wanted"]) and not (mctx["protectors"] as Dictionary).has(uid):
			terms["m_garrison"] = float(w["garrison"]) * mult(mctx, "garrison")
	elif kind == "BUILD_BASE":
		var hex := _arr_pt(c.get("hex", []))
		if fam == "M4" and hex in (mctx["site_hexes"] as Array):
			terms["m_build_site"] = float(w["build_site"])
		elif int(mctx["own_base_count"]) == 0:
			terms["m_build_first"] = float(w["build_first"])
		else:
			terms["m_build_other"] = float(w["build_other"])
	# own-HQ threat raises defense (no always-on HQ value either way)
	if kind == "MOVE" and not is_hq and mctx["own_hq_point"] != null \
			and float(hq["own_risk"]) >= float(CfgCls.section("hq")["own_risk_raise"]):
		var hp: Vector2i = mctx["own_hq_point"]
		var dest2 := _arr_pt(c.get("destination", []))
		terms["m_own_hq_defend"] = float(w["own_hq_defend"]) * float(hq["own_risk"]) \
			* clampf(float(hexd(origin, hp) - hexd(dest2, hp)), -2.0, 2.0)
	var score := 0.0
	for k in terms.keys():
		score += float(terms[k])
	return {"score": score, "terms": terms}


## A supply raid is "cheap" when the enemy strength around the line hex is below our unit's strength x ratio (line is display-only under the base-count rule).
static func _cheap_cut(dest: Vector2i, own: Dictionary, visible_by_id: Dictionary, pol: Dictionary) -> bool:
	var near := 0.0
	for e in visible_by_id.values():
		if hexd(_pt(e), dest) <= int(pol["sense_radius"]):
			near += _soldiers(e)
	return near < _soldiers(own) * float(pol["supply_cut_cheap_ratio"])
