"""D0 Parts B–H — cross-distribution eval, teacher matrix, candidates.

Pure computation over the frozen distribution sets from collect.py. No
simulation, no weight access beyond the stored selections. All Q vectors
come from identical states (pinned by state hash per row).
"""

from __future__ import annotations

import math
import os

import torch

from python_jev.diagnose.collect import SETS, TEACHERS, load_set

EPSILON_AUDIT = 0.01


def _row_q(payload: dict, i: int, t: int) -> list[float | None]:
    return [(None if math.isnan(v) else float(v))
            for v in payload["tensors"]["teacher_q"][i, t].tolist()]


def _row_legal(payload: dict, i: int) -> list[bool]:
    return [bool(x) for x in payload["tensors"]["legal"][i].tolist()]


def _regret(q: list[float | None], legal: list[bool], sel: int) -> float:
    best = max(v for v, ok in zip(q, legal) if ok)
    return max(0.0, best - q[sel])


def _ranks(values: list[float]) -> list[float]:
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def _spearman(a: list[float], b: list[float]) -> float:
    n = len(a)
    if n < 2 or len(b) != n:
        return float("nan")
    ra, rb = _ranks(a), _ranks(b)
    ma, mb = sum(ra) / n, sum(rb) / n
    cov = sum((x - ma) * (y - mb) for x, y in zip(ra, rb))
    va = sum((x - ma) ** 2 for x in ra)
    vb = sum((y - mb) ** 2 for y in rb)
    if va <= 0 or vb <= 0:
        return float("nan")
    return cov / math.sqrt(va * vb)


