"""Single-decision JEV inference helper (closed-loop + exam shared)."""

from __future__ import annotations

import torch

from python_jev.constants import ALL_ILLEGAL_SLOT, PATCH_NUM_CELLS
from python_jev.observation import ObservationBatchV0

CLASS_TO_UPPER = {
    "infantry": "INFANTRY", "spearman": "SPEARMAN", "cavalry": "CAVALRY",
    "archer": "ARCHER", "scout": "SCOUT",
}


def batch_from_projection(proj, legal_mask: list[bool]) -> ObservationBatchV0:
    """Build a batch-1 ObservationBatchV0 from a ProjectedObservation."""
    return ObservationBatchV0(
        actor_features=torch.tensor([list(proj.actor_features)], dtype=torch.float32),
        tokens=torch.tensor([[list(t) for t in proj.tokens]], dtype=torch.float32),
        token_padding_mask=torch.tensor([list(proj.token_padding_mask)], dtype=torch.bool),
        hex_patch=torch.tensor([[list(h) for h in proj.hex_patch]], dtype=torch.float32),
        hex_padding_mask=torch.zeros(1, PATCH_NUM_CELLS, dtype=torch.bool),
        mission_features=torch.tensor([list(proj.mission_features)], dtype=torch.float32),
        global_features=torch.tensor([list(proj.global_features)], dtype=torch.float32),
        legal_mask=torch.tensor([list(legal_mask)], dtype=torch.bool),
        acting_class_idx=torch.tensor([int(proj.acting_class_idx)], dtype=torch.long),
        metadata={},
    )


@torch.no_grad()
def select_slot(model, batch: ObservationBatchV0, device) -> dict:
    """Masked greedy selection for one batch (no training, no sampling)."""
    was_training = model.training
    model.eval()
    out = model(batch.to(device, torch.float32))
    if was_training:
        model.train()
    return {
        "selected_slot": [int(x) for x in out.selected_slot.cpu().tolist()],
        "selected_prob": [float(x) for x in out.selected_prob.cpu().tolist()],
        "probabilities": [list(map(float, r)) for r in out.probabilities.cpu().tolist()],
        "all_illegal": [bool(x) for x in out.all_illegal.cpu().tolist()],
    }


__all__ = ["ALL_ILLEGAL_SLOT", "CLASS_TO_UPPER", "batch_from_projection", "select_slot"]
