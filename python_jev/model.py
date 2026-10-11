"""JevPolicyV0 — the untrained tactical policy skeleton.

One shared trunk (token/hex/actor/mission/global encoders + fusion MLP) with
five class-specific six-logit heads. No recurrence, no WorldTruth input, no
prose: Observation_t -> six logits -> observation-safe mask -> one skill.
"""

from __future__ import annotations

import torch
from torch import Tensor, nn

from python_jev.constants import LEARNED_CLASSES, NUM_SKILL_SLOTS
from python_jev.encoders import (
    ActorEncoder,
    GlobalEncoder,
    HexEncoder,
    MissionEncoder,
    TokenEncoder,
    UnitContextPool,
)
from python_jev.layout import ACTOR_FEATURE_DIM
from python_jev.masking import apply_legal_mask
from python_jev.observation import ObservationBatchV0
from python_jev.output import JevPolicyOutput, build_output

# Architecture family per the v0 target: token embeddings 64–128,
# fusion latent 256–512, 2–3 lightweight encoder layers.
DEFAULT_TOKEN_EMBED = 128
DEFAULT_CONTEXT_EMBED = 128
DEFAULT_HIDDEN = 256
DEFAULT_FUSION_LATENT = 512


class FusionTrunk(nn.Module):
    """Concatenation of the five context vectors + 2-layer fusion MLP."""

    def __init__(self, embed_dim: int, latent_dim: int) -> None:
        super().__init__()
        trunk_in = embed_dim * 5  # actor+mission+global+unit+hex contexts, all embed_dim
        self.mlp = nn.Sequential(
            nn.Linear(trunk_in, latent_dim),
            nn.LayerNorm(latent_dim),
            nn.GELU(),
            nn.Linear(latent_dim, latent_dim),
            nn.LayerNorm(latent_dim),
            nn.GELU(),
        )
        self.out_dim = latent_dim

    def forward(self, actor_ctx: Tensor, mission_ctx: Tensor, global_ctx: Tensor,
                unit_ctx: Tensor, spatial_ctx: Tensor) -> Tensor:
        fused = torch.cat([actor_ctx, mission_ctx, global_ctx, unit_ctx, spatial_ctx], dim=-1)
        return self.mlp(fused)


class ClassHeads(nn.Module):
    """Five class-specific six-logit heads over the shared tactical latent."""

    def __init__(self, latent_dim: int) -> None:
        super().__init__()
        self.heads = nn.ModuleList(
            nn.Linear(latent_dim, NUM_SKILL_SLOTS) for _ in LEARNED_CLASSES
        )

    def forward(self, latent: Tensor, acting_class_idx: Tensor) -> Tensor:
        # latent: [B, L]; acting_class_idx: [B] long
        stacked = torch.stack([head(latent) for head in self.heads], dim=1)  # [B, 5, 6]
        idx = acting_class_idx.view(-1, 1, 1).expand(-1, 1, NUM_SKILL_SLOTS)
        return stacked.gather(1, idx).squeeze(1)                             # [B, 6]


class JevPolicyV0(nn.Module):
    """Shared-trunk, class-head tactical policy. Stateless in v0: no GRU/LSTM
    or recurrent Transformer state; FactionKnowledge carries persistence."""

    def __init__(
        self,
        token_embed_dim: int = DEFAULT_TOKEN_EMBED,
        context_embed_dim: int = DEFAULT_CONTEXT_EMBED,
        hidden_dim: int = DEFAULT_HIDDEN,
        fusion_latent_dim: int = DEFAULT_FUSION_LATENT,
    ) -> None:
        super().__init__()
        self.token_encoder = TokenEncoder(token_embed_dim, hidden_dim)
        self.unit_pool = UnitContextPool(token_embed_dim, ACTOR_FEATURE_DIM, hidden_dim)
        self.hex_encoder = HexEncoder(context_embed_dim, ACTOR_FEATURE_DIM, hidden_dim)
        self.actor_encoder = ActorEncoder(context_embed_dim, hidden_dim)
        self.mission_encoder = MissionEncoder(context_embed_dim, hidden_dim)
        self.global_encoder = GlobalEncoder(context_embed_dim, hidden_dim)
        self.trunk = FusionTrunk(context_embed_dim, fusion_latent_dim)
        self.class_heads = ClassHeads(fusion_latent_dim)

    def forward(self, obs: ObservationBatchV0) -> JevPolicyOutput:
        obs = obs.to(self._device(), torch.float32)

        token_embeddings = self.token_encoder(obs.tokens)                    # [B, N, E]
        unit_ctx = self.unit_pool(token_embeddings, obs.actor_features,
                                  obs.token_padding_mask)                    # [B, E]
        spatial_ctx = self.hex_encoder(obs.hex_patch, obs.actor_features)    # [B, E]
        actor_ctx = self.actor_encoder(obs.actor_features)                   # [B, E]
        mission_ctx = self.mission_encoder(obs.mission_features)             # [B, E]
        global_ctx = self.global_encoder(obs.global_features)                # [B, E]

        latent = self.trunk(actor_ctx, mission_ctx, global_ctx, unit_ctx, spatial_ctx)
        raw_logits = self.class_heads(latent, obs.acting_class_idx)          # [B, 6]

        masked = apply_legal_mask(raw_logits, obs.legal_mask)
        return build_output(
            raw_logits=raw_logits,
            legal_mask=obs.legal_mask,
            masked_logits=masked.masked_logits,
            probabilities=masked.probabilities,
            selected_slot=masked.selected_slot,
            all_illegal=masked.all_illegal,
            acting_class_idx=obs.acting_class_idx,
        )

    def _device(self) -> torch.device:
        return next(self.parameters()).device
