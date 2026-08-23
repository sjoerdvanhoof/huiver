# huiver for iOS — Chatterbox Nano, natively

A native Swift app that reads books in a cloned voice, with
[Chatterbox Nano](https://huggingface.co/ResembleAI/chatterbox-nano) running on
the phone through Core ML. No server, no network after the app is installed, and
no Kokoro: this app is Chatterbox only.

It replaced `legacy/mobile`, the Expo/Kokoro app, which is retired and no longer
worked on. They share no code. The comparison is kept because it is the reason
this app exists:

| | `legacy/mobile` (Expo, retired) | `apps/ios` (this) |
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
bun run setup:chatterbox     # if you have not already — tools/export/.venv-chatterbox
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

**Most of that used to be one model compiling for a processor it never ran on.**
Offered to the Neural Engine, `S3Flow` — a conformer over 2036 positions, 7,000
lines of MIL — keeps `ANECompilerService` at 100% for **over nineteen minutes**
without finishing; loaded as `cpuAndGPU` the same package is ready in **2.2
seconds**, both measured cold on an M-series Mac. So the export records
`computeUnits` on every package and `ComputeUnits.ladder(for:)` reads it before
loading. Nothing goes to the Neural Engine, and each package has its own reason:

| package | why not the Neural Engine |
| --- | --- |
| `T3Decode` | compiles and loads there, then **fails every prediction** — see below |
| `S3Flow` | the nineteen-minute compile above |
| `T3Prefill` | flexible text dimension, which the ANE compiler will not take (`ANECCompile() FAILED`) |
| `S3Vocoder` | `HiFTGenerator`'s DFT stand-ins fail the ANE compile outright |

### The decode step is the one that hurt

`T3Decode` is the graph the Neural Engine should have earned: fixed shapes,
hundreds of runs per chunk. It compiles for the ANE, it loads there without
complaint, and then every prediction comes back as

```
ANEProgramProcessRequestDirect() Failed with status=0x1 : statusType=0x9:
  Program Inference error
```

which Core ML hands the app as `Unable to compute the prediction using ML
Program. It can be an invalid input data or broken/unsupported model.` The
stateful KV cache is the likely cause — two 31 MB fp16 states — so reclaiming
the engine means exporting the cache as ordinary inputs and outputs rather than
as Core ML state. That is a different export, not a flag; `--decode-units all`
is there for the day it exists.

Two things about this are worth keeping in mind, because together they hid it
for a long time:

- **A compile failure falls back; an inference failure does not.** `S3Vocoder`
  fails `ANECCompile()` and Core ML quietly moves it to the GPU, so it works.
  `T3Decode` compiles *successfully*, which commits Core ML to the engine, and
  there is nowhere to fall back to once a prediction throws.
- **The Mac cannot see it.** macOS answers an `.all` load for these graphs with
  the GPU, so `swift test --filter EngineTests` renders a sentence perfectly
  while the phone cannot produce a single chunk. Reproduce it by asking for the
  engine explicitly, which is what `MLComputeUnits.cpuAndNeuralEngine` is for.

Packages exported before all this can be relabelled without re-tracing — the
weights do not change, only one metadata string:

```bash
cd tools/export && ./.venv-chatterbox/bin/python tag_compute_units.py ../../apps/ios/build
bun run ios:install
```

### Size

The export quantises weights to int8 by default, which is what ships — about
410 MB of compiled models, plus 262 MB for the voice cloner if it is installed,
for 674 MB in the app. `--quantize none` keeps float16 at roughly twice
the size:

```bash
bun run ios:export -- --quantize none
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
and the surplus audio is trimmed by sample count. The chunker targets 350
characters with a 500-character ceiling, sized to fit in one pass; a chunk that
overruns is decoded in a second window with run-up context.

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

## Voices, and recording your own

Chatterbox has no voice roster — it clones whatever ten-to-fifteen second clip
it is given. The ten voices that ship were cloned on the Mac, once:
`export_voices.py` reduces each reference clip to about 165 KB of conditionals,
and that is what travels.

```
speaker_emb    (256,)      who is speaking, for T3
cond_prompt    (375,)      speech tokens of them reading the passage
prompt_token   (250,)      the same clip again, for the mel decoder
prompt_feat    (500, 80)   and as mel frames
embedding      (192,)      an x-vector
```

The recording never leaves the device and none of these can be turned back into
it. The lengths are fixed rather than per-voice, which is what leaves the mel
decoder with one free dimension instead of three.

### Recording one on the phone

Settings › Voice › **Record your own voice**. Read the passage for about fifteen
seconds, name it, and it joins the roster; swipe to delete it again. Everything
happens on the phone.

Doing this needed a fourth package. Cloning is three networks the engine does
not otherwise carry — a speech tokenizer, an LSTM speaker encoder and an
x-vector net — plus four mel front-ends, and `mtl_clone_export.py` had already
made all of that convertible for the Mac. The graph is checkpoint-agnostic, so
`bun run ios:clone` is the same export run against Nano's weights. It is
**262 MB**, which is why the app's models went from 412 MB to 674 MB, and why
`AppModel.cloneVoice` loads it for the clone and drops it again rather than
holding it beside the engine: 736 MB of weights are already resident, and iOS
answers a high-water mark it dislikes by killing the app with no crash report.

Three things about Nano's cloning differ from the multilingual one, and every
one of them produced a plausible voice rather than an error when it was wrong —
which is why `verify_clone.py --nano` exists and what it checks:

| | multilingual | Nano |
| --- | --- | --- |
| clip the cloner reads | 10 s | **15 s** (`ChatterboxTurboTTS.ENC_COND_LEN`) |
| conditioning prompt | 150 tokens | **375** |
| loudness | as recorded | **normalised to −27 LUFS** |

The loudness one is the subtle one. The mel the decoder conditions on is a *log*
magnitude, so the clip's level lands in it as an offset: cloning without
normalising cost 0.977 speaker cosine and 0.998 mel cosine against the Python
pipeline, where doing it gives 1.000000 for both. It is a single gain, so it
stays out of the Core ML graph — Core ML has no IIR and BS.1770 is two of them —
and lives in `Loudness`, held to `pyloudnorm` by `LoudnessTests`.

Against a full fifteen seconds the exported cloner reproduces `prepare_conditionals`
exactly in torch, and to six decimal places of cosine through Core ML at float16.
A **short** clip is the one case that provably differs: upstream trims the
silence before the voice encoder sees it and a fixed-shape graph cannot, which
measured 0.977 rather than 1.000000. Hence the sheet's progress bar, and the
warning it shows when a take falls short.

```bash
bun run ios:clone          # export the cloner (about 20 s, after the checkpoint loads)
bun run ios:verify:clone   # against prepare_conditionals
bun run ios:install
```

## Languages

Set per book, not globally: a library is not monolingual, and one Dutch book
among twenty English ones should not need a setting changed before and after
reading it. The language is guessed from the book's own text on import — using
`NLLanguageRecognizer`, which is on-device and better at telling Dutch from
German than any word list worth writing — and can be corrected in the book's
own screen.

**Nano only reads English, and that is a property of the checkpoint rather than
of this app.** Chatterbox does have 23 languages, Dutch among them, but they
live in a different model:

| | Nano (shipped here) | Multilingual |
| --- | --- | --- |
| Text vocabulary | 50276 — GPT-2's English byte pairs | 2454 — `MTLTokenizer`, `[nl]`-prefixed |
| Backbone | GPT-2 small, 12 layers, 768 wide | LLaMA, 30 layers, 1024 wide, 503M params |
| Mel decoder | meanflow, 2 CFM steps | plain CFM, 10 steps |
| `language_id` | not a parameter | 23 languages |

So Dutch is not a flag that was left unset; it needs a second model roughly four
times larger, whose mel decoder does five times the work. On a phone where Nano
already runs at about the speed of speech, that is likely hours of compute per
hour of audio, and it would add around a gigabyte to the app even at int8 —
twice that at float16, because the prefill/decode split holds the backbone twice.

That trade was considered and declined. A book in an unsupported language is
therefore *still read*, with English pronunciation, and the book's screen says so
plainly rather than hiding it behind a disabled button — Nano's byte-level
tokenizer has no unknown token, so foreign text produces confidently wrong
pronunciation rather than an error.

The plumbing is in place if that changes: the language travels per book, and the
engine reports what it can read from a `languages` key in the exported model's
metadata.

**That key and a Swift port of `MTLTokenizer` are not, as this file used to
claim, the whole of it.** Read off the checkpoint by `tools/export/probe_mtl.py`,
the multilingual model also differs in ways the decode loop can see:

| | Nano | Multilingual |
| --- | --- | --- |
| Guidance | none | classifier-free, mandatory: every token is a batch of two |
| Uncond branch | — | text embeddings zeroed, learned positions kept |
| Conditioning | speaker + 375 prompt tokens | speaker + 32 perceiver latents + an emotion token |
| Positions | — | RoPE *and* learned, both |
| Speech vocab | 6563 | 8194 |
| Sampler order | temperature, top-k, top-p, penalty | CFG, penalty, temperature, min-p, top-p |

None of that is a flag; it is a second engine that happens to share a shape.
`tools/export/verify_mtl.py` is where the loop is pinned down — it checks a
second implementation of it against chatterbox's own, which is the step that
has to come before any of it is written in Swift.

## The app

```
apps/ios/Huiver/                            the SwiftUI screens
packages/huiverkit/Sources/HuiverKit/       everything that is not a view
packages/huiverkit/Tests/HuiverKitTests/    bun run kit:test
tools/export/                               the Core ML conversion
```

`HuiverKit` lives outside the app because the Mac companion in `apps/mac` shares
it. It is a Swift package so it can be built and tested on the Mac with
`bun run kit:test` — no simulator, under a second. Both Xcode targets compile the
same sources directly rather than depending on the package, which is why the app
files do not `import HuiverKit`: it is all one module there.

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
picks up at the first one missing. A *prefix* is only reused when the work is
identical; change the voice and the half-chapter is discarded rather than
continued, because half a chapter in one voice and half in another is worse than
re-rendering.

**A finished chapter is a different question, and the rule there is about the
audio rather than the voice.** `Narrator.route` decides it in one line: every
chunk on disk means play the files, anything else means synthesise. That has to
ignore `renderedVoice`, because audio rendered on the Mac arrives over sync
labelled with one of *its* multilingual voices — voices the phone filters out of
its own roster, since it cannot load those tensors — so "was this read by the
voice I have selected?" is permanently false for everything synced. Asking it
sent every synced chapter down the render path, which discarded the transfer
first and then read the chapter again in Nano: hours of the Mac's work deleted by
the play button. Re-reading a finished chapter in the current voice is "Render
again" in its context menu, which is a choice rather than a side effect.

There is no ffmpeg on the phone, so chapters stay as 24 kHz 16-bit WAV: about
173 MB per hour, against roughly 29 MB for the desktop app's 64 kbps MP3.

### Listening state

Positions live in `Documents/progress.json`, not in the library: a position
moves four times a second and the library is rewritten whole, text and all. The
store keeps them in memory and writes on a timer, plus at the three moments the
process might not get another chance — pausing, stopping, and the app leaving
the screen.

Each record is a position, whether the chapter was finished, and when that last
changed. That shape is not for the phone's benefit; it is what two devices need
to settle a disagreement by taking the newer one. `finished` deliberately
outlives the audio it describes, which is what lets the cleanup sweep delete a
finished chapter's WAVs without the chapter looking unheard afterwards.

A chapter that ends rolls on to the next one. That is also what makes the sleep
timer's "end of chapter" mean anything — without auto-advance, playback stops
there regardless and the setting would be a no-op.

### Reading along

The player can show the chapter's text with the sentence being spoken lit up.
Highlighting is per chunk, which is roughly per sentence: word-level would mean
forced alignment, a second model on both platforms and in all 23 languages, to
gain something short of the point. Knowing which sentence is being read is
following along.

The chunk texts are written to `chunks.json` beside the audio when a render
starts. They could be recomputed — the chunker is deterministic — but only by a
build that chunks the same way, and a future chunker change would otherwise
silently highlight the wrong sentence in every chapter rendered before it.

### What is not there yet

- Recording your own voice on the phone (see above). It happens on the Mac.
- Seeking past what has been rendered. The scrubber stops at the rendered edge,
  on the lock screen as well as in the app.
- Syncing with the Mac. The protocol is written and tested
  (`Sources/HuiverKit/Sync/`); the transport, the pairing and the Mac app it
  would talk to are not built yet.
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

- Nothing runs on the Neural Engine — see the `computeUnits` table above. The
  decode step is the hot loop and would be the one to want there; it is also the
  one whose predictions fail there, so these numbers are GPU numbers.
- Nothing has been profiled per stage, so where the time actually goes — prefill,
  the token loop, the mel decoder, the vocoder — is still unknown.

## Leaving the app mid-conversion

Conversion runs while huiver is open. iOS suspends an app a few seconds after it
leaves the screen, and there is no way around that for on-device computation: the
background modes on offer are for specific jobs — playing audio, transferring
files, receiving location — not for arbitrary work. A podcast app downloading
episodes in the background is doing a `URLSession` background transfer, which a
system daemon performs on its behalf; nothing equivalent exists that will run a
neural network for you.

An earlier version held the audio session open and played silence to dodge the
suspension. It is the usual trick, it works, and it has been taken out: it costs
battery for no audible benefit, and it is the pattern App Review rejects apps
for.

So stopping is cheap and resuming is automatic instead:

- Leaving mid-chapter takes a short background assertion, long enough to finish
  the chunk in flight, so what is on disk is a clean checkpoint rather than a
  truncated file.
- The queue is persisted, and the chapter being worked on stays at the head of it
  until it is genuinely complete. Re-opening the app carries on without pressing
  convert again — including after a force quit.
- A `BGProcessingTask` is registered, which iOS may grant later while charging
  and idle. A bonus rather than a plan.

Listening *does* continue off screen, because then the app is genuinely playing
audio. That is what the background-audio capability is for, and it is why the
live path renders as it plays.

## Core ML stops at the lock screen

Synthesis dies a few seconds after the phone leaves the screen. Core ML fails the
prediction outright — *"Unable to compute the prediction using ML Program"* — because
a backgrounded app cannot reach the GPU, and the models are not on the CPU. The
background-audio capability keeps *playback* going; it does not buy compute.

So the renderer stopping is the ordinary case for anyone who listens with the phone
in a pocket, not an exception. It is kept apart from `Narrator.State` for that
reason: `renderFailure` says synthesis stopped, and playback carries on with what is
on disk. Conflating the two is what made a locked phone lose its lock screen
controls mid-chapter — the state went `.failed`, `publish` cleared the now-playing
entry, and `pause()`'s `state == .speaking` guard then rejected every press while
audio was still coming out. Two lessons, both encoded in the code now:

- Pausing keys off `player.isPlaying`, not off `state`. If sound is coming out, the
  pause button stops it, whatever the app believes about itself.
- Synthesis restarts on `scenePhase == .active`. A resumed render walks the chapter
  from the beginning and re-reports what is already on disk, so `scheduledChunks`
  drops those rather than playing the opening over the top of the middle.
- **Restarting is not enough: the models have to be replaced.** A Core ML model that
  has failed once fails for good. Every later prediction on that `MLModel` throws
  too, in the foreground as much as off screen, and with a different error the
  second time round (`neural network model … error code -1`). So `resumeRendering`
  calls `ChatterboxEngine.reload`, which loads the four models again — quick,
  because the expensive part of a first run is Core ML compiling them for the
  device and that result is cached. The converter does the same after a failure,
  or a conversion interrupted by backgrounding would fail identically on every
  retry for the rest of the session.

### Reading on the CPU: tried, and taken out again

The restriction is on the *processor*, not on computing at all — the CPU has no such
limit — so the obvious idea is to move synthesis to the CPU while off screen and
back on return. It was built, and then removed. What it cost:

- **Core ML compiles per compute-unit configuration.** A first `.cpuOnly` load is not
  a cache read, it is a full compile, the same minutes-long job as the first run
  after installing.
- **A reload briefly needs two sets of models.** 736 MB of weights, twice over. iOS
  answers that by killing the app, with no crash report, so it reads as a mysterious
  restart rather than a memory kill — and it takes the audio with it, which is worse
  than the problem being solved.

Both together meant the switch killed the app before the CPU ever ran a single
prediction, so **the speed of CPU synthesis on device was never actually measured.**
The decision to drop it was made on the strength of the crashes, not on a number. If
this is ever revisited, get that number first, from the foreground: it is the only
thing that decides whether the idea is worth any of the above.

One piece of it was worth keeping. `reload` frees each model before loading its
replacement, one at a time, which keeps the high-water mark near one set instead of
two — the recovery reload after a failed prediction runs the same risk. Reloading is
not cheap even so: 20-90 seconds on device.

Two further fixes came out of building it, both for real bugs that predate it. A
render pass carries a generation number, so a superseded pass cannot set the state on
its way out — cancelling the task made it throw `CancellationError`, whose handler set
`.idle`, which is the "lock screen goes blank" bug all over again. And each pass has
its own stop flag: cancelling the consuming task does not stop the renderer, whose
producer lives in a task of its own and only stops when asked through `cancelled`.

What is left is the honest version: off screen, synthesis stops and playback carries
on with what is on disk; coming back reloads the models and picks synthesis up again.
Rendering the chapter first, with the app open, remains the comfortable way to use
this.

Speed, for reference — every synthesised chunk logs what it cost against what it
produced:

```
chunk 2/282 took 4.2s for 12.0s of audio (0.35× realtime)
```

Under 1.0 keeps up with playback. On an iPhone 17 the Neural Engine measures about
0.33× once past the first chunk, so it keeps up three times over. The first chunk of
a chapter is short and comes in around 1.0×, which is why playback runs dry for a
second or two at the very start.

Two smaller consequences of running out of audio, both fixed alongside:

- The player used to keep claiming to speak after playback ran past the last
  scheduled chunk. It now goes back to `.preparing` — "Reading ahead…" — which is
  exactly what it is doing, and `schedule` returns it to `.speaking` when a chunk
  lands. The check needs a second of margin: while synthesis is only just keeping
  up the playhead crosses the end of the queue constantly, and acting on that
  immediately would have the state flapping several times a chapter.
- Seeking forward stops at the rendered edge, and is refused when it would gain
  less than two seconds (`Narrator.seekTarget`). `+30 s` with three seconds
  rendered used to schedule the fraction of a sentence that existed and leave a
  silent player with the scrubber pinned.

## Off screen

Background audio keeps the sound going; it does not put anything on the lock
screen. Those controls belong to whichever app has claimed both halves of
`MediaPlayer` — metadata pushed to `MPNowPlayingInfoCenter` and commands taken
from `MPRemoteCommandCenter` — so `NowPlaying` does both, and the narrator pushes
it a snapshot whenever the state, position or rate changes.

What appears there is the chapter title, the book and author, the cover, and the
same transport as the player: play/pause, ±15/30 s, previous and next chapter, a
draggable bar, and the speed. All of it is registered, but which of the two pairs
of side buttons gets drawn — the skips or the chapters — is the system's choice
and varies between the lock screen, Control Centre and CarPlay. Two details are
particular to this app:

- The duration is the *estimate* while a chapter is still rendering, and the bar
  is drawn against it, so it settles rather than jumps as the real length becomes
  known. Dragging past what has been rendered lands at the rendered edge, because
  audio that does not exist has nowhere to seek to.
- The elapsed time is pushed at whole seconds and the rate is pushed as zero
  while paused. iOS counts forward from the last push using that rate, so a
  paused book that reported 1.5× would sit there ticking up.
- Pausing pauses the *engine*, not only the player node. A node-only pause leaves
  the engine running and the audio hardware live on silence, and the system reads
  its own idea of whether we are playing from the hardware rather than from
  anything published — so the lock screen sat one state behind, sending `play`
  while the book was already playing.

One trap, paid for once: MediaPlayer calls the artwork request handler on its own
queue, and a closure written inside a `@MainActor` method is *inferred* to be
isolated to the main actor. The runtime checks that on entry, so the app died with
`EXC_BREAKPOINT` inside `-[MPMediaItemArtwork jpegDataWithSize:]` the first time it
encoded a cover — every book with artwork, the moment playback started. Both the
artwork handler and the remote-command handlers are `@Sendable` for that reason,
which is what makes them nonisolated; the annotation is load-bearing, not decoration.

The end of a chapter is noticed by polling rather than by a completion handler.
Chunks are scheduled with no handler on purpose — one per chunk would fire on the
audio thread, mid-chapter, for every sentence — so the ticker that already reads
the playhead compares it against the end of the last scheduled segment. Rendering
finishing is not the same event: a part-rendered chapter streams out of the
renderer far faster than it can be listened to.
