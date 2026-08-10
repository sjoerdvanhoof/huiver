/**
 * Deterministic placeholder covers: a book id hashes to one of these
 * two-stop gradients, so a book keeps its colour everywhere it appears.
 * Values are plain hex so every renderer can take them: CSS, <canvas> (Media
 * Session artwork on the web) and React Native's gradient view.
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

/** The gradient a book draws its placeholder cover from, as `[from, to]`. */
export function coverGradient(bookId: string): [string, string] {
  return COVER_GRADIENTS[coverIndex(bookId)]!;
}
