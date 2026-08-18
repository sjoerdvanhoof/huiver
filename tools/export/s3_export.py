"""Core ML export of S3Gen, the half of Chatterbox Nano that makes sound.

Speech tokens go in at 25 Hz, a two-step meanflow decoder turns them into 80-bin
mel frames at 50 Hz, and a HiFTNet vocoder turns those into 24 kHz audio. Two
models come out, `S3Flow` and `S3Vocoder`, because they have very different
shapes and splitting them lets the app show progress between the two.

Unlike T3, the sequence length here is fixed. Every alternative reuses one
traced graph across several lengths, and this graph is full of constants that
only hold for the length it was traced at -- the conformer encoder's padding
masks, the positional encoding table slice, the mel/token arithmetic. A short
chunk is padded out with S3GEN_SIL, the model's own silence token, and the
surplus audio is cut off by sample count afterwards.

Three things in the original are not exportable as written, and are replaced
here with equivalents that are checked against torch in `verify`:

  * `torch.randn` inside the flow decoder -> noise arrives as an input, so the
    Swift side owns the seed and a chunk can be reproduced
  * `torch.stft` / `torch.istft` in the vocoder -> Core ML has neither, but at
    n_fft=16 both are small enough to write as a convolution against a DFT basis
  * random phase and excitation noise in the source module -> baked constants
"""

from __future__ import annotations

import math

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

from common import (
    MEL_DIM,
    PROMPT_FEAT_LEN,
    PROMPT_TOKEN_LEN,
    TOKEN_MEL_RATIO,
    check,
)

N_FFT = 16
HOP = 4
N_BINS = N_FFT // 2 + 1  # 9
N_HARMONICS = 9  # nb_harmonics 8, plus the fundamental

# Length of the excitation-noise block that gets tiled across the waveform.
# The source module wants white noise for every one of ~700k samples; baking
# that whole tensor in costs ~13 MB per model, and repeating a 2.7-second block
# instead costs 1.2 MB. What repeats is a hiss at a thirtieth of a hertz sitting
# 30 dB under the speech, which is not a thing anyone can hear.
NOISE_BLOCK = 65536


# ------------------------------------------------------------------ the flow


class Flow(nn.Module):
    """Speech tokens -> mel frames, conditioned on a reference clip.

    Batch size is one and nothing is padded, so every attention mask in here is
    all-ones and the original's `make_pad_mask` machinery is dropped rather than
    traced. That is the only liberty taken: the encoder, the projection and the
    flow-matching estimator are the checkpoint's own modules, called directly.
    """

    def __init__(self, s3gen: nn.Module, gen_tokens: int):
        super().__init__()
        flow = s3gen.flow
        self.input_embedding = flow.input_embedding
        self.spk_embed_affine_layer = flow.spk_embed_affine_layer
        self.encoder = flow.encoder
        self.encoder_proj = flow.encoder_proj
        self.estimator = flow.decoder.estimator
        self.gen_tokens = gen_tokens
        self.n_tokens = PROMPT_TOKEN_LEN + gen_tokens
        self.n_mel = self.n_tokens * TOKEN_MEL_RATIO
        self.token_len = torch.tensor([self.n_tokens], dtype=torch.long)
        # Two meanflow steps. The cosine schedule the base model uses is
        # skipped for meanflow, exactly as in flow_matching.py.
        self.t_span = torch.linspace(0, 1, 3)

    def forward(
        self,
        prompt_tokens: torch.Tensor,  # (1, 250) int32
        gen_tokens: torch.Tensor,  # (1, G) int32
        prompt_feat: torch.Tensor,  # (1, 500, 80)
        embedding: torch.Tensor,  # (1, 192)
        noise: torch.Tensor,  # (1, 80, 2*(250+G)) standard normal
    ):
        spks = self.spk_embed_affine_layer(F.normalize(embedding, dim=1))

        tokens = torch.cat([prompt_tokens, gen_tokens], dim=1).long()
        h, _ = self.encoder(self.input_embedding(tokens), self.token_len)
        mu = self.encoder_proj(h).transpose(1, 2).contiguous()  # (1, 80, 2N)

        # The reference mel occupies the front of the conditioning signal and
        # the part being generated is left at zero.
        tail = torch.zeros(
            1, self.n_mel - PROMPT_FEAT_LEN, MEL_DIM, dtype=prompt_feat.dtype
        )
        cond = torch.cat([prompt_feat, tail], dim=1).transpose(1, 2)
        mask = torch.ones(1, 1, self.n_mel, dtype=mu.dtype)

        x = noise
        for i in range(2):
            t = self.t_span[i].view(1)
            r = self.t_span[i + 1].view(1)
            dxdt = self.estimator.forward(
                x, mask=mask, mu=mu, t=t, spks=spks, cond=cond, r=r
            )
            x = x + (r - t) * dxdt

        return x[:, :, PROMPT_FEAT_LEN:]


# --------------------------------------------------------------- the vocoder


