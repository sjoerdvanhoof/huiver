import { AlertCircle, Play, X } from "lucide-react";
import { useMemo } from "react";
import { BookCard } from "@/components/BookCard";
import { BookCover } from "@/components/BookCover";
import { UploadDropzone } from "@/components/UploadDropzone";
import { isActiveJob, useJobs } from "../hooks/useJobs";
import { navigate } from "../hooks/useHashRoute";
import { useLibrary } from "../hooks/useLibrary";
import { useSettings } from "../hooks/useSettings";
import { playResume } from "../player/restore";
import { formatApproxDuration, type BookDTO } from "@huiver/shared";

export function LibraryPage() {
  const { books, uploading, error, reload, upload, clearError } = useLibrary();
  const { settings } = useSettings();
  const { jobs } = useJobs(() => void reload());

  const convertingBooks = useMemo(() => new Set(jobs.filter(isActiveJob).map(j => j.bookId)), [jobs]);

  const continueListening = useMemo(
    () =>
      (books ?? [])
        .filter(b => b.progress.lastPlayedAt !== null && b.progress.resume)
        .sort((a, b) => (b.progress.lastPlayedAt ?? 0) - (a.progress.lastPlayedAt ?? 0))
        .slice(0, 6),
    [books],
  );

  const onUpload = async (files: FileList | null) => {
    const lastId = await upload(files);
    if (lastId) navigate({ name: "book", id: lastId });
  };

  return (
    <div className="space-y-8">
      {error && (
        <div className="flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
          <AlertCircle className="mt-0.5 size-4 shrink-0 text-destructive" />
          <span className="flex-1">{error}</span>
          <button onClick={clearError} aria-label="Dismiss error">
            <X className="size-4" />
          </button>
        </div>
      )}

      {continueListening.length > 0 && (
        <section>
          <h2 className="mb-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Continue listening
          </h2>
          <div className="scrollbar-none -mx-4 flex gap-3 overflow-x-auto px-4 sm:mx-0 sm:px-0">
            {continueListening.map(book => (
              <ContinueCard key={book.id} book={book} onPlay={() => playResume(book, settings)} />
            ))}
          </div>
        </section>
      )}

      <section>
        <h2 className="mb-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          Library{books ? ` (${books.length})` : ""}
        </h2>

        {books && books.length === 0 ? (
          <UploadDropzone uploading={uploading} onFiles={f => void onUpload(f)} className="py-16" />
        ) : (
          <div className="grid grid-cols-2 gap-x-3 gap-y-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
            {(books ?? []).map(book => (
              <BookCard key={book.id} book={book} converting={convertingBooks.has(book.id)} />
            ))}
            {books && (
              <UploadDropzone
                uploading={uploading}
                onFiles={f => void onUpload(f)}
                compact
                className="m-2 aspect-[2/3] w-auto self-start"
              />
            )}
          </div>
        )}
      </section>
    </div>
  );
}

/** One "pick it back up" card: cover, where you were, one-tap resume. */
function ContinueCard({ book, onPlay }: { book: BookDTO; onPlay: () => void }) {
  const resume = book.progress.resume!;
  const chapterProgress =
    resume.durationSeconds && resume.durationSeconds > 0
      ? Math.min(1, resume.positionSeconds / resume.durationSeconds)
      : 0;
  const remaining =
    resume.durationSeconds !== null
      ? Math.max(0, resume.durationSeconds - resume.positionSeconds)
      : null;

  return (
    <div className="relative w-64 shrink-0 rounded-xl border bg-card p-3 shadow-sm transition-shadow hover:shadow-md">
      <div className="flex gap-3">
        <button
          onClick={onPlay}
          aria-label={`Resume ${book.title}`}
          className="group relative shrink-0 rounded-lg focus-visible:outline-2 focus-visible:outline-ring"
        >
          <BookCover bookId={book.id} title={book.title} coverUrl={book.coverUrl} className="h-24 w-16" />
          <span className="absolute inset-0 flex items-center justify-center rounded-lg bg-black/35 opacity-90 transition-opacity group-hover:opacity-100">
            <span className="flex size-9 items-center justify-center rounded-full bg-primary text-primary-foreground shadow">
              <Play className="size-4 translate-x-px" />
            </span>
          </span>
        </button>

        <button
          onClick={() => navigate({ name: "book", id: book.id })}
          className="min-w-0 flex-1 text-left"
          aria-label={`Open ${book.title}`}
        >
          <p className="truncate text-sm font-medium">{book.title}</p>
          <p className="mt-0.5 truncate text-xs text-muted-foreground">
            Ch. {resume.chapterIdx + 1} · {resume.chapterTitle}
          </p>
          <div className="mt-2 h-1 overflow-hidden rounded-full bg-muted">
            <div className="h-full bg-primary" style={{ width: `${Math.round(chapterProgress * 100)}%` }} />
          </div>
          <p className="mt-1 text-xs tabular-nums text-muted-foreground">
            {remaining !== null ? `${formatApproxDuration(remaining)} left in chapter` : "Not converted yet"}
          </p>
        </button>
      </div>
    </div>
  );
}
