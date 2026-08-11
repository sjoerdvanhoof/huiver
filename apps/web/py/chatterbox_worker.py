#!/usr/bin/env python
"""Persistent Chatterbox Nano TTS worker.

Speaks the same newline-delimited JSON protocol as kokoro_worker.py, so the
server talks to both engines through one class (src/server/tts/python-worker.ts).
The differences are all in the request:

  * there is no voice roster. Chatterbox clones whatever reference clip it is
    given, so a request names a clip rather than a speaker, and `voice` is only
    the name we filed that clip under.
  * `speed` is ignored. The model has no speed control; the player changes
    playback rate instead, which is what happens for Kokoro too.

A request carries either `prompt` (clone this clip) or `builtin: true` (use the
voice baked into Nano's own conds.pt). Never neither: a reference clip that has
gone missing must fail rather than silently fall back to a different voice.

stdin  <- {"cmd": "track", "id": str, "chunks": [str], "voice": str,
           "prompt": "/abs/ref.wav" | null, "builtin": bool,
           "out": "/abs/path.wav", "append": bool}
          {"cmd": "stream", "id": str, "chunks": [str], "voice": str,
           "prompt": "/abs/ref.wav" | null, "builtin": bool, "dir": "/abs/tmpdir"}
          {"cmd": "cancel", "id": str}
          {"cmd": "quit"}
stdout -> {"type": "ready", "sampleRate": 24000}
          {"type": "chunk", "id": str, "index": int, "total": int}
          {"type": "audio", "id": str, "index": int, "path": str}   (stream only)
          {"type": "track", "id": str, "duration": float, "path": str}
          {"type": "done", "id": str}                               (stream only)
          {"type": "cancelled", "id": str}
          {"type": "error", "id": str, "message": str}
          {"type": "fatal", "message": str}

Output is always 24 kHz mono, resampled if the model's own rate differs, because
the rest of huiver — stored streams, partial WAVs, resume checkpoints — is
written at one rate and a chapter must not change rate halfway through.

Chatterbox is autoregressive, so a chunk cannot be interrupted partway; `cancel`
is honoured between chunks, as it is for Kokoro.
"""

import json
import os
import queue
import sys
import threading
import time
import traceback
import warnings

warnings.filterwarnings("ignore")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

# Network policy, as for Kokoro. The text being spoken NEVER leaves this
# machine — synthesis is local torch inference. The only outbound traffic is
# huggingface_hub fetching the Chatterbox Nano weights into ~/.cache/huggingface
# on first use. Opt out with HUIVER_OFFLINE=1 once they are cached.
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
if os.environ.get("HUIVER_OFFLINE") == "1":
    os.environ.setdefault("HF_HUB_OFFLINE", "1")

SAMPLE_RATE = 24000
GAP_SECONDS = 0.25

# Sampling controls, with the library's own defaults.
#
# Note that `exaggeration` and `cfg_weight` — the two knobs the base Chatterbox
# model is known for — are accepted and then explicitly ignored by the Turbo and
# Nano generators, so they are deliberately not exposed here. These three are
# the ones that do something. Lowering the temperature makes a long book read
# more evenly, at the cost of some life.
TEMPERATURE = float(os.environ.get("HUIVER_CHATTERBOX_TEMPERATURE", "0.8"))
TOP_P = float(os.environ.get("HUIVER_CHATTERBOX_TOP_P", "0.95"))
REPETITION_PENALTY = float(os.environ.get("HUIVER_CHATTERBOX_REPETITION_PENALTY", "1.2"))

IDLE_EXIT_SECONDS = float(os.environ.get("HUIVER_WORKER_IDLE_EXIT", "300"))

_activity = {"last": time.monotonic(), "busy": False}
_activity_lock = threading.Lock()

_requests = queue.Queue()
_cancelled = set()
_cancelled_lock = threading.Lock()


def cancel(rid):
    with _cancelled_lock:
        _cancelled.add(rid)


def is_cancelled(rid):
    with _cancelled_lock:
        return rid in _cancelled


def forget(rid):
    with _cancelled_lock:
        _cancelled.discard(rid)


def mark(busy=None):
    with _activity_lock:
        _activity["last"] = time.monotonic()
        if busy is not None:
            _activity["busy"] = busy


