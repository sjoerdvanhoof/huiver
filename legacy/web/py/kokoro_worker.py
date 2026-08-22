#!/usr/bin/env python
"""Persistent Kokoro-82M TTS worker.

Speaks a newline-delimited JSON protocol so the model is loaded once per job
instead of once per track.

stdin  <- {"cmd": "track", "id": str, "chunks": [str], "voice": str,
           "speed": float, "out": "/abs/path.wav"}
          {"cmd": "stream", "id": str, "chunks": [str], "voice": str,
           "speed": float, "dir": "/abs/tmpdir"}
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

`cancel` is honoured between chunks, so abandoning a stream stops the work
without tearing down the worker (reloading the model costs ~6s and ~1 GB).

`stream` writes one WAV per chunk and announces each as soon as it exists, so
the caller can start playing before the chapter has finished rendering. The
caller owns those files and is expected to delete them.
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

# Network policy. The text being spoken NEVER leaves this machine — synthesis is
# local torch inference. The only outbound traffic is huggingface_hub fetching
# the Kokoro weights and per-voice files into ~/.cache/huggingface, plus a cache
# freshness check on start. Opt out entirely with HUIVER_OFFLINE=1 once the
# voices you use are cached (each voice downloads on first use).
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
if os.environ.get("HUIVER_OFFLINE") == "1":
    os.environ.setdefault("HF_HUB_OFFLINE", "1")

SAMPLE_RATE = 24000
GAP_SECONDS = 0.25

# Each worker holds ~1 GB of model weights, so a leaked one is expensive. The
# server normally closes us, but it cannot when its module is swapped out by
# `bun --hot` (our stdin stays open because bun itself is still alive), so we
# also police our own lifetime.
IDLE_EXIT_SECONDS = float(os.environ.get("HUIVER_WORKER_IDLE_EXIT", "300"))

_activity = {"last": time.monotonic(), "busy": False}
_activity_lock = threading.Lock()

# stdin is read on its own thread so a `cancel` can arrive while the main
# thread is busy rendering the request it refers to.
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
    from kokoro import KPipeline
except Exception as exc:  # noqa: BLE001 - report any import failure upstream
    emit({"type": "fatal", "message": f"import failed: {exc}"})
    sys.exit(1)


REPO_ID = "hexgrad/Kokoro-82M"
_pipelines = {}


def select_device():
    """Kokoro only auto-detects CUDA, so Apple Silicon would sit on the CPU.

    Measured on an M1 Air: MPS renders ~43% faster than CPU (7.8x vs 5.4x
    realtime) with waveform-identical output. Override with HUIVER_DEVICE.
    """
    choice = (os.environ.get("HUIVER_DEVICE") or "auto").strip().lower()
    if choice and choice != "auto":
        return choice
    try:
        if torch.backends.mps.is_available():
            return "mps"
    except Exception:  # noqa: BLE001 - older torch without the mps backend
        pass
    return "cuda" if torch.cuda.is_available() else "cpu"


_device = select_device()
_clear_mps_cache = os.environ.get("HUIVER_MPS_CACHE_CLEAR", "1") != "0"


def log_mps_memory(label):
    """Log allocator state without making diagnostics part of the protocol."""
    if _device != "mps":
        return
    try:
        allocated = torch.mps.current_allocated_memory() / (1024**2)
        driver = torch.mps.driver_allocated_memory() / (1024**2)
        print(
            f"[kokoro] MPS memory {label}: allocated={allocated:.0f} MiB "
            f"driver={driver:.0f} MiB",
            file=sys.stderr,
            flush=True,
        )
    except Exception as exc:  # noqa: BLE001 - diagnostics must never break speech
        print(f"[kokoro] MPS memory unavailable: {exc}", file=sys.stderr, flush=True)


def release_inference_memory():
    """Return completed Metal allocations instead of growing to MPS's ceiling."""
    if _device == "mps" and _clear_mps_cache:
        torch.mps.synchronize()
        torch.mps.empty_cache()


