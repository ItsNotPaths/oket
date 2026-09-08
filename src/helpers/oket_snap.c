/* Reading a snapshot: runs, lines, columns, cursors and motion. Nothing here calls the kernel —
 * it is the read path the seam does not have a message for (§6). */
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

/* --- walking a snapshot (§6) ---
 *
 * `pieces` is sorted by doc_off and covers the document with no gaps, so locating an offset is
 * a binary search. */

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
