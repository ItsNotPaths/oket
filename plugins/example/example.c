/* The example plugin: the smallest whole one, twice over.
 *
 * The SURFACE half (§7, stage 7) registers a kind, a command and a bind request; it opens
 * documents of that kind and fills them in; it counts the chords routed to it; and it frees its
 * instance in `close`. Unloading walks the ledger backwards and leaves the kernel as it was.
 *
 * The COMPLETION half (VIEWS §5, stage 7) is a view stage. A popup is positioned against WHAT
 * THE USER SEES: it reads the caret out of the snapshot it was handed — the fold stage's
 * output, not the file — so the box lands under the row on screen whether or not a fold above
 * it deleted lines. Nothing here maps a coordinate, and nothing here can: original offsets
 * never appear in the stage at all. That is the whole of §5's argument, and it is why the
 * stages are a pipeline instead of a fan.
 *
 * Note what is NOT here. No draw call, because plugins do not draw (§12): each half produces a
 * document, a descriptor or a stage's edits, and the kernel's one renderer draws them. No
 * generation bookkeeping, because oket_set reads the newest one (§6). No `enter` handler for
 * the surface, because `enter` over a row is a binds.conf line reading the `<name>` field this
 * file records — data the kernel reads, not a callback it makes (§5).
 *
 *     :pluginify plugins/example      build it and load it
 *     alt+h                           open the surface, once the requested row is in binds.conf
 *     alt+/                           gather the words that carry on from the one point is in
 *     alt+/ again                     the next candidate
 *     alt+shift+/                     put the picked one in: an ORDINARY submit
 *     [edit] view = fold, example     in config.conf; the ORDER is the pipeline
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

/* --- the surface --- */

static oket_kind EXAMPLE;

/* Per-document state. A kind that remembered nothing would not need this at all; this one is
 * here to prove close() gets it back. */
typedef struct {
    unsigned chords;
    unsigned foreign; /* generations somebody ELSE moved */
} example;

static void render(const oket_api *api, oket_self self, oket_doc doc, example *e) {
    static const char *const ROWS[][2] = {
        {"kind", "a document the kernel draws with its own renderer"},
        {"seam", "six messages, and reads are not one of them"},
        {"undo", "the kernel's, so ctrl+z reaches a foreign splice"},
    };
    oket_build b;
    oket_descriptor d;
    char count[32];
    size_t i;

    memset(&b, 0, sizeof b);
    oket_build_column(&b, "name", 8, OKET_ALIGN_LEFT);
    oket_build_column(&b, "note", 60, OKET_ALIGN_LEFT);
    for (i = 0; i < sizeof ROWS / sizeof *ROWS; i++) {
        oket_build_cell(&b, "name", ROWS[i][0], strlen(ROWS[i][0]));
        oket_build_cell(&b, "note", ROWS[i][1], strlen(ROWS[i][1]));
        oket_build_row(&b);
    }
    oket_build_cell(&b, "name", "keys", 4);
    i = (size_t)snprintf(count, sizeof count, "%u chord(s), %u foreign write(s)",
                         e->chords, e->foreign);
    oket_build_cell(&b, "note", count, i);

    memset(&d, 0, sizeof d);
    d.kind = EXAMPLE;
    d.render = OKET_RENDER_TEXT;
    d.selection = OKET_SELECT_LINE;
    /* `raw`, so a chord no row claims reaches event() below rather than going quiet (§8). */
    d.input = OKET_INPUT_RAW;
    d.tab_width = 4;
    oket_build_desc(&b, &d);
    oket_set(api, self, doc, b.text, b.oom ? 0 : b.len, &d);
    oket_build_free(&b);
}

static void *open_example(const oket_api *api, oket_self self, oket_doc doc,
                          const char *args, size_t args_len) {
    example *e = calloc(1, sizeof *e);
    (void)args;
    (void)args_len;
    if (e != NULL) {
        render(api, self, doc, e);
    }
    return e;
}

static void close_example(const oket_api *api, oket_self self, oket_doc doc, void *inst) {
    (void)api;
    (void)self;
    (void)doc;
    free(inst);
}