def get_pipeline(lang_code):
    global _device
    if lang_code not in _pipelines:
        try:
            _pipelines[lang_code] = KPipeline(
                lang_code=lang_code, repo_id=REPO_ID, device=_device
            )
        except Exception as exc:  # noqa: BLE001 - never let a bad device be fatal
            if _device == "cpu":
                raise
            print(f"device {_device!r} failed ({exc}); falling back to CPU", file=sys.stderr)
            _device = "cpu"
            _pipelines[lang_code] = KPipeline(
                lang_code=lang_code, repo_id=REPO_ID, device="cpu"
            )
    return _pipelines[lang_code]


def lang_for_voice(voice):
    """Kokoro encodes the language in the voice-name prefix (af_*, bm_*, ...)."""
    code = voice[0] if voice else "a"
    return code if code in "abefhijpz" else "a"


def to_numpy(audio):
    if hasattr(audio, "detach"):
        audio = audio.detach().cpu().numpy()
    return np.asarray(audio, dtype=np.float32)


def handle_track(req):
    rid = req["id"]
    chunks = req.get("chunks") or []
    voice = req.get("voice") or "af_heart"
    speed = float(req.get("speed") or 1.0)
    out = req["out"]
    append = bool(req.get("append"))

    pipeline = get_pipeline(lang_for_voice(voice))
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
                for _, _, audio in pipeline(
                    text, voice=voice, speed=speed, split_pattern=None
                ):
                    if audio is None:
                        continue
                    samples = None
                    try:
                        samples = to_numpy(audio)
                        wav.write(samples)
                        frames += len(samples)
                    finally:
                        del samples
                        del audio
                        release_inference_memory()
                wav.write(gap)
                frames += len(gap)
            emit({"type": "chunk", "id": rid, "index": index + 1, "total": total})

        # Preserve the previous behavior: even an empty track is a valid WAV.
        if frames == 0 and not append:
            wav.write(np.zeros(1, dtype=np.float32))
            frames = 1

    emit(
        {
            "type": "track",
            "id": rid,
            "duration": frames / SAMPLE_RATE,
            "path": out,
        }
    )
    log_mps_memory("after track")


def handle_stream(req):
    """Render chunk by chunk, publishing each one the moment it is ready."""
    rid = req["id"]
    chunks = req.get("chunks") or []
    voice = req.get("voice") or "af_heart"
    speed = float(req.get("speed") or 1.0)
    out_dir = req["dir"]

    pipeline = get_pipeline(lang_for_voice(voice))
    gap = np.zeros(int(SAMPLE_RATE * GAP_SECONDS), dtype=np.float32)
    os.makedirs(out_dir, exist_ok=True)

    for index, text in enumerate(chunks):
        if is_cancelled(rid):
            emit({"type": "cancelled", "id": rid})
            return

        text = (text or "").strip()
        if not text:
            continue

        path = os.path.join(out_dir, f"{rid}-{index:05d}.wav")
        frames = 0
        with sf.SoundFile(path, mode="w", samplerate=SAMPLE_RATE, channels=1) as wav:
            for _, _, audio in pipeline(
                text, voice=voice, speed=speed, split_pattern=None
            ):
                if audio is None:
                    continue
                samples = None
                try:
                    samples = to_numpy(audio)
                    wav.write(samples)
                    frames += len(samples)
                finally:
                    del samples
                    del audio
                    release_inference_memory()
            if frames:
                wav.write(gap)

        if not frames:
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

    # stdin closed: the server is gone, or done with us. Leave at once instead of
    # finishing the chunk we are on — a server that was killed mid-chapter is
    # replaced by one that resumes the very file we would still be writing to,
    # and we hold ~1 GB that nobody is waiting on.
    os._exit(0)


def main():
    threading.Thread(target=watchdog, args=(os.getppid(),), daemon=True).start()
    threading.Thread(target=read_stdin, daemon=True).start()

    emit({"type": "ready", "sampleRate": SAMPLE_RATE, "device": _device})
    log_mps_memory("startup")

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
