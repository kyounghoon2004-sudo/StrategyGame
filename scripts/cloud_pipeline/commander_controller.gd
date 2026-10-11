extends "res://scripts/utility_bot/utility_live_controller.gd"
const CommanderMissionCls = preload("res://scripts/cloud_pipeline/commander_mission.gd")

## COMMANDER v1 (dev / RL only, 2026-10-04): the Brain commands RED units directly; no Hand A/B models.
## RESIDENT Brain (user decision 2026-10-06, applied 2026-10-07): one conversation per game, asked every RED turn.
## The first message is the full battle state; every later message is only the new turn (events since the last
## answer + where every unit stands now), so nothing already in the conversation is sent or read again (the prefix
## stays cached). The reply {"orders": {only the units whose order changes}, "plan": "..."}:
## {"R_CAV_1": {"do": "ATTACK", "target": "B_HQ_1"}, "R_INF_1": {"do": "MOVE", "to": [-15, 0]}, ...}.
## Every request also carries the full packet as "state" (outside the messages, for code policies and data tools).
## Orders stand until replaced. Execution is deterministic over the game's legal action list (GX enumerator +
## executor): ATTACK X = attack X if legal, else the legal move that most shortens the open path to X; MOVE P = the
## same toward P (P = [q,r], any unit id, "MY_HQ" or "ENEMY_HQ"); RAID X = ATTACK X, then a cavalry unit spends its
## remaining movement toward "back_to". Only ATTACK / RAID (and ASSAULT on a stronghold) ever attack — attacking is
## solely the Brain's decision.
## 2026-10-06: FORTIFY / REST / ASSAULT / GARRISON orders, offered only when the rules allow them for this side;
## a fortified unit ordered to MOVE / ATTACK / ASSAULT / GARRISON leaves its fieldworks first (DISMANTLE, 1 MP);
## orders of dead units are dropped. Facts: class matchups (rules) always; with facts on, eta, "vs" (every my-unit x
## enemy pair: eta + the game's combat preview) and can_strike_next (flat ground). Rules the cloud kept guessing are
## stated: turn order, turn limit, unlisted matchups = 1.0, fieldworks, hidden enemy counts.
## A reply that is not a JSON object with "orders" latches a strict fault (the RL loop scores it INVALID).

const CombatCalcCls = preload("res://scripts/combat/combat_calculator.gd")
const TerrainCls = preload("res://scripts/cloud_pipeline/commander_terrain.gd")

const CMD_REQUEST := "VICTORY_COMMAND"
## Rules as the game applies them (2026-10-07 rewrite after the info audit: every rule the models kept guessing is
## stated once; no claim the game does not honour).
const SYSTEM_HEAD := """You are the RED commander in a hex wargame. You command every RED unit directly.
WIN: destroy the BLUE HQ (immediate). LOSE: your HQ destroyed. If neither HQ has fallen by "turn_limit", you have
failed; "turns_left" = RED turns remaining, this one included.
Board: every hex within "map_radius" of (0, 0), flat ground. Axial (q, r); distance = (|dq| + |dr| + |dq + dr|) / 2.
Turns: each round BLUE acts first, then RED. Units act one at a time in id order. A unit may move up to its "mp", then
attack one enemy within its "range"; only CAVALRY may move on after attacking. A unit attacks ONLY under an %s order.
Movement: one unit per hex; no unit enters or passes through a hex holding any unit (yours or BLUE's).
Combat: damage grows with the attacker's soldiers x attack x matchup and shrinks with the defender's soldiers x defense.
A melee attack (distance 1) is always answered by a counter-attack from the defender's soldiers before the hit, even
when the hit destroys it. A ranged attack (distance 2+) gets no counter and is not blocked by units in between.
"matchups" = attack multiplier, attacker row vs defender column. Enemy soldier counts are hidden: "troops" is the band
you can see.
You are asked every RED turn, right after BLUE has acted. This conversation is your memory of the battle: the first
message holds the full state at the start; every later message holds only the new turn: "events" since your last answer (every BLUE action you saw and every attack: "dealt" = soldiers killed,
"took" = the attacker's losses, "fieldworks -N" = fieldworks damage; your own moves are not listed) and where every
unit stands now. Older turns are folded by the game into a "BATTLE DIGEST" at the head of the oldest turn message
kept: what each unit did, and your orders and plan standing then.

Reply with ONE JSON object only, no prose: {"orders": {"<RED unit id>": {"do": "<ORDER>", ...}, ...}}
"orders" = only the units whose order changes ({} = every order stands). Orders stand until replaced; a unit never
ordered HOLDs. One optional key, left out unless needed:
- "plan": "<=300 chars: your strategy for winning this battle and why". Write it on the first turn and again only
  when you drop it for a different strategy. It is not a progress report and not a list of this turn's moves (those
  are your orders); your last plan stands until replaced.
A "target" is a BLUE unit id or "ENEMY_HQ". A "to" is [q, r], any unit id (yours or BLUE's), "MY_HQ" or "ENEMY_HQ".
Moving orders take the shortest open path and go around units in the way.
- {"do": "ATTACK", "target": ...}: moves toward the target and attacks it whenever it is in range; it hits nothing else.
- {"do": "MOVE", "to": ...}: moves toward it every turn until it arrives (give the real destination); never attacks.
- {"do": "HOLD"}: stays; never attacks."""
const VERB_LINES := {
	"RAID": "- {\"do\": \"RAID\", \"target\": ..., \"back_to\": <a \"to\">}: CAVALRY only. Like ATTACK, then it spends its remaining movement going toward back_to (hit and run).",
	"FORTIFY": "- {\"do\": \"FORTIFY\"}: digs in where it stands (only before it moves or attacks that turn): fieldworks of 180 HP take hits first and only the excess reaches its soldiers. It cannot move or attack but still counter-attacks melee. While the order stands it digs in again whenever its fieldworks are destroyed. Any other order first leaves the fieldworks (1 movement point). BLUE can fortify too (\"fortified\" = fieldworks HP left).",
	"REST": "- {\"do\": \"REST\"}: rests in place (only before it moves or attacks that turn) and recovers morale. It does not attack.",
	"ASSAULT": "- {\"do\": \"ASSAULT\", \"target\": \"<enemy stronghold id>\"}: closes on the stronghold and attacks its walls (its garrison once breached).",
	"GARRISON": "- {\"do\": \"GARRISON\", \"target\": \"<own stronghold id>\"}: moves into your stronghold.",
	"BUILD_BASE": "- {\"do\": \"BUILD_BASE\"}: HQ only. Builds your logistics base on the HQ's hex (not in a turn the HQ moved); then the HQ holds.",
}

