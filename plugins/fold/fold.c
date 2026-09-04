/* Folding, as a view stage (VIEWS §5, stage 7). One half of the DESIGN GATE: a stage that reads
 * the source and writes a view of it.
 *
 * It never touches the document. What it returns is EDITS against what it was handed, and the
 * kernel derives a piece table from them — so the file on disk, the undo log and the recovery
 * journal have never heard of a fold. Motion is told which runs no cell stands for and steps
 * over them; nothing else in the kernel knows either.
 *
 * A block is decided by INDENT, which is the one rule that works on a document whose language
 * nobody parsed. `:fold` folds or unfolds the block point is standing on, `:fold none` clears
 * the document's folds.
 *
 * ANCHORED BY LINE, and that is the honest limit: an edit above a fold moves its lines and the
 * anchor does not follow. The extent is recomputed from the snapshot every call, so only the
 * header line is stale, and only until the next `:fold`.
 *
 *     :pluginify plugins/fold         build it and load it
 *     [edit] view = fold              in config.conf, which it asks for on its first load
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

#define FOLDS_MAX 256 /* per document; past this a file wants a language, not an indent rule */
#define MARKER_MAX 64

/* The folded header lines of one document, sorted. A document and not an instance: this plugin
 * registers no kind, so it is a stage over somebody else's buffers. */
typedef struct doc_folds {
    oket_doc          doc;
    size_t            lines[FOLDS_MAX];
    size_t            n;
    struct doc_folds *next;
} doc_folds;

static doc_folds *FOLDS;
static oket_token DIM;

static doc_folds *folds_of(oket_doc doc, int make) {
    doc_folds *f;

    for (f = FOLDS; f != NULL; f = f->next) {
        if (f->doc == doc) {
            return f;
        }
    }
    if (!make) {
        return NULL;
    }
    f = calloc(1, sizeof *f);
    if (f == NULL) {
        return NULL;
    }
    f->doc = doc;
    f->next = FOLDS;
    FOLDS = f;
    return f;
}

static int folds_has(const doc_folds *f, size_t line) {
    size_t i;

    for (i = 0; f != NULL && i < f->n; i++) {
        if (f->lines[i] == line) {
            return 1;
        }
    }
    return 0;
}

/* Kept sorted, because the edits a stage returns have to come out in order. */
static void folds_add(doc_folds *f, size_t line) {
    size_t i, j;

    if (f->n == FOLDS_MAX || folds_has(f, line)) {
        return;
    }
    for (i = 0; i < f->n && f->lines[i] < line; i++) {
    }
    for (j = f->n; j > i; j--) {
        f->lines[j] = f->lines[j - 1];
    }
    f->lines[i] = line;
    f->n++;
}

static void folds_drop(doc_folds *f, size_t line) {
    size_t i;

    for (i = 0; i < f->n; i++) {
        if (f->lines[i] == line) {
            memmove(&f->lines[i], &f->lines[i + 1], (f->n - i - 1) * sizeof *f->lines);
            f->n--;
            return;
        }
    }
}

/* --- what a block is --- */

/* The last line of the block `line` heads: everything under it indented further, blank lines
 * carried along rather than ending it. `line` itself when nothing is. */
static size_t block_end(const oket_snapshot *s, size_t line) {
    char   buf[512];
    size_t head, last, i, len, cols;

    len = oket_line_copy(s, line, buf, sizeof buf);
    head = oket_indent_cols(buf, len);
    last = line;
    for (i = line + 1; i < s->lines; i++) {
        len = oket_line_copy(s, i, buf, sizeof buf);
        if (oket_line_blank(buf, len)) {
            continue; /* a blank line inside a block is not the end of it */
        }
        cols = oket_indent_cols(buf, len);
        if (cols <= head) {
            break;
        }
        last = i;
    }
    return last;
}

/* --- the stage --- */

/* The edits and the runs over what they inserted, kept across calls: the kernel copies inside
 * the call, so this is one allocation for the plugin's life rather than one per frame. */
static oket_batch EDITS;
static oket_spans MARKS;

