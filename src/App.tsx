import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Slider } from "@/components/ui/slider";
import {
  AlertCircle,
  BookOpen,
  Check,
  Download,
  Headphones,
  Loader2,
  Pause,
  Play,
  Trash2,
  Upload,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { BookDTO, BookDetailDTO, JobDTO, ProviderDTO } from "./shared";
import "./index.css";

const ACTIVE = new Set(["queued", "running"]);

async function api<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((body as { error?: string }).error ?? `Request failed (${response.status})`);
  return body as T;
}

const formatChars = (n: number) => (n >= 1000 ? `${Math.round(n / 1000)}k chars` : `${n} chars`);

function formatDuration(seconds: number | null): string {
  if (!seconds) return "—";
  const total = Math.round(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
    : `${m}:${String(s).padStart(2, "0")}`;
}

type PreviewState = { voice: string; loading: boolean };

export function App() {
  const [providers, setProviders] = useState<ProviderDTO[]>([]);
  const [books, setBooks] = useState<BookDTO[]>([]);
  const [bookId, setBookId] = useState<string | null>(null);
  const [book, setBook] = useState<BookDetailDTO | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [jobs, setJobs] = useState<JobDTO[]>([]);

  const [providerId, setProviderId] = useState("kokoro");
  const [voice, setVoice] = useState("");
  // `speed` only changes when the slider is released. `speedDraft` tracks the
  // handle while dragging — restarting the live stream on every tick would
  // open (and abandon) a dozen synthesis requests in a second.
  const [speed, setSpeed] = useState(1);
  const [speedDraft, setSpeedDraft] = useState(1);

  const [preview, setPreview] = useState<PreviewState | null>(null);
  const [listening, setListening] = useState<string | null>(null);
  const previewAudio = useRef<HTMLAudioElement | null>(null);

  const [uploading, setUploading] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  const provider = useMemo(() => providers.find(p => p.id === providerId), [providers, providerId]);

  const loadBooks = useCallback(async () => setBooks(await api<BookDTO[]>("/api/books")), []);
  const loadJobs = useCallback(async () => setJobs(await api<JobDTO[]>("/api/jobs")), []);

  useEffect(() => {
    api<ProviderDTO[]>("/api/providers")
      .then(list => {
        setProviders(list);
        const first = list.find(p => p.available) ?? list[0];
        if (first) {
          setProviderId(first.id);
          setVoice(first.defaultVoice);
        }
      })
      .catch(e => setError(e.message));
    void loadBooks();
    void loadJobs();
  }, [loadBooks, loadJobs]);

  useEffect(() => {
    if (!bookId) {
      setBook(null);
      setSelected(new Set());
      return;
    }
    api<BookDetailDTO>(`/api/books/${bookId}`)
      .then(detail => {
        setBook(detail);
        setSelected(new Set(detail.chapters.map(c => c.id)));
      })
      .catch(e => setError(e.message));
  }, [bookId]);

  const hasActive = jobs.some(j => ACTIVE.has(j.status));
  useEffect(() => {
    if (!hasActive) return;
    const timer = setInterval(() => void loadJobs(), 1500);
    return () => clearInterval(timer);
  }, [hasActive, loadJobs]);

  // Stop any preview when the component goes away.
  useEffect(() => () => previewAudio.current?.pause(), []);

  const playPreview = useCallback(
    (voiceId: string) => {
      previewAudio.current?.pause();

      // Clicking the voice that is already playing just stops it.
      if (preview?.voice === voiceId) {
        setPreview(null);
        return;
      }

      const audio = new Audio(
        `/api/providers/${providerId}/preview?voice=${encodeURIComponent(voiceId)}`,
      );
      previewAudio.current = audio;
      setPreview({ voice: voiceId, loading: true });

      audio.addEventListener("playing", () => setPreview({ voice: voiceId, loading: false }));
      audio.addEventListener("ended", () => setPreview(null));
      audio.addEventListener("error", () => {
        setPreview(null);
        setError(`Could not preview ${voiceId}. The first preview of a voice takes a few seconds.`);
      });
      void audio.play().catch(() => setPreview(null));
    },
    [providerId, preview],
  );

  const upload = useCallback(
    async (files: FileList | null) => {
      if (!files?.length) return;
      setUploading(true);
      setError(null);
      try {
        for (const file of Array.from(files)) {
          const form = new FormData();
          form.append("file", file);
          const created = await api<BookDTO>("/api/books", { method: "POST", body: form });
          setBookId(created.id);
        }
        await loadBooks();
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        setUploading(false);
        if (fileInput.current) fileInput.current.value = "";
      }
    },
    [loadBooks],
  );

  const convert = useCallback(async () => {
    if (!book) return;
    setError(null);
    try {
      await api<JobDTO>(`/api/books/${book.id}/convert`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ provider: providerId, voice, speed, chapterIds: [...selected] }),
      });
      await loadJobs();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [book, providerId, voice, speed, selected, loadJobs]);

  const removeBook = useCallback(
    async (id: string) => {
      if (!confirm("Delete this book and all of its generated audio?")) return;
      try {
        await api(`/api/books/${id}`, { method: "DELETE" });
        if (bookId === id) setBookId(null);
        await Promise.all([loadBooks(), loadJobs()]);
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      }
    },
    [bookId, loadBooks, loadJobs],
  );

  const cancelJob = useCallback(
    async (id: string) => {
      try {
        await api(`/api/jobs/${id}/cancel`, { method: "POST" });
        await loadJobs();
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      }
    },
    [loadJobs],
  );

  const toggleChapter = (id: string) =>
    setSelected(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });

  const bookJobs = jobs.filter(j => j.bookId === bookId);
  const selectedChars = book?.chapters.filter(c => selected.has(c.id)).reduce((s, c) => s + c.charCount, 0) ?? 0;
  const streamUrl = (chapterId: string) =>
    `/api/chapters/${chapterId}/stream?provider=${encodeURIComponent(providerId)}`
    + `&voice=${encodeURIComponent(voice)}&speed=${speed}`;

  return (
    <div className="mx-auto w-full max-w-6xl p-4 sm:p-6">
      <header className="mb-6 flex items-center gap-3">
        <Headphones className="size-7 text-primary" />
        <div>
          <h1 className="text-2xl font-bold tracking-tight">huiver</h1>
          <p className="text-sm text-muted-foreground">Turn ebooks into audiobooks, locally.</p>
        </div>
      </header>

      {error && (
        <div className="mb-4 flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
          <AlertCircle className="mt-0.5 size-4 shrink-0 text-destructive" />
          <span className="flex-1">{error}</span>
          <button onClick={() => setError(null)} aria-label="Dismiss error">
            <X className="size-4" />
          </button>
        </div>
      )}

      {/* minmax(0,…) instead of 1fr: grid children default to min-width:auto, and the
          truncated (nowrap) chapter previews would otherwise stretch the page. */}
      <div className="grid items-start gap-6 md:grid-cols-[minmax(0,300px)_minmax(0,1fr)]">
        <aside className="min-w-0 space-y-4">
          <div
            onDragOver={e => {
              e.preventDefault();
              setDragging(true);
            }}
            onDragLeave={() => setDragging(false)}
            onDrop={e => {
              e.preventDefault();
              setDragging(false);
              void upload(e.dataTransfer.files);
            }}
            onClick={() => fileInput.current?.click()}
            className={`cursor-pointer rounded-lg border-2 border-dashed p-6 text-center transition-colors ${
              dragging ? "border-primary bg-primary/5" : "border-muted-foreground/25 hover:border-primary/50"
            }`}
          >
            {uploading ? (
              <Loader2 className="mx-auto mb-2 size-6 animate-spin text-muted-foreground" />
            ) : (
              <Upload className="mx-auto mb-2 size-6 text-muted-foreground" />
            )}
            <p className="text-sm font-medium">{uploading ? "Reading…" : "Drop a book here"}</p>
            <p className="mt-1 text-xs text-muted-foreground">epub · txt · md · html</p>
            <input
              ref={fileInput}
              type="file"
              multiple
              accept=".epub,.zip,.txt,.md,.markdown,.html,.htm,.xhtml"
              className="hidden"
              onChange={e => void upload(e.target.files)}
            />
          </div>

          <div className="space-y-1">
            <h2 className="px-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              Library ({books.length})
            </h2>
            {books.length === 0 && <p className="px-1 py-4 text-sm text-muted-foreground">Nothing here yet.</p>}
            {books.map(b => (
              <div
                key={b.id}
                onClick={() => setBookId(b.id)}
                className={`group flex cursor-pointer items-start gap-2 rounded-md border p-3 transition-colors ${
                  bookId === b.id ? "border-primary bg-accent" : "border-transparent hover:bg-accent/50"
                }`}
              >
                <BookOpen className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">{b.title}</p>
                  <p className="truncate text-xs text-muted-foreground">
                    {b.author ? `${b.author} · ` : ""}
                    {b.chapterCount} ch · {formatChars(b.charCount)}
                  </p>
                </div>
                <button
                  className="opacity-0 transition-opacity group-hover:opacity-100"
                  aria-label={`Delete ${b.title}`}
                  onClick={e => {
                    e.stopPropagation();
                    void removeBook(b.id);
                  }}
                >
                  <Trash2 className="size-4 text-muted-foreground hover:text-destructive" />
                </button>
              </div>
            ))}
          </div>
        </aside>

        <main className="min-w-0 space-y-6">
          {!book && (
            <div className="rounded-lg border border-dashed p-12 text-center text-sm text-muted-foreground">
              Select a book from your library, or drop a new one in.
            </div>
          )}

          {book && (
            <>
              <section className="min-w-0 rounded-lg border p-4">
                <h2 className="text-lg font-semibold break-words">{book.title}</h2>
                {book.author && <p className="text-sm text-muted-foreground break-words">{book.author}</p>}

                <div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                  <div className="min-w-0 space-y-1.5">
                    <Label>Engine</Label>
                    <Select
                      value={providerId}
                      onValueChange={id => {
                        setProviderId(id);
                        setVoice(providers.find(p => p.id === id)?.defaultVoice ?? "");
                      }}
                    >
                      <SelectTrigger className="w-full">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {providers.map(p => (
                          <SelectItem key={p.id} value={p.id} disabled={!p.available}>
                            {p.label}
                            {!p.available && " (unavailable)"}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>

                  <div className="min-w-0 space-y-1.5">
                    <Label>Voice</Label>
                    <Select value={voice} onValueChange={setVoice} disabled={!provider?.voices.length}>
                      <SelectTrigger className="w-full">
                        <SelectValue placeholder="No voices" />
                      </SelectTrigger>
                      <SelectContent>
                        {provider?.voices.map(v => (
                          <SelectItem
                            key={v.id}
                            value={v.id}
                            leading={
                              <PreviewButton
                                state={preview?.voice === v.id ? preview : null}
                                onPlay={() => playPreview(v.id)}
                                label={v.label}
                              />
                            }
                          >
                            {v.label}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>

                  <div className="min-w-0 space-y-1.5">
                    <div className="flex items-baseline justify-between">
                      <Label>Speed</Label>
                      <span className="text-xs tabular-nums text-muted-foreground">
                        {speedDraft.toFixed(2)}×
                      </span>
                    </div>
                    <div className="flex h-9 items-center">
                      <Slider
                        value={[speedDraft]}
                        onValueChange={([next]) => setSpeedDraft(next ?? 1)}
                        onValueCommit={([next]) => setSpeed(next ?? 1)}
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
                  <Button onClick={() => void convert()} disabled={selected.size === 0 || !provider?.available}>
                    Convert {selected.size} chapter{selected.size === 1 ? "" : "s"}
                  </Button>
                  <span className="text-xs text-muted-foreground">{formatChars(selectedChars)} selected</span>
                </div>
              </section>

              <section className="min-w-0 rounded-lg border">
                <div className="flex items-center justify-between border-b px-4 py-2.5">
                  <h3 className="text-sm font-semibold">Chapters</h3>
                  <div className="flex gap-2 text-xs">
                    <button
                      className="text-muted-foreground hover:text-foreground"
                      onClick={() => setSelected(new Set(book.chapters.map(c => c.id)))}
                    >
                      Select all
                    </button>
                    <span className="text-muted-foreground">·</span>
                    <button
                      className="text-muted-foreground hover:text-foreground"
                      onClick={() => setSelected(new Set())}
                    >
                      None
                    </button>
                  </div>
                </div>
                <ul className="max-h-[26rem] divide-y overflow-y-auto">
                  {book.chapters.map(c => (
                    <li key={c.id} className="px-4 py-2.5 hover:bg-accent/50">
                      <div
                        onClick={() => toggleChapter(c.id)}
                        className="flex cursor-pointer items-start gap-3"
                      >
                        <span
                          className={`mt-0.5 flex size-4 shrink-0 items-center justify-center rounded border ${
                            selected.has(c.id) ? "border-primary bg-primary text-primary-foreground" : "border-input"
                          }`}
                        >
                          {selected.has(c.id) && <Check className="size-3" />}
                        </span>
                        <div className="min-w-0 flex-1">
                          <p className="truncate text-sm font-medium">
                            {c.idx + 1}. {c.title}
                          </p>
                          <p className="truncate text-xs text-muted-foreground">{c.preview}</p>
                        </div>
                        <span className="shrink-0 text-xs text-muted-foreground">{formatChars(c.charCount)}</span>
                        <button
                          title={listening === c.id ? "Stop" : "Listen now (streams while it renders)"}
                          aria-label={listening === c.id ? `Stop ${c.title}` : `Listen to ${c.title}`}
                          disabled={!provider?.available}
                          onClick={e => {
                            e.stopPropagation();
                            setListening(listening === c.id ? null : c.id);
                          }}
                          className="shrink-0 rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-40"
                        >
                          {listening === c.id ? <Pause className="size-4" /> : <Play className="size-4" />}
                        </button>
                      </div>

                      {listening === c.id && (
                        <div className="mt-2 flex items-center gap-2 pl-7">
                          {/* Key on the URL so changing voice/speed restarts the stream. */}
                          <audio
                            key={streamUrl(c.id)}
                            src={streamUrl(c.id)}
                            controls
                            autoPlay
                            onError={() => {
                              setListening(null);
                              setError(`Could not stream "${c.title}".`);
                            }}
                            className="h-8 min-w-0 flex-1"
                          />
                          <span className="shrink-0 text-xs text-muted-foreground">live</span>
                        </div>
                      )}
                    </li>
                  ))}
                </ul>
              </section>

              {bookJobs.map(job => (
                <JobPanel key={job.id} job={job} onCancel={() => void cancelJob(job.id)} />
              ))}
            </>
          )}
        </main>
      </div>
    </div>
  );
}

/**
 * Sits inside a Radix SelectItem, which commits a selection on pointerup — so
 * every pointer event has to be stopped for the button to be clickable.
 */
function PreviewButton({
  state,
  onPlay,
  label,
}: {
  state: PreviewState | null;
  onPlay: () => void;
  label: string;
}) {
  const stop = (e: React.SyntheticEvent) => {
    e.preventDefault();
    e.stopPropagation();
  };

  return (
    <span
      role="button"
      tabIndex={-1}
      aria-label={`Preview ${label}`}
      title={`Preview ${label}`}
      onPointerDown={stop}
      onPointerUp={stop}
      onMouseDown={stop}
      onClick={e => {
        stop(e);
        onPlay();
      }}
      onKeyDown={e => {
        if (e.key === "Enter" || e.key === " ") {
          stop(e);
          onPlay();
        }
      }}
      className="flex size-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-accent hover:text-foreground"
    >
      {state?.loading ? (
        <Loader2 className="size-3.5 animate-spin" />
      ) : state ? (
        <Pause className="size-3.5" />
      ) : (
        <Play className="size-3.5" />
      )}
    </span>
  );
}

function JobPanel({ job, onCancel }: { job: JobDTO; onCancel: () => void }) {
  const percent = job.chunksTotal > 0 ? Math.round((job.chunksDone / job.chunksTotal) * 100) : 0;
  const done = job.tracks.filter(t => t.status === "done");
  const active = ACTIVE.has(job.status);

  return (
    <section className="min-w-0 rounded-lg border">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2 border-b px-4 py-3">
        <div className="min-w-[12rem] flex-1">
          <p className="text-sm font-semibold">
            {job.provider} · {job.voice} · {job.speed}×
          </p>
          <p className="text-xs text-muted-foreground">
            {job.status === "running" && `Synthesizing… ${percent}% (${job.chunksDone}/${job.chunksTotal} chunks)`}
            {job.status === "queued" && "Queued"}
            {job.status === "done" && `Done · ${done.length} track${done.length === 1 ? "" : "s"}`}
            {job.status === "cancelled" && "Cancelled"}
            {job.status === "error" && (job.error ?? "Failed")}
          </p>
        </div>

        {active && (
          <Button variant="outline" size="sm" onClick={onCancel}>
            Cancel
          </Button>
        )}
        {done.length > 0 && (
          <Button variant="outline" size="sm" asChild>
            <a href={`/api/jobs/${job.id}/download`}>
              <Download className="size-4" /> Zip
            </a>
          </Button>
        )}
      </div>

      {active && (
        <div className="h-1 w-full bg-muted">
          <div className="h-full bg-primary transition-all" style={{ width: `${percent}%` }} />
        </div>
      )}

      <ul className="divide-y">
        {job.tracks.map(track => (
          <li key={track.id} className="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-2.5">
            <span className="w-6 shrink-0 text-xs text-muted-foreground">{track.idx + 1}</span>
            <div className="min-w-0 flex-1 basis-40">
              <p className="truncate text-sm">{track.title}</p>
              {track.error && <p className="truncate text-xs text-destructive">{track.error}</p>}
            </div>

            {track.status === "running" && <Loader2 className="size-4 animate-spin text-muted-foreground" />}
            {track.status === "pending" && <span className="text-xs text-muted-foreground">waiting</span>}
            {track.url && (
              <div className="flex min-w-0 flex-1 basis-64 items-center justify-end gap-3">
                <span className="shrink-0 text-xs tabular-nums text-muted-foreground">
                  {formatDuration(track.duration)}
                </span>
                <audio controls preload="none" src={track.url} className="h-8 min-w-0 max-w-56 flex-1" />
                <a href={track.url} download aria-label={`Download ${track.title}`}>
                  <Download className="size-4 text-muted-foreground hover:text-foreground" />
                </a>
              </div>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}

export default App;