const OPENING_VS := 3  # enemies per own unit in the first message's "vs" (nearest first)
const FACTS_PROMPT := """
Facts (each unit's own speed; units in the way are not counted):
"eta" = turns of movement until the target is in attack range, assuming it stays put (0 = in range now; 1 = it can
move and attack this turn): yours "strike_enemy_hq" and "reach_my_hq" (until next to your HQ); BLUE's "eta_strike_my_hq".
"vs" on your unit (first message) = the enemies you see nearest to it (up to %d, plus any it can attack this turn):
"<id> eta <n> dealt <a-b> taken <c-d>[ fw <f>]" = the
game's combat preview over the enemy's troops band: enemy soldiers it would kill, its own losses from the
counter-attack, damage to fieldworks; computed at its current distance if already in range, else at its full range.
Turn messages give one line per unit. Yours: "<id> <q>,<r> <soldiers>[ fort <fieldworks>][ eta_hq <strike_enemy_hq>]
[ | the "vs" entries of the enemies it can attack this turn (eta 0 or 1)]". BLUE: "<id> <q>,<r> <troops>[ fort
<fieldworks>][ seen t<last seen turn>][ eta_my_hq <eta_strike_my_hq>][ next <can_strike_next>]".
"can_strike_next" on an enemy = your units it can reach and attack on its next turn."""
## Memory (user 2026-10-08): no reset and no cut-off. Every request = system prompt + the opening (start state and the
## first answer: never changes, so it stays cached) + the turns kept word for word + the new turn. Once
## COMPACT_AT_DEFAULT turns are kept (WATCH_COMPACT_AT), or right after a new plan, all but the last
## RECENT_TURNS_DEFAULT (WATCH_RECENT_TURNS) are folded by code into a BATTLE DIGEST at the head of the oldest kept turn:
## per unit what it did (moves, attacks with kills and losses, hits taken, fieldworks, destroyed) plus the orders and
## plan standing at that point. Only the digest and the kept turns are read again, and only at a fold.
const RECENT_TURNS_DEFAULT := 5
const COMPACT_AT_DEFAULT := 10
## Size safety (2026-10-08, large armies): when the kept turns exceed this many characters (WATCH_FOLD_CHARS), the
## oldest are folded into the digest too (at least the newest turn stays), so the request stays inside the context.
const FOLD_CHARS_DEFAULT := 60000
## Turns of history in the "state" packet (code policies read it; the Brain never sees it after the first message).
const STATE_HISTORY_TURNS := 10
const AXIAL_DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 1)]

## Orders that need the unit to leave its fieldworks first.
const LEAVE_FORT := ["MOVE", "ATTACK", "RAID", "ASSAULT", "GARRISON"]
## Rule class keys that differ from the unit class names the packet shows.
const CLASS_ALIAS := {"SPEAR": "SPEARMAN"}

var use_facts := false
var mission_rules: Node = null  # mission maps (2026-10-09): the match judge, read for facts
var _terrain_aid = TerrainCls.new()
var _tfields := {}  # (dest, class) -> movement-cost field, rebuilt for every request
var rout_rule := false  # set by the match driver: large battle, a side also loses when 60% of its non-HQ units fall
var cmd_url := OS.get_environment("WATCH_CMD_URL").strip_edges() if not OS.get_environment("WATCH_CMD_URL").strip_edges().is_empty() else "http://127.0.0.1:8096/v1/chat/completions"
var orders := {}
var plan_text := ""
var plan_turn := 0
var strict_fault_info := {}
var stats := {"moves": 0, "attacks": 0, "waits": 0, "calls": 0, "decisions": 0}
var _last_results := {}
var _trace := OS.get_environment("WATCH_CMD_TRACE").strip_edges() == "1"  # one log line per executed action
## The opening of the game's conversation: [start-state message, its answer] (never changes).
var _opening: Array = []
## Turns kept word for word: {"turn", "msg", "answer", "events": the raw events behind msg}.
var _turns: Array = []
## Running totals of the folded turns (unit id -> what it did), the orders / plan standing at the last folded turn.
var _digest := {}
var _digest_upto := 0
var _digest_orders := {}
var _digest_plan := ""
var _digest_plan_turn := 0
var _plan_changed := false
## Raw events behind the last _events_since_last_call().
var _last_raw: Array = []
## The opponent's controller (set by the watch driver); its action_log feeds "history".
var opponent: Node = null
var _log_sent := {"own": 0, "opp": 0}
## The recent battle, oldest first: every seen action of both sides and each Brain decision (orders / plan).
## It is the "history" of the "state" packet.
var _history: Array = []
## Extra orders the rules allow this side (decided once, at the first call).
var _verbs := {}
var _http: HTTPRequest = null


func _ready() -> void:
	# side: "red" by default (the base class); the watch driver sets "blue" before adding a BLUE commander.
	auto_mount = false
	use_facts = OS.get_environment("WATCH_CMD_FACTS").strip_edges() == "1"
	_http = HTTPRequest.new()
	_http.timeout = 3600.0
	add_child(_http)


func strict_fault() -> Dictionary:
	return strict_fault_info.duplicate(true)


func laya_stats() -> Dictionary:
	return {"moves": stats["moves"], "attacks": stats["attacks"], "waits": stats["waits"],
		"decision_count": stats["decisions"], "fallback_count": 0, "exec_failures": 0, "hand_ab": {}}


func red_controller_mode() -> String:
	return "COMMANDER" if mount_ready else "DETERMINISTIC"


# ------------------------------------------------------------------ state for the Brain
static func _hd(a: Vector2i, b: Vector2i) -> int:
	var dq := a.x - b.x
	var dr := a.y - b.y
	return (absi(dq) + absi(dr) + absi(dq + dr)) / 2


## The history lines of the last STATE_HISTORY_TURNS turns before `turn` (older ones are dropped).
func _history_recent(turn: int) -> Array:
	var keep: Array = []
	for line in _history:
		var head := str(line).get_slice(" ", 0)
		if head.begins_with("t") and head.substr(1).is_valid_int() and int(head.substr(1)) < turn - STATE_HISTORY_TURNS:
			continue
		keep.append(line)
	_history = keep
	return keep


## The full battle state: the first message of a conversation, and the "state" every request carries.
func _packet(obs: Dictionary, why: String) -> Dictionary:
	var rules: Dictionary = EpisodeRuntimeCls.rules()
	var all_stats := {}
	var mp: Dictionary = rules.get("base_mp", {})
	for c in (rules.get("class_stats", {}) as Dictionary).keys():
		var st: Dictionary = (rules["class_stats"] as Dictionary)[c]
		var one: Dictionary = st.duplicate(true)
		one["mp"] = mp.get(c, null)
		var key := str(c).to_upper()
		all_stats[str(CLASS_ALIAS.get(key, key))] = one
	var mine: Array = []
	for u in obs.get("friendly_units", []):
		var row: Dictionary = u
		var uid := str(row.get("unit_id"))
		var soldiers := int(row.get("soldiers", 0))
		var mrow := {"id": row.get("unit_id"), "class": str(row.get("class", "")).to_upper(), "q": row.get("q"), "r": row.get("r"),
			"soldiers": soldiers, "start": int(row.get("max_count", soldiers)), "order": _order_text(orders.get(uid, {"do": "HOLD"}))}
		var fh := _fort_hp(uid)
		if fh > 0:
			mrow["fortified"] = fh
		if _terrain_on():
			mrow["terrain"] = _terrain_aid.name_of(Vector2i(int(row.get("q", 0)), int(row.get("r", 0))))
		mine.append(mrow)
	var foes: Array = []
	for e in obs.get("known_enemy_units", []):
		var row2: Dictionary = e
		var frow := {"id": row2.get("unit_id"), "class": str(row2.get("class", "")).to_upper(), "q": row2.get("q"), "r": row2.get("r"),
			"troops": _band_text(str(row2.get("troop_text", "")))}
		if str(row2.get("contact_state", "")) == "current_visible":
			var efh := _fort_hp(str(row2.get("unit_id", "")))
			if efh > 0:
				frow["fortified"] = efh
		else:
			frow["last_seen_turn"] = int(row2.get("last_seen_turn", 0))
		foes.append(frow)
	var classes: Array = []
	for row3 in mine + foes:
		if not str(row3["class"]) in classes:
			classes.append(str(row3["class"]))
	var cls_stats := {}
	for c in classes:
		if all_stats.has(c):
			cls_stats[c] = all_stats[c]
	var radius := int(((obs.get("board", {}) as Dictionary).get("dimensions", {}) as Dictionary).get("radius", 0))
	# Key order matters (stringified unsorted): what never changes, then the append-only history, then the present.
	var pkt := {"request": CMD_REQUEST, "map_radius": radius, "class_stats": cls_stats, "matchups": _matchups(classes)}
	var cap := OS.get_environment("WATCH_TURN_CAP").strip_edges()
	if cap.is_valid_int() and int(cap) > 0:
		pkt["turn_limit"] = int(cap)
	pkt["history"] = _history_recent(int(obs.get("turn", 0)))
	pkt["turn"] = obs.get("turn")
	if pkt.has("turn_limit"):
		pkt["turns_left"] = int(pkt["turn_limit"]) - int(obs.get("turn", 0)) + 1  # RED turns left, this one included
	if mission_rules != null:  # the mission's round limit, not the arena cap
		var mst: Dictionary = mission_rules.call("publish")
		pkt["turn_limit"] = int(mst.get("round_limit", 0))
		pkt["turns_left"] = int(mst.get("rounds_left", 0))
		pkt["mission"] = TerrainCls.mission_view(mst, side)
		if why == "start of battle":
			pkt["terrain"] = _terrain_list()
	if not why.is_empty():
		pkt["why_asked"] = why
	if not plan_text.is_empty():
		pkt["current_plan"] = {"text": plan_text, "since_turn": plan_turn}
	pkt["my_units"] = mine
	pkt["enemy_units"] = foes
	var shs := _strongholds_view()
	if not shs.is_empty():
		pkt["strongholds"] = shs
	_tfields = {}
	if use_facts:
		_add_facts(pkt, cls_stats)
	return pkt


