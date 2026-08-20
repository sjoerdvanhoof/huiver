"""Core ML export of voice cloning: a recording in, a voice out.

Cloning is the one thing the apps have never been able to do for themselves.
`export_voices.py` does it on the Mac in Python because turning a clip into a
voice needs three networks the apps do not carry — a speech tokenizer, an LSTM
speaker encoder and an x-vector net — plus four different mel front-ends. This
module is those pieces, made convertible.

    speaker_emb   (256,)      who is speaking            voice encoder
    cond_prompt   (150,)      6s of them, as tokens      speech tokenizer
    prompt_token  (250,)      10s of them, as tokens     speech tokenizer
    prompt_feat   (500, 80)   the same 10s as mel        s3gen mel front-end
    embedding     (192,)      an x-vector                CAMPPlus

Every front-end here is a re-implementation rather than the original, and always
for the same reason: they all reach for `torch.stft`, which produces a complex
tensor, and Core ML has no complex type. The way round it is the one
`s3_export.py` already uses for the vocoder — a real-valued DFT written as a
matmul against a fixed basis. That is the only liberty taken; the filterbanks,
the windows and the log conventions are the checkpoint's own, and
`verify_clone.py` holds each stage to the original it replaces.

One deliberate deviation: upstream resamples the same clip twice with two
different resamplers — torchaudio for the s3gen path, librosa's `kaiser_fast`
for the voice encoder's. Here the clip is resampled once, with torchaudio's
kernel, and both paths read the result. Matching two resamplers bit for bit
would mean shipping two, and the difference is far smaller than the difference
between two takes of the same sentence.
"""

from __future__ import annotations

import math

import torch
import torch.nn.functional as F
from torch import nn

S3_SR = 16000
S3GEN_SR = 24000

# What a clip is trimmed or padded to before anything looks at it. Ten seconds
# is what the decoder's conditioning is shaped for — 250 tokens at 25 Hz — and
# `export_voices.py` has always cut to it.
CLIP_SECONDS = 10
CLIP_24K = CLIP_SECONDS * S3GEN_SR
CLIP_16K = CLIP_SECONDS * S3_SR

# The conditioning prompt is six seconds of the same clip: 150 tokens, which is
# `T3Config.speech_cond_prompt_len`.
COND_SECONDS = 6
COND_16K = COND_SECONDS * S3_SR


def dft_basis(n_fft: int) -> tuple[torch.Tensor, torch.Tensor]:
    """Real and imaginary halves of a DFT, as matrices.

    `(bins, n_fft)` each, so a framed signal times these is the spectrum —
    which is what `torch.stft` would produce, in ops Core ML understands.
    """
    bins = n_fft // 2 + 1
    angle = -2 * math.pi * torch.outer(torch.arange(bins), torch.arange(n_fft)) / n_fft
    return torch.cos(angle), torch.sin(angle)


def frame(x: torch.Tensor, length: int, hop: int) -> torch.Tensor:
    """Overlapping frames, `(B, frames, length)`.

    A convolution against the identity rather than `unfold` or `as_strided`.
    Both of those are the natural way to write it and coremltools implements
    neither; a strided conv1d whose kernel is an identity matrix is the same
    operation and converts.
    """
    kernel = torch.eye(length, dtype=x.dtype, device=x.device).unsqueeze(1)
    return F.conv1d(x.unsqueeze(1), kernel, stride=hop).transpose(1, 2)


class Spectrogram(nn.Module):
    """Magnitudes, `(B, bins, frames)`, without a complex number in sight."""

    def __init__(self, n_fft: int, hop: int, window: torch.Tensor, center: bool):
        super().__init__()
        self.n_fft = n_fft
        self.hop = hop
        self.center = center
        real, imaginary = dft_basis(n_fft)
        # The window folded into the kernels, so one strided convolution does
        # the framing, the windowing and the transform together.
        self.register_buffer("real", (real * window).unsqueeze(1), persistent=False)
        self.register_buffer("imaginary", (imaginary * window).unsqueeze(1), persistent=False)

    def forward(self, wav: torch.Tensor) -> torch.Tensor:
        if self.center:
            pad = self.n_fft // 2
            wav = F.pad(wav.unsqueeze(1), (pad, pad), mode="reflect")
        else:
            wav = wav.unsqueeze(1)
        real = F.conv1d(wav, self.real, stride=self.hop)
        imaginary = F.conv1d(wav, self.imaginary, stride=self.hop)
        return (real.pow(2) + imaginary.pow(2) + 1e-12).sqrt()


