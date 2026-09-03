/* The grammar list, as a document (§5, §11). Three hundred languages is a list, and a list is a
 * box of lines: so it is a kind like any other, it opens in a lane like any other, and every row
 * is text the kernel draws and point walks. No widget, no second drawing path, no selection of
 * its own — the row point is on IS the selection, which is what `selection: line` means.
 *
 * WHAT BUILDS A GRAMMAR IS A BIND ROW, and there is no code in this file for it:
 *
 *     [grammars]
 *     enter = exec oket-grammar <lang> <repo> <rev> <sub> && :grammar ready <lang>
 *
 * The four holes are fields on the row under point, so the registry reaches the shell without
 * this plugin spawning anything, the build is a step you can read in N#, and a failure stops the
 * chain before the load. `oket-grammar` ships beside `oket`. A rev or a subpath the registry
 * does not carry is an EMPTY span, which fills its hole with an empty argument rather than with
 * whatever the row's other bytes say.
 *
 *     :ring grammars   the list (alt+g)
 *     type             filters, by name or by whole extension
 *     backspace, esc   one rune off it, or all of it
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

#include "grammars.h"
#include "languages.h"

#define FILTER_CAP 48
/* xml's row is 521 bytes today; the clamp below is for growth, not for the shipped registry. */
#define LINE_CAP 640
#define NAME_W 16
/* Lists open at once. A lane holds nine slots and nobody wants nine of these; the array is what
 * lets a finished build rewrite the ones that are open. */
#define MAX_LISTS 8

static oket_kind GRAMMARS;

/* --- the registry, and what of it is on the platter --- */

/* Counted rather than stat'd per row per frame: it changes when a build finishes, and
 * `:grammar ready` is exactly where that is known. */
static unsigned char here[OKET_GRAMMAR_COUNT];
static int here_n;

static void count_installed(void) {
    int i;

    here_n = 0;
    for (i = 0; i < OKET_GRAMMAR_COUNT; i++) {
        here[i] = grammar_installed(OKET_GRAMMARS[i].name) ? 1 : 0;
        here_n += here[i];
    }
}

int grammars_count(void) {
    return OKET_GRAMMAR_COUNT;
}

int grammars_installed(void) {
    return here_n;
}

static int contains(const char *s, const char *want, size_t n) {
    size_t len = strlen(s), i;

    if (n > len) {
        return 0;
    }
    for (i = 0; i + n <= len; i++) {
        if (memcmp(s + i, want, n) == 0) {
            return 1;
        }
    }
    return 0;
}

/* A WHOLE entry of the comma-separated list, never a substring of one: `rs` names an extension
 * and `r` does not name the start of it. */
static int ext_listed(const char *exts, const char *want, size_t n) {
    const char *at = exts;

    while (*at) {
        const char *end = strchr(at, ',');
        size_t len = end ? (size_t)(end - at) : strlen(at);

        if (len == n && memcmp(at, want, n) == 0) {
            return 1;
        }
        if (!end) {
            break;
        }
        at = end + 1;
    }
    return 0;
}

const char *grammar_for_ext(const char *ext, size_t len) {
    int i;

    for (i = 0; i < OKET_GRAMMAR_COUNT; i++) {
        if (ext_listed(OKET_GRAMMARS[i].exts, ext, len)) {
            return OKET_GRAMMARS[i].name;
        }
    }
    return NULL;
}

/* A substring of the name, which is what typing means to somebody looking for `tsx` inside
 * `typescript`, or a whole extension, which is what `rs` means to somebody who has the file
 * open and not the language's name. An empty filter matches everything. */
static int matches(const oket_grammar *g, const char *filter, size_t n) {
    return n == 0 || contains(g->name, filter, n) || ext_listed(g->exts, filter, n);
}

/* --- one list --- */

typedef struct {
    oket_doc doc;
    char filter[FILTER_CAP];
    size_t nfilter;
} list;

static list *lists[MAX_LISTS];

static void remember(list *l) {
    int i;

    for (i = 0; i < MAX_LISTS; i++) {
        if (lists[i] == NULL) {
            lists[i] = l;
            return;
        }
    }
}

