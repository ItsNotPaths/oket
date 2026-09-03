/* The oket helper library (§7).
 *
 * A library you LINK, not part of the seam. Everything here needs no kernel state, so it has no
 * reason to cross one — and plugins/stage.sh compiles it into your `.so` with -flto, so a walk
 * over a snapshot inlines into your loop and the half you never call is stripped. Nothing here
 * is versioned, because nothing here is a seam.
 *
 * Shipping these as a shared library instead would put a call boundary on the hottest path in
 * the system; putting them behind the seam would re-grow the seam. That is the whole reason
 * `pluginify` is a link step and the linker is the optimiser.
 *
 * Word boundaries, indentation and bracket matching come from tools/gen-unicode.py, the same
 * run that writes the kernel's tables, so the two agree about where a word ends by
 * construction rather than by review.
 */
#ifndef OKET_HELPERS_H
#define OKET_HELPERS_H

#include <stddef.h>
#include <stdint.h>

#include "oket.h"

#ifdef __cplusplus
extern "C" {
#endif

/* --- what every plugin writes first ---
 *
 * Not about text. Each is one line over `oket_api`, `oket_at` or malloc that a plugin would
 * otherwise carry a private copy of. */

/* A string literal as the (bytes, length) pair every seam call takes: LIT("files"). */
#define LIT(s) s, sizeof(s) - 1

/* The echo line, for a message you already have NUL-terminated. */
void oket_say(const oket_api *api, oket_self self, const char *text);

/* Whether this call is aimed at a document YOU opened: `inst` is set only for your own (§5). A
 * command the user bound globally lands on whatever is focused, so this is what it asks first. */
int oket_mine(const oket_at *at);

/* A NUL-terminated copy of a span. Seam strings carry no terminator and the C library wants
 * one. NULL when the allocation fails. */
char *oket_dup(const char *s, size_t len);

/* --- UTF-8 --- */

/* Decodes the rune at the start of `s`, writing it to `out`. Returns its length in bytes, or
 * 0 when `len` is 0. A malformed byte is one byte of U+FFFD, so a walk always advances. */
size_t oket_utf8_next(const char *s, size_t len, uint32_t *out);

/* Decodes the rune ENDING at byte `at`, writing it to `out`. Returns its length in bytes,
 * or 0 at the start of the string. */
size_t oket_utf8_prev(const char *s, size_t at, uint32_t *out);

/* Encodes `r` into `out`, which needs four bytes. Returns the length written. */
size_t oket_utf8_encode(uint32_t r, char *out);

/* --- display width --- */

/* Cells the rune occupies: 0 for combining marks, 2 for East Asian wide, 1 for the rest.
 * The kernel lays its grid out with the same table, so a plugin that measures with this one
 * agrees with the screen. */
int oket_width(uint32_t r);

/* The same, summed over a UTF-8 string. */
size_t oket_width_str(const char *s, size_t len);

/* --- character classes --- */

/* The three classes the word motions below are built on. Punct is everything else, so a rune
 * always has exactly one. */
typedef enum oket_class {
    OKET_CLASS_SPACE,
    OKET_CLASS_WORD, /* letters, decimal digits and '_' */
    OKET_CLASS_PUNCT,
} oket_class;

oket_class oket_class_of(uint32_t r);

/* --- word boundaries --- */

/* All four take one line's bytes, and `from`/`col` are BYTE columns. Every step is a whole
 * rune, so a boundary never lands inside one. Out of range clamps rather than failing. */

/* IDE-style word jump: skips a leading run of whitespace, then one run of a single class, so
 * "foo.bar" yields three stops (foo | . | bar). Returns the byte column it stopped at. */
size_t oket_word_right(const char *s, size_t len, size_t from);

/* The same, walked backwards. */
size_t oket_word_left(const char *s, size_t len, size_t from);

/* The run of one class CONTAINING `col`, as a half-open [*lo, *hi) — what a double-click
 * selects. The motions above are directional and answer this wrong at either end of a word.
 * A column past the last rune looks LEFT; whitespace is a class too. */
void oket_word_span(const char *s, size_t len, size_t col, size_t *lo, size_t *hi);

/* --- lines --- */

/* Leading spaces and tabs, in cells. A tab advances one cell today, so over the indent run
 * bytes and cells are the same count. */
size_t oket_indent_cols(const char *s, size_t len);

/* Nothing but whitespace. Such a line carries no indent, so guides flow through it. */
int oket_line_blank(const char *s, size_t len);

/* --- brackets --- */

/* What `open` pairs with, or 0 when it opens nothing. Quotes are their own close. This says
 * only what pairs with what; deciding WHEN to pair is the editor's. */
uint32_t oket_pair_close(uint32_t open);

/* --- walking a snapshot (§6) ---
 *
 * A snapshot is a piece table: the document's bytes live in `blocks` and `pieces` says which
 * run of which block sits where. So a RUN is what exists in memory and a flat string is what
 * would have to be manufactured — read runs where you can, and copy only what you must.
 *
 * None of this calls the kernel. It is the read path the seam does not have a message for. */

/* The run of bytes the document has at `off`, and how many of them are contiguous. NULL at or
 * past the end. Advance by the length it wrote to `run_len` and call again. */
const char *oket_run(const oket_snapshot *s, size_t off, size_t *run_len);

/* Copies [lo, hi) into `dst`, up to `cap` bytes. Returns how many it wrote. */
size_t oket_copy(const oket_snapshot *s, size_t lo, size_t hi, char *dst, size_t cap);

/* One byte, or 0 past the end. Convenient, not fast: it locates a piece per call, so a scan
 * wants oket_run. */
char oket_byte(const oket_snapshot *s, size_t off);

/* --- lines ---
 *
 * The line index is a run-length structure (`segs` over `starts`), so a line's start is a
 * binary search rather than a scan, and it stays that way however the document is edited. */

/* Byte offset of the start of `line`. Clamped to the document. */
size_t oket_line_start(const oket_snapshot *s, size_t line);

/* [lo, hi) of `line`, the newline excluded. */
void oket_line_range(const oket_snapshot *s, size_t line, size_t *lo, size_t *hi);

/* The line `off` sits on. */
size_t oket_line_at(const oket_snapshot *s, size_t off);

/* Copies `line` into `dst`, the newline excluded. Returns how many bytes it wrote. */
size_t oket_line_copy(const oket_snapshot *s, size_t line, char *dst, size_t cap);

/* --- columns ---
 *
 * A column is a CELL, not a byte and not a rune: a tab jumps to the next stop and a wide glyph
 * takes two. Getting this wrong is what makes a caret drift on a line with a CJK glyph in it. */

/* Cells from the start of the line to byte `col` of it. */
size_t oket_col_cells(const oket_snapshot *s, size_t line, size_t col, size_t tab_width);

/* The byte offset into the line that lands at cell `cell`, clamped to the line's end. */
size_t oket_col_bytes(const oket_snapshot *s, size_t line, size_t cell, size_t tab_width);

/* --- cursors ---
 *
 * A cursor is two positions and an edit is two byte offsets; this is the whole of the
 * conversion between them. The kernel leaves one cursor collapsed on each edit it applies, so
 * a plugin that writes every cursor's range never places a caret itself. */

/* Byte offset of a position, clamped to the line it names. */
size_t oket_pos_off(const oket_snapshot *s, oket_pos p);

/* Cursor `i`'s range in bytes, low to high. lo == hi is a bare caret. */
void oket_cursor_span(const oket_snapshot *s, size_t i, size_t *lo, size_t *hi);

/* --- the descriptor builder ---
 *
 * A listing is text plus the spans that name its parts, and the two have to be built together
 * or the offsets drift. This writes both at once: append cells to a row, and every cell's span
 * is recorded as a field under the column's name. `<path>` in a bind row then resolves with no
 * callback into your code at all (§5).
 *
 * One allocation per builder, grown as it goes. Free it with oket_build_free. */

typedef struct {
    char        *text;
    size_t       len, cap;
    oket_field  *fields;
    size_t       nfields, fields_cap;
    oket_column *columns;
    size_t       ncolumns, columns_cap;
    int32_t     *depth;
    size_t       ndepth, depth_cap;
    int32_t      line; /* the row being built */
    size_t       row_start, cell_start;
    int          oom;
} oket_build;

/* Declares a column: a name, a width in cells, and an alignment. The order you declare them in
 * is the order they draw in. */
void oket_build_column(oket_build *b, const char *name, int32_t width, oket_align align);

/* Appends a cell to the current row and records its span as a field under `name`. Cells are
 * separated by a tab, which nothing downstream parses: the fields say where they are. */
void oket_build_cell(oket_build *b, const char *name, const char *text, size_t len);

/* Records a second field over a span of the cell just appended. The offsets are from the start
 * of that cell. */
void oket_build_span(oket_build *b, const char *name, size_t lo, size_t hi);

/* The same span, pointing SOMEWHERE ELSE: what is drawn is [lo, hi) of the cell and what
 * `<name>` hands on is `value`. That is what makes a row a LINK — a line showing a bare
 * `browser.c` while `<path>` carries the whole of where it lives — and it is the only way to
 * say it in a document with no columns to hide a cell in.
 *
 * `value` is BORROWED until the submit, exactly like the names above: the kernel copies it
 * there, so it must outlive the oket_set or oket_batch_submit that carries this descriptor. */
void oket_build_link(oket_build *b, const char *name, size_t lo, size_t hi,
                     const char *value, size_t value_len);

/* Sets how deep the current row sits. A tree, an outline and folding are this one number: the
 * kernel draws the indent, so nothing here writes padding into the text a bind reads. */
void oket_build_depth(oket_build *b, int32_t depth);

/* Ends the current row and starts the next. */
void oket_build_row(oket_build *b);

/* Fills in `d`'s columns and fields from the builder. The pointers are the builder's, so it
 * must outlive the submit call. */
void oket_build_desc(oket_build *b, oket_descriptor *d);

void oket_build_free(oket_build *b);

/* --- writing (§6) ---
 *
 * Neither of these takes a generation, and that is the point: the generation is read here,
 * against the newest snapshot there is, so no plugin author writes a rebase loop. A write that
 * still loses the race is dropped whole at the drain and the owner is told through an
 * OKET_EVENT_MOVED, which is where you re-read and try again. */

/* Replaces [lo, hi) with `text`. */
void oket_replace(const oket_api *api, oket_self self, oket_doc doc,
                  size_t lo, size_t hi, const char *text, size_t len);

/* Replaces the whole document, and publishes `d` with it. Either may be empty: a NULL `d`
 * leaves the descriptor as it stands, and a zero `len` empties the text. */
void oket_set(const oket_api *api, oket_self self, oket_doc doc,
              const char *text, size_t len, const oket_descriptor *d);

/* The same, as a REGENERATION: the carets in this document were put where they are by
 * NAVIGATION, so they stay on their rows instead of collapsing onto the splice
 * (OKET_SUBMIT_REGEN). A tree rewriting itself to expand a directory wants this one; the same
 * tree taking a typed rune does not, and the difference is not in the offsets. A document that
 * takes no typing at all keeps its carets either way. */
void oket_regen(const oket_api *api, oket_self self, oket_doc doc,
                const char *text, size_t len, const oket_descriptor *d);


/* --- writing several places at once ---
 *
 * What typing is, once there is more than one caret: one edit per cursor, one transaction and
 * one undo step. The ranges must not overlap; the kernel applies them back to front, so each
 * one keeps the offsets its author read.
 *
 * Each edit's text is copied in, so no two of them have to be the same string — the indent
 * under one caret is not the indent under the next. Free it with oket_batch_free. */

typedef struct {
    oket_edit *edits;
    size_t     n, cap;
    int        oom;
} oket_batch;

/* Appends "[lo, hi) becomes this text". A zero `len` is a deletion. */
void oket_batch_edit(oket_batch *b, size_t lo, size_t hi, const char *text, size_t len);

/* Submits the whole batch against `gen`, and answers whether anything went. An empty batch,
 * or one that ran out of memory, submits nothing. */
int oket_batch_submit(const oket_api *api, oket_self self, oket_doc doc, uint64_t gen,
                      oket_batch *b);

void oket_batch_free(oket_batch *b);

/* --- publishing spans (§9) ---
 *
 * A publish REPLACES [lo, hi) on one layer and never appends, so republishing a viewport does
 * not make the store grow with the file. Out of order, overlapping and out of range are all
 * survived: the kernel clips, sorts, and lets the span that starts first win.
 *
 * Offsets are DOCUMENT BYTES. A run that crosses a line end is one run; the renderer splits it
 * where it draws. */

typedef struct {
    oket_span *spans;
    size_t     n, cap;
    int        oom;
} oket_spans;

/* Appends one run. An empty or reversed range is dropped here rather than at the seam. */
void oket_spans_add(oket_spans *b, size_t lo, size_t hi, oket_token tok, uint8_t attrs);

/* Publishes what has been added, against `gen`, and answers whether it went. An EMPTY set is a
 * real publish: it is how a layer clears a range. The buffer is left as it is, so a caller
 * slicing a parse over frames adds and publishes again. */
int oket_spans_publish(const oket_api *api, oket_self self, oket_doc doc, uint64_t gen,
                       oket_layer layer, size_t lo, size_t hi, oket_spans *b);

void oket_spans_free(oket_spans *b);

/* --- chords --- */

/* Whether a chord handed to OKET_EVENT_CHORD is the one named. The spelling is the PHYSICAL one
 * describe prints — a position on the keyboard, carrying an `@`: "@ESC", "ctrl+@AC01". A mouse
 * button has one spelling and no sigil: "click". Deliberately not the layout spelling, which
 * says what the key TYPES and is a different string on a different layout. */
int oket_chord_is(const char *chord, size_t chord_len, const char *name);

#ifdef __cplusplus
}
#endif
#endif /* OKET_HELPERS_H */
