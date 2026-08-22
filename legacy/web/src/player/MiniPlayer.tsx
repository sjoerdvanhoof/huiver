import { Loader2, Pause, Play, RotateCcw, SkipForward } from "lucide-react";
import { BookCover } from "@/components/BookCover";
import { formatDuration } from "@huiver/shared";
import { next, seekBy, setExpanded, toggle, usePlayer } from "./store";

/**
 * Docked bottom bar, visible on every page while something is loaded.
 * Tapping anywhere except the transport buttons expands the full player.
 */
export function MiniPlayer() {
  const item = usePlayer(s => s.queue[s.index] ?? null);
  const status = usePlayer(s => s.status);
  const position = usePlayer(s => s.position);
  const duration = usePlayer(s => s.duration);

  if (!item) return null;

  const fraction = duration && duration > 0 ? Math.min(1, position / duration) : 0;
  const live = item.source.kind === "live";
  const playing = status === "playing" || status === "loading";

  return (
    <div className="fixed inset-x-0 bottom-0 z-40 border-t bg-background/85 pb-[env(safe-area-inset-bottom)] backdrop-blur-md">
      {/* Progress hairline along the top edge. */}
      <div className="absolute inset-x-0 top-0 h-0.5 bg-muted">
        {live && playing ? (
          <div className="h-full w-full animate-shimmer" />
        ) : (
          <div className="h-full bg-primary" style={{ width: `${fraction * 100}%` }} />
        )}
      </div>

      <div
        role="button"
        tabIndex={0}
        aria-label="Open player"
        onClick={() => setExpanded(true)}
        onKeyDown={e => {
          if (e.key === "Enter") setExpanded(true);
        }}
        className="mx-auto flex h-16 max-w-6xl cursor-pointer items-center gap-3 px-4 sm:px-6"
      >
        <BookCover bookId={item.bookId} title={item.bookTitle} coverUrl={item.coverUrl} className="h-11 w-8" />

        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium">{item.chapterTitle}</p>
          <p className="truncate text-xs text-muted-foreground">
            {item.bookTitle}
            {live && playing && <span className="ml-2 text-primary">● live</span>}
            {!live && duration != null && (
              <span className="ml-2 tabular-nums">
                {formatDuration(position)} / {formatDuration(duration)}
              </span>
            )}
          </p>
        </div>

        <div className="flex shrink-0 items-center gap-1" onClick={e => e.stopPropagation()}>
          <button
            onClick={() => seekBy(-15)}
            disabled={live}
            aria-label="Back 15 seconds"
            className="hidden rounded-full p-2 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground disabled:opacity-30 sm:block"
          >
            <RotateCcw className="size-5" />
          </button>

          <button
            onClick={toggle}
            aria-label={playing ? "Pause" : "Play"}
            className="flex size-10 items-center justify-center rounded-full bg-primary text-primary-foreground shadow-sm transition-transform active:scale-95"
          >
            {status === "loading" ? (
              <Loader2 className="size-5 animate-spin" />
            ) : playing ? (
              <Pause className="size-5" />
            ) : (
              <Play className="size-5 translate-x-px" />
            )}
          </button>

          <button
            onClick={next}
            aria-label="Next chapter"
            className="rounded-full p-2 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
          >
            <SkipForward className="size-5" />
          </button>
        </div>
      </div>
    </div>
  );
}