def watchdog(original_parent):
    while True:
        time.sleep(5)

        # Reparented to init means the server died without closing us.
        if os.getppid() != original_parent:
            os._exit(0)

        with _activity_lock:
            idle = time.monotonic() - _activity["last"]
            busy = _activity["busy"]

        if not busy and 0 < IDLE_EXIT_SECONDS < idle:
            os._exit(0)


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


try:
    import numpy as np
    import soundfile as sf
    import torch
    import torchaudio
    from chatterbox.tts_turbo import ChatterboxTurboTTS
except Exception as exc:  # noqa: BLE001 - report any import failure upstream
    emit({"type": "fatal", "message": f"import failed: {exc}"})
    sys.exit(1)


def select_device():
    """CPU by default, even on Apple silicon.

    Nano is 110M parameters and runs several times faster than realtime on CPU,
    while its autoregressive backbone on MPS is both unproven and dominated by
    per-token dispatch overhead. CUDA is the one accelerator taken automatically.
    Force the choice with HUIVER_CHATTERBOX_DEVICE=mps|cpu|cuda.
    """
    choice = (os.environ.get("HUIVER_CHATTERBOX_DEVICE") or "auto").strip().lower()
    if choice and choice != "auto":
        return choice
    try:
        return "cuda" if torch.cuda.is_available() else "cpu"
    except Exception:  # noqa: BLE001 - a torch without cuda support at all
        return "cpu"


_device = select_device()
_model = None

# Nano's own voice, saved aside the moment the weights load: cloning a reference
# clip overwrites model.conds, and this is the only way back to it.
_model_voice_conds = None

# Which reference the model is currently conditioned on, so a chapter read in
# one voice embeds its clip once rather than once per chunk. BUILTIN is the
# sentinel for "the model's own voice".
BUILTIN = "\0builtin"
_conditioned_on = None


def get_model():
    global _model, _model_voice_conds, _device
    if _model is not None:
        return _model

    try:
        _model = ChatterboxTurboTTS.from_pretrained(device=_device, nano=True)
    except Exception as exc:  # noqa: BLE001 - never let a bad device be fatal
        if _device == "cpu":
            raise
        print(f"device {_device!r} failed ({exc}); falling back to CPU", file=sys.stderr)
        _device = "cpu"
        _model = ChatterboxTurboTTS.from_pretrained(device="cpu", nano=True)

    _model_voice_conds = _model.conds
    print(f"[chatterbox] nano loaded on {_device} at {_model.sr} Hz", file=sys.stderr, flush=True)
    return _model


def condition_on(prompt):
    """Point the model at a voice: a reference clip, or its own.

    Embedding a clip is a second or two of work, so it is done once per voice
    rather than once per chunk — which is also why the model's own conditionals
    have to be put back by hand when a chapter asks for them again.
    """
    global _conditioned_on
    model = get_model()
    target = prompt or BUILTIN
    if _conditioned_on == target:
        return

    # A failed switch must not leave us claiming the new voice is loaded.
    _conditioned_on = None

    if prompt is None:
        if _model_voice_conds is None:
            raise ValueError("this build of Chatterbox Nano has no built-in voice")
        model.conds = _model_voice_conds
    else:
        model.prepare_conditionals(prompt)

    _conditioned_on = target


def reference_for(req):
    """The clip to clone, or None for the voice Nano already has."""
    if req.get("builtin"):
        return None

    prompt = req.get("prompt")
    if not prompt:
        raise ValueError("no reference clip for this voice")
    if not os.path.exists(prompt):
        raise ValueError(f"reference clip is missing: {prompt}")
    return prompt


def to_numpy(audio, rate):
    """One channel of float32 at SAMPLE_RATE, whatever generate() handed back."""
    if not torch.is_tensor(audio):
        audio = torch.as_tensor(audio)
    audio = audio.detach().to("cpu", dtype=torch.float32)
    if audio.ndim == 1:
        audio = audio.unsqueeze(0)
    if audio.shape[0] > 1:
        audio = audio.mean(dim=0, keepdim=True)
    if rate != SAMPLE_RATE:
        audio = torchaudio.functional.resample(audio, rate, SAMPLE_RATE)
    return np.asarray(audio.squeeze(0).numpy(), dtype=np.float32)


def speak(text):
    """One chunk of text, with whatever voice condition_on last installed."""
    model = get_model()
    with torch.inference_mode():
        wav = model.generate(
            text,
            temperature=TEMPERATURE,
            top_p=TOP_P,
            repetition_penalty=REPETITION_PENALTY,
        )
    return to_numpy(wav, model.sr)