def _summarize(values: list[float]) -> dict:
    if not values:
        return {"n": 0}
    s = sorted(values)
    return {"n": len(s), "mean": sum(s) / len(s),
            "median": s[len(s) // 2],
            "p95": s[min(len(s) - 1, int(0.95 * len(s)))],
            "max": s[-1]}


def cross_distribution(dist_dir: str) -> dict:
    """Part B/C: old+new JEV regret under canonical Q_simple per set."""
    out: dict = {"teachers": list(TEACHERS),
                 "q_teacher": TEACHERS[0], "sets": {}}
    for s in SETS:
        payload = load_set(os.path.join(dist_dir, f"{s}.pt"))
        n = payload["n_records"]
        per_model = {}
        for tag, key in (("old", "sel_old"), ("new", "sel_new")):
            regrets, tops, eps, ents = [], [], [], []
            sel = payload["tensors"][key].tolist()
            for i in range(n):
                legal = _row_legal(payload, i)
                q = _row_q(payload, i, 0)
                r = _regret(q, legal, int(sel[i]))
                regrets.append(r)
                top_q = max(range(6), key=lambda a: (q[a] is not None and legal[a], q[a] or 0.0))
                tops.append(1.0 if int(sel[i]) == top_q else 0.0)
                best = max(v for v, ok in zip(q, legal) if ok)
                eps.append(1.0 if q[int(sel[i])] >= best - EPSILON_AUDIT else 0.0)
                p = payload["tensors"]["prob_new" if tag == "new" else "prob_old"][i].tolist()
                ents.append(-sum(v * math.log(v) for v in p if v > 0))
            per_model[tag] = {"regret": _summarize(regrets),
                              "top1": sum(tops) / n,
                              "epsilon_at_0.01": sum(eps) / n,
                              "entropy": _summarize(ents)}
        out["sets"][s] = {"n": n, **per_model}
    return out


def _pair_stats(rows: list[tuple[list[float], list[float], list[bool]]]) -> dict:
    agree = n = 0
    sp: list[float] = []
    dq: list[float] = []
    for qa, qb, legal in rows:
        shared = [s for s in range(6) if legal[s]]
        if not shared:
            continue
        n += 1
        agree += (max(shared, key=lambda s: qa[s]) == max(shared, key=lambda s: qb[s]))
        dq.append(sum(abs(qb[s] - qa[s]) for s in shared) / len(shared))
        c = _spearman([qa[s] for s in shared], [qb[s] for s in shared])
        if not math.isnan(c):
            sp.append(c)
    return {"states": n, "top_action_agreement": agree / max(1, n),
            "spearman_mean": sum(sp) / len(sp) if sp else None,
            "spearman_n": len(sp),
            "mean_abs_dq": sum(dq) / len(dq) if dq else None}


def teacher_matrix(dist_dir: str) -> dict:
    """Part D: Simple/Random/Hold Q disagreement on identical states."""
    from python_jev.constants import ACTION_SPACE

    pairs = ((0, 1), (0, 2), (1, 2))
    pool: dict[tuple[int, int], list] = {p: [] for p in pairs}
    per_set: dict[str, dict] = {}
    by_class: dict[str, dict[tuple[int, int], list]] = {}
    by_mission: dict[str, dict[tuple[int, int], list]] = {}
    by_profile: dict[str, dict[tuple[int, int], list]] = {}
    sign_slots: dict[int, list[int]] = {s: [0, 0] for s in range(6)}
    skills: dict[str, dict[str, int]] = {t: {} for t in TEACHERS}
    for s in SETS:
        payload = load_set(os.path.join(dist_dir, f"{s}.pt"))
        local: dict[tuple[int, int], list] = {p: [] for p in pairs}
        for i, prov in enumerate(payload["provenance"]):
            legal = _row_legal(payload, i)
            qs = [_row_q(payload, i, t) for t in range(3)]
            qf = [[v if v is not None else 0.0 for v in q] for q in qs]
            for p in pairs:
                triple = (qf[p[0]], qf[p[1]], legal)
                pool[p].append(triple)
                local[p].append(triple)
                by_class.setdefault(prov["actor_class"], {q: [] for q in pairs})[p].append(triple)
                by_mission.setdefault(prov["mission"], {q: [] for q in pairs})[p].append(triple)
                by_profile.setdefault(prov["profile"], {q: [] for q in pairs})[p].append(triple)
            for slot in range(6):
                if not legal[slot]:
                    continue
                signs = [1 if qs[t][slot] > 0 else (-1 if qs[t][slot] < 0 else 0)
                         for t in range(3)]
                sign_slots[slot][1] += 1
                sign_slots[slot][0] += (signs[0] == signs[1] == signs[2])
            for t in range(3):
                top = max([a for a in range(6) if legal[a]], key=lambda a: qs[t][a])
                skill = ACTION_SPACE[prov["actor_class"]][top]
                skills[TEACHERS[t]][skill] = skills[TEACHERS[t]].get(skill, 0) + 1
        per_set[s] = {f"{TEACHERS[a]}_vs_{TEACHERS[b]}": _pair_stats(local[(a, b)])
                      for a, b in pairs}
    key = lambda p: f"{TEACHERS[p[0]]}_vs_{TEACHERS[p[1]]}"  # noqa: E731
    return {
        "pooled": {key(p): _pair_stats(pool[p]) for p in pairs},
        "per_set": per_set,
        "by_class": {c: {key(p): _pair_stats(v[p]) for p in pairs}
                     for c, v in sorted(by_class.items())},
        "by_mission": {m: {key(p): _pair_stats(v[p]) for p in pairs}
                       for m, v in sorted(by_mission.items())},
        "by_profile": {m: {key(p): _pair_stats(v[p]) for p in pairs}
                       for m, v in sorted(by_profile.items())},
        "per_slot_sign_agreement": {
            str(s): {"states": v[1], "all_agree_rate": v[0] / max(1, v[1])}
            for s, v in sign_slots.items()},
        "top_skill_histogram": skills,
    }


def cross_teacher_regret(dist_dir: str) -> dict:
    """Part E: cost of acting on teacher A under teacher B's Q."""
    directed = [(0, 1), (0, 2), (1, 0), (1, 2), (2, 0), (2, 1)]
    pool: dict[tuple[int, int], list[float]] = {d: [] for d in directed}
    per_set: dict[str, dict[str, dict]] = {}
    per_class: dict[str, dict[tuple[int, int], list[float]]] = {}
    for s in SETS:
        payload = load_set(os.path.join(dist_dir, f"{s}.pt"))
        local: dict[tuple[int, int], list[float]] = {d: [] for d in directed}
        for i, prov in enumerate(payload["provenance"]):
            legal = _row_legal(payload, i)
            qs = [_row_q(payload, i, t) for t in range(3)]
            for a, b in directed:
                top_a = max([x for x in range(6) if legal[x]], key=lambda x: qs[a][x])
                best_b = max(qs[b][x] for x in range(6) if legal[x])
                r = max(0.0, best_b - qs[b][top_a])
                pool[(a, b)].append(r)
                local[(a, b)].append(r)
                per_class.setdefault(prov["actor_class"], {d: [] for d in directed})[(a, b)].append(r)
        per_set[s] = {f"act_{TEACHERS[a]}_eval_{TEACHERS[b]}": _summarize(local[(a, b)])
                      for a, b in directed}
    key = lambda d: f"act_{TEACHERS[d[0]]}_eval_{TEACHERS[d[1]]}"  # noqa: E731
    return {"pooled": {key(d): _summarize(pool[d]) for d in directed},
            "per_set": per_set,
            "per_class": {c: {key(d): _summarize(v[d]) for d in directed}
                          for c, v in sorted(per_class.items())}}


def jev_robustness(dist_dir: str) -> dict:
    """Part F: NEW JEV selection regret under every teacher's Q."""
    out: dict[str, dict] = {}
    for s in SETS:
        payload = load_set(os.path.join(dist_dir, f"{s}.pt"))
        sel = payload["tensors"]["sel_new"].tolist()
        per_teacher: dict[str, list[float]] = {t: [] for t in TEACHERS}
        worst, mean_all = [], []
        for i in range(payload["n_records"]):
            legal = _row_legal(payload, i)
            rs = []
            for t in range(3):
                r = _regret(_row_q(payload, i, t), legal, int(sel[i]))
                per_teacher[TEACHERS[t]].append(r)
                rs.append(r)
            worst.append(max(rs))
            mean_all.append(sum(rs) / 3.0)
        out[s] = {"n": payload["n_records"],
                  "per_teacher": {t: _summarize(v) for t, v in per_teacher.items()},
                  "worst_teacher": _summarize(worst),
                  "mean_of_teachers": _summarize(mean_all)}
    return out


def candidate_targets(dist_dir: str) -> dict:
    """Part G/H: candidates A/B/C + JSD disagreement. No fitting."""
    from python_jev.training.policy_target import soft_targets_from_q

    out: dict[str, dict] = {}
    for s in SETS:
        payload = load_set(os.path.join(dist_dir, f"{s}.pt"))
        ent = {"A": [], "B": [], "C": []}
        change_ab = change_ac = 0
        jsd: list[float] = []
        agree_count = {"3/3": 0, "2/3": 0, "1/3": 0}
        n = payload["n_records"]
        for i in range(n):
            legal = _row_legal(payload, i)
            qs = [_row_q(payload, i, t) for t in range(3)]
            ps = [soft_targets_from_q(q, legal) for q in qs]
            pb = [(a + b) / 2.0 for a, b in zip(ps[0], ps[1])]
            mb = sum(pb[x] for x in range(6) if legal[x])
            pb = [v / mb if legal[x] else 0.0 for x, v in enumerate(pb)]
            pc = [(a + b + c) / 3.0 for a, b, c in zip(ps[0], ps[1], ps[2])]
            mc = sum(pc[x] for x in range(6) if legal[x])
            pc = [v / mc if legal[x] else 0.0 for x, v in enumerate(pc)]
            for tag, p in (("A", ps[0]), ("B", pb), ("C", pc)):
                ent[tag].append(-sum(v * math.log(v) for v in p if v > 0))
            tops = [max([x for x in range(6) if legal[x]], key=lambda x: p[x])
                    for p in ps]
            top_b = max([x for x in range(6) if legal[x]], key=lambda x: pb[x])
            top_c = max([x for x in range(6) if legal[x]], key=lambda x: pc[x])
            change_ab += (top_b != tops[0])
            change_ac += (top_c != tops[0])
            mix = [(a + b + c) / 3.0 for a, b, c in zip(ps[0], ps[1], ps[2])]
            h_mix = -sum(v * math.log(v) for v in mix if v > 0)
            h_each = [-sum(v * math.log(v) for v in p if v > 0) for p in ps]
            jsd.append(max(0.0, h_mix - sum(h_each) / 3.0))
            votes = len(set(tops))
            agree_count["3/3" if votes == 1 else ("2/3" if votes == 2 else "1/3")] += 1
        out[s] = {"n": n,
                  "entropy": {t: _summarize(v) for t, v in ent.items()},
                  "top_change_A_to_B": change_ab / n,
                  "top_change_A_to_C": change_ac / n,
                  "jsd": _summarize(jsd),
                  "teacher_agreement": agree_count,
                  "high_disagreement_share": {
                      ">0.05": sum(1 for v in jsd if v > 0.05) / n,
                      ">0.10": sum(1 for v in jsd if v > 0.10) / n,
                      ">0.20": sum(1 for v in jsd if v > 0.20) / n,
                  }}
    return out


__all__ = ["EPSILON_AUDIT", "candidate_targets", "cross_distribution",
           "cross_teacher_regret", "jev_robustness", "teacher_matrix"]
