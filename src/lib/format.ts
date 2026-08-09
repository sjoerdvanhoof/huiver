export const formatChars = (n: number) => (n >= 1000 ? `${Math.round(n / 1000)}k chars` : `${n} chars`);

/** Clock-style duration: 4:05 or 1:04:05. */
export function formatDuration(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds)) return "—";
  const total = Math.max(0, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
    : `${m}:${String(s).padStart(2, "0")}`;
}

/** Human-scale duration for totals and estimates: "42 min", "7 h 40 min". */
export function formatApproxDuration(seconds: number): string {
  const minutes = Math.round(seconds / 60);
  if (minutes < 1) return "<1 min";
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest > 0 ? `${h} h ${rest} min` : `${h} h`;
}

/** Same, with the "this is an expectation" marker for unconverted audio. */
export const formatEstimate = (seconds: number) => `~${formatApproxDuration(seconds)}`;
