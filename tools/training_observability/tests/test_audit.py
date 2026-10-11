"""Audit harness tests - SYNTHETIC fixtures only (no model, no Godot, no lock)."""
import json
import random
import unittest

from tools.training_observability import audit_harness as A
from tools.training_observability.safe_io import OutputWriter, ReadOnlySource
from tools.training_observability.tests._fixtures import fresh_workspace


def synth_games(a, b, pair_outcomes, strict_a=()):
    """pair_outcomes: list of (outcome_a_when_a_RED, outcome_a_when_a_BLUE)."""
    gs = []
    for i, (r, bl) in enumerate(pair_outcomes):
        pid = f"P{i + 1:03d}"
        gs.append({"game_id": f"{a}{b}{pid}A", "player_a": a, "player_b": b, "pair_id": pid,
                   "seed": 700000001 + i, "a_side": "RED", "outcome_a": r,
                   "strict_a": (pid, "RED") in strict_a, "strict_b": False})
        gs.append({"game_id": f"{a}{b}{pid}B", "player_a": a, "player_b": b, "pair_id": pid,
                   "seed": 700000001 + i, "a_side": "BLUE", "outcome_a": bl,
                   "strict_a": (pid, "BLUE") in strict_a, "strict_b": False})
    return gs


def rps(n_pairs, p_win, seed=1):
    """Rock-paper-scissors among X>Y>Z>X with per-game win prob p_win."""
    rng = random.Random(seed)

    def outcomes():
        return [tuple("WIN" if rng.random() < p_win else "LOSS" for _ in range(2)) for _ in range(n_pairs)]
    return synth_games("X", "Y", outcomes()) + synth_games("Y", "Z", outcomes()) + \
        synth_games("Z", "X", outcomes())


