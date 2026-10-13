/* `:grep <args>`: `grep -rn <args>` in the workspace, as a document in the `grep` lane.
 *
 * Each match is a block: a header that names `path:line`, then the lines grep printed around it.
 * Every line carries a `link` to itself, so `enter` opens the file there; up and down step a
 * block at a time. The jump is the kernel's `:openlink`, bound in binds.conf like any row.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "grep.h"

/* -Z ends the path with a NUL, so a `-` or `:` in a name cannot be read as the separator. */
#define GREP "grep -rnIZ -C 2 --exclude-dir=.git "

typedef struct {
    lues_io io;
    int     done;
    char   *query;
    char   *cwd;
    char   *out;
    size_t  len, cap;
    size_t *heads; /* the header line of each block */
    size_t  nheads;
} grep_doc;

/* One line of grep's output. */
typedef struct {
    const char *path, *text;
    size_t      path_len, text_len, line;
    int         match, block;
} entry;

static lues_kind GREP_KIND;

static void append(grep_doc *g, const char *text, size_t len) {
    if (g->len + len > g->cap) {
        size_t cap = (g->len + len) * 2;
        char  *grown = realloc(g->out, cap);
        if (!grown) {
            return;
        }
        g->out = grown;
        g->cap = cap;
    }
    memcpy(g->out + g->len, text, len);
    g->len += len;
}

/* Splits the output into entries. A `--` line, or a new path, starts a block. */
static size_t parse(const grep_doc *g, entry **out) {
    size_t      n = 0, cap = 0;
    entry      *es = NULL;
    const char *at = g->out, *end = g->out + g->len;
    int         block = -1, broke = 1;

    while (at < end) {
        const char *nl = memchr(at, '\n', (size_t)(end - at));
        const char *eol = nl ? nl : end;
        const char *z = memchr(at, '\0', (size_t)(eol - at));
        const char *num;
        entry       e = {0};

        if (eol - at == 2 && at[0] == '-' && at[1] == '-') {
            broke = 1;
        } else if (z) {
            e.path = at;
            e.path_len = (size_t)(z - at);
            for (num = z + 1; num < eol && *num >= '0' && *num <= '9'; num++) {
                e.line = e.line * 10 + (size_t)(*num - '0');
            }
            if (num < eol) {
                e.match = *num == ':';
                e.text = num + 1;
                e.text_len = (size_t)(eol - num - 1);
                if (broke || n == 0 || es[n - 1].path_len != e.path_len ||
                    memcmp(es[n - 1].path, e.path, e.path_len) != 0) {
                    block++;
                }
                broke = 0;
                e.block = block;
                if (n == cap) {
                    entry *grown = realloc(es, (cap = cap ? cap * 2 : 64) * sizeof *es);
                    if (!grown) {
                        break;
                    }
                    es = grown;
                }
                es[n++] = e;
            }
        }
        at = eol + 1;
    }
    *out = es;
    return n;
}

/* `fmt` as one cell of the row being built, with a `link` over it when `link` is set. */
static void cell(oket_build *b, const char *link, const char *fmt, ...) {
    static char *buf;
    static size_t cap;
    va_list       ap;
    int           n;

    va_start(ap, fmt);
    n = vsnprintf(buf, cap, fmt, ap);
    va_end(ap);
    if (n >= 0 && (size_t)n >= cap) {
        char *grown = realloc(buf, (size_t)n + 1);
        if (!grown) {
            return;
        }
        buf = grown;
        cap = (size_t)n + 1;
        va_start(ap, fmt);
        vsnprintf(buf, cap, fmt, ap);
        va_end(ap);
    }
    oket_build_cell(b, "row", buf, (size_t)n);
    if (link) {
        oket_build_link(b, "link", 0, (size_t)n, link, strlen(link));
    }
}

static char *link_of(const grep_doc *g, const entry *e) {
    size_t n = strlen(g->cwd) + e->path_len + 32;
    char  *s = malloc(n);
    if (s) {
        int abs = e->path_len > 0 && e->path[0] == '/';
        snprintf(s, n, "%s%s%.*s:%zu", abs ? "" : g->cwd, abs ? "" : "/", (int)e->path_len,
                 e->path, e->line);
    }
    return s;
}

static void render(const lues_api *api, lues_self self, lues_doc doc, grep_doc *g) {
    entry          *es = NULL;
    size_t          n = parse(g, &es), i, j, matches = 0, nlinks = 0;
    char          **links = calloc(n * 2 + 1, sizeof *links); /* borrowed until the submit */
    oket_build      b = {0};
    oket_descriptor d = {0};
    oket_cursor     c = {0};

    for (i = 0; i < n; i++) {
        matches += (size_t)es[i].match;
    }
    cell(&b, NULL, "%s%zu matches for %s in %s", g->done ? "" : "searching, ", matches, g->query,
         g->cwd);
    oket_build_row(&b);
    free(g->heads);
    g->heads = calloc(n + 1, sizeof *g->heads);
    g->nheads = 0;

    for (i = 0; links && g->heads && i < n; i = j) {
        const entry *first = &es[i];
        char        *head;

        for (j = i; j < n && es[j].block == es[i].block; j++) {
            if (es[j].match && !first->match) {
                first = &es[j];
            }
        }
        oket_build_row(&b);
        g->heads[g->nheads++] = (size_t)b.line;
        head = links[nlinks++] = link_of(g, first);
        cell(&b, head, "%.*s:%zu", (int)first->path_len, first->path, first->line);
        if (head) {
            oket_build_link(&b, "file", 0, first->path_len, head, strlen(head));
        }
        oket_build_row(&b);
        for (; i < j; i++) {
            links[nlinks] = link_of(g, &es[i]);
            cell(&b, links[nlinks++], "%6zu%c %.*s", es[i].line, es[i].match ? '>' : ' ',
                 (int)es[i].text_len, es[i].text);
            oket_build_row(&b);
        }
    }

    d.kind = GREP_KIND;
    d.render = OKET_RENDER_TEXT;
    d.selection = OKET_SELECT_LINE;
    d.input = OKET_INPUT_BOUND;
    d.tab_width = 4;
    oket_build_submit(api, self, doc, &b, b.len > 0 ? b.len - 1 : 0, &d, LUES_SUBMIT_FORGET);
    oket_build_free(&b);
    if (g->done && g->nheads > 0) {
        c.head.line = c.anchor.line = (ptrdiff_t)g->heads[0];
        c.goal = -1;
        oket(api)->cursors(api, self, doc, &c, 1, 0);
    }
    for (i = 0; links && i < nlinks; i++) {
        free(links[i]);
    }
    free(links);
    free(es);
}

