import json
import random
import subprocess
import math
import os
import sys

def hex_to_pixel(q, r):
    x = math.sqrt(3) * q + (math.sqrt(3) / 2.0) * r
    y = 1.5 * r
    return x, y

def hex_dist(q1, r1, q2, r2):
    return (abs(q1 - q2) + abs(q1 + r1 - q2 - r2) + abs(r1 - r2)) // 2

def generate_random_scenario(id_num):
    bounds = {"q_min": -20, "q_max": 20, "r_min": -15, "r_max": 15}
    forces = []
    
    # Randomize HQ positions
    # To ensure varied orientations, pick a random angle and place HQs opposite
    angle = random.uniform(0, 2 * math.pi)
    dist = random.uniform(10, 15)
    hq1_x, hq1_y = math.cos(angle) * dist, math.sin(angle) * dist
    hq2_x, hq2_y = -hq1_x, -hq1_y
    
    # We need to map pixel back to hex (approximate)
    def pixel_to_hex(x, y):
        q = (math.sqrt(3)/3 * x - 1/3 * y)
        r = (2/3 * y)
        return round(q), round(r)
        
    hq_red_q, hq_red_r = pixel_to_hex(hq1_x, hq1_y)
    hq_blue_q, hq_blue_r = pixel_to_hex(hq2_x, hq2_y)
    
    forces.append({"id": "R_HQ", "class": "hq", "faction": "red", "q": hq_red_q, "r": hq_red_r, "soldiers": 300})
    forces.append({"id": "B_HQ", "class": "hq", "faction": "blue", "q": hq_blue_q, "r": hq_blue_r, "soldiers": 300})
    
    classes = ["infantry", "cavalry", "archer", "spearman"]
    
    used_hexes = set([(hq_red_q, hq_red_r), (hq_blue_q, hq_blue_r)])
    
    def spawn_units(side, hq_q, hq_r, prefix, n):
        for i in range(n):
            for _ in range(10):
                dq, dr = random.randint(-5, 5), random.randint(-5, 5)
                q, r = hq_q + dq, hq_r + dr
                if (q, r) not in used_hexes:
                    used_hexes.add((q, r))
                    cls = random.choice(classes)
                    forces.append({
                        "id": f"{prefix}_{cls[:3].upper()}_{i}",
                        "class": cls,
                        "faction": side,
                        "q": q,
                        "r": r,
                        "soldiers": random.randint(200, 500)
                    })
                    break
                    
    spawn_units("red", hq_red_q, hq_red_r, "R", random.randint(4, 8))
    spawn_units("blue", hq_blue_q, hq_blue_r, "B", random.randint(4, 8))
    
    return {
        "id": id_num,
        "scenario": {
            "scenario_id": f"SYN_{id_num}",
            "mission_contract": {"primary_objective": "destroy_all_red", "turn_limit": 100},
            "map": {"bounds": bounds, "default_terrain": 0, "terrain_overrides": {}, "river_cells": []},
            "forces": forces,
            "start_turn": 1
        }
    }

def normalize(v):
    mag = math.sqrt(v[0]*v[0] + v[1]*v[1])
    if mag == 0: return (0, 0)
    return (v[0]/mag, v[1]/mag)

def score_candidate(cmd_task, cmd_area, candidate, unit_data, obs, is_ranged, hq_own_qr, hq_enemy_qr, all_enemy_qr):
    uq, ur = unit_data["q"], unit_data["r"]
    cq, cr = candidate["q"], candidate["r"]
    
    # Forward vector
    hx1, hy1 = hex_to_pixel(hq_own_qr[0], hq_own_qr[1])
    hx2, hy2 = hex_to_pixel(hq_enemy_qr[0], hq_enemy_qr[1])
    fwd = normalize((hx2 - hx1, hy2 - hy1))
    lft = (-fwd[1], fwd[0])
    rgt = (fwd[1], -fwd[0])
    bck = (-fwd[0], -fwd[1])
    
    # Nearest enemy
    nearest_dist = 9999
    nearest_e = None
    for e in all_enemy_qr:
        d = hex_dist(uq, ur, e[0], e[1])
        if d < nearest_dist:
            nearest_dist = d
            nearest_e = e
            
    if not nearest_e: return 0
    
    cdist_enemy = hex_dist(cq, cr, nearest_e[0], nearest_e[1])
    cdist_hq = hex_dist(cq, cr, hq_own_qr[0], hq_own_qr[1])
    
    # Movement vector
    ux, uy = hex_to_pixel(uq, ur)
    cx, cy = hex_to_pixel(cq, cr)
    mx, my = cx - ux, cy - uy
    
    score = 0
    
    # Area direction vectors
    dir_vec = fwd
    if cmd_area == "LEFT": dir_vec = lft
    elif cmd_area == "RIGHT": dir_vec = rgt
    elif cmd_area == "BACK": dir_vec = bck
    
    move_along_dir = mx * dir_vec[0] + my * dir_vec[1]
    
    if cmd_task in ["ADVANCE", "ATTACK", "FIX", "EXECUTE"]:
        if is_ranged:
            # Want to be distance 2 or 3
            if cdist_enemy == 2 or cdist_enemy == 3:
                score += 50
            elif cdist_enemy < 2:
                score -= cdist_enemy * 20
            else:
                score -= cdist_enemy * 10
            # Also moving forward is generally good
            score += move_along_dir * 0.5
        else:
            # Want to minimize distance
            score -= cdist_enemy * 15
            score += move_along_dir * 0.5
            
    elif cmd_task == "FLANK":
        if cmd_area == "ANY":
            dir_vec = lft if random.random() > 0.5 else rgt
            move_along_dir = mx * dir_vec[0] + my * dir_vec[1]
            
        score += move_along_dir * 2.0
        # Should also get somewhat close
        score -= cdist_enemy * 5
        
    elif cmd_task == "WITHDRAW":
        score -= cdist_hq * 15
        
    elif cmd_task in ["HOLD", "RESERVE"]:
        score -= hex_dist(uq, ur, cq, cr) * 20
        
    return score