class AuditTests(unittest.TestCase):
    # (7) side-swap pairing
    def test_plan_side_swap_pairs(self):
        reg = A.build_seed_registry({"all": [1, 2, 3]}, n_pairs=8)
        cfg = {"champion": {"id": "C"}, "opponents": [{"id": "B0"}, {"id": "H1"}, {"id": "C"}],
               "games_per_opponent": 6, "round_robin_between_opponents": True}
        plan = A.build_plan(cfg, reg)
        self.assertEqual(plan["matchups"], [["C", "B0"], ["C", "H1"], ["B0", "H1"]])
        self.assertEqual(plan["n_games"], 3 * 6)
        by = {}
        for g in plan["games"]:
            by.setdefault((g["player_a"], g["player_b"], g["pair_id"]), []).append(g)
        for games in by.values():
            self.assertEqual(sorted(x["a_side"] for x in games), ["BLUE", "RED"])
            self.assertEqual(len({x["seed"] for x in games}), 1, "both sides share the seed")
        with self.assertRaises(ValueError):
            A.build_plan(dict(cfg, games_per_opponent=5), reg)

    def test_pairing_orientation_and_incomplete_pairs(self):
        gs = synth_games("C", "O", [("WIN", "DRAW"), ("LOSS", "WIN")])
        # the same games recorded from O's perspective must give identical stats
        flipped = [dict(g, player_a=g["player_b"], player_b=g["player_a"],
                        a_side="BLUE" if g["a_side"] == "RED" else "RED",
                        outcome_a=A.FLIP[g["outcome_a"]]) for g in gs]
        s1 = A.matchup_stats(gs, "C", "O")
        s2 = A.matchup_stats(flipped, "C", "O")
        for k in ("wins", "losses", "draws", "score", "pair_shapes", "score_rate", "ci95"):
            self.assertEqual(s1[k], s2[k], k)
        gs.append({"game_id": "x", "player_a": "C", "player_b": "O", "pair_id": "P099",
                   "seed": 1, "a_side": "RED", "outcome_a": "WIN"})
        s3 = A.matchup_stats(gs, "C", "O")
        self.assertEqual(s3["pairs_incomplete"], ["P099"])
        self.assertEqual(s3["n_pairs_complete"], 2)
        self.assertEqual(s3["games"], 5)

    # (8) score = W + 0.5 D
    def test_score(self):
        gs = synth_games("C", "O", [("WIN", "DRAW"), ("DRAW", "DRAW"), ("LOSS", "WIN")],
                         strict_a={("P003", "RED")})
        s = A.matchup_stats(gs, "C", "O")
        self.assertEqual((s["wins"], s["losses"], s["draws"]), (2, 1, 3))
        self.assertEqual(s["score"], 2 + 0.5 * 3)
        self.assertAlmostEqual(s["score_rate_games"], 3.5 / 6, places=5)
        self.assertAlmostEqual(s["pair_score_mean"], (1.5 + 1.0 + 1.0) / 3, places=5)
        self.assertAlmostEqual(s["score_rate"], 3.5 / 6, places=6)
        self.assertAlmostEqual(s["strict_failure_rate_per_game_a"], 1 / 6, places=5)
        self.assertEqual(s["pair_shapes"], {"DW": 1, "DD": 1, "LW": 1})

    # (9) CI / statistics
    def test_bootstrap_ci(self):
        self.assertEqual(A.bootstrap_ci([2.0] * 10), (1.0, 1.0))
        self.assertEqual(A.bootstrap_ci([]), (None, None))
        sym = [0.0, 2.0] * 20
        lo, hi = A.bootstrap_ci(sym)
        self.assertLess(lo, 0.5)
        self.assertGreater(hi, 0.5)
        self.assertEqual(A.bootstrap_ci(sym), (lo, hi), "fixed RNG seed -> deterministic")
        strong = A.matchup_stats(synth_games("C", "O", [("WIN", "WIN")] * 30 + [("DRAW", "LOSS")] * 2), "C", "O")
        self.assertEqual(strong["significance"], "A_BETTER")
        weak = A.matchup_stats(synth_games("C", "O", [("WIN", "LOSS")] * 10 + [("WIN", "DRAW")]), "C", "O")
        self.assertEqual(weak["significance"], "NOT_SIGNIFICANT")
        self.assertLessEqual(weak["ci95"][0], weak["score_rate"])
        self.assertGreaterEqual(weak["ci95"][1], weak["score_rate"])

    def test_non_transitivity(self):
        strong = A.analyze(rps(40, 0.95), champion="X")
        self.assertEqual(strong["non_transitivity"]["verdict"], "CYCLE")
        self.assertEqual(strong["non_transitivity"]["cycles"][0]["cycle"], ["X", "Y", "Z", "X"])
        # X>Y and Y>Z significant, Z>X only by point estimate -> UNRESOLVED, not CYCLE
        weak_games = synth_games("X", "Y", [("WIN", "WIN")] * 20) + \
            synth_games("Y", "Z", [("WIN", "WIN")] * 20) + \
            synth_games("Z", "X", [("WIN", "LOSS")] * 5 + [("WIN", "DRAW")])
        weak = A.analyze(weak_games, champion="X")
        cyc = weak["non_transitivity"]
        self.assertEqual(cyc["verdict"], "UNRESOLVED")
        self.assertEqual(cyc["cycles"][0]["cycle"], ["X", "Y", "Z", "X"])
        self.assertEqual(cyc["cycles"][0]["non_significant_edges"], [["Z", "X"]])
        transitive = synth_games("X", "Y", [("WIN", "WIN")] * 20) + synth_games("Y", "Z", [("WIN", "WIN")] * 20) \
            + synth_games("X", "Z", [("WIN", "WIN")] * 20)
        self.assertTrue(A.analyze(transitive, "X")["non_transitivity"]["verdict"].startswith("NONE"))
        star = synth_games("X", "Y", [("WIN", "WIN")] * 3) + synth_games("X", "Z", [("LOSS", "LOSS")] * 3)
        self.assertTrue(A.analyze(star, "X")["non_transitivity"]["verdict"].startswith("NOT_TESTABLE"))
        m = strong["matrix"]
        self.assertAlmostEqual(m["X"]["Y"]["score_rate"] + m["Y"]["X"]["score_rate"], 1.0)

    def test_seed_registry_disjoint(self):
        _, paths = fresh_workspace()
        obs = A.observed_seeds(ReadOnlySource(), paths)
        self.assertIn(3101, obs["rollout_generation"])
        self.assertIn(4101, obs["rollout_episode"])
        self.assertIn(9101, obs["eval"])
        self.assertIn(2101, obs["rollout_generation"])  # manual loop
        reg = A.build_seed_registry(obs, n_pairs=16)
        self.assertEqual(reg["disjointness"]["verdict"], "DISJOINT")
        self.assertFalse(set(p["seed"] for p in reg["pairs"]) & set(obs["all"]))
        self.assertGreater(reg["disjointness"]["producer_streams_safe_until_iteration"], 1_000_000)
        with self.assertRaises(ValueError):
            A.build_seed_registry({"all": [A.REGISTRY_BASE + 3]}, n_pairs=8)
        with self.assertRaises(ValueError):  # projected producer streams would collide
            A.build_seed_registry({"all": []}, n_pairs=8, base=5000)

    def test_report_and_live_executor_refuses(self):
        _, paths = fresh_workspace()
        w = OutputWriter(paths.output_root, paths.protected_roots)
        res = A.write_audit(w, paths.audits_dir, "synthetic_fixture", rps(10, 0.9), "X", synthetic=True)
        rep = (paths.audits_dir / "synthetic_fixture" / "AUDIT_REPORT.md").read_text(encoding="utf-8")
        self.assertIn("SYNTHETIC FIXTURE RESULTS", rep)
        doc = json.loads((paths.audits_dir / "synthetic_fixture" / "AUDIT_RESULT.json").read_text(encoding="utf-8"))
        self.assertEqual(doc["result"]["players"], res["players"])
        with self.assertRaises(A.AuditExecutionDisabled):
            A.LiveMatchExecutor().run({})

    def test_prepare_assets_from_lineage(self):
        _, paths = fresh_workspace()
        out = A.prepare_audit_assets(paths, n_pairs=16, games_per_opponent=8)
        ids = [o["id"] for o in out["config"]["opponents"]]
        self.assertEqual(ids[0], "B0")
        self.assertNotIn(out["config"]["champion"]["id"], ids)
        self.assertEqual(out["plan"]["pairs_per_matchup"], 4)
        self.assertTrue((paths.audits_dir / "seed_registry.json").exists())


if __name__ == "__main__":
    unittest.main()
