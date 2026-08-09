import { Loader2, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { cancelJob, isActiveJob, cancelTrack, queueEntries, useJobs } from "../hooks/useJobs";
import { navigate } from "../hooks/useHashRoute";

/**
 * Conversions run in the background, so the app bar carries the only global
 * sign of one. Clicking opens the queue: what is rendering, what is waiting,
 * and a way to drop any of it.
 */
export function ConversionIndicator() {
  const { jobs } = useJobs();
  const [open, setOpen] = useState(false);
  const wrapper = useRef<HTMLDivElement>(null);

  const active = useMemo(() => jobs.filter(isActiveJob), [jobs]);
  const queue = useMemo(() => queueEntries(jobs), [jobs]);

  // Close on outside click or Escape, like any other menu.
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!wrapper.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  // Nothing left to show once the queue drains.
  useEffect(() => {
    if (active.length === 0) setOpen(false);
  }, [active.length]);

  if (active.length === 0) return null;

  const done = active.reduce((sum, j) => sum + j.chunksDone, 0);
  const total = active.reduce((sum, j) => sum + j.chunksTotal, 0);
  const percent = total > 0 ? Math.round((done / total) * 100) : 0;
  const books = new Set(active.map(j => j.bookId));
  const label = books.size > 1 ? `Converting ${books.size} books` : `Converting ${active[0]!.bookTitle}`;

  return (
    <div ref={wrapper} className="relative">
      <button
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        aria-haspopup="dialog"
        aria-label={`${label}, ${percent} percent. Show the conversion queue.`}
        title={`${label} — ${percent}%`}
        className={`flex items-center gap-2 rounded-full border px-2.5 py-1 text-xs transition-colors hover:bg-accent hover:text-foreground ${
          open ? "bg-accent text-foreground" : "text-muted-foreground"
        }`}
      >
        <Loader2 className="size-3.5 shrink-0 animate-spin text-primary" />
        <span className="hidden max-w-40 truncate sm:inline">{label}</span>
        <span className="tabular-nums">{percent}%</span>
      </button>

      {open && (
        <div
          role="dialog"
          aria-label="Conversion queue"
          className="absolute right-0 top-full z-50 mt-2 w-[min(22rem,calc(100vw-2rem))] overflow-hidden rounded-xl border bg-popover shadow-xl"
        >
          <div className="flex items-center justify-between gap-2 border-b px-3 py-2">
            <div className="min-w-0">
              <p className="text-sm font-semibold">Conversion queue</p>
              <p className="text-xs text-muted-foreground">
                {queue.length} chapter{queue.length === 1 ? "" : "s"} left · {percent}% overall
              </p>
            </div>
            <button
              onClick={() => void Promise.all(active.map(job => cancelJob(job.id)))}
              className="shrink-0 rounded-md px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
            >
              Stop all
            </button>
          </div>

          <ul className="max-h-80 divide-y overflow-y-auto">
            {queue.map(entry => (
              <li key={entry.trackId} className="flex items-center gap-2.5 px-3 py-2">
                <span className="w-8 shrink-0 text-center text-[11px] tabular-nums text-muted-foreground">
                  {entry.running ? (
                    entry.progress !== null ? (
                      `${Math.round(entry.progress * 100)}%`
                    ) : (
                      <Loader2 className="mx-auto size-3.5 animate-spin text-primary" />
                    )
                  ) : (
                    "—"
                  )}
                </span>

                <button
                  onClick={() => {
                    setOpen(false);
                    navigate({ name: "book", id: entry.bookId });
                  }}
                  className="min-w-0 flex-1 text-left"
                  title={`${entry.chapterTitle} — ${entry.bookTitle}`}
                >
                  <p className={`truncate text-sm ${entry.running ? "font-medium" : ""}`}>
                    {entry.chapterTitle}
                  </p>
                  <p className="truncate text-xs text-muted-foreground">{entry.bookTitle}</p>
                  {entry.running && (
                    <div className="mt-1 h-0.5 overflow-hidden rounded-full bg-muted">
                      <div
                        className="h-full bg-primary transition-all"
                        style={{ width: `${(entry.progress ?? 0) * 100}%` }}
                      />
                    </div>
                  )}
                </button>

                <button
                  onClick={() => void cancelTrack(entry.trackId)}
                  aria-label={`Remove ${entry.chapterTitle} from the queue`}
                  title="Remove from queue"
                  className="shrink-0 rounded-full p-1.5 text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
                >
                  <X className="size-4" />
                </button>
              </li>
            ))}

            {queue.length === 0 && (
              <li className="px-3 py-4 text-center text-xs text-muted-foreground">Finishing up…</li>
            )}
          </ul>
        </div>
      )}
    </div>
  );
}
