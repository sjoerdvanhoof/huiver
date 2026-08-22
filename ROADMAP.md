# Roadmap

Where the v2 work stands: a two-device product — an iPhone that reads books
aloud, a Mac that will read them in 23 languages, and a direct link between
them with no server in the middle.

Status: the "Add native Mac app and iOS-Mac library sync" commit, plus the
uncommitted work in the tree — convert-offload, AAC on the wire, unattended
sync, and the multilingual groundwork. What each of those was checked against
is at the end, under **How this was checked**.

## Built

### The shared package
`packages/huiverkit` holds everything that is not a view; `apps/ios` and
`apps/mac` are thin SwiftUI shells that compile those sources directly (there is
no `import HuiverKit` — it is all one module per app). Core ML export tooling
moved to `tools/export`.

### Content identity
Two devices that import the same EPUB independently arrive at the same
`contentId` — a hash of the *extracted text*, not the file, because the phone
throws the EPUB away after extracting and the same book arrives as different
bytes from different sources. This is what sync addresses books by.
`Chunker.version` travels with it: audio is only interchangeable between devices
that agree where the chunk boundaries are.

### Listening state
Positions live in `Documents/progress.json`, not the library — a position moves
four times a second and the library is rewritten whole, text and all. Each
record is a position, a finished flag, and when it last changed, which is
exactly what two devices need to settle a disagreement. `finished` deliberately
outlives the audio it describes, so the cleanup sweep can delete a finished
chapter without it looking unheard.

Chapters auto-advance, which is also what makes the sleep timer's "end of
chapter" mean anything.

### Player
Read-along with chunk-level highlighting and tap-to-seek; sleep timer with a
fade; a queue screen; auto-cleanup of finished chapters after a week; persisted
render errors with a retry state; voice personas.

### Chunking (v5)
Chunks never end mid-sentence. Boundaries fall at paragraph ends where a
paragraph fits, sentence ends otherwise. A sentence is only broken past the
point the model would silently truncate it, and then at its own punctuation.

The ceiling is the **generation budget** — `SamplingOptions.maxTokens` — because
that is the only limit that loses words. It is deliberately *not* the mel
decoder's 768-token window: only vocoding is windowed, the speech tokens are one
continuous pass, and a chunk spanning two windows keeps unbroken prosody for the
cost of a 5 ms ramp. Splitting the sentence instead would restart the prosody
*and* insert a quarter-second of silence.

Windows that are crossed get run-up context and tail trimming, and every chunk
now ends at digital silence — which is what removed the audible click at chunk
joins and after a budget truncation.

### Mac app
`apps/mac` — library with EPUB import and drag-drop, book detail with
per-chapter and whole-book conversion, queue, voices with previews, settings,
a mini player for auditioning, and the Connector.

### Pairing and sync
Verified working between the two devices.

- **Pairing** — the Mac shows a QR holding a 32-byte secret with a two-minute
  expiry; the phone scans it and connects with TLS-PSK. Completing the handshake
  *is* the mutual authentication. Both sides then derive a long-term key (HKDF
  over both nonces) and keep it.
- **Transport** — Bonjour `_huiver._tcp` with `includePeerToPeer`, so it also
  works with no router between the devices. Length-prefixed frames; the protocol
  engine sits behind a `SyncTransport` seam and is tested over an in-memory pipe.
- **A session** — hello, both manifests, both diffs, transfers, goodbye. Books
  move both ways, audio Mac→phone, positions newest-wins. Everything is
  recomputed per session, which is why an interrupted transfer needs no resume
  logic: the next diff is simply smaller.
- **Storage** — iOS keeps pairings in the Keychain. **macOS keeps them in a file
  in the app container**, deliberately: see `PairingKeys.swift` for the four
  distinct silent failures that earned that decision.

193 tests, including an end-to-end `EngineTests` that renders real audio through
the Core ML models and a `NetworkSyncTests` that runs a whole session over real
sockets.

