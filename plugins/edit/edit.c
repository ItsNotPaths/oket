/* The editor, as a plugin (§7, stage 8). THE DESIGN GATE: if the seam could not express one,
 * §5 would be redesigned rather than patched.
 *
 * It has no privileged path. It opens a file because the kernel handed it one, it reads a
 * snapshot the way every plugin does, and it writes through `submit` like every plugin does.
 * Nothing in the kernel knows this is the editor.
 *
 * WHAT IS HERE is the part that is genuinely an editor's, and it is small:
 *
 *   - reading a file in, writing it back (`:w`), and taking it back when it changes on disk
 *   - self-insert: what a typed rune MEANS. The kernel routes the rune and interprets none of
 *     it (§7) — a rune is the one input the bind table never sees, so the kernel deciding what
 *     it does would be an editing policy nobody could audit or rebind (§8).
 *   - the verbs that are policy rather than storage: a newline that keeps the indent and a
 *     Tab that lands on the next tab stop. Each is a row in binds.conf, shadowing the kernel's
 *     plain one for this kind alone.
 *
 * WHAT IS NOT HERE is everything the kernel owns for every document (§12): motion, the
 * viewport, undo, the placement verbs and the plain deletes. An editor buffer gets those with no
 * code at all, which is the whole reason this file is a few hundred lines and not 3,000. A
 * plugin that wants motion calls `oket(api)->move`.
 *
 *     :pluginify plugins/edit         build it and load it
 *     :open <file>                    the kernel hands a regular file to the `edit` kind
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "links.h"
#include "oket_helpers.h"

#define TAB_WIDTH 4
#define INDENT_MAX 256 /* a pasted-in wall of indent is not worth a heap allocation */

static lues_kind EDIT;
static lues_token LINK; /* the key :openlink reads (links.c) */

/* Per-document state. The text, the cursors and the undo history are the kernel's, and
 * re-reading them is a pointer walk rather than a copy we would have to keep in step (§6).
 *
 * `disk` is the exception: the file as we last saw it, and the only way to tell OUR unsaved
 * edits from somebody else's write. */
typedef struct {
    char   *path; /* owned; NULL for a buffer with no file yet */
    char   *disk; /* owned; the bytes the file had when we last read or wrote it */
    size_t  disk_len;
    lues_io watch; /* that path, watched (§9) */
    uint64_t scanned; /* the generation links were last scanned at, plus one; 0 is never */
} editor;

static void rescan(const lues_api *api, lues_self self);

static int same(const char *a, size_t alen, const char *b, size_t blen) {
    return alen == blen && (alen == 0 || memcmp(a, b, alen) == 0);
}

/* Takes ownership of `bytes`. */
static void disk_keep(editor *e, char *bytes, size_t len) {
    free(e->disk);
    e->disk = bytes;
    e->disk_len = len;
}

/* The document, flat. A piece table is what it is stored as; a file is a run of bytes. */
static char *buffer_bytes(const lues_snapshot *s, size_t *len) {
    char *buf = malloc(s->size + 1);

    *len = 0;
    if (buf == NULL) {
        return NULL;
    }
    *len = oket_copy(s, 0, s->size, buf, s->size);
    buf[*len] = '\0';
    return buf;
}

/* The descriptor this kind publishes (§5). `bound`, not `raw`: every chord goes through the
 * bind table, so an editor's keys are as auditable as any other document's — what reaches this
 * plugin is a rune, and rows naming the verbs below. */
static void describe(const editor *e, oket_descriptor *d) {
    memset(d, 0, sizeof *d);
    d->kind = EDIT;
    d->render = OKET_RENDER_TEXT;
    d->numbers = OKET_NUMBERS_ABSOLUTE;
    d->selection = OKET_SELECT_CHAR;
    d->input = OKET_INPUT_BOUND;
    d->editable = 1;
    d->tab_width = TAB_WIDTH;
    d->file = e->path;
    d->file_len = e->path == NULL ? 0 : strlen(e->path);
}

/* The kernel made the document and handed over the path it was asked to open. Reading it is
 * the opener's: the kernel decides nothing about what a file becomes (§7). */
static void *open_edit(const lues_api *api, lues_self self, lues_doc doc,
                       const char *args, size_t args_len) {
    editor *e = calloc(1, sizeof *e);
    oket_descriptor d;
    char *text = NULL;
    size_t len = 0;

    if (e == NULL) {
        return NULL;
    }
    if (args_len > 0) {
        e->path = oket_dup(args, args_len);
        text = e->path == NULL ? NULL : oket_file_read(e->path, 0, &len);
        if (text == NULL) {
            oket_say(api, self, "edit: that file will not read");
        }
    }
    describe(e, &d);
    oket_set(api, self, doc, text, len, &d);
    disk_keep(e, text, len);
    /* Naming the DOCUMENT routes the answer to this kind's event, not a watcher (§9). A path
     * that does not exist yet is watched all the same: the file appearing is reported. */
    if (e->path != NULL) {
        e->watch = api->io_watch(api, self, doc, e->path, strlen(e->path));
    }
    return e;
}

