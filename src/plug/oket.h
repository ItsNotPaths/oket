/* oket's half of the plugin seam, in C. src/plug/abi.odin is the same declarations on the kernel's
 * side, and every struct here asserts the size that one asserts.
 *
 * A plugin is a lues plugin (lues.h): one `.so`, dlopen'd in-process, exporting `lues_main`
 * (LUES_MAIN). lues hands it a `const lues_api *`; oket's calls follow lues's in the same
 * struct, reached as `oket(api)->cursors(api, ...)`. Every snapshot carries oket's view of the
 * document behind `snap->app`: `oket_side_of(snap)`.
 *
 * What oket reads off lues's own types:
 *   lues_edit.tag        the caret that asked for the edit (oket_cursor.id), carried onto the
 *                        caret that replaces its range; 0 leaves the kernel to name it
 *   lues_span.attrs      OKET_ATTR_* bits
 *   LUES_SUBMIT_FORGET   REGEN: derived text, so the carets stay on their rows and the undo
 *                        log goes. Typing into the same document carries no flag.
 *
 * oket_helpers.h is what walks a snapshot; the helpers link INTO the plugin, so under -flto a
 * walk inlines into your loop and the half you never call is stripped.
 */
#ifndef OKET_H
#define OKET_H

#include "lues.h"

#ifdef __cplusplus
extern "C" {
#endif

#define OKET_API 10 /* lues_api.app_version, under app "oket" */

/* --- the descriptor's vocabulary (§5). The kernel's enum order, and it is an ABI. --- */

typedef enum { OKET_RENDER_TEXT = 0, OKET_RENDER_GRID = 1, OKET_RENDER_CELLS = 2 } oket_render;
typedef enum { OKET_WRAP_NONE = 0, OKET_WRAP_WORD = 1, OKET_WRAP_CHAR = 2 } oket_wrap;
typedef enum { OKET_NUMBERS_OFF = 0, OKET_NUMBERS_ABSOLUTE = 1, OKET_NUMBERS_RELATIVE = 2 } oket_numbers;
typedef enum { OKET_ALIGN_LEFT = 0, OKET_ALIGN_RIGHT = 1 } oket_align;
typedef enum { OKET_FOLLOW_NONE = 0, OKET_FOLLOW_TAIL = 1 } oket_follow;
typedef enum { OKET_INPUT_BOUND = 0, OKET_INPUT_RAW = 1 } oket_input;
typedef enum { OKET_MOUSE_BOUND = 0, OKET_MOUSE_EVENTS = 1 } oket_mouse;
typedef enum { OKET_SELECT_CHAR = 0, OKET_SELECT_LINE = 1, OKET_SELECT_NONE = 2 } oket_selection;

typedef struct {
    ptrdiff_t line;
    ptrdiff_t col; /* BYTES into the line */
} oket_pos;

/* anchor == head means no selection; head is the moving caret. `goal` is the sticky column
 * for vertical motion, in display cells (tabs expanded); negative asks the kernel to compute
 * it from head. `id` names the caret; 0 means "no identity", not "cursor zero". */
typedef struct {
    oket_pos  anchor, head;
    ptrdiff_t goal;
    uint32_t  id;
    uint8_t   _pad[4];
} oket_cursor;

/* A run of the document no cell on screen stands for (a fold). lo and hi draw at the same
 * cell; motion that crosses one steps over it. */
typedef struct {
    oket_pos lo, hi;
} oket_range;

/* --- the descriptor (§5) ---
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

/* A named byte span inside one line, offsets from that line's start. THE SPAN IS WHAT IS DRAWN
 * AND `value` IS WHAT IS ACTED ON: NULL means the span's own bytes fill `<name>`. Set it and a
 * line may show `browser.c` while `<path>` hands on the whole of where it lives — a LINK. */
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
    /* One per LINE, dense and in line order. A short array leaves the rest at depth 0. */
    const int32_t     *depth;
    size_t             ndepth;
    lues_kind          kind;
    int32_t            tab_width;
    uint8_t render, wrap, numbers, selection, follow, input, mouse, editable;
} oket_descriptor;

/* snap->app: the document as oket sees it, at the snapshot's generation. `hidden` is empty
 * inside a view stage: the text handed to one is already the derived text. */
