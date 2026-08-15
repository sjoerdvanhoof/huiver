import {
  ModelCategory,
  deleteModelByCategory,
  ensureModelByCategory,
  getLocalModelPathByCategory,
  getModelByIdByCategory,
  isModelDownloadedByCategory,
  refreshModelsByCategory,
  type DownloadProgress,
  type TtsModelMeta,
} from "react-native-sherpa-onnx/download";
import { useSyncExternalStore } from "react";

/**
 * Getting Kokoro onto the phone.
 *
 * `kokoro-multi-lang-v1_0` rather than the newer v1.1: v1.1 is a Chinese
 * fine-tune with a different speaker roster, while v1.0 carries exactly the 21
 * English voices the desktop app offers. fp32 rather than int8, too — int8
 * halves the download but runs about twice as slow on Apple silicon.
 *
 * sherpa-onnx publishes the model as a release asset and its download manager
 * handles fetching, checksums, extraction and resume, so nothing is hosted here.
 */
export const MODEL_ID = "kokoro-multi-lang-v1_0";

/** Roughly what the user is committing to; the real number comes from the registry. */
export const APPROX_DOWNLOAD_BYTES = 350 * 1024 * 1024;

export type ModelState =
  | { status: "unknown" }
  | { status: "missing"; bytes: number | null }
  | { status: "downloading"; percent: number; phase: DownloadProgress["phase"]; bytes: number | null }
  | { status: "ready"; path: string }
  | { status: "error"; message: string };

let state: ModelState = { status: "unknown" };
const listeners = new Set<() => void>();

function publish(next: ModelState): void {
  state = next;
  listeners.forEach(listener => listener());
}

const subscribe = (onChange: () => void) => {
  listeners.add(onChange);
  return () => {
    listeners.delete(onChange);
  };
};

export const getModelState = (): ModelState => state;

export function useModelState(): ModelState {
  return useSyncExternalStore(subscribe, getModelState);
}

async function metaBytes(): Promise<number | null> {
  const meta = await getModelByIdByCategory<TtsModelMeta>(ModelCategory.Tts, MODEL_ID);
  return meta?.bytes ?? null;
}

/** Work out where we stand without downloading anything. */
export async function refreshModelState(): Promise<ModelState> {
  try {
    const path = await getLocalModelPathByCategory(ModelCategory.Tts, MODEL_ID);
    if (path) {
      publish({ status: "ready", path });
      return state;
    }

    // The registry is a cached copy of the sherpa-onnx release listing; refresh
    // it so the size shown in the download prompt is the real one.
    let bytes = await metaBytes();
    if (bytes === null) {
      await refreshModelsByCategory(ModelCategory.Tts).catch(() => undefined);
      bytes = await metaBytes();
    }

    publish({ status: "missing", bytes });
  } catch (error) {
    publish({ status: "error", message: message(error) });
  }
  return state;
}

let inFlight: Promise<string> | null = null;

/**
 * Download and unpack the model, reporting progress. Safe to call repeatedly:
 * a download already running is joined rather than started again, and an
 * interrupted one resumes where it stopped.
 */
export function downloadModel(): Promise<string> {
  if (inFlight) return inFlight;

  inFlight = (async () => {
    const bytes = await metaBytes().catch(() => null);
    publish({ status: "downloading", percent: 0, phase: "downloading", bytes });

    try {
      const result = await ensureModelByCategory(ModelCategory.Tts, MODEL_ID, {
        onProgress: progress =>
          publish({
            status: "downloading",
            percent: Math.max(0, Math.min(100, progress.percent)),
            phase: progress.phase,
            bytes: progress.totalBytes || bytes,
          }),
      });
      publish({ status: "ready", path: result.localPath });
      return result.localPath;
    } catch (error) {
      publish({ status: "error", message: message(error) });
      throw error;
    } finally {
      inFlight = null;
    }
  })();

  return inFlight;
}

/** The model directory, downloading it first if it is not there yet. */
export async function ensureModelPath(): Promise<string> {
  const path = await getLocalModelPathByCategory(ModelCategory.Tts, MODEL_ID);
  if (path) {
    publish({ status: "ready", path });
    return path;
  }
  return downloadModel();
}

export async function deleteModel(): Promise<void> {
  await deleteModelByCategory(ModelCategory.Tts, MODEL_ID);
  await refreshModelState();
}

export const isModelReady = (): Promise<boolean> => isModelDownloadedByCategory(ModelCategory.Tts, MODEL_ID);

const message = (error: unknown): string => (error instanceof Error ? error.message : String(error));
