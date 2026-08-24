# Language preprocessing and pack distribution

Huiver keeps ebook source text immutable. The language processor creates a
separate spoken form after stable source chunking; read-along and content
identity continue to use the source form. English and Dutch have compiled
processors, while every other language uses the punctuation-only fallback.

## Pack trust and release process

`.narcissepack` files are ZIP archives with a signed `manifest.json`. The
manifest signature is Ed25519 over sorted-key JSON with `signature: null`.
Every non-manifest archive member must be listed by path and SHA-256 digest.
`LICENSES.json` is mandatory. `LanguagePackManager` rejects duplicate,
absolute, backslash, dot and parent paths; files not listed by the manifest;
unknown schemas; unsupported languages; missing notices; invalid signatures;
and hash mismatches before creating an installed version.

The release build supplies current and next public keys in the application
Info.plist as a `[keyId: base64RawEd25519PublicKey]` dictionary named
`LanguagePackPublicKeys`. Private signing keys must never be stored in this
repository. A new pack is fully validated in `LanguagePacks/.staging`, moved
to its version directory and only then recorded in `active.json`. A failed
activation removes the staged version and leaves the previous active version
unchanged.

Catalog files use the same canonical encoding and signature scheme. The last
valid catalog can be cached locally; installed processors and data do not
depend on a network connection.

## Third-party data and GPL obligations

The intended native G2P implementation is eSpeak NG 1.52, licensed
GPL-3.0-or-later. Distributing a build that links that core requires the app's
corresponding source, build scripts, license text and installation information
to be made available under the applicable GPL terms. The current source tree
contains the serialized Swift `EspeakBackend` boundary but does not vendor or
link the eSpeak binary. Do not label a build as carrying eSpeak until the
native source target and corresponding-source release artifact are present.

English `gruut-lang-en` 2.0.1 and Dutch `gruut-lang-nl` 2.0.2 lexicons may be
pruned into data packs. Their package licenses and exact source hashes must be
listed in `LICENSES.json`. Gruut's runtime is MIT licensed and archived; Huiver
uses pinned data rather than its Python, CRF, POS or G2P runtime. Python
`phonemizer` is development-only and is never part of an app or pack.

Phoneme output is an analysis signal only. Chatterbox always receives the
normalized grapheme `spokenText`; IPA is never sent to its tokenizer.

