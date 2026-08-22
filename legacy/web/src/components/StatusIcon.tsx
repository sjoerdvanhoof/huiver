import { CircleAlert, CircleCheckBig, CircleDashed, Clock, Loader2 } from "lucide-react";
import { cn } from "@/lib/utils";

export type ConversionState = "none" | "queued" | "converting" | "done" | "error";

const LABELS: Record<ConversionState, string> = {
  none: "Not converted",
  queued: "Queued for conversion",
  converting: "Converting…",
  done: "Converted — ready offline",
  error: "Conversion failed",
};

/** One icon language for "is this audio on disk yet", used everywhere. */
export function StatusIcon({
  state,
  detail,
  className,
}: {
  state: ConversionState;
  /** Extra tooltip context, e.g. an error message. */
  detail?: string | null;
  className?: string;
}) {
  const title = detail ? `${LABELS[state]}: ${detail}` : LABELS[state];
  const common = cn("size-4 shrink-0", className);

  switch (state) {
    case "none":
      return <CircleDashed className={cn(common, "text-muted-foreground/50")} aria-label={title} />;
    case "queued":
      return <Clock className={cn(common, "text-muted-foreground")} aria-label={title} />;
    case "converting":
      return <Loader2 className={cn(common, "animate-spin text-primary")} aria-label={title} />;
    case "done":
      return (
        <CircleCheckBig className={cn(common, "text-emerald-600 dark:text-emerald-400")} aria-label={title} />
      );
    case "error":
      return <CircleAlert className={cn(common, "text-destructive")} aria-label={title} />;
  }
}

/** Tiny progress ring for partially converted books (library cards). */
export function ProgressRing({ fraction, className }: { fraction: number; className?: string }) {
  const radius = 7;
  const circumference = 2 * Math.PI * radius;
  const clamped = Math.max(0, Math.min(1, fraction));

  return (
    <svg viewBox="0 0 18 18" className={cn("size-4 shrink-0", className)} aria-hidden>
      <circle cx="9" cy="9" r={radius} fill="none" strokeWidth="2.5" className="stroke-muted-foreground/25" />
      <circle
        cx="9"
        cy="9"
        r={radius}
        fill="none"
        strokeWidth="2.5"
        strokeLinecap="round"
        strokeDasharray={`${clamped * circumference} ${circumference}`}
        transform="rotate(-90 9 9)"
        className="stroke-primary"
      />
    </svg>
  );
}
