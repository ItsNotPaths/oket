/* The smallest plugin that is a whole one (§7, stage 7).
 *
 * It registers a kind, a command and a bind request; it opens documents of that kind and fills
 * them in; it counts the chords routed to it; and it frees its instance in `close`. Unloading
 * it walks the ledger backwards and leaves the kernel exactly as it was.
 *
 * Note what is NOT here. There is no draw call, because plugins do not draw (§12): this
 * produces a document and a descriptor, and the kernel's one renderer draws it. There is no
 * generation anywhere, because oket_set reads the newest one for you (§6). There is no
 * `enter` handler, because `enter` over a row is a binds.conf line reading the `<name>` field
 * this file records — data the kernel reads, not a callback it makes (§5).
 *
 *     :pluginify plugins/hello        build it and load it
 *     alt+h                           open one, once the requested row is in binds.conf
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

static oket_kind HELLO;

/* Per-document state. A kind that remembered nothing would not need this at all; this one is
 * here to prove close() gets it back. */
typedef struct {
    unsigned chords;
    unsigned foreign; /* generations somebody ELSE moved */
} hello;

static void render(const oket_api *api, oket_self self, oket_doc doc, hello *h) {
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
                         h->chords, h->foreign);
    oket_build_cell(&b, "note", count, i);

    memset(&d, 0, sizeof d);
    d.kind = HELLO;
    d.render = OKET_RENDER_TEXT;
    d.selection = OKET_SELECT_LINE;
    /* `raw`, so a chord no row claims reaches event() below rather than going quiet (§8). */
    d.input = OKET_INPUT_RAW;
    d.tab_width = 4;
    oket_build_desc(&b, &d);
    oket_set(api, self, doc, b.text, b.oom ? 0 : b.len, &d);
    oket_build_free(&b);
}

static void *open_hello(const oket_api *api, oket_self self, oket_doc doc,
                        const char *args, size_t args_len) {
    hello *h = calloc(1, sizeof *h);
    (void)args;
    (void)args_len;
    if (h != NULL) {
        render(api, self, doc, h);
    }
    return h;
}

static void close_hello(const oket_api *api, oket_self self, oket_doc doc, void *inst) {
    (void)api;
    (void)self;
    (void)doc;
    free(inst);
}

static int32_t event(const oket_api *api, oket_self self, const oket_at *at,
                     oket_event ev, const char *text, size_t len) {
    hello *h = at->inst;

    if (h == NULL) {
        return 0;
    }
    /* Somebody else spliced our document — a formatter, a sort addon, `:put`. Nothing here
     * needs repairing, so it is only counted; a REPL would re-read its editable span here. The
     * kernel does not report our OWN writes, so counting one cannot start a loop. */
    if (ev == OKET_EVENT_MOVED) {
        h->foreign++;
        return 0;
    }
    if (ev == OKET_EVENT_CHORD && oket_chord_is(text, len, "@ESC")) {
        return 0; /* declined, so the kernel reports it rather than swallowing it */
    }
    h->chords++;
    render(api, self, at->doc, h);
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
        api->message(api, self, "hello", 5);
        return 0;
    }
    n = oket_line_copy(at->snap, (size_t)at->snap->cursors[at->snap->primary].head.line,
                       line, sizeof line);
    api->message(api, self, line, n);
    return 0;
}

OKET_MAIN {
    static const oket_kind_spec SPEC = {
        "hello", 5,
        "surface", 7, /* rows, not characters: a listing is not a text field */
        {open_hello, close_hello, event},
    };
    HELLO = api->register_kind(api, self, &SPEC);
    if (HELLO == 0) {
        return 1; /* the ledger reverts nothing, because nothing went on */
    }
    api->register_command(api, self, "hello", 5, "echo the line under point", 25, say);
    /* ASKED FOR, never claimed (§8): this becomes a row in binds.conf and the file decides
     * from then on. A chord already taken is written commented out, not stolen. */
    api->request_bind(api, self, "global", 6, "alt+h", 5, "exec :ring hello", 16);
    return 0;
}
