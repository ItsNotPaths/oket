#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"
#include "oket_unicode.h"

#define BAD 0xFFFD

size_t oket_utf8_next(const char *s, size_t len, uint32_t *out) {
    /* The smallest value each length may encode; anything under it is overlong. */
    static const uint32_t least[5] = {0, 0, 0x80, 0x800, 0x10000};
    const unsigned char *p = (const unsigned char *)s;
    unsigned char b0;
    size_t need, i;
    uint32_t r;

    *out = BAD;
    if (len == 0) {
        return 0;
    }
    b0 = p[0];
    if (b0 < 0x80) {
        *out = b0;
        return 1;
    }
    if ((b0 & 0xE0) == 0xC0) {
        need = 2, r = b0 & 0x1Fu;
    } else if ((b0 & 0xF0) == 0xE0) {
        need = 3, r = b0 & 0x0Fu;
    } else if ((b0 & 0xF8) == 0xF0) {
        need = 4, r = b0 & 0x07u;
    } else {
        return 1; /* a stray continuation or a 5-byte lead: one byte of U+FFFD */
    }
    if (need > len) {
        return 1;
    }
    for (i = 1; i < need; i++) {
        if ((p[i] & 0xC0) != 0x80) {
            return 1; /* truncated: resync on the byte that broke it, never past it */
        }
        r = (r << 6) | (p[i] & 0x3Fu);
    }
    /* Overlong forms and surrogates decode to something; refusing them here is what stops a
     * plugin's own parser and the kernel's disagreeing about how many runes a line holds. */
    if (r < least[need] || r > 0x10FFFF || (r >= 0xD800 && r <= 0xDFFF)) {
        return 1;
    }
    *out = r;
    return need;
}

size_t oket_utf8_prev(const char *s, size_t at, uint32_t *out) {
    const unsigned char *p = (const unsigned char *)s;
    size_t start, back, got;

    *out = BAD;
    if (at == 0) {
        return 0;
    }
    /* At most three continuation bytes precede a lead, so the scan is bounded. */
    start = at - 1;
    for (back = 0; back < 3 && start > 0 && (p[start] & 0xC0) == 0x80; back++) {
        start--;
    }
    got = oket_utf8_next(s + start, at - start, out);
    if (got != at - start) { /* the run did not end where we started: take one byte */
        *out = BAD;
        return 1;
    }
    return got;
}