static void close_edit(const lues_api *api, lues_self self, lues_doc doc, void *inst) {
    editor *e = inst;

    (void)doc;
    if (e != NULL) {
        api->io_close(api, self, e->watch);
        free(e->path);
        free(e->disk);
        free(e);
    }
}

/* --- the file, changing underneath --- */

/* The smallest splice that turns the buffer into `now`, and it takes ownership of `now`. Only
 * the changed MIDDLE is submitted: a whole-buffer replace drags every caret onto it. */
static void take_disk(const lues_api *api, lues_self self, const lues_snapshot *s, editor *e,
                      char *now, size_t now_len) {
    size_t buf_len, lo, a, b;
    char *buf = buffer_bytes(s, &buf_len);

    if (buf == NULL) {
        free(now);
        return;
    }
    for (lo = 0; lo < buf_len && lo < now_len && buf[lo] == now[lo]; lo++) {
    }
    a = buf_len;
    b = now_len;
    while (a > lo && b > lo && buf[a - 1] == now[b - 1]) {
        a--;
        b--;
    }
    oket_replace(api, self, s->doc, lo, a, now + lo, b - lo);
    rescan(api, self);
    disk_keep(e, now, now_len); /* the baseline moves, so our own splice is not a foreign one */
    free(buf);
}

/* Three answers, told apart by the baseline: our own write coming back, a clean buffer that
 * takes the new file whole, or two edits of one file — say so and change nothing.
 * The third is the whole reason for the baseline; `ed.reload` is how you overrule it. */
static void changed(const lues_api *api, lues_self self, const lues_at *at, editor *e) {
    const lues_snapshot *s = at->snap;
    size_t now_len, buf_len;
    char *now, *buf;
    char note[512];

    now = oket_file_read(e->path, 0, &now_len);
    if (now == NULL) {
        return; /* deleted, or being written this instant; the buffer is what we still have */
    }
    if (same(now, now_len, e->disk, e->disk_len)) {
        free(now);
        return;
    }
    buf = buffer_bytes(s, &buf_len);
    if (buf == NULL) {
        free(now);
        return;
    }
    if (!same(buf, buf_len, e->disk, e->disk_len)) {
        snprintf(note, sizeof note, "edit: %s changed on disk", e->path);
        oket_say(api, self, note);
        free(buf);
        free(now);
        return;
    }
    free(buf);
    take_disk(api, self, s, e, now, now_len);
}

/* --- links --- */

/* Every document the generation moved on, this plugin's own included once rescan re-arms it.
 * Only ours are scanned, and only at a generation not scanned yet. */
static int32_t links_watch(const lues_api *api, lues_self self, const lues_at *at, lues_event ev,
                           const char *text, size_t len) {
    editor *e = at->inst;
    const lues_snapshot *s = at->snap;
    oket_spans out;
    char *buf, *dir = NULL, *slash;
    size_t n;

    (void)text;
    (void)len;
    if (ev != LUES_EVENT_MOVED || s == NULL || e == NULL || e->scanned == s->gen + 1) {
        return 0;
    }
    buf = buffer_bytes(s, &n);
    if (buf == NULL) {
        return 0;
    }
    if (e->path != NULL && (slash = strrchr(e->path, '/')) != NULL) {
        dir = oket_dup(e->path, (size_t)(slash - e->path));
    }
    memset(&out, 0, sizeof out);
    links_scan(buf, n, dir, LINK, &out);
    if (oket_spans_publish(api, self, s->doc, s->gen, 0, s->size, &out)) {
        e->scanned = s->gen + 1;
    }
    oket_spans_free(&out);
    free(dir);
    free(buf);
    return 0;
}

/* A watcher is never told about this plugin's own writes. Registering again forgets what it
 * was told, so the next frame shows every document once more and ours get rescanned. */
static void rescan(const lues_api *api, lues_self self) {
    api->register_watch(api, self, links_watch);
}

/* --- writing --- */

/* One edit per cursor, one transaction, one undo step: every caret's range becomes `text`. Each
 * edit NAMES its caret, so the one it leaves behind is the same caret and the primary does not
 * jump to the top of the set. */
static int insert_each_cursor(const lues_api *api, lues_self self, const lues_at *at,
                              const char *text, size_t len) {
    const lues_snapshot *s = at->snap;
    oket_batch b;
    size_t i;
    int sent;

    memset(&b, 0, sizeof b);
    for (i = 0; i < oket_side_of(s)->ncursors; i++) {
        size_t lo, hi;

        oket_cursor_span(s, i, &lo, &hi);
        oket_batch_edit_for(&b, oket_side_of(s)->cursors[i].id, lo, hi, text, len);
    }
    sent = oket_batch_submit(api, self, s->doc, s->gen, &b);
    oket_batch_free(&b);
    rescan(api, self);
    return sent;
}

