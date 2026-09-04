/* Syntax highlighting, as a plugin (§9, §11). It parses with tree-sitter and publishes spans;
 * the kernel stores them and the renderer reads them merged. Nothing about a syntax tree
 * crosses the seam, which is the point: an in-kernel parser would freeze a tree API into the
 * ABI forever, and the tree drives indentation, folding and text objects too.
 *
 * This plugin DRAWS NOTHING. It is reached because it asks to be: register_watch tells it about
 * every document, and a `moved` handler that answers non-zero is called again next frame. A
 * parse too big for one frame says so and resumes — that is the whole of cooperative slicing,
 * and it needs no thread and no seventh message.
 *
 * Grammars are not shipped and are not fetched from here. `tools/oket-grammar` builds one into
 * <home>/grammars, and it is reached the way §7 says composition is reached — a command line:
 *
 *     oket-grammar json https://github.com/tree-sitter/tree-sitter-json && :grammar ready json
 *
 * A shell step and a plugin command, chained. The seam grows nothing for it, and grammars.c
 * puts that line under `enter` over a list of every grammar there is.
 */
/* clock_gettime and readlink: stage.sh builds at -std=c11, which hides POSIX by default. */
#define _POSIX_C_SOURCE 200809L

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <tree_sitter/api.h>

#include "oket_helpers.h"

#include "grammars.h"

/* How long one call may parse for. The kernel kills a plugin that holds a dispatch past its
 * hang deadline, and a frame at 60 is 16 ms, so this has to sit well under both; what is left
 * unfinished resumes next frame. */
#define PARSE_BUDGET_US 3000

#define MAX_DOCS 16
#define MAX_LANGS 16
#define PATH_MAX_ 512

/* Spans emitted before a slice hands the frame back. The PARSE is not the only half that
 * outgrows a frame: walking the query over a megabyte of tree and flattening it costs more on
 * its own. Restarting a cursor per byte range instead of carrying one re-walks the tree every
 * slice, which is quadratic on a document whose root has one child per line — measured, not
 * feared. */
#define PAINT_SLICE 512

/* --- where a grammar lives --- */

/* Set by `:grammar dir`, which is how a gate points at a temp directory and how somebody who
 * keeps grammars elsewhere says so, neither of them through a process-wide env var. */
static char dir_override[PATH_MAX_];

/* Beside the binary, like binds.conf and plugins/ (§10). */
const char *grammars_dir(void) {
    static char dir[PATH_MAX_];
    const char *home;
    char exe[PATH_MAX_ - 16];
    ssize_t n;
    char *slash;

    if (dir_override[0]) {
        return dir_override;
    }
    if (dir[0]) {
        return dir;
    }
    home = getenv("OKET_HOME");
    if (home && *home) {
        snprintf(dir, sizeof dir, "%s/grammars", home);
        return dir;
    }
    n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n <= 0) {
        return NULL;
    }
    exe[n] = 0;
    slash = strrchr(exe, '/');
    if (!slash) {
        return NULL;
    }
    *slash = 0;
    snprintf(dir, sizeof dir, "%s/grammars", exe);
    return dir;
}

/* --- an extension names a grammar --- */

/* Three answers, narrowest first. The registry the list is built on already says which
 * extensions each grammar claims, so it answers this too and the two cannot drift — a name
 * typed into the list and a file opened by hand reach the same `<name>.so`.
 *
 * This table is what is left: the exceptions to the registry, and there is one. Helix hands
 * `.h` to cpp, and a header in a C project wants C.
 *
 * Past both, THE EXTENSION IS THE NAME, so a language nobody listed still colours the moment
 * its grammar is built under the name of its own extension. */
static const struct {
    const char *ext, *lang;
} ALIASES[] = {
    {"h", "c"},
};

/* The grammar name a path selects, written into `out`. Zero when the path has no extension. */
static size_t lang_of_path(const char *path, size_t len, char *out, size_t cap) {
    size_t i = len, n, k;
    const char *ext, *listed;

    while (i > 0 && path[i - 1] != '/') {
        i--;
        if (path[i] != '.' || i + 1 >= len) {
            continue;
        }
        ext = path + i + 1;
        n = len - i - 1;
        for (k = 0; k < sizeof ALIASES / sizeof *ALIASES; k++) {
            if (strlen(ALIASES[k].ext) == n && memcmp(ALIASES[k].ext, ext, n) == 0) {
                snprintf(out, cap, "%s", ALIASES[k].lang);
                return strlen(out);
            }
        }
        listed = grammar_for_ext(ext, n);
        if (listed != NULL) {
            snprintf(out, cap, "%s", listed);
            return strlen(out);
        }
        /* A name that could name a file elsewhere is not one to open a .so by. */
        for (k = 0; k < n; k++) {
            char c = ext[k];
            int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                     (c >= '0' && c <= '9') || c == '_' || c == '-';
            if (!ok || n >= cap) {
                return 0;
            }
        }
        memcpy(out, ext, n);
        out[n] = 0;
        return n;
    }
    return 0;
}

