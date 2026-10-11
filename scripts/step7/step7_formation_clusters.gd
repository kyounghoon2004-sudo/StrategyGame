class_name Step7FormationClusters
extends RefCounted

## Adaptive Friendly Formation Clusters - canonical tactical-band authority.
##
## Replaces the fixed LEFT_WING / CENTER / RIGHT_WING one-third partition
## (Step7TacticalFrame sectors are now LEGACY; see that file's header).
## Cluster count emerges from friendly formation geometry; no fixed K.
##
## FRAME (preserved stable battle axes, Sec 2):
## - FORWARD: BLUE EAST (+q). Stable mission/deployment/objective geometry.
##   Never derived from unit clustering (a column must not rotate the frame).
## - LATERAL: world Y facing east (y = r*42 + q*21, mirrors HexUtils).
##   Clustering happens ONLY along this lateral dimension.
## - Clustering scalar (map-scale normalized, translation invariant):
##     s_i = r_i + 0.5 * q_i   (= lateral world Y / ROW_STEP, in hex units)
##   Gaps between sorted s_i drive segmentation, so a translated or
##   re-scaled-but-equivalent deployment clusters identically.
##
## ANCHOR POLICY (Sec 4, Sec 26):
## - Discovery anchors = friendly MOVABLE COMBAT formations only:
##   CAVALRY, INFANTRY, SPEARMAN, ARCHER, SCOUT, SIEGE, CONSCRIPT.
## - HQ / SUPPLY never steer discovery (a distant wagon must not redraw wings)
##   but ARE assignable to resulting bands for inspection and scope queries.
## - Skipped anchors: garrisoned, routed, or dead (soldier_count <= 0).
## - 0 anchors -> honest failure (no invented geometry). 1 anchor -> one
##   cluster. 2 anchors -> split iff the single gap >= MIN_SPLIT_HEX.
##
## GAP RULE (Sec 6-7, all DATA in CLUSTER_CONFIG below, no hidden constants):
## - Sort s_i (tie: unit id). Gaps g_i = s_(i+1) - s_i.
## - Robust spread: median gap + MAD (median absolute deviation).
## - split_threshold = max(MIN_SPLIT_HEX,
##                         median + GAP_K * MAD_SCALED,
##                         median * GAP_RATIO (when median > 0))
## - Split at every gap strictly greater than the threshold. A singleton
##   beyond a large gap is a VALID cluster (outliers are tactically
##   important, Sec 9). Continuous spacing below the floor never splits.
##
## LABELS (Sec 11-13): robust center c = median anchor s. Clusters sorted by
## centroid. The cluster whose [min_s, max_s] contains c becomes C. If c falls
## in a natural gap, NO center is invented: left clusters -> L1 (nearest) ..
## Ln (outermost), right clusters -> R1 .. Rn. Single cluster -> C.
##
## MACRO WINGS (Sec 14): LEFT = all L*, CENTER = C if present, RIGHT = all R*,
## EXTREME_LEFT/RIGHT = outermost L*/R*. Stored as DATA aliases (Korean incl.),
## no natural-language parser lives here.
##
## BANDS (Sec 15-16): 1D Voronoi over centroids; boundary_i = (mu_i+mu_(i+1))/2.
## Every playable hex resolves to exactly one band. No overlap, no holes.
##
## LIFECYCLE (Sec 17-18): refresh() at FRIENDLY TURN START freezes centroids +
## boundaries + labels. During the turn, units move: membership derives from
## CURRENT hex against the FROZEN map (crossing is legal; geometry never
## slides mid-command). Next turn (or explicit rebuild) recomputes.
##
## KNOWLEDGE HYGIENE: discovery reads friendly positions only. No enemy
## positions, no fog, no camera, no pixels, no map-coordinate thresholds.

const VERSION := "formation_clusters_v1"

