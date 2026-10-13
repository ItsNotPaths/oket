/* Reading a snapshot: runs, lines, columns and cursors. Nothing here calls the kernel —
 * it is the read path the seam does not have a message for (§6). */
#include <string.h>

#include "oket_helpers.h"

/* --- walking a snapshot (§6) ---
 *
 * `pieces` is sorted by doc_off and covers the document with no gaps, so locating an offset is
 * a binary search. */

static size_t piece_at(const lues_snapshot *s, size_t off) {
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

const char *oket_run(const lues_snapshot *s, size_t off, size_t *run_len) {
    size_t i, into;
    const lues_piece *p;

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

size_t oket_copy(const lues_snapshot *s, size_t lo, size_t hi, char *dst, size_t cap) {
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

char oket_byte(const lues_snapshot *s, size_t off) {
    size_t run_len;
    const char *run = oket_run(s, off, &run_len);
    return run != NULL ? *run : '\0';
}

/* --- lines ---
 *
 * `segs` holds runs of consecutive lines whose starts sit in `starts`, each read back with the
 * run's `delta` added. An edit re-deltas segments rather than rewriting every start after the
 * caret, which is what keeps a keystroke off an O(document) path. */

static const lues_seg *seg_of_line(const lues_snapshot *s, size_t line) {
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

size_t oket_line_start(const lues_snapshot *s, size_t line) {
    const lues_seg *g;
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

void oket_line_range(const lues_snapshot *s, size_t line, size_t *lo, size_t *hi) {
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

size_t oket_line_at(const lues_snapshot *s, size_t off) {
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

size_t oket_line_copy(const lues_snapshot *s, size_t line, char *dst, size_t cap) {
    size_t lo, hi;
    oket_line_range(s, line, &lo, &hi);
    return oket_copy(s, lo, hi, dst, cap);
}

/* --- columns --- */

/* One walk for both column questions: forward until `hi` bytes or `cell_stop` cells, whichever
 * comes first. Returns where it stopped and writes the cells it crossed. */
static size_t col_walk(const lues_snapshot *s, size_t lo, size_t hi, size_t cell_stop,
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

size_t oket_col_cells(const lues_snapshot *s, size_t line, size_t col, size_t tab_width) {
    size_t lo, hi, cells;

    oket_line_range(s, line, &lo, &hi);
    if (hi > lo + col) {
        hi = lo + col;
    }
    col_walk(s, lo, hi, SIZE_MAX, tab_width, &cells);
    return cells;
}

size_t oket_col_bytes(const lues_snapshot *s, size_t line, size_t cell, size_t tab_width) {
    size_t lo, hi, cells;

    oket_line_range(s, line, &lo, &hi);
    return col_walk(s, lo, hi, cell, tab_width, &cells) - lo;
}

/* --- cursors --- */

size_t oket_pos_off(const lues_snapshot *s, oket_pos p) {
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

void oket_cursor_span(const lues_snapshot *s, size_t i, size_t *lo, size_t *hi) {
    size_t a, b;

    if (i >= oket_side_of(s)->ncursors) {
        *lo = *hi = 0;
        return;
    }
    a = oket_pos_off(s, oket_side_of(s)->cursors[i].anchor);
    b = oket_pos_off(s, oket_side_of(s)->cursors[i].head);
    *lo = a < b ? a : b;
    *hi = a < b ? b : a;
}
