extends SceneTree

## Live Korean semantic benchmark for the tiny frontend (REQUIRES Ollama +
## semantic tag; NO scene). Drives the game prompt (Step7SemanticFrontend)
## against the SEMANTIC role model, then normalizes via the game path
## (envelope -> intent -> CommandIR v2). Measures route accuracy, IR
## validity, scope-AST validity, evidence binding, fallback taxonomy,
## minimal-pair routing, and per-case latency.
## Compares a small subset against the TACTICAL role model on the SAME
## prompt (model-size delta, same input).
## Usage: Godot --headless --path <proj> -s tools/step7_semantic_live_check.gd
## Evidence: tools/.audit_semantic_live.json. Exit 0 = harness completed.

const OUT := "D:/Game development/Demon slayer/StrategyGame/tools/.audit_semantic_live.json"
const FrontendScript = preload("res://scripts/step7/step7_semantic_frontend.gd")
const EnvelopeScript = preload("res://scripts/step7/step7_semantic_envelope.gd")
const CommandIRScript = preload("res://scripts/step7/step7_command_ir.gd")
const AlgebraScript = preload("res://scripts/step7/step7_scope_algebra.gd")
const ConfigScript = preload("res://scripts/step7/step7_ollama_config.gd")

const ENDPOINT := "http://127.0.0.1:11434"
const CALL_TIMEOUT := 90.0
## Subset of case indices re-run on the TACTICAL model (same prompt).
const LARGE_IDX := [0, 3, 9, 12, 20, 30]

var _cases: Array = []


func _init() -> void:
	call_deferred("_run")


func _c(text: String, mode: String, actions: Array = [], relation: String = "",
		classes: Array = [], regions: Array = []) -> Dictionary:
	return {"text": text, "mode": mode, "actions": actions,
		"relation": relation, "classes": classes, "regions": regions}


func _build_cases() -> void:
	_cases = [
		_c("전군 진격", "COMMAND", ["ADVANCE"]),
		_c("전군 대기", "COMMAND", ["HOLD"]),
		_c("기병 전진", "COMMAND", ["ADVANCE"], "", ["CAVALRY"]),
		_c("정찰병 깊게 정찰", "COMMAND", ["RECON"], "", ["SCOUT"]),
		_c("정찰병은 전진하고 나머지는 대기", "COMMAND", ["ADVANCE", "HOLD"], "PARALLEL"),
		_c("정찰병 다 전진", "COMMAND", ["ADVANCE"], "", ["SCOUT"]),
		_c("정찰병 제외하고 모두 대기", "COMMAND", ["HOLD"]),
		_c("보병과 창병은 전진하고 궁병은 대기", "COMMAND", ["ADVANCE", "HOLD"], "PARALLEL"),
		_c("좌익은 대기하고 우익은 전진", "COMMAND", ["HOLD", "ADVANCE"], "PARALLEL"),
		_c("기병 전진 말고 대기", "COMMAND", ["HOLD"], "", ["CAVALRY"]),
		_c("기병은 깊게 들어가지 마", "COMMAND", ["HOLD"], "", ["CAVALRY"]),
		_c("기병을 전진시키는 게 좋을까?", "TACTICAL_ADVICE"),
		_c("정찰병을 어디로 보내는 게 좋을까?", "TACTICAL_ADVICE"),
		_c("현재 좌익 상황이 어때?", "INFORMATION"),
		_c("적 기병이 어디에 보여?", "INFORMATION"),
		_c("적 기병이 어디로 올 것 같아?", "TACTICAL_ADVICE"),
		_c("지금 어느 쪽을 밀어야 할까?", "TACTICAL_ADVICE"),
		_c("지금 어디를 밀어야 할까?", "TACTICAL_ADVICE"),
		_c("좌익은 버티고 우익을 미는 게 나을까?", "TACTICAL_ADVICE"),
		_c("정찰병을 깊게 보내는 게 좋을까?", "TACTICAL_ADVICE"),
		_c("우익 밀어", "COMMAND", ["ADVANCE"]),
		_c("우익을 미는 게 나을까?", "TACTICAL_ADVICE"),
		_c("기병 대기", "COMMAND", ["HOLD"], "", ["CAVALRY"]),
		_c("기병이 대기 중이야?", "INFORMATION"),
		_c("적 기병 위치 알려줘", "INFORMATION"),
		_c("전군 진격하라", "COMMAND", ["ADVANCE"]),
		_c("좌익 기병 전진", "COMMAND", ["ADVANCE"], "", ["CAVALRY"]),
		_c("보병은 먼저 전진하고 그다음 대기", "COMMAND", ["ADVANCE", "HOLD"], "SEQUENCE"),
		_c("좌익은 전진하고 기병은 대기", "COMMAND", ["ADVANCE", "HOLD"], "PARALLEL"),
		_c("아까 말한 부대만 전진", "COMMAND", ["ADVANCE"]),
		_c("그렇게 해", "COMMAND", ["ADVANCE"]),
		_c("이 부대 대기", "COMMAND", ["HOLD"]),
		_c("기병 전진하는 게 좋을까?", "TACTICAL_ADVICE"),
		_c("정찰병 깊게 정찰", "COMMAND", ["RECON"], "", ["SCOUT"]),
		_c("정찰병을 깊게 보내는 게 좋을까?", "TACTICAL_ADVICE"),
		_c("좌익 기병은 전진하고 나머지 기병은 대기", "COMMAND", ["ADVANCE", "HOLD"], "PARALLEL"),
		_c("궁병은 대기하고 나머지는 전진", "COMMAND", ["HOLD", "ADVANCE"], "PARALLEL"),
		_c("양쪽 기병 전진", "COMMAND", ["ADVANCE"], "", ["CAVALRY"]),
		_c("창병 천천히 전진", "COMMAND", ["ADVANCE"], "", ["SPEARMAN"]),
		_c("보병 전열을 유지하며 전진", "COMMAND", ["ADVANCE"], "", ["INFANTRY"]),
		_c("수고했어", "CONVERSATION"),
		_c("기병 최대한 빠르게 전진", "COMMAND", ["ADVANCE"], "", ["CAVALRY"]),
		_c("좌익 보병과 창병 전진", "COMMAND", ["ADVANCE"]),
		_c("공성대는 안전하게 따라와", "COMMAND", ["ADVANCE"], "", ["SIEGE"]),
	]


