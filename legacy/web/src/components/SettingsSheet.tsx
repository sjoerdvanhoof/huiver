import { AlertCircle, Monitor, Moon, Sun, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { VoicePicker } from "@/components/VoicePicker";
import { VoiceStudio } from "@/components/VoiceStudio";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useProviders } from "../hooks/useProviders";
import { useSettings } from "../hooks/useSettings";
import { setTheme, useTheme, type Theme } from "../hooks/useTheme";
import { STREAM_ADVANCE_KEY, pause } from "../player/store";

/**
 * There are few enough settings to fit beside whatever you were doing, so this
 * slides in from the right instead of being a page you have to navigate back
 * from.
 */
export function SettingsSheet({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { providers, error: providersError, refresh: refreshProviders } = useProviders();
  const { settings, update, error: settingsError, clearError } = useSettings();
  const { theme } = useTheme();
  const [error, setError] = useState<string | null>(null);

  const provider = useMemo(
    () => providers.find(p => p.id === settings.defaultProvider),
    [providers, settings.defaultProvider],
  );

  // Chatterbox is the one engine whose voice list the user can change from
  // here, and every change moves the list the picker is reading from.
  const chatterbox = providers.find(p => p.id === "chatterbox");

  const onVoicesChanged = useCallback(
    async ({ created, deleted }: { created?: string; deleted?: string }) => {
      await refreshProviders();
      if (created) update({ defaultProvider: "chatterbox", defaultVoice: created });
      // Leaving a deleted voice selected would fail at the next conversion.
      else if (deleted && settings.defaultVoice === deleted) update({ defaultVoice: null });
    },
    [refreshProviders, update, settings.defaultVoice],
  );

  const [streamAdvance, setStreamAdvance] = useState(() => {
    try {
      return localStorage.getItem(STREAM_ADVANCE_KEY) === "1";
    } catch {
      return false;
    }
  });

  useEffect(() => {
    if (!open) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  if (!open) return null;

  const toggleStreamAdvance = () => {
    const value = !streamAdvance;
    setStreamAdvance(value);
    try {
      localStorage.setItem(STREAM_ADVANCE_KEY, value ? "1" : "0");
    } catch {
      // Best effort.
    }
  };

  const shownError = error ?? settingsError ?? providersError;

  return (
    <div className="fixed inset-0 z-50 flex justify-end">
      <div className="absolute inset-0 bg-black/40 backdrop-blur-[2px]" onClick={onClose} aria-hidden />

      <aside
        role="dialog"
        aria-modal="true"
        aria-label="Settings"
        className="relative flex h-full w-full max-w-sm flex-col border-l bg-background shadow-2xl duration-300 animate-in slide-in-from-right"
      >
        <div className="flex items-center justify-between border-b px-4 py-3">
          <h2 className="font-serif text-lg font-bold tracking-tight">Settings</h2>
          <button
            onClick={onClose}
            aria-label="Close settings"
            className="-mr-1 rounded-full p-2 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
          >
            <X className="size-5" />
          </button>
        </div>

        <div className="flex-1 space-y-6 overflow-y-auto px-4 py-5 pb-[max(1.25rem,env(safe-area-inset-bottom))]">
          {shownError && (
            <div className="flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
              <AlertCircle className="mt-0.5 size-4 shrink-0 text-destructive" />
              <span className="flex-1">{shownError}</span>
              <button
                onClick={() => {
                  setError(null);
                  clearError();
                }}
                aria-label="Dismiss error"
              >
                <X className="size-4" />
              </button>
            </div>
          )}

          <section className="space-y-4">
            <div>
              <h3 className="text-sm font-semibold">Voice</h3>
              <p className="mt-0.5 text-xs text-muted-foreground">
                Used for every new conversion and for streaming unconverted chapters.
              </p>
            </div>

            <div className="space-y-1.5">
              <Label>Engine</Label>
              <Select
                value={settings.defaultProvider}
                onValueChange={id =>
                  update({
                    defaultProvider: id,
                    defaultVoice: providers.find(p => p.id === id)?.defaultVoice ?? null,
                  })
                }
              >
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {providers.map(p => (
                    <SelectItem key={p.id} value={p.id} disabled={!p.available}>
                      {p.label}
                      {!p.available && " (unavailable)"}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {provider && !provider.available && (
                <p className="text-xs text-muted-foreground">{provider.reason}</p>
              )}
            </div>

            <div className="space-y-1.5">
              <Label>Voice</Label>
              <VoicePicker
                provider={provider}
                voice={settings.defaultVoice ?? provider?.defaultVoice ?? ""}
                onVoiceChange={v => update({ defaultVoice: v })}
                onPreviewStart={pause}
                onError={setError}
              />
            </div>
          </section>

          {chatterbox && (
            <section className="border-t pt-5">
              <VoiceStudio onChanged={onVoicesChanged} onError={setError} />
            </section>
          )}

          <section className="space-y-3 border-t pt-5">
            <h3 className="text-sm font-semibold">Playback</h3>

            <div className="flex items-center justify-between gap-4">
              <div>
                <p className="text-sm">Continue into unconverted chapters</p>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  When a chapter ends, synthesize the next one live instead of stopping.
                </p>
              </div>
              <Toggle
                checked={streamAdvance}
                onChange={toggleStreamAdvance}
                label="Continue into unconverted chapters"
              />
            </div>

            <p className="text-xs text-muted-foreground">
              Audio is always converted at normal speed — set listening speed in the player.
            </p>
          </section>

          <section className="space-y-3 border-t pt-5">
            <h3 className="text-sm font-semibold">Appearance</h3>

            <div className="grid grid-cols-3 gap-2">
              {(
                [
                  { value: "system", label: "System", icon: Monitor },
                  { value: "light", label: "Light", icon: Sun },
                  { value: "dark", label: "Dark", icon: Moon },
                ] as { value: Theme; label: string; icon: typeof Sun }[]
              ).map(({ value, label, icon: Icon }) => (
                <button
                  key={value}
                  onClick={() => {
                    setTheme(value);
                    update({ theme: value });
                  }}
                  aria-pressed={theme === value}
                  className={`flex flex-col items-center gap-1.5 rounded-lg border p-3 text-xs transition-colors ${
                    theme === value
                      ? "border-primary bg-primary/5 text-foreground"
                      : "text-muted-foreground hover:bg-accent"
                  }`}
                >
                  <Icon className="size-4" />
                  {label}
                </button>
              ))}
            </div>
          </section>
        </div>
      </aside>
    </div>
  );
}

function Toggle({ checked, onChange, label }: { checked: boolean; onChange: () => void; label: string }) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      aria-label={label}
      onClick={onChange}
      className={`relative h-6 w-11 shrink-0 rounded-full transition-colors ${
        checked ? "bg-primary" : "bg-muted-foreground/30"
      }`}
    >
      <span
        className={`absolute top-0.5 size-5 rounded-full bg-white shadow transition-[left] ${
          checked ? "left-[calc(100%-1.375rem)]" : "left-0.5"
        }`}
      />
    </button>
  );
}
