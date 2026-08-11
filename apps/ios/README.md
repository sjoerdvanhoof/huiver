# huiver for iOS — Chatterbox Nano, natively

A native Swift app that reads books in a cloned voice, with
[Chatterbox Nano](https://huggingface.co/ResembleAI/chatterbox-nano) running on
the phone through Core ML. No server, no network after the app is installed, and
no Kokoro: this app is Chatterbox only.

It is a separate app from `apps/mobile`, which is the Expo/Kokoro one. Neither
replaces the other and they share no code.

| | `apps/mobile` (Expo) | `apps/ios` (this) |
| --- | --- | --- |
| Engine | Kokoro via `react-native-sherpa-onnx` | Chatterbox Nano via Core ML |
| Voices | 21 built-in | 11 cloned, shipped with the app |
| UI | React Native | SwiftUI |
| Platforms | iOS and Android | iOS 18+ |
| Bundle id | `online.mo4.huiver` | `online.mo4.huiver.nano` |

The bundle ids differ deliberately. They started out the same, which would have
meant installing one replaced the other on the phone rather than sitting beside
it.

## Getting it onto your phone

You need Xcode with the iOS platform, and the desktop app's Chatterbox venv,
which is where the weights already are.

```bash
bun run setup:chatterbox     # if you have not already — creates .venv-chatterbox
bun run ios:setup            # adds coremltools to that venv
bun run ios:export           # converts Nano to Core ML (~25 min, one time)
bun run ios:voices           # turns the reference clips into voice files
bun run ios:install          # compiles the models into apps/ios/Models
```

Then open `apps/ios/Huiver.xcodeproj`, pick your team under *Signing &
Capabilities*, and run it on your iPhone. A free Apple ID works; the build
expires after seven days and you re-run it.

`bun run ios:voices` clones the ten LibriVox narrators the desktop app uses, so
run `bun run voices` first if you have not. Without it you still get **Nano**,
the voice baked into the weights, which needs no download.

**The first launch is slow.** Core ML compiles each model for the device the
first time it is loaded, which takes several minutes. The app shows a progress
screen for it rather than appearing to hang — the bar is weighted by how big
each model is on disk, since Core ML offers no progress callback of its own, and
there is a running clock rather than an estimate of what is left. You can put
that screen aside and add a book while it finishes.

Measured on a Mac: about 10 minutes cold, 16 seconds once cached. The cache
survives relaunches, but it is invalidated by re-exporting the models or by
changing how they are loaded, so an occasional repeat of the long wait during
development is expected.

### Size

The models are about 700 MB at float16, which is what the export produces by
default. `--quantize int8` roughly halves that:

```bash
bun run ios:export -- --quantize int8
```

Nothing generated is committed: `Models/`, `Voices/`, `build/` and
`build-voices/` are all gitignored, and everything in them is reproducible from
the two export scripts.

## How the model was got onto the phone

There is no off-the-shelf Core ML build of Chatterbox Nano, so `export/` makes
one. Four models come out, in two stages.

**T3** is the autoregressive half: a 12-layer **GPT-2 small** (not LLaMA — that
is the 500M variant) that reads a conditioning prefix and the text and emits
speech tokens at 25 Hz, one at a time. It is exported twice:

- `T3Prefill` — stateless, flexible text length, run once per chunk. It returns
  the first logits and the KV cache it built.
- `T3Decode` — stateful and fixed-shape, run a few hundred times per chunk. The
  KV cache lives inside Core ML as an `MLState`, so it never crosses back into
  Swift.

The split exists because a Core ML state belongs to one model, and the two
halves want different shapes. Swift copies the prefill's cache into the decode
model's state once per chunk (~12 MB, under a millisecond). Without the cache,
generating token *n* would re-read all *n−1* before it, which is the difference
between an app and a hand warmer.

**S3Gen** is the other half: `S3Flow` turns a run of speech tokens into mel
frames with a two-step meanflow decoder, and `S3Vocoder` turns those into 24 kHz
audio.

### Three things that had to change to convert at all

- **`torch.stft` and `torch.istft`** — the vocoder uses both and Core ML has
  neither. At `n_fft=16` they are small enough to write as convolutions against
  a DFT basis, which is what `s3_export.py` does. Checked against torch to 1e-6.
- **Randomness** — the flow decoder starts from `torch.randn`, and the source
  module draws a fresh phase and excitation noise on every call. Core ML has no
  random number generator, so the flow's noise is passed in from Swift and the
  source module's is a baked constant.
- **`view_as`** — one op coremltools does not implement, used by the conformer
  encoder's relative-position attention. Registered in `mil_ops.py`.

### Why the mel decoder has a fixed length

`S3Flow` is exported for exactly one number of speech tokens. Flexible shapes
would be nicer, but every mechanism for them — `RangeDim`, enumerated shapes —
reuses a single traced graph, and that graph is full of constants that only hold
at the length it was traced at: the conformer's padding masks, the positional
encoding slice, the mel arithmetic. A graph traced at one length is quietly
wrong at another, and "quietly" is the problem.

So a short chunk is padded out with `S3GEN_SIL`, the model's own silence token,
and the surplus audio is trimmed by sample count. The chunker's 260-character
default is sized to fit in one pass; a chunk that overruns is decoded in a
second window.

Change it with `--gen-tokens`. The Swift side reads the value back out of the
model's metadata, so nothing else needs touching.

### Checking the conversion

A converted model that loads, runs and produces plausible noise looks exactly
like one that works, so nothing is written without being compared against torch
first:

```bash
bun run ios:verify
```

Current results, at float16:

| | |
| --- | --- |
| T3 prefill logits | correlation 0.999993 |
| T3 decode, 8 greedy steps | identical tokens |
| S3 flow mel, Core ML vs torch | correlation 0.999998 |
| S3 flow mel, torch re-implementation vs original | bit-exact |
| stft / istft stand-ins | 1e-6 |
| S3 vocoder envelope | correlation 0.999 |

The vocoder is the one thing not compared sample by sample, and not because of
conversion error: its source module draws a random phase per harmonic and random
excitation noise on every call, so two runs of the *original* model do not agree
either. The export replaces both with constants, and what gets checked is the
energy envelope. Raw sample correlation lands around 0.97, which is what two
identical readings with different dither look like.

`export_models.py` also runs the torch-level half of this before converting, and
refuses to write a model that does not match — a mismatch there is a bug in the
export scripts, whereas one after conversion is a bug in coremltools, and
telling them apart afterwards is miserable.

`probe.py` prints every shape the export depends on. Run it after bumping the
chatterbox pin in `apps/web/py/requirements-chatterbox.txt`; the constants in
`common.py` are properties of the checkpoint, not of its config file.

## Voices, and why there is no recording

Chatterbox has no voice roster — it clones whatever ten-to-fifteen second clip
it is given. Doing that on the phone would mean exporting three more networks: a
speech tokenizer, a speaker encoder and an x-vector model.

So the cloning happens on the Mac, once. `export_voices.py` reduces each
reference clip to about 165 KB of conditionals, and that is what ships:

```
speaker_emb    (256,)      who is speaking, for T3
cond_prompt    (375,)      speech tokens of them reading the passage
prompt_token   (250,)      the same clip again, for the mel decoder
prompt_feat    (500, 80)   and as mel frames
embedding      (192,)      an x-vector
```

The recording never leaves the Mac and none of these can be turned back into it.
The lengths are fixed rather than per-voice — the clip is cut to exactly ten
seconds — which is what leaves the mel decoder with one free dimension instead
of three.

**Recording a voice on the phone is not in this version.** Anything you record
in the web app is picked up by `ios:voices` and shipped like the rest.

## The app

```
Sources/HuiverKit/    everything that is not a view
Huiver/               the SwiftUI screens
Tests/HuiverKitTests/ swift test
export/               the Core ML conversion
```

`HuiverKit` is a Swift package so it can be built and tested on the Mac with
`swift test` — 22 tests, no simulator, under a second. The Xcode target compiles
the same sources directly rather than depending on the package, which is why the
app files do not `import HuiverKit`: it is all one module there.

The text pipeline is a port of the desktop app's, deliberately faithful, so a
book breaks into the same chapters and pauses in the same places whichever
huiver reads it: `Chunker` matches `packages/shared/src/chunk.ts`, `Extract`
matches `extract.ts`, `PuncNorm` matches chatterbox's own `punc_norm`. The
tokenizer is checked against reference ids generated by the Python tokenizer.

### Playback

Each chunk is rendered to its own WAV and scheduled on an `AVAudioPlayerNode` as
it lands, so audio starts after the first sentence rather than after the
chapter. The desktop app pipes a growing MP3 to an `<audio>` element; iOS cannot
seek a stream whose length it does not know, so the phone walks files instead.

Those files are also the checkpoint. A render interrupted anywhere — the app was
killed, you pressed stop — leaves a prefix of numbered WAVs, and starting again
picks up at the first one missing. A prefix is only reused when the work is
identical; change the voice and the audio is discarded rather than continued,
because half a chapter in one voice and half in another is worse than
re-rendering.

There is no ffmpeg on the phone, so chapters stay as 24 kHz 16-bit WAV: about
173 MB per hour, against roughly 29 MB for the desktop app's 64 kbps MP3.

### What is not there yet

- Recording your own voice on the phone (see above).
- Seeking within a chapter. Playback is sequential; stop and start again.
- Lock-screen controls and a `Now Playing` entry.
- Android, which Core ML rules out by construction.

## Speed

Nano is autoregressive and dominated by per-token dispatch, so it is slower than
Kokoro by a wide margin. The desktop torch path measures about 1.2× realtime on
an M-series CPU; budget roughly an hour of compute per hour of audiobook, and
expect a phone to run hot doing it. Converting a chapter and listening later is
the comfortable way to use this.

The end-to-end test (`swift test --filter EngineTests`) is the only measurement
taken here so far, and it is a Mac rather than a phone: 13.5 s warm to produce
2.2 s of audio, including loading all four models. That is not a throughput
figure — most of it is the one-off load — but it is the number that has actually
been observed, and **no timing on real hardware has been measured yet.**

Two things are worth knowing before reading too much into any of it:

- Core ML declines to put the flexible-shape prefill model on the Neural Engine
  (`ANECCompile() FAILED` in the log, then a silent fall back to GPU/CPU). The
  fixed-shape decode step, which is the hot loop, is the one that matters.
- Nothing has been profiled per stage, so where the time actually goes — prefill,
  the token loop, the mel decoder, the vocoder — is still unknown.

iOS suspends an app a few seconds after it leaves the screen unless audio is
playing, so synthesis continues in the background while you are listening and
stops when you background the app with nothing playing.