const ANCHOR_CLASSES: Array = [
	"CAVALRY", "INFANTRY", "SPEARMAN", "ARCHER", "SCOUT", "SIEGE", "CONSCRIPT",
]

# Hex geometry mirrors HexUtils (COL_STEP=36, ROW_STEP=42, ODD_Q=21).
# Kept local so clustering has zero pathing/render dependencies.
const ROW_STEP := 42
const ODD_Q_Y_OFFSET := 21

# Robust-gap configuration - DATA, map-independent, documented in Sec 7.
const CLUSTER_CONFIG := {
	"MIN_SPLIT_HEX": 3.0, # gaps below this (hex units) never split
	"GAP_K": 3.0, # median + GAP_K * MAD_scaled robust bar
	"MAD_SCALE": 1.4826, # normal-consistent MAD scaling
	"GAP_RATIO": 2.5, # threshold is at least median * GAP_RATIO
}

const WINGS: Array = ["LEFT", "CENTER", "RIGHT"]

# Canonical language aliases - DATA ONLY (future parser maps words to these
# tokens; Godot keeps owning membership).
const CLUSTER_ALIASES := {
	"C": ["center", "centre", "middle", "중앙", "중부"],
	"L": ["left", "left wing", "좌", "좌측", "왼쪽", "좌익"],
	"R": ["right", "right wing", "우", "우측", "오른쪽", "우익"],
	"EXTREME_LEFT": ["extreme left", "outer left", "far left", "극좌", "극좌익"],
	"EXTREME_RIGHT": ["extreme right", "outer right", "far right", "극우", "극우익"],
}

const BoundaryScript = preload("res://scripts/step2r/step2r_world_boundary.gd")

# --- Frozen turn geometry (static cache; refresh() owns every write) --------
# STEP 2: one frozen registry per acting side. BLUE callers (every Step 1
# path) keep the original registry untouched; RED geometry freezes
# separately so a RED observation never redraws BLUE wings mid-turn.
static var _built: bool = false
static var _frozen_turn: int = -1
static var _clusters: Array = [] # sorted by centroid asc; each {id,centroid,min_s,max_s,members,anchor_q,anchor_r}
static var _boundaries: Array = [] # floats, size = clusters-1
static var _band_by_hex: Dictionary = {} # "q,r" -> cluster id
static var _stats: Dictionary = {}
static var _timings: Dictionary = {}
static var _built_red: bool = false
static var _frozen_turn_red: int = -1
static var _clusters_red: Array = []
static var _boundaries_red: Array = []
static var _band_by_hex_red: Dictionary = {}
static var _stats_red: Dictionary = {}
static var _timings_red: Dictionary = {}


## Acting-side key. Anything but "red" means "blue" (Step 1).
static func _side_key(side: String) -> String:
	return "red" if side.strip_edges().to_lower() == "red" else "blue"


static func _s_clusters(side: String) -> Array:
	return _clusters_red if _side_key(side) == "red" else _clusters


static func _s_boundaries(side: String) -> Array:
	return _boundaries_red if _side_key(side) == "red" else _boundaries


static func _s_band_map(side: String) -> Dictionary:
	return _band_by_hex_red if _side_key(side) == "red" else _band_by_hex


static func _s_stats(side: String) -> Dictionary:
	return _stats_red if _side_key(side) == "red" else _stats


static func _s_timings(side: String) -> Dictionary:
	return _timings_red if _side_key(side) == "red" else _timings


static func _s_built(side: String) -> bool:
	return _built_red if _side_key(side) == "red" else _built


static func _s_frozen_turn(side: String) -> int:
	return _frozen_turn_red if _side_key(side) == "red" else _frozen_turn


## Lateral scalar in hex units (world Y / ROW_STEP). Gaps are translation
## invariant and map-scale normalized by construction.
static func lateral_hex(q: int, r: int) -> float:
	return float(r) + float(q) * 0.5


