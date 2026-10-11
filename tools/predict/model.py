"""Game-native prediction model (2026-10-08): one token per unit, a transformer over the units with a learned bias
per hex-distance bucket in every attention head, and four heads:
  action  per own unit: action type (tools/predict/data.ACT) and, for ATTACK, a pointer to the enemy it hits
  outcome per unit: share of soldiers lost in this phase, destroyed or not
  intent  per enemy unit: a pointer to the own unit it will attack next (or a learned "none")
  value   win / draw / loss for the side about to act
Given the acting side's actions for this phase (act_in / hit_in, 2026-10-08), the same network answers "what if":
outcome and value conditioned on those actions (one pass per candidate action set).
"""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F

from tools.predict.data import ACT

# The eval-mode "fast path" of nn.TransformerEncoderLayer treats the per-head float distance bias differently from
# training and returned NaN; one code path for both.
torch.backends.mha.set_fastpath_enabled(False)


def load(path, feat: int, dev):
    """A trained predictor; its size comes from model.json next to the weights (2026-10-09; none = the default size)."""
    import json
    from pathlib import Path
    cfg = Path(path).with_name("model.json")
    kw = json.loads(cfg.read_text(encoding="utf-8")) if cfg.exists() else {}
    m = Predictor(feat, **kw).to(dev)
    m.load_state_dict(torch.load(path, map_location=dev))
    return m


class Predictor(nn.Module):
    def __init__(self, feat: int, d: int = 128, layers: int = 4, heads: int = 4, buckets: int = 16):
        super().__init__()
        self.heads = heads
        self.inp = nn.Sequential(nn.Linear(feat, d), nn.GELU(), nn.Linear(d, d))
        self.act_emb = nn.Embedding(len(ACT) + 1, d)  # index len(ACT) = action not given
        self.hit_proj = nn.Linear(1, d)  # how many own units attack this unit this phase
        self.dist_bias = nn.Embedding(buckets, heads * layers)
        self.layers = nn.ModuleList(nn.TransformerEncoderLayer(d, heads, 4 * d, dropout=0.1, batch_first=True,
                                                               norm_first=True) for _ in range(layers))
        self.norm = nn.LayerNorm(d)
        self.act = nn.Linear(d, len(ACT))
        self.atk_q, self.atk_k = nn.Linear(d, d), nn.Linear(d, d)
        self.out_lost, self.out_dead = nn.Linear(d, 1), nn.Linear(d, 1)
        self.int_q, self.int_k = nn.Linear(d, d), nn.Linear(d, d)
        self.int_none = nn.Parameter(torch.zeros(d))
        self.value = nn.Sequential(nn.Linear(2 * d, d), nn.GELU(), nn.Linear(d, 3))

    def forward(self, feat, dist, own, mask, act_in=None, hit_in=None):
        """feat [B,N,F], dist [B,N,N] buckets, own [B,N] bool, mask [B,N] True = real unit.
        act_in [B,N] long: the action each own unit takes this phase (len(ACT) = not given); hit_in [B,N] float: own
        attacks on each unit this phase. Both None: the plain state prediction."""
        b, n, _ = feat.shape
        h = self.inp(feat)
        if act_in is not None:
            h = h + self.act_emb(act_in) + self.hit_proj(hit_in[..., None])
        bias_all = self.dist_bias(dist)  # [B,N,N,H*L]
        pad = torch.zeros(b, 1, 1, n, device=feat.device).masked_fill(~mask[:, None, None, :], float("-inf"))
        for i, layer in enumerate(self.layers):
            bias = bias_all[..., i * self.heads:(i + 1) * self.heads].permute(0, 3, 1, 2) + pad  # [B,H,N,N]
            h = layer(h, src_mask=bias.reshape(b * self.heads, n, n))
        h = self.norm(h)
        scale = h.shape[-1] ** -0.5
        enemy = mask & ~own
        atk = (self.atk_q(h) @ self.atk_k(h).transpose(1, 2)) * scale  # own query -> enemy key
        atk = atk.masked_fill(~enemy[:, None, :], float("-inf"))
        keys = torch.cat([self.int_k(h), self.int_none.expand(b, 1, -1)], 1)  # own units + "none"
        intent = (self.int_q(h) @ keys.transpose(1, 2)) * scale
        allowed = torch.cat([mask & own, torch.ones(b, 1, dtype=torch.bool, device=feat.device)], 1)
        intent = intent.masked_fill(~allowed[:, None, :], float("-inf"))
        m = mask.float()[..., None]
        pooled = torch.cat([(h * m * own.float()[..., None]).sum(1) / (m * own.float()[..., None]).sum(1).clamp(min=1),
                            (h * m * enemy.float()[..., None]).sum(1) / (m * enemy.float()[..., None]).sum(1).clamp(min=1)], -1)
        return {"act": self.act(h), "atk": atk, "lost": self.out_lost(h).squeeze(-1), "dead": self.out_dead(h).squeeze(-1),
                "intent": intent, "value": self.value(pooled)}


def candidates(out: dict, i: int, u: int, k: int = 10) -> list:
    """Top-k joint actions (type, target) for own unit u of sample i, with probabilities."""
    pt = F.softmax(out["act"][i, u].float(), -1)
    pa = F.softmax(out["atk"][i, u].float(), -1)
    cands = [(pt[a].item(), ACT[a], None) for a in range(len(ACT)) if ACT[a] != "ATTACK"]
    p_atk = pt[ACT.index("ATTACK")].item()
    cands += [(p_atk * pa[j].item(), "ATTACK", j) for j in range(pa.shape[0]) if pa[j] > 0]
    return sorted(cands, key=lambda c: -c[0])[:k]
