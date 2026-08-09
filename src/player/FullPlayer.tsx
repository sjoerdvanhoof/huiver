import {
  ChevronDown,
  Gauge,
  ListOrdered,
  Loader2,
  Moon,
  Pause,
  Play,
  RotateCcw,
  RotateCw,
  SkipBack,
  SkipForward,
} from "lucide-react";
import { useEffect, useState } from "react";
import { BookCover } from "@/components/BookCover";
import { Slider } from "@/components/ui/slider";
import { formatDuration, formatEstimate } from "@/lib/format";
import { navigate } from "../hooks/useHashRoute";
import {
  cycleRate,
  cycleSleep,
  next,
  previous,
  seekBy,
  seekTo,
  setExpanded,
  toggle,
  usePlayer,
} from "./store";

/**
 * The expanded player: a full-screen sheet on phones, a centered card on
 * desktop. One component, styled responsively.
 */
export function FullPlayer() {
  const expanded = usePlayer(s => s.expanded);
  const item = usePlayer(s => s.queue[s.index] ?? null);
  const status = usePlayer(s => s.status);
  const position = usePlayer(s => s.position);
  const duration = usePlayer(s => s.duration);
  const rate = usePlayer(s => s.rate);
  const sleep = usePlayer(s => s.sleep);
  const queueLength = usePlayer(s => s.queue.length);
  const index = usePlayer(s => s.index);

  // While dragging, the thumb follows the finger instead of the audio clock.
  const [scrub, setScrub] = useState<number | null>(null);

  useEffect(() => {
    if (!expanded) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setExpanded(false);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [expanded]);

  if (!expanded || !item) return null;

  const live = item.source.kind === "live";
  const playing = status === "playing" || status === "loading";
  const shownPosition = scrub ?? position;
  const remaining = duration != null ? Math.max(0, duration - shownPosition) : null;

  const sleepLabel =
    sleep === null ? null : sleep.kind === "chapter" ? "End of chapter" : `${sleep.minutes} min`;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center">
      <div
        className="absolute inset-0 bg-black/50 backdrop-blur-sm"
        onClick={() => setExpanded(false)}
        aria-hidden
      />

      <div
        role="dialog"
        aria-modal="true"
        aria-label="Audio player"
        className="relative flex h-dvh w-full flex-col bg-background px-6 pb-[max(1.5rem,env(safe-area-inset-bottom))] pt-[max(1rem,env(safe-area-inset-top))] duration-300 animate-in slide-in-from-bottom sm:h-auto sm:max-w-md sm:rounded-2xl sm:border sm:px-8 sm:pb-8 sm:pt-4 sm:shadow-2xl"
      >
        <div className="flex items-center justify-between">
          <button
            onClick={() => setExpanded(false)}
            aria-label="Close player"
            className="-ml-2 rounded-full p-2 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
          >
            <ChevronDown className="size-6" />
          </button>
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Chapter {item.chapterIdx + 1} of {queueLength}
          </span>
          <span className="w-10" />
        </div>

        <div className="flex flex-1 flex-col items-center justify-center gap-6 py-6 sm:py-4">
          <BookCover
            bookId={item.bookId}
            title={item.bookTitle}
            coverUrl={item.coverUrl}
            className="aspect-[2/3] w-[52vw] max-w-56 shadow-2xl sm:w-52"
          />

          <div className="w-full text-center">
            <h2 className="truncate font-serif text-xl font-semibold tracking-tight">{item.chapterTitle}</h2>
            <p className="mt-1 truncate text-sm text-muted-foreground">
              {item.bookTitle}
              {item.author ? ` · ${item.author}` : ""}
            </p>
            {live && (
              <p className="mt-2 inline-flex items-center gap-1.5 rounded-full bg-primary/10 px-3 py-1 text-xs font-medium text-primary">
                <span className="size-1.5 animate-pulse rounded-full bg-primary" />
                Live synthesis
              </p>
            )}
          </div>
        </div>

        <div className="space-y-6">
          {/* Live seeks restart synthesis at the nearest short text chunk. */}
          <div>
            <Slider
                value={[shownPosition]}
                min={0}
                max={Math.max(duration ?? 0, shownPosition, 1)}
                step={1}
                onValueChange={([v]) => setScrub(v ?? 0)}
                onValueCommit={([v]) => {
                  seekTo(v ?? 0);
                  setScrub(null);
                }}
                aria-label="Seek"
              />
            <div className="mt-2 flex justify-between text-xs tabular-nums text-muted-foreground">
              <span>{formatDuration(shownPosition)}</span>
              <span>
                {live
                  ? `${formatEstimate(item.source.kind === "live" ? item.source.estimatedDuration : 0)} total`
                  : remaining != null
                    ? `−${formatDuration(remaining)}`
                    : "—"}
              </span>
            </div>
          </div>

          {/* Transport */}
          <div className="flex items-center justify-center gap-2">
            <button
              onClick={previous}
              disabled={index <= 0 && position < 4}
              aria-label="Previous chapter"
              className="rounded-full p-3 text-foreground transition-colors hover:bg-accent disabled:opacity-30"
            >
              <SkipBack className="size-6" />
            </button>
            <button
              onClick={() => seekBy(-15)}
              aria-label="Back 15 seconds"
              className="relative rounded-full p-3 text-foreground transition-colors hover:bg-accent disabled:opacity-30"
            >
              <RotateCcw className="size-6" />
              <span className="absolute inset-0 flex items-center justify-center pt-1 text-[8px] font-bold">15</span>
            </button>

            <button
              onClick={toggle}
              aria-label={playing ? "Pause" : "Play"}
              className="mx-2 flex size-16 items-center justify-center rounded-full bg-primary text-primary-foreground shadow-lg transition-transform active:scale-95"
            >
              {status === "loading" ? (
                <Loader2 className="size-7 animate-spin" />
              ) : playing ? (
                <Pause className="size-7" />
              ) : (
                <Play className="size-7 translate-x-0.5" />
              )}
            </button>

            <button
              onClick={() => seekBy(30)}
              aria-label="Forward 30 seconds"
              className="relative rounded-full p-3 text-foreground transition-colors hover:bg-accent disabled:opacity-30"
            >
              <RotateCw className="size-6" />
              <span className="absolute inset-0 flex items-center justify-center pt-1 text-[8px] font-bold">30</span>
            </button>
            <button
              onClick={next}
              disabled={index >= queueLength - 1}
              aria-label="Next chapter"
              className="rounded-full p-3 text-foreground transition-colors hover:bg-accent disabled:opacity-30"
            >
              <SkipForward className="size-6" />
            </button>
          </div>

          {/* Secondary controls */}
          <div className="flex items-center justify-between text-sm">
            <button
              onClick={cycleRate}
              aria-label={`Playback speed ${rate}×, tap to change`}
              className="flex items-center gap-1.5 rounded-full px-3 py-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            >
              <Gauge className="size-4" />
              <span className="tabular-nums">{rate}×</span>
            </button>

            <button
              onClick={cycleSleep}
              aria-label={sleepLabel ? `Sleep timer: ${sleepLabel}, tap to change` : "Set sleep timer"}
              className={`flex items-center gap-1.5 rounded-full px-3 py-1.5 transition-colors hover:bg-accent ${
                sleep ? "text-primary" : "text-muted-foreground hover:text-foreground"
              }`}
            >
              <Moon className="size-4" />
              <span>{sleepLabel ?? "Sleep"}</span>
            </button>

            <button
              onClick={() => {
                setExpanded(false);
                navigate({ name: "book", id: item.bookId });
              }}
              aria-label="Show chapters"
              className="flex items-center gap-1.5 rounded-full px-3 py-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            >
              <ListOrdered className="size-4" />
              <span>Chapters</span>
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
