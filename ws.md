<!-- (swiss :tags (lues store seam view input) :sev (blocker gap polish)) -->

## Workstream S: one span store

Spans and fields do one job twice: a named range over the text. Merge them. A span has a key and
a value. Some keys the renderer reads (`fg`, `bg`, `ul`). The bind rows read the other keys
(`path`, `url`, `line`). The kernel never knows what a link is.

Decisions:

- One record: `{lo, hi, edges, key, val}`. `key` is an interned name, as tokens are now. `val` is
  a token id for a renderer key, or a string in the bucket's pool for a data key. An empty value
  means the span's own bytes.
- Values are strings. Do not add a type tag or a binary payload. When the kernel can switch on a
  type, feature code moves into the kernel.
- The publisher sets two edge bits per span. Colour runs do not absorb text at either end. Link
  runs absorb text at both ends, so a rename typed at the end of a name stays in the name.
- Overlay merge: renderer keys merge top-down by the `spans =` z-order. Data keys with different
  names all survive at one position. For the same name, the top producer wins.
- Spans are stored in the coordinates of their publisher: source bytes for a producer, the
  stage's output for a view stage. Once per frame, after the view chain, all buckets resolve into
  one flat list in drawn coordinates. Draw and lookup both read that list.
- Lookup for `<name>`: the span under the caret first, then the first on the line. The themer
  expands `<rm>` on a row where the caret is not over that span. The pointer still takes the
  narrowest span under it.

Order:

1. Built: overlay-after-view. It removed the `restyle`/`overstyle` split before anything else
   moved. `doc_styles` now returns one list in drawn lines, and the command line reads it too.
2. Built: span-key, in lues `f102521`. Key 0 is a look; any other key is data with a string
   value. Flatness is per key, and the overlay merges per key.
3. Built: fields-are-spans. `OKET_API` 11; the descriptor has no fields. `oket_build_submit`
   sends a builder's spans with its text, and home publishes as producer `home`. Field spans are
   `open`, so text typed at either end of a name joins it. An explicit empty value (lues
   `368d3ae`) replaces the zero-width spans themer and grammars used for an empty argument.
   `doc_fields` reads them back by line, still first-per-line.
4. Built: overlay-is-the-lookup. `<name>`, `:home enter` and the live link take the span under
   the caret (`desc.field_under`), ends included; of two that meet, the one ending there wins;
   none covering means the first on the line. The link underline comes off the same store read
   as the colours, in `doc_styles`. The stream is closed.

Things to measure: the extra bytes per syntax run against the 16k cap, and the sort cost noted in
the spans-are-a-store memory.

After this stream (no code site yet): a `links` plugin that publishes `url`, `path` and `line`
spans over any document, the terminal too. Then `[link]` bind rows such as
`enter = :open <path> && :goto <line>`. A completion popup can publish `insert` spans on its own
rows and become clickable for free.

<!-- (skeleton :tags (lues store seam view input)) -->

_No holes match this query._

<!-- /skeleton -->
