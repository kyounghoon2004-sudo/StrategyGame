"""SG0 gates for the significance-gating ablation (experimental, no v0.6).

Fast structural checks over frozen sources + siggate artifacts. No training,
no collection, no benchmark battles here.
"""

from __future__ import annotations

import hashlib
import json
import os

import torch

ROOT = os.path.join("artifacts", "jev_significance_gate_v0")
ARMS = ("r25", "m25", "or25", "and25", "or10", "or50")
SEEDS = (42, 43, 44)
V04_CKPT = os.path.join("artifacts", "jev_dagger_v1", "checkpoints", "seed44.pt")
V05_CKPT = os.path.join("artifacts", "jev_dagger_v2", "checkpoints", "seed44.pt")


def _load(rel: str) -> dict:
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return json.load(f)


def test_sg0_01_sources_verified():
    from python_jev.aggregate.dataset_v05 import V04_CKPT_SHA256, V04_TRAIN_SHA256
    from python_jev.aggregate.dataset_v05 import load_shard_v05
    from python_jev.aggregate.gather import collection_ckpt_hash
    from python_jev.diagnose.collect import load_set

    assert collection_ckpt_hash(V04_CKPT) == V04_CKPT_SHA256
    with open(os.path.join("artifacts", "jev_dagger_v1", "dataset_v04", "train.pt"),
              "rb") as f:
        assert hashlib.sha256(f.read()).hexdigest() == V04_TRAIN_SHA256
    v05 = load_shard_v05(
        os.path.join("artifacts", "jev_dagger_v2", "dataset_v05", "train.pt"),
        verify=True)
    assert v05["n_records"] == 26698
    d3 = load_set(os.path.join("artifacts", "jev_dagger_v2", "round3_collection",
                               "dagger3_unique.pt"), verify=True)
    assert d3["n_records"] == 6048
    src = _load("summary/sources.json")
    assert src["new_states_collected"] == 0
    assert src["d3_novel"] == 5408


def test_sg0_02_no_new_collection():
    # manifests reference existing rows only; no collected-state artifacts.
    for arm in ARMS:
        man = _load(f"manifests/{arm}.json")
        assert man["base"]["train_idx"] == [0, 21290]
        assert all(21290 <= i < 26698 for i in man["retained_train_idx"])
        assert len(man["retained_dagger_idx"]) == len(man["retained_positions"])
    banned = ("collected_train_states", "round4", "dagger4_unique")
    for dirpath, _dirs, files in os.walk(ROOT):
        for fn in files:
            assert not any(b in fn for b in banned), fn
            assert not fn.endswith("_unique.pt"), fn


def test_sg0_03_arms_deterministic():
    from python_jev.siggate.gates import dagger3_signals, gate_membership

    member = gate_membership(dagger3_signals())
    for arm in ARMS:
        man = _load(f"manifests/{arm}.json")
        assert man["retained_positions"] == member[arm]
        assert man["retained_positions"] == sorted(man["retained_positions"])


def test_sg0_04_full_precision_membership():
    from python_jev.diagnose.collect import load_set
    from python_jev.siggate.gates import D3_SET, D3_XD, arm_predicate

    payload = load_set(D3_SET, verify=True)
    novel = sorted(json.load(open(D3_XD, encoding="utf-8"))["novel_indices"])
    t = payload["tensors"]
    sel = t["sel_new"].tolist()
    for arm in ARMS:
        man = _load(f"manifests/{arm}.json")
        g = man["gate"]
        keep = []
        for j, k in enumerate(novel):
            legal = [bool(x) for x in t["legal"][k].tolist()]
            qv = [float(v) for v in t["teacher_q"][k, 0].tolist()]
            lq = sorted([qv[s] for s in range(6) if legal[s]], reverse=True)
            rec = {"driver_regret": max(0.0, lq[0] - qv[int(sel[k])]),
                   "teacher_margin": lq[0] - lq[1] if len(lq) > 1 else 0.0}
            if arm_predicate(g["kind"], g["driver_regret_thr"],
                             g["teacher_margin_thr"], rec):
                keep.append(j)
        assert keep == man["retained_positions"], arm