## World-Y form (mirrors TacticalFrame.lateral_y for cross-checks).
static func lateral_y(q: int, r: int) -> float:
	return float(r * ROW_STEP + q * ODD_Q_Y_OFFSET)


## Anchor eligibility (Sec 4). Expects a unit Dictionary; case-insensitive class.
static func is_anchor(unit: Dictionary) -> bool:
	if str(unit.get("class", "")).to_upper() not in ANCHOR_CLASSES:
		return false
	if int(unit.get("soldier_count", 0)) <= 0:
		return false
	if bool(unit.get("garrisoned", false)) or bool(unit.get("routed", false)):
		return false
	return true


## Cluster-id shape: C, L1..Ln, R1..Rn.
static func is_valid_cluster_id(cid: String) -> bool:
	var c := cid.strip_edges().to_upper()
	if c == "C":
		return true
	var re := RegEx.new()
	re.compile("^[LR][1-9][0-9]*$")
	return re.search(c) != null


static func is_valid_wing(wing: String) -> bool:
	return wing.strip_edges().to_upper() in WINGS


## Wing of a cluster id: L* -> LEFT, C -> CENTER, R* -> RIGHT.
static func wing_of_cluster(cid: String) -> String:
	var c := cid.strip_edges().to_upper()
	if c == "C":
		return "CENTER"
	if c.begins_with("L"):
		return "LEFT"
	if c.begins_with("R"):
		return "RIGHT"
	return ""


# --- Pure deterministic core (no static state; fully unit-testable) ---------

static func _median_of(sorted_vals: Array) -> float:
	if sorted_vals.is_empty():
		return 0.0
	var n := sorted_vals.size()
	if n % 2 == 1:
		return float(sorted_vals[n / 2])
	return (float(sorted_vals[n / 2 - 1]) + float(sorted_vals[n / 2])) / 2.0


