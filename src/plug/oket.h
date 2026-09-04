/* The plugin seam, in C. src/plug/abi.odin is the same declarations on the kernel's side, and
 * every struct here asserts the size that one asserts, so an ABI drift is a build error rather
 * than a corrupt read.
 *
 * A plugin is one `.so`, dlopen'd in-process and trusted (§7). It exports `oket_main` and
 * nothing else; there is no manifest to keep in step and no wire format to version.
 *
 * SIX MESSAGES:
 *
 *     register   plugin -> kernel   api->register_kind / register_command / request_bind /
 *                                    register_token / register_watch
 *     submit     plugin -> kernel   api->submit
 *     reveal     plugin -> kernel   api->reveal
 *     event      kernel -> plugin   oket_kind_vt.event
 *     open       kernel -> plugin   oket_kind_vt.open
 *     close      kernel -> plugin   oket_kind_vt.close
 *
 * Reads are not among them. Every call into a plugin hands over an `oket_snapshot`, and the
 * plugin reads text, the line index, cursors and the descriptor straight out of it by pointer.
 * oket_helpers.h is what walks it; the helpers link INTO the plugin, so under -flto a walk
 * inlines into your loop and the half you never call is stripped.
 */
#ifndef OKET_H
#define OKET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OKET_API 7

/* A plugin exports exactly this, and hidden visibility keeps everything else in. */
#define OKET_EXPORT __attribute__((visibility("default")))

typedef uint64_t oket_self;
typedef uint64_t oket_doc;
/* An I/O job — a subprocess, or a watched path (§9). Packed and refused like a doc, so a
 * handle held past the job's end names nothing rather than whoever spawned next. */
typedef uint64_t oket_io;
typedef uint32_t oket_kind;

/* --- the descriptor's vocabulary (§5). The kernel's enum order, and it is an ABI. --- */

typedef enum { OKET_RENDER_TEXT = 0, OKET_RENDER_GRID = 1, OKET_RENDER_CELLS = 2 } oket_render;
typedef enum { OKET_WRAP_NONE = 0, OKET_WRAP_WORD = 1, OKET_WRAP_CHAR = 2 } oket_wrap;
typedef enum { OKET_NUMBERS_OFF = 0, OKET_NUMBERS_ABSOLUTE = 1, OKET_NUMBERS_RELATIVE = 2 } oket_numbers;
typedef enum { OKET_ALIGN_LEFT = 0, OKET_ALIGN_RIGHT = 1 } oket_align;
typedef enum { OKET_FOLLOW_NONE = 0, OKET_FOLLOW_TAIL = 1 } oket_follow;
typedef enum { OKET_INPUT_BOUND = 0, OKET_INPUT_RAW = 1 } oket_input;
typedef enum { OKET_MOUSE_BOUND = 0, OKET_MOUSE_EVENTS = 1 } oket_mouse;
typedef enum { OKET_SELECT_CHAR = 0, OKET_SELECT_LINE = 1, OKET_SELECT_NONE = 2 } oket_selection;

/* --- the read view (§6) ---
 *
 * A snapshot is a piece table, so a run of text is what exists in memory and a flat string is
 * what would have to be manufactured. These mirror the kernel's own arrays and point straight
 * into them: the kernel builds the header, never the bytes. Good until you release it. */

typedef struct {
    uint8_t *ptr;
    size_t   len;
} oket_block;

/* [off, off+len) of blocks[block], sitting at [doc_off, doc_off+len) of the document. */
typedef struct {
    ptrdiff_t block, off, len, doc_off;
} oket_piece;

/* Lines [first, first+n) start at starts[at ..< at+n], each read back with `delta` added. */
typedef struct {
    ptrdiff_t first, at, n, delta;
} oket_seg;

typedef struct {
    ptrdiff_t line;
    ptrdiff_t col; /* BYTES into the line */
} oket_pos;

/* anchor == head means no selection; head is the moving caret. */
typedef struct {
    oket_pos  anchor, head;
    ptrdiff_t goal;
} oket_cursor;