class TokenizerMel(nn.Module):
    """The speech tokenizer's front-end: 128 log-mels at 16 kHz.

    Whisper's convention, which the tokenizer inherited: magnitudes squared,
    clamped at 1e-10, log10, then floored to within 8 dB of the maximum and
    scaled into roughly [-1, 1].
    """

    def __init__(self, tokenizer):
        super().__init__()
        self.spectrogram = Spectrogram(
            n_fft=tokenizer.n_fft, hop=160, window=tokenizer.window.clone(), center=True
        )
        self.register_buffer("filters", tokenizer._mel_filters.clone(), persistent=False)

    def forward(self, wav16: torch.Tensor) -> torch.Tensor:
        # Whisper drops the final frame, which `torch.stft`'s centring produces
        # and nothing consumes.
        magnitudes = self.spectrogram(wav16)[..., :-1].pow(2)
        mel = self.filters @ magnitudes
        log = mel.clamp(min=1e-10).log10()
        log = torch.maximum(log, log.amax(dim=(-2, -1), keepdim=True) - 8.0)
        return (log + 4.0) / 4.0


class S3GenMel(nn.Module):
    """The mel decoder's own front-end: 80 log-mels at 24 kHz.

    `center=False` with the padding applied by hand, exactly as
    `s3gen/utils/mel.py` does it — the reflect pad is `(n_fft - hop) / 2` a
    side, not `n_fft / 2`, and getting that wrong shifts every frame.
    """

    def __init__(self, n_fft=1920, hop=480, mels=80):
        super().__init__()
        from librosa.filters import mel as librosa_mel

        self.pad = (n_fft - hop) // 2
        self.spectrogram = Spectrogram(
            n_fft=n_fft, hop=hop, window=torch.hann_window(n_fft), center=False
        )
        filters = torch.from_numpy(
            librosa_mel(sr=S3GEN_SR, n_fft=n_fft, n_mels=mels, fmin=0, fmax=8000)
        ).float()
        self.register_buffer("filters", filters, persistent=False)

    def forward(self, wav24: torch.Tensor) -> torch.Tensor:
        padded = F.pad(wav24.unsqueeze(1), (self.pad, self.pad), mode="reflect").squeeze(1)
        magnitudes = self.spectrogram(padded)
        mel = self.filters @ magnitudes
        return mel.clamp(min=1e-5).log()


def real_rotary(tokenizer) -> None:
    """Swap the tokenizer encoder's complex rotary table for a real one.

    The rotation is already real arithmetic — `apply_rotary_emb` pulls cos and
    sin out of the table with `view_as_real` and does the usual rotate-half.
    Only the *table* is complex, and Core ML has no complex type, so conversion
    dies on a dtype cast rather than on anything mathematical.

    Two things are replaced, both at export time and on the instance rather than
    in the package: the function that applies the rotation, and the encoder's
    `forward` — which recomputes cos and sin from the complex table into
    variables it then never uses. That dead code is the only other place the
    complex type appears, and it would fail the conversion on its own.
    """
    import types

    import s3tokenizer.model_v2 as v2
    from s3tokenizer.model_v2 import make_non_pad_mask, mask_to_bias

    encoder = tokenizer.encoder
    if getattr(encoder, "_huiver_real_rotary", False):
        return

    def apply_real(xq, xk, freqs_cis):
        # (T, D, 2) reals rather than (T, D) complex.
        cos = freqs_cis[..., 0].unsqueeze(0).unsqueeze(2).to(xq.dtype)
        sin = freqs_cis[..., 1].unsqueeze(0).unsqueeze(2).to(xq.dtype)

        def rotate(x):
            half = x.shape[-1] // 2
            return torch.cat((-x[..., half:], x[..., :half]), dim=-1)

        return xq * cos + rotate(xq) * sin, xk * cos + rotate(xk) * sin

    v2.apply_rotary_emb = apply_real

    def forward(self, x: torch.Tensor, x_len: torch.Tensor):
        """`AudioEncoderV2.forward`, with the dead complex block removed."""
        T = x.size(-1)
        mask = make_non_pad_mask(x_len, T).unsqueeze(1)
        x = F.gelu(self.conv1(x * mask))
        x_len = (x_len + 2 - 1 * (3 - 1) - 1) // self.stride + 1
        x_slen = (T + 2 - 1 * (3 - 1) - 1) // self.stride + 1
        mask = make_non_pad_mask(x_len, x_slen).unsqueeze(1)
        x = F.gelu(self.conv2(x * mask))
        x_len = (x_len + 2 - 1 * (3 - 1) - 1) // 2 + 1
        x_slen = (x_slen + 2 - 1 * (3 - 1) - 1) // self.stride + 1
        mask = make_non_pad_mask(x_len, x_slen).unsqueeze(1)
        x = x.permute(0, 2, 1)
        mask_pad = mask.transpose(1, 2)
        mask = mask_to_bias(mask, x.dtype)

        for block in self.blocks:
            x = block(x, mask.unsqueeze(1), mask_pad, self.freqs_cis[: x.size(1)])
        return x, x_len

    if torch.is_complex(encoder.freqs_cis):
        encoder.freqs_cis = torch.view_as_real(encoder.freqs_cis)
    encoder.forward = types.MethodType(forward, encoder)
    encoder._huiver_real_rotary = True