## Full pipeline over anchor rows [{id,q,r}]. Returns {ok, clusters,
## boundaries, stats} or {ok:false, reason}. Never reads global state.
static func clusterize(anchors: Array) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var cfg: Dictionary = CLUSTER_CONFIG
	var min_split := float(cfg.get("MIN_SPLIT_HEX", 3.0))
	# Deterministic order: lateral asc, id tie-break.
	var rows: Array = []
	for a in anchors:
		if not a is Dictionary:
			continue
		rows.append({"id": str((a as Dictionary).get("id", "")),
			"q": int((a as Dictionary).get("q", 0)),
			"r": int((a as Dictionary).get("r", 0)),
			"s": lateral_hex(int((a as Dictionary).get("q", 0)), int((a as Dictionary).get("r", 0)))})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if abs(float(a["s"]) - float(b["s"])) > 1e-9:
			return float(a["s"]) < float(b["s"])
		return str(a["id"]) < str(b["id"]))
	if rows.is_empty():
		return {"ok": false, "reason": "no anchor formations to cluster"}
	var proj_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var t1 := Time.get_ticks_usec()
	var scalars: Array = []
	for r in rows:
		scalars.append(float((r as Dictionary)["s"]))
	# Gaps between consecutive sorted projections.
	var gaps: Array = []
	for i in range(scalars.size() - 1):
		gaps.append(float(scalars[i + 1]) - float(scalars[i]))
	var gaps_sorted: Array = gaps.duplicate()
	gaps_sorted.sort()
	var median_gap := _median_of(gaps_sorted)
	var absdev: Array = []
	for g in gaps_sorted:
		absdev.append(absf(float(g) - median_gap))
	absdev.sort()
	var mad := _median_of(absdev)
	var mad_scaled := float(cfg.get("MAD_SCALE", 1.4826)) * mad
	var threshold: float = maxf(min_split,
		median_gap + float(cfg.get("GAP_K", 3.0)) * mad_scaled)
	if median_gap > 0.0:
		threshold = maxf(threshold, median_gap * float(cfg.get("GAP_RATIO", 2.5)))
	# Split points (indices into rows: split AFTER row i).
	var splits: Array = []
	if rows.size() == 2:
		# Pair rule (Sec 7 fallback): far pair separates, close pair coheres.
		if float(gaps[0]) >= min_split:
			splits.append(0)
	else:
		for i in range(gaps.size()):
			if float(gaps[i]) > threshold:
				splits.append(i)
	# Build contiguous groups.
	var groups: Array = []
	var start := 0
	for sp in splits:
		groups.append(rows.slice(start, int(sp) + 1))
		start = int(sp) + 1
	groups.append(rows.slice(start))
	# Robust center = median anchor projection (never map/enemy/screen).
	var center := _median_of(scalars)
	# Order groups by centroid for labeling.
	var ginfo: Array = []
	for g in groups:
		var sum := 0.0
		var mn := 1e18
		var mx := -1e18
		var ids: Array = []
		for r in (g as Array):
			var rd: Dictionary = r
			sum += float(rd["s"])
			mn = minf(mn, float(rd["s"]))
			mx = maxf(mx, float(rd["s"]))
			ids.append(str(rd["id"]))
		ids.sort()
		ginfo.append({"centroid": sum / float((g as Array).size()),
			"min_s": mn, "max_s": mx, "members": ids, "rows": g})
	ginfo.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if abs(float(a["centroid"]) - float(b["centroid"])) > 1e-9:
			return float(a["centroid"]) < float(b["centroid"])
		return str((a["members"] as Array)[0]) < str((b["members"] as Array)[0]))
	# Labels: genuine center cluster -> C; a center inside a gap invents
	# nothing (left of gap -> L*, right -> R*, nearest first).
	var center_idx := -1
	for i in range(ginfo.size()):
		if float((ginfo[i] as Dictionary)["min_s"]) <= center and center <= float((ginfo[i] as Dictionary)["max_s"]):
			center_idx = i
			break
	var labels: Array = []
	labels.resize(ginfo.size())
	if center_idx >= 0:
		labels[center_idx] = "C"
		var li := 1
		for i in range(center_idx - 1, -1, -1):
			labels[i] = "L%d" % li
			li += 1
		var ri := 1
		for i in range(center_idx + 1, ginfo.size()):
			labels[i] = "R%d" % ri
			ri += 1
	else:
		var left_count := 0
		for i in range(ginfo.size()):
			if float((ginfo[i] as Dictionary)["max_s"]) < center:
				left_count += 1
		var li2 := 1
		for i in range(left_count - 1, -1, -1):
			labels[i] = "L%d" % li2
			li2 += 1
		var ri2 := 1
		for i in range(left_count, ginfo.size()):
			labels[i] = "R%d" % ri2
			ri2 += 1
	var clusters: Array = []
	for i in range(ginfo.size()):
		var gd: Dictionary = ginfo[i]
		# Cluster anchor: member nearest the centroid (real map hex, always
		# playable since a friendly stands on it). Id tie-break.
		var best_q := 0
		var best_r := 0
		var best_d := 1e18
		var best_id := ""
		for r in (gd["rows"] as Array):
			var rd: Dictionary = r
			var d := absf(float(rd["s"]) - float(gd["centroid"]))
			if d < best_d - 1e-9 or (absf(d - best_d) <= 1e-9 and str(rd["id"]) < best_id):
				best_d = d
				best_q = int(rd["q"])
				best_r = int(rd["r"])
				best_id = str(rd["id"])
		clusters.append({"id": str(labels[i]), "centroid": float(gd["centroid"]),
			"min_s": float(gd["min_s"]), "max_s": float(gd["max_s"]),
			"members": (gd["members"] as Array).duplicate(),
			"anchor_q": best_q, "anchor_r": best_r, "anchor_id": best_id})
	var boundaries: Array = []
	for i in range(clusters.size() - 1):
		boundaries.append((float((clusters[i] as Dictionary)["centroid"]) + float((clusters[i + 1] as Dictionary)["centroid"])) / 2.0)
	var build_ms := float(Time.get_ticks_usec() - t1) / 1000.0
	return {"ok": true, "clusters": clusters, "boundaries": boundaries,
		"stats": {"anchor_count": rows.size(), "cluster_count": clusters.size(),
			"sorted_projections": rows.map(func(r: Dictionary) -> Dictionary:
				return {"id": str(r["id"]), "s": float(r["s"])}),
			"gaps": gaps.duplicate(), "median_gap": median_gap, "mad": mad,
			"mad_scaled": mad_scaled, "split_threshold": threshold,
			"split_after": splits.duplicate(), "robust_center": center,
			"config": cfg.duplicate(),
			"projection_sort_ms": proj_ms, "cluster_build_ms": build_ms}}


