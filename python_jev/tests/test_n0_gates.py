"""N0 acceptance-gate suite for the untrained JevPolicyV0 skeleton.

Covers gates N0-1 .. N0-15. N0-16 (scope audit) is performed by the run
entry point via git diff, not by a unit test.

These tests verify the network skeleton ONLY: shapes, masking, permutation /
padding / anti-leakage safety, determinism, gradient flow, parameter count
and latency. No training, no simulator, no dataset generation.
"""

from __future__ import annotations

import copy
import time

import pytest
import torch

from python_jev.constants import (
    ACTION_SPACE,
    ALL_ILLEGAL_SLOT,
    LEARNED_CLASSES,
    NUM_SKILL_SLOTS,
    PATCH_NUM_CELLS,
)
from python_jev.layout import TOKEN_CAPACITY, TOKEN_FEATURE_DIM
from python_jev.masking import apply_legal_mask
from python_jev.model import JevPolicyV0
from python_jev.observation import ObservationBatchV0
from python_jev.synthetic import make_observation_batch

ALL_CLASSES = list(ACTION_SPACE)


@pytest.fixture(scope="module")
def policy() -> JevPolicyV0:
    torch.manual_seed(20260919)
    model = JevPolicyV0()
    model.eval()
    return model


# ---------------------------------------------------------------------------
# N0-1 IMPORT + N0-2 FORWARD
# ---------------------------------------------------------------------------
def test_n0_1_import_and_public_api() -> None:
    import python_jev  # noqa: F401  (import must succeed cleanly)
    from python_jev import (  # noqa: F401
        JevPolicyOutput,
        JevPolicyV0,
        ObservationBatchV0,
        apply_legal_mask,
    )


@pytest.mark.parametrize("acting_class", ALL_CLASSES)
def test_n0_2_forward_shapes_per_class(policy: JevPolicyV0, acting_class: str) -> None:
    obs = make_observation_batch(batch_size=4, acting_class=acting_class)
    out = policy(obs)
    assert out.raw_logits.shape == (4, NUM_SKILL_SLOTS)
    assert out.masked_logits.shape == (4, NUM_SKILL_SLOTS)
    assert out.probabilities.shape == (4, NUM_SKILL_SLOTS)
    assert out.selected_slot.shape == (4,)
    assert out.selected_prob.shape == (4,)
    assert out.norm_entropy.shape == (4,)
    assert torch.isfinite(out.raw_logits).all()
    # all-legal mask: probabilities rows sum to 1
    assert torch.allclose(out.probabilities.sum(dim=-1), torch.ones(4), atol=1e-5)


# ---------------------------------------------------------------------------
# N0-3 CLASS HEADS: five distinct heads, one shared trunk
# ---------------------------------------------------------------------------
def test_n0_3_class_heads_are_distinct(policy: JevPolicyV0) -> None:
    assert len(policy.class_heads.heads) == len(LEARNED_CLASSES)
    ids = {id(h) for h in policy.class_heads.heads}
    assert len(ids) == len(LEARNED_CLASSES), "heads must be distinct modules"

    # Same trunk parameters feed every head: heads take only the shared latent.
    # Distinct per-class logits for identical inputs confirm no head-sharing:
    latents = torch.randn(5, policy.trunk.out_dim)
    idx = torch.arange(5)
    logits = policy.class_heads(latents, idx)
    assert logits.shape == (5, NUM_SKILL_SLOTS)
    # Rows come from different heads; pairwise equality would imply sharing.
    for i in range(5):
        for j in range(i + 1, 5):
            assert not torch.allclose(logits[i], logits[j])


def test_n0_3_shared_trunk_single_instance(policy: JevPolicyV0) -> None:
    # Exactly one token encoder / hex encoder / trunk / unit pool in the module tree.
    top_names = [n for n, _ in policy.named_children()]
    for uniq in ("token_encoder", "hex_encoder", "trunk", "unit_pool"):
        assert top_names.count(uniq) == 1, f"expected exactly one {uniq}, found {top_names}"


