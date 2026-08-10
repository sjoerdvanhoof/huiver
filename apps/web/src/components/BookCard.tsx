import { Loader2 } from "lucide-react";
import { BookCover } from "@/components/BookCover";
import { ProgressRing, StatusIcon } from "@/components/StatusIcon";
import { href } from "../hooks/useHashRoute";
import { formatApproxDuration, formatEstimate, type BookDTO } from "@huiver/shared";

/** Library grid tile: cover, conversion badge, listening progress. */
export function BookCard({ book, converting }: { book: BookDTO; converting: boolean }) {
  const p = book.progress;
  const fullyConverted = p.conversionStatus === "full";

  return (
    <a
      href={href({ name: "book", id: book.id })}
      className="group flex flex-col gap-2.5 rounded-xl p-2 transition-colors hover:bg-accent/60 focus-visible:outline-2 focus-visible:outline-ring"
    >
      <div className="relative">
        <BookCover
          bookId={book.id}
          title={book.title}
          coverUrl={book.coverUrl}
          className="aspect-[2/3] w-full transition-shadow group-hover:shadow-lg"
        />
        {p.percentListened > 0.005 && (
          <div className="absolute inset-x-0 bottom-0 h-1 overflow-hidden rounded-b-lg bg-black/30">
            <div className="h-full bg-primary" style={{ width: `${Math.round(p.percentListened * 100)}%` }} />
          </div>
        )}
      </div>

      <div className="min-w-0 px-0.5">
        <p className="truncate text-sm font-medium leading-tight">{book.title}</p>
        {book.author && <p className="mt-0.5 truncate text-xs text-muted-foreground">{book.author}</p>}
        <p className="mt-1.5 flex items-center gap-1.5 text-xs text-muted-foreground">
          {converting ? (
            <>
              <Loader2 className="size-3.5 animate-spin text-primary" />
              <span>Converting…</span>
            </>
          ) : fullyConverted ? (
            <>
              <StatusIcon state="done" className="size-3.5" />
              <span>{formatApproxDuration(p.estimatedTotalSeconds)}</span>
            </>
          ) : p.conversionStatus === "partial" ? (
            <>
              <ProgressRing fraction={p.convertedChapters / Math.max(1, book.chapterCount)} className="size-3.5" />
              <span>
                {p.convertedChapters}/{book.chapterCount} ch · {formatEstimate(p.estimatedTotalSeconds)}
              </span>
            </>
          ) : (
            <>
              <StatusIcon state="none" className="size-3.5" />
              <span>
                {book.chapterCount} ch · {formatEstimate(p.estimatedTotalSeconds)}
              </span>
            </>
          )}
        </p>
      </div>
    </a>
  );
}
