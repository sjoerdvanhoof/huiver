import { AlertCircle, Check, Download, ListChecks, Play, Trash2, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { BookCover } from "@/components/BookCover";
import { JobPanel } from "@/components/JobPanel";
import { StatusIcon, type ConversionState } from "@/components/StatusIcon";
import { VoicePicker } from "@/components/VoicePicker";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Slider } from "@/components/ui/slider";
import { api } from "@/lib/api";
import { formatApproxDuration, formatDuration, formatEstimate } from "@/lib/format";
import { useBookDetail } from "../hooks/useBookDetail";
import { ACTIVE_JOB_STATES, useJobs } from "../hooks/useJobs";
import { navigate } from "../hooks/useHashRoute";
import { useProviders } from "../hooks/useProviders";
import { useSettings } from "../hooks/useSettings";
import { buildQueueFromBook, playQueue, usePlayer } from "../player/store";
import type { BookDetailDTO, ChapterDTO, JobDTO, SettingsDTO } from "../shared";

export function BookPage({ bookId }: { bookId: string }) {
  const { book, error: bookError, reload, clearError } = useBookDetail(bookId);
  const { jobs, cancel, error: jobsError } = useJobs(() => void reload());
  const { providers } = useProviders();
  const { settings, loaded: settingsLoaded } = useSettings();
  const [actionError, setActionError] = useState<string | null>(null);

  // Conversion settings for THIS run, seeded from the persisted defaults.
  const [providerId, setProviderId] = useState<string | null>(null);
  const [voice, setVoice] = useState<string>("");
  const [speed, setSpeed] = useState(1);
  const [speedDraft, setSpeedDraft] = useState(1);

  useEffect(() => {
    if (!settingsLoaded || providerId !== null) return;
    setProviderId(settings.defaultProvider);
    setSpeed(settings.defaultSpeed);
    setSpeedDraft(settings.defaultSpeed);
  }, [settingsLoaded, settings, providerId]);

  const provider = useMemo(
    () => providers.find(p => p.id === (providerId ?? settings.defaultProvider)),
    [providers, providerId, settings.defaultProvider],
  );

  useEffect(() => {
    if (!provider || voice) return;
    setVoice(settings.defaultVoice ?? provider.defaultVoice);
  }, [provider, voice, settings.defaultVoice]);

  const [selectMode, setSelectMode] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const bookJobs = useMemo(() => jobs.filter(j => j.bookId === bookId), [jobs, bookId]);
  const chapterStates = useMemo(() => deriveChapterStates(book, bookJobs), [book, bookJobs]);

  const effectiveSettings: SettingsDTO = {
    defaultProvider: providerId ?? settings.defaultProvider,
    defaultVoice: voice || settings.defaultVoice,
    defaultSpeed: speed,
    theme: settings.theme,
  };

  const playingChapterId = usePlayer(s => s.queue[s.index]?.chapterId ?? null);
  const playerStatus = usePlayer(s => s.status);

  const error = actionError ?? bookError ?? jobsError;

  if (!book) {
    return (
      <div className="py-16 text-center text-sm text-muted-foreground">
        {bookError ?? "Loading book…"}
      </div>
    );
  }

  const p = book.progress;
  const unconverted = book.chapters.filter(c => !c.audio);
  const toConvert = selectMode
    ? book.chapters.filter(c => selected.has(c.id))
    : unconverted.length > 0
      ? unconverted
      : book.chapters;
  const toConvertSeconds = toConvert.reduce((sum, c) => sum + c.estimatedDurationSeconds, 0);

  const playChapter = (chapter: ChapterDTO) => {
    const queue = buildQueueFromBook(book, effectiveSettings);
    const index = queue.findIndex(q => q.chapterId === chapter.id);
    if (index < 0) return;
    const startAt =
      chapter.audio && chapter.position && !chapter.position.completed && chapter.position.positionSeconds > 3
        ? chapter.position.positionSeconds
        : null;
    playQueue(queue, index, startAt);
  };

  const resume = () => {
    if (!p.resume) return;
    const queue = buildQueueFromBook(book, effectiveSettings);
    const index = queue.findIndex(q => q.chapterId === p.resume!.chapterId);
    if (index < 0) return;
    playQueue(queue, index, p.resume.positionSeconds > 0 ? p.resume.positionSeconds : null);
  };

  const convert = async () => {
    setActionError(null);
    try {
      await api<JobDTO>(`/api/books/${book.id}/convert`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          provider: effectiveSettings.defaultProvider,
          voice: effectiveSettings.defaultVoice ?? undefined,
          speed,
          chapterIds: toConvert.map(c => c.id),
        }),
      });
      setSelectMode(false);
      setSelected(new Set());
      // Poll picks the job up; reload now so statuses flip to "queued" immediately.
      window.setTimeout(() => window.location.hash === `#/book/${book.id}` && void reload(), 300);
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

      {/* Header */}
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
            <button
              onClick={() => void removeBook()}
              aria-label={`Delete ${book.title}`}
              className="rounded-full p-2 text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
            >
              <Trash2 className="size-4" />
            </button>
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
            {p.resume ? (
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
                  disabled={!book.chapters[0]!.audio && !provider?.available}
                >
                  <Play className="size-4" /> Play
                </Button>
              )
            )}
          </div>
        </div>
      </section>

      {/* Convert */}
      {p.conversionStatus !== "full" || selectMode ? (
        <section className="rounded-xl border bg-card p-4">
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <div className="min-w-0 space-y-1.5">
              <Label>Engine</Label>
              <Select
                value={providerId ?? settings.defaultProvider}
                onValueChange={id => {
                  setProviderId(id);
                  setVoice(providers.find(pr => pr.id === id)?.defaultVoice ?? "");
                }}
              >
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {providers.map(pr => (
                    <SelectItem key={pr.id} value={pr.id} disabled={!pr.available}>
                      {pr.label}
                      {!pr.available && " (unavailable)"}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="min-w-0 space-y-1.5">
              <Label>Voice</Label>
              <VoicePicker provider={provider} voice={voice} onVoiceChange={setVoice} onError={setActionError} />
            </div>

            <div className="min-w-0 space-y-1.5">
              <div className="flex items-baseline justify-between">
                <Label>Speed</Label>
                <span className="text-xs tabular-nums text-muted-foreground">{speedDraft.toFixed(2)}×</span>
              </div>
              <div className="flex h-9 items-center">
                <Slider
                  value={[speedDraft]}
                  onValueChange={([v]) => setSpeedDraft(v ?? 1)}
                  onValueCommit={([v]) => setSpeed(v ?? 1)}
                  min={0.5}
                  max={2}
                  step={0.05}
                  disabled={!provider?.supportsSpeed}
                  aria-label="Speech speed"
                />
              </div>
            </div>
          </div>

          {provider && !provider.available && (
            <p className="mt-3 text-xs text-muted-foreground">{provider.reason}</p>
          )}

          <div className="mt-4 flex flex-wrap items-center gap-x-3 gap-y-2">
            <Button onClick={() => void convert()} disabled={toConvert.length === 0 || !provider?.available}>
              Convert {toConvert.length} chapter{toConvert.length === 1 ? "" : "s"}
            </Button>
            <span className="text-xs text-muted-foreground">
              {formatEstimate(toConvertSeconds)} of audio
              {!selectMode && unconverted.length > 0 && unconverted.length < book.chapters.length && " (remaining)"}
            </span>
          </div>
        </section>
      ) : null}

      {/* Chapters */}
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
                  const nextSet = new Set(prev);
                  nextSet.has(chapter.id) ? nextSet.delete(chapter.id) : nextSet.add(chapter.id);
                  return nextSet;
                })
              }
              playing={playingChapterId === chapter.id && (playerStatus === "playing" || playerStatus === "loading")}
              canStream={provider?.available ?? false}
              onPlay={() => playChapter(chapter)}
            />
          ))}
        </ul>
      </section>

      {bookJobs
        .filter(j => ACTIVE_JOB_STATES.has(j.status) || j.status === "error" || j.status === "cancelled")
        .map(job => (
          <JobPanel
            key={job.id}
            job={job}
            onCancel={() => void cancel(job.id)}
            onPlayChapter={chapterId => {
              const chapter = book.chapters.find(c => c.id === chapterId);
              if (chapter) playChapter(chapter);
            }}
          />
        ))}

      <FinishedJobs jobs={bookJobs.filter(j => j.status === "done")} />
    </div>
  );
}