### Convert-offload
"Render this on the Mac" now exists on both ends of the wire that already
described it.

The phone writes the ask down in `Documents/convert-requests.json` and it
travels in every manifest until it is satisfied — so it can be made with the Mac
asleep, elsewhere, or not yet holding the book. `ConvertRequest.requestId` is
derived from `(textHash, voiceId)`, which is what lets the whole list be re-sent
every session without becoming a queue full of duplicates, and pruning happens
against the local library at manifest time: a chapter rendered in the asked-for
voice, wherever it was rendered, stops being asked for.

The Mac merges what arrives into the queue it already had. Two cases needed
deciding rather than coding around:

- **The book may not be here yet.** Requests are merged while the manifests are
  still being exchanged, which is before this session's transfers. One that
  names an unknown book is held and placed after the session, when the library
  has caught up — in memory only, because the phone re-sends it anyway.
- **The chapter may already be rendered in a different voice.** Re-rendering
  would throw away audio the Mac's own listener may be part-way through, so the
  ask is refused and reported as `failed` — the same rule the diff follows when
  it declines to take audio in a voice it did not ask for.

Job statuses come back as `jobStatus` messages, and the session now swallows
them anywhere between the manifests and the goodbye rather than only inside the
receive loop. That was not tidying: a phone with an empty want list never enters
that loop, and met a status where it expected a want.

### Audio on the wire
Audio crosses as AAC and is stored as WAV, which is the whole design. Measured,
not assumed:

- **One file per transfer, not per chunk.** An MPEG-4 container costs ~33 kB
  whatever it holds — more than a five-second chunk of speech compresses to. Per
  chunk it would make short chapters *larger*; per transfer it disappears.
- **MPEG-4 rather than raw ADTS.** This encoder delays its output by 2112
  samples. The container records that and the decoder gives back exactly what
  went in; ADTS does not, and every chunk would come back 88 ms late — a
  read-along drifting further out of step with each one.
- **The smaller of the two wins.** A transfer too small to amortise the
  container crosses uncompressed, which needs no threshold to tune.

Half a minute of speech is about a sixth of its WAV, and the chunk boundaries
survive: the decoded stream is cut back up by the sample counts that travelled
with it, and a chunk ends at digital silence anyway, so an AAC frame straddling
a boundary has nothing to smear.

Whether AAC is used at all is negotiated in the handshake — `Hello.audioCodecs`,
absent meaning WAV — so an older phone gets what it can read without a protocol
version bump.

### Sync that does not need watching
`SyncWatcher` keeps a Bonjour browser open and reports the *edge*: the moment a
Mac that was not there is. The phone syncs on that, at most once a minute, with
a setting in the Connector to turn it off. Level-triggered would mean a session
every time the browser reported anything at all.

Leaving the app mid-sync now holds a background assertion, so a transfer in
flight finishes instead of being cut off — and a `BGProcessingTask` asks for a
later slot, the same bargain the converter makes. **This is not background sync
and cannot be:** iOS has no background mode that runs an `NWConnection` on your
behalf, so what exists is a few seconds of grace plus whatever the system
volunteers while charging.

### Multilingual: the loop, pinned down
The first half of the large remaining piece, which was blocked on a 3 GB
download and is not any more.

`tools/export/probe_mtl.py` reads the architecture off the checkpoint rather
than off a config file — 30 LLaMA layers, 16 heads, 1024 wide, RoPE with
llama3 scaling *and* learned per-segment positions, a 34-token conditioning
prefix (speaker + 32 perceiver latents + emotion), speech vocab 8194.

`tools/export/mtl_reference.py` is a second implementation of the decode loop,
written the way Swift will have to write it: explicit cache, batch-2 guidance,
positions computed rather than tracked, and a sampler that is code rather than a
list of `LogitsProcessor` objects. `verify_mtl.py` puts it against chatterbox's
own at six levels — prompt, prefill, decoded tokens, sampler, backbone, export
modules — and all six agree. Two details it pinned down that a port would
otherwise have got wrong:

