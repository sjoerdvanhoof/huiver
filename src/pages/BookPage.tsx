import { AlertCircle, Check, Download, ListChecks, Loader2, Pause, Play, Sparkles, Trash2, X } from "lucide-react";
import { useMemo, useState } from "react";
import { BookCover } from "@/components/BookCover";
import { ChapterAction } from "@/components/ChapterAction";
import { Button } from "@/components/ui/button";
import { api } from "@/lib/api";
import { deriveChapterStates, type ChapterUiState } from "@/lib/chapter-state";
import { formatApproxDuration, formatDuration, formatEstimate } from "@/lib/format";
import { useBookDetail } from "../hooks/useBookDetail";
import { cancelJob, cancelTrack, isActiveJob, reloadJobs, useJobs } from "../hooks/useJobs";
import { navigate } from "../hooks/useHashRoute";
import { useProviders } from "../hooks/useProviders";
import { useSettings } from "../hooks/useSettings";
import { buildQueueFromBook, playQueue, toggle, usePlayer } from "../player/store";
import type { BookDetailDTO, ChapterDTO, JobDTO } from "../shared";

export function BookPage({ bookId }: { bookId: string }) {
  const { book, error: bookError, reload, clearError } = useBookDetail(bookId);
  const { jobs, error: jobsError } = useJobs(() => void reload());
  const { providers } = useProviders();
  const { settings } = useSettings();
  const [actionError, setActionError] = useState<string | null>(null);

  const [selectMode, setSelectMode] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  // Conversion uses whatever the Settings page has stored; the engine, voice
  // and speed pickers live there, not here.
  const engine = useMemo(
    () => providers.find(p => p.id === settings.defaultProvider),
    [providers, settings.defaultProvider],
  );

  const bookJobs = useMemo(() => jobs.filter(j => j.bookId === bookId), [jobs, bookId]);
  const activeJobs = useMemo(() => bookJobs.filter(isActiveJob), [bookJobs]);
  const chapterStates = useMemo(() => deriveChapterStates(book, bookJobs), [book, bookJobs]);

  // What the global player is doing, so the buttons here mirror it instead of
  // offering a second, conflicting "play".
  const playingChapterId = usePlayer(s => s.queue[s.index]?.chapterId ?? null);
  const playingBookId = usePlayer(s => s.queue[s.index]?.bookId ?? null);
  const playingChapterIdx = usePlayer(s => s.queue[s.index]?.chapterIdx ?? null);
  const playingChapterTitle = usePlayer(s => s.queue[s.index]?.chapterTitle ?? null);
  const playerPosition = usePlayer(s => s.position);
  const playerStatus = usePlayer(s => s.status);
  const isPlaying = playerStatus === "playing" || playerStatus === "loading";

  const error = actionError ?? bookError ?? jobsError;

  if (!book) {
    return <div className="py-16 text-center text-sm text-muted-foreground">{bookError ?? "Loading book…"}</div>;
  }

  const p = book.progress;
  const unconverted = book.chapters.filter(c => !c.audio);
  // Chapters already waiting or rendering, so bulk convert never double-queues.
  const queued = new Set(
    activeJobs.flatMap(j =>
      j.tracks.filter(t => t.status === "pending" || t.status === "running").map(t => t.chapterId),
    ),
  );
  const toConvert = selectMode
    ? book.chapters.filter(c => selected.has(c.id))
    : unconverted.filter(c => !queued.has(c.id));
  const toConvertSeconds = toConvert.reduce((sum, c) => sum + c.estimatedDurationSeconds, 0);

  const playChapter = (chapter: ChapterDTO) => {
    const queue = buildQueueFromBook(book, settings);
    const index = queue.findIndex(q => q.chapterId === chapter.id);
    if (index < 0) return;
    const startAt =
      chapter.position && !chapter.position.completed && chapter.position.positionSeconds > 3
        ? chapter.position.positionSeconds
        : null;
    playQueue(queue, index, startAt);
  };

  const resume = () => {
    if (!p.resume) return;
    const queue = buildQueueFromBook(book, settings);
    const index = queue.findIndex(q => q.chapterId === p.resume!.chapterId);
    if (index < 0) return;
    playQueue(queue, index, p.resume.positionSeconds > 0 ? p.resume.positionSeconds : null);
  };

  /** Queue chapters and get out of the way — progress shows up inline. */
  const convert = async (chapterIds: string[]) => {
    if (chapterIds.length === 0) return;
    setActionError(null);
    try {
      // No provider/voice/speed: the server falls back to the saved settings.
      await api<JobDTO>(`/api/books/${book.id}/convert`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chapterIds }),
      });
      setSelectMode(false);
      setSelected(new Set());
      await Promise.all([reload(), reloadJobs()]);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : String(e));
    }
  };

  const stopConverting = async () => {
    try {
      await Promise.all(activeJobs.map(job => cancelJob(job.id)));
      await reload();
    } catch (e) {
      setActionError(e instanceof Error ? e.message : String(e));
    }
  };

  const removeBook = async () => {
    if (!confirm("Delete this book and all of its generated audio?")) return;
    try {
      await api(`/api/books/${book.id}`, { method: "DELETE" });
      navigate({ name: "library" });
    } catch (e) {
      setActionError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div className="space-y-6">
      {error && (
        <div className="flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
          <AlertCircle className="mt-0.5 size-4 shrink-0 text-destructive" />
          <span className="flex-1">{error}</span>
          <button
            onClick={() => {
              setActionError(null);
              clearError();
            }}
            aria-label="Dismiss error"
          >
            <X className="size-4" />
          </button>
        </div>
      )}

      <section className="flex gap-4 sm:gap-6">
        <BookCover
          bookId={book.id}
          title={book.title}
          coverUrl={book.coverUrl}
          className="aspect-[2/3] w-24 sm:w-36"
        />
        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-2">
            <div className="min-w-0">
              <h1 className="break-words font-serif text-xl font-bold tracking-tight sm:text-3xl">{book.title}</h1>
              {book.author && <p className="mt-0.5 text-sm text-muted-foreground">{book.author}</p>}
            </div>
            <div className="flex shrink-0 items-center">
              {p.convertedChapters > 0 && (
                <a
                  href={`/api/books/${book.id}/download`}
                  aria-label={`Download ${book.title} as a zip`}
                  title="Download converted chapters"
                  className="rounded-full p-2 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                >
                  <Download className="size-4" />
                </a>
              )}
              <button
                onClick={() => void removeBook()}
                aria-label={`Delete ${book.title}`}
                className="rounded-full p-2 text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
              >
                <Trash2 className="size-4" />
              </button>
            </div>
          </div>

          <p className="mt-2 text-xs text-muted-foreground sm:text-sm">
            {book.chapterCount} chapters · {p.conversionStatus === "full" ? "" : "~"}
            {formatApproxDuration(p.estimatedTotalSeconds)} total
            {p.convertedSeconds > 0 && p.conversionStatus !== "full" && (
              <> · {formatApproxDuration(p.convertedSeconds)} converted</>
            )}
            {p.percentListened > 0.005 && <> · {Math.round(p.percentListened * 100)}% listened</>}
          </p>

          <SegmentedProgress book={book} className="mt-3" />

          <div className="mt-4 flex flex-wrap items-center gap-2">
            {/* One transport button: it controls the player when this book is
                loaded, and only starts a new session otherwise. */}
            {playingBookId === book.id ? (
              <Button onClick={toggle} size="lg" className="gap-2">
                {isPlaying ? <Pause className="size-4" /> : <Play className="size-4" />}
                {isPlaying ? "Pause" : "Resume"} · Ch. {(playingChapterIdx ?? 0) + 1}
                {playerPosition > 3 && ` at ${formatDuration(playerPosition)}`}
              </Button>
            ) : p.resume ? (
              <Button onClick={resume} size="lg" className="gap-2">
                <Play className="size-4" />
                Resume · Ch. {p.resume.chapterIdx + 1}
                {p.resume.positionSeconds > 3 && ` at ${formatDuration(p.resume.positionSeconds)}`}
              </Button>
            ) : (
              book.chapters.length > 0 && (
                <Button
                  onClick={() => playChapter(book.chapters[0]!)}
                  size="lg"
                  className="gap-2"
                  disabled={!book.chapters[0]!.audio && !engine?.available}
                >
                  <Play className="size-4" /> Play
                </Button>
              )
            )}

            {toConvert.length > 0 && (
              <Button
                variant="outline"
                size="lg"
                className="gap-2"
                onClick={() => void convert(toConvert.map(c => c.id))}
                disabled={!engine?.available}
                title={engine?.available ? undefined : engine?.reason}
              >
                <Sparkles className="size-4" />
                Convert {toConvert.length} chapter{toConvert.length === 1 ? "" : "s"}
                <span className="text-xs font-normal text-muted-foreground">
                  {formatEstimate(toConvertSeconds)}
                </span>
              </Button>
            )}

            {activeJobs.length > 0 && (
              <ConversionStatus jobs={activeJobs} onStop={() => void stopConverting()} />
            )}
          </div>

          {!engine?.available && engine?.reason && (
            <p className="mt-2 text-xs text-muted-foreground">{engine.reason}</p>
          )}
        </div>
      </section>

      <section className="overflow-hidden rounded-xl border bg-card">
        <div className="flex items-center justify-between border-b px-4 py-2.5">
          <h3 className="text-sm font-semibold">Chapters</h3>
          <div className="flex items-center gap-2 text-xs">
            {selectMode && (
              <>
                <button
                  className="text-muted-foreground hover:text-foreground"
                  onClick={() => setSelected(new Set(book.chapters.map(c => c.id)))}
                >
                  All
                </button>
                <span className="text-muted-foreground">·</span>
                <button
                  className="text-muted-foreground hover:text-foreground"
                  onClick={() => setSelected(new Set(unconverted.map(c => c.id)))}
                >
                  Unconverted
                </button>
                <span className="text-muted-foreground">·</span>
              </>
            )}
            <button
              className={`flex items-center gap-1 ${selectMode ? "text-primary" : "text-muted-foreground hover:text-foreground"}`}
              onClick={() => {
                setSelectMode(!selectMode);
                setSelected(new Set());
              }}
            >
              <ListChecks className="size-3.5" />
              {selectMode ? "Done" : "Select"}
            </button>
          </div>
        </div>

        <ul className="divide-y">
          {book.chapters.map(chapter => (
            <ChapterRow
              key={chapter.id}
              chapter={chapter}
              state={chapterStates.get(chapter.id) ?? { state: chapter.audio ? "done" : "none" }}
              selectMode={selectMode}
              selected={selected.has(chapter.id)}
              onToggleSelect={() =>
                setSelected(prev => {
                  const next = new Set(prev);
                  next.has(chapter.id) ? next.delete(chapter.id) : next.add(chapter.id);
                  return next;
                })
              }
              isCurrent={playingChapterId === chapter.id}
              isPlaying={isPlaying}
              canStream={engine?.available ?? false}
              canConvert={engine?.available ?? false}
              onPlay={() => playChapter(chapter)}
              onTogglePlay={toggle}
              onConvert={() => void convert([chapter.id])}
              onCancel={(() => {
                const trackId = chapterStates.get(chapter.id)?.cancelTrackId;
                return trackId ? () => void cancelTrack(trackId) : undefined;
              })()}
            />
          ))}
        </ul>
      </section>
    </div>
  );
}