def test_sg0_05_no_argmax_filtering():
    # gate spec carries only regret/margin thresholds; membership is a pure
    # function of (driver_regret, teacher_margin) — verified by SG0-04 which
    # never consults argmax identity.
    for arm in ARMS:
        g = _load(f"manifests/{arm}.json")["gate"]
        assert set(g) == {"kind", "driver_regret_thr", "teacher_margin_thr"}
        assert g["kind"] in ("R", "M", "OR", "AND")


def test_sg0_06_correction_mass_reported():
    stats = _load("gate_stats/all_arms.json")
    for arm in ARMS:
        s = stats[arm]
        assert s["retained"] > 0
        assert 0.0 < s["correction_frac"] <= 1.0
        assert s["correction_density"] > 0.0
        assert s["large_retained"] + (s["large_total"] - s["large_retained"]) \
            == s["large_total"]


def test_sg0_07_tie_removal_reported():
    stats = _load("gate_stats/all_arms.json")
    for arm in ARMS:
        s = stats[arm]
        assert s["retained"] + s["excluded"] == s["d3_pool"] == 5408
        assert s["tie_retained"] <= s["retained"]
    # at least one arm must remove substantial low-value mass
    assert any(stats[a]["frac_retained"] < 0.30 for a in ARMS)


def test_sg0_08_sources_immutable():
    # siggate writes no train shards; only tiny audit shards + manifests.
    for dirpath, _dirs, files in os.walk(ROOT):
        for fn in files:
            if fn in ("train.pt", "validation.pt", "test.pt"):
                assert "tiny_" in dirpath or "audit" in dirpath, \
                    os.path.join(dirpath, fn)
    test_sg0_01_sources_verified()


def test_sg0_09_architecture_unchanged():
    from python_jev.model import JevPolicyV0

    ref = set(JevPolicyV0().state_dict())
    for arm in ARMS:
        for seed in SEEDS:
            ckpt = torch.load(os.path.join(ROOT, "checkpoints", arm, f"seed{seed}.pt"),
                              map_location="cpu", weights_only=False)
            assert set(ckpt["state_dict"]) == ref
            assert sum(v.numel() for v in ckpt["state_dict"].values()) == 1014430
            cv = ckpt["contract_versions"]
            assert cv["policy_target_version"] == "policy-target-v0.1.0"
            assert cv["value_target_version"] == "value-target-v0.1.0"
            assert ckpt["model_config"]["fusion_latent_dim"] == 512
            assert ckpt["experimental"] is True and ckpt["production"] is False


def test_sg0_10_three_seeds_per_arm():
    for arm in ARMS:
        rec = _load(f"checkpoints/{arm}/training.json")
        assert sorted(int(s) for s in rec["seeds"]) == [42, 43, 44]
        for seed in SEEDS:
            p = os.path.join(ROOT, "checkpoints", arm, f"seed{seed}.pt")
            assert os.path.exists(p)
            h = rec["seeds"][str(seed)]["history"]
            assert len(h["train_loss"]) == len(h["val_loss"]) >= 1


def test_sg0_11_selection_is_frozen_val_ce():
    import hashlib as _h

    va = os.path.join("artifacts", "jev_dagger_v2", "dataset_v05", "validation.pt")
    vb = os.path.join("artifacts", "jev_training_v1", "dataset", "validation.pt")
    assert _h.sha256(open(va, "rb").read()).hexdigest() == \
        _h.sha256(open(vb, "rb").read()).hexdigest()
    for arm in ARMS:
        rec = _load(f"checkpoints/{arm}/training.json")
        assert rec["selection_rule"] == \
            "lowest validation soft-target cross entropy"
        best = min(rec["seeds"], key=lambda s: rec["seeds"][s]["best_val_loss"])
        assert rec["selected_seed"] == int(best)


def _offline_models() -> dict:
    return _load("validation/offline.json")["models"]


def test_sg0_12_visited_validation_produced():
    for tag, m in _offline_models().items():
        assert m["visited_v04"]["n"] == 1536, tag
        assert m["visited_frozen_a1"]["n"] > 0, tag