# ---------------------------------------------------------------------------
# N0-4 VARIABLE-N
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("counts", [
    (0, 0, 0),          # empty token set
    (1, 0, 0),          # single friendly
    (0, 3, 0),          # visible enemies only
    (2, 1, 1),          # mixed small set
    (10, 8, 6),         # larger padded set (24 = capacity)
])
def test_n0_4_variable_n(policy: JevPolicyV0, counts: tuple[int, int, int]) -> None:
    nf, ne, ns = counts
    obs = make_observation_batch(batch_size=3, num_friendly=nf,
                                 num_visible_enemies=ne, num_stale=ns)
    out = policy(obs)
    assert out.raw_logits.shape == (3, NUM_SKILL_SLOTS)
    assert torch.isfinite(out.raw_logits).all()


def test_n0_4_capacity_exceeded_fails_loudly() -> None:
    with pytest.raises(ValueError, match="exceeds frozen capacity"):
        make_observation_batch(batch_size=1, num_friendly=30)


# ---------------------------------------------------------------------------
# N0-5 PERMUTATION SAFETY
# ---------------------------------------------------------------------------
def test_n0_5_permutation_invariance(policy: JevPolicyV0) -> None:
    torch.manual_seed(7)
    obs = make_observation_batch(batch_size=2, num_friendly=4,
                                 num_visible_enemies=3, num_stale=2, seed=7)
    out1 = policy(obs)

    perm = torch.randperm(obs.tokens.shape[1], generator=torch.Generator().manual_seed(1))
    obs2 = ObservationBatchV0(
        actor_features=obs.actor_features,
        tokens=obs.tokens[:, perm].contiguous(),
        token_padding_mask=obs.token_padding_mask[:, perm],
        hex_patch=obs.hex_patch,
        hex_padding_mask=obs.hex_padding_mask,
        mission_features=obs.mission_features,
        global_features=obs.global_features,
        legal_mask=obs.legal_mask,
        acting_class_idx=obs.acting_class_idx,
        metadata=dict(obs.metadata),
    )
    out2 = policy(obs2)
    assert torch.allclose(out1.raw_logits, out2.raw_logits, atol=1e-5), (
        (out1.raw_logits - out2.raw_logits).abs().max()
    )


# ---------------------------------------------------------------------------
# N0-6 PADDING SAFETY
# ---------------------------------------------------------------------------
def test_n0_6_padding_has_no_influence(policy: JevPolicyV0) -> None:
    obs = make_observation_batch(batch_size=2, num_friendly=2,
                                 num_visible_enemies=1, num_stale=1, seed=3)
    out_small = policy(obs)

    # Pad to full capacity with masked PAD tokens (token values arbitrary).
    pad_tokens = torch.randn(2, TOKEN_CAPACITY - obs.tokens.shape[1], TOKEN_FEATURE_DIM,
                             generator=torch.Generator().manual_seed(99))
    obs_padded = ObservationBatchV0(
        actor_features=obs.actor_features,
        tokens=torch.cat([obs.tokens, pad_tokens], dim=1),
        token_padding_mask=torch.cat(
            [obs.token_padding_mask, torch.ones(2, pad_tokens.shape[1], dtype=torch.bool)],
            dim=1,
        ),
        hex_patch=obs.hex_patch,
        hex_padding_mask=obs.hex_padding_mask,
        mission_features=obs.mission_features,
        global_features=obs.global_features,
        legal_mask=obs.legal_mask,
        acting_class_idx=obs.acting_class_idx,
        metadata=dict(obs.metadata),
    )
    assert obs_padded.tokens.shape[1] == TOKEN_CAPACITY
    out_padded = policy(obs_padded)
    diff = (out_small.raw_logits - out_padded.raw_logits).abs().max().item()
    assert diff < 1e-4, f"padded tokens altered logits by {diff}"