static int32_t event(const oket_api *api, oket_self self, const oket_at *at,
                     oket_event ev, const char *text, size_t len) {
    example *e = at->inst;

    if (e == NULL) {
        return 0;
    }
    /* Somebody else spliced our document — a formatter, a sort addon, `:put`. Nothing here
     * needs repairing, so it is only counted; a REPL would re-read its editable span here. The
     * kernel does not report our OWN writes, so counting one cannot start a loop. */
    if (ev == OKET_EVENT_MOVED) {
        e->foreign++;
        return 0;
    }
    if (ev == OKET_EVENT_CHORD && oket_chord_is(text, len, "@ESC")) {
        return 0; /* declined, so the kernel reports it rather than swallowing it */
    }
    e->chords++;
    render(api, self, at->doc, e);
    return 1;
}

/* Reads the document under point through the snapshot it was handed — by pointer, with no call
 * back into the kernel — and echoes the line the caret is on. */
static int32_t say(const oket_api *api, oket_self self, const oket_at *at,
                   const char *args, size_t args_len) {
    char line[256];
    size_t n;

    if (args_len > 0) {
        api->message(api, self, args, args_len);
        return 0;
    }
    if (at->snap == NULL || at->snap->ncursors == 0) {
        api->message(api, self, LIT("example"));
        return 0;
    }
    n = oket_line_copy(at->snap, (size_t)at->snap->cursors[at->snap->primary].head.line,
                       line, sizeof line);
    api->message(api, self, line, n);
    return 0;
}

/* --- completion --- */

#define CANDS_MAX 8
#define WORD_MAX 64
#define BOX_MAX 40
#define BOX_MIN 12

/* One popup, because one is what is on screen. It closes on the generation moving, so typing
 * ends it and the list is never read against a document it was not gathered from. */
static struct {
    oket_doc doc;
    int      on;
    char     prefix[WORD_MAX];
    size_t   prefix_len;
    char     cands[CANDS_MAX][WORD_MAX];
    size_t   ncands, pick;
} POP;

static oket_token BOX, PICKED;

static void popup_close(void) {
    POP.on = 0;
    POP.ncands = 0;
    POP.pick = 0;
    POP.prefix_len = 0;
}

static int popup_showing(oket_doc doc) {
    return POP.on && POP.doc == doc && POP.ncands > 0;
}

/* --- gathering ---
 *
 * THE SCAN IS IN THE COMMAND, NOT THE STAGE (§11). A stage that re-read the file every frame
 * would defeat the zero-copy the derived table exists for; this one walks the buffer once, when
 * the chord asks, and the stage after it only draws the list. */

static int word_byte(char c) {
    return oket_class_of((uint32_t)(unsigned char)c) == OKET_CLASS_WORD;
}

/* The word run point is inside, as a byte range of the document. A caret at the end of a word
 * is inside it, which is where completion is asked for. */
static int caret_word(const oket_snapshot *s, size_t *lo, size_t *hi) {
    size_t at, start, end;

    if (s->ncursors == 0) {
        return 0;
    }
    at = oket_pos_off(s, s->cursors[s->primary].head);
    for (start = at; start > 0 && word_byte(oket_byte(s, start - 1)); start--) {
    }
    for (end = at; end < s->size && word_byte(oket_byte(s, end)); end++) {
    }
    *lo = start;
    *hi = end;
    return end > start;
}

static int kept(const char *w, size_t len) {
    size_t i;

    if (len == POP.prefix_len) {
        return 0; /* the word point is already on is not a completion of itself */
    }
    for (i = 0; i < POP.ncands; i++) {
        if (strlen(POP.cands[i]) == len && memcmp(POP.cands[i], w, len) == 0) {
            return 0;
        }
    }
    return 1;
}

/* Every distinct word in the buffer that carries on from the prefix. One pass over the runs the
 * piece table already has, so nothing is copied that is not a candidate. */