## One turn of the conversation: the events since the last answer and one line per unit for where it stands now
## (built from the full state, so the numbers are the ones a first message would show).
func _turn_message(state: Dictionary, events: Array) -> Dictionary:
	var mine: Array = []
	for m in state["my_units"]:
		var line := "%s %s,%s %s" % [m["id"], m["q"], m["r"], m["soldiers"]]
		if m.has("fortified"):
			line += " fort %s" % m["fortified"]
		if str(m.get("terrain", "plains")) != "plains":
			line += " " + str(m["terrain"])
		var eta: Dictionary = m.get("eta", {})
		if eta.has("strike_enemy_hq") and str(m.get("class", "")) != "HQ":
			line += " eta_hq %s" % eta["strike_enemy_hq"]
		var reach: Array = []
		for v in m.get("vs", []):
			var parts := str(v).split(" ")
			if parts.size() > 2 and parts[1] == "eta" and int(parts[2]) <= 1:
				reach.append(v)
		if not reach.is_empty():
			line += " | " + "; ".join(reach)
		mine.append(line)
	var foes: Array = []
	for f in state["enemy_units"]:
		var line2 := "%s %s,%s %s" % [f["id"], f["q"], f["r"], f.get("troops", "?")]
		if f.has("fortified"):
			line2 += " fort %s" % f["fortified"]
		if f.has("last_seen_turn"):
			line2 += " seen t%s" % f["last_seen_turn"]
		if f.has("eta_strike_my_hq"):
			line2 += " eta_my_hq %s" % f["eta_strike_my_hq"]
		if not (f.get("can_strike_next", []) as Array).is_empty():
			line2 += " next " + ",".join(f["can_strike_next"])
		foes.append(line2)
	var msg := {"turn": state["turn"]}
	if state.has("turns_left"):
		msg["turns_left"] = state["turns_left"]
	msg["events"] = events
	msg["my_units"] = mine
	msg["enemy_units"] = foes
	if state.has("strongholds"):
		msg["strongholds"] = state["strongholds"]
	if state.has("mission"):
		msg["mission"] = state["mission"]
	return msg


## Every action since the last call, both sides, oldest first: within a round BLUE acts before RED.
func _events_since_last_call() -> Array:
	var rows: Array = []  # [event, index, own?]
	var mine: Array = action_log
	for i in range(int(_log_sent["own"]), mine.size()):
		rows.append([mine[i], i, true])
	if opponent != null:
		var opp: Array = opponent.get("action_log")
		for j in range(int(_log_sent["opp"]), opp.size()):
			if bool((opp[j] as Dictionary).get("seen_by_foe", false)):
				rows.append([opp[j], j, false])
	var own_last := side != "blue"  # in a round RED acts after BLUE
	rows.sort_custom(func(x, y):
		var kx := [int((x[0] as Dictionary).get("turn", 0)), 1 if bool(x[2]) == own_last else 0, int(x[1])]
		var ky := [int((y[0] as Dictionary).get("turn", 0)), 1 if bool(y[2]) == own_last else 0, int(y[1])]
		return kx < ky)
	# Own moves / rests / fortifies are left out (my_units holds where they are now); a BLUE unit's consecutive
	# moves in one turn become one line "from>to".
	var out: Array = []
	_last_raw = []
	var prev_move := {}  # the move event behind the last line, when it is one
	for row in rows:
		var e: Dictionary = row[0]
		var act := str(e.get("do", ""))
		if bool(row[2]) and not act in ["ATTACK", "ASSAULT", "ENTER_GARRISON"]:
			continue
		_last_raw.append(e)
		if act == "MOVE" and not prev_move.is_empty() and str(prev_move.get("unit", "")) == str(e.get("unit", "")) 				and int(prev_move.get("turn", 0)) == int(e.get("turn", 0)):
			var merged := e.duplicate()
			merged["from"] = prev_move.get("from", [])
			out[out.size() - 1] = _event_text(merged)
			prev_move = merged
			continue
		out.append(_event_text(e))
		prev_move = e if act == "MOVE" else {}
	return out


func _mark_events_sent() -> void:
	_log_sent["own"] = action_log.size()
	if opponent != null:
		_log_sent["opp"] = (opponent.get("action_log") as Array).size()


static func _event_text(e: Dictionary) -> String:
	var s := "t%d %s %s" % [int(e.get("turn", 0)), str(e.get("unit", "")), str(e.get("do", "")).to_lower()]
	match str(e.get("do", "")):
		"MOVE":
			var f: Array = e.get("from", [])
			var t: Array = e.get("to", [])
			if f.size() >= 2 and t.size() >= 2:
				s += " %d,%d>%d,%d" % [int(f[0]), int(f[1]), int(t[0]), int(t[1])]
		"ATTACK":
			var tgt := str(e.get("target", ""))
			s += " %s: dealt %d took %d" % [tgt, int(e.get("dealt", 0)), int(e.get("took", 0))]
			if int(e.get("fieldworks", 0)) > 0:
				s += " fieldworks -%d" % int(e.get("fieldworks", 0))
			if bool(e.get("destroyed", false)):
				s += ", %s destroyed" % tgt
			if bool(e.get("attacker_destroyed", false)):
				s += ", %s destroyed" % str(e.get("unit", ""))
		"ASSAULT", "ENTER_GARRISON":
			s += " " + str(e.get("target", ""))
	return s


