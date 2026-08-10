import { useCallback, useEffect, useState } from "react";
import type { BookDetailDTO } from "@huiver/shared";
import { api } from "../lib/api";

export function useBookDetail(bookId: string) {
  const [book, setBook] = useState<BookDetailDTO | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    try {
      setBook(await api<BookDetailDTO>(`/api/books/${bookId}`));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [bookId]);

  useEffect(() => {
    setBook(null);
    setError(null);
    void reload();
  }, [reload]);

  return { book, error, reload, clearError: () => setError(null) };
}
