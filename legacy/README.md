# Legacy

Code that is kept but no longer worked on. The two apps under active development are
`apps/web` and `apps/ios`.

## `legacy/mobile` — the Expo app

A standalone Expo app for iOS and Android, running Kokoro on the device through
`react-native-sherpa-onnx`. Retired on 15 August 2026 in favour of `apps/ios`, which
is native Swift and runs Chatterbox Nano on Core ML — cloned voices being the thing
the Expo app could never do (see "Not in the Expo app" in the root README).

It worked when it was parked. Nothing here is broken; it is simply not being carried
forward, and it will rot as its dependencies age.

**It is not in the Bun workspace.** `package.json` globs `apps/*` and `packages/*`, so
moving it here took it out of `bun install` and out of `bun run test` and
`bun run typecheck`. Its `mobile:*` scripts are gone from the root `package.json` too.

`bun.lock` still carries its dependencies, because nothing has re-resolved since the
move. The next `bun install` prunes them, and there is no hurry either way.

To bring it back to life:

1. Add `"legacy/*"` to `workspaces` in the root `package.json`.
2. `bun install` — this pulls React Native and Expo back in.
3. `bun run --cwd legacy/mobile prebuild`, then the steps below.

The rest of this file is the documentation as it stood when the app was retired, with
paths updated. `bun run mobile:*` shortcuts have become
`bun run --cwd legacy/mobile <script>`.

---

## Mobile app

`legacy/mobile` is a standalone Expo app: it imports EPUBs on the phone, splits them
into chapters with the same extractor the server uses, and renders them with Kokoro
running on the device. There is no server involved and no network after the model is
downloaded.

### Building it

On-device speech is a native module, so Expo Go will not do — you need a development
build. Install Xcode itself (the command line tools alone are not enough), with the
iOS platform component; watchOS, tvOS and visionOS are not needed. Then point the
tooling at it:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

```bash
bun install
bun run --cwd legacy/mobile prebuild        # regenerates ios/ and android/; both are gitignored
```

Use that script rather than `bunx expo prebuild` directly: CocoaPods crashes with
`Unicode Normalization not appropriate for ASCII-8BIT` when `LANG` is unset, which it
is by default on a fresh macOS shell, and the script sets it. If you would rather fix
it once for every project, put this in your shell profile instead:

```bash
export LANG=en_US.UTF-8
```

Prebuild runs `pod install`, which downloads the sherpa-onnx xcframework (~185 MB) and
compiles libarchive — a few minutes the first time. Then open
`legacy/mobile/ios/huiver.xcworkspace` in Xcode, pick your team under *Signing &
Capabilities*, and run it on your iPhone. A free Apple ID works; the build expires
after seven days and you re-run it.

Or skip Xcode's UI once the signing team is set. For the phone, name the device
explicitly — a bare `--device` opens a picker that lists simulators alongside phones,
and iOS reuses the same device name across your old and new handsets, so the UDID is
the only unambiguous answer:

```bash
xcodebuild -workspace legacy/mobile/ios/huiver.xcworkspace -scheme huiver \
  -showdestinations | grep "platform:iOS," | grep -v Simulator

bun run --cwd legacy/mobile ios:device <id-from-that-listing>
```

Build **Release** for the phone, which that script does. A Debug build leaves the JS
on the Mac's Metro server, so the phone has to stay on the same Wi-Fi — no use for
testing background audio or the lock screen while walking around.

Simulator: `bun run --cwd legacy/mobile ios`. Android: `bun run --cwd legacy/mobile android`. Day-to-day,
`bun run --cwd legacy/mobile start` starts the Metro dev server against an installed Debug build.

`ios/` and `android/` are generated, not committed: everything native comes from
`app.config.ts` and `plugins/`, so a prebuild always reproduces them. If pods ever
drift without a full regeneration, `bun run --cwd legacy/mobile pods` reinstalls them.

### The voice model

Kokoro is downloaded on first use from settings — `kokoro-multi-lang-v1_0`, about
350 MB, unpacked to roughly 400 MB. It carries the same 21 English voices the desktop
app offers, at the same ids, so a book sounds the same whichever huiver read it. An
interrupted download resumes rather than starting over.

The fp32 model is used deliberately: the int8 build is a third of the size but runs
about twice as slow on Apple silicon, and barely saves memory. Expect roughly 800 MB
of RAM while a chapter is being rendered.

### Converting and listening

The controls match the web app's: convert a chapter and it renders in the background,
or just press play on an unconverted one and listen while it is written.

Live playback works differently from the web's, because iOS cannot seek an open-ended
HTTP stream. Each chunk is rendered to its own small WAV, and the player walks them as
they land, so seeking backwards inside what has been rendered is exact rather than a
re-request. The scrubber dims the part that does not exist yet. When the chapter
finishes the chunks are stitched into one file and it becomes an ordinary track.

Those chunk files are also the checkpoint: a render interrupted anywhere leaves a
prefix, and pressing convert again continues from it. As on the server, a prefix is
only reused when the work is identical — same text, same voice, same chunking.

**Backgrounding.** iOS suspends an app a few seconds after it leaves the screen unless
audio is playing. So synthesis keeps running in the background while you are listening,
and pauses when you background the app with nothing playing — picking up from the
checkpoint when you come back. The app says as much rather than pretending otherwise.

**Storage.** There is no ffmpeg on the phone, so chapters stay as 24 kHz 16-bit WAV:
about 173 MB per hour, against roughly 29 MB per hour for the desktop app's 64 kbps
MP3. A ten-hour book is therefore around 1.7 GB. Deleting a book removes its audio.

### How it maps to the web app

| Web | Mobile |
| --- | --- |
| `Bun.serve` + REST | nothing — the screens read SQLite directly |
| `bun:sqlite` in `data/` | `expo-sqlite`, same table shapes minus the job queue |
| Python Kokoro subprocess | `react-native-sherpa-onnx` (ONNX Runtime) in-process |
| Chatterbox Nano cloned voices | not here — it is the whole point of [`apps/ios`](#ios-app) |
| `<audio>` + Media Session | `expo-audio` + its lock-screen controls |
| chunked MP3 stream | per-chunk WAV files the player walks |
| Tailwind + shadcn | `StyleSheet` over the same tokens, in `src/theme/tokens.ts` |

