import { useCallback, useEffect, useRef, useState } from "react";
import type { JobDTO } from "../shared";
import { api } from "../lib/api";

export const ACTIVE_JOB_STATES = new Set(["queued", "running"]);

/**
 * Job list with 1.5s polling while anything is queued or running. When a job
 * changes status (queued → running → done/error), `onJobSettled` fires so the
 * page can refresh book/library data and the status icons flip.
 */
export function useJobs(onJobSettled?: () => void) {
  const [jobs, setJobs] = useState<JobDTO[]>([]);
  const [error, setError] = useState<string | null>(null);
  const statuses = useRef(new Map<string, string>());
  const settled = useRef(onJobSettled);
  settled.current = onJobSettled;

  const reload = useCallback(async () => {
    try {
      const list = await api<JobDTO[]>("/api/jobs");
      setJobs(list);

      let finished = false;
      for (const job of list) {
        const previous = statuses.current.get(job.id);
        if (previous && previous !== job.status && !ACTIVE_JOB_STATES.has(job.status)) finished = true;
        statuses.current.set(job.id, job.status);
      }
      if (finished) settled.current?.();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);

  useEffect(() => {
    void reload();
  }, [reload]);

  const hasActive = jobs.some(j => ACTIVE_JOB_STATES.has(j.status));
  useEffect(() => {
    if (!hasActive) return;
    const timer = setInterval(() => void reload(), 1500);
    return () => clearInterval(timer);
  }, [hasActive, reload]);

  const cancel = useCallback(
    async (id: string) => {
      try {
        await api(`/api/jobs/${id}/cancel`, { method: "POST" });
        await reload();
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      }
    },
    [reload],
  );

  return { jobs, error, reload, cancel, hasActive, clearError: () => setError(null) };
}
