"""Shared constants and model loading for the Core ML export.

Every number here is a property of the Chatterbox Nano checkpoint rather than
of its config file, and was read off a loaded model by probe.py. Re-run that
after bumping the chatterbox pin in
apps/web/py/requirements-chatterbox.txt.
"""

from __future__ import annotations

import os
from pathlib import Path

# The export only ever reads weights; nothing is uploaded. Same policy as the
# server workers.
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import torch  # noqa: E402

# ---------------------------------------------------------------- T3 backbone

N_LAYER = 12
N_HEAD = 12
HEAD_DIM = 64
N_EMBD = 768

TEXT_VOCAB = 50276
SPEECH_VOCAB = 6563
START_SPEECH_TOKEN = 6561
STOP_SPEECH_TOKEN = 6562

# Speaker embedding (1) + cloned prompt speech tokens (375). Fixed by the
# checkpoint: hp.speech_cond_prompt_len is 375 and Nano has no perceiver
# resampler, so the conditioning prefix is always this long.
COND_PROMPT_LEN = 375
COND_PREFIX_LEN = 1 + COND_PROMPT_LEN  # 376

SPEAKER_EMBED_SIZE = 256

# How much room the decode model's KV cache has: the conditioning prefix, the
# longest text we will ever prefill, the BOS speech token, and the generation
# budget. Overrunning it is a hard error in Swift rather than silent corruption.
MAX_TEXT_TOKENS = 320
MAX_GEN_TOKENS = 1000
MAX_CONTEXT = COND_PREFIX_LEN + MAX_TEXT_TOKENS + 1 + MAX_GEN_TOKENS  # 1697

# --------------------------------------------------------------- S3Gen decoder

S3GEN_SR = 24000
S3GEN_SIL = 4299
SPEECH_TOKEN_RATE = 25  # tokens per second
TOKEN_MEL_RATIO = 2  # mel frames per speech token
MEL_HOP = 480  # audio samples per mel frame (24000 / 50)
MEL_DIM = 80

# The reference clip the decoder is conditioned on is trimmed to exactly ten
# seconds during the voice export, which makes both of these constants rather
# than per-voice shapes — the single biggest simplification in the whole export,
# because it leaves the flow decoder with one free dimension instead of three.
PROMPT_TOKEN_LEN = 10 * SPEECH_TOKEN_RATE  # 250
PROMPT_FEAT_LEN = PROMPT_TOKEN_LEN * TOKEN_MEL_RATIO  # 500

XVECTOR_DIM = 192

# Speech tokens the flow decoder converts in one pass. Fixed, not flexible:
# every alternative (RangeDim, enumerated shapes) reuses a single traced graph,
# and the conformer encoder bakes its padding masks in as constants when traced,
# so a graph traced at one length is quietly wrong at another. A short chunk is
# padded out with S3GEN_SIL, which is a real silence token rather than padding,
# and the extra audio is trimmed off by sample count on the Swift side.
#
# 768 tokens is ~30s of speech, comfortably more than one text chunk produces.
# Lower it to trade tail latency for wasted compute; the Swift side reads the
# value back out of the model's metadata, so nothing else has to change.
DEFAULT_GEN_TOKENS = 768


def snapshot_dir() -> Path:
    """Where the Nano weights already are, without re-downloading them."""
    from huggingface_hub import snapshot_download

    return Path(
        snapshot_download(
            repo_id="ResembleAI/chatterbox-nano",
            token=os.getenv("HF_TOKEN") or None,
            allow_patterns=["*.safetensors", "*.json", "*.txt", "*.pt", "*.model"],
        )
    )


def load_nano():
    """The full torch model on the CPU, in eval mode.

    Loaded through chatterbox's own loader rather than from the safetensors
    directly: the checkpoint's layout is the loader's business, and this way an
    upstream change breaks here loudly instead of producing a subtly wrong
    export.
    """
    from chatterbox.tts_turbo import ChatterboxTurboTTS

    model = ChatterboxTurboTTS.from_local(snapshot_dir(), device="cpu", nano=True)
    model.t3.eval()
    model.s3gen.eval()
    return model


def check(name: str, got, want, atol=1e-3, rtol=1e-3) -> bool:
    """Report how far a re-implementation drifted from the original module."""
    import numpy as np

    got = got.detach().float().numpy() if torch.is_tensor(got) else np.asarray(got)
    want = want.detach().float().numpy() if torch.is_tensor(want) else np.asarray(want)
    if got.shape != want.shape:
        print(f"  {name}: SHAPE {got.shape} != {want.shape}")
        return False
    err = np.abs(got - want).max()
    scale = max(np.abs(want).max(), 1e-9)
    ok = err <= atol + rtol * scale
    print(f"  {name}: max abs err {err:.3e} (scale {scale:.3e}) {'ok' if ok else 'FAIL'}")
    return bool(ok)
