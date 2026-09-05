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
