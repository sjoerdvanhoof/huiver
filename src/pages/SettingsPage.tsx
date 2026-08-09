import { AlertCircle, Monitor, Moon, Sun, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { VoicePicker } from "@/components/VoicePicker";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Slider } from "@/components/ui/slider";
import { useProviders } from "../hooks/useProviders";
import { useSettings } from "../hooks/useSettings";
import { setTheme, useTheme, type Theme } from "../hooks/useTheme";
import { STREAM_ADVANCE_KEY } from "../player/store";

export function SettingsPage() {
  const { providers, error: providersError } = useProviders();
  const { settings, loaded, update, error: settingsError, clearError } = useSettings();
  const { theme } = useTheme();
  const [error, setError] = useState<string | null>(null);

  const [speedDraft, setSpeedDraft] = useState<number | null>(null);
  useEffect(() => {
    if (loaded) setSpeedDraft(settings.defaultSpeed);
    // Only seed the slider once settings arrive; afterwards the draft is local.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loaded]);

  const provider = useMemo(
    () => providers.find(p => p.id === settings.defaultProvider),
    [providers, settings.defaultProvider],
  );

  const [streamAdvance, setStreamAdvance] = useState(() => {
    try {
      return localStorage.getItem(STREAM_ADVANCE_KEY) === "1";
    } catch {
      return false;
    }
  });

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
    <div className="mx-auto max-w-2xl space-y-6">
      <h1 className="font-serif text-2xl font-bold tracking-tight">Settings</h1>

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

      <section className="rounded-xl border bg-card p-4 sm:p-5">
        <h2 className="text-sm font-semibold">Conversion defaults</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Used for every new conversion and for streaming unconverted chapters.
        </p>

        <div className="mt-4 space-y-4">
          <div className="space-y-1.5">
            <Label>Engine</Label>
            <Select
              value={settings.defaultProvider}
              onValueChange={id => {
                update({
                  defaultProvider: id,
                  defaultVoice: providers.find(p => p.id === id)?.defaultVoice ?? null,
                });
              }}
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
              onError={setError}
            />
          </div>

          <div className="space-y-1.5">
            <div className="flex items-baseline justify-between">
              <Label>Speed</Label>
              <span className="text-xs tabular-nums text-muted-foreground">
                {(speedDraft ?? settings.defaultSpeed).toFixed(2)}×
              </span>
            </div>
            <Slider
              value={[speedDraft ?? settings.defaultSpeed]}
              onValueChange={([v]) => setSpeedDraft(v ?? 1)}
              onValueCommit={([v]) => update({ defaultSpeed: v ?? 1 })}
              min={0.5}
              max={2}
              step={0.05}
              disabled={!provider?.supportsSpeed}
              aria-label="Default speech speed"
            />
          </div>
        </div>
      </section>

      <section className="rounded-xl border bg-card p-4 sm:p-5">
        <h2 className="text-sm font-semibold">Playback</h2>

        <div className="mt-4 flex items-center justify-between gap-4">
          <div>
            <p className="text-sm">Continue into unconverted chapters</p>
            <p className="mt-0.5 text-xs text-muted-foreground">
              When a chapter ends, synthesize the next one live instead of stopping.
            </p>
          </div>
          <Toggle checked={streamAdvance} onChange={toggleStreamAdvance} label="Continue into unconverted chapters" />
        </div>
      </section>

      <section className="rounded-xl border bg-card p-4 sm:p-5">
        <h2 className="text-sm font-semibold">Appearance</h2>

        <div className="mt-4 grid grid-cols-3 gap-2">
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