def handle_track(req):
    rid = req["id"]
    chunks = req.get("chunks") or []
    out = req["out"]
    append = bool(req.get("append"))

    condition_on(reference_for(req))
    gap = np.zeros(int(SAMPLE_RATE * GAP_SECONDS), dtype=np.float32)
    total = len(chunks)
    frames = 0

    os.makedirs(os.path.dirname(out), exist_ok=True)
    mode = "r+" if append and os.path.exists(out) else "w"
    wav_file = (
        sf.SoundFile(out, mode="r+")
        if mode == "r+"
        else sf.SoundFile(out, mode="w", samplerate=SAMPLE_RATE, channels=1)
    )
    with wav_file as wav:
        if mode == "r+":
            wav.seek(0, sf.SEEK_END)
        for index, text in enumerate(chunks):
            if is_cancelled(rid):
                emit({"type": "cancelled", "id": rid})
                return

            text = (text or "").strip()
            if text:
                samples = speak(text)
                wav.write(samples)
                frames += len(samples)
                wav.write(gap)
                frames += len(gap)
            emit({"type": "chunk", "id": rid, "index": index + 1, "total": total})

        # Even an empty track is a valid WAV, as on the Kokoro path.
        if frames == 0 and not append:
            wav.write(np.zeros(1, dtype=np.float32))
            frames = 1

    emit({"type": "track", "id": rid, "duration": frames / SAMPLE_RATE, "path": out})


def handle_stream(req):
    """Render chunk by chunk, publishing each one the moment it is ready."""
    rid = req["id"]
    chunks = req.get("chunks") or []
    out_dir = req["dir"]

    condition_on(reference_for(req))
    gap = np.zeros(int(SAMPLE_RATE * GAP_SECONDS), dtype=np.float32)
    os.makedirs(out_dir, exist_ok=True)

    for index, text in enumerate(chunks):
        if is_cancelled(rid):
            emit({"type": "cancelled", "id": rid})
            return

        text = (text or "").strip()
        if not text:
            continue

        samples = speak(text)
        path = os.path.join(out_dir, f"{rid}-{index:05d}.wav")
        with sf.SoundFile(path, mode="w", samplerate=SAMPLE_RATE, channels=1) as wav:
            wav.write(samples)
            wav.write(gap)

        if not len(samples):
            os.remove(path)
            continue
        emit({"type": "audio", "id": rid, "index": index, "path": path})

    emit({"type": "done", "id": rid})


def read_stdin():
    """Queue work, but apply `cancel` immediately so it can interrupt a render."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            emit({"type": "error", "id": None, "message": f"bad request: {exc}"})
            continue

        if req.get("cmd") == "cancel":
            cancel(req.get("id"))
        else:
            _requests.put(req)

    # stdin closed: the server is gone, or done with us. Leave at once rather
    # than finishing the chunk we are on — a server that was killed mid-chapter
    # is replaced by one that resumes the very file we would still be writing.
    os._exit(0)


def main():
    threading.Thread(target=watchdog, args=(os.getppid(),), daemon=True).start()
    threading.Thread(target=read_stdin, daemon=True).start()

    # Ready before the weights are loaded, as Kokoro is: the first request pays
    # for the load, and the server is free to spawn us speculatively.
    emit({"type": "ready", "sampleRate": SAMPLE_RATE, "device": _device})

    while True:
        req = _requests.get()
        if req is None:
            break

        cmd = req.get("cmd")
        if cmd == "quit":
            break
        if cmd not in ("track", "stream"):
            emit({"type": "error", "id": req.get("id"), "message": f"unknown cmd {cmd!r}"})
            continue

        rid = req.get("id")
        try:
            mark(busy=True)
            if is_cancelled(rid):
                # Cancelled while still queued — never start it.
                emit({"type": "cancelled", "id": rid})
            elif cmd == "track":
                handle_track(req)
            else:
                handle_stream(req)
        except Exception as exc:  # noqa: BLE001 - one bad track must not kill the worker
            print(traceback.format_exc(), file=sys.stderr)
            emit({"type": "error", "id": rid, "message": str(exc)})
        finally:
            mark(busy=False)
            forget(rid)


if __name__ == "__main__":
    main()
