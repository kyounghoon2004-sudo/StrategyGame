"""Observation-safe legality masking.

The mask is deterministic game-rule information computed upstream from the
acting faction's authorized knowledge — never from WorldTruth — and is applied
to the six logits exactly once, before selection. An all-zero mask is an
explicit safe-failure condition, never a silent skill choice.
"""

from __future__ import annotations

from dataclasses import dataclass

import torch
from torch import Tensor

from python_jev.constants import ALL_ILLEGAL_SLOT

NEG_INF = float("-inf")


@dataclass(frozen=True)
class LegalMaskResult:
    """Result of masking a [B, 6] logit tensor with a [B, 6] bool legal mask."""

    masked_logits: Tensor   # [B, 6], illegal slots = -inf
    probabilities: Tensor   # [B, 6], zero at illegal slots, rows sum to 1.0 or 0.0
    selected_slot: Tensor   # [B] long, ALL_ILLEGAL_SLOT where nothing is selectable
    all_illegal: Tensor     # [B] bool


def apply_legal_mask(logits: Tensor, legal_mask: Tensor) -> LegalMaskResult:
    """Apply the observation-safe legality mask.

    Illegal slots become -inf, making them impossible to select by any
    downstream argmax / softmax / sampling. Rows whose mask is all-False do
    NOT silently choose a skill: their probability row is all zeros and their
    selected slot is the explicit ALL_ILLEGAL sentinel.

    Args:
        logits: [B, 6] raw class-head logits.
        legal_mask: [B, 6] bool, True = legal/selectable (observation-safe).
    """
    if logits.ndim != 2 or logits.shape[-1] != legal_mask.shape[-1]:
        raise ValueError(
            f"logits must be [B, S] aligned with legal_mask; got "
            f"{tuple(logits.shape)} vs {tuple(legal_mask.shape)}"
        )
    if legal_mask.dtype != torch.bool:
        raise ValueError(f"legal_mask must be bool, got {legal_mask.dtype}")
    if logits.shape != legal_mask.shape:
        raise ValueError(
            f"logits and legal_mask batch shapes differ: "
            f"{tuple(logits.shape)} vs {tuple(legal_mask.shape)}"
        )

    masked = logits.masked_fill(~legal_mask, NEG_INF)

    any_legal = legal_mask.any(dim=-1)                                   # [B]
    safe_masked = torch.where(
        any_legal.unsqueeze(-1), masked, torch.zeros_like(masked)
    )
    probs = torch.softmax(safe_masked, dim=-1)
    probs = torch.where(any_legal.unsqueeze(-1), probs, torch.zeros_like(probs))

    selected = masked.argmax(dim=-1)                                     # [B]
    selected = torch.where(
        any_legal,
        selected,
        torch.full_like(selected, ALL_ILLEGAL_SLOT),
    )

    return LegalMaskResult(
        masked_logits=masked,
        probabilities=probs,
        selected_slot=selected,
        all_illegal=~any_legal,
    )


def normalized_entropy(probabilities: Tensor) -> Tensor:
    """Entropy of [B, 6] probability rows normalized to [0, 1] over log(6).

    All-illegal rows (all-zero probabilities) report 0.0 entropy.
    """
    log6 = float(torch.log(torch.tensor(6.0, dtype=probabilities.dtype)))
    p = probabilities.clamp_min(0.0)
    ent = -(p * p.clamp_min(1e-12).log()).sum(dim=-1)
    ent = torch.where(p.sum(dim=-1) > 0, ent, torch.zeros_like(ent))
    return (ent / log6).clamp(0.0, 1.0)
