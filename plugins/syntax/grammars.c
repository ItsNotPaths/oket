/* The grammar list, as a document (§5, §11). Three hundred languages is a list, and a list is a
 * box of lines: so it is a kind like any other, it opens in a lane like any other, and every row
 * is text the kernel draws and point walks. The list scaffold — the filter, the publish, the
 * verbs — is the helper library's list core; what is this file's is the registry, the rows, and
 * the build bar.
 *
 * WHAT BUILDS A GRAMMAR IS A BIND ROW, and nothing in this file spawns it:
 *
 *     [grammars]
 *     enter = exec :gr.build <lang>
 *          && oket-grammar <lang> <repo> <rev> <sub> || true
 *          && :grammar ready <lang>
 *
 * The four holes are fields on the row under point, so the registry reaches the shell without
 * this plugin spawning anything, the build is a step you can read in N#, and the grammar is
 * loaded only if one landed. `oket-grammar` ships beside `oket`. A rev or a subpath the
 * registry does not carry is an EMPTY span, which fills its hole with an empty argument rather
 * than with whatever the row's other bytes say.
 *
 * THE TWO BUILTINS EITHER SIDE OF THE SHELL STEP ARE THE FEEDBACK, and they are why the step is
 * `|| true`: a chain that stopped on a failure would leave a bar running with nothing behind
 * it. So the step always exits 0, the last builtin always runs, and it stats `<lang>.so` to
 * find out which of `done` and `failed` the row gets. THE PLATTER IS THE ANSWER, not the exit
 * code and not the tool's own word.
 *
 *     :ring grammars   the list (alt+g)
 *     ctrl+f           filters, by name or by whole extension
 *     backspace, esc   one rune off it, or all of it
 */
/* clock_gettime: stage.sh builds at -std=c11, which hides POSIX by default. */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "oket_helpers.h"

#include "grammars.h"
#include "languages.h"

/* xml's row is 521 bytes today; the clamp below is for growth, not for the shipped registry. */
#define LINE_CAP 640
#define NAME_W 16

/* The bar, in cells, the lit run that crosses it, and how long one cell of travel takes. The
 * run LEAVES at the right before it arrives again at the left: a block wrapped around both
 * edges at once reads as two of them, bouncing. `travel` counts only the positions where some
 * of the run is on screen, so neither end of the cycle is a bar with nothing lit in it. */
#define BAR_W 23
#define BAR_LIT 6
#define BAR_TRAVEL (BAR_W + BAR_LIT - 1)
#define BAR_MS 45

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

/* --- the build under way, and the bar that says so --- */

/* One at a time, because the kernel runs one shell step at a time: a second `enter` would be
 * refused at the step anyway, and this is where it is refused first and said out loud. */
enum { BUILD_OFF = 0, BUILD_RUNNING, BUILD_DONE, BUILD_FAILED };

static struct {
    int state;
    int at; /* the row it is on, or -1: never a row while the state is BUILD_OFF */
    struct timespec start;
} build = {BUILD_OFF, -1, {0, 0}};

/* A WALL CLOCK and not a frame count. The kernel polls rather than waits while anything is
 * latched, so how often this is reached is the machine's answer and not a rate: a bar stepped
 * per frame runs at whatever the display and the GPU allow. */
static unsigned build_ms(void) {
    struct timespec now;
    long long ms;

    clock_gettime(CLOCK_MONOTONIC, &now);
    ms = (long long)(now.tv_sec - build.start.tv_sec) * 1000 +
         (now.tv_nsec - build.start.tv_nsec) / 1000000;
    return ms > 0 ? (unsigned)ms : 0;
}

/* An INDETERMINATE bar: nothing here knows how far a clone or a compile has got, so what moves
 * is a lit run and not a fill. A fill that jumped back to nothing at the end would be a claim
 * about progress that this side of the chain cannot make. */
static void bar_text(char *out, size_t cap, unsigned ms) {
    int head = 1 + (int)((ms / BAR_MS) % BAR_TRAVEL), i;
    size_t n = 0;

    for (i = 0; i < BAR_W && n + 4 <= cap; i++) {
        const char *cell = i < head && i >= head - BAR_LIT ? "█" : "░";

        memcpy(out + n, cell, 3);
        n += 3;
    }
    out[n] = 0;
}

