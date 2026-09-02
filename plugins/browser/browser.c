/* The file tree, as a plugin (§5, stage 10). What it proves is that `fields`, `columns`,
 * `depth` and `selection: line` are enough to be a TUI, with the kernel drawing all of it.
 *
 * WHAT IS HERE is a directory walk, a set of expanded paths, and a builder call per row.
 *
 * WHAT IS NOT HERE is everything a tree widget usually carries: no draw, no scroll, no
 * hit-test, no cursor, no key handler, and no `enter` callback. Moving through the tree is the
 * kernel's own nav rows over any document; the indent is one number per line; and `enter` is a
 * line in binds.conf, so what it does is auditable, rebindable and answers to `describe`:
 *
 *     [browser]
 *     enter = exec :br.toggle <path> && :open <path>
 *
 * That row is the whole navigation story. `br.toggle` expands a directory and STOPS the chain;
 * over a file it does nothing and lets the chain go on to the kernel's own `:open`, which
 * hands the file to whoever registered the `edit` kind. An exit code is the only thing the
 * plugin contributes, and `&&` is doing the rest.
 *
 *     :pluginify plugins/browser      build it and load it
 *     alt+b                           the tree, rooted where oket was started
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "oket_helpers.h"

#define LIT(s) s, sizeof(s) - 1

/* A level of nesting is INDENT cells, because the kernel indents by the document's own tab
 * width (§5) — so a tree says how wide a level is by saying what a tab is worth. */
#define INDENT 2
#define PATH_CAP 4096
#define NAME_WIDTH 60

static oket_kind BROWSER;

/* Per-document state. The tree itself is not here: the rows ARE the document, and re-reading
 * them is a snapshot walk rather than a copy this would have to keep in step (§6). */
typedef struct {
    char  *root;  /* owned */
    char **open;  /* owned paths, the directories that are expanded */
    size_t nopen;
} browser;

static int is_dir(const char *path, long *size) {
    struct stat st;

    if (stat(path, &st) != 0) {
        *size = 0;
        return 0;
    }
    *size = (long)st.st_size;
    return S_ISDIR(st.st_mode);
}

/* --- the expanded set --- */

static int expanded(const browser *b, const char *path) {
    size_t i;

    for (i = 0; i < b->nopen; i++) {
        if (strcmp(b->open[i], path) == 0) {
            return 1;
        }
    }
    return 0;
}

/* Collapsing keeps its children in the set, so re-opening a directory comes back the way you
 * left it. */
static void toggle_open(browser *b, const char *path) {
    char **grown;
    size_t i;

    for (i = 0; i < b->nopen; i++) {
        if (strcmp(b->open[i], path) == 0) {
            free(b->open[i]);
            b->open[i] = b->open[--b->nopen];
            return;
        }
    }
    grown = realloc(b->open, (b->nopen + 1) * sizeof *b->open);
    if (grown == NULL) {
        return;
    }
    b->open = grown;
    b->open[b->nopen] = oket_dup(path, strlen(path));
    if (b->open[b->nopen] != NULL) {
        b->nopen++;
    }
}

/* Open, whatever it was: a re-root must not close the directory it is rooting at. */
static void expand(browser *b, const char *path) {
    if (!expanded(b, path)) {
        toggle_open(b, path);
    }
}

/* --- building the rows --- */

typedef struct {
    char *name;
    int   dir;
    long  size;
} entry;

/* Directories first, then by name: the shape the eye expects, and the order is the plugin's to
 * pick because a listing is text it produced. */
static int by_kind_then_name(const void *a, const void *b) {
    const entry *x = a, *y = b;

    return x->dir != y->dir ? y->dir - x->dir : strcmp(x->name, y->name);
}

/* One row: the marker, the full path with its tail named, and the size.
 *
 * The row DRAWS the name and ACTS on the path (§14). Both are spans over one cell — the name
 * being the path's tail — so hover underlines the drawn half, because the field a bind names
 * CONTAINS it. `file` is the same span under another name, and a directory carries none: a row
 * that cannot fill `<file>` says so with data rather than with a refusal (§8). */