typedef struct {
    const oket_descriptor *desc;
    const oket_cursor     *cursors;
    size_t                 ncursors, primary;
    const oket_range      *hidden;
    size_t                 nhidden;
} oket_side;

/* --- style runs (§5, VIEWS §8) --- A token, never a colour: the theme decides. */

typedef enum {
    OKET_TOK_FG     = 0,
    OKET_TOK_BG     = 1,
    OKET_TOK_ACCENT = 2,
    OKET_TOK_DIM    = 3,
    OKET_TOK_ALERT  = 4,
    OKET_TOKEN_BASE = 5 /* ids below this are the base vocabulary; the rest were interned */
} oket_style;

/* lues_span.attrs */
enum {
    OKET_ATTR_BOLD      = 1 << 0,
    OKET_ATTR_ITALIC    = 1 << 1,
    OKET_ATTR_UNDERLINE = 1 << 2,
    OKET_ATTR_REVERSE   = 1 << 3
};

typedef enum {
    OKET_REVEAL_NEAREST = 0, /* scroll as little as it takes */
    OKET_REVEAL_CENTER  = 1,
    OKET_REVEAL_TOP     = 2
} oket_reveal;

/* --- the view pipeline (§5) ---
 *
 * A stage is handed the PREVIOUS stage's output and returns edits in that space. Nothing here
 * reaches the document: a view edit is never submitted, journalled or saved.
 *
 * `edits` are against the text you were handed, sorted by `lo` and disjoint. `spans` are over
 * YOUR OWN OUTPUT. Set `size` on each, as for a submit; both are copied before the call
 * returns. */
typedef struct {
    const lues_edit *edits;
    size_t           nedits;
    const lues_span *spans;
    size_t           nspans;
} oket_view_out;

/* Non-zero is the latch: "not finished, call me again next frame". */
typedef int32_t (*oket_view_fn)(const lues_api *api, lues_self self, const lues_at *at,
                                oket_view_out *out);

/* --- the world (§12): the layout, built per call and read as memory --- */

typedef struct {
    lues_doc doc;
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

/* --- oket's calls, after lues's --- */

typedef struct oket_api {
    lues_api lues;

    /* The descriptor your next submit to `doc` lands with, at that submit's generation, so the
     * fields it names and the text they sit on cannot disagree. A descriptor alone is a submit
     * with no edits. */
    void (*describe)(const lues_api *api, lues_self self, lues_doc doc,
                     const oket_descriptor *d);

    void (*reveal)(const lues_api *api, lues_self self, lues_doc doc, size_t lo, size_t hi,
                   oket_reveal at);

    /* The cursor set, named exactly (CURSORS.md §4), copied at the call. It lands with your
     * pending submit, and is dropped with it if that loses the race; with nothing pending it is
     * a bare move, and the generation does not move. */
    void (*cursors)(const lues_api *api, lues_self self, lues_doc doc,
                    const oket_cursor *curs, size_t n, size_t primary);

    /* A view stage (§5). ONE per plugin, ranked by PLUGIN NAME on a `[<kind>] view =` line;
     * a plugin no line names is never called. Registering again replaces it. */
    void (*register_view)(const lues_api *api, lues_self self, oket_view_fn fn);

    const oket_world *(*world)(const lues_api *api, lues_self self);
    void (*world_release)(const lues_api *api, lues_self self, const oket_world *w);
} oket_api;

static inline const oket_api *oket(const lues_api *api) {
    return (const oket_api *)api;
}

static inline const oket_side *oket_side_of(const lues_snapshot *s) {
    return (const oket_side *)s->app;
}

LUES_SIZE(oket_pos, 16);
LUES_SIZE(oket_cursor, 48);
LUES_SIZE(oket_range, 32);
LUES_SIZE(oket_column, 24);
LUES_SIZE(oket_field, 48);
LUES_SIZE(oket_descriptor, 80);
LUES_SIZE(oket_side, 48);
LUES_SIZE(oket_view_out, 32);
LUES_SIZE(oket_pane, 32);
LUES_SIZE(oket_world, 24);
LUES_SIZE(oket_api, sizeof(lues_api) + 6 * sizeof(void *));

#ifdef __cplusplus
}
#endif
#endif /* OKET_H */
