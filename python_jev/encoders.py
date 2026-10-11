"""Jev v0 encoders.

Design rules:
  - shared encoders across all five classes (the trunk learns common
    battlefield representation; class specificity lives only in the heads),
  - permutation-safe token handling (actor-query attention pool + additive
    padding mask so padded tokens have exactly zero influence),
  - unknown never conflated with known zero (known bits travel as separate
    features into the encoders),
  - hex neighborhood relations preserved by per-cell relative-geometry
    encoding + attention-pooled aggregation (Option B: shared hex encoder +
    topology-aware lightweight aggregation, no message-passing graph stack).
"""

from __future__ import annotations

import math

import torch
from torch import Tensor, nn

from python_jev.layout import (
    ACTOR_FEATURE_DIM,
    GLOBAL_FEATURE_DIM,
    HEX_FEATURE_DIM,
    MISSION_FEATURE_DIM,
    TOKEN_FEATURE_DIM,
)


def _mlp(input_dim: int, hidden_dim: int, output_dim: int, layers: int) -> nn.Sequential:
    """Small typed MLP: Linear -> LayerNorm -> GELU blocks."""
    dims = [input_dim] + [hidden_dim] * (layers - 1) + [output_dim]
    mods: list[nn.Module] = []
    for i, (a, b) in enumerate(zip(dims[:-1], dims[1:])):
        mods.append(nn.Linear(a, b))
        if i < len(dims) - 2:
            mods.append(nn.LayerNorm(b))
            mods.append(nn.GELU())
    return nn.Sequential(*mods)


class TokenEncoder(nn.Module):
    """Shared unit/contact token encoder.

    One MLP shared by FRIENDLY / ENEMY_VISIBLE / STALE_CONTACT tokens; the
    relation kind is simply a one-hot input feature, so no semantic is
    attached to token ordering anywhere.
    """

    def __init__(self, embed_dim: int, hidden_dim: int) -> None:
        super().__init__()
        self.embed_dim = embed_dim
        self.proj = _mlp(TOKEN_FEATURE_DIM, hidden_dim, embed_dim, layers=2)

    def forward(self, tokens: Tensor) -> Tensor:
        # tokens: [B, N, TOKEN_FEATURE_DIM] -> [B, N, E]
        return self.proj(tokens)


class UnitContextPool(nn.Module):
    """Actor-conditioned attention pooling over unit/contact tokens.

    The pooled UnitContext is the actor's query attending over the encoded
    tokens. Padding is applied as an additive -inf attention bias, so padded
    tokens receive exactly zero attention weight and zero influence.
    An empty set (all tokens padded) yields the learned empty-set vector.
    """

    def __init__(self, embed_dim: int, actor_dim: int, hidden_dim: int) -> None:
        super().__init__()
        self.embed_dim = embed_dim
        self.query = nn.Linear(actor_dim, embed_dim, bias=False)
        self.key = _mlp(embed_dim, hidden_dim, embed_dim, layers=2)
        self.value = _mlp(embed_dim, hidden_dim, embed_dim, layers=2)
        self.empty_set = nn.Parameter(torch.zeros(embed_dim))

    def forward(self, token_embeddings: Tensor, actor_features: Tensor,
                token_padding_mask: Tensor) -> Tensor:
        # token_embeddings: [B, N, E]; actor_features: [B, A]
        # token_padding_mask: [B, N] bool, True = padded
        q = self.query(actor_features)                       # [B, E]
        k = self.key(token_embeddings)                       # [B, N, E]
        v = self.value(token_embeddings)                     # [B, N, E]

        scores = torch.einsum("be,bne->bn", q, k) / math.sqrt(self.embed_dim)
        scores = scores.masked_fill(token_padding_mask, float("-inf"))

        empty = token_padding_mask.all(dim=-1)               # [B]
        # All-padded rows would softmax to NaN; route them to empty-set ctx.
        scores = torch.where(
            empty.unsqueeze(-1), torch.zeros_like(scores), scores
        )
        attn = torch.softmax(scores, dim=-1)
        attn = torch.where(empty.unsqueeze(-1), torch.zeros_like(attn), attn)

        pooled = torch.einsum("bn,bne->be", attn, v)         # [B, E]
        pooled = torch.where(empty.unsqueeze(-1), self.empty_set.unsqueeze(0), pooled)
        return pooled


class HexEncoder(nn.Module):
    """Lightweight local spatial encoder over the frozen radius-5 patch.

    Option B of the freeze: a shared per-hex encoder produces hex tokens that
    already carry relative geometry (offsets, direction buckets, distance), a
    center-token query attends over all 91 cells, and the pooled context is
    concatenated with the center cell embedding. Neighborhood structure is
    therefore preserved through each cell's relative-position encoding and
    distance-weighted attention without a message-passing graph stack.

    Exactly PATCH_NUM_CELLS tokens are accepted; malformed sizes fail loudly.
    """

    def __init__(self, embed_dim: int, actor_dim: int, hidden_dim: int) -> None:
        super().__init__()
        self.embed_dim = embed_dim
        self.cell_proj = _mlp(HEX_FEATURE_DIM, hidden_dim, embed_dim, layers=2)
        self.query = nn.Linear(actor_dim, embed_dim, bias=False)
        self.key = nn.Linear(embed_dim, embed_dim, bias=False)
        self.center_proj = nn.Linear(embed_dim, embed_dim)

    def forward(self, hex_patch: Tensor, actor_features: Tensor) -> Tensor:
        # hex_patch: [B, 91, HEX_FEATURE_DIM]
        num_cells = hex_patch.shape[1]
        if num_cells != 91:
            raise ValueError(
                f"Local hex patch must contain exactly 91 cells (radius-5 "
                f"frozen contract); got {num_cells}. Malformed patch sizes "
                f"are rejected, never silently reshaped."
            )
        cells = self.cell_proj(hex_patch)                    # [B, 91, E]

        q = self.query(actor_features)                       # [B, E]
        k = self.key(cells)                                  # [B, 91, E]
        scores = torch.einsum("be,bne->bn", q, k) / math.sqrt(self.embed_dim)
        attn = torch.softmax(scores, dim=-1)                 # [B, 91]
        pooled = torch.einsum("bn,bne->be", attn, cells)     # [B, E]

        center = cells[:, 0, :]                              # actor's own cell
        return self.center_proj(pooled + center)


class ActorEncoder(nn.Module):
    def __init__(self, embed_dim: int, hidden_dim: int) -> None:
        super().__init__()
        self.proj = _mlp(ACTOR_FEATURE_DIM, hidden_dim, embed_dim, layers=2)

    def forward(self, actor_features: Tensor) -> Tensor:
        return self.proj(actor_features)


class MissionEncoder(nn.Module):
    def __init__(self, embed_dim: int, hidden_dim: int) -> None:
        super().__init__()
        self.proj = _mlp(MISSION_FEATURE_DIM, hidden_dim, embed_dim, layers=2)

    def forward(self, mission_features: Tensor) -> Tensor:
        return self.proj(mission_features)


class GlobalEncoder(nn.Module):
    def __init__(self, embed_dim: int, hidden_dim: int) -> None:
        super().__init__()
        self.proj = _mlp(GLOBAL_FEATURE_DIM, hidden_dim, embed_dim, layers=2)

    def forward(self, global_features: Tensor) -> Tensor:
        return self.proj(global_features)
