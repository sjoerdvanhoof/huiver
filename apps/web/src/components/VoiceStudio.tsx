import { Circle, Loader2, Mic, Play, Square, Trash2 } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { VOICE_PROMPT_TARGET_SECONDS } from "@huiver/shared";
import { useVoiceProfiles } from "../hooks/useVoiceProfiles";

/**
 * Making a narrator out of your own voice.
 *
 * Chatterbox clones from a single short clip, so this is the whole training
 * process: read the passage once, name it, done — there is no fine-tuning step
 * and nothing is uploaded anywhere, the recording goes to the local server and
 * stays in the data directory.
 *
 * The passage is fixed rather than free-form on purpose. It comes from the
 * server so it is the same text the downloaded voice pack was cut against,
 * which makes a bad clone a property of the recording rather than of the words.
 */

type Recording = { blob: Blob; url: string; seconds: number; extension: string };

/** Whichever container this browser will actually give us. */
function pickMimeType(): { mimeType?: string; extension: string } {
  const candidates = [
    { mimeType: "audio/webm;codecs=opus", extension: "webm" },
    { mimeType: "audio/webm", extension: "webm" },
    { mimeType: "audio/mp4", extension: "m4a" },
    { mimeType: "audio/ogg;codecs=opus", extension: "ogg" },
  ];
  for (const candidate of candidates) {
    if (MediaRecorder.isTypeSupported(candidate.mimeType)) return candidate;
  }
  // Let the browser choose; ffmpeg sniffs the container on the way in anyway.
  return { extension: "bin" };
}