- **The prompt ends with two start-of-speech tokens**, both at learned position
  zero. It looks like a slip upstream and it is what the weights were trained
  against.
- **The unconditional branch keeps its positions.** CFG zeroes the text *token*
  embeddings and then adds the learned positions to both rows, so uncond is
  position without content. Zeroing after the addition is a different model.

`mtl_backbone.py` is the forward pass the export traces, agreeing with
`transformers` to 4e-05, and `mtl_t3_export.py` is the pair of modules that
become Core ML packages — prompt assembled from pieces, a state-backed cache,
and guidance folded in before the logits leave the model. Both check out against
the reference loop.

**Both convert, and both are right.** `MTLT3Prefill` and `MTLT3Decode` are 1.06
and 1.05 GB at float16; prefill logits correlate at 1.000000 with torch and
eight greedy tokens come out identical. The batch-2 stateful decode — the part
this roadmap expected to force a shape compromise — converted in 23 seconds and
needed none.

One thing did bite, and it is worth knowing before the Swift side meets it:
**the prefill must not be compiled for the Neural Engine.** A flexible text
dimension over thirty layers takes a 16 GB machine down at *load* time, with no
exception thrown — the process simply ends. Loading it as `cpuAndGPU` fixes it,
costs nothing (prefill runs once per chunk on an otherwise idle GPU), and the
package now carries `computeUnits` in its metadata so the port does not have to
rediscover it. The decode package keeps the engine.

One number worth having early: the decode cache is 2 rows x 30 layers x 16 heads
x 1356 positions x 64 dims, twice, at float16 — **333 MB**. Nano's pair is 62 MB.
That is guidance being mandatory, and it is another reason this model belongs on
the Mac.

### Multilingual: tokens to audio
`mtl_s3_export.py` is the mel decoder and the vocoder, and it is mostly Nano's
`s3_export.py` — the encoder, the projection and the estimator are the
checkpoint's own modules, and `HiFTGenerator` is literally the same class, so
Nano's vocoder exporter is reused rather than rewritten.

The solver is the part that is new, and it is guidance again: **ten Euler steps
on a cosine schedule, each running the estimator on a batch of two** — the
conditional row against `mu`, the speaker and the reference mel, the other with
those three zeroed — combined as `(1 + 0.7)·cond − 0.7·uncond`. Twenty estimator
passes per window, against Nano's two. Written out, it reproduces
`flow.inference` **exactly**: max abs error 0.000e+00 in float32.

Converted, at a 50-token window for the parity run: `MTLS3Flow` 230 MB, mel
correlating 0.999980 with torch, and `MTLS3Vocoder` 43 MB producing a waveform
of the right length at 1.015× the reference's RMS — loose on purpose, because
the reference draws its own excitation noise where nothing can seed it.

The vocoder is another package that must stay off the Neural Engine, for a
different reason than the prefill: the ANE compiler simply fails on it
(`ANECCompile() FAILED`), and Core ML falls back on its own — correctly, after
wasting the compile and logging something that reads like a crash.

## Not built

### Chatterbox Multilingual: the rest of it
**Superseded — see "Done since: the token loop on MLX" below.** The Swift
port, shipping-size exports, multilingual voices and int8 quantisation all
exist now; this section is kept as the record of what the plan looked like
before they did.

- **The models are exported at parity sizes, not shipping ones.** The flow was
  traced at a 50-token window against the built-in voice's 157-token prompt,
  because that is what could be checked against torch today. Shipping wants
  Nano's convention — a 768-token window and a reference clip trimmed to ten
  seconds, so 250 — and the estimator's cost at that size has not been measured.
- **There are no multilingual voices.** `export_voices.py` clones through the
  Nano checkpoint. The multilingual one has its own voice encoder and s3
  tokenizer, and the ten LibriVox narrators need re-cloning through them.
- **Nothing is written in Swift.** `MTLTokenizer`, the guided decode loop, the
  cache hand-off, the CFM solver. `ChatterboxEngine` already drives a windowed
  decode, so the shape exists — but every number it hardcodes is Nano's, and two
  packages have to be loaded away from the Neural Engine.
