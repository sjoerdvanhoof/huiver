import { useEffect, useState } from "react";
import type { ProviderDTO } from "@huiver/shared";
import { api } from "../lib/api";

export function useProviders() {
  const [providers, setProviders] = useState<ProviderDTO[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api<ProviderDTO[]>("/api/providers")
      .then(list => !cancelled && setProviders(list))
      .catch(e => !cancelled && setError(e.message));
    return () => {
      cancelled = true;
    };
  }, []);

  return { providers, error, clearError: () => setError(null) };
}