struct oket_descriptor;

typedef struct {
    const struct oket_descriptor *desc;
    const oket_block  *blocks;
    const ptrdiff_t   *starts;
    const oket_piece  *pieces;
    const oket_seg    *segs;
    const oket_cursor *cursors;
    size_t   nblocks, nstarts, npieces, nsegs, ncursors, primary;
    size_t   size;  /* bytes */
    size_t   lines;
    uint64_t gen;
    oket_doc doc;
} oket_snapshot;

/* --- the descriptor, read and written through one struct (§5) ---
 *
 * No `ctx` field: a kind's bind context is fixed where the kind is registered, so publishing a
 * descriptor cannot move your documents into another context's keys. */

typedef struct {
    const char *name;
    size_t      name_len;
    int32_t     width;
    uint8_t     align; /* oket_align */
    uint8_t     _pad[3];
} oket_column;

/* A named byte span inside one line, offsets from that line's start.
 *
 * THE SPAN IS WHAT IS DRAWN AND `value` IS WHAT IS ACTED ON. NULL, the common case, means the
 * two are the same and the span's own bytes fill `<name>`. Set it and a line may show a bare
 * `browser.c` while `<path>` hands on the whole of where it lives — which is what makes a row
 * a LINK, and the one thing a span alone cannot say. */
typedef struct {
    const char *name;
    size_t      name_len;
    const char *value; /* NULL: the span's own bytes are the value */
    size_t      value_len;
    int32_t     line, lo, hi;
    uint8_t     _pad[4];
} oket_field;

typedef struct oket_descriptor {
    const char        *file;
    size_t             file_len;
    const oket_column *columns;
    size_t             ncolumns;
    const oket_field  *fields;
    size_t             nfields;
    /* One per LINE, dense and in line order, unlike the fields above. A short array leaves the
     * rest of the document at depth 0. */
    const int32_t     *depth;
    size_t             ndepth;
    oket_kind          kind;
    int32_t            tab_width;
    uint8_t render, wrap, numbers, selection, follow, input, mouse, editable;
} oket_descriptor;

/* What a submit is, beyond its bytes. The kernel cannot read this off the edits: replacing a
 * whole document and replacing a whole selection are the same two offsets.
 *
 * REGEN says this text is DERIVED rather than typed, and two rules follow from the one word.
 * The carets stay on their rows, because navigation put them there: a tree that expands a
 * directory rewrites every row under it, and point following that splice to the end of the
 * document is a tree you cannot walk. And the undo log is forgotten, because there is nothing
 * of the user's in derived text to take back.
 *
 * Typing into that same tree to rename a file carries no flag: it collapses and it undoes, the
 * way an editor's must. A document that takes no typing at all keeps its carets either way. */
enum {
    OKET_SUBMIT_REGEN = 1 << 0
};

/* One replacement, in bytes. A batch is the transaction and one undo entry. The kernel copies
 * the text at submit, so your buffer may die the moment the call returns. */
typedef struct {
    size_t      lo, hi;
    const char *text;
    size_t      text_len;
} oket_edit;

/* --- style runs (§5, VIEWS §8) ---
 *
 * A style TOKEN, never a colour: the theme decides what it looks like, and a plugin that names
 * an RGB value breaks every theme. An id and not an enum, because a syntax vocabulary is open —
 * the five below are always there, and any other name is interned through register_token. */

typedef uint16_t oket_token;

typedef enum {
    OKET_TOK_FG     = 0,
    OKET_TOK_BG     = 1,
    OKET_TOK_ACCENT = 2,
    OKET_TOK_DIM    = 3,
    OKET_TOK_ALERT  = 4,
    OKET_TOKEN_BASE = 5 /* ids below this are the base vocabulary; the rest were interned */
} oket_style;

/* Cell attributes, as bits on a span. */
enum {
    OKET_ATTR_BOLD      = 1 << 0,
    OKET_ATTR_ITALIC    = 1 << 1,
    OKET_ATTR_UNDERLINE = 1 << 2,
    OKET_ATTR_REVERSE   = 1 << 3
};