- **Quantisation is untried.** About 1.06 GB per package at float16, and there
  are two of them holding the same weights. Nano's export takes
  `--quantize int8`; this one does not yet. On a Mac it matters less than it
  does on a phone, but 2.1 GB of models is still 2.1 GB.

### Sync follow-ups
- **The Mac still cannot be told to convert from the phone in bulk.** One
  chapter at a time is what the UI offers; "convert this book on the Mac" is a
  loop nobody has written.
- **A `jobStatus` is only as fresh as the last session.** The Mac does not push
  progress while it renders — there is no connection open to push it down — so a
  phone watching the queue screen sees the state from when it last connected.
  Live progress needs the session to stay open, which is a different shape of
  connection than "diff, transfer, goodbye".

### Other
- ~~Voice recording on the Mac is still a disabled placeholder~~ — **done**:
  `RecordVoiceSheet` records, `MTLVoiceCloner` clones on-device, and the voice
  lands in the roster (commit "Add on-device Mac voice recording and cloning").
- `legacy/web` is still present. Its venv is not: the Chatterbox environment now
  lives in `tools/export/.venv-chatterbox`, which was the one ordering
  constraint on retiring the web app, and `HUIVER_CHATTERBOX_VENV` points the
  web app at it meanwhile.

## What happens next

The ordering argument that opened this roadmap has largely played out. The item
that could have failed on something outside our control — a checkpoint that
would not convert — did not: the loop matches at every level, and the batch-2
stateful decode converts in 23 seconds. What is left is long rather than
uncertain.

### 1. Finish the multilingual model

**Shipping-size exports and voices first.** Both are mechanical now that every
piece is measured: retrace the flow at a 768-token window with a 250-token
prompt, re-clone the ten narrators through the multilingual voice encoder, and
re-run `verify_mtl.py --models`. What is worth watching is the estimator's cost
at that window — twenty passes over 2036 mel frames is the number that decides
whether a chapter converts in minutes or in hours.

**Then Swift**, where `MTLTokenizer` and the languages key really are the small
part. What is not small: the decode loop carries a 333 MB state, guidance is
folded into the model rather than the sampler, and the sampler order differs
from Nano's — all three are written down in `mtl_reference.py` precisely so the
port has something to be checked against rather than something to be inferred.

**Done means** `EngineTests` renders real audio through the multilingual models
in a non-English language, and `verify_mtl.py --models …` passes every level at
shipping sizes.

### 2. Voice recording on the Mac, then retire `legacy/web`

Unchanged from before, minus the constraint that used to gate it: the venv has
moved, so `legacy/web` can go to `legacy/` the moment the Mac can record a
reference clip and clone from it.

### 3. Sync, when it has something to carry

Bulk offload and live job progress are both worth more once the Mac has a model
the phone does not — a book converted into Dutch is a reason to select a whole
shelf and walk away. Doing them now would be building a lever with nothing on
the other end.

## How this was checked

- **HuiverKit**: `swift test` — 193 tests, all passing. That includes
  `EngineTests`, which renders real audio through the Core ML models (2.16 s of
  speech in 60 s), and a new `NetworkSyncTests` that runs a whole session over
  real sockets: Bonjour discovery, the TLS-PSK handshake, `NWSyncTransport`'s
  framing, a book each way, audio compressed to a seventh of its size and
  landing as WAV at the same sample count, and a convert-offload ask that comes
  back answered. The pipe tests cover the protocol; that one covers everything
  under it.
- **Both apps build.** iOS Debug for the simulator *and* Release for arm64
  device — the second matters because a Release-only compile error would
  otherwise surface for the first time during an install. The Mac app builds and
  launches, loading 412 MB of compiled models.
