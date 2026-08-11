
Default to using Bun instead of Node.js.

- Use `bun <file>` instead of `node <file>` or `ts-node <file>`
- Use `bun test` instead of `jest` or `vitest`
- Use `bun build <file.html|file.ts|file.css>` instead of `webpack` or `esbuild`
- Use `bun install` instead of `npm install` or `yarn install` or `pnpm install`
- Use `bun run <script>` instead of `npm run <script>` or `yarn run <script>` or `pnpm run <script>`
- Use `bunx <package> <command>` instead of `npx <package> <command>`
- Bun automatically loads .env, so don't use dotenv.

## APIs

- `Bun.serve()` supports WebSockets, HTTPS, and routes. Don't use `express`.
- `bun:sqlite` for SQLite. Don't use `better-sqlite3`.
- `Bun.redis` for Redis. Don't use `ioredis`.
- `Bun.sql` for Postgres. Don't use `pg` or `postgres.js`.
- `WebSocket` is built-in. Don't use `ws`.
- Prefer `Bun.file` over `node:fs`'s readFile/writeFile
- Bun.$`ls` instead of execa.

## Testing

Use `bun test` to run tests.

```ts#index.test.ts
import { test, expect } from "bun:test";

test("hello world", () => {
  expect(1).toBe(1);
});
```

## Dev server
I will always run the dev server myself. Don't spin up your own one in the background.

## Github
I will always commit and push myself to github. Don't do this yourself.

## Python environment
Please always use the virtual env. to run your python apps. If there is no virtual python env. yet, please make one with latest stable python version.

## iOS app (apps/ios)

After every change under `apps/ios`, build the app target:

```
xcodebuild -project apps/ios/Huiver.xcodeproj -scheme Huiver -sdk iphonesimulator \
  -configuration Debug -arch arm64 CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/huiver-xcbuild build
```

`swift build` in `apps/ios` only compiles HuiverKit for the Mac, so on its own it
misses every `#if os(iOS)` branch. Keep `-derivedDataPath` outside the repo:
without it xcodebuild writes into `apps/ios/build/`, where the exported
`.mlpackage` models live.

`swift test` covers the logic, but `EngineTests` compiles the Core ML models and
takes about eight minutes — run it in the background, or `--skip EngineTests` for
a quick pass.

### Getting it onto my iPhone

When you are done making changes, deploy it:

```
bun run ios:install && bun run ios:device
```

`ios:install` copies the models and voices into the app folder, `ios:device` builds
Release and installs over USB. `ios:device` builds **Release** while the check above
builds Debug, so a Release-only compile error will not show up until this runs.

Add `bun run ios:previews` in front only when the voices themselves changed — it
re-renders all 11 samples through the model and is most of the wall clock.

Run it yourself rather than asking me to — a change is not on my phone until it
has. It needs the iPhone plugged in and unlocked; say so if that is why it failed.
It takes a few minutes, so start it in the background.

If the app then crashes on the phone, read the crash report rather than guessing:

```
xcrun devicectl list devices
xcrun devicectl device info files --device <id> --domain-type systemCrashLogs
xcrun devicectl device copy from --device <id> --domain-type systemCrashLogs \
  --source Huiver-<stamp>.ips --destination /tmp/crash.ips
```

An `.ips` is a one-line JSON header followed by a JSON body; the frames in
`threads[faultingThread]` already carry Swift symbol names.


