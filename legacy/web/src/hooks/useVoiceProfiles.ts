import { useCallback, useEffect, useState } from "react";
import type { VoiceProfileDTO } from "@huiver/shared";
import { api } from "../lib/api";

type VoicesResponse = {
  prompt: string;
  minSeconds: number;
  maxSeconds: number;
  voices: VoiceProfileDTO[];
};

/**
 * The Chatterbox reference clips, and the passage to read to add one.
 *
 * The passage comes from the server rather than being duplicated here so the
 * text a listener reads is always the one the built-in pack was cut against.
 */
export function useVoiceProfiles() {
  const [data, setData] = useState<VoicesResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(
    () =>
      api<VoicesResponse>("/api/voices")
        .then(setData)
        .catch((e: Error) => setError(e.message)),
    [],
  );

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const remove = useCallback(
    async (id: string) => {
      await api(`/api/voices/${encodeURIComponent(id)}`, { method: "DELETE" });
      await refresh();
    },
    [refresh],
  );

  const create = useCallback(
    async (audio: Blob, label: string, filename: string, trim?: { start: number; end: number }) => {
      const form = new FormData();
      form.append("audio", audio, filename);
      form.append("label", label);
      if (trim) {
        form.append("trimStart", String(trim.start));
        form.append("trimEnd", String(trim.end));
      }
      const profile = await api<VoiceProfileDTO>("/api/voices", { method: "POST", body: form });
      await refresh();
      return profile;
    },
    [refresh],
  );

  return {
    prompt: data?.prompt ?? "",
    minSeconds: data?.minSeconds ?? 5,
    voices: data?.voices ?? [],
    loaded: data !== null,
    error,
    clearError: () => setError(null),
    refresh,
    create,
    remove,
  };
}
