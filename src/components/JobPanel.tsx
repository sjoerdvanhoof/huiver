import { Download, Loader2, Play } from "lucide-react";
import { Button } from "@/components/ui/button";
import { formatDuration } from "@/lib/format";
import { ACTIVE_JOB_STATES } from "../hooks/useJobs";
import type { JobDTO } from "../shared";

/** One conversion run: progress, per-track status, zip download. */
export function JobPanel({
  job,
  onCancel,
  onPlayChapter,
}: {
  job: JobDTO;
  onCancel: () => void;
  /** Open a finished track in the global player. */
  onPlayChapter?: (chapterId: string) => void;
}) {
  const percent = job.chunksTotal > 0 ? Math.round((job.chunksDone / job.chunksTotal) * 100) : 0;
  const done = job.tracks.filter(t => t.status === "done");
  const active = ACTIVE_JOB_STATES.has(job.status);

  return (
    <section className="min-w-0 overflow-hidden rounded-xl border bg-card">
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
          <li key={track.id} className="flex items-center gap-3 px-4 py-2.5">
            <span className="w-6 shrink-0 text-xs tabular-nums text-muted-foreground">{track.idx + 1}</span>
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm">{track.title}</p>
              {track.error && <p className="truncate text-xs text-destructive">{track.error}</p>}
            </div>

            {track.status === "running" && <Loader2 className="size-4 shrink-0 animate-spin text-primary" />}
            {track.status === "pending" && <span className="shrink-0 text-xs text-muted-foreground">waiting</span>}
            {track.status === "done" && (
              <div className="flex shrink-0 items-center gap-2">
                <span className="text-xs tabular-nums text-muted-foreground">{formatDuration(track.duration)}</span>
                {onPlayChapter && (
                  <button
                    onClick={() => onPlayChapter(track.chapterId)}
                    aria-label={`Play ${track.title}`}
                    className="rounded-full p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                  >
                    <Play className="size-4" />
                  </button>
                )}
                {track.url && (
                  <a
                    href={track.url}
                    download
                    aria-label={`Download ${track.title}`}
                    className="rounded-full p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                  >
                    <Download className="size-4" />
                  </a>
                )}
              </div>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
