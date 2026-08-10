/**
 * Split chapter text into TTS-sized pieces.
 *
 * Kokoro truncates anything past ~510 phoneme tokens, so we stay well under it
 * and prefer to break on paragraph, then sentence, then word boundaries.
 */
const DEFAULT_MAX_CHARS = 420;

function splitSentences(paragraph: string): string[] {
  return paragraph.match(/[^.!?…]+(?:[.!?…]+["'”’)\]]*\s*|$)/g)?.map(s => s.trim()).filter(Boolean)
    ?? [paragraph];
}

function splitLongPiece(piece: string, max: number): string[] {
  const out: string[] = [];
  let current = "";
  for (const word of piece.split(/\s+/)) {
    if (current && `${current} ${word}`.length > max) {
      out.push(current);
      current = word;
    } else {
      current = current ? `${current} ${word}` : word;
    }
  }
  if (current) out.push(current);
  // A single "word" longer than max (e.g. a URL) still has to go somewhere.
  return out.flatMap(p => (p.length <= max ? [p] : (p.match(new RegExp(`.{1,${max}}`, "g")) ?? [p])));
}

export function chunkText(text: string, max = DEFAULT_MAX_CHARS): string[] {
  const chunks: string[] = [];
  let current = "";

  const push = () => {
    const trimmed = current.trim();
    if (trimmed) chunks.push(trimmed);
    current = "";
  };

  for (const paragraph of text.split(/\n{2,}/)) {
    const clean = paragraph.replace(/\s+/g, " ").trim();
    if (!clean) continue;

    if (current && current.length + clean.length + 1 > max) push();

    if (clean.length <= max) {
      current = current ? `${current} ${clean}` : clean;
      continue;
    }

    for (const sentence of splitSentences(clean)) {
      const pieces = sentence.length <= max ? [sentence] : splitLongPiece(sentence, max);
      for (const piece of pieces) {
        if (current && current.length + piece.length + 1 > max) push();
        current = current ? `${current} ${piece}` : piece;
      }
    }
    push();
  }
  push();

  return chunks;
}

/** Give live playback a fast first byte without cutting the opening sentence. */
export function chunkTextWithSentenceLead(text: string, max = DEFAULT_MAX_CHARS): string[] {
  const chunks = chunkText(text, max);
  const first = chunks[0];
  if (!first) return chunks;

  const sentences = splitSentences(first);
  if (sentences.length < 2) return chunks;
  return [sentences[0]!, sentences.slice(1).join(" "), ...chunks.slice(1)].filter(Boolean);
}