/* Which channels a run SETS. What it leaves unset is whoever is below it, so a parser saying
 * `fg`, a linter saying `underline` and a search saying `bg` all draw at one byte instead of
 * the top one deleting the other two.
 *
 * There is no layer here. WHO published is the ordering: the kernel knows which plugin called,
 * and `[<kind>] spans = a, b, c` in config.conf says which of them draws over which. */
enum {
    OKET_SET_FG    = 1 << 0,
    OKET_SET_BG    = 1 << 1, /* the token paints the BACKGROUND of this run */
    OKET_SET_ATTRS = 1 << 2  /* including `attrs = 0`, which is how a run clears them */
};

/* A run of the document, in BYTES, with a style token on it. Not a line and a column: a line
 * number is a display convenience, and making it the unit costs every run that crosses a line
 * end. */
typedef struct {
    size_t     lo, hi;
    oket_token tok;
    uint8_t    attrs; /* OKET_ATTR_* */
    uint8_t    set;   /* OKET_SET_*; a run that sets nothing draws nothing */
    uint8_t    _pad[4];
} oket_span;

/* One PUBLISHER's range-scoped REPLACE, as it rides a submit. Whatever this plugin held inside
 * [lo, hi) is dropped and `spans` takes its place, so republishing a viewport does not make the
 * store grow with the file. Out of order, overlapping and out of range are all survived: the
 * kernel clips, sorts, and lets the span that starts first win.
 *
 * There is no publisher field: the kernel knows which plugin called. */
typedef struct {
    size_t     lo, hi;
    const oket_span *spans;
    size_t     nspans;
} oket_span_pub;

typedef enum {
    OKET_REVEAL_NEAREST = 0, /* scroll as little as it takes */
    OKET_REVEAL_CENTER  = 1,
    OKET_REVEAL_TOP     = 2
} oket_reveal;

/* --- the view pipeline (§5) ---
 *
 * A stage is handed the PREVIOUS stage's output and returns edits in that space. That is why
 * this is a pipeline and not a fan: a popup positioned against the original would land in the
 * wrong place the moment a fold above it deleted lines.
 *
 * Nothing here reaches the document. A view edit is never submitted, never journalled and never
 * saved; it derives what is DRAWN, and motion, undo, find and `:w` go on seeing the original.
 * Text you insert is not enterable either: point never lands in it. */

/* `edits` are against the text you were handed, sorted by `lo` and disjoint. `spans` are over
 * YOUR OWN OUTPUT — the text after those edits — because what a stage wants to colour is
 * usually what it just inserted, and that has no original bytes to name.
 *
 * Both point into your memory and are copied before the call returns. */
typedef struct {
    const oket_edit *edits;
    size_t           nedits;
    const oket_span *spans;
    size_t           nspans;
} oket_view_out;

/* --- the world (§12) ---
 *
 * A stage has to size what it inserts, and a popup that cannot ask how wide the pane is draws
 * off the edge. Shaped like oket_snapshot: built, flat, taken by a call and read as memory. */
typedef struct {
    oket_doc doc;
    /* The BODY, in cells: the gutter is outside it, and `y` counts from the top of the
     * surface. */
    int32_t  x, y, w, h;
    int32_t  top; /* the first line drawn, in the DERIVED document */
    uint8_t  focused;
    char     _pad[3];
} oket_pane;

typedef struct {
    const oket_pane *panes;
    size_t           npanes;
    int32_t          cols, rows; /* the whole surface, in cells */
} oket_world;

/* --- kernel -> plugin --- */