## The game's own combat preview (as the attack tooltip shows it) for my unit attacking a foe from distance dist,
## taken over the foe's visible troops band (its exact count is hidden from RED): "dealt a-b taken c-d[ fw f]".
func _preview(my_id: String, foe_id: String, dist: int, band: Array) -> String:
	var a: Dictionary = manager.call("get_unit_by_id", my_id)
	var d: Dictionary = manager.call("get_unit_by_id", foe_id)
	if a.is_empty() or d.is_empty():
		return ""
	var walls := int(manager.call("get_fortress_hp", int(d.get("q", 0)), int(d.get("r", 0))))
	var counts: Array = band if not band.is_empty() else [int(d.get("soldier_count", 0))]
	var lo := [1 << 30, 1 << 30]
	var hi := [0, 0]
	var fw := 0
	for n in counts:
		var dd: Dictionary = d.duplicate()
		dd["soldier_count"] = maxi(1, int(n))
		var pv: Dictionary = CombatCalcCls.preview_attack(a, dd, maxi(1, dist), walls)
		lo[0] = mini(lo[0], int(pv.get("expected_enemy_casualties_min", 0)))
		hi[0] = maxi(hi[0], int(pv.get("expected_enemy_casualties_max", 0)))
		lo[1] = mini(lo[1], int(pv.get("expected_friendly_casualties_min", 0)))
		hi[1] = maxi(hi[1], int(pv.get("expected_friendly_casualties_max", 0)))
		fw = maxi(fw, int(CombatCalcCls.calculate_combat(a, dd, maxi(1, dist), walls, {}, 1.0).get("field_fortification_damage", 0)))
	var s := "dealt %d-%d taken %d-%d" % [lo[0], hi[0], lo[1], hi[1]]
	if fw > 0:
		s += " fw %d" % fw
	return s


## Field fortification HP left on a unit (0 = not fortified).
func _fort_hp(uid: String) -> int:
	var u: Dictionary = manager.call("get_unit_by_id", uid)
	if u.is_empty():
		return 0
	if bool(u.get("field_fortified", false)) or bool(u.get("fortified", false)) or int(u.get("field_fortification_hp", 0)) > 0:
		return maxi(1, int(u.get("field_fortification_hp", 0)))
	return 0


## Strongholds as the map shows them (an enemy garrison roster is not visible, so only own garrisons are listed).
func _strongholds_view() -> Array:
	var out: Array = []
	for sh in manager.call("get_all_strongholds"):
		var hexes: Array = []
		for h in sh.get_footprint():
			hexes.append([h.x, h.y])
		var row := {"id": str(sh.structure_id), "owner": str(sh.owner).to_upper(), "hexes": hexes,
			"walls": int(sh.fortification_hp), "walls_max": int(sh.fortification_hp_max), "breached": bool(sh.breached)}
		if str(sh.owner) == side:
			var ids: Array = []
			for g in sh.get_garrison_roster():
				ids.append(str((g as Dictionary).get("id", "")))
			row["garrison"] = ids
		out.append(row)
	return out


## Attack multipliers between the classes on this battlefield (rules, not a computation), every pair stated: one row
## per attacker class, "DEFENDER mult" in the column order of the row keys (a missing pair made every model stop to
## check that it meant 1.0).
static func _matchups(classes: Array) -> Dictionary:
	var out := {}
	for a in classes:
		var cells: Array = []
		for d in classes:
			var m := float(CombatCalcCls.get_matchup_mult(str(a).to_lower(), str(d).to_lower()))
			cells.append("%s %.2f" % [d, m])
		out[str(a)] = ", ".join(cells)
	return out


## An order as one short text for the packet ("ATTACK B_HQ_1", "MOVE 3,-4", "RAID B_ARC_1 back MY_HQ").
static func _order_text(o: Dictionary) -> String:
	var s := str(o.get("do", "HOLD")).to_upper()
	for k in ["target", "to", "back_to"]:
		if o.has(k):
			var v: Variant = o[k]
			var txt := "%d,%d" % [int(v[0]), int(v[1])] if v is Array and (v as Array).size() >= 2 else str(v)
			s += (" back " if k == "back_to" else " ") + txt
	return s


## Low and high soldier counts of a visible troops band ("약 150~300" -> [150, 300]; "약 450명" -> [450, 450]);
## [] when unknown.
static func _band(text: String) -> Array:
	var nums: Array = []
	var rx := RegEx.new()
	rx.compile("[0-9][0-9,]*")
	for m in rx.search_all(text):
		nums.append(int(m.get_string().replace(",", "")))
	if nums.is_empty():
		return []
	return [nums.min(), nums.max()]


static func _band_text(text: String) -> String:
	var b := _band(text)
	if b.is_empty():
		return "unknown"
	return str(b[0]) if b[0] == b[1] else "%d-%d" % [b[0], b[1]]


static func _mp_val(st: Dictionary) -> int:
	var v: Variant = st.get("mp", null)
	return 1 if v == null else maxi(1, int(v))


static func _eta(a: Vector2i, b: Vector2i, st: Dictionary, reach: int) -> int:
	return int(ceil(float(maxi(0, _hd(a, b) - reach)) / float(_mp_val(st))))


## How far a unit can strike this turn: movement + range (leaving fieldworks costs 1 movement point).
static func _strike_reach(row: Dictionary, st: Dictionary) -> int:
	return int(st.get("range", 1)) + _mp_val(st) - (1 if row.has("fortified") else 0)


func _add_facts(pkt: Dictionary, cls_stats: Dictionary) -> void:
	"""Facts only (no options, no selection): flat-ground movement at each unit's own speed; lists are complete."""
	var e_hq: Variant = null
	var o_hq: Variant = null
	for f in pkt["enemy_units"]:
		if str((f as Dictionary).get("class", "")) == "HQ":
			e_hq = Vector2i(int(f["q"]), int(f["r"]))
	for m in pkt["my_units"]:
		if str((m as Dictionary).get("class", "")) == "HQ":
			o_hq = Vector2i(int(m["q"]), int(m["r"]))
	for m in pkt["my_units"]:
		var p := Vector2i(int(m["q"]), int(m["r"]))
		var st: Dictionary = cls_stats.get(str(m["class"]), {})
		var eta := {}
		if e_hq != null:
			eta["strike_enemy_hq"] = _teta(p, e_hq, str(m["class"]), st, int(st.get("range", 1)))
		if o_hq != null and str(m["class"]) != "HQ":
			eta["reach_my_hq"] = _teta(p, o_hq, str(m["class"]), st, 1)
		m["eta"] = eta
		# Every enemy: turns until it is in this unit's range (+1 hex to leave fieldworks) and the game's preview,
		# from where it would actually strike (its current distance if already in range, else its full range).
		var leave := 1 if m.has("fortified") else 0
		var rng := int(st.get("range", 1))
		var vs: Array = []
		for f in pkt["enemy_units"]:
			var fp := Vector2i(int(f["q"]), int(f["r"]))
			var dist := _hd(p, fp)
			var e_turns := int(ceil(float(maxi(0, dist + leave - rng)) / float(_mp_val(st))))
			if _terrain_on():
				e_turns = _teta(p, fp, str(m["class"]), st, rng) + leave
			vs.append("%s eta %d %s" % [str(f["id"]), e_turns, _preview(str(m["id"]), str(f["id"]), dist if dist <= rng else rng,
				_band(str(f.get("troops", ""))))])
		m["vs"] = vs
	for f in pkt["enemy_units"]:
		var fp := Vector2i(int(f["q"]), int(f["r"]))
		var st2: Dictionary = cls_stats.get(str(f["class"]), {})
		if o_hq != null:
			f["eta_strike_my_hq"] = _teta(fp, o_hq, str(f["class"]), st2, int(st2.get("range", 1)))
		var reach2 := _strike_reach(f, st2)
		var tgts: Array = []
		for m in pkt["my_units"]:
			if _hd(fp, Vector2i(int(m["q"]), int(m["r"]))) <= reach2:
				tgts.append(m["id"])
		f["can_strike_next"] = tgts