export function VoiceStudio({
  onChanged,
  onError,
}: {
  /** A voice was added or removed, so the engine's voice list has moved on. */
  onChanged: (event: { created?: string; deleted?: string }) => void;
  onError: (message: string) => void;
}) {
  const { prompt, minSeconds, voices, create, remove, error, clearError } = useVoiceProfiles();

  const [recording, setRecording] = useState<Recording | null>(null);
  const [active, setActive] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [busy, setBusy] = useState(false);
  const [label, setLabel] = useState("");

  const recorder = useRef<MediaRecorder | null>(null);
  const stream = useRef<MediaStream | null>(null);
  const startedAt = useRef(0);
  const supported = typeof MediaRecorder !== "undefined" && Boolean(navigator.mediaDevices?.getUserMedia);

  useEffect(() => {
    if (error) {
      onError(error);
      clearError();
    }
  }, [error, onError, clearError]);

  const releaseMic = useCallback(() => {
    stream.current?.getTracks().forEach(track => track.stop());
    stream.current = null;
  }, []);

  // Never leave the microphone open, or the recording indicator on, behind us.
  useEffect(() => releaseMic, [releaseMic]);

  const discard = useCallback(() => {
    setRecording(current => {
      if (current) URL.revokeObjectURL(current.url);
      return null;
    });
  }, []);

  const start = useCallback(async () => {
    discard();
    setElapsed(0);

    let media: MediaStream;
    try {
      media = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });
    } catch {
      onError("Could not use the microphone. Check the site's permissions and try again.");
      return;
    }

    const { mimeType, extension } = pickMimeType();
    const started = new MediaRecorder(media, mimeType ? { mimeType } : undefined);
    const parts: Blob[] = [];

    started.addEventListener("dataavailable", event => {
      if (event.data.size > 0) parts.push(event.data);
    });
    started.addEventListener("stop", () => {
      const seconds = (Date.now() - startedAt.current) / 1000;
      const blob = new Blob(parts, { type: started.mimeType || "application/octet-stream" });
      releaseMic();
      recorder.current = null;
      setActive(false);
      setRecording({ blob, url: URL.createObjectURL(blob), seconds, extension });
    });

    stream.current = media;
    recorder.current = started;
    startedAt.current = Date.now();
    started.start();
    setActive(true);
  }, [discard, onError, releaseMic]);

  const stop = useCallback(() => recorder.current?.stop(), []);

  // Drive the running timer while, and only while, the recorder is running.
  useEffect(() => {
    if (!active) return;
    const timer = setInterval(() => setElapsed((Date.now() - startedAt.current) / 1000), 100);
    return () => clearInterval(timer);
  }, [active]);

  const save = useCallback(async () => {
    if (!recording) return;
    setBusy(true);
    try {
      const created = await create(recording.blob, label.trim() || "My voice", `voice.${recording.extension}`);
      discard();
      setLabel("");
      onChanged({ created: created.id });
    } catch (failure) {
      onError(failure instanceof Error ? failure.message : "Could not save that voice");
    } finally {
      setBusy(false);
    }
  }, [recording, label, create, discard, onChanged, onError]);

  const deleteVoice = useCallback(
    async (id: string, name: string) => {
      if (!confirm(`Delete "${name}"? Chapters already converted keep their audio.`)) return;
      try {
        await remove(id);
        onChanged({ deleted: id });
      } catch (failure) {
        onError(failure instanceof Error ? failure.message : "Could not delete that voice");
      }
    },
    [remove, onChanged, onError],
  );

  const recorded = voices.filter(voice => voice.kind === "recorded");
  const tooShort = recording !== null && recording.seconds < minSeconds;

  return (
    <div className="space-y-4">
      <div>
        <h3 className="text-sm font-semibold">Your own voice</h3>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Read the passage once and Chatterbox will narrate in your voice. The recording stays on this machine.
        </p>
      </div>

      {!supported ? (
        <p className="text-xs text-muted-foreground">
          This browser cannot record audio. Try Chrome, Firefox or Safari over https or localhost.
        </p>
      ) : (
        <>
          <blockquote className="rounded-md border-l-2 border-primary/50 bg-muted/40 py-2.5 pr-3 pl-3 font-serif text-sm leading-relaxed">
            {prompt || "…"}
          </blockquote>

          <div className="flex items-center gap-2">
            {active ? (
              <Button onClick={stop} variant="destructive" size="sm">
                <Square className="size-3.5 fill-current" />
                Stop
              </Button>
            ) : (
              <Button onClick={start} variant={recording ? "outline" : "default"} size="sm" disabled={busy}>
                <Mic className="size-3.5" />
                {recording ? "Record again" : "Record"}
              </Button>
            )}

            {active && (
              <span className="flex items-center gap-1.5 text-xs tabular-nums text-muted-foreground">
                <Circle className="size-2.5 animate-pulse fill-destructive text-destructive" />
                {elapsed.toFixed(1)}s
                <span className="text-muted-foreground/60">/ about {VOICE_PROMPT_TARGET_SECONDS}s</span>
              </span>
            )}

            {recording && !active && (
              <span className={`text-xs tabular-nums ${tooShort ? "text-destructive" : "text-muted-foreground"}`}>
                {recording.seconds.toFixed(1)}s recorded
                {tooShort && ` — needs at least ${minSeconds}s`}
              </span>
            )}
          </div>

          {recording && !active && (
            <div className="space-y-3 rounded-md border p-3">
              {/* Hearing it back before saving catches the clipped, the mumbled
                  and the interrupted, none of which the clone recovers from. */}
              <audio src={recording.url} controls className="h-9 w-full" />

              <div className="space-y-1.5">
                <Label htmlFor="voice-label">Name this voice</Label>
                <Input
                  id="voice-label"
                  value={label}
                  onChange={event => setLabel(event.target.value)}
                  placeholder="My voice"
                  maxLength={60}
                />
              </div>

              <div className="flex gap-2">
                <Button onClick={save} size="sm" disabled={busy || tooShort}>
                  {busy ? <Loader2 className="size-3.5 animate-spin" /> : null}
                  Save voice
                </Button>
                <Button onClick={discard} variant="ghost" size="sm" disabled={busy}>
                  Discard
                </Button>
              </div>
            </div>
          )}
        </>
      )}

      {recorded.length > 0 && (
        <div className="space-y-1.5">
          <Label>Voices you recorded</Label>
          <ul className="divide-y rounded-md border">
            {recorded.map(voice => (
              <li key={voice.id} className="flex items-center gap-2 px-3 py-2">
                <span className="flex-1 truncate text-sm">{voice.label}</span>
                <span className="text-xs tabular-nums text-muted-foreground">{voice.seconds.toFixed(0)}s</span>
                <ClipButton id={voice.id} label={voice.label} />
                <button
                  onClick={() => void deleteVoice(voice.id, voice.label)}
                  aria-label={`Delete ${voice.label}`}
                  title={`Delete ${voice.label}`}
                  className="rounded p-1 text-muted-foreground hover:bg-accent hover:text-destructive"
                >
                  <Trash2 className="size-3.5" />
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

/** Plays the reference clip itself — what the model hears, not a synthesis. */
function ClipButton({ id, label }: { id: string; label: string }) {
  const audio = useRef<HTMLAudioElement | null>(null);
  const [playing, setPlaying] = useState(false);

  useEffect(() => () => audio.current?.pause(), []);

  return (
    <button
      onClick={() => {
        if (playing) {
          audio.current?.pause();
          setPlaying(false);
          return;
        }
        const element = new Audio(`/api/voices/${encodeURIComponent(id)}/clip`);
        audio.current = element;
        element.addEventListener("ended", () => setPlaying(false));
        element.addEventListener("error", () => setPlaying(false));
        void element.play().then(() => setPlaying(true)).catch(() => setPlaying(false));
      }}
      aria-label={`Play the recording for ${label}`}
      title={`Play the recording for ${label}`}
      className="rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
    >
      {playing ? <Square className="size-3.5 fill-current" /> : <Play className="size-3.5" />}
    </button>
  );
}
