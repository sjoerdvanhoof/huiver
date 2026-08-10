/**
 * Ids carry their kind so a stray id in a log or a file path is readable.
 *
 * Hermes has no Web Crypto, so this cannot lean on `crypto.randomUUID` the way
 * the server does. Three parts stand in for it: the clock separates runs, a
 * counter guarantees uniqueness within one (a book inserts all its chapters
 * inside a single millisecond), and a random tail keeps two installs of the app
 * from landing on the same id for the same book.
 *
 * Base36 throughout, because these end up in file paths.
 *
 * Kept apart from ./index so it can be tested: that module reaches for
 * expo-sqlite, and anything that pulls in React Native cannot be loaded by Bun.
 */
const WRAP = 46656; // 36^3

let sequence = Math.floor(Math.random() * WRAP);

export function newId(prefix: string): string {
  sequence = (sequence + 1) % WRAP;

  const time = Date.now().toString(36).slice(-8);
  const seq = sequence.toString(36).padStart(3, "0");
  const tail = Math.floor(Math.random() * 36).toString(36);

  return `${prefix}_${time}${seq}${tail}`;
}
