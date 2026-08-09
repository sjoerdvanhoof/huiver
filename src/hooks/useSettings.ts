import { useCallback, useEffect, useState } from "react";
import type { SettingsDTO } from "../shared";
import { api } from "../lib/api";

const DEFAULTS: SettingsDTO = {
  defaultProvider: "kokoro",
  defaultVoice: null,
  theme: "system",
};

/** Server-persisted defaults (engine, voice, speed, theme) with optimistic writes. */
export function useSettings() {
  const [settings, setSettings] = useState<SettingsDTO>(DEFAULTS);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api<SettingsDTO>("/api/settings")
      .then(s => {
        if (cancelled) return;
        setSettings(s);
        setLoaded(true);
      })
      .catch(e => !cancelled && setError(e.message));
    return () => {
      cancelled = true;
    };
  }, []);

  const update = useCallback((patch: Partial<SettingsDTO>) => {
    setSettings(prev => ({ ...prev, ...patch })); // optimistic
    api<SettingsDTO>("/api/settings", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(patch),
    })
      .then(setSettings)
      .catch(e => setError(e.message));
  }, []);

  return { settings, loaded, error, update, clearError: () => setError(null) };
}