def _stft_basis() -> torch.Tensor:
    """Rows of cos/sin, windowed: a 16-point real DFT as a conv1d kernel."""
    window = torch.hann_window(N_FFT, periodic=True)
    n = torch.arange(N_FFT, dtype=torch.float64)
    basis = []
    for k in range(N_BINS):
        basis.append(torch.cos(2 * math.pi * k * n / N_FFT))
    for k in range(N_BINS):
        # torch.stft's imaginary part carries the minus sign of exp(-i...).
        basis.append(-torch.sin(2 * math.pi * k * n / N_FFT))
    return (torch.stack(basis).float() * window).unsqueeze(1)  # (18, 1, 16)


def _istft_basis() -> torch.Tensor:
    """The inverse: one-sided spectrum back to a windowed frame.

    Bins 1..N/2-1 stand in for a conjugate pair and so count twice; DC and
    Nyquist do not. Overlap-add and the window-squared normalisation are done
    by the caller, which is also where torch.istft does them.
    """
    window = torch.hann_window(N_FFT, periodic=True)
    n = torch.arange(N_FFT, dtype=torch.float64)
    rows = []
    for k in range(N_BINS):
        weight = 1.0 if k in (0, N_FFT // 2) else 2.0
        rows.append(weight * torch.cos(2 * math.pi * k * n / N_FFT) / N_FFT)
    for k in range(N_BINS):
        weight = 1.0 if k in (0, N_FFT // 2) else 2.0
        rows.append(-weight * torch.sin(2 * math.pi * k * n / N_FFT) / N_FFT)
    return (torch.stack(rows).float() * window).unsqueeze(1)  # (18, 1, 16)


class Vocoder(nn.Module):
    """Mel frames -> 24 kHz waveform.

    A straight port of HiFTGenerator.inference with the three unexportable
    pieces swapped out. Everything with weights in it is the checkpoint's own
    module.
    """

    def __init__(self, s3gen: nn.Module, mel_frames: int, seed: int = 0):
        super().__init__()
        gen = s3gen.mel2wav
        self.g = gen
        self.mel_frames = mel_frames
        self.samples = mel_frames * 480
        self.frames = self.samples // HOP + 1

        self.register_buffer("stft_w", _stft_basis(), persistent=False)
        self.register_buffer("istft_w", _istft_basis(), persistent=False)

        # torch.istft divides the overlap-added signal by the overlap-added
        # squared window. With hann/16/4 that envelope is constant except at the
        # very ends, but it is computed rather than assumed.
        window = torch.hann_window(N_FFT, periodic=True)
        env = F.fold(
            (window**2).view(1, N_FFT, 1).expand(1, N_FFT, self.frames),
            output_size=(1, self.samples + N_FFT),
            kernel_size=(1, N_FFT),
            stride=(1, HOP),
        ).view(1, -1)
        self.register_buffer("istft_env", env.clamp_min(1e-11), persistent=False)

        rng = torch.Generator().manual_seed(seed)
        phase = torch.rand(1, N_HARMONICS, 1, generator=rng) * (2 * math.pi) - math.pi
        phase[:, 0, :] = 0
        self.register_buffer("phase", phase, persistent=False)
        self.register_buffer(
            "noise_block",
            torch.randn(1, N_HARMONICS, NOISE_BLOCK, generator=rng),
            persistent=False,
        )

    def excitation_noise(self, length: int) -> torch.Tensor:
        reps = -(-length // NOISE_BLOCK)
        return self.noise_block.repeat(1, 1, reps)[:, :, :length]

    def source(self, f0: torch.Tensor) -> torch.Tensor:
        """The neural source filter's excitation signal, made deterministic."""
        gen = self.g.m_source.l_sin_gen
        up = self.g.f0_upsamp(f0[:, None]).transpose(1, 2)  # (1, L, 1)
        f0_up = up.transpose(1, 2)  # (1, 1, L)
        length = f0_up.shape[-1]

        harmonics = torch.arange(1, N_HARMONICS + 1, dtype=f0_up.dtype).view(
            1, N_HARMONICS, 1
        )
        f_mat = f0_up * harmonics / gen.sampling_rate
        theta = 2 * math.pi * (torch.cumsum(f_mat, dim=-1) % 1)
        sine = gen.sine_amp * torch.sin(theta + self.phase)

        uv = (f0_up > gen.voiced_threshold).to(f0_up.dtype)
        noise_amp = uv * gen.noise_std + (1 - uv) * gen.sine_amp / 3
        sine = sine * uv + noise_amp * self.excitation_noise(length)

        merged = self.g.m_source.l_tanh(self.g.m_source.l_linear(sine.transpose(1, 2)))
        return merged.transpose(1, 2)  # (1, 1, L)

    def stft(self, x: torch.Tensor):
        padded = F.pad(x.unsqueeze(1), (N_FFT // 2, N_FFT // 2), mode="reflect")
        spec = F.conv1d(padded, self.stft_w, stride=HOP)
        return spec[:, :N_BINS], spec[:, N_BINS:]

    def istft(self, magnitude: torch.Tensor, phase: torch.Tensor) -> torch.Tensor:
        magnitude = torch.clip(magnitude, max=1e2)
        spec = torch.cat([magnitude * torch.cos(phase), magnitude * torch.sin(phase)], 1)
        frames = F.conv_transpose1d(spec, self.istft_w, stride=HOP)
        return (frames / self.istft_env)[:, 0, N_FFT // 2 : N_FFT // 2 + self.samples]

    def forward(self, mel: torch.Tensor) -> torch.Tensor:
        g = self.g
        f0 = g.f0_predictor(mel)
        s = self.source(f0)

        s_real, s_imag = self.stft(s.squeeze(1))
        s_stft = torch.cat([s_real, s_imag], dim=1)

        x = g.conv_pre(mel)
        for i in range(g.num_upsamples):
            x = F.leaky_relu(x, g.lrelu_slope)
            x = g.ups[i](x)
            if i == g.num_upsamples - 1:
                x = g.reflection_pad(x)
            x = x + g.source_resblocks[i](g.source_downs[i](s_stft))
            xs = sum(
                g.resblocks[i * g.num_kernels + j](x) for j in range(g.num_kernels)
            )
            x = xs / g.num_kernels

        x = g.conv_post(F.leaky_relu(x))
        magnitude = torch.exp(x[:, :N_BINS, :])
        phase = torch.sin(x[:, N_BINS:, :])
        return torch.clamp(self.istft(magnitude, phase), -g.audio_limit, g.audio_limit)


# --------------------------------------------------------------------- parity


def reference_run(model, gen_tokens: torch.Tensor, noise: torch.Tensor):
    """Mel and waveform from the original code path, with our noise injected.

    This goes through `flow.inference` rather than through the same submodule
    calls the wrapper makes, so it actually tests the liberties taken above --
    dropping the padding masks, flattening the CFM loop. Comparing a
    re-implementation against itself would prove nothing.

    The flow decoder starts from `torch.randn_like(mu)`, which is patched out
    for the length of the call so both sides start from the same noise. The
    vocoder's randomness cannot be pinned the same way (it is drawn deep inside
    the source module), so the waveform is checked loosely and the mel tightly.
    """
    gen = model.conds.gen
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
                n_timesteps=2,
                noised_mels=noise[:, :, PROMPT_FEAT_LEN:],
                meanflow=True,
            )
            wav, _ = model.s3gen.hift_inference(mel)
    finally:
        torch.randn_like = real_randn_like
    return mel, wav


def verify(model, flow: Flow, vocoder: Vocoder, gen_tokens: int) -> bool:
    """Check the two wrappers against torch before anything is converted."""
    torch.manual_seed(0)
    gen = model.conds.gen
    tokens = torch.randint(0, 6000, (1, gen_tokens), dtype=torch.int32)
    n_mel = (PROMPT_TOKEN_LEN + gen_tokens) * TOKEN_MEL_RATIO
    noise = torch.randn(1, MEL_DIM, n_mel)

    with torch.inference_mode():
        got_mel = flow(
            gen["prompt_token"].to(torch.int32),
            tokens,
            gen["prompt_feat"],
            gen["embedding"],
            noise,
        )
    want_mel, want_wav = reference_run(model, tokens, noise)
    ok = check("flow mel", got_mel, want_mel, atol=1e-3, rtol=1e-3)

    # The DFT stand-ins are compared against torch on their own, where an exact
    # answer is available, rather than only through the vocoder where the source
    # module's randomness would mask a real error.
    samples = vocoder.samples
    window = torch.hann_window(N_FFT)
    signal = torch.randn(1, samples)
    with torch.inference_mode():
        spec = torch.stft(signal, N_FFT, HOP, N_FFT, window=window, return_complex=True)
        real, imag = vocoder.stft(signal)
        ok &= check("stft real", real, spec.real, atol=1e-3, rtol=1e-4)
        ok &= check("stft imag", imag, spec.imag, atol=1e-3, rtol=1e-4)

        mag, ang = spec.abs(), torch.angle(spec)
        want = torch.istft(spec, N_FFT, HOP, N_FFT, window=window, length=samples)
        ok &= check("istft", vocoder.istft(mag, ang), want, atol=1e-3, rtol=1e-4)

        got_wav = vocoder(want_mel)
    # Loose on purpose: the reference draws its own excitation noise, so this
    # only says "the same speech", not "the same samples".
    rms = float(got_wav.std())
    print(f"  vocoder waveform: {tuple(got_wav.shape)} rms {rms:.4f} vs {float(want_wav.std()):.4f}")
    ok &= 0.5 < rms / max(float(want_wav.std()), 1e-9) < 2.0
    return bool(ok)


def build(model, gen_tokens: int):
    flow = Flow(model.s3gen, gen_tokens).eval()
    vocoder = Vocoder(model.s3gen, gen_tokens * TOKEN_MEL_RATIO).eval()
    for p in list(flow.parameters()) + list(vocoder.parameters()):
        p.requires_grad_(False)
    return flow, vocoder
