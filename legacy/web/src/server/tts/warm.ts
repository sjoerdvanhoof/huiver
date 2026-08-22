import { getProvider } from "./index";
import type { TTSSession } from "./types";

/**
 * Loading Kokoro costs ~5-10s, which is fine once per conversion job but awful
 * for voice previews and live playback. Keep one session per provider alive
 * between requests and retire it once nobody has used it for a while.
 */
const IDLE_MS = 5 * 60_000;

type Entry = { session: TTSSession; refs: number; timer?: ReturnType<typeof setTimeout> };

const warm = new Map<string, Entry>();
const opening = new Map<string, Promise<TTSSession>>();

export async function acquireWarmSession(providerId: string): Promise<TTSSession> {
  const existing = warm.get(providerId);
  if (existing) {
    clearTimeout(existing.timer);
    existing.refs++;
    return existing.session;
  }

  // Two requests arriving together must not each spawn a worker.
  let pending = opening.get(providerId);
  if (!pending) {
    pending = getProvider(providerId).open();
    opening.set(providerId, pending);
    pending.finally(() => opening.delete(providerId));
  }

  const session = await pending;
  const entry = warm.get(providerId);
  if (entry) {
    clearTimeout(entry.timer);
    entry.refs++;
    return entry.session;
  }

  warm.set(providerId, { session, refs: 1 });
  return session;
}

/**
 * @param discard drop the session instead of keeping it warm — use when the
 * session may be in a bad state (aborted stream, worker error).
 */
export function releaseWarmSession(providerId: string, discard = false) {
  const entry = warm.get(providerId);
  if (!entry) return;

  entry.refs = Math.max(0, entry.refs - 1);

  if (discard) {
    warm.delete(providerId);
    if (entry.refs === 0) void entry.session.close().catch(() => {});
    return;
  }

  if (entry.refs === 0) {
    entry.timer = setTimeout(() => {
      warm.delete(providerId);
      void entry.session.close().catch(() => {});
    }, IDLE_MS);
  }
}

export async function closeWarmSessions() {
  const entries = [...warm.values()];
  warm.clear();
  for (const entry of entries) {
    clearTimeout(entry.timer);
    await entry.session.close().catch(() => {});
  }
}

// `bun --hot` replaces this module without ending the process, which would
// strand the worker we spawned (its stdin stays open, so it never sees EOF).
// The worker has its own idle watchdog as a backstop, but reap it promptly.
if (import.meta.hot) {
  import.meta.hot.dispose(() => void closeWarmSessions());
}

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void closeWarmSessions().finally(() => process.exit(0));
  });
}