static void *open_grep(const lues_api *api, lues_self self, lues_doc doc, const char *args,
                       size_t args_len) {
    grep_doc   *g = calloc(1, sizeof *g);
    char             *cmd;
    const char       *argv[3];
    const oket_world *w;

    if (!g) {
        return NULL;
    }
    g->query = oket_dup(args, args_len);
    if ((w = oket(api)->world(api, self))) {
        g->cwd = oket_dup(w->dir, w->dir_len);
        oket(api)->world_release(api, self, w);
    }
    cmd = malloc(sizeof GREP + args_len);
    if (!g->query || !g->cwd || !cmd) {
        free(cmd);
        g->done = 1;
        return g;
    }
    memcpy(cmd, GREP, sizeof GREP - 1);
    memcpy(cmd + sizeof GREP - 1, args, args_len);
    cmd[sizeof GREP - 1 + args_len] = '\0';
    argv[0] = "sh";
    argv[1] = "-c";
    argv[2] = cmd;
    g->io = api->io_spawn(api, self, doc, argv, 3, g->cwd, strlen(g->cwd));
    free(cmd);
    render(api, self, doc, g);
    return g;
}

static void close_grep(const lues_api *api, lues_self self, lues_doc doc, void *inst) {
    grep_doc *g = inst;

    (void)doc;
    if (!g->done) {
        api->io_close(api, self, g->io);
    }
    free(g->query);
    free(g->cwd);
    free(g->out);
    free(g->heads);
    free(g);
}

static int32_t grep_event(const lues_api *api, lues_self self, const lues_at *at, lues_event ev,
                          const char *text, size_t len) {
    grep_doc *g = at->inst;

    if (!g) {
        return 0;
    }
    if (ev == LUES_EVENT_IO) {
        append(g, text, len);
    } else if (ev == LUES_EVENT_IO_END) {
        g->done = 1;
        render(api, self, at->doc, g);
    }
    return 0;
}

/* The next or previous block's header, from the caret's line. */
static int32_t step(const lues_api *api, lues_self self, const lues_at *at, int forward) {
    grep_doc       *g = at->inst;
    const oket_side *side;
    size_t          caret, i, to;
    oket_cursor     c = {0};

    if (!oket_mine(at) || !at->snap || !g || g->nheads == 0) {
        return 1;
    }
    side = oket_side_of(at->snap);
    caret = side->ncursors ? (size_t)side->cursors[side->primary].head.line : 0;
    to = forward ? g->heads[g->nheads - 1] : g->heads[0];
    for (i = 0; i < g->nheads; i++) {
        size_t h = forward ? g->heads[i] : g->heads[g->nheads - 1 - i];
        if (forward ? h > caret : h < caret) {
            to = h;
            break;
        }
    }
    c.head.line = c.anchor.line = (ptrdiff_t)to;
    c.goal = -1;
    oket(api)->cursors(api, self, at->doc, &c, 1, 0);
    oket(api)->reveal(api, self, at->doc, oket_line_start(at->snap, to),
                      oket_line_start(at->snap, to + 1), OKET_REVEAL_NEAREST);
    return 0;
}

static int32_t down_cmd(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                        size_t args_len) {
    (void)args;
    (void)args_len;
    return step(api, self, at, 1);
}

static int32_t up_cmd(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                      size_t args_len) {
    (void)args;
    (void)args_len;
    return step(api, self, at, 0);
}

static int32_t grep_cmd(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                        size_t args_len) {
    (void)at;
    if (args_len == 0) {
        api->message(api, self, LIT(":grep <pattern> [path]..."));
        return 1;
    }
    oket(api)->open(api, self, GREP_KIND, args, args_len);
    return 0;
}

int grep_register(const lues_api *api, lues_self self) {
    static const lues_kind_spec SPEC = {
        sizeof(lues_kind_spec),
        LIT("grep"),
        LIT("surface"),
        {open_grep, close_grep, grep_event},
    };

    GREP_KIND = api->register_kind(api, self, &SPEC);
    if (GREP_KIND == 0) {
        return 1;
    }
    api->register_command(api, self, LIT("grep"), LIT("grep -rn, as a list of links"), grep_cmd);
    api->register_command(api, self, LIT("grep.down"), LIT("the next match's block"), down_cmd);
    api->register_command(api, self, LIT("grep.up"), LIT("the previous match's block"), up_cmd);
    api->request_bind(api, self, LIT("grep"), LIT("enter"), LIT("exec :openlink"));
    /* `<file>` is the hole that draws the header as a link. */
    api->request_bind(api, self, LIT("grep"), LIT("double-click"), LIT("exec :openlink <file>"));
    api->request_bind(api, self, LIT("grep"), LIT("down"), LIT("grep.down"));
    api->request_bind(api, self, LIT("grep"), LIT("up"), LIT("grep.up"));
    return 0;
}
