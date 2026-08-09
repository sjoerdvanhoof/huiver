import { Loader2, Pause, Play } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { ProviderDTO } from "../shared";

type PreviewState = { voice: string; loading: boolean };

/**
 * Voice dropdown with an inline preview button per voice. Previews use their
 * own Audio element so they never disturb the main player; callers can pass
 * `onPreviewStart` to pause it while a preview runs.
 */
export function VoicePicker({
  provider,
  voice,
  onVoiceChange,
  onPreviewStart,
  onError,
}: {
  provider: ProviderDTO | undefined;
  voice: string;
  onVoiceChange: (voice: string) => void;
  onPreviewStart?: () => void;
  onError?: (message: string) => void;
}) {
  const [preview, setPreview] = useState<PreviewState | null>(null);
  const previewAudio = useRef<HTMLAudioElement | null>(null);

  // Stop any preview when the component goes away.
  useEffect(() => () => previewAudio.current?.pause(), []);

  const playPreview = useCallback(
    (voiceId: string) => {
      previewAudio.current?.pause();

      // Clicking the voice that is already playing just stops it.
      if (preview?.voice === voiceId) {
        setPreview(null);
        return;
      }
      if (!provider) return;

      onPreviewStart?.();
      const audio = new Audio(`/api/providers/${provider.id}/preview?voice=${encodeURIComponent(voiceId)}`);
      previewAudio.current = audio;
      setPreview({ voice: voiceId, loading: true });

      audio.addEventListener("playing", () => setPreview({ voice: voiceId, loading: false }));
      audio.addEventListener("ended", () => setPreview(null));
      audio.addEventListener("error", () => {
        setPreview(null);
        onError?.(`Could not preview ${voiceId}. The first preview of a voice takes a few seconds.`);
      });
      void audio.play().catch(() => setPreview(null));
    },
    [provider, preview, onPreviewStart, onError],
  );

  return (
    <Select value={voice} onValueChange={onVoiceChange} disabled={!provider?.voices.length}>
      <SelectTrigger className="w-full">
        <SelectValue placeholder="No voices" />
      </SelectTrigger>
      <SelectContent>
        {provider?.voices.map(v => (
          <SelectItem
            key={v.id}
            value={v.id}
            leading={
              <PreviewButton
                state={preview?.voice === v.id ? preview : null}
                onPlay={() => playPreview(v.id)}
                label={v.label}
              />
            }
          >
            {v.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

/**
 * Sits inside a Radix SelectItem, which commits a selection on pointerup — so
 * every pointer event has to be stopped for the button to be clickable.
 */
function PreviewButton({
  state,
  onPlay,
  label,
}: {
  state: PreviewState | null;
  onPlay: () => void;
  label: string;
}) {
  const stop = (e: React.SyntheticEvent) => {
    e.preventDefault();
    e.stopPropagation();
  };

  return (
    <span
      role="button"
      tabIndex={-1}
      aria-label={`Preview ${label}`}
      title={`Preview ${label}`}
      onPointerDown={stop}
      onPointerUp={stop}
      onMouseDown={stop}
      onClick={e => {
        stop(e);
        onPlay();
      }}
      onKeyDown={e => {
        if (e.key === "Enter" || e.key === " ") {
          stop(e);
          onPlay();
        }
      }}
      className="flex size-6 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-accent hover:text-foreground"
    >
      {state?.loading ? (
        <Loader2 className="size-3.5 animate-spin" />
      ) : state ? (
        <Pause className="size-3.5" />
      ) : (
        <Play className="size-3.5" />
      )}
    </span>
  );
}