class SpeechTokens(nn.Module):
    """The speech tokenizer, front-end and all: 16 kHz in, tokens out.

    The tokenizer's own `forward` takes a list of wavs, pads each to a multiple
    of 40 ms and tracks lengths — all of which is Python around a fixed-shape
    network. Given a clip already cut to exactly ten seconds, none of it is
    needed: the mel is 1000 frames, the encoder halves that to 500, and the
    quantiser emits 250 tokens.
    """

    def __init__(self, tokenizer, samples: int):
        super().__init__()
        self.mel = TokenizerMel(tokenizer)
        real_rotary(tokenizer)
        self.tokenizer = tokenizer
        self.frames = samples // 160  # the mel's hop
        self.tokens = self.frames // 4

    def forward(self, wav16: torch.Tensor) -> torch.Tensor:
        mel = self.mel(wav16)[..., : self.frames]
        lengths = torch.tensor([mel.shape[-1]], dtype=torch.long)
        tokens, _ = self.tokenizer.quantize(mel, lengths)
        return tokens[:, : self.tokens].to(torch.int32)


class SpeakerEmbedding(nn.Module):
    """The voice encoder: 16 kHz in, a 256-wide identity out.

    Its config is mercifully plain — no pre-emphasis, no decibels, no
    normalisation, just squared magnitudes through a 40-band filterbank — so the
    only re-implementation is the DFT again.

    What needs care is the windowing. The encoder does not read a clip; it reads
    overlapping 160-frame partials, embeds each, averages them and normalises
    the result. How many partials there are depends on the clip length, which is
    why the length is fixed here: at ten seconds it is always eleven, and
    eleven is a shape Core ML can compile.
    """

    PARTIAL_FRAMES = 160
    # `get_frame_step(rate=1.3)`: round((16000 / 1.3) / 160).
    FRAME_STEP = 77
    MIN_COVERAGE = 0.8

    def __init__(self, encoder, samples: int):
        super().__init__()
        from librosa.filters import mel as librosa_mel

        self.encoder = encoder
        self.spectrogram = Spectrogram(
            n_fft=400, hop=160, window=torch.hann_window(400), center=True
        )
        filters = torch.from_numpy(
            librosa_mel(sr=S3_SR, n_fft=400, n_mels=40, fmin=0, fmax=8000)
        ).float()
        self.register_buffer("filters", filters, persistent=False)

        frames = 1 + samples // 160
        self.partials, self.padded_frames = self.window_count(frames)

    @classmethod
    def window_count(cls, frames: int) -> tuple[int, int]:
        """`get_num_wins`, spelled out: partials, and the length they need."""
        step, window = cls.FRAME_STEP, cls.PARTIAL_FRAMES
        count, remainder = divmod(max(frames - window + step, 0), step)
        if count == 0 or (remainder + (window - step)) / window >= cls.MIN_COVERAGE:
            count += 1
        return count, window + step * (count - 1)

    def mel(self, wav16: torch.Tensor) -> torch.Tensor:
        """`(B, frames, 40)`, unscaled — the shape the encoder wants."""
        magnitudes = self.spectrogram(wav16).pow(2)  # mel_power = 2
        return (self.filters @ magnitudes).transpose(1, 2)

    def forward(self, wav16: torch.Tensor) -> torch.Tensor:
        mel = self.mel(wav16)
        if mel.shape[1] < self.padded_frames:
            mel = F.pad(mel, (0, 0, 0, self.padded_frames - mel.shape[1]))

        # Eleven overlapping windows, stacked into a batch.
        partials = torch.cat(
            [
                mel[:, index * self.FRAME_STEP: index * self.FRAME_STEP + self.PARTIAL_FRAMES]
                for index in range(self.partials)
            ],
            dim=0,
        )
        embeds = self.encoder(partials)
        # The utterance embedding: the partials' mean, normalised again.
        mean = embeds.mean(dim=0, keepdim=True)
        return mean / mean.norm(dim=1, keepdim=True)


