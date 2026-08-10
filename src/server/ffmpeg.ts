/**
 * ffmpeg is optional. It encodes finished chapters to MP3, encodes voice
 * previews, and is what turns a live render into an MP3 stream — but a machine
 * without it still converts, it just keeps WAVs.
 *
 * Set HUIVER_FFMPEG to use a build that is not on PATH.
 */
export const ffmpegBinary = (): string => process.env.HUIVER_FFMPEG || "ffmpeg";