/** Inline, unobtrusive replacement for the old per-job panels. */
function ConversionStatus({ jobs, onStop }: { jobs: JobDTO[]; onStop: () => void }) {
  const done = jobs.reduce((sum, j) => sum + j.chunksDone, 0);
  const total = jobs.reduce((sum, j) => sum + j.chunksTotal, 0);
  const percent = total > 0 ? Math.round((done / total) * 100) : 0;
  const chapters = jobs.flatMap(j => j.tracks);
  const finished = chapters.filter(t => t.status === "done").length;

  return (
    <div className="flex min-w-0 items-center gap-3 rounded-lg border bg-card px-3 py-2">
      <Loader2 className="size-4 shrink-0 animate-spin text-primary" />
      <div className="min-w-0">
        <p className="text-sm font-medium">
          Converting… {percent}%
          <span className="ml-2 text-xs font-normal text-muted-foreground">
            {finished} of {chapters.length} chapters
          </span>
        </p>
        <div className="mt-1 h-1 w-40 overflow-hidden rounded-full bg-muted">
          <div className="h-full bg-primary transition-all" style={{ width: `${percent}%` }} />
        </div>
      </div>
      <button onClick={onStop} className="shrink-0 text-xs text-muted-foreground hover:text-destructive">
        Stop
      </button>
    </div>
  );
}

