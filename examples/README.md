# examples

The 10 books listed below are committed to the repo, so the app is testable
immediately after a clone. They are public domain, from
[Project Gutenberg](https://www.gutenberg.org), and about 3 MB in total.

**Anything else you put in this folder stays out of git.** `.gitignore` blocks all
ebook formats by default and re-includes only these ten by name, so dropping your own
(likely copyrighted) books here is safe — they will not be committed to a public repo.

Adding a new sample means adding a `!examples/<name>.epub` line to `.gitignore` as
well; a unit test fails if that list drifts out of sync with `scripts/fetch-examples.ts`.

## Re-downloading

The books are already here. If you ever need to refetch them:

```bash
bun run examples
```

They cover different EPUB shapes:

| Book | Why it's here |
| --- | --- |
| The Yellow Wallpaper | Single short chapter — the fastest full conversion to try first |
| Alice's Adventures in Wonderland | Short, dialogue-heavy |
| Metamorphosis | A few long chapters |
| The Time Machine | Compact, evenly split |
| Frankenstein | Epistolary — opens with letters, not chapters |
| The Adventures of Sherlock Holmes | Self-contained short stories |
| Pride and Prejudice | Many short chapters |
| Dracula | Epistolary, journal entries |
| The Adventures of Tom Sawyer | Dialect-heavy prose, a good pronunciation test |
| Moby Dick | Long — stress test |

Start with **The Yellow Wallpaper**: about 51k characters, so a full conversion
finishes in a couple of minutes rather than hours.

Downloading does not put a book on the shelf — the library lives in SQLite. `bun run
examples` imports as well as downloads. To shelf files you dropped in here yourself:

```bash
bun run examples:import
```

Both skip anything already imported, and are safe to run while `bun dev` is up.
Reload the page afterwards.

## Chapter counts

Project Gutenberg packs many chapters into a handful of XHTML files and marks the
real boundaries with `#fragment` anchors in its NCX table of contents. huiver splits
on those anchors, so you get a track per chapter: Pride and Prejudice comes through as
63 (61 chapters plus a title page and preface), Moby Dick as 140.

## Your own books

Drop anything here; it stays out of git. Note that a *folder* named `something.epub`
(an unpacked EPUB) is not a file — browsers zip it on the way in, which huiver
detects by content rather than by extension.
