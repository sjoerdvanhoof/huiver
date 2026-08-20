"""The multilingual backbone's forward pass, written out for export.

Chatterbox Multilingual's T3 is a 30-layer LLaMA — RMSNorm, SwiGLU, rotary
positions with llama3 frequency scaling — reading a sequence assembled by hand
out of conditioning, text and speech tokens, exactly as Nano's GPT-2 does.

Re-implemented here rather than traced out of `transformers`, for the same three
reasons `t3_export.py` gives for Nano: prefill and decode can share one
attention implementation, the graph stays free of the Python-level `int(x.size(1))`
calls a traced HF model bakes in as constants, and what Swift will have to write
is legible in one file.

Two shapes rather than one, and here the split is not only about flexible
dimensions:

  prefill   the whole prompt, both CFG rows, cache out
  decode    one token per row, fixed shapes, cache in and out

**Every step is a batch of two.** Guidance is not optional in this model, so the
unconditional row is computed for every token that is ever generated. That is
the single biggest difference from Nano at runtime — twice the arithmetic and
twice the cache — and it is why the cache is worth counting before anything is
converted:

    2 rows × 30 layers × 16 heads × 64 dims × 2 (K and V) × 2 bytes
      = 245 kB per position, or about 340 MB at a 1400-token context.

Nano's equivalent is 62 MB. A phone would not hold this; a Mac will not notice.
"""

from __future__ import annotations

import torch
import torch.nn.functional as F
from torch import nn

# What an unattendable position contributes to the attention logits. Not -inf:
# the graph runs in float16 on device, where -inf survives the addition but
# turns an all-masked row into NaN. Same choice, and same reason, as Nano's.
MASKED = -1e4


def rms_norm(x: torch.Tensor, weight: torch.Tensor, eps: float) -> torch.Tensor:
    """LLaMA's normalisation, in float32 whatever the weights are.

    The variance is the part that overflows: a 1024-wide sum of squares in
    float16 is not safe, and Core ML will happily run the whole graph in half
    precision if this does not say otherwise.
    """
    dtype = x.dtype
    x = x.float()
    x = x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + eps)
    return (x * weight.float()).to(dtype)


def rotate_half(x: torch.Tensor) -> torch.Tensor:
    half = x.shape[-1] // 2
    return torch.cat([-x[..., half:], x[..., :half]], dim=-1)


def apply_rope(x: torch.Tensor, cos: torch.Tensor, sin: torch.Tensor) -> torch.Tensor:
    """`cos`/`sin` are (T, head_dim); `x` is (B, heads, T, head_dim)."""
    return x * cos + rotate_half(x) * sin


