/**
 * The passage you read aloud to make a narrator out of your own voice.
 *
 * Zero-shot cloning takes whatever it is given, so a fixed passage is worth
 * more than it looks: every recording then covers the same ground, and a clone
 * that comes out wrong is the recording's fault rather than the text's.
 *
 * It is chosen to be broad rather than long — the awkward English consonants
 * are all in here (church, judged, thin, through, pushed, morning) alongside a
 * full spread of vowels — and to be read the way a book is read, so the clone
 * inherits a narrating voice instead of a talking-to-camera one.
 */
export const VOICE_PROMPT_TEXT =
  "The quiet harbour town woke slowly. Gulls turned above the jetty, a church bell rang past the " +
  "bridge, and the first boats pushed out through thin grey water. She judged it a fair morning " +
  "for the crossing, and said so.";

/**
 * Chatterbox asserts outright that a reference clip is longer than five
 * seconds, so this sits just above that line: a recording rejected here gets an
 * explanation, one that slips through crashes the worker instead.
 */
export const VOICE_PROMPT_MIN_SECONDS = 6;

/**
 * Read at an unhurried narrating pace the passage lands around here, which is
 * also the most Chatterbox looks at — its speech encoder takes the first 15
 * seconds of the reference and its decoder the first 10.
 */
export const VOICE_PROMPT_TARGET_SECONDS = 15;

/**
 * Past this there is nothing left to learn, and the reference is trimmed. Kept
 * generous so a slow reader is never cut off mid-sentence.
 */
export const VOICE_PROMPT_MAX_SECONDS = 30;