/**
 * One bar for the whole book: each chapter is a segment sized by its (real or
 * estimated) duration; the fill shows how much of it you've heard. Converted
 * chapters get a visible base tint, so "on disk" reads at a glance.
 */
function SegmentedProgress({ book, className }: { book: BookDetailDTO; className?: string }) {
  const total = book.progress.estimatedTotalSeconds || 1;
  return (
    <div className={`flex h-1.5 w-full gap-px overflow-hidden rounded-full ${className ?? ""}`}>
      {book.chapters.map(chapter => {
        const width = (chapter.estimatedDurationSeconds / total) * 100;
        const listened = chapter.position
          ? chapter.position.completed
            ? 1
            : Math.min(1, chapter.position.positionSeconds / Math.max(1, chapter.estimatedDurationSeconds))
          : 0;
        return (
          <div
            key={chapter.id}
            className={chapter.audio ? "bg-primary/25" : "bg-muted"}
            style={{ width: `${width}%` }}
          >
            <div className="h-full bg-primary" style={{ width: `${listened * 100}%` }} />
          </div>
        );
      })}
    </div>
  );
}

function ChapterRow({
  chapter,
  state,
  selectMode,
  selected,
  onToggleSelect,
  isCurrent,
  isPlaying,
  canStream,
  canConvert,
  onPlay,
  onTogglePlay,
  onConvert,
  onCancel,
}: {
  chapter: ChapterDTO;
  state: ChapterUiState;
  selectMode: boolean;
  selected: boolean;
  onToggleSelect: () => void;
  /** This chapter is the one loaded in the player. */
  isCurrent: boolean;
  isPlaying: boolean;
  canStream: boolean;
  canConvert: boolean;
  onPlay: () => void;
  onTogglePlay: () => void;
  onConvert: () => void;
  onCancel?: () => void;
}) {
  const finished = chapter.position?.completed ?? false;
  const partial =
    !finished && chapter.position !== null && chapter.position.positionSeconds > 3
      ? Math.min(1, chapter.position.positionSeconds / Math.max(1, chapter.estimatedDurationSeconds))
      : null;
  const showPause = isCurrent && isPlaying;

  return (
    <li
      onClick={selectMode ? onToggleSelect : undefined}
      className={`relative px-4 py-2.5 transition-colors ${selectMode ? "cursor-pointer" : ""} ${
        isCurrent ? "bg-primary/5" : "hover:bg-accent/50"
      }`}
    >
      <div className="flex items-center gap-3">
        {selectMode && (
          <span
            className={`flex size-4 shrink-0 items-center justify-center rounded border ${
              selected ? "border-primary bg-primary text-primary-foreground" : "border-input"
            }`}
          >
            {selected && <Check className="size-3" />}
          </span>
        )}

        <ChapterAction
          state={state.state}
          progress={state.progress}
          detail={state.detail}
          disabled={!canConvert}
          onConvert={onConvert}
          onCancel={onCancel}
        />

        <div className="min-w-0 flex-1">
          <p className="flex items-center gap-1.5 text-sm font-medium">
            <span className={`truncate ${finished ? "text-muted-foreground" : ""}`}>
              {chapter.idx + 1}. {chapter.title}
            </span>
            {finished && (
              <span className="inline-flex shrink-0 items-center gap-0.5 text-xs font-normal text-muted-foreground">
                <Check className="size-3.5 text-emerald-600 dark:text-emerald-400" />
                Finished
              </span>
            )}
          </p>
          <p className="truncate text-xs text-muted-foreground">{chapter.preview}</p>
        </div>

        <span className="shrink-0 text-xs tabular-nums text-muted-foreground">
          {chapter.audio?.duration
            ? formatDuration(chapter.audio.duration)
            : formatEstimate(chapter.estimatedDurationSeconds)}
        </span>

        {!selectMode && (
          <button
            title={
              showPause
                ? "Pause"
                : isCurrent
                  ? "Resume"
                  : chapter.audio
                    ? "Play"
                    : "Listen now (streams while it renders)"
            }
            aria-label={`${showPause ? "Pause" : "Play"} ${chapter.title}`}
            disabled={!chapter.audio && !canStream}
            onClick={e => {
              e.stopPropagation();
              // Already loaded? Toggle it, never restart it.
              isCurrent ? onTogglePlay() : onPlay();
            }}
            className={`shrink-0 rounded-full p-1.5 transition-colors disabled:opacity-30 ${
              isCurrent
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-accent hover:text-foreground"
            }`}
          >
            {showPause ? <Pause className="size-4" /> : <Play className="size-4" />}
          </button>
        )}
      </div>

      {partial !== null && (
        <div className="absolute inset-x-4 bottom-0 h-0.5 overflow-hidden rounded-full bg-transparent">
          <div className="h-full bg-primary/50" style={{ width: `${partial * 100}%` }} />
        </div>
      )}
    </li>
  );
}