typedef enum {
    OKET_EVENT_CHORD = 0, /* the bind table routed a chord here; text is its spelling */
    OKET_EVENT_TEXT  = 1, /* a rune was typed into this document; text is its UTF-8 */
    OKET_EVENT_MOVED = 2, /* a generation moved, or a watcher has not seen this document yet */
    /* An I/O job said something (§9). `at->io` names it; text is a frame's worth of a child's
     * stdout, or the path a watch saw change. Nothing is held for you: what you do not copy
     * inside this call is gone. */
    OKET_EVENT_IO     = 3,
    /* That job is over and `at->code` is its exit status. Never sent for a job you closed. */
    OKET_EVENT_IO_END = 4
} oket_event;

/* Where a call is happening. `doc` is the FOCUSED document — or, for a watcher, the document
 * that moved — and not only one you opened: that is what lets a plugin act on a buffer it did
 * not create. `inst` is non-NULL only when the document is your own instance. */
typedef struct {
    oket_doc             doc;
    void                *inst;
    const oket_snapshot *snap;
    oket_io              io;   /* the job an IO event names; zero on every other event */
    int32_t              code; /* OKET_EVENT_IO_END's exit status */
    char                 _pad[4];
} oket_at;

struct oket_api;

/* Non-zero claims the event; zero lets the kernel report it unhandled (§8).
 *
 * A WATCHER's return means the other thing, and it is cooperative slicing (§9): non-zero says
 * "not finished, call me again next frame" and the kernel does, on the same document, whether or
 * not its generation moved again. A cold parse too big for one frame spreads over several that
 * way, with no thread and no seventh message.
 *
 * An I/O event's return is IGNORED. The latch is a record kept per DOCUMENT and a job need not
 * name one, so there is nowhere honest to put it; work an answer starts is spread over frames on
 * the document it writes to, through the latch that already exists. */
typedef int32_t (*oket_event_fn)(const struct oket_api *api, oket_self self, const oket_at *at,
                                 oket_event ev, const char *text, size_t len);

/* The kernel made a document for your kind and hands it over. The return is your instance
 * pointer, handed back on every later call and freed by `close`. `args` is what the command
 * line carried and is never NUL-terminated. */
typedef void *(*oket_open_fn)(const struct oket_api *api, oket_self self, oket_doc doc,
                              const char *args, size_t args_len);

typedef void (*oket_close_fn)(const struct oket_api *api, oket_self self, oket_doc doc,
                              void *inst);

/* The return is an exit code: 0 advances an `&&` chain, anything else stops it.
 *
 * `args` is the rest of the line, with ONE surrounding quote pair taken off when the whole of
 * it is one quoted value — a `<name>` hole fills quoted where its value would re-parse, and
 * this is where that line ends. A command taking two arguments gets its line as typed and
 * splits it itself. Never NUL-terminated. */
typedef int32_t (*oket_command_fn)(const struct oket_api *api, oket_self self, const oket_at *at,
                                   const char *args, size_t args_len);

/* A non-zero return is the latch, the same meaning an event handler's carries for a watcher:
 * "not finished, call me again next frame". What you emitted this time is still drawn, so a
 * stage too cold for one frame settles over several with no new convention. */
typedef int32_t (*oket_view_fn)(const struct oket_api *api, oket_self self, const oket_at *at,
                                oket_view_out *out);

typedef struct {
    oket_open_fn  open;
    oket_close_fn close;
    oket_event_fn event;
} oket_kind_vt;

/* `ctx` names the bind context this kind's documents route in: "text", "surface" or
 * "terminal". NULL means surface, which is what a document that is not a text field wants. */
typedef struct {
    const char  *name;
    size_t       name_len;
    const char  *ctx;
    size_t       ctx_len;
    oket_kind_vt vt;
} oket_kind_spec;

/* --- plugin -> kernel ---
 *
 * Every call hands the api pointer back, so a plugin needs no state of its own. */

