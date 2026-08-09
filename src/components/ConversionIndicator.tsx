import { Loader2 } from "lucide-react";
import { isActiveJob, useJobs } from "../hooks/useJobs";
import { navigate } from "../hooks/useHashRoute";

/**
 * Conversions run in the background, so the only global sign of one is this
 * chip in the app bar. Tapping it opens the book being converted.
 */
export function ConversionIndicator() {
  const { jobs } = useJobs();
  const active = jobs.filter(isActiveJob);
  if (active.length === 0) return null;

  const done = active.reduce((sum, j) => sum + j.chunksDone, 0);
  const total = active.reduce((sum, j) => sum + j.chunksTotal, 0);
  const percent = total > 0 ? Math.round((done / total) * 100) : 0;
  const first = active[0]!;
  const label =
    active.length > 1 ? `Converting ${active.length} books` : `Converting ${first.bookTitle}`;

  return (
    <button
      onClick={() => navigate({ name: "book", id: first.bookId })}
      title={`${label} — ${percent}%`}
      aria-label={`${label}, ${percent} percent. Open book.`}
      className="flex items-center gap-2 rounded-full border px-2.5 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
    >
      <Loader2 className="size-3.5 shrink-0 animate-spin text-primary" />
      <span className="hidden max-w-40 truncate sm:inline">{label}</span>
      <span className="tabular-nums">{percent}%</span>
    </button>
  );
}
