import { Loader2, Upload } from "lucide-react";
import { useRef, useState } from "react";
import { cn } from "@/lib/utils";

/** Drag/drop or click-to-pick book importer. */
export function UploadDropzone({
  uploading,
  onFiles,
  compact = false,
  className,
}: {
  uploading: boolean;
  onFiles: (files: FileList | null) => void;
  /** Tile-sized variant for a library that already has books. */
  compact?: boolean;
  className?: string;
}) {
  const [dragging, setDragging] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  return (
    <div
      role="button"
      tabIndex={0}
      aria-label="Add a book"
      onDragOver={e => {
        e.preventDefault();
        setDragging(true);
      }}
      onDragLeave={() => setDragging(false)}
      onDrop={e => {
        e.preventDefault();
        setDragging(false);
        onFiles(e.dataTransfer.files);
      }}
      onClick={() => fileInput.current?.click()}
      onKeyDown={e => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          fileInput.current?.click();
        }
      }}
      className={cn(
        "cursor-pointer rounded-xl border-2 border-dashed text-center transition-colors",
        compact ? "flex flex-col items-center justify-center gap-1 p-4" : "p-10",
        dragging ? "border-primary bg-primary/5" : "border-muted-foreground/25 hover:border-primary/50",
        className,
      )}
    >
      {uploading ? (
        <Loader2 className={cn("mx-auto text-muted-foreground animate-spin", compact ? "size-5" : "mb-2 size-6")} />
      ) : (
        <Upload className={cn("mx-auto text-muted-foreground", compact ? "size-5" : "mb-2 size-6")} />
      )}
      <p className={cn("font-medium", compact ? "text-xs" : "text-sm")}>
        {uploading ? "Reading…" : compact ? "Add book" : "Drop a book here"}
      </p>
      {!compact && <p className="mt-1 text-xs text-muted-foreground">epub · txt · md · html</p>}
      <input
        ref={fileInput}
        type="file"
        multiple
        accept=".epub,.zip,.txt,.md,.markdown,.html,.htm,.xhtml"
        className="hidden"
        onChange={e => {
          onFiles(e.target.files);
          e.target.value = "";
        }}
        onClick={e => e.stopPropagation()}
      />
    </div>
  );
}