static void forget(list *l) {
    int i;

    for (i = 0; i < MAX_LISTS; i++) {
        if (lists[i] == l) {
            lists[i] = NULL;
        }
    }
}

/* One row: what it draws for the eye, and the fields a bind acts through.
 *
 * `lang` is the name's own bytes, so hover underlines exactly what enter would build. The other
 * three carry a VALUE the row never draws — the whole registry entry travels with the row, and
 * the bind line reads like the command a person would type. */
static void put_row(oket_build *out, const oket_grammar *g, int installed) {
    char text[LINE_CAP];
    size_t n, name_lo = 2, name_hi;

    n = (size_t)snprintf(text, sizeof text, "%s %-*s  %s", installed ? "*" : " ", NAME_W,
                         g->name, g->exts);
    if (n >= sizeof text) {
        n = sizeof text - 1; /* an extension list longer than the buffer: what fits is the row */
    }
    name_hi = name_lo + strlen(g->name);

    oket_build_cell(out, "row", text, n);
    oket_build_span(out, "lang", name_lo, name_hi);
    oket_build_link(out, "repo", name_lo, name_hi, g->repo, strlen(g->repo));
    /* An empty span for what the registry does not carry: its value is the no bytes it covers,
     * which is an empty argument. A link with an empty value would fall back to the span's own
     * bytes and hand the shell the grammar's name as a revision. */
    if (g->rev[0]) {
        oket_build_link(out, "rev", name_lo, name_hi, g->rev, strlen(g->rev));
    } else {
        oket_build_span(out, "rev", name_hi, name_hi);
    }
    if (g->subpath[0]) {
        oket_build_link(out, "sub", name_lo, name_hi, g->subpath, strlen(g->subpath));
    } else {
        oket_build_span(out, "sub", name_hi, name_hi);
    }
    oket_build_row(out);
}

/* The list as it stands, and the byte the first ROW starts at — which is where point goes
 * whenever the filter moved, because the row it was on may not be in the list any more.
 *
 * A REGENERATION: these carets were put where they are by navigation, so they stay on their
 * rows rather than collapsing onto the splice, and the undo log goes with the text (§5). */
static size_t publish(const oket_api *api, oket_self self, list *l) {
    oket_descriptor d;
    oket_build out;
    char head[LINE_CAP];
    size_t first = 0;
    int i, n = 0, shown = 0;

    memset(&out, 0, sizeof out);
    for (i = 0; i < OKET_GRAMMAR_COUNT; i++) {
        shown += matches(&OKET_GRAMMARS[i], l->filter, l->nfilter) ? 1 : 0;
    }
    if (l->nfilter > 0) {
        n = snprintf(head, sizeof head, "grammars   %d of %d installed   /%.*s   %d shown; esc clears",
                     here_n, OKET_GRAMMAR_COUNT, (int)l->nfilter, l->filter, shown);
    } else {
        n = snprintf(head, sizeof head,
                     "grammars   %d of %d installed   type to filter; enter builds the row under point",
                     here_n, OKET_GRAMMAR_COUNT);
    }
    if (n < 0 || (size_t)n >= sizeof head) {
        n = (int)sizeof head - 1;
    }
    oket_build_cell(&out, "head", head, (size_t)n);
    oket_build_row(&out);
    for (i = 0; i < OKET_GRAMMAR_COUNT; i++) {
        if (!matches(&OKET_GRAMMARS[i], l->filter, l->nfilter)) {
            continue;
        }
        if (first == 0) {
            first = out.len;
        }
        put_row(&out, &OKET_GRAMMARS[i], here[i]);
    }

    memset(&d, 0, sizeof d);
    d.kind = GRAMMARS;
    d.render = OKET_RENDER_TEXT;
    /* A row is the unit: point stands on one and the whole line marks. Typing is not editing
     * here — `editable` is what makes a rune reach this plugin at all (§5), and every one of
     * them goes into the filter. */
    d.selection = OKET_SELECT_LINE;
    d.input = OKET_INPUT_BOUND;
    d.editable = 1;
    d.tab_width = 4;
    oket_build_desc(&out, &d);
    /* Minus the row terminator the last row wrote: a document does not end in a blank line. */
    oket_regen(api, self, l->doc, out.text, out.len > 0 ? out.len - 1 : 0, &d);
    oket_build_free(&out);
    return first;
}