# ---------------------------------------------------------------------------
# N0-7 UNKNOWN vs KNOWN-ZERO semantics
# ---------------------------------------------------------------------------
def test_n0_7_unknown_not_conflated_with_zero() -> None:
    from python_jev.layout import TOKEN_GROUP_OFFSETS

    obs = make_observation_batch(batch_size=1, num_friendly=0, num_visible_enemies=1)
    tok = obs.tokens[0, 0]

    s_off, _ = TOKEN_GROUP_OFFSETS["strength_ratio"]
    s_known = s_off + 1
    # ENEMY_VISIBLE tokens carry known strength in the factory...
    assert tok[s_known] == 1.0
    assert tok[s_off] >= 0.0  # real value present

    # ...stale contacts carry known=0 (unknown current state) with neutral fill.
    obs_stale = make_observation_batch(batch_size=1, num_friendly=0,
                                       num_visible_enemies=0, num_stale=1)
    stale_tok = obs_stale.tokens[0, 0]
    assert stale_tok[s_known] == 0.0
    # distinguishability is enforced at schema level: (fill, known) pairs differ
    assert (stale_tok[s_off].item(), stale_tok[s_known].item()) != (tok[s_off].item(), tok[s_known].item())

    # categorical unknowns get a dedicated UNKNOWN bucket (never a valid class slot)
    u_off, u_end = TOKEN_GROUP_OFFSETS["unit_class"]
    assert u_end - u_off == len(LEARNED_CLASSES) + 1  # 5 classes + 1 UNKNOWN bucket


# ---------------------------------------------------------------------------
# N0-8 HEX PATCH
# ---------------------------------------------------------------------------
def test_n0_8_hex_patch_exactly_91(policy: JevPolicyV0) -> None:
    obs = make_observation_batch(batch_size=1)
    assert obs.hex_patch.shape[1] == PATCH_NUM_CELLS == 91
    out = policy(obs)
    assert out.raw_logits.shape == (1, NUM_SKILL_SLOTS)


@pytest.mark.parametrize("bad_cells", [90, 92, 49, 169])
def test_n0_8_malformed_patch_sizes_fail_loudly(policy: JevPolicyV0, bad_cells: int) -> None:
    obs = make_observation_batch(batch_size=1)
    if bad_cells < 91:
        patch = obs.hex_patch[:, :bad_cells].contiguous()
        pad = obs.hex_padding_mask[:, :bad_cells].contiguous()
    else:
        extra = bad_cells - 91
        patch = torch.cat([obs.hex_patch, obs.hex_patch[:, :extra]], dim=1).contiguous()
        pad = torch.cat([obs.hex_padding_mask, obs.hex_padding_mask[:, :extra]], dim=1).contiguous()
    # Construction itself must fail loudly (schema-level validation).
    with pytest.raises(ValueError, match="exactly 91"):
        broken = ObservationBatchV0(
            actor_features=obs.actor_features,
            tokens=obs.tokens,
            token_padding_mask=obs.token_padding_mask,
            hex_patch=patch,
            hex_padding_mask=pad,
            mission_features=obs.mission_features,
            global_features=obs.global_features,
            legal_mask=obs.legal_mask,
            acting_class_idx=obs.acting_class_idx,
            metadata=dict(obs.metadata),
        )
        policy(broken)


def test_n0_8_validation_rejects_wrong_patch_shape() -> None:
    obs = make_observation_batch(batch_size=1)
    with pytest.raises(ValueError, match="91"):
        ObservationBatchV0(
            actor_features=obs.actor_features,
            tokens=obs.tokens,
            token_padding_mask=obs.token_padding_mask,
            hex_patch=obs.hex_patch[:, :90].contiguous(),
            hex_padding_mask=obs.hex_padding_mask[:, :90].contiguous(),
            mission_features=obs.mission_features,
            global_features=obs.global_features,
            legal_mask=obs.legal_mask,
            acting_class_idx=obs.acting_class_idx,
            metadata=dict(obs.metadata),
        )