def test_sg0_13_high_signal_produced():
    for tag, m in _offline_models().items():
        assert m["d3_high"]["n"] == 519, tag


def test_sg0_14_low_agree_produced():
    for tag, m in _offline_models().items():
        assert m["d3_low"]["n"] == 2372, tag
        assert m["d3_agree"]["n"] == 2214, tag


def test_sg0_15_scout_produced():
    sc = _load("scout/scout.json")
    assert sc["n"] == 1341
    for skill in ("EVADE", "RECON_ADVANCE", "SHADOW", "HARASS", "SCREEN", "REGROUP"):
        assert skill in sc["argmax_freq"], skill


def test_sg0_16_iid_test_produced():
    for tag, m in _offline_models().items():
        assert m["test"]["n"] == 1531, tag


def test_sg0_17_closedloop_produced():
    comp = _load("closedloop/comparison.json")["blue_vs_simple_red"]
    for tag in ("v04", "v05", *ARMS, "Simple"):
        assert tag in comp, tag
        assert comp[tag]["battles"] == 24, tag


def test_sg0_18_oracle_produced():
    import pytest

    rep = _load("oracle/oracle_gap.json")
    assert rep["oracle_exchange"] == pytest.approx(-2.8333333333333335)
    assert len(rep["subset_scenario_ids"]) == 6
    for tag in ("v04", "v05", *ARMS):
        assert tag in rep["models"], tag


def test_sg0_19_exam_produced():
    rep = _load("exam/exam.json")
    for tag in ("v04", "v05", *ARMS):
        assert rep[tag]["cases"] == 60, tag


def test_sg0_20_gradients_produced():
    rep = _load("gradients/retained.json")
    for arm in ARMS:
        assert rep[arm]["n_retained"] > 0
        assert rep[arm]["grad_norm_512"] > 0.0


def test_sg0_21_or_robustness_present():
    for arm in ("or10", "or25", "or50"):
        assert arm in _offline_models()
        assert arm in _load("closedloop/comparison.json")["blue_vs_simple_red"]


def test_sg0_22_no_production_freeze():
    assert not os.path.exists("artifacts/jev_training_v6")
    assert not os.path.exists("artifacts/jev_dagger_v3")
    for _dir, _ds, files in os.walk(ROOT):
        for fn in files:
            assert "v0.6" not in fn and "v06" not in fn, fn
    for arm in ARMS:
        for seed in SEEDS:
            ckpt = torch.load(os.path.join(ROOT, "checkpoints", arm, f"seed{seed}.pt"),
                              map_location="cpu", weights_only=False)
            assert "siggate" in ckpt["model_version"] and "-exp" in ckpt["model_version"]


def test_sg0_23_invalid_zero():
    comp = _load("closedloop/comparison.json")["blue_vs_simple_red"]
    for tag in ("v04", "v05", *ARMS):
        assert comp[tag]["blue_invalid_rate"] == 0, tag


def test_sg0_25_no_dagger4():
    assert not os.path.exists("artifacts/jev_dagger_v3")
    for dirpath, _dirs, files in os.walk(ROOT):
        for fn in files + [os.path.basename(dirpath)]:
            low = fn.lower()
            assert "dagger4" not in low and "dagger_4" not in low, fn


def test_sg0_26_no_fog_rl():
    import pathlib

    banned = ("self_play", "self-play", "PPO", "REINFORCE", "TERRAIN_FOG",
              "FLAT_FOG", "MORALE_COMBAT")
    for path in pathlib.Path("python_jev/siggate").glob("*.py"):
        text = path.read_text(encoding="utf-8")
        for tok in banned:
            assert tok not in text, f"{path}:{tok}"
    stats = _load("gate_stats/all_arms.json")
    for arm in ARMS:
        for profile in stats[arm]["profile_dist"]:
            assert profile in ("DEV_FLAT_ALL_INFO", "TERRAIN_FULL_INFO"), profile


def test_sg0_27_handoff_next():
    path = os.path.join("docs", "JEV", "SIGNIFICANCE_GATE_V0_HANDOFF.md")
    assert os.path.exists(path)
    text = open(path, encoding="utf-8").read()
    assert "NEXT" in text