class Block(nn.Module):
    """One LLaMA decoder layer, weights lifted straight off the HF module."""

    def __init__(self, hf_layer: nn.Module, eps: float, scaling: float):
        super().__init__()
        self.eps = eps
        self.scaling = scaling
        attn, mlp = hf_layer.self_attn, hf_layer.mlp
        self.q = nn.Parameter(attn.q_proj.weight.data.clone())
        self.k = nn.Parameter(attn.k_proj.weight.data.clone())
        self.v = nn.Parameter(attn.v_proj.weight.data.clone())
        self.o = nn.Parameter(attn.o_proj.weight.data.clone())
        self.gate = nn.Parameter(mlp.gate_proj.weight.data.clone())
        self.up = nn.Parameter(mlp.up_proj.weight.data.clone())
        self.down = nn.Parameter(mlp.down_proj.weight.data.clone())
        self.norm_in = nn.Parameter(hf_layer.input_layernorm.weight.data.clone())
        self.norm_post = nn.Parameter(hf_layer.post_attention_layernorm.weight.data.clone())

    def project(self, x: torch.Tensor, heads: int, head_dim: int):
        batch, length, _ = x.shape

        def split(weight):
            return (
                F.linear(x, weight)
                .view(batch, length, heads, head_dim)
                .transpose(1, 2)
            )

        return split(self.q), split(self.k), split(self.v)

    def mlp_forward(self, x: torch.Tensor) -> torch.Tensor:
        return F.linear(F.silu(F.linear(x, self.gate)) * F.linear(x, self.up), self.down)

    def forward(
        self,
        x: torch.Tensor,
        cos: torch.Tensor,
        sin: torch.Tensor,
        heads: int,
        head_dim: int,
        past_k: torch.Tensor | None = None,
        past_v: torch.Tensor | None = None,
        mask: torch.Tensor | None = None,
    ):
        """Prefill when `past_k` is None, one cached step when it is not."""
        residual = x
        h = rms_norm(x, self.norm_in, self.eps)
        q, k, v = self.project(h, heads, head_dim)
        q, k = apply_rope(q, cos, sin), apply_rope(k, cos, sin)

        if past_k is not None:
            k = torch.cat([past_k, k], dim=2)
            v = torch.cat([past_v, v], dim=2)

        scores = torch.matmul(q, k.transpose(-1, -2)) * self.scaling
        if mask is not None:
            scores = scores + mask
        attended = torch.matmul(torch.softmax(scores, dim=-1, dtype=torch.float32).to(q.dtype), v)

        batch, _, length, _ = attended.shape
        attended = attended.transpose(1, 2).reshape(batch, length, heads * head_dim)
        x = residual + F.linear(attended, self.o)
        return x + self.mlp_forward(rms_norm(x, self.norm_post, self.eps)), k, v


class Backbone(nn.Module):
    """The thirty layers, plus the final norm and the speech head.

    Rotary tables are precomputed rather than derived, and deliberately: the
    llama3 frequency correction is four constants and a piecewise formula, and
    re-deriving it in Swift is one more thing to get subtly wrong. Baking the
    table means the only thing either side has to agree on is the position
    index.
    """

    def __init__(self, t3, max_context: int):
        super().__init__()
        cfg = t3.cfg
        self.heads = cfg.num_attention_heads
        self.head_dim = cfg.head_dim
        self.eps = t3.tfmr.norm.variance_epsilon
        self.layers = nn.ModuleList(
            Block(layer, self.eps, t3.tfmr.layers[0].self_attn.scaling)
            for layer in t3.tfmr.layers
        )
        self.norm = nn.Parameter(t3.tfmr.norm.weight.data.clone())
        self.head = nn.Parameter(t3.speech_head.weight.data.clone())

        positions = torch.arange(max_context)[None]
        cos, sin = t3.tfmr.rotary_emb(torch.zeros(1, max_context, cfg.hidden_size), positions)
        self.register_buffer("cos", cos[0], persistent=False)
        self.register_buffer("sin", sin[0], persistent=False)

    def logits(self, hidden: torch.Tensor) -> torch.Tensor:
        return F.linear(rms_norm(hidden, self.norm, self.eps), self.head)

    def prefill(self, embeds: torch.Tensor):
        """The whole prompt, both rows. Returns logits and the filled cache."""
        length = embeds.shape[1]
        cos, sin = self.cos[:length], self.sin[:length]
        mask = torch.full((length, length), MASKED).triu(1)

        keys, values = [], []
        x = embeds
        for layer in self.layers:
            x, k, v = layer(x, cos, sin, self.heads, self.head_dim, mask=mask)
            keys.append(k)
            values.append(v)
        return self.logits(x), keys, values

    def decode(self, embed: torch.Tensor, position: int, keys, values):
        """One token per row against the cache."""
        cos, sin = self.cos[position:position + 1], self.sin[position:position + 1]
        x = embed
        out_keys, out_values = [], []
        for index, layer in enumerate(self.layers):
            x, k, v = layer(
                x, cos, sin, self.heads, self.head_dim,
                past_k=keys[index], past_v=values[index],
            )
            out_keys.append(k)
            out_values.append(v)
        return self.logits(x), out_keys, out_values