func _terrain_on() -> bool:
	if not _terrain_aid.active() and shell != null and not bool(shell.get("is_step0_sandbox")):
		_terrain_aid.setup(shell.get("_battlefield"))
	return _terrain_aid.active()


## Eta with the map's movement costs on terrain maps (units in the way not counted), flat hex distance otherwise.
func _teta(a: Vector2i, b: Vector2i, cls: String, st: Dictionary, reach: int) -> int:
	if not _terrain_on():
		return _eta(a, b, st, reach)
	var key := "%d,%d,%s" % [b.x, b.y, "scout" if cls.to_lower() == "scout" else "std"]
	if not _tfields.has(key):
		_tfields[key] = _terrain_aid.field(b, cls)
	var e := TerrainCls.eta_from(_tfields[key], a, reach, _mp_val(st))
	return 99 if e < 0 else e


## First message: the hexes a player sees on the map that change how units move and what the mission is about.
func _terrain_list() -> Dictionary:
	var walls: Array = []
	var rivers: Array = []
	var bridges: Array = []
	for h in _terrain_aid.terrain.keys():
		var t := int(_terrain_aid.terrain[h])
		if t == 8:
			walls.append([h.x, h.y])
		elif _terrain_aid.river.has(h) and t != 6:
			rivers.append([h.x, h.y])
	for h in _terrain_aid.terrain.keys():
		if int(_terrain_aid.terrain[h]) == 6:
			for dv in AXIAL_DIRS:
				if _terrain_aid.river.has(h + dv):
					bridges.append([h.x, h.y])
					break
	walls.sort()
	rivers.sort()
	bridges.sort()
	return {"walls": walls, "rivers": rivers, "bridges": bridges}


## Which extra orders the rules allow this side; decided once so every call of a game sees the same prompt.
func _detect_verbs(obs: Dictionary) -> void:
	_verbs = {"RAID": false, "FORTIFY": false, "REST": false, "ASSAULT": false, "GARRISON": false,
		"BUILD_BASE": mission_rules != null}
	var morale_on := bool(EpisodeRuntimeCls.rules().get("morale", false))
	for f in obs.get("friendly_units", []):
		var fid := str((f as Dictionary).get("unit_id", ""))
		if str((f as Dictionary).get("class", "")).to_lower() == "cavalry":
			_verbs["RAID"] = true
		if bool(manager.call("can_unit_fortify", fid)):
			_verbs["FORTIFY"] = true
		if morale_on and bool(manager.call("can_unit_rest", fid)):
			_verbs["REST"] = true
	for sh in manager.call("get_all_strongholds"):
		if str(sh.owner) == side:
			_verbs["GARRISON"] = true
		else:
			_verbs["ASSAULT"] = true


func _system_prompt() -> String:
	var strikers := "ATTACK" + (" / RAID" if bool(_verbs.get("RAID", false)) else "") + (" / ASSAULT" if bool(_verbs.get("ASSAULT", false)) else "")
	var head := SYSTEM_HEAD % strikers
	if CommanderMissionCls.enabled():
		head = CommanderMissionCls.apply_prompt(head)
	if not CommanderMissionCls.enabled() and rout_rule and OS.get_environment("WATCH_NO_HQ_WIN") == "1":
		head = head.replace("WIN: destroy the BLUE HQ (immediate). LOSE: your HQ destroyed.",
			"WIN: destroy 60% of BLUE's units other than the HQ (immediate). LOSE: 60% of your units other than the HQ "
			+ "destroyed. An HQ is an ordinary unit in this battle: destroying one does not end it.")
		head = head.replace("If neither HQ has fallen by \"turn_limit\", you have", "If neither side has won by \"turn_limit\", you have")
	elif not CommanderMissionCls.enabled() and rout_rule:
		head = head.replace("If neither HQ has fallen by \"turn_limit\", you have", "If neither side has won by \"turn_limit\", you have")
		head = head.replace("LOSE: your HQ destroyed.", "You also WIN at once when 60% of BLUE's units "
			+ "other than the HQ are destroyed.\nLOSE: your HQ destroyed, or 60% of your units other than the HQ destroyed.")
	if mission_rules != null:  # mission maps: the mission's own win / lose / supply rules and the terrain rules
		head = head.replace("WIN: destroy the BLUE HQ (immediate). LOSE: your HQ destroyed. If neither HQ has fallen by \"turn_limit\", you have\nfailed; \"turns_left\" = RED turns remaining, this one included.",
			TerrainCls.mission_prompt(mission_rules.get("mission"), side))
		head = head.replace("Board: every hex within \"map_radius\" of (0, 0), flat ground. Axial (q, r); distance = (|dq| + |dr| + |dq + dr|) / 2.",
			TerrainCls.BOARD_TEXT)
	if side == "blue":
		# The prompt is written for RED; a BLUE commander gets the same text with the sides swapped (the turn
		# order itself does not change: each round BLUE acts first).
		head = head.replace("RED", "@SIDE@").replace("BLUE", "RED").replace("@SIDE@", "BLUE")
		head = head.replace("each round RED acts first, then BLUE.", "each round BLUE (you) acts first, then RED.")
	if OS.get_environment("WATCH_PREFER_FEWER_LOSSES").strip_edges() == "1":  # A/B: the wording removed 2026-10-06
		head = head.replace("this one included.", "this one included. Among winning plans prefer fewer losses.")
	for v in ["RAID", "FORTIFY", "REST", "ASSAULT", "GARRISON", "BUILD_BASE"]:
		if bool(_verbs.get(v, false)):
			head += "\n" + str(VERB_LINES[v])
	if use_facts:
		head += FACTS_PROMPT % OPENING_VS
	return CommanderMissionCls.canonical_text(head) if CommanderMissionCls.enabled() else head


## The first message's view of the state (2026-10-08): each own unit's "vs" keeps only the OPENING_VS enemies nearest
## to it, plus every enemy it can attack this turn (eta 0 or 1), so the opening grows with the number of units, not
## with its square (33 v 33 was 30k tokens). The full state (all pairs) still goes to "state" for code policies.
func _opening_view(state: Dictionary) -> Dictionary:
	var view := state.duplicate(true)
	var pos := {}
	for f in view.get("enemy_units", []):
		pos[str(f["id"])] = Vector2i(int(f["q"]), int(f["r"]))
	for m in view.get("my_units", []):
		if not (m as Dictionary).has("vs"):
			continue
		var p := Vector2i(int(m["q"]), int(m["r"]))
		var rows: Array = []
		for v in m["vs"]:
			var parts := str(v).split(" ")
			var fid := parts[0]
			rows.append([_hd(p, pos.get(fid, p)), int(parts[2]) if parts.size() > 2 else 99, fid, v])
		rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and str(a[2]) < str(b[2])))
		var keep: Array = []
		for i in rows.size():
			if i < OPENING_VS or int(rows[i][1]) <= 1:
				keep.append(rows[i][3])
		m["vs"] = keep
	return view