static void gather(const oket_snapshot *s) {
    char        word[WORD_MAX];
    size_t      off = 0, len, i, n = 0;
    const char *run;

    while (POP.ncands < CANDS_MAX && (run = oket_run(s, off, &len)) != NULL) {
        for (i = 0; i < len && POP.ncands < CANDS_MAX; i++) {
            if (word_byte(run[i])) {
                if (n < WORD_MAX - 1) {
                    word[n++] = run[i];
                }
                continue;
            }
            if (n >= POP.prefix_len && memcmp(word, POP.prefix, POP.prefix_len) == 0 &&
                kept(word, n)) {
                memcpy(POP.cands[POP.ncands], word, n);
                POP.cands[POP.ncands++][n] = '\0';
            }
            n = 0;
        }
        off += len;
    }
    /* A word ending at the last byte of the document never met a separator. */
    if (POP.ncands < CANDS_MAX && n >= POP.prefix_len &&
        memcmp(word, POP.prefix, POP.prefix_len) == 0 && kept(word, n)) {
        memcpy(POP.cands[POP.ncands], word, n);
        POP.cands[POP.ncands++][n] = '\0';
    }
}

/* --- the stage --- */

static oket_batch EDITS;
static oket_spans MARKS;

/* Appends to `buf`, advancing `*n`, and answers whether the whole of it fitted. snprintf returns
 * what it WOULD have written, so adding that straight to an offset walks off the end of the
 * buffer on the row after a truncated one. */
static int put(char *buf, size_t cap, size_t *n, const char *fmt, ...) {
    va_list ap;
    int     k;

    va_start(ap, fmt);
    k = vsnprintf(buf + *n, cap - *n, fmt, ap);
    va_end(ap);
    if (k < 0 || (size_t)k >= cap - *n) {
        return 0;
    }
    *n += (size_t)k;
    return 1;
}

/* How wide the pane showing this document is, in cells. A stage that guessed would draw its box
 * off the edge of a narrow panel (§12). */
static size_t pane_width(const oket_api *api, oket_self self, oket_doc doc) {
    const oket_world *w = api->world(api, self);
    size_t            i, out = BOX_MAX;

    if (w == NULL) {
        return out;
    }
    for (i = 0; i < w->npanes; i++) {
        if (w->panes[i].doc == doc && w->panes[i].w > 0) {
            out = (size_t)w->panes[i].w;
            break;
        }
    }
    api->world_release(api, self, w);
    return out;
}

/* The widest candidate plus its air, clamped to the pane. */
static size_t box_width(size_t room) {
    size_t i, cell, width = BOX_MIN;

    for (i = 0; i < POP.ncands; i++) {
        cell = strlen(POP.cands[i]) + 2;
        if (cell > width) {
            width = cell;
        }
    }
    return width < room ? width : room;
}

/* The box, into EDITS and MARKS: one row per candidate, hung under THE CARET IN THE SPACE WE
 * WERE HANDED. Not the document's: the stage before this one may have deleted the lines above,
 * and the row on screen is what a popup is positioned by. */
static void popup_box(const oket_api *api, oket_self self, const oket_at *at) {
    const oket_snapshot *s = at->snap;
    char                 box[(CANDS_MAX + 1) * (BOX_MAX + WORD_MAX)];
    size_t               line, col, lo, hi, pad, width, room, i, n = 0, row;

    line = (size_t)s->cursors[s->primary].head.line;
    col = (size_t)s->cursors[s->primary].head.col;
    if (line >= s->lines) {
        return;
    }
    oket_line_range(s, line, &lo, &hi);
    room = pane_width(api, self, at->doc);
    if (room > BOX_MAX * 2) {
        room = BOX_MAX * 2; /* the indent is padding, and the box buffer is what bounds it */
    }
    width = box_width(room);
    /* Under the caret's cell, pulled left when the box would hang off the edge. */
    pad = oket_col_cells(s, line, col, s->desc != NULL ? (size_t)s->desc->tab_width : 4);
    if (pad + width > room) {
        pad = room - width; /* width <= room, so this never underflows */
    }

    for (i = 0; i < POP.ncands; i++) {
        if (!put(box, sizeof box, &n, "\n%*s", (int)pad, "")) {
            break;
        }
        row = hi + n; /* the box's own bytes, in the document THESE edits make */
        if (!put(box, sizeof box, &n, " %-*s", (int)(width - 1), POP.cands[i])) {
            break;
        }
        oket_spans_add(&MARKS, row, hi + n, i == POP.pick ? PICKED : BOX, 0, OKET_SET_BG);
    }
    oket_batch_edit(&EDITS, hi, hi, box, n);
}

static int32_t popup_view(const oket_api *api, oket_self self, const oket_at *at,
                          oket_view_out *out) {
    oket_view_clear(&EDITS, &MARKS);
    if (popup_showing(at->doc) && at->snap->ncursors > 0) {
        popup_box(api, self, at);
    }
    oket_view_fill(out, &EDITS, &MARKS);
    return 0;
}