/** Past conversions stay reachable for their zip download, without the noise. */
function FinishedJobs({ jobs }: { jobs: JobDTO[] }) {
  if (jobs.length === 0) return null;
  return (
    <section className="overflow-hidden rounded-xl border bg-card">
      <h3 className="border-b px-4 py-2.5 text-sm font-semibold">Conversions</h3>
      <ul className="divide-y">
        {jobs.map(job => {
          const done = job.tracks.filter(t => t.status === "done").length;
          return (
            <li key={job.id} className="flex items-center gap-3 px-4 py-2.5 text-sm">
              <StatusIcon state="done" />
              <span className="min-w-0 flex-1 truncate">
                {job.provider} · {job.voice} · {job.speed}×
                <span className="ml-2 text-xs text-muted-foreground">
                  {done} track{done === 1 ? "" : "s"}
                </span>
              </span>
              <Button variant="outline" size="sm" asChild>
                <a href={`/api/jobs/${job.id}/download`}>
                  <Download className="size-4" /> Zip
                </a>
              </Button>
            </li>
          );
        })}
      </ul>
    </section>
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

type ChapterUiState = { state: ConversionState; detail?: string | null };

/** Fold the chapter's tracks and any active jobs into one displayable state. */
function deriveChapterStates(book: BookDetailDTO | null, jobs: JobDTO[]): Map<string, ChapterUiState> {
  const map = new Map<string, ChapterUiState>();
  if (!book) return map;

  for (const chapter of book.chapters) {
    map.set(chapter.id, { state: chapter.audio ? "done" : "none" });
  }

  // Newest jobs first so the freshest attempt wins the badge.
  for (const job of [...jobs].sort((a, b) => b.createdAt - a.createdAt)) {
    const active = ACTIVE_JOB_STATES.has(job.status);
    for (const track of job.tracks) {
      const current = map.get(track.chapterId);
      if (!current) continue;
      if (active && track.status === "running") map.set(track.chapterId, { state: "converting" });
      else if (active && track.status === "pending" && current.state === "none") {
        map.set(track.chapterId, { state: "queued" });
      } else if (track.status === "error" && current.state === "none") {
        map.set(track.chapterId, { state: "error", detail: track.error });
      }
    }
  }
  return map;
}

function ChapterRow({
  chapter,
  state,
  selectMode,
  selected,
  onToggleSelect,
  playing,
  canStream,
  onPlay,
}: {
  chapter: ChapterDTO;
  state: ChapterUiState;
  selectMode: boolean;
  selected: boolean;
  onToggleSelect: () => void;
  playing: boolean;
  canStream: boolean;
  onPlay: () => void;
}) {
  const finished = chapter.position?.completed ?? false;
  const partial =
    !finished && chapter.position !== null && chapter.position.positionSeconds > 3
      ? Math.min(1, chapter.position.positionSeconds / Math.max(1, chapter.estimatedDurationSeconds))
      : null;

  return (
    <li
      onClick={selectMode ? onToggleSelect : undefined}
      className={`relative px-4 py-2.5 transition-colors ${selectMode ? "cursor-pointer" : ""} ${
        playing ? "bg-primary/5" : "hover:bg-accent/50"
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

        <StatusIcon state={state.state} detail={state.detail} />

        <div className="min-w-0 flex-1">
          <p className={`truncate text-sm font-medium ${finished ? "text-muted-foreground" : ""}`}>
            {chapter.idx + 1}. {chapter.title}
            {finished && <Check className="ml-1.5 inline size-3.5 text-primary" aria-label="Finished" />}
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
            title={chapter.audio ? "Play" : "Listen now (streams while it renders)"}
            aria-label={`Play ${chapter.title}`}
            disabled={!chapter.audio && !canStream}
            onClick={e => {
              e.stopPropagation();
              onPlay();
            }}
            className={`shrink-0 rounded-full p-1.5 transition-colors disabled:opacity-30 ${
              playing
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-accent hover:text-foreground"
            }`}
          >
            <Play className="size-4" />
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