func _prune_orders(obs: Dictionary) -> void:
	"""Drop orders of units that are gone; a dead unit's stale ATTACK order made the Brain re-ask every turn."""
	var alive := {}
	for f in obs.get("friendly_units", []):
		alive[str((f as Dictionary).get("unit_id", "")).to_upper()] = true
	for uid in orders.keys():
		if not alive.has(str(uid)):
			orders.erase(uid)


static func _env_int(name: String, dflt: int) -> int:
	var v := OS.get_environment(name).strip_edges()
	return int(v) if v.is_valid_int() and int(v) > 0 else dflt


func _dg(uid: String) -> Dictionary:
	if not _digest.has(uid):
		_digest[uid] = {"atk": {}, "atk_n": 0, "dealt": 0, "took": 0, "hit": 0, "lost": 0, "fw": 0}
	return _digest[uid]


## Folds one kept turn into the digest: its events into the unit totals, its answer into the standing orders / plan.
func _fold(rec: Dictionary) -> void:
	for ev in rec["events"]:
		var e: Dictionary = ev
		var t := int(e.get("turn", 0))
		var a := _dg(str(e.get("unit", "")))
		match str(e.get("do", "")):
			"ATTACK":
				var tgt := str(e.get("target", ""))
				a["atk"][tgt] = int(a["atk"].get(tgt, 0)) + 1
				a["atk_n"] += 1
				a["dealt"] += int(e.get("dealt", 0))
				a["took"] += int(e.get("took", 0))
				var d := _dg(tgt)
				d["hit"] += 1
				d["lost"] += int(e.get("dealt", 0))
				d["fw"] += int(e.get("fieldworks", 0))
				if bool(e.get("destroyed", false)):
					d["dead"] = t
				if bool(e.get("attacker_destroyed", false)):
					a["dead"] = t
			"MOVE":
				if not a.has("from"):
					a["from"] = e.get("from", [])
					a["from_t"] = t
				a["to"] = e.get("to", [])
				a["to_t"] = t
			"FORTIFY":
				a["fort"] = t
	var doc: Variant = JSON.parse_string(str(rec["answer"]))
	if doc is Dictionary:
		var o: Variant = (doc as Dictionary).get("orders", {})
		if o is Dictionary:
			for uid in (o as Dictionary).keys():
				if o[uid] is Dictionary:
					_digest_orders[str(uid).to_upper()] = _order_text(o[uid])
		var pl := str((doc as Dictionary).get("plan", "")).strip_edges()
		if not pl.is_empty():
			_digest_plan = pl
			_digest_plan_turn = int(rec["turn"])
	_digest_upto = int(rec["turn"])


static func _hex_text(v: Variant) -> String:
	return "%d,%d" % [int(v[0]), int(v[1])] if v is Array and (v as Array).size() >= 2 else "?"


func _digest_text(my_hq: Variant) -> String:
	if _digest_upto <= 1:
		return ""
	var lines: Array = ["BATTLE DIGEST of turns 2-%d (computed by the game from every event you saw; the turn messages below continue from turn %d):" % [_digest_upto, _digest_upto + 1]]
	var ids: Array = _digest.keys()
	var own := "R_" if side == "red" else "B_"  # enemy units first, then mine
	ids.sort_custom(func(x, y): return ("1" if str(x).begins_with(own) else "0") + str(x) < ("1" if str(y).begins_with(own) else "0") + str(y))
	for uid in ids:
		var d: Dictionary = _digest[uid]
		var parts: Array = []
		if d.has("from"):
			var mv := "moved t%d-t%d %s>%s" % [int(d["from_t"]), int(d["to_t"]), _hex_text(d["from"]), _hex_text(d["to"])]
			if my_hq != null and d["from"] is Array and d["to"] is Array and (d["from"] as Array).size() >= 2 and (d["to"] as Array).size() >= 2:
				mv += " (to my HQ %d>%d hexes)" % [_hd(Vector2i(int(d["from"][0]), int(d["from"][1])), my_hq),
					_hd(Vector2i(int(d["to"][0]), int(d["to"][1])), my_hq)]
			parts.append(mv)
		if int(d["atk_n"]) > 0:
			var tg: Array = []
			for k in (d["atk"] as Dictionary).keys():
				tg.append("%s x%d" % [k, int(d["atk"][k])] if int(d["atk"][k]) > 1 else str(k))
			parts.append("attacked %d times: %s (killed %d, lost %d)" % [int(d["atk_n"]), ", ".join(tg), int(d["dealt"]), int(d["took"])])
		if int(d["hit"]) > 0:
			parts.append("was hit %d times (lost %d%s)" % [int(d["hit"]), int(d["lost"]), (", fieldworks -%d" % int(d["fw"])) if int(d["fw"]) > 0 else ""])
		if d.has("fort"):
			parts.append("fortified t%d" % int(d["fort"]))
		if d.has("dead"):
			parts.append("destroyed t%d" % int(d["dead"]))
		if not parts.is_empty():
			lines.append("%s: %s" % [uid, "; ".join(parts)])
	var ord: Array = []
	for uid in _digest_orders.keys():
		ord.append("%s %s" % [uid, _digest_orders[uid]])
	if not ord.is_empty():
		lines.append("Your orders standing after turn %d: %s" % [_digest_upto, "; ".join(ord)])
	if not _digest_plan.is_empty():
		lines.append("Your plan (since turn %d): %s" % [_digest_plan_turn, _digest_plan])
	return "\n".join(lines)


