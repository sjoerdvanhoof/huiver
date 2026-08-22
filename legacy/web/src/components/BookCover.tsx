import { useState } from "react";
import { COVER_GRADIENTS, coverIndex, coverInitial } from "@huiver/shared";
import { cn } from "@/lib/utils";

/**
 * A book cover that never looks broken: the real cover image when the EPUB
 * has one, otherwise a deterministic gradient with the title's initial.
 */
export function BookCover({
  bookId,
  title,
  coverUrl,
  className,
}: {
  bookId: string;
  title: string;
  coverUrl: string | null;
  className?: string;
}) {
  const [failed, setFailed] = useState(false);
  const [from, to] = COVER_GRADIENTS[coverIndex(bookId)]!;

  return (
    <div
      className={cn(
        "relative shrink-0 select-none overflow-hidden rounded-lg shadow-md ring-1 ring-black/10 dark:ring-white/10",
        className,
      )}
      style={{ backgroundImage: `linear-gradient(135deg, ${from}, ${to})` }}
    >
      {coverUrl && !failed ? (
        <img
          src={coverUrl}
          alt=""
          loading="lazy"
          onError={() => setFailed(true)}
          className="absolute inset-0 size-full object-cover"
        />
      ) : (
        <>
          {/* SVG so the initial scales with the cover, from thumbnail to hero. */}
          <svg viewBox="0 0 100 150" className="absolute inset-0 size-full" aria-hidden>
            <text
              x="50"
              y="75"
              textAnchor="middle"
              dominantBaseline="central"
              fontSize="64"
              fontFamily="Georgia, 'Iowan Old Style', serif"
              fill="rgba(255,255,255,0.35)"
            >
              {coverInitial(title)}
            </text>
          </svg>
          {/* Spine highlight, for a hint of physicality. */}
          <span className="absolute inset-y-0 left-0 w-[6%] bg-white/10" />
        </>
      )}
      <span className="pointer-events-none absolute inset-0 rounded-lg shadow-[inset_0_1px_0_rgba(255,255,255,0.15)]" />
    </div>
  );
}