## Band lookup over a frozen cluster set (pure): nearest centroid in lateral
## space; ties resolve to the lower (left) cluster deterministically.
static func band_lookup(s: float, clusters: Array, boundaries: Array) -> String:
	if clusters.is_empty():
		return ""
	for i in range(boundaries.size()):
		if s < float(boundaries[i]):
			return str((clusters[i] as Dictionary)["id"])
	return str((clusters[clusters.size() - 1] as Dictionary)["id"])


# --- Frozen turn geometry ----------------------------------------------------

## Build + freeze from live BLUE unit dicts at turn start. HQ/SUPPLY excluded
## from discovery but assigned to bands afterwards. Records phase latency.
static func refresh(blue_units: Array, turn: int, playable_keys: Array = []) -> Dictionary:
	return refresh_side(blue_units, "blue", turn, playable_keys)


## Build + freeze from live acting-side unit dicts at turn start.
## discovery reads the acting side's positions only. Side registries are
## independent: freezing RED never touches the frozen BLUE geometry.
static func refresh_side(units: Array, side: String, turn: int, playable_keys: Array = []) -> Dictionary:
	var sk := _side_key(side)
	var t0 := Time.get_ticks_usec()
	var anchors: Array = []
	for u_val in units:
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != sk:
			continue
		if not is_anchor(u):
			continue
		anchors.append({"id": str(u.get("id", "")), "q": int(u.get("q", 0)), "r": int(u.get("r", 0))})
	anchors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
	var res := clusterize(anchors)
	if not bool(res.get("ok", false)):
		_store_frozen(sk, false, turn, [], [], {}, {"ok": false, "reason": str(res.get("reason", "?"))}, {})
		return {"ok": false, "reason": str(res.get("reason", "?"))}
	var clusters: Array = (res.get("clusters", []) as Array).duplicate(true)
	var boundaries: Array = (res.get("boundaries", []) as Array).duplicate()
	var t_band := Time.get_ticks_usec()
	var band_map := _build_band_map(playable_keys, sk, clusters, boundaries)
	var band_ms := float(Time.get_ticks_usec() - t_band) / 1000.0
	var stats: Dictionary = (res.get("stats", {}) as Dictionary).duplicate(true)
	var timings := {"projection_sort_ms": float(stats.get("projection_sort_ms", 0.0)),
		"cluster_build_ms": float(stats.get("cluster_build_ms", 0.0)),
		"band_map_ms": band_ms,
		"total_ms": float(Time.get_ticks_usec() - t0) / 1000.0,
		"anchor_count": int(stats.get("anchor_count", 0)),
		"cluster_count": clusters.size()}
	stats["band_hexes"] = band_map.size()
	_store_frozen(sk, true, turn, clusters, boundaries, band_map, stats, timings)
	return {"ok": true, "turn": turn, "clusters": clusters.duplicate(true),
		"boundaries": boundaries.duplicate(), "stats": stats.duplicate(true),
		"latency": timings.duplicate()}


