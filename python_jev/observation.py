"""Typed, loudly-validated observation tensors for the Jev v0 policy.

`ObservationBatchV0` is the single forward-contract type. WorldTruth metadata
has no field here and no path into the model: the anti-leakage invariant is
enforced by construction because the forward contract simply cannot express a
hidden-truth input. Anything not listed below is rejected, so hidden state
cannot ride along in extra attributes.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import torch
from torch import Tensor

from python_jev.constants import (
    ACTION_SPACE,
    LEARNED_CLASSES,
    NUM_SKILL_SLOTS,
    PATCH_NUM_CELLS,
)
from python_jev.layout import (
    ACTOR_FEATURE_DIM,
    GLOBAL_FEATURE_DIM,
    HEX_FEATURE_DIM,
    LEGAL_MASK_DIM,
    MISSION_FEATURE_DIM,
    TOKEN_CAPACITY,
    TOKEN_FEATURE_DIM,
)


@dataclass(frozen=True)
class ObservationBatchV0:
    """One batch of faction-authorized actor-centric observations.

    Shape conventions (B = batch size):
      actor_features          [B, ACTOR_FEATURE_DIM]
      tokens                  [B, TOKEN_CAPACITY, TOKEN_FEATURE_DIM]
      token_padding_mask      [B, TOKEN_CAPACITY]  (True = padded, no influence)
      hex_patch               [B, PATCH_NUM_CELLS, HEX_FEATURE_DIM]
      hex_padding_mask        [B, PATCH_NUM_CELLS] (True = padded; normally all False)
      mission_features        [B, MISSION_FEATURE_DIM]
      global_features         [B, GLOBAL_FEATURE_DIM]
      legal_mask              [B, NUM_SKILL_SLOTS] (True = legal/selectable)
      acting_class_idx        [B] long in [0, len(LEARNED_CLASSES))
    """

    actor_features: Tensor
    tokens: Tensor
    token_padding_mask: Tensor
    hex_patch: Tensor
    hex_padding_mask: Tensor
    mission_features: Tensor
    global_features: Tensor
    legal_mask: Tensor
    acting_class_idx: Tensor
    metadata: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        _validate_observation(self)

    # -- convenience --------------------------------------------------------
    @property
    def batch_size(self) -> int:
        return int(self.actor_features.shape[0])

    def to(self, device: torch.device | str, dtype: torch.dtype) -> "ObservationBatchV0":
        """Device/dtype move that keeps masks long/bool and class indices long."""
        return ObservationBatchV0(
            actor_features=self.actor_features.to(device=device, dtype=dtype),
            tokens=self.tokens.to(device=device, dtype=dtype),
            token_padding_mask=self.token_padding_mask.to(device=device),
            hex_patch=self.hex_patch.to(device=device, dtype=dtype),
            hex_padding_mask=self.hex_padding_mask.to(device=device),
            mission_features=self.mission_features.to(device=device, dtype=dtype),
            global_features=self.global_features.to(device=device, dtype=dtype),
            legal_mask=self.legal_mask.to(device=device),
            acting_class_idx=self.acting_class_idx.to(device=device),
            metadata=dict(self.metadata),
        )


def _validate_observation(obs: ObservationBatchV0) -> None:
    B = obs.actor_features.shape[0]

    def _require(cond: bool, msg: str) -> None:
        if not cond:
            raise ValueError(msg)

    _require(obs.actor_features.ndim == 2, "actor_features must be [B, D]")
    _require(obs.actor_features.shape == (B, ACTOR_FEATURE_DIM),
             f"actor_features must be [B, {ACTOR_FEATURE_DIM}], got {tuple(obs.actor_features.shape)}")
    _require(obs.tokens.ndim == 3, "tokens must be [B, N, D]")
    _require(0 <= obs.tokens.shape[1] <= TOKEN_CAPACITY,
             f"tokens second dim must be in [0, {TOKEN_CAPACITY}] (production "
             f"projectors emit full capacity; sub-capacity/empty buffers are "
             f"allowed for verification only), got {tuple(obs.tokens.shape)}")
    _require(obs.token_padding_mask.shape == obs.tokens.shape[:2],
             f"token_padding_mask must be [B, N] matching tokens, got {tuple(obs.token_padding_mask.shape)}")
    _require(obs.hex_patch.shape == (B, PATCH_NUM_CELLS, HEX_FEATURE_DIM),
             f"hex_patch must be exactly [B, {PATCH_NUM_CELLS}, {HEX_FEATURE_DIM}] "
             f"(frozen radius-5 patch of exactly 91 cells), got {tuple(obs.hex_patch.shape)}")
    _require(obs.hex_padding_mask.shape == (B, PATCH_NUM_CELLS),
             f"hex_padding_mask must be [B, {PATCH_NUM_CELLS}]")
    _require(obs.mission_features.shape == (B, MISSION_FEATURE_DIM),
             f"mission_features must be [B, {MISSION_FEATURE_DIM}], got {tuple(obs.mission_features.shape)}")
    _require(obs.global_features.shape == (B, GLOBAL_FEATURE_DIM),
             f"global_features must be [B, {GLOBAL_FEATURE_DIM}], got {tuple(obs.global_features.shape)}")
    _require(obs.legal_mask.shape == (B, NUM_SKILL_SLOTS),
             f"legal_mask must be [B, {NUM_SKILL_SLOTS}], got {tuple(obs.legal_mask.shape)}")
    _require(obs.acting_class_idx.shape == (B,), "acting_class_idx must be [B]")
    _require(bool(obs.acting_class_idx.min() >= 0 and obs.acting_class_idx.max() < len(LEARNED_CLASSES)),
             "acting_class_idx values must index the five learned classes (HQ is not learned)")

    _require(bool(torch.isfinite(obs.actor_features).all()), "actor_features contains NaN/Inf")
    _require(bool(torch.isfinite(obs.tokens).all()), "tokens contain NaN/Inf")
    _require(bool(torch.isfinite(obs.hex_patch).all()), "hex_patch contains NaN/Inf")
    _require(bool(torch.isfinite(obs.mission_features).all()), "mission_features contains NaN/Inf")
    _require(bool(torch.isfinite(obs.global_features).all()), "global_features contains NaN/Inf")

    _require(obs.token_padding_mask.dtype == torch.bool, "token_padding_mask must be bool")
    _require(obs.hex_padding_mask.dtype == torch.bool, "hex_padding_mask must be bool")
    _require(obs.legal_mask.dtype == torch.bool, "legal_mask must be bool")


def stack_observations(obs: ObservationBatchV0, other: ObservationBatchV0) -> ObservationBatchV0:
    """Concatenate two batches along the batch dimension."""
    return ObservationBatchV0(
        actor_features=torch.cat([obs.actor_features, other.actor_features], dim=0),
        tokens=torch.cat([obs.tokens, other.tokens], dim=0),
        token_padding_mask=torch.cat([obs.token_padding_mask, other.token_padding_mask], dim=0),
        hex_patch=torch.cat([obs.hex_patch, other.hex_patch], dim=0),
        hex_padding_mask=torch.cat([obs.hex_padding_mask, other.hex_padding_mask], dim=0),
        mission_features=torch.cat([obs.mission_features, other.mission_features], dim=0),
        global_features=torch.cat([obs.global_features, other.global_features], dim=0),
        legal_mask=torch.cat([obs.legal_mask, other.legal_mask], dim=0),
        acting_class_idx=torch.cat([obs.acting_class_idx, other.acting_class_idx], dim=0),
        metadata={**obs.metadata, **other.metadata},
    )


def class_names_for(obs: ObservationBatchV0) -> list[str]:
    """Per-batch-element acting class names (validated against the frozen table)."""
    for idx in obs.acting_class_idx.tolist():
        ACTION_SPACE[LEARNED_CLASSES[idx]]
    return [LEARNED_CLASSES[idx] for idx in obs.acting_class_idx.tolist()]