static void put_row(oket_build *out, int depth, const char *path, int dir, int open, long size) {
    const char *slash = strrchr(path, '/');
    const char *base = slash == NULL ? path : slash + 1;
    size_t len = strlen(path);
    char size_text[32];
    int n = dir ? 0 : snprintf(size_text, sizeof size_text, "%ld", size);

    oket_build_depth(out, depth);
    oket_build_cell(out, "mark", dir ? (open ? "-" : "+") : " ", 1);
    oket_build_cell(out, "path", path, len);
    oket_build_span(out, "name", (size_t)(base - path), len);
    if (!dir) {
        oket_build_span(out, "file", 0, len);
    }
    oket_build_cell(out, "size", size_text, n < 0 ? 0 : (size_t)n);
    oket_build_row(out);
}

/* The children of one expanded directory, and the children of any of THOSE that are expanded.
 * Depth is the recursion's own counter, which is the whole of what the kernel needs to draw a
 * tree. */
static void walk(browser *b, oket_build *out, const char *dir, int depth) {
    DIR *d = opendir(dir);
    struct dirent *de;
    entry *entries = NULL;
    size_t n = 0, i;
    char path[PATH_CAP];

    if (d == NULL) {
        return;
    }
    while ((de = readdir(d)) != NULL) {
        entry *grown;

        if (de->d_name[0] == '.') {
            continue; /* dotfiles are noise until there is a row to toggle them */
        }
        grown = realloc(entries, (n + 1) * sizeof *entries);
        if (grown == NULL) {
            break;
        }
        entries = grown;
        snprintf(path, sizeof path, "%s/%s", dir, de->d_name);
        entries[n].name = oket_dup(de->d_name, strlen(de->d_name));
        entries[n].dir = is_dir(path, &entries[n].size);
        if (entries[n].name == NULL) {
            break;
        }
        n++;
    }
    closedir(d);
    if (entries != NULL) { /* an empty directory: qsort's base must be a valid pointer */
        qsort(entries, n, sizeof *entries, by_kind_then_name);
    }

    for (i = 0; i < n; i++) {
        int open;

        snprintf(path, sizeof path, "%s/%s", dir, entries[i].name);
        open = entries[i].dir && expanded(b, path);
        put_row(out, depth, path, entries[i].dir, open, entries[i].size);
        if (open) {
            walk(b, out, path, depth + 1);
        }
        free(entries[i].name);
    }
    free(entries);
}

/* The tree, and the descriptor that says how to draw it. `editable` is 0, which is what makes
 * the kernel treat the next rewrite as a REGENERATION and leave point on its row. */
static void publish(const oket_api *api, oket_self self, oket_doc doc, browser *b) {
    oket_descriptor d;
    oket_build out;

    memset(&out, 0, sizeof out);
    /* The whole row moves in by its depth (§5), so a tree draws no size column: it would come
     * back ragged. `size` is still a FIELD — a value a bind row can read that nothing draws. */
    oket_build_column(&out, "mark", 1, OKET_ALIGN_LEFT);
    oket_build_column(&out, "name", NAME_WIDTH, OKET_ALIGN_LEFT);
    put_row(&out, 0, b->root, 1, expanded(b, b->root), 0);
    if (expanded(b, b->root)) {
        walk(b, &out, b->root, 1);
    }

    memset(&d, 0, sizeof d);
    d.kind = BROWSER;
    d.render = OKET_RENDER_TEXT;
    d.selection = OKET_SELECT_LINE; /* a browser selects rows, an editor characters (§5) */
    d.input = OKET_INPUT_BOUND;
    d.tab_width = INDENT;
    d.file = b->root;
    d.file_len = strlen(b->root);
    oket_build_desc(&out, &d);
    /* Minus the row terminator the last row wrote: a document does not end in a blank line. */
    oket_set(api, self, doc, out.text, out.len > 0 ? out.len - 1 : 0, &d);
    oket_build_free(&out); /* the kernel copied all of it at submit */
}

