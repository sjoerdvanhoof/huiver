import { Circle, Loader2, Mic, Play, Square, Trash2, Upload } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Slider } from "@/components/ui/slider";
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

type Recording = { blob: Blob; url: string; seconds: number; filename: string; uploaded: boolean };

const formatTime = (seconds: number) => {
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${(seconds % 60).toFixed(1).padStart(4, "0")}`;
};

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
  const [trim, setTrim] = useState<[number, number] | null>(null);
  const uploadInput = useRef<HTMLInputElement | null>(null);

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
    setTrim(null);
  }, []);

  const useFile = useCallback((file: File) => {
    discard();
    const url = URL.createObjectURL(file);
    const probe = new Audio(url);
    probe.addEventListener("loadedmetadata", () => {
      if (!Number.isFinite(probe.duration) || probe.duration <= 0) {
        URL.revokeObjectURL(url);
        onError("Could not read the duration of that audio file.");
        return;
      }
      setRecording({ blob: file, url, seconds: probe.duration, filename: file.name, uploaded: true });
      setTrim([0, Math.min(probe.duration, VOICE_PROMPT_TARGET_SECONDS)]);
      if (!label) setLabel(file.name.replace(/\.[^.]+$/, "").slice(0, 60));
    }, { once: true });
    probe.addEventListener("error", () => {
      URL.revokeObjectURL(url);
      onError("That file does not appear to contain playable audio.");
    }, { once: true });
  }, [discard, label, onError]);

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
      setRecording({ blob, url: URL.createObjectURL(blob), seconds, filename: `voice.${extension}`, uploaded: false });
      setTrim([0, seconds]);
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
      const created = await create(
        recording.blob,
        label.trim() || "My voice",
        recording.filename,
        trim ? { start: trim[0], end: trim[1] } : undefined,
      );
      discard();
      setLabel("");
      onChanged({ created: created.id });
    } catch (failure) {
      onError(failure instanceof Error ? failure.message : "Could not save that voice");
    } finally {
      setBusy(false);
    }
  }, [recording, label, trim, create, discard, onChanged, onError]);

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
  const selectedSeconds = trim ? trim[1] - trim[0] : (recording?.seconds ?? 0);
  const tooShort = recording !== null && selectedSeconds < minSeconds;

  return (
    <div className="space-y-4">
      <div>
        <h3 className="text-sm font-semibold">Your own voice</h3>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Record the passage or upload a clear voice sample. Your audio stays on this machine.
        </p>
      </div>

      <>
          <blockquote className="rounded-md border-l-2 border-primary/50 bg-muted/40 py-2.5 pr-3 pl-3 font-serif text-sm leading-relaxed">
            {prompt || "…"}
          </blockquote>

          <div className="flex flex-wrap items-center gap-2">
            {active ? (
              <Button onClick={stop} variant="destructive" size="sm">
                <Square className="size-3.5 fill-current" />
                Stop
              </Button>
            ) : (
              <Button onClick={start} variant={recording ? "outline" : "default"} size="sm" disabled={busy || !supported} title={!supported ? "Microphone recording is unavailable in this browser" : undefined}>
                <Mic className="size-3.5" />
                {recording ? "Record again" : "Record"}
              </Button>
            )}

            {!active && (
              <>
                <input
                  ref={uploadInput}
                  type="file"
                  accept="audio/*,.mp3,.wav,.m4a,.aac,.ogg,.flac,.webm"
                  className="hidden"
                  onChange={event => {
                    const file = event.target.files?.[0];
                    if (file) useFile(file);
                    event.target.value = "";
                  }}
                />
                <Button onClick={() => uploadInput.current?.click()} variant="outline" size="sm" disabled={busy}>
                  <Upload className="size-3.5" />
                  Upload audio
                </Button>
              </>
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
                {selectedSeconds.toFixed(1)}s selected
                {tooShort && ` — needs at least ${minSeconds}s`}
              </span>
            )}
          </div>

          {recording && !active && (
            <div className="space-y-3 rounded-md border p-3">
              <WaveformEditor recording={recording} value={trim ?? [0, recording.seconds]} onChange={setTrim} onError={onError} />

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

function WaveformEditor({
  recording,
  value,
  onChange,
  onError,
}: {
  recording: Recording;
  value: [number, number];
  onChange: (value: [number, number]) => void;
  onError: (message: string) => void;
}) {
  const [peaks, setPeaks] = useState<number[]>([]);
  const [playing, setPlaying] = useState(false);
  const audio = useRef<HTMLAudioElement | null>(null);

  useEffect(() => {
    let cancelled = false;
    const context = new AudioContext();
    void recording.blob.arrayBuffer()
      .then(buffer => context.decodeAudioData(buffer))
      .then(decoded => {
        if (cancelled) return;
        const channel = decoded.getChannelData(0);
        const bars = 120;
        const stride = Math.max(1, Math.floor(channel.length / bars));
        const next = Array.from({ length: bars }, (_, index) => {
          let peak = 0;
          const end = Math.min(channel.length, (index + 1) * stride);
          for (let i = index * stride; i < end; i += Math.max(1, Math.floor(stride / 80))) {
            peak = Math.max(peak, Math.abs(channel[i] ?? 0));
          }
          return Math.max(0.04, peak);
        });
        const max = Math.max(...next, 0.01);
        setPeaks(next.map(peak => peak / max));
      })
      .catch(() => onError("The waveform could not be decoded, but you can still save this audio."))
      .finally(() => void context.close());
    return () => {
      cancelled = true;
      audio.current?.pause();
    };
  }, [recording.blob, onError]);

  const stop = useCallback(() => {
    audio.current?.pause();
    setPlaying(false);
  }, []);

  const toggle = useCallback(() => {
    if (playing) return stop();
    const element = audio.current ?? new Audio(recording.url);
    audio.current = element;
    element.currentTime = value[0];
    element.ontimeupdate = () => {
      if (element.currentTime >= value[1]) stop();
    };
    element.onended = stop;
    void element.play().then(() => setPlaying(true)).catch(() => setPlaying(false));
  }, [playing, recording.url, stop, value]);

  const left = (value[0] / recording.seconds) * 100;
  const right = 100 - (value[1] / recording.seconds) * 100;

  return (
    <div className="space-y-2" aria-label="Trim audio sample">
      <div className="flex items-center justify-between gap-2">
        <div>
          <p className="text-sm font-medium">{recording.uploaded ? recording.filename : "Your recording"}</p>
          <p className="text-xs text-muted-foreground">Drag the handles to keep the clearest part of the sample.</p>
        </div>
        <Button type="button" onClick={toggle} variant="outline" size="icon-sm" aria-label={playing ? "Stop preview" : "Preview selection"}>
          {playing ? <Square className="size-3.5 fill-current" /> : <Play className="size-3.5" />}
        </Button>
      </div>

      <div className="relative h-24 overflow-hidden rounded-md bg-muted/50 px-1" aria-hidden="true">
        <div className="flex h-full items-center gap-px">
          {(peaks.length ? peaks : Array.from({ length: 80 }, () => 0.12)).map((peak, index) => (
            <span key={index} className="min-w-0 flex-1 rounded-full bg-primary/80" style={{ height: `${Math.max(5, peak * 82)}%` }} />
          ))}
        </div>
        <div className="pointer-events-none absolute inset-y-0 left-0 bg-background/70" style={{ width: `${left}%` }} />
        <div className="pointer-events-none absolute inset-y-0 right-0 bg-background/70" style={{ width: `${right}%` }} />
        <div className="pointer-events-none absolute inset-y-0 border-x-2 border-primary" style={{ left: `${left}%`, right: `${right}%` }} />
      </div>

      <Slider
        value={value}
        min={0}
        max={recording.seconds}
        step={0.05}
        minStepsBetweenThumbs={Math.ceil(Math.min(0.5, recording.seconds) / 0.05)}
        onValueChange={next => {
          stop();
          onChange([next[0] ?? 0, next[1] ?? recording.seconds]);
        }}
        aria-label="Audio trim range"
      />
      <div className="flex justify-between text-xs tabular-nums text-muted-foreground">
        <span>Start {formatTime(value[0])}</span>
        <span className="font-medium text-foreground">{formatTime(value[1] - value[0])} selected</span>
        <span>End {formatTime(value[1])}</span>
      </div>
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