/* --- a loaded grammar --- */

/* One per language, loaded once and kept: a dlopen and a query compile are not per-document
 * work, and two files of one language share both. */
typedef struct {
    char name[64];
    void *lib;
    const TSLanguage *language;
    TSQuery *query;
    oket_token *caps; /* one style token per capture id, interned once */
    uint32_t ncaps;
    int tried; /* a failed load is not retried every frame */
} loaded;

static loaded loads[MAX_LANGS];

/* The whole file, or NULL. Queries are small; one that is not is refused rather than read into
 * an unbounded allocation. */
static char *read_file(const char *path, uint32_t *out_len) {
    FILE *f = fopen(path, "rb");
    long size;
    char *buf;

    if (!f) {
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0 || (size = ftell(f)) < 0 || size > (1 << 22)) {
        fclose(f);
        return NULL;
    }
    rewind(f);
    buf = malloc((size_t)size + 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    *out_len = (uint32_t)fread(buf, 1, (size_t)size, f);
    buf[*out_len] = 0;
    fclose(f);
    return buf;
}

/* `tree_sitter_<name>`, with dashes turned into underscores the way every grammar does it. */
static const TSLanguage *grammar_entry(void *lib, const char *name) {
    char sym[128];
    size_t i;
    const TSLanguage *(*fn)(void);

    snprintf(sym, sizeof sym, "tree_sitter_%s", name);
    for (i = 0; sym[i]; i++) {
        if (sym[i] == '-') {
            sym[i] = '_';
        }
    }
    /* The object-pointer to function-pointer cast C forbids and every dlopen needs. */
    *(void **)&fn = dlsym(lib, sym);
    return fn ? fn() : NULL;
}

/* The capture names ARE the style vocabulary, and they are interned rather than mapped here:
 * the kernel hands back an id per name and the theme decides what `function.builtin` looks
 * like. This plugin never names a colour. */
static void intern_captures(const oket_api *api, oket_self self, loaded *l) {
    uint32_t i;

    l->ncaps = ts_query_capture_count(l->query);
    l->caps = calloc(l->ncaps ? l->ncaps : 1, sizeof *l->caps);
    if (!l->caps) {
        l->ncaps = 0;
        return;
    }
    for (i = 0; i < l->ncaps; i++) {
        uint32_t len = 0;
        const char *name = ts_query_capture_name_for_id(l->query, i, &len);
        l->caps[i] = name ? api->register_token(api, self, name, len) : OKET_TOK_FG;
    }
}

/* Loaded on demand and kept. A grammar with no query parses and does not colour, which is what
 * a grammar shipped without highlights.scm gets. */
static loaded *grammar_load(const oket_api *api, oket_self self, const char *name) {
    const char *dir = grammars_dir();
    char path[PATH_MAX_];
    char *src;
    uint32_t len = 0, err_off = 0;
    TSQueryError err = TSQueryErrorNone;
    loaded *l = NULL;
    int i;

    if (!dir || !name[0]) {
        return NULL;
    }
    for (i = 0; i < MAX_LANGS; i++) {
        if (loads[i].tried && strcmp(loads[i].name, name) == 0) {
            return loads[i].language ? &loads[i] : NULL;
        }
        if (!loads[i].tried && !l) {
            l = &loads[i];
        }
    }
    if (!l) {
        return NULL;
    }
    l->tried = 1;
    snprintf(l->name, sizeof l->name, "%s", name);

    snprintf(path, sizeof path, "%s/%s.so", dir, name);
    l->lib = dlopen(path, RTLD_LOCAL | RTLD_NOW);
    if (!l->lib) {
        return NULL;
    }
    l->language = grammar_entry(l->lib, name);
    if (!l->language) {
        dlclose(l->lib);
        l->lib = NULL;
        return NULL;
    }

    snprintf(path, sizeof path, "%s/%s.scm", dir, name);
    src = read_file(path, &len);
    if (src) {
        l->query = ts_query_new(l->language, src, len, &err_off, &err);
        free(src);
    }
    if (l->query) {
        intern_captures(api, self, l);
    }
    return l;
}

int grammar_installed(const char *name) {
    const char *dir = grammars_dir();
    char path[PATH_MAX_];

    if (!dir || !name[0]) {
        return 0;
    }
    snprintf(path, sizeof path, "%s/%s.so", dir, name);
    return access(path, R_OK) == 0;
}

/* --- captures into spans --- */

/* Captures nest, because nodes do: `(string)` covers the `(escape_sequence)` inside it. The
 * store wants flat runs, so the inner capture cuts the outer one into the parts either side of
 * it. A stack does that in one pass, since the cursor walks in document order.
 *
 * Two captures over the SAME range are one node matched by two patterns, and the first wins,
 * which is the convention every tree-sitter query is written against. */
typedef struct {
    oket_spans out;
    uint32_t n; /* emitted this slice, which is what bounds one frame */
    struct {
        uint32_t end;
        oket_token tok;
    } open[64];
    uint32_t depth;
    uint32_t at; /* the byte everything before is already emitted */
} painter;

/* --- one document --- */

typedef struct {
    oket_doc doc;
    int live;
    char lang[64]; /* what its extension selects, installed or not */
    loaded *l;
    TSParser *parser;
    TSTree *tree;
    uint64_t done_gen;  /* the generation whose tree is built; 0 means none */
    uint64_t parse_gen; /* the generation the half-built tree is being parsed against */
    /* The query walk, carried across frames: one cursor, and the flattening it feeds. */
    TSQueryCursor *cursor;
    painter paint;
    /* The read callback runs inside ts_parser_parse and gets only a payload, so the snapshot
     * it reads travels here for the length of the call. */
    const oket_snapshot *snap;
    struct timespec deadline;
    uint64_t stamp; /* when it was last told about, for the eviction below */
} tracked;

static tracked docs[MAX_DOCS];
static uint64_t told;

/* Everything of `d` that references a grammar, dropped while its .so is still mapped: the
 * parser's external scanner destructor and the cursor's query live in that library. */
static void doc_unbind(tracked *d) {
    if (d->cursor) {
        ts_query_cursor_delete(d->cursor);
        d->cursor = NULL;
    }
    if (d->tree) {
        ts_tree_delete(d->tree);
        d->tree = NULL;
    }
    if (d->parser) {
        ts_parser_delete(d->parser);
        d->parser = NULL;
    }
    d->l = NULL;
    d->done_gen = 0;
    d->parse_gen = 0;
}

static void doc_release(tracked *d) {
    doc_unbind(d);
    oket_spans_free(&d->paint.out);
    memset(d, 0, sizeof *d);
}

/* `:grammar ready` and `:grammar dir` throw the cache away, so a grammar built while oket was
 * running is picked up without a reload. Every document is unbound FIRST: its parser, tree and
 * cursor reference the library this dlcloses. */
void grammar_forget(void) {
    int i;

    for (i = 0; i < MAX_DOCS; i++) {
        doc_unbind(&docs[i]);
    }
    for (i = 0; i < MAX_LANGS; i++) {
        if (loads[i].query) {
            ts_query_delete(loads[i].query);
        }
        free(loads[i].caps);
        if (loads[i].lib) {
            dlclose(loads[i].lib);
        }
        memset(&loads[i], 0, sizeof loads[i]);
    }
}

/* The slot for `doc`, else the one told about least recently. A close never reaches this
 * plugin — the kernel prunes its own watch table — so a document that stops being told about
 * ages out, and one evicted early is reparsed from cold if it comes back. */
static tracked *doc_slot(oket_doc doc) {
    tracked *pick = &docs[0];
    int i;

    for (i = 0; i < MAX_DOCS; i++) {
        if (docs[i].live && docs[i].doc == doc) {
            docs[i].stamp = ++told;
            return &docs[i];
        }
        if (docs[i].stamp < pick->stamp) {
            pick = &docs[i];
        }
    }
    doc_release(pick);
    pick->doc = doc;
    pick->live = 1;
    pick->stamp = ++told;
    return pick;
}

/* --- reading the document --- */

/* tree-sitter reads a run at a time and borrows it until it has read it, which is exactly what
 * a piece table hands out. Nothing is flattened and nothing is copied. */
static const char *read_chunk(void *payload, uint32_t byte, TSPoint pos, uint32_t *read) {
    tracked *d = payload;
    size_t len = 0;
    const char *run;

    (void)pos;
    run = oket_run(d->snap, byte, &len);
    if (!run) {
        *read = 0;
        return "";
    }
    *read = (uint32_t)len;
    return run;
}

static int past_deadline(const struct timespec *deadline) {
    struct timespec now;

    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec > deadline->tv_sec ||
           (now.tv_sec == deadline->tv_sec && now.tv_nsec >= deadline->tv_nsec);
}

/* True cancels the parse. tree-sitter keeps its position, so the next call resumes rather than
 * starting over — which is what makes a budget a budget and not a truncation. */
static bool out_of_time(TSParseState *state) {
    tracked *d = state->payload;
    return past_deadline(&d->deadline);
}

/* --- painting --- */

static void emit(painter *p, uint32_t lo, uint32_t hi, oket_token tok) {
    if (lo >= hi) {
        return;
    }
    /* A colour and nothing else: no claim on the background, and none on the attributes a
     * linter above may want to put on the same bytes. */
    oket_spans_add(&p->out, lo, hi, tok, 0, OKET_SET_FG);
    p->n++;
}

/* Everything on the stack that closes at or before `to`, flushed in order. */
static void close_to(painter *p, uint32_t to) {
    while (p->depth > 0 && p->open[p->depth - 1].end <= to) {
        emit(p, p->at, p->open[p->depth - 1].end, p->open[p->depth - 1].tok);
        if (p->open[p->depth - 1].end > p->at) {
            p->at = p->open[p->depth - 1].end;
        }
        p->depth--;
    }
}

static void push(painter *p, uint32_t lo, uint32_t hi, oket_token tok) {
    close_to(p, lo);
    if (p->depth > 0 && p->open[p->depth - 1].end == hi && p->at == lo) {
        return; /* the same range, already claimed by an earlier pattern */
    }
    if (p->depth > 0) {
        emit(p, p->at, lo, p->open[p->depth - 1].tok); /* the parent's part before this one */
    }
    if (p->at < lo) {
        p->at = lo;
    }
    if (p->depth == sizeof p->open / sizeof *p->open) {
        return; /* deeper than any real query nests; the rest of this node draws plain */
    }
    p->open[p->depth].end = hi;
    p->open[p->depth].tok = tok;
    p->depth++;
}

/* One slice of the query walk, and whether there is more of it.
 *
 * The WHOLE document is walked and not the viewport, because where the user is looking does not
 * cross the seam (§11): the kernel owns the viewport and a plugin gets `reveal`, not a scroll
 * position. What bounds a frame is this slice; what bounds the store is its own cap.
 *
 * The painter emits in document order, so `p->at` is a frontier: everything below it is
 * decided and everything above is still open on the stack. A slice publishes exactly
 * [frontier before, frontier after), which is what makes a range-scoped replace the right
 * shape for partial work — no slice ever claims bytes it has not walked, and the next one
 * picks up where this stopped.
 *
 * The last slice runs to the END rather than to its frontier, so a document that shrank leaves
 * no runs behind past what it now has. */
static int paint_slice(const oket_api *api, oket_self self, tracked *d, uint64_t gen) {
    painter *p = &d->paint;
    TSQueryMatch match;
    uint32_t index = 0, from = p->at;
    int more = 1;

    if (!d->cursor) {
        return 0;
    }
    p->out.n = 0;
    p->n = 0;
    while (p->n < PAINT_SLICE) {
        if (!ts_query_cursor_next_capture(d->cursor, &match, &index)) {
            close_to(p, (uint32_t)-1);
            ts_query_cursor_delete(d->cursor);
            d->cursor = NULL;
            more = 0;
            break;
        }
        if (match.captures[index].index < d->l->ncaps) {
            TSNode node = match.captures[index].node;
            push(p, ts_node_start_byte(node), ts_node_end_byte(node),
                 d->l->caps[match.captures[index].index]);
        }
    }
    oket_spans_publish(api, self, d->doc, gen, from, more ? p->at : (uint32_t)-1, &p->out);
    return more;
}

/* The cursor a paint walks, opened once per finished tree. */
static void paint_start(tracked *d) {
    if (d->cursor) {
        ts_query_cursor_delete(d->cursor);
        d->cursor = NULL;
    }
    oket_spans_free(&d->paint.out);
    memset(&d->paint, 0, sizeof d->paint);
    if (!d->l->query) {
        return; /* it parses, it does not colour; the grammar shipped no highlights query */
    }
    d->cursor = ts_query_cursor_new();
    if (d->cursor) {
        ts_query_cursor_exec(d->cursor, d->l->query, ts_tree_root_node(d->tree));
    }
}

/* --- the parse --- */

/* The old tree is NOT reused. tree-sitter's incremental path needs the edits that made the new
 * text, and a watcher carries a generation rather than a delta; feeding it an unedited tree
 * would parse against ranges that have moved. A full re-parse under a per-frame budget is
 * correct and bounded, and the incremental path opens if applied edits ever cross the seam. */
static int reparse(const oket_api *api, oket_self self, tracked *d, const oket_snapshot *snap) {
    TSParseOptions opts;
    TSInput input;
    TSTree *tree;
    struct timespec now;

    if (!d->l || !d->l->language) {
        return 0;
    }
    /* The tree is built and the query is walking it, a slice per frame. */
    if (d->done_gen == snap->gen) {
        return paint_slice(api, self, d, snap->gen);
    }
    if (!d->parser) {
        d->parser = ts_parser_new();
        if (!d->parser || !ts_parser_set_language(d->parser, d->l->language)) {
            return 0; /* the grammar is for another tree-sitter; nothing to retry */
        }
    }
    /* The text moved under a half-built tree, so what it has read so far is against bytes that
     * are gone. Start again rather than resume. */
    if (d->parse_gen != snap->gen) {
        ts_parser_reset(d->parser);
        d->parse_gen = snap->gen;
    }

    d->snap = snap;
    clock_gettime(CLOCK_MONOTONIC, &now);
    d->deadline = now;
    d->deadline.tv_nsec += PARSE_BUDGET_US * 1000;
    if (d->deadline.tv_nsec >= 1000000000L) {
        d->deadline.tv_nsec -= 1000000000L;
        d->deadline.tv_sec++;
    }

    memset(&input, 0, sizeof input);
    input.payload = d;
    input.read = read_chunk;
    input.encoding = TSInputEncodingUTF8;
    memset(&opts, 0, sizeof opts);
    opts.payload = d;
    opts.progress_callback = out_of_time;

    tree = ts_parser_parse_with_options(d->parser, NULL, input, opts);
    d->snap = NULL;
    if (!tree) {
        return 1; /* out of time, not out of luck: called again, it picks up where it stopped */
    }
    if (d->tree) {
        ts_tree_delete(d->tree);
    }
    d->tree = tree;
    d->done_gen = snap->gen;
    paint_start(d);
    return paint_slice(api, self, d, snap->gen);
}

/* --- being told about documents --- */

/* Every open document, whenever this plugin has not seen it at the generation it is at now.
 * That is the open notice and the moved notice in one message (§9), and the return is the
 * latch: non-zero means the parse is unfinished and the kernel calls again next frame. */
static int32_t on_moved(const oket_api *api, oket_self self, const oket_at *at, oket_event ev,
                        const char *text, size_t len) {
    tracked *d;
    const oket_descriptor *desc;

    (void)text;
    (void)len;
    if (ev != OKET_EVENT_MOVED || !at->snap) {
        return 0;
    }
    /* A grammar list with a build out. The latch is the only thing that keeps frames coming
     * while a shell step waits, and a bar nobody redraws is a bar that says nothing. */
    if (grammars_tick(api, self, at)) {
        return 1;
    }
    desc = at->snap->desc;
    if (!desc || !desc->file || desc->file_len == 0) {
        return 0; /* a terminal, a listing, the command line: nothing with a language */
    }
    d = doc_slot(at->doc);
    if (!d->lang[0] && !lang_of_path(desc->file, desc->file_len, d->lang, sizeof d->lang)) {
        return 0;
    }
    if (!d->l) {
        if (!grammar_installed(d->lang)) {
            return 0; /* installing one later re-latches it, through `:grammar ready` */
        }
        d->l = grammar_load(api, self, d->lang);
        if (!d->l) {
            return 0;
        }
    }
    return reparse(api, self, d, at->snap);
}

/* Re-registering REPLACES the handler and forgets its record, so every document is unseen again
 * next frame. Cheap where it lands: a document already painted has no cursor left, so its extra
 * `moved` is one call that answers zero. */
void grammar_relatch(const oket_api *api, oket_self self) {
    api->register_watch(api, self, on_moved);
}

/* --- `:grammar` --- */

/* A word off the front of `args`, which is not NUL-terminated. */
static size_t word(const char *s, size_t len, size_t at, size_t *out_len) {
    size_t start;

    while (at < len && (s[at] == ' ' || s[at] == '\t')) {
        at++;
    }
    start = at;
    while (at < len && s[at] != ' ' && s[at] != '\t') {
        at++;
    }
    *out_len = at - start;
    return start;
}

static int word_is(const char *s, size_t len, const char *name) {
    return strlen(name) == len && memcmp(s, name, len) == 0;
}

static int cmd_dir(const oket_api *api, oket_self self, const char *name, size_t nlen) {
    char msg[PATH_MAX_ + 32];

    if (nlen && nlen < sizeof dir_override) {
        memcpy(dir_override, name, nlen);
        dir_override[nlen] = 0;
        grammar_forget(); /* the old directory's grammars are not this one's */
    }
    grammars_refresh(api, self); /* another directory holds another set of them */
    snprintf(msg, sizeof msg, "grammars in %s", grammars_dir() ? grammars_dir() : "?");
    oket_say(api, self, msg);
    return 0;
}

static int cmd_status(const oket_api *api, oket_self self) {
    char msg[256];
    int i, n = 0;

    for (i = 0; i < MAX_DOCS; i++) {
        if (docs[i].live && docs[i].l) {
            n++;
        }
    }
    grammars_refresh(api, self); /* counted off the platter, not remembered from a start */
    snprintf(msg, sizeof msg, "%d document(s) parsing; %d of %d grammars in %s", n,
             grammars_installed(), grammars_count(),
             grammars_dir() ? grammars_dir() : "?");
    oket_say(api, self, msg);
    return 0;
}

/* The chain reaches here whichever way the build went, because the step before it cannot fail
 * (grammars.c). THE PLATTER SAYS WHICH: a `<name>.so` that is there was built, and one that is
 * not means the tool said why in N# and there is nothing to load.
 *
 * A build is not something the kernel can see: no generation moved, so nothing would tell this
 * plugin to look again. grammar_relatch is that ask. */
static int cmd_ready(const oket_api *api, oket_self self, const char *name, size_t nlen) {
    char lang[64], msg[128];
    int installed;

    if (nlen == 0 || nlen >= sizeof lang) {
        oket_say(api, self, "usage: :grammar ready <lang>");
        return 1;
    }
    memcpy(lang, name, nlen);
    lang[nlen] = 0;
    installed = grammar_installed(lang);
    if (installed) {
        grammar_forget();
        grammar_relatch(api, self);
    }
    /* The row for it is a `*` now, wherever the list is open, and its bar stops. */
    grammars_done(api, self, lang, installed);
    if (installed) {
        snprintf(msg, sizeof msg, "grammar %s ready", lang);
    } else {
        snprintf(msg, sizeof msg, "grammar %s did not build; alt+0 says why", lang);
    }
    oket_say(api, self, msg);
    return installed ? 0 : 1;
}

static int32_t grammar_cmd(const oket_api *api, oket_self self, const oket_at *at,
                           const char *args, size_t args_len) {
    size_t vlen = 0, nlen = 0;
    size_t vat = word(args, args_len, 0, &vlen);
    size_t nat = word(args, args_len, vat + vlen, &nlen);
    const char *verb = args + vat, *name = args + nat;

    (void)at;
    if (word_is(verb, vlen, "dir")) {
        return cmd_dir(api, self, name, nlen);
    }
    if (vlen == 0 || word_is(verb, vlen, "status")) {
        return cmd_status(api, self);
    }
    if (word_is(verb, vlen, "ready") && nlen) {
        return cmd_ready(api, self, name, nlen);
    }
    oket_say(api, self, "usage: :grammar [status | ready <lang> | dir <path>]");
    return 1;
}

OKET_MAIN {
    api->register_watch(api, self, on_moved);
    api->register_command(api, self, "grammar", 7,
                          "syntax: status | ready <lang> | dir <path>", 41, grammar_cmd);
    /* The list is a KIND, so `:ring grammars` opens it and alt+g is one requested row. A plugin
     * cannot open a document — there is no message for it, and the ring already answers the
     * question (§5, §7). */
    return grammars_register(api, self) == 0 ? 1 : 0;
}
