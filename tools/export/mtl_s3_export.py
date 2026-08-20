"""Core ML export of the multilingual S3Gen: speech tokens -> mel -> waveform.

The twin of `s3_export.py`, and mostly the same shape — the encoder, the
projection and the flow-matching estimator are the checkpoint's own modules,
called directly, with batch size one and no padding so the original's
`make_pad_mask` machinery drops out.

What differs is the solver, and it differs twice over:

* **Ten Euler steps on a cosine schedule**, where Nano's distilled meanflow
  takes two on a linear one. Five times the work per mel frame, which is most of
  why this model is the Mac's.
* **Guidance again.** Each step runs the estimator on a batch of two — the
  conditional row with `mu`, the speaker and the reference mel, the other with
  those three zeroed — and combines them as `(1 + r)·cond − r·uncond` with
  `r = 0.7` read off the checkpoint. So a ten-step solve is twenty estimator
  passes, and the T3's guidance is not the only place this model pays for it.

The vocoder is Nano's, reused rather than rewritten: `HiFTGenerator` is the same
module in both checkpoints, and `s3_export.Vocoder` already stands in for the
DFTs Core ML will not trace.
"""

from __future__ import annotations

import torch
import torch.nn.functional as F
from torch import nn

from common import MEL_DIM, TOKEN_MEL_RATIO, check
from s3_export import Vocoder  # noqa: F401  — re-exported; the two share it

# Read off the checkpoint by probe_mtl.py rather than assumed.
CFM_STEPS = 10
CFM_CFG_RATE = 0.7


class MTLFlow(nn.Module):
    """Speech tokens -> mel frames, conditioned on a reference clip."""

    def __init__(self, s3gen: nn.Module, gen_tokens: int, prompt_tokens: int):
        super().__init__()
        flow = s3gen.flow
        self.input_embedding = flow.input_embedding
        self.spk_embed_affine_layer = flow.spk_embed_affine_layer
        self.encoder = flow.encoder
        self.encoder_proj = flow.encoder_proj
        self.estimator = flow.decoder.estimator

        self.prompt_tokens = prompt_tokens
        self.prompt_feat_len = prompt_tokens * TOKEN_MEL_RATIO
        self.n_tokens = prompt_tokens + gen_tokens
        self.n_mel = self.n_tokens * TOKEN_MEL_RATIO
        self.token_len = torch.tensor([self.n_tokens], dtype=torch.long)

        # Cosine, as `CausalConditionalCFM` builds it: the steps bunch up near
        # t=0 where the field changes fastest.
        span = torch.linspace(0, 1, CFM_STEPS + 1)
        self.register_buffer("t_span", 1 - torch.cos(span * 0.5 * torch.pi), persistent=False)

    def forward(
        self,
        prompt_tokens: torch.Tensor,  # (1, P) int32
        gen_tokens: torch.Tensor,  # (1, G) int32
        prompt_feat: torch.Tensor,  # (1, 2P, 80)
        embedding: torch.Tensor,  # (1, 192)
        noise: torch.Tensor,  # (1, 80, 2*(P+G)) standard normal
    ):
        spks = self.spk_embed_affine_layer(F.normalize(embedding, dim=1))

        tokens = torch.cat([prompt_tokens, gen_tokens], dim=1).long()
        h, _ = self.encoder(self.input_embedding(tokens), self.token_len)
        mu = self.encoder_proj(h).transpose(1, 2).contiguous()  # (1, 80, 2N)

        # The reference mel occupies the front of the conditioning signal and
        # the part being generated is left at zero.
        tail = torch.zeros(
            1, self.n_mel - self.prompt_feat_len, MEL_DIM, dtype=prompt_feat.dtype
        )
        cond = torch.cat([prompt_feat, tail], dim=1).transpose(1, 2)
        mask = torch.ones(1, 1, self.n_mel, dtype=mu.dtype)

        # The unconditional half of every step, built once: it does not change
        # with t, and it is three zero tensors.
        zero_mu = torch.zeros_like(mu)
        zero_spks = torch.zeros_like(spks)
        zero_cond = torch.zeros_like(cond)

        x = noise
        for index in range(CFM_STEPS):
            t = self.t_span[index].view(1)
            r = self.t_span[index + 1].view(1)
            dxdt = self.estimator.forward(
                torch.cat([x, x], dim=0),
                mask=torch.cat([mask, mask], dim=0),
                mu=torch.cat([mu, zero_mu], dim=0),
                t=torch.cat([t, t], dim=0),
                spks=torch.cat([spks, zero_spks], dim=0),
                cond=torch.cat([cond, zero_cond], dim=0),
            )
            guided, unguided = dxdt[0:1], dxdt[1:2]
            x = x + (r - t) * ((1.0 + CFM_CFG_RATE) * guided - CFM_CFG_RATE * unguided)

        return x[:, :, self.prompt_feat_len:]


# --------------------------------------------------------------------- parity


def reference_run(model, gen_tokens: torch.Tensor, noise: torch.Tensor, gen=None):
    """Mel and waveform from the original code path, with our noise injected.

    Through `flow.inference` rather than the same submodule calls the wrapper
    makes, so it actually tests the liberties taken above — the dropped padding
    masks, the flattened solver, the guidance written out. Comparing a
    re-implementation against itself would prove nothing.

    `gen` is the conditioning to use, defaulting to the checkpoint's built-in
    voice. It is a parameter because that voice's reference clip is 6.3 seconds
    — 157 speech tokens — while the export is shaped for the ten seconds the
    voice export trims to, so a comparison has to hand both sides the same
    padded tensors rather than one each.
    """
    gen = gen if gen is not None else model.conds.gen
    real_randn_like = torch.randn_like

    def fixed(t, *a, **kw):
        return noise if t.shape == noise.shape else real_randn_like(t, *a, **kw)

    torch.randn_like = fixed
    try:
        with torch.inference_mode():
            mel, _ = model.s3gen.flow.inference(
                token=gen_tokens.long(),
                token_len=torch.tensor([gen_tokens.shape[1]], dtype=torch.long),
                prompt_token=gen["prompt_token"],
                prompt_token_len=gen["prompt_token_len"],
                prompt_feat=gen["prompt_feat"],
                prompt_feat_len=None,
                embedding=gen["embedding"],
                finalize=True,
                n_timesteps=CFM_STEPS,
            )
            wav, _ = model.s3gen.hift_inference(mel)
    finally:
        torch.randn_like = real_randn_like
    return mel, wav


def verify(model, flow: MTLFlow, gen_tokens: int) -> bool:
    """Check the flow wrapper against torch before anything is converted."""
    torch.manual_seed(0)
    gen = model.conds.gen
    tokens = torch.randint(0, 6000, (1, gen_tokens), dtype=torch.int32)
    noise = torch.randn(1, MEL_DIM, flow.n_mel)

    with torch.inference_mode():
        got = flow(
            gen["prompt_token"].to(torch.int32),
            tokens,
            gen["prompt_feat"],
            gen["embedding"],
            noise,
        )
    want, _ = reference_run(model, tokens, noise)
    return bool(check("flow mel", got, want, atol=1e-3, rtol=1e-3))


def build(model, gen_tokens: int):
    prompt_tokens = int(model.conds.gen["prompt_token"].shape[1])
    flow = MTLFlow(model.s3gen, gen_tokens, prompt_tokens).eval()
    for parameter in flow.parameters():
        parameter.requires_grad_(False)
    return flow
