"""Typed inference result envelope for the Jev v0 policy.

Telemetry only — never prose, rationale, coordinates, target IDs, or
OperationalCommands. The policy output is six masked logits / probabilities,
one selected slot, and bounded confidence telemetry.
"""

from __future__ import annotations

from dataclasses import dataclass

import torch
from torch import Tensor

from python_jev.constants import MODEL_VERSION, NUM_SKILL_SLOTS
from python_jev.masking import normalized_entropy


@dataclass(frozen=True)
class JevPolicyOutput:
    """Primary output contract for a batch of observations.

    raw_logits:    [B, 6] unmasked class-head logits
    legal_mask:    [B, 6] observation-safe legality mask (True = legal)
    masked_logits: [B, 6] raw logits with illegal slots set to -inf
    probabilities: [B, 6] masked softmax; zero at illegal slots;
                   all-zero rows for all-illegal masks
    selected_slot: [B] long argmax of masked logits; ALL_ILLEGAL_SLOT (-1)
                   where the mask is all-zero
    all_illegal:   [B] bool, True where no skill is selectable
    selected_prob: [B] probability of the selected slot (0.0 if all illegal)
    norm_entropy:  [B] policy entropy normalized by log(6), in [0, 1]
    """

    raw_logits: Tensor
    legal_mask: Tensor
    masked_logits: Tensor
    probabilities: Tensor
    selected_slot: Tensor
    all_illegal: Tensor
    selected_prob: Tensor
    norm_entropy: Tensor

    @property
    def model_version(self) -> str:
        return MODEL_VERSION

    @property
    def batch_size(self) -> int:
        return int(self.raw_logits.shape[0])

    def skill_name(self, batch_index: int) -> str | None:
        """Selected skill NAME from the frozen class table, or None when the
        mask is all-illegal. Convenience for telemetry / replay logs only."""
        from python_jev.constants import ACTION_SPACE, LEARNED_CLASSES, ALL_ILLEGAL_SLOT

        slot = int(self.selected_slot[batch_index])
        if slot == ALL_ILLEGAL_SLOT:
            return None
        class_idx = int(self._acting_class_idx[batch_index])
        return ACTION_SPACE[LEARNED_CLASSES[class_idx]][slot]

    # set by the policy at construction time; not a forward input
    _acting_class_idx: Tensor | None = None


def build_output(
    raw_logits: Tensor,
    legal_mask: Tensor,
    masked_logits: Tensor,
    probabilities: Tensor,
    selected_slot: Tensor,
    all_illegal: Tensor,
    acting_class_idx: Tensor | None,
) -> JevPolicyOutput:
    if raw_logits.shape[-1] != NUM_SKILL_SLOTS:
        raise ValueError(f"raw_logits must end in {NUM_SKILL_SLOTS} slots")
    selected_prob = probabilities.gather(
        1, selected_slot.clamp_min(0).unsqueeze(-1)
    ).squeeze(-1)
    selected_prob = torch.where(
        all_illegal, torch.zeros_like(selected_prob), selected_prob
    )
    return JevPolicyOutput(
        raw_logits=raw_logits,
        legal_mask=legal_mask,
        masked_logits=masked_logits,
        probabilities=probabilities,
        selected_slot=selected_slot,
        all_illegal=all_illegal,
        selected_prob=selected_prob,
        norm_entropy=normalized_entropy(probabilities),
        _acting_class_idx=acting_class_idx,
    )
