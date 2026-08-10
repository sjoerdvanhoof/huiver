import { ArrowDown, Check, RotateCw, Square } from "lucide-react";
import { cn } from "@/lib/utils";

export type ChapterActionState = "none" | "queued" | "converting" | "done" | "error";

const RADIUS = 14;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

/**
 * The download control from a podcast app, in one 32px circle: an arrow to
 * convert, a ring that fills while it renders, a filled check when the audio
 * is on disk. The ring doubles as the cancel button for single-chapter runs.
 */
export function ChapterAction({
  state,
  progress,
  onConvert,
  onCancel,
  disabled,
  detail,
  className,
}: {
  state: ChapterActionState;
  /** 0–1 while converting; null when the share of a bigger run is unknown. */
  progress?: number | null;
  onConvert: () => void;
  onCancel?: () => void;
  disabled?: boolean;
  detail?: string | null;
  className?: string;
}) {
  const base = "flex size-8 shrink-0 items-center justify-center rounded-full transition-colors";

  if (state === "done") {
    return (
      <span
        role="img"
        aria-label="Converted — available offline"
        title="Converted — available offline"
        className={cn(base, "bg-emerald-600 text-white dark:bg-emerald-500 dark:text-emerald-950", className)}
      >
        <Check className="size-4" strokeWidth={3} />
      </span>
    );
  }

  if (state === "error") {
    return (
      <button
        onClick={onConvert}
        disabled={disabled}
        aria-label={`Conversion failed${detail ? `: ${detail}` : ""}. Try again`}
        title={detail ? `Failed: ${detail} — click to retry` : "Conversion failed — click to retry"}
        className={cn(
          base,
          "border-2 border-destructive text-destructive hover:bg-destructive/10 disabled:opacity-40",
          className,
        )}
      >
        <RotateCw className="size-3.5" />
      </button>
    );
  }

  if (state === "queued" || state === "converting") {
    const fraction = state === "converting" ? (progress ?? null) : 0;
    const label =
      state === "queued"
        ? "Queued for conversion"
        : `Converting${fraction !== null ? ` — ${Math.round(fraction * 100)}%` : "…"}`;

    return (
      <button
        onClick={onCancel}
        disabled={!onCancel}
        aria-label={onCancel ? `${label}. Click to stop` : label}
        title={onCancel ? `${label} — click to stop` : label}
        className={cn(base, "relative text-muted-foreground", onCancel && "hover:text-foreground", className)}
      >
        <svg viewBox="0 0 32 32" className={cn("absolute inset-0 size-8", fraction === null && "animate-spin")}>
          <circle cx="16" cy="16" r={RADIUS} fill="none" strokeWidth="2" className="stroke-muted-foreground/25" />
          <circle
            cx="16"
            cy="16"
            r={RADIUS}
            fill="none"
            strokeWidth="2"
            strokeLinecap="round"
            // A determinate arc, or a short spinning one while the share is unknown.
            strokeDasharray={`${(fraction ?? 0.22) * CIRCUMFERENCE} ${CIRCUMFERENCE}`}
            transform="rotate(-90 16 16)"
            className="stroke-primary transition-[stroke-dasharray]"
          />
        </svg>
        <Square className="size-2.5 fill-current" />
      </button>
    );
  }

  return (
    <button
      onClick={onConvert}
      disabled={disabled}
      aria-label="Convert this chapter"
      title={disabled ? "The speech engine is unavailable" : "Convert this chapter"}
      className={cn(
        base,
        "border-2 border-muted-foreground/30 text-muted-foreground",
        "hover:border-primary hover:text-primary disabled:opacity-40 disabled:hover:border-muted-foreground/30 disabled:hover:text-muted-foreground",
        className,
      )}
    >
      <ArrowDown className="size-4" strokeWidth={2.5} />
    </button>
  );
}