/* --- the six messages --- */

static void *open_browser(const oket_api *api, oket_self self, oket_doc doc,
                          const char *args, size_t args_len) {
    browser *b = calloc(1, sizeof *b);

    if (b == NULL) {
        return NULL;
    }
    b->root = args_len > 0 ? oket_dup(args, args_len) : oket_dup(".", 1);
    if (b->root == NULL) {
        free(b);
        return NULL;
    }
    expand(b, b->root); /* the root starts open, or there is nothing to look at */
    publish(api, self, doc, b);
    return b;
}

static void close_browser(const oket_api *api, oket_self self, oket_doc doc, void *inst) {
    browser *b = inst;
    size_t i;

    (void)api;
    (void)self;
    (void)doc;
    if (b == NULL) {
        return;
    }
    for (i = 0; i < b->nopen; i++) {
        free(b->open[i]);
    }
    free(b->open);
    free(b->root);
    free(b);
}

/* `br.toggle <path>` — the first half of the `enter` row.
 *
 * The exit code is the whole interface: non-zero over a directory STOPS the `&&` chain, having
 * expanded or collapsed it; zero over anything else lets the chain reach `:open <path>`. A
 * plugin cannot open a document of somebody else's kind and does not need to — the command
 * line it was bound in can. */
static int32_t toggle_cmd(const oket_api *api, oket_self self, const oket_at *at,
                          const char *args, size_t args_len) {
    browser *b = at->inst;
    char path[PATH_CAP];
    long size;

    if (!oket_mine(at) || args_len == 0 || args_len >= sizeof path) {
        return 0;
    }
    memcpy(path, args, args_len);
    path[args_len] = '\0';
    if (!is_dir(path, &size)) {
        return 0;
    }
    toggle_open(b, path);
    publish(api, self, at->snap->doc, b);
    return 1;
}

/* `:br.root <path>` — the tree, somewhere else. The lane already holds this document, so the
 * root moves rather than a second tree opening beside it. */
static int32_t root_cmd(const oket_api *api, oket_self self, const oket_at *at,
                        const char *args, size_t args_len) {
    browser *b = at->inst;
    char *root;
    long size;

    if (!oket_mine(at)) {
        oket_say(api, self, "br.root: this document is not the browser's");
        return 1;
    }
    if (args_len == 0) {
        oket_say(api, self, "br.root <path>");
        return 1;
    }
    root = oket_dup(args, args_len);
    if (root == NULL || !is_dir(root, &size)) {
        free(root);
        oket_say(api, self, "br.root: that is not a directory");
        return 1;
    }
    free(b->root);
    b->root = root;
    expand(b, b->root);
    publish(api, self, at->snap->doc, b);
    return 0;
}

OKET_MAIN {
    static const oket_kind_spec SPEC = {
        LIT("browser"),
        LIT("surface"),
        {open_browser, close_browser, NULL}, /* no event: every chord is a row (§8) */
    };

    BROWSER = api->register_kind(api, self, &SPEC);
    if (BROWSER == 0) {
        return 1;
    }
    api->register_command(api, self, LIT("br.toggle"),
                          LIT("expand or collapse the directory, and stop the chain if it was one"),
                          toggle_cmd);
    api->register_command(api, self, LIT("br.root"), LIT("move the tree to another directory"),
                          root_cmd);
    /* ASKED FOR, never claimed (§8). `enter` shadows the surface-tier `:open <path>` row for
     * this kind alone, and `click` is the same line: a plugin that declares `fields` gets the
     * mouse by adding a row, and never sees an event. */
    api->request_bind(api, self, LIT("browser"), LIT("enter"),
                      LIT("exec :br.toggle <path> && :open <path>"));
    api->request_bind(api, self, LIT("browser"), LIT("click"),
                      LIT("exec :br.toggle <path> && :open <path>"));
    api->request_bind(api, self, LIT("global"), LIT("alt+@AB05"), LIT("exec :ring browser"));
    return 0;
}