class KaldiFbank(nn.Module):
    """`torchaudio.compliance.kaldi.fbank(num_mel_bins=80)`, made convertible.

    The x-vector network is the one that reads kaldi features rather than a
    log-mel, and kaldi's conventions are its own: the DC offset comes out of
    every frame, a 0.97 pre-emphasis goes on, the window is a Hann raised to
    0.85 ("povey"), and the 400-sample frame is zero-padded to 512 before the
    transform. Get any of them wrong and the features are plausible but not the
    ones the weights were trained on.

    The filterbank itself is torchaudio's own table, computed once here and
    carried as a constant — it is a matrix, not code.
    """

    FRAME_LENGTH = 400  # 25 ms at 16 kHz
    FRAME_SHIFT = 160  # 10 ms
    PADDED = 512  # kaldi rounds the window up to a power of two
    PREEMPHASIS = 0.97

    def __init__(self, mel_bins: int = 80):
        super().__init__()
        from torchaudio.compliance.kaldi import get_mel_banks

        real, imaginary = dft_basis(self.PADDED)
        self.register_buffer("real", real, persistent=False)
        self.register_buffer("imaginary", imaginary, persistent=False)

        # Povey: a Hann window to the power 0.85. kaldi builds it over the frame
        # length, not the padded length.
        hann = torch.hann_window(self.FRAME_LENGTH, periodic=False)
        self.register_buffer("window", hann.pow(0.85), persistent=False)

        banks, _ = get_mel_banks(
            num_bins=mel_bins,
            window_length_padded=self.PADDED,
            sample_freq=float(S3_SR),
            low_freq=20.0,
            high_freq=0.0,
            vtln_low=100.0,
            vtln_high=-500.0,
            vtln_warp_factor=1.0,
        )
        # kaldi's bank has no bin for Nyquist; pad it back to the spectrum width.
        self.register_buffer(
            "filters", F.pad(banks, (0, self.PADDED // 2 + 1 - banks.shape[1])), persistent=False
        )

    def forward(self, wav16: torch.Tensor) -> torch.Tensor:
        # snip_edges: whole frames only, no padding at either end.
        frames = frame(wav16, self.FRAME_LENGTH, self.FRAME_SHIFT)
        frames = frames - frames.mean(dim=-1, keepdim=True)

        # Pre-emphasis, with kaldi's edge rule: the first sample is its own
        # predecessor, so the filter starts from rest rather than from zero.
        shifted = torch.cat([frames[..., :1], frames[..., :-1]], dim=-1)
        frames = (frames - self.PREEMPHASIS * shifted) * self.window

        padded = F.pad(frames, (0, self.PADDED - self.FRAME_LENGTH))
        real = padded @ self.real.T
        imaginary = padded @ self.imaginary.T
        power = real.pow(2) + imaginary.pow(2)
        return (power @ self.filters.T).clamp(min=torch.finfo(torch.float32).eps).log()


class XVector(nn.Module):
    """The x-vector: kaldi features, mean-subtracted, through CAMPPlus."""

    def __init__(self, speaker_encoder):
        super().__init__()
        self.fbank = KaldiFbank()
        self.encoder = speaker_encoder

    def forward(self, wav16: torch.Tensor) -> torch.Tensor:
        features = self.fbank(wav16)
        # Per-utterance mean normalisation, as `extract_feature` does it.
        features = features - features.mean(dim=1, keepdim=True)
        return self.encoder(features)


class VoiceCloner(nn.Module):
    """A recording in, the five tensors of a voice out.

    One package rather than four, because the Swift side then has nothing to
    orchestrate: hand it ten seconds at 24 kHz and it gets back exactly what a
    `.voice` file holds. The resampling happens here too — a fixed kernel is a
    convolution, and doing it in the graph means one fewer place for the two
    sides to disagree about what 16 kHz means.
    """

    def __init__(self, model):
        super().__init__()
        from torchaudio.transforms import Resample

        self.resample = Resample(S3GEN_SR, S3_SR)
        self.mel = S3GenMel()
        self.tokens = SpeechTokens(model.s3gen.tokenizer, CLIP_16K)
        self.cond_tokens = SpeechTokens(model.s3gen.tokenizer, COND_16K)
        self.speaker = SpeakerEmbedding(model.ve, CLIP_16K)
        self.xvector = XVector(model.s3gen.speaker_encoder)

    def forward(self, wav24: torch.Tensor):
        wav16 = self.resample(wav24)[:, :CLIP_16K]
        return (
            self.speaker(wav16),
            self.cond_tokens(wav16[:, :COND_16K]),
            self.tokens(wav16),
            self.mel(wav24).transpose(1, 2),
            self.xvector(wav16),
        )


OUTPUTS = ("speaker_emb", "cond_prompt_tokens", "prompt_token", "prompt_feat", "embedding")


def build(model) -> VoiceCloner:
    cloner = VoiceCloner(model).eval()
    for parameter in cloner.parameters():
        parameter.requires_grad_(False)
    return cloner


def export(model, out, quant: str = "none", precision: str = "fp16"):
    """Convert the cloner and write it beside the other packages."""
    import time

    import coremltools as ct
    import numpy as np

    import mil_ops  # noqa: F401 — the ops coremltools is missing
    from export_mtl import quantize, save

    cloner = build(model)
    example = (torch.zeros(1, CLIP_24K),)
    print("clone: tracing")
    with torch.inference_mode():
        traced = torch.jit.trace(cloner, example, strict=False)

    print("clone: converting")
    started = time.time()
    converted = ct.convert(
        traced,
        inputs=[ct.TensorType(name="wav24", shape=(1, CLIP_24K), dtype=np.float32)],
        outputs=[
            ct.TensorType(name="speaker_emb", dtype=np.float32),
            ct.TensorType(name="cond_prompt_tokens", dtype=np.int32),
            ct.TensorType(name="prompt_token", dtype=np.int32),
            ct.TensorType(name="prompt_feat", dtype=np.float32),
            ct.TensorType(name="embedding", dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.macOS15,
        # Precision is a parameter, and the default is not the usual one. Two of
        # these five outputs are *tokens* — an argmin over a codebook — and
        # quantisation moves the encoder's output just enough to flip which
        # entry wins. Measured: int8 got 106 of 250 tokens right, which is not a
        # voice. See verify_clone.py.
        compute_precision={
            "fp16": ct.precision.FLOAT16,
            "fp32": ct.precision.FLOAT32,
        }[precision],
        # Off the Neural Engine like the other front-end-heavy packages: this one
        # is four DFTs and an LSTM, and it runs once per voice rather than once
        # per token, so there is nothing to gain and a compiler to avoid.
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
    )
    print(f"  converted in {time.time() - started:.0f}s")
    save(
        quantize(converted, quant),
        out,
        "MTLVoiceCloner",
        dict(
            sampleRate=S3GEN_SR,
            clipSamples=CLIP_24K,
            condPromptLen=150,
            promptTokenLen=250,
            promptFeatLen=500,
            melDim=80,
            speakerEmbedSize=256,
            xvectorDim=192,
            computeUnits="cpu_gpu",
            precision=precision,
            quantize=quant,
        ),
    )
    return converted