func _chat(model: String, messages: Array, num_predict: int, num_ctx: int) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var http := HTTPRequest.new()
	http.timeout = CALL_TIMEOUT + 10.0
	http.body_size_limit = 1048576
	root.add_child(http)
	var payload := {"model": model, "stream": false, "format": "json",
		"think": false,
		"options": {"temperature": 0.0, "num_predict": num_predict, "num_ctx": num_ctx},
		"messages": messages}
	var err := http.request(ENDPOINT + "/api/chat",
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		http.queue_free()
		return {"ok": false, "code": "OFFLINE", "latency_ms": Time.get_ticks_msec() - t0}
	var res: Array = await http.request_completed
	var lat := Time.get_ticks_msec() - t0
	http.queue_free()
	if res.size() < 4:
		return {"ok": false, "code": "BAD_RESPONSE", "latency_ms": lat}
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": "OFFLINE", "latency_ms": lat}
	if int(res[1]) == 404:
		return {"ok": false, "code": "MODEL_MISSING", "latency_ms": lat}
	if int(res[1]) < 200 or int(res[1]) >= 300:
		return {"ok": false, "code": "HTTP_ERROR", "latency_ms": lat}
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if not parsed is Dictionary:
		return {"ok": false, "code": "BAD_RESPONSE", "latency_ms": lat}
	var msg: Variant = (parsed as Dictionary).get("message", {})
	return {"ok": true, "content": str((msg as Dictionary).get("content", "")),
		"latency_ms": lat}


func _ps_vram() -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	root.add_child(http)
	var err := http.request(ENDPOINT + "/api/ps", PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {}
	var res: Array = await http.request_completed
	http.queue_free()
	if res.size() < 4 or int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {}
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if not parsed is Dictionary:
		return {}
	var out := {}
	for m in ((parsed as Dictionary).get("models", []) as Array):
		if m is Dictionary:
			out[str((m as Dictionary).get("name", ""))] = {
				"size_vram": int((m as Dictionary).get("size_vram", 0)),
				"context_length": int((m as Dictionary).get("context_length", 0))}
	return out


func _score_case(cs: Dictionary, h: Dictionary) -> Dictionary:
	var s := {"text": str(cs.get("text", "")), "expect_mode": str(cs.get("mode", ""))}
	if not bool(h.get("ok", false)):
		s["route_ok"] = false
		s["ir_ok"] = false
		s["fallback_reason"] = str(h.get("fallback_reason", ""))
		s["why"] = str(h.get("why", ""))
		return s
	var env: Dictionary = h.get("envelope", {})
	var ir: Dictionary = h.get("ir", {})
	s["mode"] = str(env.get("mode", ""))
	s["route_ok"] = str(env.get("mode", "")) == str(cs.get("mode", ""))
	s["ir_ok"] = true
	s["confidence"] = float(env.get("confidence", 0.0))
	s["fingerprint"] = str(ir.get("fingerprint", ""))
	var cov: Dictionary = ir.get("coverage", {})
	s["coverage_ratio"] = float(cov.get("coverage_ratio", 0.0))
	s["unbound"] = (cov.get("unbound", []) as Array).size()
	var sem: Array = (cov.get("semantic_uncovered", []) as Array).duplicate()
	s["sem_uncovered"] = sem.map(func(e: Dictionary) -> String: return str(e.get("token", "?")))
	# Scope AST structural validity per order.
	var ast_ok := true
	for o in (ir.get("orders", []) as Array):
		var ex: Dictionary = CommandIRScript.effective_scope_expr(o)
		if ex.is_empty():
			var leg: Dictionary = AlgebraScript.compile_legacy((o as Dictionary).get("scope", {}))
			if not bool(leg.get("ok", false)):
				ast_ok = false
		elif not bool(AlgebraScript.validate_expr(ex).get("ok", false)):
			ast_ok = false
	s["scope_ast_ok"] = ast_ok
	# Expected actions / relation where specified.
	var exp_a: Array = cs.get("actions", [])
	if not exp_a.is_empty():
		var got_a: Array = []
		for o2 in (ir.get("orders", []) as Array):
			got_a.append(str((o2 as Dictionary).get("action", "")))
		s["actions"] = got_a
		s["actions_ok"] = got_a == exp_a
	if not str(cs.get("relation", "")).is_empty():
		s["relation"] = str(ir.get("relation", ""))
		s["relation_ok"] = str(ir.get("relation", "")) == str(cs.get("relation", ""))
	var exp_c: Array = cs.get("classes", [])
	if not exp_c.is_empty() and not (ir.get("orders", []) as Array).is_empty():
		var o0: Dictionary = (ir.get("orders", []) as Array)[0]
		s["class"] = str(((o0.get("scope", {}) as Dictionary).get("class", "")))
		s["class_ok"] = str(((o0.get("scope", {}) as Dictionary).get("class", ""))) in exp_c
	return s


func _run() -> void:
	_build_cases()
	var sem_tag := ConfigScript.semantic_model()
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--sem-tag="):
			sem_tag = str(a).trim_prefix("--sem-tag=").strip_edges()
	var tac_tag := ConfigScript.model()
	print("[live] semantic=%s tactical=%s cases=%d" % [sem_tag, tac_tag, _cases.size()])
	var vram_before: Dictionary = await _ps_vram()
	print("[live] vram_before=" + JSON.stringify(vram_before))
	var results: Array = []
	var lat_simple: Array = []
	var lat_multi: Array = []
	for i in range(_cases.size()):
		var cs: Dictionary = _cases[i]
		var messages: Array = FrontendScript.build_messages(str(cs.get("text", "")),
			FrontendScript.build_ctx({}, {}, "", ""))
		var r: Dictionary = await _chat(sem_tag, messages, 1024, 4096)
		var row := {"idx": i, "latency_ms": int(r.get("latency_ms", 0)),
			"transport": str(r.get("code", "ok"))}
		if not bool(r.get("ok", false)):
			row["fallback_reason"] = "TINY_" + str(r.get("code", "OFFLINE"))
			row["text"] = str(cs.get("text", ""))
			row["expect_mode"] = str(cs.get("mode", ""))
			row["route_ok"] = false
			row["ir_ok"] = false
		else:
			var h: Dictionary = FrontendScript.handle_raw(str(r.get("content", "")), str(cs.get("text", "")))
			var s := _score_case(cs, h)
			for k in s.keys():
				row[k] = s[k]
			row["raw_head"] = str(r.get("content", "")).left(400)
			if bool(s.get("ir_ok", false)):
				if ((h.get("ir", {}) as Dictionary).get("orders", []) as Array).size() > 1:
					lat_multi.append(int(r.get("latency_ms", 0)))
				else:
					lat_simple.append(int(r.get("latency_ms", 0)))
		results.append(row)
		print("[live] #%d %s -> mode=%s route=%s ir=%s %dms" % [i, str(cs.get("text", "")).left(24),
			str(row.get("mode", row.get("fallback_reason", "?"))),
			str(row.get("route_ok", "?")), str(row.get("ir_ok", "?")), int(row.get("latency_ms", 0))])
	var vram_after: Dictionary = await _ps_vram()
	print("[live] vram_after=" + JSON.stringify(vram_after))
	# Large-model subset (same prompt): model-size delta only.
	var large_rows: Array = []
	for li in LARGE_IDX:
		if li < 0 or li >= _cases.size():
			continue
		var cs2: Dictionary = _cases[li]
		var m2: Array = FrontendScript.build_messages(str(cs2.get("text", "")),
			FrontendScript.build_ctx({}, {}, "", ""))
		var r2: Dictionary = await _chat(tac_tag, m2, 1024, 4096)
		var row2 := {"idx": li, "text": str(cs2.get("text", "")),
			"latency_ms": int(r2.get("latency_ms", 0))}
		if bool(r2.get("ok", false)):
			var h2: Dictionary = FrontendScript.handle_raw(str(r2.get("content", "")), str(cs2.get("text", "")))
			var s2 := _score_case(cs2, h2)
			for k2 in s2.keys():
				row2[k2] = s2[k2]
			row2["raw_head"] = str(r2.get("content", "")).left(400)
		else:
			row2["transport"] = str(r2.get("code", "?"))
		large_rows.append(row2)
		print("[live:LARGE] #%d %s -> %s %dms" % [li, str(cs2.get("text", "")).left(24),
			str(row2.get("mode", row2.get("transport", "?"))), int(row2.get("latency_ms", 0))])
	# Minimal-pair slice.
	var pairs := [[2, 32], [3, 34], [20, 21], [22, 23], [24, 14]]
	var pair_rows: Array = []
	for p in pairs:
		var a: Dictionary = results[int(p[0])]
		var b: Dictionary = results[int(p[1])]
		pair_rows.append({"a_idx": int(p[0]), "a_text": str((a as Dictionary).get("text", "")),
			"a_mode": str((a as Dictionary).get("mode", (a as Dictionary).get("fallback_reason", "?"))),
			"b_idx": int(p[1]), "b_text": str((b as Dictionary).get("text", "")),
			"b_mode": str((b as Dictionary).get("mode", (b as Dictionary).get("fallback_reason", "?"))),
			"distinguished": str((a as Dictionary).get("mode", "?")) != str((b as Dictionary).get("mode", "?"))})
	var summary := _summarize(results)
	var out_path := OUT
	if sem_tag != ConfigScript.semantic_model():
		var safe := sem_tag.replace(":", "_").replace("/", "_").replace("\\", "_")
		out_path = OUT.replace(".audit_semantic_live.json", ".audit_semantic_live__" + safe + ".json")
	var doc := {"semantic_tag": sem_tag, "tactical_tag": tac_tag,
		"vram_before": vram_before, "vram_after": vram_after,
		"summary": summary, "results": results,
		"large_subset": large_rows, "minimal_pairs": pair_rows,
		"lat_simple_ms": lat_simple, "lat_multi_ms": lat_multi}
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(doc, "\t"))
		f.close()
	print("[live] " + JSON.stringify(summary))
	print("LIVE_DONE cases=%d" % results.size())
	quit(0)


func _summarize(results: Array) -> Dictionary:
	var n := results.size()
	var route := 0
	var ir := 0
	var ast := 0
	var bound := 0
	var fb := {}
	var mode_conf := {}
	for r in results:
		if bool((r as Dictionary).get("route_ok", false)):
			route += 1
		if bool((r as Dictionary).get("ir_ok", false)):
			ir += 1
		if bool((r as Dictionary).get("scope_ast_ok", false)):
			ast += 1
		if bool((r as Dictionary).get("ir_ok", false)) and int((r as Dictionary).get("unbound", 1)) == 0:
			bound += 1
		var fr := str((r as Dictionary).get("fallback_reason", ""))
		if not fr.is_empty():
			fb[fr] = int(fb.get(fr, 0)) + 1
		var key := "%s->%s" % [str((r as Dictionary).get("expect_mode", "?")), str((r as Dictionary).get("mode", "?"))]
		mode_conf[key] = int(mode_conf.get(key, 0)) + 1
	return {"n": n, "route_acc": float(route) / float(maxi(n, 1)),
		"ir_valid_rate": float(ir) / float(maxi(n, 1)),
		"scope_ast_rate": float(ast) / float(maxi(n, 1)),
		"evidence_bound_rate": float(bound) / float(maxi(n, 1)),
		"fallbacks": fb, "mode_confusion": mode_conf}