typedef struct oket_api {
    uint32_t version;

    /* register. Three entry points, one message: each appends a ledger record, and unload
     * walks the ledger backwards. */
    oket_kind (*register_kind)(const struct oket_api *api, oket_self self,
                               const oket_kind_spec *spec);
    void (*register_command)(const struct oket_api *api, oket_self self,
                             const char *name, size_t name_len,
                             const char *doc, size_t doc_len, oket_command_fn fn);
    /* A plugin never CLAIMS a chord (§8): it asks, the row becomes a line in binds.conf, and
     * the file decides from then on. */
    void (*request_bind)(const struct oket_api *api, oket_self self,
                         const char *ctx, size_t ctx_len,
                         const char *chord, size_t chord_len,
                         const char *line, size_t line_len);
    /* The same rule one file over: a setting you need is WRITTEN to config.conf if that
     * section has no such key, and from then on the file decides. A view stage asks for its own
     * name in `[<kind>] view` this way, so installing it is copying the `.so` in. */
    void (*request_config)(const struct oket_api *api, oket_self self,
                           const char *section, size_t section_len,
                           const char *key, size_t key_len,
                           const char *value, size_t value_len);
    /* Interns a style-token name and answers its id, the same id for the same name whoever
     * asks: two plugins naming "keyword" get one colour because the palette maps the name.
     * Falls back to OKET_TOK_FG when the table is full, which draws rather than fails. */
    oket_token (*register_token)(const struct oket_api *api, oket_self self,
                                 const char *name, size_t name_len);
    /* A plugin that draws nothing asks to be told about documents it did not open: `fn` is
     * called with OKET_EVENT_MOVED for every open document you have not seen at its current
     * generation.
     *
     * Registering again replaces the handler AND forgets what you have been told, so every open
     * document arrives once more. That is how you ask to look again at something the kernel
     * cannot see having changed — a grammar that finished building, a config reloaded. */
    void (*register_watch)(const struct oket_api *api, oket_self self, oket_event_fn fn);
    /* A view stage (§5). ONE per plugin, because the config line that orders the stages ranks
     * them by PLUGIN NAME — the same rule spans follow, where the producer is the layer (§8).
     * Registering again replaces it. A plugin whose name no `view =` line carries is never
     * called, which is what makes installing one a config decision and not a load order. */
    void (*register_view)(const struct oket_api *api, oket_self self, oket_view_fn fn);

    /* submit. `d` may be NULL to leave the descriptor as it stands. Text is copied here, so
     * your buffer may die the moment this returns. A submit against a document that has moved
     * is dropped whole at the drain, and you are told through an OKET_EVENT_MOVED. oket_set
     * and oket_replace in oket_helpers.h read the newest generation for you; oket_batch_submit
     * takes the one off the snapshot you read.
     *
     * `spans` may be NULL to leave this plugin's runs as they stand. Edits, descriptor and
     * spans land together at ONE generation, so nothing ever paints a colour against bytes it
     * was not measured over. `flags` is OKET_SUBMIT_* and 0 for an ordinary edit. */
    void (*submit)(const struct oket_api *api, oket_self self, oket_doc doc, uint64_t gen,
                   const oket_edit *edits, size_t nedits, const oket_descriptor *d,
                   const oket_span_pub *spans, uint32_t flags);

    void (*reveal)(const struct oket_api *api, oket_self self, oket_doc doc,
                   size_t lo, size_t hi, oket_reveal at);

    /* Point, put somewhere. The kernel owns the cursors and every motion verb writes them, so
     * this is not how a document is navigated — it is for the case where the row point was on
     * STOPS EXISTING because of what you just submitted. A tree collapsing a subtree has to
     * leave point on the parent, and the line it was standing on is gone.
     *
     * A byte offset, and it collapses every cursor to one caret there. It lands with the
     * transaction, not before it: writes still happen at one point in the frame, so a submit
     * and the point that goes with it arrive at the same generation. */
    void (*point)(const struct oket_api *api, oket_self self, oket_doc doc, size_t off);

    /* Not a message: taking a REFERENCE is a call, reading through it is memory (§6). The
     * snapshot handed with a message is good for that call; take your own here to hold one
     * longer, and release it. */
    const oket_snapshot *(*snapshot)(const struct oket_api *api, oket_self self, oket_doc doc);
    void (*release)(const struct oket_api *api, oket_self self, const oket_snapshot *snap);

    /* The layout, the same way (§12). Cheap, and rebuilt per call: what is on screen changes
     * every frame, so there is nothing here worth holding. */
    const oket_world *(*world)(const struct oket_api *api, oket_self self);
    void (*world_release)(const struct oket_api *api, oket_self self, const oket_world *w);

    /* The echo line. Lives until the next keystroke, same as the kernel's own messages. */
    void (*message)(const struct oket_api *api, oket_self self, const char *text, size_t len);

    /* --- I/O (§9) ---
     *
     * Not a seventh message: what a job says arrives through `event`, at the same handler a
     * moved generation would reach. `doc` is what does that routing — a job on one of your own
     * documents reaches its kind, and doc = 0 reaches your watcher — and it is the only thing
     * the kernel reads it for.
     *
     * Nothing here blocks. One kernel thread does the waiting for every plugin, and your
     * handler is called on the main thread like all the rest, so you still never see a thread.
     */

    /* A child process. `argv` is `nargv` NUL-terminated strings, argv[0] resolved through PATH.
     * Its STDERR IS INHERITED: merging it into stdout corrupts a framed protocol, and a shell
     * redirect already captures it. Zero when it could not start. */
    oket_io (*io_spawn)(const struct oket_api *api, oket_self self, oket_doc doc,
                        const char *const *argv, size_t nargv, const char *cwd, size_t cwd_len);
    /* Bytes for that child's stdin, queued: the write happens on the kernel's thread, so a full
     * pipe costs you nothing. */
    void (*io_write)(const struct oket_api *api, oket_self self, oket_io io,
                     const char *bytes, size_t len);
    /* A path. Its DIRECTORY is what is watched and the name is the filter, because a save by
     * rename leaves a watch on the file holding an inode nobody will write again. */
    oket_io (*io_watch)(const struct oket_api *api, oket_self self, oket_doc doc,
                        const char *path, size_t path_len);
    /* Ends it: the child's process group is signalled and the watch dropped. Silent — a job you
     * ended is not one you need telling about. */
    void (*io_close)(const struct oket_api *api, oket_self self, oket_io io);
} oket_api;

