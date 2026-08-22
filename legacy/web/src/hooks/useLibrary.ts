import { useCallback, useEffect, useState } from "react";
import type { BookDTO } from "@huiver/shared";
import { api } from "../lib/api";

export function useLibrary() {
  const [books, setBooks] = useState<BookDTO[] | null>(null);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    try {
      setBooks(await api<BookDTO[]>("/api/books"));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);

  useEffect(() => {
    void reload();
  }, [reload]);

  /** Returns the id of the last imported book so callers can navigate to it. */
  const upload = useCallback(
    async (files: FileList | File[] | null): Promise<string | null> => {
      if (!files || files.length === 0) return null;
      setUploading(true);
      setError(null);
      let lastId: string | null = null;
      try {
        for (const file of Array.from(files)) {
          const form = new FormData();
          form.append("file", file);
          const created = await api<BookDTO>("/api/books", { method: "POST", body: form });
          lastId = created.id;
        }
        await reload();
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        setUploading(false);
      }
      return lastId;
    },
    [reload],
  );

  const removeBook = useCallback(
    async (id: string) => {
      try {
        await api(`/api/books/${id}`, { method: "DELETE" });
        await reload();
        return true;
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
        return false;
      }
    },
    [reload],
  );

  return { books, uploading, error, reload, upload, removeBook, clearError: () => setError(null) };
}