static func _store_frozen(sk: String, built: bool, turn: int, clusters: Array, boundaries: Array, band_map: Dictionary, stats: Dictionary, timings: Dictionary) -> void:
	if sk == "red":
		_built_red = built
		_frozen_turn_red = turn
		_clusters_red = clusters
		_boundaries_red = boundaries
		_band_by_hex_red = band_map
		_stats_red = stats
		_timings_red = timings
	else:
		_built = built
		_frozen_turn = turn
		_clusters = clusters
		_boundaries = boundaries
		_band_by_hex = band_map
		_stats = stats
		_timings = timings


static func _build_band_map(playable_keys: Array, side: String = "blue", clusters: Array = [], boundaries: Array = []) -> Dictionary:
	var out := {}
	var keys: Array = playable_keys.duplicate()
	if keys.is_empty():
		for q in range(-BoundaryScript.HEX_RADIUS, BoundaryScript.HEX_RADIUS + 1):
			for r in range(-BoundaryScript.HEX_RADIUS, BoundaryScript.HEX_RADIUS + 1):
				var c := Vector2i(q, r)
				if BoundaryScript.is_playable_hex(c):
					keys.append("%d,%d" % [q, r])
	# An explicitly passed cluster set always pairs with its own boundaries
	# (even when empty for a single cluster); the stored registry is only a
	# fallback when no set is passed. Mixing a fresh set with stale
	# boundaries would desync band_lookup.
	var use_clusters: Array = _s_clusters(side)
	var use_boundaries: Array = _s_boundaries(side)
	if not clusters.is_empty():
		use_clusters = clusters
		use_boundaries = boundaries
	for key_val in keys:
		var parts := str(key_val).split(",")
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		var q := int(parts[0])
		var r := int(parts[1])
		out[str(key_val)] = band_lookup(lateral_hex(q, r), use_clusters, use_boundaries)
	return out


## Turn-freeze gate (Sec 17): rebuild only when nothing is frozen yet or the
## friendly turn advanced. Mid-turn moves never trigger a rebuild here.
static func ensure_turn(turn: int, blue_units: Array, side: String = "blue") -> bool:
	if not _s_built(side) or turn != _s_frozen_turn(side):
		refresh_side(blue_units, side, turn)
		return true
	return false


static func is_built(side: String = "blue") -> bool:
	return _s_built(side)


static func frozen_turn(side: String = "blue") -> int:
	return _s_frozen_turn(side)


static func force_invalidate(side: String = "") -> void:
	# Empty side clears BOTH registries (test/lifecycle reset); an explicit
	# side clears only that registry.
	if side.strip_edges().is_empty() or _side_key(side) == "blue":
		_built = false
		_clusters = []
		_boundaries = []
		_band_by_hex = {}
		_stats = {}
		_timings = {}
		_frozen_turn = -1
	if side.strip_edges().is_empty() or _side_key(side) == "red":
		_built_red = false
		_clusters_red = []
		_boundaries_red = []
		_band_by_hex_red = {}
		_stats_red = {}
		_timings_red = {}
		_frozen_turn_red = -1


## Canonical resolver: exactly one band per playable hex (Sec 16).
static func cluster_of_hex(q: int, r: int, side: String = "blue") -> String:
	if not _s_built(side):
		return ""
	return str(_s_band_map(side).get("%d,%d" % [q, r], ""))


static func cluster_of_unit(unit: Dictionary, side: String = "blue") -> String:
	return cluster_of_hex(int(unit.get("q", 0)), int(unit.get("r", 0)), side)


static func active_clusters(side: String = "blue") -> Array:
	return _s_clusters(side).duplicate(true)


static func cluster_ids(side: String = "blue") -> Array:
	var out: Array = []
	for c in _s_clusters(side):
		out.append(str((c as Dictionary)["id"]))
	return out


static func cluster_info(cid: String, side: String = "blue") -> Dictionary:
	for c in _s_clusters(side):
		if str((c as Dictionary)["id"]) == cid.strip_edges().to_upper():
			return (c as Dictionary).duplicate(true)
	return {}