/* --- the verbs --- */

static int32_t complete_cmd(const oket_api *api, oket_self self, const oket_at *at,
                            const char *args, size_t args_len) {
    const oket_snapshot *s = at->snap;
    oket_batch           b;
    size_t               lo, hi;

    if (s == NULL) {
        return 1;
    }
    if (args_len == 5 && memcmp(args, "close", 5) == 0) {
        popup_close();
        return 0;
    }
    if (args_len == 6 && memcmp(args, "accept", 6) == 0) {
        if (!popup_showing(at->doc) || !caret_word(s, &lo, &hi)) {
            popup_close();
            return 1;
        }
        /* An ORDINARY submit against the document (§5). Nothing a view stage drew is involved:
         * the box has no bytes in the file, and this replaces the word the caret is in. */
        memset(&b, 0, sizeof b);
        oket_batch_edit(&b, lo, hi, POP.cands[POP.pick], strlen(POP.cands[POP.pick]));
        oket_batch_submit(api, self, at->doc, s->gen, &b);
        oket_batch_free(&b);
        popup_close();
        return 0;
    }
    /* Open, or step to the next candidate. Asking again is how the list is walked, so there is
     * no mode to be in and no second tier of binds while one is up. */
    if (popup_showing(at->doc)) {
        POP.pick = (POP.pick + 1) % POP.ncands;
        return 0;
    }
    popup_close();
    if (!caret_word(s, &lo, &hi) || hi - lo >= WORD_MAX) {
        oket_say(api, self, "point is not inside a word");
        return 1;
    }
    POP.prefix_len = oket_copy(s, lo, hi, POP.prefix, sizeof POP.prefix);
    gather(s);
    if (POP.ncands == 0) {
        oket_say(api, self, "nothing in this buffer carries on from that");
        return 1;
    }
    POP.doc = at->doc;
    POP.on = 1;
    return 0;
}

/* A generation that moved under the popup is a list gathered from a document that no longer
 * says that. Closing is the whole of the answer: nothing here is worth repairing. */
static int32_t popup_moved(const oket_api *api, oket_self self, const oket_at *at,
                           oket_event ev, const char *text, size_t len) {
    (void)api;
    (void)self;
    (void)text;
    (void)len;
    if (ev == OKET_EVENT_MOVED && POP.on && POP.doc == at->doc) {
        popup_close();
    }
    return 0;
}

OKET_MAIN {
    static const oket_kind_spec SPEC = {
        LIT("example"),
        LIT("surface"), /* rows, not characters: a listing is not a text field */
        {open_example, close_example, event},
    };
    EXAMPLE = api->register_kind(api, self, &SPEC);
    if (EXAMPLE == 0) {
        return 1; /* the ledger reverts nothing, because nothing went on */
    }
    api->register_command(api, self, LIT("example"), LIT("echo the line under point"), say);
    /* ASKED FOR, never claimed (§8): this becomes a row in binds.conf and the file decides
     * from then on. A chord already taken is written commented out, not stolen. */
    api->request_bind(api, self, LIT("global"), LIT("alt+h"), LIT("exec :ring example"));

    BOX = api->register_token(api, self, LIT("punctuation"));
    PICKED = api->register_token(api, self, LIT("accent"));
    api->register_view(api, self, popup_view);
    api->register_watch(api, self, popup_moved);
    api->register_command(api, self, LIT("complete"),
                          LIT("words that carry on from the one point is in; `accept`, `close`"),
                          complete_cmd);
    /* alt+/, which is dabbrev-expand's key in every Emacs there has ever been, and this is
     * dabbrev: the words already in the buffer. alt+w is the strip's width toggle. */
    api->request_bind(api, self, LIT("text"), LIT("alt+@AB10"), LIT("complete"));
    api->request_bind(api, self, LIT("text"), LIT("alt+shift+@AB10"), LIT("complete accept"));
    /* The pipeline is a config line, never a load order (§5). This stage goes AFTER fold, which
     * is what makes the box land under the row on screen. */
    api->request_config(api, self, LIT("edit"), LIT("view"), LIT("example"));
    return 0;
}