- **The iOS app runs in the simulator.** Core ML itself cannot: the simulator
  has no MPSGraph backend, so the models fail to load and the app says so on its
  preparing screen instead of crashing, which is what it is written to do. What
  that run did confirm is the new request store surviving a real launch — a
  seeded ask naming a book the library does not have was pruned and the file
  rewritten, exactly as `ConvertRequestTests` says it should be.
- **The multilingual work**: `verify_mtl.py`, seven levels, all passing against
  the real checkpoint — including all four converted Core ML packages, which
  predict the same eight tokens as torch and produce a waveform from them.
- **Nothing has been installed on the phone.** Two things block it, both
  outside the code: no iPhone is connected, and Xcode has no Apple ID signed in,
  so `-allowProvisioningUpdates` has no team to provision with. `bun run
  ios:device` is the last step and it has not run.

## Done since: the token loop on MLX

The multilingual T3 no longer runs through Core ML on the Mac. Measured on the
M4 mini, the Core ML loop had two costs that no export flag was going to fix:
each decode `prediction()` was ~56 ms for 40 ms of audio, and the prefill's
flexible text dimension made Core ML re-specialize for *every text length it
had not seen* — 5.6 s for a 265-token chunk, and every chunk's length is novel.

So `MTLDecodeMLX` runs the thirty layers on MLX instead: the decode step as a
single compiled graph against a preallocated KV cache (~15 ms/token at int8),
and the prefill as one flexible-length pass (~0.25 s, any length). The
conditioning encoder — the perceiver, the one piece that is not backbone
weights — stays in Core ML as `MTLCond`, fixed shapes, once per chunk. So do
the mel decoder and the vocoder. The sampler stays in Swift, unchanged.

The MLX loop is the *only* multilingual T3 now. The Core ML prefill/decode
pair it replaced is no longer installed at all — a gigabyte the engine would
never load — and a missing backbone is a broken install said out loud
(`EngineError.backboneRequired`), not something to fall back from. The pair
still exists as verification tooling: `bun run mac:models` exports it to
build-mtl, and `MTLMLXParityTests` — which seeds both decoders from the same
prefill output and walks them greedily; 47/48 argmax agreement, 0.09 worst
top-band logit drift, fp16 rounding — runs whenever the two are compiled
beside the backbone, and is disabled rather than failed when they are not.
`bun run mac:backbone` exports the MLX weights (int8 by default, the same
quantisation the Core ML decode shipped with). Nano's Core ML prefill/decode
path is untouched; the phone knows nothing of any of this.

**The mel decoder's window is right-sized too.** A window's cost is paid in
full however little of it is used — twenty estimator passes over every mel
frame, rendered silence included — and a typical ~390-token chunk was paying
for 768. `bun run mac:models` now traces the flow+vocoder pair at 768, 512 and
256 (one traced graph per size; the conformer bakes its padding masks in at
trace time, so a single flexible package cannot exist), the install ships all
of them, and `decodeWindow` picks the smallest installed window that fits.
Fixed shapes mean each size pays Core ML's specialisation once per process,
not per length. Measured: the S3 half of the typical chunk fell from 5.9 s to
3.6 s.

Where that leaves the measured chunk (363 chars, 15.5 s of audio): 29.4 s of
compute before any of this, **11.3 s now — 1.35× realtime**, or 0.7 h of
compute per hour of audio against the original 1.9 h. The two blocks left are
roughly equal now: ~7.5 s of token loop (of which ~1.5 s is the debug-build
sampler; Release is thinner) and ~3.6 s of mel decoding, so the next levers,
if ever wanted, are int4 decode weights (measured 12.9 ms/step against int8's
15.4, at a real quality cost that wants listening first) and overlapping chunk
N's mel decode under chunk N+1's token loop.

## Deliberately not planned

- **A server, an account, or a cloud anything.** The whole shape of sync —
  content-addressed books, per-session diffs, no resume logic — falls out of
  there being two devices and no third party. That is the product, not a stage
  it is passing through.
- **Resume for interrupted transfers.** The next diff is simply smaller. Adding
  resume would mean persisting partial state that the recompute-per-session
  model exists to avoid.