/* The indent-aware newline: each caret takes "\n" plus its OWN line's leading whitespace,
 * which is why each edit in a batch carries its own string. */
static int newline_each_cursor(const lues_api *api, lues_self self, const lues_at *at) {
    const lues_snapshot *s = at->snap;
    oket_batch b;
    size_t i;
    int sent;

    memset(&b, 0, sizeof b);
    for (i = 0; i < oket_side_of(s)->ncursors; i++) {
        char text[INDENT_MAX] = "\n";
        char line[INDENT_MAX];
        size_t lo, hi, at_line, col, len, ind;

        oket_cursor_span(s, i, &lo, &hi);
        at_line = oket_line_at(s, lo);
        col = lo - oket_line_start(s, at_line);
        len = oket_line_copy(s, at_line, line, sizeof line);
        ind = oket_indent_cols(line, len < col ? len : col);
        if (ind > sizeof text - 1) {
            ind = sizeof text - 1;
        }
        memcpy(text + 1, line, ind);
        oket_batch_edit_for(&b, oket_side_of(s)->cursors[i].id, lo, hi, text, 1 + ind);
    }
    sent = oket_batch_submit(api, self, s->doc, s->gen, &b);
    oket_batch_free(&b);
    rescan(api, self);
    return sent;
}

/* Self-insert, and nothing else reaches here: `bound` means the bind table answered every
 * chord already. A generation that moved needs no repair — the text IS the state (§6). */
static int32_t event(const lues_api *api, lues_self self, const lues_at *at,
                     lues_event ev, const char *text, size_t len) {
    editor *e = at->inst;

    if (!oket_mine(at)) {
        return 0;
    }
    if (ev == LUES_EVENT_IO && at->io == e->watch) {
        changed(api, self, at, e);
        return 0;
    }
    if (ev != LUES_EVENT_TEXT) {
        return 0;
    }
    return insert_each_cursor(api, self, at, text, len);
}

/* --- the verbs that are policy --- */

/* A command answers an EXIT CODE: 0 advances an `&&` chain. Note the polarity is the opposite
 * of event()'s "did you claim it". */
static int32_t refuse(const lues_api *api, lues_self self, const char *why) {
    oket_say(api, self, why);
    return 1;
}

static int32_t newline_cmd(const lues_api *api, lues_self self, const lues_at *at,
                           const char *args, size_t args_len) {
    (void)args;
    (void)args_len;
    if (!oket_mine(at)) {
        return refuse(api, self, "ed.newline: this document is not the editor's");
    }
    newline_each_cursor(api, self, at);
    return 0;
}

/* Spaces to the next tab stop, which is a COLUMN question: the stop is counted in cells, so a
 * tab already on the line and a wide glyph both count for what they draw. */
static int32_t indent_cmd(const lues_api *api, lues_self self, const lues_at *at,
                          const char *args, size_t args_len) {
    static const char SPACES[TAB_WIDTH] = {' ', ' ', ' ', ' '};
    const lues_snapshot *s = at->snap;
    oket_batch b;
    size_t i;

    (void)args;
    (void)args_len;
    if (!oket_mine(at)) {
        return refuse(api, self, "ed.indent: this document is not the editor's");
    }
    memset(&b, 0, sizeof b);
    for (i = 0; i < oket_side_of(s)->ncursors; i++) {
        size_t lo, hi, line, cells;

        oket_cursor_span(s, i, &lo, &hi);
        line = oket_line_at(s, lo);
        cells = oket_col_cells(s, line, lo - oket_line_start(s, line), TAB_WIDTH);
        oket_batch_edit_for(&b, oket_side_of(s)->cursors[i].id, lo, hi, SPACES, TAB_WIDTH - cells % TAB_WIDTH);
    }
    oket_batch_submit(api, self, s->doc, s->gen, &b);
    oket_batch_free(&b);
    rescan(api, self);
    return 0;
}

/* `ed.reload` — the file, back into the buffer, unsaved edits and all. It is `changed`'s third
 * answer overruled: the watch REFUSES to touch a buffer that has edits the file does not, and
 * this is how the user says take it anyway. The kernel kept no verb for this — it reads no file
 * into a document, so it cannot re-read one either (PLAN.md §14's answer for `watch`). */