/* The one symbol you export. Non-zero refuses the load, and the ledger reverts whatever you
 * managed to register first.
 *
 *     OKET_MAIN { api->register_command(api, self, "hi", 2, "say hi", 6, say_hi); return 0; }
 */
#define OKET_MAIN \
    OKET_EXPORT int32_t oket_main(const oket_api *api, oket_self self)

typedef int32_t (*oket_entry_fn)(const oket_api *api, oket_self self);

_Static_assert(sizeof(oket_block) == 16, "oket_block");
_Static_assert(sizeof(oket_piece) == 32, "oket_piece");
_Static_assert(sizeof(oket_seg) == 32, "oket_seg");
_Static_assert(sizeof(oket_cursor) == 40, "oket_cursor");
_Static_assert(sizeof(oket_snapshot) == 128, "oket_snapshot");
_Static_assert(sizeof(oket_column) == 24, "oket_column");
_Static_assert(sizeof(oket_field) == 48, "oket_field");
_Static_assert(sizeof(oket_descriptor) == 80, "oket_descriptor");
_Static_assert(sizeof(oket_edit) == 32, "oket_edit");
_Static_assert(sizeof(oket_span) == 24, "oket_span");
_Static_assert(sizeof(oket_span_pub) == 32, "oket_span_pub");
_Static_assert(sizeof(oket_at) == 40, "oket_at");
_Static_assert(sizeof(oket_view_out) == 32, "oket_view_out");
_Static_assert(sizeof(oket_pane) == 32, "oket_pane");
_Static_assert(sizeof(oket_world) == 24, "oket_world");
_Static_assert(sizeof(oket_kind_spec) == 56, "oket_kind_spec");

#ifdef __cplusplus
}
#endif
#endif /* OKET_H */