func _ask_brain(obs: Dictionary) -> void:
	if _verbs.is_empty():
		_detect_verbs(obs)
	var events := _events_since_last_call()
	_history.append_array(events)
	_mark_events_sent()
	var raw := _last_raw.duplicate()
	var recent := _env_int("WATCH_RECENT_TURNS", RECENT_TURNS_DEFAULT)
	if _turns.size() > recent and (_turns.size() >= _env_int("WATCH_COMPACT_AT", COMPACT_AT_DEFAULT) or _plan_changed):
		for rec in _turns.slice(0, _turns.size() - recent):
			_fold(rec)
		_turns = _turns.slice(_turns.size() - recent)
	var budget := _env_int("WATCH_FOLD_CHARS", FOLD_CHARS_DEFAULT)
	var kept := 0
	for rec in _turns:
		kept += str(rec["msg"]).length() + str(rec["answer"]).length()
	while _turns.size() > 1 and kept > budget:
		var old: Dictionary = _turns.pop_front()
		kept -= str(old["msg"]).length() + str(old["answer"]).length()
		_fold(old)
	_plan_changed = false
	var state := _packet(obs, "start of battle" if _opening.is_empty() else "")
	var my_hq: Variant = null
	for m in state["my_units"]:
		if str((m as Dictionary).get("class", "")) == "HQ":
			my_hq = Vector2i(int(m["q"]), int(m["r"]))
	var digest := _digest_text(my_hq)
	var user_text := JSON.stringify(_opening_view(state) if _opening.is_empty() else _turn_message(state, events), "", false)
	var msgs: Array = [{"role": "system", "content": _system_prompt()}]
	msgs.append_array(_opening)
	for i in _turns.size():
		var rec: Dictionary = _turns[i]
		msgs.append({"role": "user", "content": (digest + "\n\n" + str(rec["msg"])) if i == 0 and not digest.is_empty() else str(rec["msg"])})
		msgs.append({"role": "assistant", "content": str(rec["answer"])})
	var sent_text := (digest + "\n\n" + user_text) if _turns.is_empty() and not digest.is_empty() else user_text
	msgs.append({"role": "user", "content": sent_text})
	if CommanderMissionCls.enabled():
		for message in msgs:
			message["content"] = CommanderMissionCls.canonical_text(str(message["content"]))
	var body := JSON.stringify({"model": "rl_policy", "messages": msgs, "state": state})
	var tag := OS.get_environment("WATCH_SPEC_TAG").strip_edges()
	var headers := PackedStringArray(["Content-Type: application/json",
		"X-Episode-Spec-Path: commander_%s.json" % tag, "X-Episode-Id: " + EpisodeRuntimeCls.episode_id()])
	stats["calls"] += 1
	if _http.request(cmd_url, headers, HTTPClient.METHOD_POST, body) != OK:
		strict_fault_info = {"code": "CMD_HTTP", "detail": "request failed to start", "kind": "COMMAND", "turn": obs.get("turn")}
		return
	var res: Array = await _http.request_completed
	var text := ""
	if int(res[1]) == 200:
		var resp: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
		if resp is Dictionary:
			text = str(((((resp as Dictionary).get("choices", [{}]) as Array)[0] as Dictionary).get("message", {}) as Dictionary).get("content", ""))
	var doc: Variant = JSON.parse_string(text.strip_edges())
	if not doc is Dictionary or not (doc as Dictionary).get("orders", {}) is Dictionary:
		strict_fault_info = {"code": "CMD_JSON", "detail": text.left(200), "kind": "COMMAND", "turn": obs.get("turn"), "side": side.to_upper()}
		return
	stats["decisions"] += 1
	var turn := int(obs.get("turn", 0))
	if _opening.is_empty():
		_opening = [{"role": "user", "content": user_text}, {"role": "assistant", "content": text.strip_edges()}]
	else:
		_turns.append({"turn": turn, "msg": user_text, "answer": text.strip_edges(), "events": raw})
	var new_orders: Dictionary = (doc as Dictionary).get("orders", {})
	var new_plan := str((doc as Dictionary).get("plan", "")).strip_edges().left(400)
	if not new_plan.is_empty() and new_plan != plan_text:
		_plan_changed = not plan_text.is_empty()
		plan_text = new_plan
		plan_turn = turn
	else:
		new_plan = ""
	var ord: Array = []
	for uid in new_orders.keys():
		var o: Variant = new_orders[uid]
		if o is Dictionary:
			orders[str(uid).to_upper()] = o
			ord.append("%s %s" % [str(uid).to_upper(), _order_text(o)])
	_prune_orders(obs)
	if (doc as Dictionary).has("skipped"):
		# The Brain passed (data collection: its request ran out of time); every order stands.
		_history.append("t%d %s: no answer (%s), orders stand" % [turn, side.to_upper(), str((doc as Dictionary)["skipped"])])
	elif not ord.is_empty() or not new_plan.is_empty():
		var line := "t%d %s" % [turn, side.to_upper()]
		if not ord.is_empty():
			line += " orders: " + "; ".join(ord)
		if not new_plan.is_empty():
			line += " | plan: " + new_plan
		_history.append(line)
	if _trace or not ord.is_empty():
		print("[Commander] t%d changed=%d plan=%s" % [turn, ord.size(), plan_text.left(120)])


# ------------------------------------------------------------------ execution
## Hex of an order reference: [q, r], a BLUE or RED unit id, "ENEMY_HQ" (also the legacy "HQ") or "MY_HQ".
func _pos_of(obs: Dictionary, ref: Variant) -> Variant:
	if ref is Array and (ref as Array).size() >= 2:
		return Vector2i(int(ref[0]), int(ref[1]))
	var key := str(ref).to_upper()
	var pools := {"known_enemy_units": key in ["HQ", "ENEMY_HQ"], "friendly_units": key == "MY_HQ"}
	for pool in pools.keys():
		for row_val in obs.get(pool, []):
			var row: Dictionary = row_val
			if str(row.get("unit_id", "")).to_upper() == key or (bool(pools[pool]) and str(row.get("class", "")).to_upper() == "HQ"):
				return Vector2i(int(row.get("q", 0)), int(row.get("r", 0)))
	return null


func _target_id(obs: Dictionary, ref: Variant) -> String:
	var key := str(ref).to_upper()
	for e in obs.get("known_enemy_units", []):
		var row: Dictionary = e
		if str(row.get("unit_id", "")).to_upper() == key or (key in ["HQ", "ENEMY_HQ"] and str(row.get("class", "")).to_upper() == "HQ"):
			return str(row.get("unit_id", ""))
	return ""


## Footprint hex of a stronghold nearest to the unit (null when unknown).
func _stronghold_hex(sid: String, unit_pos: Vector2i) -> Variant:
	for sh in manager.call("get_all_strongholds"):
		if str(sh.structure_id).to_upper() != sid:
			continue
		var best: Variant = null
		var best_d := 1 << 30
		for h in sh.get_footprint():
			var d := _hd(unit_pos, h)
			if d < best_d:
				best_d = d
				best = h
		return best
	return null


func _choose(uid: String, cands: Array, obs: Dictionary, unit_pos: Vector2i) -> Dictionary:
	var o: Dictionary = orders.get(uid, {"do": "HOLD"})
	var kind := str(o.get("do", "HOLD")).to_upper()
	var moves: Array = []
	var typed := {}
	for c in cands:
		var at := str((c as Dictionary).get("action_type", ""))
		if at == "MOVE":
			moves.append(c)
		else:
			if not typed.has(at):
				typed[at] = []
			(typed[at] as Array).append(c)
	var wait := _wait_candidate(cands)
	match kind:
		"ATTACK", "RAID":
			var tid := _target_id(obs, o.get("target", ""))
			for c in typed.get("ATTACK", []):
				if str((c as Dictionary).get("target_id", "")) == tid:
					return c
			# RAID: once it has struck this turn (cavalry keeps its remaining movement), fall back.
			if kind == "RAID" and bool((manager.call("get_unit_by_id", uid) as Dictionary).get("has_attacked", false)):
				return _approach(moves, _pos_of(obs, o.get("back_to", "MY_HQ")), unit_pos, wait, obs, uid)
			return _approach(moves, _pos_of(obs, o.get("target", "")), unit_pos, wait, obs, uid)
		"MOVE":
			return _approach(moves, _pos_of(obs, o.get("to", "")), unit_pos, wait, obs, uid)
		"ASSAULT", "GARRISON":
			var sid := str(o.get("target", "")).to_upper()
			var at2 := "ASSAULT" if kind == "ASSAULT" else "ENTER_GARRISON"
			for c in typed.get(at2, []):
				if str((c as Dictionary).get("stronghold_id", "")).to_upper() == sid:
					return c
			return _approach(moves, _stronghold_hex(sid, unit_pos), unit_pos, wait, obs, uid)
		"FORTIFY", "REST":
			var lst: Array = typed.get(kind, [])
			return lst[0] if not lst.is_empty() else wait
		"BUILD_BASE":
			if mission_rules != null and bool((mission_rules.call("can_build_base", uid) as Dictionary).get("ok", false)):
				return {"candidate_id": "BUILD_BASE|" + uid, "unit_id": uid, "action_type": "BUILD_BASE"}
			return wait
	# HOLD (and anything unknown): stay. Attacking is solely the Brain's decision (user rule).
	return wait


func _approach(moves: Array, dest: Variant, unit_pos: Vector2i, wait: Dictionary, obs: Dictionary, uid: String) -> Dictionary:
	if dest != null:
		var best := _path_move(moves, dest, unit_pos, obs, uid)
		if not best.is_empty():
			return best
	return wait