static func boundaries(side: String = "blue") -> Array:
	return _s_boundaries(side).duplicate()


static func band_map(side: String = "blue") -> Dictionary:
	return _s_band_map(side).duplicate()


static func debug_stats(side: String = "blue") -> Dictionary:
	var d := _s_stats(side).duplicate(true)
	d["latency"] = _s_timings(side).duplicate()
	d["frozen_turn"] = _s_frozen_turn(side)
	d["built"] = _s_built(side)
	return d


static func frozen_signature(side: String = "blue") -> String:
	var parts: Array = ["t=%d" % _s_frozen_turn(side)]
	for c in _s_clusters(side):
		parts.append("%s:%.3f" % [str((c as Dictionary)["id"]), float((c as Dictionary)["centroid"])])
	for b in _s_boundaries(side):
		parts.append("b=%.3f" % float(b))
	return "|".join(parts)


## Band range of a cluster in lateral-hex units: [lo, hi); null edge means
## open (extends to the envelope edge). Deterministic from frozen geometry.
static func band_range(cid: String, side: String = "blue") -> Dictionary:
	var reg: Array = _s_clusters(side)
	var bnd: Array = _s_boundaries(side)
	var idx := -1
	for i in range(reg.size()):
		if str((reg[i] as Dictionary)["id"]) == cid.strip_edges().to_upper():
			idx = i
			break
	if idx < 0:
		return {}
	var lo: Variant = null
	var hi: Variant = null
	if idx > 0:
		lo = float(bnd[idx - 1])
	if idx < bnd.size():
		hi = float(bnd[idx])
	return {"lo": lo, "hi": hi}


static func extreme_left(side: String = "blue") -> String:
	var ids := cluster_ids(side)
	var lefts: Array = []
	for cid in ids:
		if str(cid).begins_with("L"):
			lefts.append(str(cid))
	if lefts.is_empty():
		return ""
	lefts.sort_custom(func(a: String, b: String) -> bool: return int(a.substr(1)) > int(b.substr(1)))
	return str(lefts[0])


static func extreme_right(side: String = "blue") -> String:
	var ids := cluster_ids(side)
	var rights: Array = []
	for cid in ids:
		if str(cid).begins_with("R"):
			rights.append(str(cid))
	if rights.is_empty():
		return ""
	rights.sort_custom(func(a: String, b: String) -> bool: return int(a.substr(1)) > int(b.substr(1)))
	return str(rights[0])


static func has_center(side: String = "blue") -> bool:
	return "C" in cluster_ids(side)


## Macro wing membership over unit dicts (CURRENT hex vs frozen bands).
static func wing_members(wing: String, units: Array, side: String = "blue") -> Array:
	var w := wing.strip_edges().to_upper()
	var out: Array = []
	for u_val in units:
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		var cid := cluster_of_unit(u, side)
		if cid.is_empty():
			continue
		match w:
			"LEFT":
				if cid.begins_with("L"):
					out.append(u)
			"CENTER":
				if cid == "C":
					out.append(u)
			"RIGHT":
				if cid.begins_with("R"):
					out.append(u)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out


static func _filter_live(units: Array, side: String, want_class: String, want_cluster: String) -> Array:
	var out: Array = []
	var wc := want_class.strip_edges().to_upper()
	var wcl := want_cluster.strip_edges().to_upper()
	for u_val in units:
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != side:
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if not wc.is_empty() and str(u.get("class", "")).to_upper() != wc:
			continue
		if cluster_of_unit(u, side) != wcl:
			continue
		out.append(u)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	return out


## Scope entry points (fog-safe: only the requesting side's CURRENT
## positions are read for membership; geometry itself uses zero unit reads
## beyond the frozen friendly discovery set).
static func resolve_cluster_class(cluster: String, unit_class: String, side: String, formation_source: RefCounted) -> Array:
	if formation_source == null or not formation_source.has_method("get_all_units_including_garrisoned"):
		return []
	var live: Array = formation_source.get_all_units_including_garrisoned()
	return _filter_live(live, side, unit_class, cluster)