size_t oket_utf8_encode(uint32_t r, char *out) {
    if (r < 0x80) {
        out[0] = (char)r;
        return 1;
    }
    if (r < 0x800) {
        out[0] = (char)(0xC0 | (r >> 6));
        out[1] = (char)(0x80 | (r & 0x3F));
        return 2;
    }
    if (r < 0x10000) {
        out[0] = (char)(0xE0 | (r >> 12));
        out[1] = (char)(0x80 | ((r >> 6) & 0x3F));
        out[2] = (char)(0x80 | (r & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (r >> 18));
    out[1] = (char)(0x80 | ((r >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((r >> 6) & 0x3F));
    out[3] = (char)(0x80 | (r & 0x3F));
    return 4;
}

static int in_ranges(const oket_crange *rs, size_t n, uint32_t r) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (r < rs[mid].lo) {
            hi = mid;
        } else if (r > rs[mid].hi) {
            lo = mid + 1;
        } else {
            return 1;
        }
    }
    return 0;
}

int oket_width(uint32_t r) {
    /* Below U+0300 everything is one column, so nearly all text skips both searches. */
    if (r < 0x0300) {
        return r == 0 ? 0 : 1;
    }
    if (in_ranges(OKET_WIDTH_ZERO, sizeof OKET_WIDTH_ZERO / sizeof *OKET_WIDTH_ZERO, r)) {
        return 0;
    }
    if (in_ranges(OKET_WIDTH_WIDE, sizeof OKET_WIDTH_WIDE / sizeof *OKET_WIDTH_WIDE, r)) {
        return 2;
    }
    return 1;
}

size_t oket_width_str(const char *s, size_t len) {
    size_t i = 0, w = 0;
    while (i < len) {
        uint32_t r;
        size_t n = oket_utf8_next(s + i, len - i, &r);
        if (n == 0) {
            break;
        }
        i += n;
        w += (size_t)oket_width(r);
    }
    return w;
}

/* --- character classes --- */

oket_class oket_class_of(uint32_t r) {
    if (in_ranges(OKET_SPACE_RANGES, sizeof OKET_SPACE_RANGES / sizeof *OKET_SPACE_RANGES,
                  r)) {
        return OKET_CLASS_SPACE;
    }
    if (in_ranges(OKET_WORD_RANGES, sizeof OKET_WORD_RANGES / sizeof *OKET_WORD_RANGES,
                  r)) {
        return OKET_CLASS_WORD;
    }
    return OKET_CLASS_PUNCT;
}

/* --- word boundaries --- */

static size_t clamp_to(size_t v, size_t len) {
    return v > len ? len : v;
}

size_t oket_word_right(const char *s, size_t len, size_t from) {
    size_t i = clamp_to(from, len);
    uint32_t r;
    oket_class c;

    while (i < len) {
        size_t n = oket_utf8_next(s + i, len - i, &r);
        if (oket_class_of(r) != OKET_CLASS_SPACE) {
            break;
        }
        i += n;
    }
    if (i >= len) {
        return i;
    }
    oket_utf8_next(s + i, len - i, &r);
    c = oket_class_of(r);
    while (i < len) {
        size_t n = oket_utf8_next(s + i, len - i, &r);
        if (oket_class_of(r) != c) {
            break;
        }
        i += n;
    }
    return i;
}

size_t oket_word_left(const char *s, size_t len, size_t from) {
    size_t i = clamp_to(from, len);
    uint32_t r;
    oket_class c;

    while (i > 0) {
        size_t n = oket_utf8_prev(s, i, &r);
        if (oket_class_of(r) != OKET_CLASS_SPACE) {
            break;
        }
        i -= n;
    }
    if (i == 0) {
        return 0;
    }
    oket_utf8_prev(s, i, &r);
    c = oket_class_of(r);
    while (i > 0) {
        size_t n = oket_utf8_prev(s, i, &r);
        if (oket_class_of(r) != c) {
            break;
        }
        i -= n;
    }
    return i;
}

void oket_word_span(const char *s, size_t len, size_t col, size_t *lo, size_t *hi) {
    size_t i = clamp_to(col, len);
    uint32_t r;
    oket_class c;
    size_t size;

    *lo = *hi = 0;
    if (len == 0) {
        return;
    }
    if (i == len) {
        i -= oket_utf8_prev(s, i, &r); /* past the end: the run that ends here */
    }
    size = oket_utf8_next(s + i, len - i, &r);
    c = oket_class_of(r);
    *lo = i;
    *hi = i + size;
    while (*lo > 0) {
        size_t n = oket_utf8_prev(s, *lo, &r);
        if (oket_class_of(r) != c) {
            break;
        }
        *lo -= n;
    }
    while (*hi < len) {
        size_t n = oket_utf8_next(s + *hi, len - *hi, &r);
        if (oket_class_of(r) != c) {
            break;
        }
        *hi += n;
    }
}

/* --- lines --- */

size_t oket_indent_cols(const char *s, size_t len) {
    size_t n = 0;
    while (n < len && (s[n] == ' ' || s[n] == '\t')) {
        n++;
    }
    return n;
}

int oket_line_blank(const char *s, size_t len) {
    return oket_indent_cols(s, len) == len;
}

/* --- brackets --- */

uint32_t oket_pair_close(uint32_t open) {
    switch (open) {
    case '(': return ')';
    case '[': return ']';
    case '{': return '}';
    case '"': return '"';
    case '\'': return '\'';
    case '`': return '`';
    }
    return 0;
}

/* --- chords --- */

int oket_chord_is(const char *chord, size_t chord_len, const char *name) {
    return strlen(name) == chord_len && memcmp(chord, name, chord_len) == 0;
}

/* --- walking a snapshot (§6) ---
 *
 * `pieces` is sorted by doc_off and covers the document with no gaps, so locating an offset is
 * a binary search. Nothing here calls the kernel: it reads the arrays the seam handed over. */

static size_t piece_at(const oket_snapshot *s, size_t off) {
    size_t lo = 0, hi = s->npieces;
    while (lo + 1 < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if ((size_t)s->pieces[mid].doc_off <= off) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return lo;
}

const char *oket_run(const oket_snapshot *s, size_t off, size_t *run_len) {
    size_t i, into;
    const oket_piece *p;

    *run_len = 0;
    if (s == NULL || off >= s->size || s->npieces == 0) {
        return NULL;
    }
    i = piece_at(s, off);
    p = &s->pieces[i];
    into = off - (size_t)p->doc_off;
    if (into >= (size_t)p->len) {
        return NULL; /* the piece list disagrees with `size`; refuse rather than read past */
    }
    *run_len = (size_t)p->len - into;
    return (const char *)s->blocks[p->block].ptr + (size_t)p->off + into;
}

size_t oket_copy(const oket_snapshot *s, size_t lo, size_t hi, char *dst, size_t cap) {
    size_t n = 0;

    if (s == NULL || dst == NULL) {
        return 0;
    }
    if (hi > s->size) {
        hi = s->size;
    }
    while (lo < hi && n < cap) {
        size_t run_len, want;
        const char *run = oket_run(s, lo, &run_len);
        if (run == NULL || run_len == 0) {
            break;
        }
        want = hi - lo;
        if (want > run_len) {
            want = run_len;
        }
        if (want > cap - n) {
            want = cap - n;
        }
        memcpy(dst + n, run, want);
        n += want;
        lo += want;
    }
    return n;
}

char oket_byte(const oket_snapshot *s, size_t off) {
    size_t run_len;
    const char *run = oket_run(s, off, &run_len);
    return run != NULL ? *run : '\0';
}

/* --- lines ---
 *
 * `segs` holds runs of consecutive lines whose starts sit in `starts`, each read back with the
 * run's `delta` added. An edit re-deltas segments rather than rewriting every start after the
 * caret, which is what keeps a keystroke off an O(document) path. */

static const oket_seg *seg_of_line(const oket_snapshot *s, size_t line) {
    size_t lo = 0, hi = s->nsegs;
    while (lo + 1 < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if ((size_t)s->segs[mid].first <= line) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return &s->segs[lo];
}

size_t oket_line_start(const oket_snapshot *s, size_t line) {
    const oket_seg *g;
    ptrdiff_t at;

    if (s == NULL || s->nsegs == 0 || s->lines == 0) {
        return 0;
    }
    if (line >= s->lines) {
        line = s->lines - 1;
    }
    g = seg_of_line(s, line);
    at = g->at + (ptrdiff_t)(line - (size_t)g->first);
    if (at < 0 || (size_t)at >= s->nstarts) {
        return 0;
    }
    return (size_t)(s->starts[at] + g->delta);
}

void oket_line_range(const oket_snapshot *s, size_t line, size_t *lo, size_t *hi) {
    *lo = *hi = 0;
    if (s == NULL || s->lines == 0) {
        return;
    }
    *lo = oket_line_start(s, line);
    /* The next line's start is one PAST the newline, so the end of this one is one before it. */
    *hi = line + 1 < s->lines ? oket_line_start(s, line + 1) - 1 : s->size;
    if (*hi < *lo) {
        *hi = *lo;
    }
}

size_t oket_line_at(const oket_snapshot *s, size_t off) {
    size_t lo = 0, hi;

    if (s == NULL || s->lines == 0) {
        return 0;
    }
    hi = s->lines - 1;
    while (lo < hi) {
        size_t mid = lo + (hi - lo + 1) / 2;
        if (oket_line_start(s, mid) <= off) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    return lo;
}

size_t oket_line_copy(const oket_snapshot *s, size_t line, char *dst, size_t cap) {
    size_t lo, hi;
    oket_line_range(s, line, &lo, &hi);
    return oket_copy(s, lo, hi, dst, cap);
}

/* --- columns --- */

/* One walk for both column questions: forward until `hi` bytes or `cell_stop` cells, whichever
 * comes first. Returns where it stopped and writes the cells it crossed. */
static size_t col_walk(const oket_snapshot *s, size_t lo, size_t hi, size_t cell_stop,
                       size_t tab_width, size_t *cells_out) {
    size_t at, cells = 0;

    if (tab_width == 0) {
        tab_width = 1;
    }
    for (at = lo; at < hi && cells < cell_stop;) {
        char buf[4];
        uint32_t r;
        size_t n = oket_copy(s, at, at + 4 < hi ? at + 4 : hi, buf, sizeof buf);
        size_t used = oket_utf8_next(buf, n, &r);
        if (used == 0) {
            break;
        }
        cells += r == '\t' ? tab_width - cells % tab_width : (size_t)oket_width(r);
        at += used;
    }
    *cells_out = cells;
    return at;
}

size_t oket_col_cells(const oket_snapshot *s, size_t line, size_t col, size_t tab_width) {
    size_t lo, hi, cells;

    oket_line_range(s, line, &lo, &hi);
    if (hi > lo + col) {
        hi = lo + col;
    }
    col_walk(s, lo, hi, SIZE_MAX, tab_width, &cells);
    return cells;
}

size_t oket_col_bytes(const oket_snapshot *s, size_t line, size_t cell, size_t tab_width) {
    size_t lo, hi, cells;

    oket_line_range(s, line, &lo, &hi);
    return col_walk(s, lo, hi, cell, tab_width, &cells) - lo;
}

/* --- cursors --- */

size_t oket_pos_off(const oket_snapshot *s, oket_pos p) {
    size_t lo, hi, at;

    if (p.line < 0) {
        return 0;
    }
    oket_line_range(s, (size_t)p.line, &lo, &hi);
    if (p.col <= 0) {
        return lo;
    }
    at = lo + (size_t)p.col;
    return at > hi ? hi : at;
}

void oket_cursor_span(const oket_snapshot *s, size_t i, size_t *lo, size_t *hi) {
    size_t a, b;

    if (i >= s->ncursors) {
        *lo = *hi = 0;
        return;
    }
    a = oket_pos_off(s, s->cursors[i].anchor);
    b = oket_pos_off(s, s->cursors[i].head);
    *lo = a < b ? a : b;
    *hi = a < b ? b : a;
}

/* --- motion (CURSORS.md §8) --- */

int oket_pos_less(oket_pos a, oket_pos b) {
    return a.line < b.line || (a.line == b.line && a.col < b.col);
}

static int pos_same(oket_pos a, oket_pos b) {
    return a.line == b.line && a.col == b.col;
}

/* The rune ending at `off` and the one starting there, in bytes, both floored at the line's own
 * ends. Through the decoders above and never a byte count of their own, so a plugin and the
 * kernel cannot disagree about where a rune ends. */

static size_t rune_back(const oket_snapshot *s, size_t off, size_t lo) {
    char     buf[4];
    uint32_t r;
    size_t   n = oket_copy(s, off - lo > 4 ? off - 4 : lo, off, buf, sizeof buf);
    size_t   used = oket_utf8_prev(buf, n, &r);

    return used == 0 ? 1 : used;
}

static size_t rune_fwd(const oket_snapshot *s, size_t off, size_t hi) {
    char     buf[4];
    uint32_t r;
    size_t   n = oket_copy(s, off, off + 4 < hi ? off + 4 : hi, buf, sizeof buf);
    size_t   used = oket_utf8_next(buf, n, &r);

    return used == 0 ? 1 : used;
}

oket_pos oket_pos_left(const oket_snapshot *s, oket_pos p) {
    oket_pos out = p;
    size_t   lo, hi, off;

    if (p.line < 0) {
        out.line = out.col = 0;
        return out;
    }
    oket_line_range(s, (size_t)p.line, &lo, &hi);
    off = oket_pos_off(s, p);
    if (off > lo) {
        out.col = (ptrdiff_t)(off - lo - rune_back(s, off, lo));
        return out;
    }
    if (p.line == 0) {
        out.col = 0; /* the start of the document is itself */
        return out;
    }
    oket_line_range(s, (size_t)p.line - 1, &lo, &hi);
    out.line = p.line - 1;
    out.col = (ptrdiff_t)(hi - lo);
    return out;
}

oket_pos oket_pos_right(const oket_snapshot *s, oket_pos p) {
    oket_pos out = p;
    size_t   lo, hi, off;

    if (p.line < 0) {
        out.line = out.col = 0;
        return out;
    }
    oket_line_range(s, (size_t)p.line, &lo, &hi);
    off = oket_pos_off(s, p);
    if (off < hi) {
        out.col = (ptrdiff_t)(off - lo + rune_fwd(s, off, hi));
        return out;
    }
    if ((size_t)p.line + 1 < s->lines) {
        out.line = p.line + 1;
        out.col = 0;
    }
    return out;
}

oket_pos oket_visible(const oket_snapshot *s, oket_pos p, int toward_lo) {
    oket_pos out = p;
    size_t   pass, i;

    /* Looped, because two runs can meet and the edge of one is then inside the next. */
    for (pass = 0; pass < s->nhidden; pass++) {
        int moved = 0;

        for (i = 0; i < s->nhidden; i++) {
            oket_pos e = toward_lo ? s->hidden[i].lo : s->hidden[i].hi;

            if (oket_pos_less(out, s->hidden[i].lo) || oket_pos_less(s->hidden[i].hi, out)) {
                continue;
            }
            if (!pos_same(e, out)) {
                out = e;
                moved = 1;
            }
        }
        if (!moved) {
            break;
        }
    }
    return out;
}

/* Where one caret goes. `goal` is left negative: the seam reads that as "compute the cell
 * column from head", and only the kernel can measure one against the grid it draws. */
static oket_cursor move_cursor(const oket_snapshot *s, oket_cursor c, oket_motion m,
                               int select) {
    int      right = m == OKET_MOTION_RIGHT;
    oket_pos to;

    if (!select && !pos_same(c.anchor, c.head)) {
        /* A plain move over a selection puts the caret on the edge it goes toward. */
        int ahead = oket_pos_less(c.anchor, c.head);
        to = (right == ahead) ? c.head : c.anchor;
    } else {
        /* Off the FAR edge of a run first: a step taken from the near edge lands back on the
         * same cell, so a fold would cost two presses to cross. */
        oket_pos from = oket_visible(s, c.head, !right);
        to = right ? oket_pos_right(s, from) : oket_pos_left(s, from);
    }
    /* And no caret is left inside hidden text, including one that only collapsed. */
    to = oket_visible(s, to, !right);
    c.head = to;
    if (!select) {
        c.anchor = to;
    }
    c.goal = -1;
    return c;
}

/* Under this cap an arrow key at repeat rate allocates nothing; past it, one malloc per press
 * beats a buffer kept per document for the rare case. */
#define CURSORS_INLINE 32

void oket_move(const oket_api *api, oket_self self, const oket_snapshot *s,
               oket_motion m, int select) {
    oket_cursor  inline_set[CURSORS_INLINE];
    oket_cursor *set = inline_set;
    size_t       i, n = s->ncursors;

    if (n == 0) {
        return;
    }
    if (n > CURSORS_INLINE) {
        set = malloc(n * sizeof *set);
        if (set == NULL) {
            return;
        }
    }
    for (i = 0; i < n; i++) {
        set[i] = move_cursor(s, s->cursors[i], m, select);
    }
    api->cursors(api, self, s->doc, set, n, s->primary);
    if (set != inline_set) {
        free(set);
    }
}

/* --- the descriptor builder --- */

/* One growth policy for all three arrays. `oom` latches: a builder that failed once keeps
 * failing, so a caller checks it at the end rather than after every append. */
static int grow(int *oom, void **arr, size_t *cap, size_t need, size_t item) {
    size_t want = *cap ? *cap : 16;
    void *bigger;

    if (*oom) {
        return 0;
    }
    if (need <= *cap) {
        return 1;
    }
    while (want < need) {
        want *= 2;
    }
    bigger = realloc(*arr, want * item);
    if (bigger == NULL) {
        *oom = 1;
        return 0;
    }
    *arr = bigger;
    *cap = want;
    return 1;
}

static void put(oket_build *b, const char *s, size_t len) {
    if (!grow(&b->oom, (void **)&b->text, &b->cap, b->len + len, 1)) {
        return;
    }
    memcpy(b->text + b->len, s, len);
    b->len += len;
}

void oket_build_column(oket_build *b, const char *name, int32_t width, oket_align align) {
    oket_column *c;

    if (!grow(&b->oom, (void **)&b->columns, &b->columns_cap, b->ncolumns + 1, sizeof *b->columns)) {
        return;
    }
    c = &b->columns[b->ncolumns++];
    c->name = name;
    c->name_len = strlen(name);
    c->width = width;
    c->align = (uint8_t)align;
    memset(c->_pad, 0, sizeof c->_pad);
}

void oket_build_span(oket_build *b, const char *name, size_t lo, size_t hi) {
    oket_field *f;

    if (!grow(&b->oom, (void **)&b->fields, &b->fields_cap, b->nfields + 1, sizeof *b->fields)) {
        return;
    }
    f = &b->fields[b->nfields++];
    f->name = name;
    f->name_len = strlen(name);
    f->line = b->line;
    /* Cell-relative in, line-relative out, which is what a Field's offsets are. The document
     * offset never appears on either side. */
    f->lo = (int32_t)(b->cell_start + lo);
    f->hi = (int32_t)(b->cell_start + hi);
    f->value = NULL; /* the span's own bytes are the value */
    f->value_len = 0;
    memset(f->_pad, 0, sizeof f->_pad);
}

void oket_build_link(oket_build *b, const char *name, size_t lo, size_t hi,
                     const char *value, size_t value_len) {
    oket_build_span(b, name, lo, hi);
    if (b->nfields > 0 && value != NULL) {
        b->fields[b->nfields - 1].value = value;
        b->fields[b->nfields - 1].value_len = value_len;
    }
}

void oket_build_cell(oket_build *b, const char *name, const char *text, size_t len) {
    if (b->len > b->row_start) {
        put(b, "\t", 1);
    }
    b->cell_start = b->len - b->row_start;
    put(b, text, len);
    oket_build_span(b, name, 0, len);
}

void oket_build_depth(oket_build *b, int32_t depth) {
    size_t want = (size_t)b->line + 1;

    if (!grow(&b->oom, (void **)&b->depth, &b->depth_cap, want, sizeof *b->depth)) {
        return;
    }
    /* Dense and in line order, so a row that says nothing leaves a zero behind it. */
    while (b->ndepth < want) {
        b->depth[b->ndepth++] = 0;
    }
    b->depth[b->line] = depth;
}

void oket_build_row(oket_build *b) {
    put(b, "\n", 1);
    b->line++;
    b->row_start = b->len;
    b->cell_start = 0;
}

void oket_build_desc(oket_build *b, oket_descriptor *d) {
    d->columns = b->columns;
    d->ncolumns = b->ncolumns;
    d->fields = b->fields;
    d->nfields = b->nfields;
    d->depth = b->depth;
    d->ndepth = b->ndepth;
}

void oket_build_free(oket_build *b) {
    free(b->text);
    free(b->fields);
    free(b->columns);
    free(b->depth);
    memset(b, 0, sizeof *b);
}

/* --- writing (§6) --- */

void oket_replace(const oket_api *api, oket_self self, oket_doc doc,
                  size_t lo, size_t hi, const char *text, size_t len) {
    const oket_snapshot *s = api->snapshot(api, self, doc);
    oket_edit e;

    if (s == NULL) {
        return;
    }
    memset(&e, 0, sizeof e);
    e.lo = lo;
    e.hi = hi;
    e.text = text;
    e.text_len = len;
    api->submit(api, self, doc, s->gen, &e, 1, NULL, NULL, 0);
    api->release(api, self, s);
}

static void set(const oket_api *api, oket_self self, oket_doc doc,
                const char *text, size_t len, const oket_descriptor *d, uint32_t flags);

void oket_set(const oket_api *api, oket_self self, oket_doc doc,
              const char *text, size_t len, const oket_descriptor *d) {
    set(api, self, doc, text, len, d, 0);
}

void oket_regen(const oket_api *api, oket_self self, oket_doc doc,
                const char *text, size_t len, const oket_descriptor *d) {
    set(api, self, doc, text, len, d, OKET_SUBMIT_REGEN);
}

static void set(const oket_api *api, oket_self self, oket_doc doc,
                const char *text, size_t len, const oket_descriptor *d, uint32_t flags) {
    const oket_snapshot *s = api->snapshot(api, self, doc);
    oket_edit e;

    if (s == NULL) {
        return;
    }
    memset(&e, 0, sizeof e);
    e.lo = 0;
    e.hi = s->size;
    e.text = text;
    e.text_len = len;
    api->submit(api, self, doc, s->gen, &e, 1, d, NULL, flags);
    api->release(api, self, s);
}

/* --- writing several places at once --- */

void oket_batch_edit(oket_batch *b, size_t lo, size_t hi, const char *text, size_t len) {
    oket_batch_edit_for(b, 0, lo, hi, text, len);
}

void oket_batch_edit_for(oket_batch *b, uint32_t cur, size_t lo, size_t hi,
                         const char *text, size_t len) {
    oket_edit *e;
    char *own = NULL;

    if (!grow(&b->oom, (void **)&b->edits, &b->cap, b->n + 1, sizeof *b->edits)) {
        return;
    }
    /* The edit owns its text until the submit copies it, so two carets may take two different
     * strings — which is what an indent-aware newline needs. */
    if (len > 0) {
        own = malloc(len);
        if (own == NULL) {
            b->oom = 1;
            return;
        }
        memcpy(own, text, len);
    }
    e = &b->edits[b->n++];
    memset(e, 0, sizeof *e);
    e->lo = lo;
    e->hi = hi;
    e->text = own;
    e->text_len = len;
    e->id = cur;
}

int oket_batch_submit(const oket_api *api, oket_self self, oket_doc doc, uint64_t gen,
                      oket_batch *b) {
    if (b->oom || b->n == 0) {
        return 0;
    }
    api->submit(api, self, doc, gen, b->edits, b->n, NULL, NULL, 0);
    return 1;
}

/* --- publishing spans (§9) --- */

void oket_spans_add(oket_spans *b, size_t lo, size_t hi, oket_token tok, uint8_t attrs,
                    uint8_t set) {
    oket_span *sp;

    if (hi <= lo || !grow(&b->oom, (void **)&b->spans, &b->cap, b->n + 1, sizeof *b->spans)) {
        return;
    }
    sp = &b->spans[b->n++];
    memset(sp, 0, sizeof *sp);
    sp->lo = lo;
    sp->hi = hi;
    sp->tok = tok;
    sp->attrs = attrs;
    sp->set = set;
}

int oket_spans_publish(const oket_api *api, oket_self self, oket_doc doc, uint64_t gen,
                       size_t lo, size_t hi, oket_spans *b) {
    oket_span_pub pub;

    if (b->oom) {
        return 0;
    }
    memset(&pub, 0, sizeof pub);
    pub.lo = lo;
    pub.hi = hi;
    pub.spans = b->spans;
    pub.nspans = b->n;
    /* An EMPTY list still goes: a range-scoped replace with nothing in it is how a publisher
     * says "no colours here any more", and refusing it would leave the last parse's on screen. */
    api->submit(api, self, doc, gen, NULL, 0, NULL, &pub, 0);
    return 1;
}

void oket_spans_free(oket_spans *b) {
    free(b->spans);
    memset(b, 0, sizeof *b);
}

void oket_batch_free(oket_batch *b) {
    size_t i;

    for (i = 0; i < b->n; i++) {
        free((char *)b->edits[i].text);
    }
    free(b->edits);
    memset(b, 0, sizeof *b);
}

/* --- a view stage (VIEWS §5) --- */

void oket_view_fill(oket_view_out *out, const oket_batch *edits, const oket_spans *spans) {
    memset(out, 0, sizeof *out);
    if (edits != NULL && !edits->oom) {
        out->edits = edits->edits;
        out->nedits = edits->n;
    }
    if (spans != NULL && !spans->oom) {
        out->spans = spans->spans;
        out->nspans = spans->n;
    }
}

void oket_view_clear(oket_batch *edits, oket_spans *spans) {
    size_t i;

    if (edits != NULL) {
        for (i = 0; i < edits->n; i++) {
            free((char *)edits->edits[i].text);
        }
        edits->n = 0;
        edits->oom = 0;
    }
    if (spans != NULL) {
        spans->n = 0;
        spans->oom = 0;
    }
}

/* --- a list of rows (the browser/picker core) ---
 *
 * Plugin-level statics: every plugin links its own copy of this file, so this is per-plugin
 * state and one spec is one plugin's list kind. */

static const oket_list_spec *LIST_SPEC;
static oket_kind             LIST_KIND;
static oket_list            *LISTS;

/* The verb names, built once from the prefix and alive for as long as the commands are. */
static char LIST_FILTER_CMD[48], LIST_ERASE_CMD[48], LIST_ERASE_FWD_CMD[56], LIST_CLEAR_CMD[48];

static size_t list_first(void) {
    return LIST_SPEC != NULL && LIST_SPEC->head != NULL ? 1 : 0;
}

static size_t list_clamp(size_t v, size_t lo, size_t hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

oket_list *oket_list_open(const oket_api *api, oket_self self, oket_doc doc, void *ctx) {
    oket_list *l;

    (void)api;
    (void)self;
    if (LIST_SPEC == NULL) {
        return NULL;
    }
    l = calloc(1, sizeof *l);
    if (l == NULL) {
        return NULL;
    }
    l->doc = doc;
    l->ctx = ctx;
    l->next = LISTS;
    LISTS = l;
    return l;
}

void oket_list_close(oket_list *l) {
    oket_list **at;

    if (l == NULL) {
        return;
    }
    for (at = &LISTS; *at != NULL; at = &(*at)->next) {
        if (*at == l) {
            *at = l->next;
            break;
        }
    }
    free(l->rows);
    free(l);
}

oket_list *oket_list_of(const oket_at *at) {
    oket_list *l;

    for (l = LISTS; l != NULL; l = l->next) {
        if (l == at->inst) {
            return l;
        }
    }
    return NULL;
}

const oket_list_row *oket_list_at(const oket_list *l, size_t line) {
    size_t first = list_first();

    if (line < first || line - first >= l->nrows) {
        return NULL;
    }
    return &l->rows[line - first];
}

ptrdiff_t oket_list_row_line(const oket_list *l, int32_t idx) {
    size_t i;

    for (i = 0; i < l->nrows; i++) {
        if (l->rows[i].idx == idx) {
            return (ptrdiff_t)(list_first() + i);
        }
    }
    return -1;
}

size_t oket_list_line(const oket_snapshot *s) {
    size_t lo, hi;

    if (s == NULL || s->ncursors == 0) {
        return 0;
    }
    oket_cursor_span(s, s->primary, &lo, &hi);
    return oket_line_at(s, lo);
}

void oket_list_name_span(const oket_snapshot *s, const oket_list *l, size_t line,
                         size_t *lo, size_t *hi) {
    const oket_list_row *r = oket_list_at(l, line);
    size_t start, end;

    oket_line_range(s, line, &start, &end);
    *lo = *hi = end;
    if (r == NULL) {
        return;
    }
    *lo = start + (size_t)r->name_off;
    if (*lo > end) {
        *lo = end; /* the prefix is gone: not a row a name can be read out of */
    }
    *hi = end;
    if (r->tail > 0 && *hi >= *lo + r->tail) {
        *hi -= r->tail; /* a directory's slash is punctuation, not part of its name */
    }
    if (*hi < *lo) {
        *hi = *lo;
    }
}

size_t oket_list_name(const oket_snapshot *s, const oket_list *l, size_t line,
                      char *dst, size_t cap) {
    size_t lo, hi;

    oket_list_name_span(s, l, line, &lo, &hi);
    return oket_copy(s, lo, hi, dst, cap);
}

void oket_list_publish(const oket_api *api, oket_self self, oket_list *l) {
    const oket_list_spec *sp = LIST_SPEC;
    oket_descriptor d;
    oket_build out;
    char head[512];
    int32_t i, n, shown = 0;

    if (sp == NULL) {
        return;
    }
    n = sp->count(l->ctx);
    for (i = 0; i < n; i++) {
        shown += sp->match(l->ctx, i, l->filter, l->nfilter) ? 1 : 0;
    }
    memset(&out, 0, sizeof out);
    if (sp->head != NULL) {
        size_t hn = sp->head(l->ctx, head, sizeof head, l, shown);

        if (hn >= sizeof head) {
            hn = sizeof head - 1;
        }
        oket_build_cell(&out, "head", head, hn);
        oket_build_row(&out);
    }
    l->nrows = 0;
    for (i = 0; i < n; i++) {
        oket_list_row *r;

        if (!sp->match(l->ctx, i, l->filter, l->nfilter)) {
            continue;
        }
        if (l->nrows == l->rows_cap) {
            size_t cap = l->rows_cap ? l->rows_cap * 2 : 64;
            oket_list_row *grown = realloc(l->rows, cap * sizeof *grown);

            if (grown == NULL) {
                break;
            }
            l->rows = grown;
            l->rows_cap = cap;
        }
        r = &l->rows[l->nrows];
        memset(r, 0, sizeof *r);
        r->idx = i;
        sp->row(l->ctx, &out, r, i);
        oket_build_row(&out);
        l->nrows++;
    }

    memset(&d, 0, sizeof d);
    d.kind = LIST_KIND;
    d.render = OKET_RENDER_TEXT;
    d.selection = sp->selection;
    d.input = OKET_INPUT_BOUND;
    d.editable = 1; /* what makes a typed rune reach the plugin at all */
    d.tab_width = sp->tab_width;
    if (l->file != NULL) {
        d.file = l->file;
        d.file_len = strlen(l->file);
    }
    oket_build_desc(&out, &d);
    /* Minus the row terminator the last row wrote: a document does not end in a blank line. */
    oket_regen(api, self, l->doc, out.text, out.len > 0 ? out.len - 1 : 0, &d);
    oket_build_free(&out);
}

void oket_list_repaint(const oket_api *api, oket_self self) {
    oket_list *l;

    for (l = LISTS; l != NULL; l = l->next) {
        oket_list_publish(api, self, l);
    }
}

void oket_list_point(const oket_api *api, oket_self self, oket_list *l, size_t line) {
    size_t first = list_first();
    oket_cursor c;

    memset(&c, 0, sizeof c);
    if (l->nrows == 0) {
        line = 0;
    } else {
        line = list_clamp(line, first, first + l->nrows - 1);
    }
    c.head.line = (ptrdiff_t)line;
    if (LIST_SPEC != NULL && LIST_SPEC->pin && l->nrows > 0) {
        const oket_list_row *r = &l->rows[line - first];

        c.head.col = r->name_off + r->name_len;
    }
    c.anchor = c.head;
    c.goal = -1; /* the kernel computes the cell column */
    api->cursors(api, self, l->doc, &c, 1, 0);
}

void oket_list_refilter(const oket_api *api, oket_self self, oket_list *l) {
    size_t i, line;

    oket_list_publish(api, self, l);
    /* The first row a filter can MEAN: not `..`, whose fixed row matches every filter and
     * whose path would send enter up instead of into the match. A list of only fixed rows
     * (a picker) points at the first as before. */
    line = list_first();
    for (i = 0; i < l->nrows; i++) {
        if (!l->rows[i].fixed) {
            line = list_first() + i;
            break;
        }
    }
    oket_list_point(api, self, l, line);
}

/* A list with no head row says its filter through the echo line instead. */
static void list_feedback(const oket_api *api, oket_self self, oket_list *l) {
    char msg[OKET_LIST_FILTER_CAP + 48];

    if (LIST_SPEC->head != NULL || (!l->filtering && l->nfilter == 0)) {
        return;
    }
    snprintf(msg, sizeof msg, "/%s   %zu shown; esc clears", l->filter, l->nrows);
    oket_say(api, self, msg);
}

static void list_filter_changed(const oket_api *api, oket_self self, oket_list *l) {
    if (LIST_SPEC->filtered != NULL) {
        LIST_SPEC->filtered(l->ctx);
    }
    oket_list_refilter(api, self, l);
    list_feedback(api, self, l);
}

int32_t oket_list_event(const oket_api *api, oket_self self, const oket_at *at,
                        oket_event ev, const char *text, size_t len) {
    const oket_snapshot *s = at->snap;
    oket_list *l = oket_list_of(at);
    oket_batch batch;
    size_t i;
    int sent;

    if (l == NULL || ev != OKET_EVENT_TEXT || s == NULL || len == 0) {
        return 0;
    }
    if (l->filtering) {
        if (l->nfilter + len >= sizeof l->filter) {
            return 0;
        }
        memcpy(l->filter + l->nfilter, text, len);
        l->nfilter += len;
        l->filter[l->nfilter] = 0;
        list_filter_changed(api, self, l);
        return 1;
    }
    /* Self-insert, CLAMPED INTO THE NAME, so nothing left of it is writable and a fixed row
     * takes nothing at all. No REGEN flag: a typed rune is exactly the case whose caret must
     * follow the splice. */
    memset(&batch, 0, sizeof batch);
    for (i = 0; i < s->ncursors; i++) {
        size_t lo, hi, nlo, nhi, line;
        const oket_list_row *r;

        oket_cursor_span(s, i, &lo, &hi);
        line = oket_line_at(s, lo);
        r = oket_list_at(l, line);
        if (r == NULL || r->fixed) {
            continue;
        }
        oket_list_name_span(s, l, line, &nlo, &nhi);
        lo = list_clamp(lo, nlo, nhi);
        hi = list_clamp(hi, lo, nhi);
        oket_batch_edit(&batch, lo, hi, text, len);
    }
    sent = oket_batch_submit(api, self, s->doc, s->gen, &batch);
    oket_batch_free(&batch);
    return sent;
}

/* Backspace and Delete in a name, clamped like typing: a row cannot be spliced into the one
 * above, and the prefix left of the name cannot be eaten. */
static int32_t list_erase(const oket_api *api, oket_self self, const oket_at *at, int forward) {
    const oket_snapshot *s = at->snap;
    oket_list *l = at->inst;
    oket_batch batch;
    size_t i;
    int sent;

    memset(&batch, 0, sizeof batch);
    for (i = 0; i < s->ncursors; i++) {
        size_t lo, hi, nlo, nhi, line, col, step_len, len;
        char text[1024];
        uint32_t r;
        const oket_list_row *row = NULL;

        oket_cursor_span(s, i, &lo, &hi);
        line = oket_line_at(s, lo);
        row = oket_list_at(l, line);
        if (row == NULL || row->fixed) {
            continue;
        }
        oket_list_name_span(s, l, line, &nlo, &nhi);
        if (lo != hi) { /* a selection: whatever of it lies inside the name */
            lo = list_clamp(lo, nlo, nhi);
            hi = list_clamp(hi, lo, nhi);
            if (lo < hi) {
                oket_batch_edit(&batch, lo, hi, "", 0);
            }
            continue;
        }
        lo = list_clamp(lo, nlo, nhi);
        len = oket_line_copy(s, line, text, sizeof text);
        col = lo - oket_line_start(s, line);
        if (col > len) {
            continue; /* the line outgrew the copy: no rune to measure there */
        }
        if (forward) {
            if (lo >= nhi) {
                continue; /* the name ends here, and the row does not go on being one */
            }
            step_len = oket_utf8_next(text + col, len - col, &r);
            oket_batch_edit(&batch, lo, lo + step_len, "", 0);
        } else {
            if (lo <= nlo) {
                continue;
            }
            step_len = oket_utf8_prev(text, col, &r);
            oket_batch_edit(&batch, lo - step_len, lo, "", 0);
        }
    }
    sent = oket_batch_submit(api, self, s->doc, s->gen, &batch);
    oket_batch_free(&batch);
    return sent ? 0 : 1;
}

static oket_list *list_mine(const oket_api *api, oket_self self, const oket_at *at,
                            const char *verb) {
    oket_list *l = oket_list_of(at);

    if (l == NULL || at->snap == NULL) {
        char msg[96];

        snprintf(msg, sizeof msg, "%s: this document is not the %s list", verb,
                 LIST_SPEC != NULL ? LIST_SPEC->name : "?");
        oket_say(api, self, msg);
        return NULL;
    }
    return l;
}

static int32_t list_filter_cmd(const oket_api *api, oket_self self, const oket_at *at,
                               const char *args, size_t args_len) {
    oket_list *l = list_mine(api, self, at, LIST_FILTER_CMD);

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return 1;
    }
    if (!l->filtering) {
        l->filtering = 1;
        if (LIST_SPEC->head != NULL) {
            oket_list_publish(api, self, l); /* the head shows the prompt */
        } else {
            list_feedback(api, self, l);
        }
    }
    return 0;
}

static int32_t list_erase_dir(const oket_api *api, oket_self self, const oket_at *at,
                              const char *verb, int forward) {
    oket_list *l = list_mine(api, self, at, verb);
    uint32_t r;

    if (l == NULL) {
        return 1;
    }
    if (l->filtering) {
        l->nfilter -= oket_utf8_prev(l->filter, l->nfilter, &r);
        l->filter[l->nfilter] = 0;
        list_filter_changed(api, self, l);
        return 0;
    }
    return list_erase(api, self, at, forward);
}

static int32_t list_erase_cmd(const oket_api *api, oket_self self, const oket_at *at,
                              const char *args, size_t args_len) {
    (void)args;
    (void)args_len;
    return list_erase_dir(api, self, at, LIST_ERASE_CMD, 0);
}

static int32_t list_erase_fwd_cmd(const oket_api *api, oket_self self, const oket_at *at,
                                  const char *args, size_t args_len) {
    (void)args;
    (void)args_len;
    return list_erase_dir(api, self, at, LIST_ERASE_FWD_CMD, 1);
}

static int32_t list_clear_cmd(const oket_api *api, oket_self self, const oket_at *at,
                              const char *args, size_t args_len) {
    oket_list *l = list_mine(api, self, at, LIST_CLEAR_CMD);

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return 1;
    }
    l->nfilter = 0;
    l->filter[0] = 0;
    l->filtering = 0;
    list_filter_changed(api, self, l);
    return 0;
}

void oket_list_register(const oket_api *api, oket_self self, const oket_list_spec *spec,
                        oket_kind kind) {
    LIST_SPEC = spec;
    LIST_KIND = kind;
    snprintf(LIST_FILTER_CMD, sizeof LIST_FILTER_CMD, "%s.filter", spec->prefix);
    snprintf(LIST_ERASE_CMD, sizeof LIST_ERASE_CMD, "%s.erase", spec->prefix);
    snprintf(LIST_ERASE_FWD_CMD, sizeof LIST_ERASE_FWD_CMD, "%s.erase.fwd", spec->prefix);
    snprintf(LIST_CLEAR_CMD, sizeof LIST_CLEAR_CMD, "%s.clear", spec->prefix);
    api->register_command(api, self, LIST_FILTER_CMD, strlen(LIST_FILTER_CMD),
                          LIT("typed runes go to the filter until esc"), list_filter_cmd);
    api->register_command(api, self, LIST_ERASE_CMD, strlen(LIST_ERASE_CMD),
                          LIT("one rune off the filter, or back in the name"), list_erase_cmd);
    api->register_command(api, self, LIST_ERASE_FWD_CMD, strlen(LIST_ERASE_FWD_CMD),
                          LIT("delete forward, stopping at the end of the name"),
                          list_erase_fwd_cmd);
    api->register_command(api, self, LIST_CLEAR_CMD, strlen(LIST_CLEAR_CMD),
                          LIT("clear the filter and leave it"), list_clear_cmd);
    /* ASKED FOR, never claimed (§8). ctrl+f is `ctrl+@AC04` in the physical spelling, and esc
     * shadows quit for this kind — the writeback says so where it can be taken back. */
    api->request_bind(api, self, spec->name, strlen(spec->name), LIT("ctrl+@AC04"),
                      LIST_FILTER_CMD, strlen(LIST_FILTER_CMD));
    api->request_bind(api, self, spec->name, strlen(spec->name), LIT("backspace"),
                      LIST_ERASE_CMD, strlen(LIST_ERASE_CMD));
    api->request_bind(api, self, spec->name, strlen(spec->name), LIT("esc"),
                      LIST_CLEAR_CMD, strlen(LIST_CLEAR_CMD));
}

/* --- what every plugin writes first --- */

void oket_say(const oket_api *api, oket_self self, const char *text) {
    api->message(api, self, text, strlen(text));
}

int oket_mine(const oket_at *at) {
    return at->inst != NULL && at->snap != NULL;
}

char *oket_dup(const char *s, size_t len) {
    char *out = malloc(len + 1);

    if (out == NULL) {
        return NULL;
    }
    memcpy(out, s, len);
    out[len] = '\0';
    return out;
}

char *oket_file_read(const char *path, size_t max, size_t *len) {
    FILE *f = fopen(path, "rb");
    char *buf;
    long n;

    *len = 0;
    if (f == NULL) {
        return NULL;
    }
    /* Seek-tell-seek rather than stat: one header fewer, and a file that will not seek is one
     * this cannot read whole anyway. */
    if (fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return NULL;
    }
    if (max != 0 && (size_t)n > max) {
        fclose(f);
        return NULL;
    }
    buf = malloc((size_t)n + 1);
    if (buf != NULL) {
        /* Short reads are not an error here: `len` is what arrived, and a file shrinking under
         * a reader is the same answer as a file that was always that size. */
        *len = fread(buf, 1, (size_t)n, f);
        buf[*len] = '\0';
    }
    fclose(f);
    return buf;
}