if __name__ == "__main__":
    import shutil
    godot_exe = "C:\\Users\\kyoun\\AppData\\Local\\Programs\\Godot\\Godot_v4.2.2-stable_win64.exe"
    if not os.path.exists(godot_exe):
        # fallback to standard godot command if in PATH, otherwise try typical
        godot_exe = "godot"
        
    BATCH_SIZE = 200
    NUM_BATCHES = 500 # 100,000 total
    
    out_dir = "D:\\Game development\\Demon slayer\\StrategyGame\\artifacts\\laya_synthetic_v1"
    os.makedirs(out_dir, exist_ok=True)
    
    f_pairs = open(os.path.join(out_dir, "command_action_pairs.jsonl"), "w", encoding="utf-8")
    f_cmds = open(os.path.join(out_dir, "commands.jsonl"), "w", encoding="utf-8")
    
    tasks = ["ADVANCE", "FIX", "ATTACK", "FLANK", "RECON", "RESERVE", "HOLD", "WITHDRAW", "EXECUTE"]
    areas = ["FORWARD", "LEFT", "RIGHT", "BACK", "ANY"]
    
    total_rows = 0
    rejected_rows = 0
    task_dist = {t: 0 for t in tasks}
    class_dist = {}
    melee_ranged = {"melee": 0, "ranged": 0}
    side_dist = {"red": 0, "blue": 0}
    dir_dist = {a: 0 for a in areas}
    
    # We will use the proper Godot executable
    godot_path = shutil.which("godot")
    if godot_path: godot_exe = godot_path
    
    print(f"Using godot: {godot_exe}")
    
    for batch_idx in range(NUM_BATCHES):
        print(f"Batch {batch_idx+1}/{NUM_BATCHES}")
        sys.stdout.flush()
        scenarios = []
        for i in range(BATCH_SIZE):
            scenarios.append(generate_random_scenario(batch_idx * BATCH_SIZE + i))
            
        with open("batch_in.json", "w", encoding="utf-8") as f:
            json.dump(scenarios, f)
            
        cmd = [godot_exe, "--headless", "-s", "tools/extract_candidates.gd", "--in", "batch_in.json", "--out", "batch_out.json"]
        res = subprocess.run(cmd, cwd="D:\\Game development\\Demon slayer\\StrategyGame", capture_output=True, text=True)
        if res.returncode != 0 or "Load failed" in res.stdout:
            print(res.stdout)
            print(res.stderr)
        
        if not os.path.exists("batch_out.json"):
            print("Godot failed to produce output!")
            continue
            
        with open("batch_out.json", "r", encoding="utf-8") as f:
            results = json.load(f)
            
        scenario_dict = { s["id"]: s["scenario"] for s in scenarios }
        
        for res in results:
            scn = scenario_dict[res["id"]]
            hq_red = next(f for f in scn["forces"] if f["id"] == "R_HQ")
            hq_blue = next(f for f in scn["forces"] if f["id"] == "B_HQ")
            
            for side, data in res["sides"].items():
                hq_own_qr = (hq_red["q"], hq_red["r"]) if side == "red" else (hq_blue["q"], hq_blue["r"])
                hq_enemy_qr = (hq_blue["q"], hq_blue["r"]) if side == "red" else (hq_red["q"], hq_red["r"])
                enemy_side = "blue" if side == "red" else "red"
                all_enemy_qr = [(f["q"], f["r"]) for f in scn["forces"] if f["faction"] == enemy_side]
                
                obs = data["obs"]
                for u in data["units"]:
                    if len(u["reachable"]) == 0 and len(u["attacks"]) == 0:
                        continue
                        
                    task = random.choice(tasks)
                    area = random.choice(areas)
                    
                    cmd_intent = {
                        "task": task,
                        "area": area,
                        "intent": f"{task} {area}"
                    }
                    
                    wire_map = {"FORWARD": "NORTH", "BACK": "SOUTH", "LEFT": "WEST", "RIGHT": "EAST", "ANY": "ANY"}
                    wire_area = wire_map[area]
                    
                    is_ranged = u["unit_class"] in ["ARCHER"]
                    
                    scored_candidates = []
                    
                    for r in u["reachable"]:
                        s = score_candidate(task, area, r, u, obs, is_ranged, hq_own_qr, hq_enemy_qr, all_enemy_qr)
                        scored_candidates.append({"type": "move", "q": r["q"], "r": r["r"], "score": s})
                        
                    for a in u["attacks"]:
                        # Attacking is generally good for aggressive tasks, unless ranged and too close
                        s = 100
                        if is_ranged:
                            dist = hex_dist(u["q"], u["r"], a["defender_q"], a["defender_r"])
                            if dist < 2 and task not in ["HOLD", "RESERVE"]: s -= 50
                        scored_candidates.append({"type": "attack", "target": a["defender_id"], "score": s})
                        
                    if not scored_candidates:
                        rejected_rows += 1
                        continue
                        
                    # Find best
                    scored_candidates.sort(key=lambda x: x["score"], reverse=True)
                    best_score = scored_candidates[0]["score"]
                    
                    accepted = [c for c in scored_candidates if c["score"] >= best_score - 10]
                    
                    if not accepted:
                        rejected_rows += 1
                        continue
                        
                    pair = {
                        "observation": obs,
                        "command": {"task": task, "area": wire_area, "intent": cmd_intent["intent"]},
                        "unit": {"unit_id": u["unit_id"], "class": u["unit_class"], "q": u["q"], "r": u["r"]},
                        "candidates": u["reachable"] + u["attacks"],
                        "accepted_actions": accepted
                    }
                    
                    f_pairs.write(json.dumps(pair) + "\n")
                    f_cmds.write(json.dumps({"observation": obs, "command": pair["command"]}) + "\n")
                    
                    total_rows += 1
                    task_dist[task] += 1
                    class_dist[u["unit_class"]] = class_dist.get(u["unit_class"], 0) + 1
                    side_dist[side] += 1
                    dir_dist[area] += 1
                    if is_ranged: melee_ranged["ranged"] += 1
                    else: melee_ranged["melee"] += 1
                    
        f_pairs.flush()
        f_cmds.flush()
        print(f"Stats after batch {batch_idx+1}: total_rows={total_rows}, rejected_rows={rejected_rows}")
        sys.stdout.flush()
                    
        # Early stop if we hit 100k
        if total_rows >= 100000:
            break
            
    f_pairs.close()
    f_cmds.close()
    
    with open(os.path.join(out_dir, "MANIFEST.md"), "w") as f:
        f.write("# Laya Synthetic Dataset v1\n\n")
        f.write(f"- Total rows: {total_rows}\n")
        f.write(f"- Rejected illegal/unscorable rows: {rejected_rows}\n\n")
        f.write("## Task Distribution\n")
        for k, v in task_dist.items(): f.write(f"- {k}: {v}\n")
        f.write("\n## Class Distribution\n")
        for k, v in class_dist.items(): f.write(f"- {k}: {v}\n")
        f.write("\n## Side Distribution\n")
        for k, v in side_dist.items(): f.write(f"- {k}: {v}\n")
        f.write("\n## Directional Distribution\n")
        for k, v in dir_dist.items(): f.write(f"- {k}: {v}\n")
        f.write("\n## Melee vs Ranged\n")
        f.write(f"- Melee: {melee_ranged['melee']}\n")
        f.write(f"- Ranged: {melee_ranged['ranged']}\n")
        f.write("\n## Schema & Pipeline\n")
        f.write("Generated using `generate_laya_synthetic_dataset.py` driving Godot `extract_candidates.gd`.\n")
        f.write("Candidate labels are scored based on side-relative geometry where NORTH=FORWARD, SOUTH=BACK, WEST=LEFT, EAST=RIGHT.\n")
        
    print("Done!")