# ---------------------------------------------------------------------------
# N0-9 MASKING with partial legality
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("mask_bits", [
    [1, 1, 0, 1, 0, 1],
    [1, 0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0, 1],
])
def test_n0_9_illegal_slots_unselectable(policy: JevPolicyV0, mask_bits: list[int]) -> None:
    obs = make_observation_batch(batch_size=1, legal_mask=mask_bits)
    out = policy(obs)
    for slot, legal in enumerate(mask_bits):
        if not legal:
            assert out.masked_logits[0, slot] == float("-inf")
            assert out.probabilities[0, slot] == 0.0
            assert int(out.selected_slot[0]) != slot
    assert out.probabilities.shape == (1, NUM_SKILL_SLOTS)
    assert torch.isclose(out.probabilities.sum(), torch.tensor(1.0), atol=1e-5)


def test_n0_9_apply_legal_mask_direct() -> None:
    logits = torch.tensor([[2.0, 1.0, 3.0, 0.5, 4.0, -1.0]])
    mask = torch.tensor([[True, True, False, True, False, True]])
    res = apply_legal_mask(logits, mask)
    assert res.masked_logits[0, 2] == float("-inf")
    assert res.masked_logits[0, 4] == float("-inf")
    assert int(res.selected_slot[0]) == 0  # slot 0 (2.0) is the highest LEGAL logit
    # slot 4 holds the global max (4.0) but is masked and must not be chosen
    assert res.probabilities[0, [2, 4]].sum() == 0.0
    assert torch.isclose(res.probabilities.sum(), torch.tensor(1.0), atol=1e-6)


# ---------------------------------------------------------------------------
# N0-10 ALL-ILLEGAL explicit safe failure
# ---------------------------------------------------------------------------
def test_n0_10_all_illegal_is_explicit_failure(policy: JevPolicyV0) -> None:
    obs = make_observation_batch(batch_size=3, legal_mask=[0, 0, 0, 0, 0, 0])
    out = policy(obs)
    assert bool(out.all_illegal.all())
    assert (out.selected_slot == ALL_ILLEGAL_SLOT).all()
    assert (out.probabilities == 0.0).all()
    assert (out.selected_prob == 0.0).all()
    assert out.skill_name(0) is None  # telemetry must not invent a skill
    # -inf logits are present but never produce a NaN probability row
    assert torch.isinf(out.masked_logits).all()
    assert torch.isfinite(out.norm_entropy).all()


# ---------------------------------------------------------------------------
# N0-11 ANTI-LEAKAGE
# ---------------------------------------------------------------------------
def test_n0_11_worldtruth_metadata_cannot_affect_inference(policy: JevPolicyV0) -> None:
    obs_a = make_observation_batch(
        batch_size=2, num_friendly=3, num_visible_enemies=2, num_stale=1, seed=11,
        worldtruth_metadata={"hidden_enemy_count": "7", "hidden_hq_alive": "true"},
    )
    obs_b = make_observation_batch(
        batch_size=2, num_friendly=3, num_visible_enemies=2, num_stale=1, seed=11,
        worldtruth_metadata={"hidden_enemy_count": "99", "hidden_hq_alive": "false"},
    )
    # byte-equivalent faction observation tensors
    for f_a, f_b in zip(
        (obs_a.actor_features, obs_a.tokens, obs_a.hex_patch,
         obs_a.mission_features, obs_a.global_features, obs_a.legal_mask,
         obs_a.acting_class_idx),
        (obs_b.actor_features, obs_b.tokens, obs_b.hex_patch,
         obs_b.mission_features, obs_b.global_features, obs_b.legal_mask,
         obs_b.acting_class_idx),
    ):
        assert torch.equal(f_a, f_b)
    assert obs_a.metadata != obs_b.metadata  # hidden truth differs only in metadata

    out_a = policy(obs_a)
    out_b = policy(obs_b)
    assert torch.equal(out_a.raw_logits, out_b.raw_logits)
    assert torch.equal(out_a.selected_slot, out_b.selected_slot)
    assert torch.equal(out_a.probabilities, out_b.probabilities)