## The legal move that leaves the unit the fewest steps from dest along open hexes (BFS out from dest; every other
## unit blocks, as in the game). A move must shorten that path; when dest cannot be reached at all, the move that
## gets closest in hex distance. This replaced the straight-line pick, which stalled behind any unit in the way.
func _path_move(moves: Array, dest: Vector2i, unit_pos: Vector2i, obs: Dictionary, uid: String) -> Dictionary:
	var radius := int(((obs.get("board", {}) as Dictionary).get("dimensions", {}) as Dictionary).get("radius", 64))
	var blocked := {}
	var my_cls := ""
	for pool in ["friendly_units", "known_enemy_units"]:
		for row_val in obs.get(pool, []):
			var row: Dictionary = row_val
			if str(row.get("unit_id", "")) != uid:
				blocked[Vector2i(int(row.get("q", 0)), int(row.get("r", 0)))] = true
			else:
				my_cls = str(row.get("class", ""))
	if _terrain_on():  # terrain maps: the legal move that leaves the least movement cost to dest
		var fm: Dictionary = _terrain_aid.field(dest, my_cls, blocked)
		var tbest := {}
		var tbest_c := float(fm.get(unit_pos, TerrainCls.INF))
		var tbest_h := _hd(unit_pos, dest)
		for c in moves:
			var dv: Array = (c as Dictionary).get("destination", [])
			if dv.size() < 2:
				continue
			var p := Vector2i(int(dv[0]), int(dv[1]))
			var cc := float(fm.get(p, TerrainCls.INF))
			var hh := _hd(p, dest)
			if cc < tbest_c or (cc == tbest_c and cc >= TerrainCls.INF and hh < tbest_h):
				tbest_c = cc
				tbest_h = hh
				tbest = c
		return tbest
	var steps := {dest: 0}
	var queue: Array = [dest]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for d in AXIAL_DIRS:
			var nxt: Vector2i = cur + d
			if steps.has(nxt) or blocked.has(nxt) or _hd(nxt, Vector2i.ZERO) > radius:
				continue
			steps[nxt] = int(steps[cur]) + 1
			queue.append(nxt)
	var best := {}
	var best_s := int(steps.get(unit_pos, 1 << 30))
	var best_h := _hd(unit_pos, dest)
	for c in moves:
		var dv: Array = (c as Dictionary).get("destination", [])
		if dv.size() < 2:
			continue
		var p := Vector2i(int(dv[0]), int(dv[1]))
		var s := int(steps.get(p, 1 << 30))
		var h := _hd(p, dest)
		if s < best_s or (s == best_s and s >= 1 << 30 and h < best_h):
			best_s = s
			best_h = h
			best = c
	return best


## BUILD_BASE goes to MissionRules (the authority); the HQ holds afterwards.
func _build_base(uid: String) -> Dictionary:
	var res: Dictionary = mission_rules.call("build_base", uid) if mission_rules != null else {"success": false}
	if bool(res.get("success", false)):
		orders.erase(uid)
		action_log.append({"turn": int(manager.call("get_current_turn")), "side": side.to_upper(), "unit": uid,
			"do": "BUILD_BASE", "seen_by_foe": true})
	return res


func _note(uid: String, note: String) -> void:
	var lst: Array = _last_results.get(uid, [])
	lst.append(note)
	_last_results[uid] = lst


func run_red_phase() -> Dictionary:
	if not mount_ready or _busy:
		var unavailable := {"ok": false, "status": "NOT_READY" if not mount_ready else "BUSY", "actions": 0}
		phase_finished.emit(unavailable)
		return unavailable
	_busy = true
	var obs := _build_observation()
	_prune_orders(obs)
	await _ask_brain(obs)
	if not strict_fault_info.is_empty():
		_busy = false
		var faulted := {"ok": false, "status": "STRICT_FAULT", "actions": 0}
		phase_finished.emit(faulted)
		return faulted
	_last_results = {}
	# A fortified unit is resolved for the turn queue: if its order needs it to leave, dismantle first (1 MP).
	for f in obs.get("friendly_units", []):
		var fid := str((f as Dictionary).get("unit_id", ""))
		var fo: Dictionary = orders.get(fid.to_upper(), {})
		if str(fo.get("do", "")).to_upper() in LEAVE_FORT and bool(manager.call("can_dismantle_fortification", fid)):
			var dres: Dictionary = await _execute_fresh({"candidate_id": "DISMANTLE|" + fid, "unit_id": fid, "action_type": "DISMANTLE"})
			if bool(dres.get("success", false)):
				_note(fid, "DISMANTLE")
	var steps := 0
	var after_id := ""
	while steps < MAX_ACTIONS_PER_PHASE and not _battle_over():
		var unit: Dictionary = enumerator.call("next_unresolved_unit", after_id)
		if unit.is_empty():
			break
		var uid := str(unit.get("id", ""))
		var pool: Dictionary = enumerator.call("enumerate_for_unit", uid)
		if bool(pool.get("terminal", false)) or _battle_over():
			break
		var cands := _authorized_candidates(pool.get("candidates", []))
		if cands.is_empty():
			break
		obs = _build_observation()
		var pos := Vector2i(int(unit.get("q", 0)), int(unit.get("r", 0)))
		for f in obs.get("friendly_units", []):
			if str((f as Dictionary).get("unit_id", "")) == uid:
				pos = Vector2i(int((f as Dictionary).get("q", 0)), int((f as Dictionary).get("r", 0)))
		var cand := _choose(uid, cands, obs, pos)
		if cand.is_empty():
			cand = _wait_candidate(cands)
		if cand.is_empty():
			break
		var result: Dictionary
		if str(cand.get("action_type", "")) == "BUILD_BASE":
			result = _build_base(uid)
		else:
			result = await _execute_fresh(cand)
		if not bool(result.get("success", false)):
			var w := _wait_candidate(cands)
			if w.is_empty() or w.get("candidate_id", "") == cand.get("candidate_id", ""):
				break
			result = await _execute_fresh(w)
			cand = w
		var at := str(cand.get("action_type", "WAIT"))
		stats["moves" if at == "MOVE" else ("attacks" if at in ["ATTACK", "ASSAULT"] else "waits")] += 1
		var note := at
		if at == "ATTACK":
			note += " %s dealt %d took %d" % [str(cand.get("target_id", "")), int(result.get("defender_casualties", 0)),
				int(result.get("attacker_casualties", 0))]
			if int(result.get("field_fortification_damage", 0)) > 0:
				note += " fieldworks -%d" % int(result.get("field_fortification_damage", 0))
			if bool(result.get("defender_destroyed", false)):
				note += " destroyed"
		elif at == "MOVE":
			note += " " + str(cand.get("destination", []))
		elif at == "ASSAULT" or at == "ENTER_GARRISON":
			note += " " + str(cand.get("stronghold_id", ""))
		_note(uid, note)
		if _trace:
			print("[Commander] t%d %s %s (%s)" % [int(obs.get("turn", 0)), uid, note, _order_text(orders.get(uid, {"do": "HOLD"}))])
		steps += 1
		last_action = note + " " + uid
		if bool(enumerator.call("is_unit_id_resolved", uid)):
			after_id = uid
		await get_tree().create_timer(0.02).timeout
	_busy = false
	last_phase_result = {"ok": true, "status": "COMMANDER", "actions": steps, "terminal": _battle_over(), "last_action": last_action}
	phase_finished.emit(last_phase_result.duplicate(true))
	return last_phase_result.duplicate(true)