/* What follows the name. A RUNNING build takes the column the extensions were in, because a bar
 * you can watch move is the whole of what this row has to say while it is out; a finished one
 * only adds a word, so what is left behind is the row you already know. */
static void row_tail(int idx, char *out, size_t cap) {
    char bar[BAR_W * 3 + 1];

    if (idx != build.at) {
        snprintf(out, cap, "%s", OKET_GRAMMARS[idx].exts);
        return;
    }
    if (build.state == BUILD_RUNNING) {
        unsigned ms = build_ms();

        /* The seconds are the only honest number here, and they are what says a clone that
         * fetches nothing for a minute is slow rather than hung. */
        bar_text(bar, sizeof bar, ms);
        snprintf(out, cap, "%s  building %us", bar, ms / 1000);
        return;
    }
    snprintf(out, cap, "%s   %s", OKET_GRAMMARS[idx].exts,
             build.state == BUILD_DONE ? "done" : "failed");
}

/* --- the rows, through the list core --- */

/* Per-list draw state the core has no field for: the bar step this list last published. */
typedef struct {
    unsigned drawn;
} list_ui;

/* One row: what it draws for the eye, and the fields a bind acts through.
 *
 * `lang` is the name's own bytes, so hover underlines exactly what enter would build. The other
 * three carry a VALUE the row never draws — the whole registry entry travels with the row, and
 * the bind line reads like the command a person would type. */
static void g_row(void *ctx, oket_build *out, oket_list_row *r, int32_t idx) {
    const oket_grammar *g = &OKET_GRAMMARS[idx];
    char text[LINE_CAP], tail[LINE_CAP];
    size_t n, name_lo = 2, name_hi;

    (void)ctx;
    row_tail(idx, tail, sizeof tail);
    n = (size_t)snprintf(text, sizeof text, "%s %-*s  %s", here[idx] ? "*" : " ", NAME_W,
                         g->name, tail);
    if (n >= sizeof text) {
        n = sizeof text - 1; /* an extension list longer than the buffer: what fits is the row */
    }
    name_hi = name_lo + strlen(g->name);
    r->fixed = 1; /* a row you build, never one you rename */

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
}

static int32_t g_count(void *ctx) {
    (void)ctx;
    return OKET_GRAMMAR_COUNT;
}

static int g_match(void *ctx, int32_t i, const char *filter, size_t n) {
    (void)ctx;
    return matches(&OKET_GRAMMARS[i], filter, n);
}

static size_t g_head(void *ctx, char *out, size_t cap, const oket_list *l, int32_t shown) {
    int n;

    (void)ctx;
    if (l->filtering || l->nfilter > 0) {
        n = snprintf(out, cap, "grammars   %d of %d installed   /%.*s   %d shown; esc clears",
                     here_n, OKET_GRAMMAR_COUNT, (int)l->nfilter, l->filter, shown);
    } else {
        n = snprintf(out, cap,
                     "grammars   %d of %d installed   ctrl+f filters; enter builds the row under point",
                     here_n, OKET_GRAMMAR_COUNT);
    }
    return n < 0 ? 0 : (size_t)n;
}

/* The filter moved, so browsing resumed — which is also what takes `done` off the row it was
 * left on: the word answered the keystroke that asked for the build, and this is the next one. */
static void g_filtered(void *ctx) {
    (void)ctx;
    if (build.state == BUILD_DONE || build.state == BUILD_FAILED) {
        build.state = BUILD_OFF;
        build.at = -1;
    }
}

static const oket_list_spec LSPEC = {
    "grammars", "gr", OKET_SELECT_LINE, 0, 4,
    g_count, g_match, g_row, g_head, g_filtered,
};

void grammars_refresh(const oket_api *api, oket_self self) {
    count_installed();
    oket_list_repaint(api, self);
}

void grammars_done(const oket_api *api, oket_self self, const char *lang, int installed) {
    if (build.state == BUILD_RUNNING && strcmp(OKET_GRAMMARS[build.at].name, lang) == 0) {
        build.state = installed ? BUILD_DONE : BUILD_FAILED;
    }
    grammars_refresh(api, self);
}

/* A frame of the bar, and the ask for the next one. The kernel waits on events when nothing is
 * latched, so without this the row would sit still for the whole of a build: a shell step
 * finishing is the only other thing that would wake it, and that is the end, not the middle. */