static int32_t reload_cmd(const lues_api *api, lues_self self, const lues_at *at,
                          const char *args, size_t args_len) {
    editor *e = at->inst;
    size_t len;
    char *now;
    char note[512];

    (void)args;
    (void)args_len;
    if (!oket_mine(at)) {
        return refuse(api, self, "reload: this document is not the editor's");
    }
    if (e->path == NULL) {
        return refuse(api, self, "reload: this buffer has no file");
    }
    now = oket_file_read(e->path, 0, &len);
    if (now == NULL) {
        snprintf(note, sizeof note, "reload: %s will not read", e->path);
        return refuse(api, self, note);
    }
    take_disk(api, self, at->snap, e, now, len);
    snprintf(note, sizeof note, "reloaded %s", e->path);
    oket_say(api, self, note);
    return 1;
}

/* `:w [path]` — the buffer, back to its file. The kernel's own `file.dump` writes a copy
 * into the state directory and knows nothing about paths, which is what leaves this verb here:
 * what a file IS on disk is the opener's business, and the opener is this plugin. */
static int32_t write_cmd(const lues_api *api, lues_self self, const lues_at *at,
                         const char *args, size_t args_len) {
    const lues_snapshot *s = at->snap;
    editor *e = at->inst;
    char note[512];
    char *buf;
    FILE *f;
    size_t n;

    if (!oket_mine(at)) {
        return refuse(api, self, "w: this document is not the editor's");
    }
    if (args_len > 0) {
        oket_descriptor d;

        free(e->path);
        e->path = oket_dup(args, args_len);
        describe(e, &d); /* the buffer takes the name it was written under */
        oket(api)->describe(api, self, s->doc, &d);
        api->submit(api, self, s->doc, s->gen, NULL, 0, NULL, 0);
        /* The watch follows the name: the file this buffer IS is the one worth hearing about. */
        api->io_close(api, self, e->watch);
        e->watch = e->path == NULL
                       ? 0
                       : api->io_watch(api, self, s->doc, e->path, strlen(e->path));
    }
    if (e->path == NULL) {
        return refuse(api, self, "w <path>");
    }
    buf = buffer_bytes(s, &n);
    if (buf == NULL) {
        return refuse(api, self, "w: out of memory");
    }
    f = fopen(e->path, "wb");
    if (f == NULL || fwrite(buf, 1, n, f) != n) {
        free(buf);
        if (f != NULL) {
            fclose(f);
        }
        return refuse(api, self, "w: the write failed");
    }
    fclose(f);
    /* The baseline moves to what we just wrote, so the watch that fires for our own save
     * has nothing to report. */
    disk_keep(e, buf, n);
    n = (size_t)snprintf(note, sizeof note, "wrote %zu bytes to %s", n, e->path);
    api->message(api, self, note, n < sizeof note ? n : sizeof note - 1);
    return 0;
}

LUES_MAIN {
    /* `text` is the bind context, so every motion, selection and delete row the kernel already
     * has serves this kind unchanged (§8). The kind's NAME is what `:open` hands a regular file
     * to, and what the `[edit]` section of binds.conf narrows to. */
    static const lues_kind_spec SPEC = {
        sizeof(lues_kind_spec),
        LIT("edit"),
        LIT("text"),
        {open_edit, close_edit, event},
    };

    EDIT = api->register_kind(api, self, &SPEC);
    if (EDIT == 0) {
        return 1; /* the ledger reverts nothing, because nothing went on */
    }
    LINK = api->register_token(api, self, LIT("link"));
    rescan(api, self);
    api->register_command(api, self, LIT("w"), LIT("write the buffer to its file"), write_cmd);
    api->register_command(api, self, LIT("ed.reload"),
                          LIT("drop unsaved edits and take the disk version"), reload_cmd);
    api->register_command(api, self, LIT("ed.newline"),
                          LIT("split the line and keep its indent"), newline_cmd);
    api->register_command(api, self, LIT("ed.indent"), LIT("spaces to the next tab stop"),
                          indent_cmd);
    /* ASKED FOR, never claimed (§8). Each of these shadows a kernel row for this kind alone —
     * plain enter and plain tab go on serving the command line and anything else. */
    api->request_bind(api, self, LIT("edit"), LIT("enter"), LIT(":ed.newline"));
    api->request_bind(api, self, LIT("edit"), LIT("shift+enter"), LIT(":ed.newline"));
    api->request_bind(api, self, LIT("edit"), LIT("tab"), LIT(":ed.indent"));
    api->request_bind(api, self, LIT("edit"), LIT("ctrl+@AC02"), LIT(":w")); /* ctrl+s */
    api->request_bind(api, self, LIT("edit"), LIT("@FK05"), LIT(":ed.reload")); /* f5 */
    /* Off a link, :openlink selects the word, so double-click loses nothing to it. */
    api->request_bind(api, self, LIT("edit"), LIT("alt+enter"), LIT(":openlink"));
    api->request_bind(api, self, LIT("edit"), LIT("double-click"), LIT(":openlink"));
    return 0;
}