- **Storing audio as AAC.** It crosses compressed and lands as WAV, and the
  measurements above are why: per-chunk containers cost more than they save, and
  per-chunk encoder priming is the click the chunker spent v5 removing.
- **Android, or reviving `legacy/mobile`.** Nano runs through Core ML.
- **Nano on the Mac or multilingual on the phone.** Nine times the arithmetic
  per token and a 333 MB decode cache is the reason there are two models; a
  device that can run both is a device that will be asked to.

## Done since: the top-notch pass

One sweep over both apps and the engine, in four layers.

**Bugs.** The Mac now holds a power assertion while converting (idle sleep was
ending overnight renders), recovers playback when the output device changes,
finishes its lazy writes before ⌘Q (`applicationShouldTerminate` →
`terminateLater`), guards `AppModel.load()` against ⌘N re-entry, and picks a
book's voice from the *current* book after a language change. The phone loads
synced voices (the two-directory `VoicePack.load`, filtered by
`engine.canRead` so a multilingual voice cannot be picked as Nano's narrator),
surfaces a refused Keychain save instead of showing a pairing that would
evaporate, and stopped clobbering the narrator's audio session from the voice
previews. Both apps persist playback rate and sampling options, separate
import failures from engine failures, refuse duplicate imports by content
identity, and confirm a voice change that would invalidate rendered chapters.
Received sync voices are now also written into `voices.json` — before, a
synced blob was invisible to `load` *and* re-requested by every later session.
The renderer's quarter-second pause respects `endsMidSentence`: a force-split
sentence gets a breath, not a hole.

**Speed.** The two halves of a chunk's cost no longer run in series:
`ChapterRenderer` decodes chunk N's mel off the engine actor (`S3Stack`,
snapshotted models) while chunk N+1's token loop holds it — the ROADMAP's own
named lever. The sampler's min-p-only path (the multilingual preset) replaced
a per-token full-vocabulary sort with a max scan, and `MTLCond` is memoised
per (voice, expression) instead of re-predicted per chunk. `splitToFit` splits
at the sentence or clause nearest the middle rather than the midpoint word —
chunk boundaries on disk are untouched, so audio stays interchangeable.
Deliberately skipped: caching the conditioning prefix's KV inside the MLX
prefill (~30 ms/chunk against re-verifying a parity-pinned forward pass) and
int4 decode weights (wants a listening test first).

**Export.** `AudiobookExporter` writes a chapter-marked `.m4b` per book — AAC
via `AVAssetWriter`, a hand-assembled `tx3g` chapter track associated as the
audio track's chapter list, cover art and tags — and tagged per-chapter
`.m4a`s. The Mac gets save panels (entitlement now user-selected read-write);
the phone gets the share sheet on books and rendered chapters.

**Platform.** Now Playing and the media keys work on the Mac (the `#if
os(iOS)` bodies were the only thing in the way), space toggles playback in the
player, File ▸ Open ⌘O imports, ⌘, opens Settings, the Dock badges the queue
and a notification fires when it drains (both platforms). Libraries got
search, sort (Mac) and a Continue Listening row; players got a chapter list
and a measured "~n min to convert" estimate (`RenderPace`, blended from real
chunk timings); skip intervals are configurable and defined once
(`SkipIntervals`). Read-along respects Reduce Motion, has a text-size control
and can be hidden (Mac). The scrubbers are VoiceOver-adjustable, the transport
is labelled, and the iOS scrubber bumps when a drag hits the rendered edge.
The iOS target is iPhone-only until it has a real iPad layout. The phone can
ask the Mac for a whole book ("Convert book on the Mac"), both Settings
screens can copy the playback log, and the last sync time survives relaunch.

Still open from this pass: parity coverage for `MTLCond` and the 512/256 mel
windows, engine-level tests for `splitToFit`/`reload()` reentrancy (both need
installed models), a proper first-run screen for a Mac without models, and
per-book voice pinning on the phone (the Mac has it).
