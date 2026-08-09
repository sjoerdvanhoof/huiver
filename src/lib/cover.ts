/**
 * Deterministic placeholder covers: a book id hashes to one of these
 * two-stop gradients, so a book keeps its colour everywhere it appears.
 * Values are plain rgb so <canvas> (Media Session artwork) can use them too.
 */
export const COVER_GRADIENTS: [string, string][] = [
  ["#8c5a3a", "#3f2d23"], // leather
  ["#5a6e4e", "#26301f"], // moss
  ["#4e5d78", "#232b3a"], // slate blue
  ["#7a4e63", "#331f2b"], // plum
  ["#3e6b6b", "#1c3232"], // teal
  ["#8a6a3b", "#3a2d18"], // ochre
  ["#6b4a7a", "#2b1d33"], // violet
  ["#845050", "#361f1f"], // brick
];

export function coverIndex(id: string): number {
  let hash = 0;
  for (let i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) | 0;
  return Math.abs(hash) % COVER_GRADIENTS.length;
}

export const coverInitial = (title: string): string =>
  (title.replace(/^(the|a|an)\s+/i, "").trim()[0] ?? "?").toUpperCase();

/** 512×512 PNG data URL of the placeholder cover, for lock-screen artwork. */
export function coverArtworkDataUrl(bookId: string, title: string): string {
  const [from, to] = COVER_GRADIENTS[coverIndex(bookId)]!;
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