/* The list, and point on its first row: what every change to the filter ends with. */
static void refilter(const oket_api *api, oket_self self, list *l) {
    api->point(api, self, l->doc, publish(api, self, l));
}

void grammars_refresh(const oket_api *api, oket_self self) {
    int i;

    count_installed();
    for (i = 0; i < MAX_LISTS; i++) {
        if (lists[i] != NULL) {
            publish(api, self, lists[i]); /* the markers moved, not the rows; point stays */
        }
    }
}

/* --- the six messages --- */

static void *open_list(const oket_api *api, oket_self self, oket_doc doc, const char *args,
                       size_t args_len) {
    list *l = calloc(1, sizeof *l);

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return NULL;
    }
    l->doc = doc;
    remember(l);
    count_installed();
    refilter(api, self, l);
    return l;
}

static void close_list(const oket_api *api, oket_self self, oket_doc doc, void *inst) {
    (void)api;
    (void)self;
    (void)doc;
    forget(inst);
    free(inst);
}

/* A typed rune is the filter, and it is the only thing that reaches here: `bound` means the
 * bind table answered every chord already. Nothing is inserted into the document — the rows are
 * derived text, and what a keystroke moves is which of them there are. */
static int32_t event(const oket_api *api, oket_self self, const oket_at *at, oket_event ev,
                     const char *text, size_t len) {
    list *l = at->inst;

    if (!oket_mine(at) || ev != OKET_EVENT_TEXT || l == NULL) {
        return 0;
    }
    if (len == 0 || l->nfilter + len >= sizeof l->filter) {
        return 0;
    }
    memcpy(l->filter + l->nfilter, text, len);
    l->nfilter += len;
    refilter(api, self, l);
    return 1;
}

/* --- the verbs --- */

static int32_t erase_cmd(const oket_api *api, oket_self self, const oket_at *at,
                         const char *args, size_t args_len) {
    list *l = at->inst;
    uint32_t r;

    (void)args;
    (void)args_len;
    if (!oket_mine(at) || l == NULL) {
        oket_say(api, self, "gr.erase: this document is not the grammar list");
        return 1;
    }
    l->nfilter -= oket_utf8_prev(l->filter, l->nfilter, &r);
    refilter(api, self, l);
    return 0;
}

static int32_t clear_cmd(const oket_api *api, oket_self self, const oket_at *at,
                         const char *args, size_t args_len) {
    list *l = at->inst;

    (void)args;
    (void)args_len;
    if (!oket_mine(at) || l == NULL) {
        oket_say(api, self, "gr.clear: this document is not the grammar list");
        return 1;
    }
    l->nfilter = 0;
    refilter(api, self, l);
    return 0;
}

oket_kind grammars_register(const oket_api *api, oket_self self) {
    static const oket_kind_spec SPEC = {
        LIT("grammars"),
        LIT("surface"),
        {open_list, close_list, event},
    };

    GRAMMARS = api->register_kind(api, self, &SPEC);
    if (GRAMMARS == 0) {
        return 0;
    }
    api->register_command(api, self, LIT("gr.erase"), LIT("one rune off the list's filter"),
                          erase_cmd);
    api->register_command(api, self, LIT("gr.clear"), LIT("clear the list's filter"), clear_cmd);
    /* ASKED FOR, never claimed (§8). `esc` is the loud one: it quits oket everywhere else, and
     * a picker where esc drops what you typed is worth the shadow — the writeback says so in
     * binds.conf, where it can be taken back. */
    api->request_bind(api, self, LIT("global"), LIT("alt+@AC05"), LIT("exec :ring grammars"));
    api->request_bind(api, self, LIT("grammars"), LIT("enter"),
                      LIT("exec oket-grammar <lang> <repo> <rev> <sub> && :grammar ready <lang>"));
    api->request_bind(api, self, LIT("grammars"), LIT("backspace"), LIT("gr.erase"));
    api->request_bind(api, self, LIT("grammars"), LIT("esc"), LIT("gr.clear"));
    return GRAMMARS;
}
