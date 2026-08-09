import { useEffect, useRef, useSyncExternalStore } from "react";
import type { JobDTO } from "../shared";
import { api } from "../lib/api";

const ACTIVE_JOB_STATES = new Set(["queued", "running"]);

export const isActiveJob = (job: JobDTO) => ACTIVE_JOB_STATES.has(job.status);

type JobsState = { jobs: JobDTO[]; error: string | null };

/**
 * Conversions run in the background, so several views watch them at once (the
 * app bar, the library grid, the open book). One module-level poller feeds all
 * of them: it ticks every 1.5s only while something is queued or running.
 */
const POLL_MS = 1500;

let state: JobsState = { jobs: [], error: null };
let snapshot = state;
const listeners = new Set<() => void>();
/** Fires when a job leaves the queued/running states, so pages can refetch. */
const settledCallbacks = new Set<() => void>();
const lastStatus = new Map<string, string>();

let timer: ReturnType<typeof setInterval> | null = null;
let inFlight = false;

function emit(): void {
  snapshot = state;
  listeners.forEach(listener => listener());
}

async function poll(): Promise<void> {
  if (inFlight) return;
  inFlight = true;
  try {
    const jobs = await api<JobDTO[]>("/api/jobs");

    let settled = false;
    for (const job of jobs) {
      const previous = lastStatus.get(job.id);
      if (previous && previous !== job.status && !isActiveJob(job)) settled = true;
      lastStatus.set(job.id, job.status);
    }

    state = { jobs, error: null };
    emit();
    schedule();
    if (settled) settledCallbacks.forEach(callback => callback());
  } catch (error) {
    state = { ...state, error: error instanceof Error ? error.message : String(error) };
    emit();
  } finally {
    inFlight = false;
  }
}

/** Poll only while there is something to watch. */
function schedule(): void {
  const wanted = listeners.size > 0 && state.jobs.some(isActiveJob);
  if (wanted && !timer) timer = setInterval(() => void poll(), POLL_MS);
  else if (!wanted && timer) {
    clearInterval(timer);
    timer = null;
  }
}

export const reloadJobs = () => poll();

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  if (listeners.size === 1) void poll();
  return () => {
    listeners.delete(listener);
    schedule();
  };
};

export function useJobs(onJobSettled?: () => void) {
  const jobs = useSyncExternalStore(subscribe, () => snapshot);

  const callback = useRef(onJobSettled);
  callback.current = onJobSettled;
  useEffect(() => {
    const wrapper = () => callback.current?.();
    settledCallbacks.add(wrapper);
    return () => {
      settledCallbacks.delete(wrapper);
    };
  }, []);

  return { jobs: jobs.jobs, error: jobs.error, reload: reloadJobs };
}

export async function cancelJob(id: string): Promise<void> {
  await api(`/api/jobs/${id}/cancel`, { method: "POST" });
  await poll();
}