static func resolve_cluster(cluster: String, side: String, formation_source: RefCounted) -> Array:
	if formation_source == null or not formation_source.has_method("get_all_units_including_garrisoned"):
		return []
	var live: Array = formation_source.get_all_units_including_garrisoned()
	return _filter_live(live, side, "", cluster)


static func resolve_wing_class(wing: String, unit_class: String, side: String, formation_source: RefCounted) -> Array:
	if formation_source == null or not formation_source.has_method("get_all_units_including_garrisoned"):
		return []
	var live: Array = []
	for u_val in formation_source.get_all_units_including_garrisoned():
		if not u_val is Dictionary:
			continue
		var u: Dictionary = u_val
		if str(u.get("faction", "")) != side:
			continue
		if int(u.get("soldier_count", 0)) <= 0:
			continue
		if str(u.get("class", "")).to_upper() != unit_class.strip_edges().to_upper():
			continue
		live.append(u)
	return wing_members(wing, live, side)


## Cluster anchor for target-oriented verbs: the frozen anchor hex of the
## requested cluster (a real friendly-occupied, playable hex).
static func cluster_anchor(cid: String, side: String = "blue") -> Vector2i:
	var info := cluster_info(cid.strip_edges().to_upper(), side)
	if info.is_empty():
		return Vector2i(0, 0)
	return Vector2i(int(info.get("anchor_q", 0)), int(info.get("anchor_r", 0)))


## Wing anchor: CENTER -> C anchor; LEFT/RIGHT -> extreme anchor of the wing.
## Deterministic; honest empty (0,0 never returned for a live wing).
static func wing_anchor(wing: String, side: String = "blue") -> Dictionary:
	var w := wing.strip_edges().to_upper()
	match w:
		"CENTER":
			if has_center(side):
				return {"ok": true, "point": cluster_anchor("C", side)}
			return {"ok": false}
		"LEFT":
			var e := extreme_left(side)
			if not e.is_empty():
				return {"ok": true, "point": cluster_anchor(e, side)}
			return {"ok": false}
		"RIGHT":
			var e2 := extreme_right(side)
			if not e2.is_empty():
				return {"ok": true, "point": cluster_anchor(e2, side)}
			return {"ok": false}
	return {"ok": false}


## DEV inspector payload (Sec 43): axes, projections, gaps, robust stats,
## per-cluster geometry + band ranges. Single call for panel + probe.
static func debug_snapshot(side: String = "blue") -> Dictionary:
	var per: Array = []
	for c in _s_clusters(side):
		var cd: Dictionary = c
		var cid := str(cd["id"])
		per.append({"id": cid, "centroid": float(cd["centroid"]),
			"min_s": float(cd["min_s"]), "max_s": float(cd["max_s"]),
			"anchor_ids": (cd["members"] as Array).duplicate(),
			"anchor_hex": [int(cd.get("anchor_q", 0)), int(cd.get("anchor_r", 0))],
			"band_range": band_range(cid, side),
			"wing": wing_of_cluster(cid)})
	return {"version": VERSION, "built": _s_built(side), "frozen_turn": _s_frozen_turn(side),
		"forward": "FORWARD (+q EAST, stable mission geometry)",
		"lateral": "LATERAL_Y world Y facing east; s = r + 0.5q (hex units)",
		"anchor_policy": "combat classes CAVALRY INFANTRY SPEARMAN ARCHER SCOUT SIEGE CONSCRIPT; HQ SUPPLY excluded from discovery",
		"stats": _s_stats(side).duplicate(true), "latency": _s_timings(side).duplicate(),
		"clusters": per, "boundaries": _s_boundaries(side).duplicate(),
		"signature": frozen_signature(side)}
