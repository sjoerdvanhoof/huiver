import { useCallback, useEffect, useState } from "react";
import type { ProviderDTO } from "@huiver/shared";
import { api } from "../lib/api";

export function useProviders() {
  const [providers, setProviders] = useState<ProviderDTO[]>([]);
  const [error, setError] = useState<string | null>(null);

  // Recording a voice changes what Chatterbox offers, so the list has to be
  // re-fetchable rather than read once at mount.
  const refresh = useCallback(
    () =>
      api<ProviderDTO[]>("/api/providers")
        .then(setProviders)
        .catch((e: Error) => setError(e.message)),
    [],
  );

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return { providers, error, refresh, clearError: () => setError(null) };
}
