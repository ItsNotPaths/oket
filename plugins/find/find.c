/* A live preview of `:find`: while the line's last builtin step is `:find <text>`, every match in the
 * focused document is marked, and the one enter would land on is reversed. up and down step
 * that one through the matches. Enter still runs the builtin; this plugin only shows it.
 * `:grep` and its lane are grep.c.
 *
 *     :pluginify plugins/find
 */
#define _GNU_SOURCE /* memmem */
#include <stdlib.h>
#include <string.h>

#include "grep.h"

// (hole find-preview-delete :tags live :needs (live-whitelist) :sev cleanup) re-parses the CL and copies doc_find_all; all but grep_register goes
#define PREFIX ":find "

static char      *PAT;
static size_t     PAT_LEN;
static lues_doc   TARGET = LUES_NO_DOC;
static oket_spans OUT;

static size_t *HITS;
static size_t  NHITS, HITS_CAP;

static int is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static void trim(const char **s, size_t *n) {
    while (*n > 0 && is_space(**s)) {
        (*s)++, (*n)--;
    }
    while (*n > 0 && is_space((*s)[*n - 1])) {
        (*n)--;
    }
}

/* The pattern the line's last builtin step asks for, or none when that step is not a `:find`.
 * Trimmed as the builtin trims. */
static void pattern_read(const lues_snapshot *line, size_t step, size_t step_len) {
    char       *text = malloc(step_len + 1);
    const char *s = text;
    size_t      n;

    PAT_LEN = 0;
    if (!text) {
        return;
    }
    n = oket_copy(line, step, step + step_len, text, step_len);
    trim(&s, &n);
    if (n > strlen(PREFIX) && memcmp(s, PREFIX, strlen(PREFIX)) == 0) {
        s += strlen(PREFIX), n -= strlen(PREFIX);
        trim(&s, &n);
        free(PAT);
        PAT = oket_dup(s, n);
        PAT_LEN = PAT ? n : 0;
    }
    free(text);
}

/* Match starts, non-overlapping, as `txt.doc_find_all` finds them. A pattern holds no newline,
 * so a search over the whole text finds what one per line would. */
static void hits_find(const lues_snapshot *s) {
    char       *text = malloc(s->size);
    const char *at, *end;

    NHITS = 0;
    if (!text || PAT_LEN == 0) {
        free(text);
        return;
    }
    oket_copy(s, 0, s->size, text, s->size);
    end = text + s->size;
    for (at = text; (at = memmem(at, (size_t)(end - at), PAT, PAT_LEN)); at += PAT_LEN) {
        if (NHITS == HITS_CAP) {
            size_t *grown = realloc(HITS, (HITS_CAP ? HITS_CAP * 2 : 64) * sizeof *HITS);
            if (!grown) {
                break;
            }
            HITS = grown;
            HITS_CAP = HITS_CAP ? HITS_CAP * 2 : 64;
        }
        HITS[NHITS++] = (size_t)(at - text);
    }
    free(text);
}

static size_t caret_of(const lues_snapshot *s) {
    const oket_side *side = oket_side_of(s);
    return side->ncursors ? oket_pos_off(s, side->cursors[side->primary].head) : 0;
}

/* Marks every hit found in `s` and reverses `current`. No hits publishes nothing, which clears. */
static void paint(const lues_api *api, lues_self self, const lues_snapshot *s, size_t current) {
    size_t i;

    oket_view_clear(NULL, &OUT);
    for (i = 0; i < NHITS; i++) {
        oket_spans_add(&OUT, HITS[i], HITS[i] + PAT_LEN, OKET_TOK_ACCENT,
                       HITS[i] == current ? OKET_ATTR_REVERSE : OKET_ATTR_UNDERLINE,
                       LUES_CHAN_FG | LUES_CHAN_ATTRS);
    }
    oket_spans_publish(api, self, s->doc, s->gen, 0, (size_t)-1, &OUT);
}