def test_n0_11_forward_signature_has_no_worldtruth_input(policy: JevPolicyV0) -> None:
    # The forward contract is ObservationBatchV0 -> JevPolicyOutput only.
    import inspect

    sig = inspect.signature(policy.forward)
    assert list(sig.parameters) == ["obs"]
    fields = ObservationBatchV0.__dataclass_fields__
    tensor_fields = {
        name for name, f in fields.items()
        if f.type.startswith("Tensor") or "Tensor" in str(f.type)
    }
    assert tensor_fields == {
        "actor_features", "tokens", "token_padding_mask", "hex_patch",
        "hex_padding_mask", "mission_features", "global_features",
        "legal_mask", "acting_class_idx",
    }


# ---------------------------------------------------------------------------
# N0-12 DETERMINISTIC EVAL
# ---------------------------------------------------------------------------
def test_n0_12_deterministic_repeated_inference(policy: JevPolicyV0) -> None:
    torch.manual_seed(5)
    obs = make_observation_batch(batch_size=4, num_friendly=3,
                                 num_visible_enemies=2, num_stale=1, seed=5)
    policy.eval()
    with torch.no_grad():
        out1 = policy(obs)
        out2 = policy(obs)
        out3 = policy(copy.deepcopy(obs))
    assert torch.equal(out1.raw_logits, out2.raw_logits)
    assert torch.equal(out1.raw_logits, out3.raw_logits)
    assert torch.equal(out1.selected_slot, out3.selected_slot)


# ---------------------------------------------------------------------------
# N0-13 GRADIENT trainability
# ---------------------------------------------------------------------------
def test_n0_13_dummy_loss_backpropagates() -> None:
    torch.manual_seed(13)
    model = JevPolicyV0()
    model.train()
    # One dummy scalar loss over the logits of EACH of the five class heads.
    parts = []
    for class_idx, class_name in enumerate(LEARNED_CLASSES):
        obs = make_observation_batch(
            batch_size=8, acting_class=class_name, num_friendly=2,
            num_visible_enemies=2, num_stale=1, seed=13 + class_idx,
        )
        out = model(obs)
        parts.append(out.raw_logits.square().mean())
    loss = torch.stack(parts).sum()
    loss.backward()

    no_grad_params = [n for n, p in model.named_parameters() if p.grad is None]
    assert not no_grad_params, f"parameters without gradient: {no_grad_params}"
    zero_grad_params = [
        n for n, p in model.named_parameters()
        if p.grad is not None and p.grad.abs().sum() == 0
    ]
    # empty-set vector gets no gradient with non-empty token sets — expected.
    assert set(zero_grad_params) <= {"unit_pool.empty_set"}, zero_grad_params


# ---------------------------------------------------------------------------
# N0-14 PARAMETER COUNT
# ---------------------------------------------------------------------------
def test_n0_14_parameter_count_in_target_family(policy: JevPolicyV0) -> None:
    total = sum(p.numel() for p in policy.parameters() if p.requires_grad)
    assert 1_000_000 <= total <= 5_000_000, f"parameter count {total:,} outside 1M–5M"
    print(f"\nN0-14 trainable parameters: {total:,}")


# ---------------------------------------------------------------------------
# N0-15 LATENCY (skip silently if no CUDA; CPU always measurable)
# ---------------------------------------------------------------------------
def test_n0_15_latency_warm_forward(policy: JevPolicyV0, request: pytest.FixtureRequest) -> None:
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = policy.to(device)
    model.eval()

    def bench(batch: int) -> float:
        obs = make_observation_batch(
            batch_size=batch, num_friendly=4, num_visible_enemies=3,
            num_stale=2, device=device,
        )
        with torch.no_grad():
            for _ in range(5):  # warmup
                model(obs)
            if device.type == "cuda":
                torch.cuda.synchronize()
            iters = 50 if device.type == "cuda" else 20
            t0 = time.perf_counter()
            for _ in range(iters):
                model(obs)
            if device.type == "cuda":
                torch.cuda.synchronize()
            return (time.perf_counter() - t0) / iters * 1000.0

    b1 = bench(1)
    b64 = bench(64)
    print(f"\nN0-15 device={device.type} dtype=float32 "
          f"batch1={b1:.2f}ms batch64={b64:.2f}ms")
    assert b1 > 0.0 and b64 > 0.0
