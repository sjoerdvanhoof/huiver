import { coverGradient, coverInitial } from "@huiver/shared";

/**
 * 512×512 PNG data URL of the placeholder cover, for lock-screen artwork.
 * Canvas-only, so it stays on the web side; the gradient itself is shared.
 */
export function coverArtworkDataUrl(bookId: string, title: string): string {
  const [from, to] = coverGradient(bookId);
  const canvas = document.createElement("canvas");
  canvas.width = 512;
  canvas.height = 512;
  const ctx = canvas.getContext("2d");
  if (!ctx) return "";

  const gradient = ctx.createLinearGradient(0, 0, 512, 512);
  gradient.addColorStop(0, from);
  gradient.addColorStop(1, to);
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, 512, 512);

  ctx.fillStyle = "rgba(255,255,255,0.4)";
  ctx.font = "300 300px Georgia, serif";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(coverInitial(title), 256, 276);

  return canvas.toDataURL("image/png");
}