/* The hit enter would land on: the first at or after the caret. */
static size_t landing(size_t caret) {
    size_t i;

    for (i = 0; i < NHITS; i++) {
        if (HITS[i] >= caret) {
            return HITS[i];
        }
    }
    return NHITS ? HITS[0] : 0;
}

static void repaint(const lues_api *api, lues_self self) {
    const lues_snapshot *s = api->snapshot(api, self, TARGET);

    if (!s) {
        return;
    }
    hits_find(s);
    paint(api, self, s, landing(caret_of(s)));
    api->release(api, self, s);
}

static lues_doc focused_of(const oket_world *w) {
    size_t i;

    for (i = 0; w && i < w->npanes; i++) {
        if (w->panes[i].focused) {
            return w->panes[i].doc;
        }
    }
    return LUES_NO_DOC;
}

static int32_t on_moved(const lues_api *api, lues_self self, const lues_at *at, lues_event ev,
                        const char *text, size_t len) {
    const oket_world *w;
    lues_doc          line, focused;
    size_t            step, step_len;

    (void)text;
    (void)len;
    if (ev != LUES_EVENT_MOVED || !at->snap) {
        return 0;
    }
    w = oket(api)->world(api, self);
    line = w ? w->line : LUES_NO_DOC;
    focused = focused_of(w);
    step = w ? w->step : 0;
    step_len = w ? w->step_len : 0;
    oket(api)->world_release(api, self, w);

    if (line != LUES_NO_DOC && at->doc == line) {
        if (focused != TARGET) {
            PAT_LEN = 0;
            repaint(api, self); /* off the old one */
            TARGET = focused;
        }
        pattern_read(at->snap, step, step_len);
        repaint(api, self);
    } else if (line == LUES_NO_DOC && PAT_LEN) {
        PAT_LEN = 0;
        repaint(api, self);
    } else if (at->doc == TARGET && PAT_LEN) {
        repaint(api, self);
    }
    return 0;
}

/* One hit along from the caret, wrapping. A caret moved here does not move the generation, so
 * this paints the new current hit itself. */
static int32_t step(const lues_api *api, lues_self self, const lues_at *at, int forward) {
    const lues_snapshot *s = at->snap;
    size_t               caret, to, i, line;
    oket_cursor          c = {0};

    if (!s || !PAT_LEN || at->doc != TARGET) {
        return 1;
    }
    hits_find(s);
    if (NHITS == 0) {
        return 1;
    }
    caret = caret_of(s);
    to = forward ? HITS[0] : HITS[NHITS - 1];
    for (i = 0; i < NHITS; i++) {
        size_t h = forward ? HITS[i] : HITS[NHITS - 1 - i];
        if (forward ? h > caret : h < caret) {
            to = h;
            break;
        }
    }
    line = oket_line_at(s, to);
    c.head.line = c.anchor.line = (ptrdiff_t)line;
    c.head.col = c.anchor.col = (ptrdiff_t)(to - oket_line_start(s, line));
    c.goal = -1;
    oket(api)->cursors(api, self, at->doc, &c, 1, 0);
    oket(api)->reveal(api, self, at->doc, to, to + PAT_LEN, OKET_REVEAL_NEAREST);
    paint(api, self, s, to);
    return 0;
}

static int32_t next(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    (void)args;
    (void)args_len;
    return step(api, self, at, 1);
}

static int32_t prev(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    (void)args;
    (void)args_len;
    return step(api, self, at, 0);
}

LUES_MAIN {
    if (grep_register(api, self) != 0) {
        return 1;
    }
    api->register_watch(api, self, on_moved);
    api->register_command(api, self, LIT("find.next"), LIT("the next :find match, as you type"),
                          next);
    api->register_command(api, self, LIT("find.prev"),
                          LIT("the previous :find match, as you type"), prev);
    api->request_bind(api, self, LIT(":find"), LIT("down"), LIT(":find.next"));
    api->request_bind(api, self, LIT(":find"), LIT("up"), LIT(":find.prev"));
    return 0;
}