static int32_t fold_view(const oket_api *api, oket_self self, const oket_at *at,
                         oket_view_out *out) {
    const oket_snapshot *s = at->snap;
    doc_folds *f = folds_of(at->doc, 0);
    char       marker[MARKER_MAX];
    size_t     i, head, last, lo, hi, tail, mark, cut = 0, put = 0;
    int        n;

    (void)api;
    (void)self;
    oket_view_clear(&EDITS, &MARKS);
    for (i = 0; f != NULL && i < f->n; i++) {
        head = f->lines[i];
        if (head >= s->lines) {
            continue; /* the anchor outlived the line: the document shrank under it */
        }
        last = block_end(s, head);
        if (last == head) {
            continue; /* nothing is under it any more */
        }
        /* From the END of the header's text to the end of the block's last line. The header
         * keeps its own bytes, its number and its indent; what goes is the newline after it and
         * everything under it, and the marker takes their place. */
        oket_line_range(s, head, &lo, &hi);
        oket_line_range(s, last, &lo, &tail);
        n = snprintf(marker, sizeof marker, " \xe2\x8b\xaf %zu lines", last - head);
        /* snprintf answers what it WOULD have written, so a truncation is not a length. */
        if (n <= 0 || (size_t)n >= sizeof marker) {
            continue;
        }
        oket_batch_edit(&EDITS, hi, tail, marker, (size_t)n);
        /* The run is over the stage's OWN OUTPUT, so it is measured in the document these edits
         * make: everything cut out so far comes off, everything put in goes back on. */
        mark = hi - cut + put;
        oket_spans_add(&MARKS, mark, mark + (size_t)n, DIM, 0, OKET_SET_FG);
        cut += tail - hi;
        put += (size_t)n;
    }
    oket_view_fill(out, &EDITS, &MARKS);
    return 0; /* never latched: an indent scan is one pass, and one pass finishes */
}

/* --- the verbs --- */

/* The block point is standing on: the caret's line when something is under it, otherwise the
 * nearest line above that heads one. Standing anywhere inside a block folds the block. */
static int caret_block(const oket_snapshot *s, size_t *line) {
    char   buf[512];
    size_t at, i, len, want, cols;

    if (s->ncursors == 0 || s->lines == 0) {
        return 0;
    }
    at = (size_t)s->cursors[s->primary].head.line;
    if (at >= s->lines) {
        return 0;
    }
    if (block_end(s, at) != at) {
        *line = at;
        return 1;
    }
    len = oket_line_copy(s, at, buf, sizeof buf);
    want = oket_indent_cols(buf, len);
    for (i = at; i > 0; i--) {
        len = oket_line_copy(s, i - 1, buf, sizeof buf);
        if (oket_line_blank(buf, len)) {
            continue;
        }
        cols = oket_indent_cols(buf, len);
        if (cols < want) {
            *line = i - 1;
            return 1;
        }
    }
    return 0;
}

static int32_t fold_cmd(const oket_api *api, oket_self self, const oket_at *at,
                        const char *args, size_t args_len) {
    const oket_snapshot *s = at->snap;
    doc_folds           *f;
    size_t               line;

    if (s == NULL) {
        return 1;
    }
    if (args_len == 4 && memcmp(args, "none", 4) == 0) {
        f = folds_of(at->doc, 0);
        if (f != NULL) {
            f->n = 0;
        }
        return 0;
    }
    if (!caret_block(s, &line)) {
        oket_say(api, self, "nothing here is a block");
        return 1;
    }
    f = folds_of(at->doc, 1);
    if (f == NULL) {
        return 1;
    }
    if (folds_has(f, line)) {
        folds_drop(f, line);
    } else {
        folds_add(f, line);
    }
    return 0;
}

OKET_MAIN {
    DIM = api->register_token(api, self, LIT("comment"));
    api->register_view(api, self, fold_view);
    api->register_command(api, self, LIT("fold"),
                          LIT("fold or unfold the block point is on; `none` clears them"),
                          fold_cmd);
    api->request_bind(api, self, LIT("text"), LIT("alt+@AB01"), LIT("fold")); /* alt+z */
    api->request_bind(api, self, LIT("text"), LIT("alt+shift+@AB01"), LIT("fold none"));
    /* A stage is in a pipeline because a config line says so, never because it loaded (§5).
     * This is the row that puts it there the first time, and the file owns it afterwards. */
    api->request_config(api, self, LIT("edit"), LIT("view"), LIT("fold"));
    return 0;
}