int grammars_tick(const oket_api *api, oket_self self, const oket_at *at) {
    oket_list *l = oket_list_of(at);
    list_ui *ui;
    unsigned step;

    if (build.state != BUILD_RUNNING || l == NULL) {
        return 0;
    }
    /* Redrawn when the bar moved and not when the frame did: the clock is the same for every
     * list, so each one reaches the same step on its own and no two of them race it. */
    ui = l->ctx;
    step = build_ms() / BAR_MS;
    if (step != ui->drawn) {
        ui->drawn = step;
        oket_list_publish(api, self, l);
    }
    return 1;
}

/* --- the six messages --- */

static void *open_list(const oket_api *api, oket_self self, oket_doc doc, const char *args,
                       size_t args_len) {
    list_ui *ui = calloc(1, sizeof *ui);
    oket_list *l;

    (void)args;
    (void)args_len;
    if (ui == NULL) {
        return NULL;
    }
    l = oket_list_open(api, self, doc, ui);
    if (l == NULL) {
        free(ui);
        return NULL;
    }
    count_installed();
    oket_list_publish(api, self, l);
    oket_list_point(api, self, l, 2);
    return l;
}

static void close_list(const oket_api *api, oket_self self, oket_doc doc, void *inst) {
    oket_list *l = inst;

    (void)api;
    (void)self;
    (void)doc;
    if (l == NULL) {
        return;
    }
    free(l->ctx);
    oket_list_close(l);
}

/* --- the verbs --- */

/* The chain's FIRST step, and the only one that can refuse: a name the registry does not carry
 * is one no shell step should be spawned for, and a build already out is one the kernel would
 * refuse at the step with nothing on screen to say why. Either way a non-zero return stops the
 * chain here. */
static int32_t build_cmd(const oket_api *api, oket_self self, const oket_at *at,
                         const char *args, size_t args_len) {
    char msg[128];
    int i, idx = -1;

    (void)at;
    if (args_len == 0) { /* the kernel hands args trimmed */
        oket_say(api, self, "usage: :gr.build <lang>");
        return 1;
    }
    if (build.state == BUILD_RUNNING) {
        snprintf(msg, sizeof msg, "gr.build: %s is still building",
                 OKET_GRAMMARS[build.at].name);
        oket_say(api, self, msg);
        return 1;
    }
    for (i = 0; i < OKET_GRAMMAR_COUNT; i++) {
        if (strlen(OKET_GRAMMARS[i].name) == args_len &&
            memcmp(OKET_GRAMMARS[i].name, args, args_len) == 0) {
            idx = i;
            break;
        }
    }
    if (idx < 0) {
        snprintf(msg, sizeof msg, "gr.build: the registry lists no grammar called %.*s",
                 (int)args_len, args);
        oket_say(api, self, msg);
        return 1;
    }
    build.state = BUILD_RUNNING;
    build.at = idx;
    clock_gettime(CLOCK_MONOTONIC, &build.start);
    oket_list_repaint(api, self);
    /* A write of your own is not reported back to you, so the publish above is the one thing
     * that cannot ask for the frame after it. The relatch can: the list arrives again next
     * frame, grammars_tick answers non-zero, and from there the latch feeds itself. */
    grammar_relatch(api, self);
    return 0;
}

oket_kind grammars_register(const oket_api *api, oket_self self) {
    static const oket_kind_spec SPEC = {
        LIT("grammars"),
        LIT("surface"),
        {open_list, close_list, oket_list_event},
    };

    GRAMMARS = api->register_kind(api, self, &SPEC);
    if (GRAMMARS == 0) {
        return 0;
    }
    /* The filter, the erase pair and esc are the list core's: gr.filter on ctrl+f, gr.erase on
     * backspace, gr.clear on esc, all rows the core ASKED for (§8). */
    oket_list_register(api, self, &LSPEC, GRAMMARS);
    api->register_command(api, self, LIT("gr.build"), LIT("mark a row as building"), build_cmd);
    api->request_bind(api, self, LIT("global"), LIT("alt+@AC05"), LIT("exec :ring grammars"));
    /* `|| true` is not a shrug: it is what makes the last step run either way, and the last
     * step is the one that stats the platter and stops the bar on `done` or on `failed`. */
    api->request_bind(api, self, LIT("grammars"), LIT("enter"),
                      LIT("exec :gr.build <lang> && oket-grammar <lang> <repo> <rev> <sub>"
                          " || true && :grammar ready <lang>"));
    return GRAMMARS;
}
