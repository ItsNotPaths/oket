/* The plugin seam, in C. src/plug/abi.odin is the same declarations on the kernel's side, and
 * every struct here asserts the size that one asserts, so an ABI drift is a build error rather
 * than a corrupt read.
 *
 * A plugin is one `.so`, dlopen'd in-process and trusted (§7). It exports `oket_main` and
 * nothing else; there is no manifest to keep in step and no wire format to version.
 *
 * SIX MESSAGES:
 *
 *     register   plugin -> kernel   api->register_kind / register_command / request_bind
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

#define OKET_API 1

/* A plugin exports exactly this, and hidden visibility keeps everything else in. */
#define OKET_EXPORT __attribute__((visibility("default")))

typedef uint64_t oket_self;
typedef uint64_t oket_doc;
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

/* A named byte span inside one line, offsets from that line's start. */
typedef struct {
    const char *name;
    size_t      name_len;
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
    oket_kind          kind;
    int32_t            tab_width;
    uint8_t render, wrap, numbers, selection, follow, input, mouse, editable;
} oket_descriptor;

/* One replacement, in bytes. A batch is the transaction and one undo entry. The kernel copies
 * the text at submit, so your buffer may die the moment the call returns. */
typedef struct {
    size_t      lo, hi;
    const char *text;
    size_t      text_len;
} oket_edit;

typedef enum {
    OKET_REVEAL_NEAREST = 0, /* scroll as little as it takes */
    OKET_REVEAL_CENTER  = 1,
    OKET_REVEAL_TOP     = 2
} oket_reveal;

/* --- kernel -> plugin --- */

typedef enum {
    OKET_EVENT_CHORD = 0, /* the bind table routed a chord here; text is its spelling */
    OKET_EVENT_TEXT  = 1, /* a rune was typed into this document; text is its UTF-8 */
    OKET_EVENT_MOVED = 2  /* a document's generation moved */
} oket_event;

/* Where a call is happening. `doc` is the FOCUSED document, not only one you opened: that is
 * what lets a plugin act on a buffer it did not create. `inst` is non-NULL only when the
 * focused document is your own instance. */
typedef struct {
    oket_doc             doc;
    void                *inst;
    const oket_snapshot *snap;
} oket_at;

struct oket_api;

/* Non-zero claims the event; zero lets the kernel report it unhandled (§8). */
typedef int32_t (*oket_event_fn)(const struct oket_api *api, oket_self self, const oket_at *at,
                                 oket_event ev, const char *text, size_t len);

/* The kernel made a document for your kind and hands it over. The return is your instance
 * pointer, handed back on every later call and freed by `close`. `args` is what the command
 * line carried and is never NUL-terminated. */
typedef void *(*oket_open_fn)(const struct oket_api *api, oket_self self, oket_doc doc,
                              const char *args, size_t args_len);

typedef void (*oket_close_fn)(const struct oket_api *api, oket_self self, oket_doc doc,
                              void *inst);

/* The return is an exit code: 0 advances an `&&` chain, anything else stops it. */
typedef int32_t (*oket_command_fn)(const struct oket_api *api, oket_self self, const oket_at *at,
                                   const char *args, size_t args_len);

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

    /* submit. `d` may be NULL to leave the descriptor as it stands. Text is copied here, so
     * your buffer may die the moment this returns. A submit against a document that has moved
     * is dropped whole at the drain — oket_submit_retry() in oket_helpers.h is the loop you
     * use instead of writing one. */
    void (*submit)(const struct oket_api *api, oket_self self, oket_doc doc, uint64_t gen,
                   const oket_edit *edits, size_t nedits, const oket_descriptor *d);

    void (*reveal)(const struct oket_api *api, oket_self self, oket_doc doc,
                   size_t lo, size_t hi, oket_reveal at);

    /* Not a message: taking a REFERENCE is a call, reading through it is memory (§6). The
     * snapshot handed with a message is good for that call; take your own here to hold one
     * longer, and release it. */
    const oket_snapshot *(*snapshot)(const struct oket_api *api, oket_self self, oket_doc doc);
    void (*release)(const struct oket_api *api, oket_self self, const oket_snapshot *snap);

    /* The echo line. Lives until the next keystroke, same as the kernel's own messages. */
    void (*message)(const struct oket_api *api, oket_self self, const char *text, size_t len);
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
_Static_assert(sizeof(oket_field) == 32, "oket_field");
_Static_assert(sizeof(oket_descriptor) == 64, "oket_descriptor");
_Static_assert(sizeof(oket_edit) == 32, "oket_edit");
_Static_assert(sizeof(oket_at) == 24, "oket_at");
_Static_assert(sizeof(oket_kind_spec) == 56, "oket_kind_spec");

#ifdef __cplusplus
}
#endif
#endif /* OKET_H */
