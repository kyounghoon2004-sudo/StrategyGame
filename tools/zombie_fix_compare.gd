extends SceneTree

## Behavioral delta of ZOMBIE_FORT_FIX_V1 (tool-only). Runs the frozen pre-fix
## calculator and the live calculator over a grid and asserts that outputs
## differ ONLY when (a) the defender is field-fortified and (b) the pre-fix
## per-hit cap was binding (uncapped strike > def_troops). Also asserts the
## fix never lowers damage and that unfortified / fortress results are
## byte-identical. Prints DELTA_* lines; exit 0 = contained delta.

const NewCls = preload("res://scripts/combat/combat_calculator.gd")
var OldCls = load("res://artifacts/zombie_fix_v1/combat_calculator_PRE_FIX.gd")

const CLASSES := ["infantry", "archer", "cavalry", "spearman", "scout", "siege", "conscript", "hq"]
const TROOPS := [1, 2, 5, 12, 30, 100, 250, 450]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var total := 0
	var changed := 0
	var illegal := 0
	var lowered := 0
	var examples: Array = []
	for ac in CLASSES:
		for dc in CLASSES:
			for at in TROOPS:
				for dt in TROOPS:
					for fort in [false, true]:
						for dist in [1, 2]:
							for morale in [100.0, 35.0]:
								var a := {"class": ac, "soldier_count": at, "morale": morale}
								var d := {"class": dc, "soldier_count": dt, "morale": morale}
								if fort:
									d["field_fortified"] = true
									d["field_fortification_hp"] = 180
								var o: Dictionary = OldCls.calculate_combat(a, d, dist, 0, {}, 1.0)
								var n: Dictionary = NewCls.calculate_combat(a, d, dist, 0, {}, 1.0)
								total += 1
								if JSON.stringify(o) == JSON.stringify(n):
									continue
								changed += 1
								var strike := maxi(1, roundi(float(n["effective_attack"]) * 0.60))
								if not fort or strike <= dt:
									illegal += 1
									if examples.size() < 5:
										examples.append({"a": a, "d": d, "dist": dist, "old": o["defender_casualties"], "new": n["defender_casualties"]})
								if int(n["field_fortification_damage"]) < int(o["field_fortification_damage"]) \
										or int(n["defender_casualties"]) < int(o["defender_casualties"]):
									lowered += 1
	# fortress walls path must be untouched
	var fw_same := true
	for ac2 in CLASSES:
		var a2 := {"class": ac2, "soldier_count": 300, "morale": 100.0}
		var d2 := {"class": "infantry", "soldier_count": 5, "morale": 100.0}
		if JSON.stringify(OldCls.calculate_combat(a2, d2, 1, 900, {}, 1.0)) != JSON.stringify(NewCls.calculate_combat(a2, d2, 1, 900, {}, 1.0)):
			fw_same = false
	print("DELTA_TOTAL cases=%d changed=%d outside_contract=%d lowered_damage=%d fortress_path_identical=%s" % [
		total, changed, illegal, lowered, str(fw_same)])
	if not examples.is_empty():
		print("DELTA_EXAMPLES %s" % JSON.stringify(examples))
	var ok := illegal == 0 and lowered == 0 and fw_same
	print("DELTA_RESULT %s" % ("CONTAINED" if ok else "UNEXPECTED"))
	quit(0 if ok else 1)
