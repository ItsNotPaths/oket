/* The file browser (§5, stage 10, and §14's link answer). A DIRECTORY IS A BUFFER FULL OF
 * NAMES: the document is `ls -la` output, typing into a row renames it, and `:fs.commit` does
 * the renames on disk. There is no listing widget here and no second, smaller editor — the
 * names go into a kernel document and the kernel draws and edits it.
 *
 * THE LIST SCAFFOLD IS THE HELPER LIBRARY'S LIST CORE: the publish, the caret pinned to the end
 * of a name, typing and erase clamped into it, and the ctrl+f filter are oket_list's. What is
 * this file's is the platter — the walk, the open set, and the commit that renames.
 *
 * WHAT MAKES IT WORK is that a field carries a VALUE (desc.Field). The `path` field spans the
 * NAME and its value is the whole path, so a row DRAWS `files.c` and ACTS on
 * `plugins/files/files.c`. Without a value the path has to hide in a column nothing
 * renders, and a `columns` document cannot draw a caret — no caret, no typing.
 *
 * THE CARET IS PINNED TO THE END OF A NAME, and everything else follows from that. There is no
 * cursor movement inside a row: `up` and `down` move a row and land at the end of its name,
 * with the trailing slash of a directory left out of it, so every row you arrive on is ready to
 * type into. `left` and `right` are the hierarchy — up a directory, into one — because nothing
 * else needs them. A typed rune and a backspace are both CLAMPED into the name, so the mode
 * bits, the size and the date cannot be edited at all, wherever the caret happens to be.
 *
 * WHAT IS NOT HERE is everything a listing usually carries: no draw, no scroll, no hit-test,
 * no cursor, and no key handler. Motion, selection and undo are the kernel's, and every chord
 * is a row in binds.conf:
 *
 *     [files]
 *     enter          = exec :fs.enter <path> && :open <path>
 *     ctrl+backspace = fs.up
 *
 * `fs.enter` VISITS a directory — the buffer becomes that directory, the way dired's RET does —
 * and STOPS the chain; over a file it does nothing and lets the chain reach the kernel's own
 * `:open`, which hands the file to the `edit` kind. An exit code is the only thing the plugin
 * contributes, and `&&` is doing the rest.
 *
 * `fs.toggle` is still here and opens a subtree UNDER a row without leaving the directory. It
 * is unbound by default — one binds.conf line from any key.
 *
 *     :pluginify plugins/files      build it and load it
 *     alt+f                           the listing, rooted where oket was started
 */
/* stage.sh compiles with -std=c11, which hides the POSIX names this file reads the platter
 * with: mode_t, localtime_r, and readdir's own header. */
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "oket_helpers.h"

#define INDENT 2 /* cells per level, for a subtree opened in place */
#define PATH_CAP 4096
#define NAME_CAP 256
#define MODE_CAP 12
#define WHEN_CAP 16
#define SIZE_CAP 24
#define SIZE_W 9
#define WHEN_W 12
/* `drwxr-xr-x` SP `     4096` SP SP `Sep  2 21:35` SP SP — fixed, so every name starts at the
 * same column and a rename never moves what is left of it. */
#define PREFIX_W (10 + 1 + SIZE_W + 2 + WHEN_W + 2)
#define LINE_CAP (PREFIX_W + NAME_CAP + 64)

static oket_kind FILES;

/* One line of the document. `path` is where the row POINTS and `shown` is what it DRAWS, and a
 * commit is the whole of the difference between them: the two stop agreeing the moment you type.
 *
 * `shown` is not read back off the document at publish time. It is what was last written there
 * plus whatever the harvest below picked up, so a listing that regenerates while a rename is
 * half-typed keeps the half. */
typedef struct {
    char *path;  /* owned */
    char *shown; /* owned; the name, without a directory's trailing slash */
    char  mode[MODE_CAP];
    char  when[WHEN_CAP];
    char  size[SIZE_CAP];
    int   dir;
    int   depth;
    /* `..`, which is a way OUT and not an entry: it renames to nothing, so typing, backspace
     * and the commit all skip it. Every other row is a name on the platter. */
    int   fixed;
} row;

typedef struct {
    char  *root; /* owned */
    char **open; /* owned paths, the directories whose subtree is open in place */
    size_t nopen;
    row   *rows; /* owned, one per entry the walk found */
    size_t nrows;
    int    hidden; /* are dotfiles listed */
} browser;

/* --- the platter --- */

static void mode_string(mode_t m, char *out) {
    static const char RWX[] = "rwx";
    int i;

    out[0] = S_ISDIR(m) ? 'd' : S_ISLNK(m) ? 'l' : '-';
    for (i = 0; i < 9; i++) {
        out[1 + i] = (m & (mode_t)(1 << (8 - i))) != 0 ? RWX[i % 3] : '-';
    }
    out[10] = '\0';
}

/* `ls`'s own rule: the clock for something recent, the year for anything older, so the column
 * stays one width and still says which. */
static void when_string(time_t t, char *out, size_t cap) {
    struct tm parts;
    time_t now = time(NULL);

    if (localtime_r(&t, &parts) == NULL) {
        snprintf(out, cap, "%*s", WHEN_W, "");
        return;
    }
    if (now - t > 180 * 24 * 3600 || t > now + 60) {
        strftime(out, cap, "%b %e  %Y", &parts);
    } else {
        strftime(out, cap, "%b %e %H:%M", &parts);
    }
}

static int is_dir(const char *path) {
    struct stat st;

    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int exists(const char *path) {
    struct stat st;

    return stat(path, &st) == 0;
}

/* The directory `path` lives in, written into `out`. A path with no separator is a name in the
 * current directory, so its parent is that. */
static void parent_of(const char *path, char *out, size_t cap) {
    const char *slash = strrchr(path, '/');
    size_t n;

    if (slash == NULL) {
        snprintf(out, cap, ".");
        return;
    }
    n = slash == path ? 1 : (size_t)(slash - path); /* "/etc" lives in "/", not in "" */
    if (n >= cap) {
        n = cap - 1;
    }
    memcpy(out, path, n);
    out[n] = '\0';
}

static const char *base_of(const char *path) {
    const char *slash = strrchr(path, '/');

    return slash == NULL ? path : slash + 1;
}

/* --- the open set (a subtree shown in place) --- */

static int expanded(const browser *b, const char *path) {
    size_t i;

    for (i = 0; i < b->nopen; i++) {
        if (strcmp(b->open[i], path) == 0) {
            return 1;
        }
    }
    return 0;
}

/* Closing keeps its children in the set, so re-opening a directory comes back the way you left
 * it. */
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

/* --- the rows --- */

static void rows_free(browser *b) {
    size_t i;

    for (i = 0; i < b->nrows; i++) {
        free(b->rows[i].path);
        free(b->rows[i].shown);
    }
    free(b->rows);
    b->rows = NULL;
    b->nrows = 0;
}

/* The row a path had before the rebuild, so a name you have typed and not committed survives
 * one. A rolling start index, because both lists are in the same order. */
static const row *kept_row(const row *old, size_t nold, size_t *from, const char *path) {
    size_t i;

    for (i = *from; i < nold; i++) {
        if (strcmp(old[i].path, path) == 0) {
            *from = i + 1;
            return &old[i];
        }
    }
    return NULL;
}

typedef struct {
    row       *list;
    size_t     n, cap;
    const row *old;
    size_t     nold, from;
} rows_build;

static void row_add(rows_build *rb, const char *path, const char *name, const struct stat *st,
                    int depth, int fixed) {
    const row *was = kept_row(rb->old, rb->nold, &rb->from, path);
    row *r;

    if (rb->n == rb->cap) {
        size_t cap = rb->cap == 0 ? 64 : rb->cap * 2;
        row *grown = realloc(rb->list, cap * sizeof *grown);

        if (grown == NULL) {
            return;
        }
        rb->list = grown;
        rb->cap = cap;
    }
    r = &rb->list[rb->n];
    memset(r, 0, sizeof *r);
    r->path = oket_dup(path, strlen(path));
    r->shown = was != NULL ? oket_dup(was->shown, strlen(was->shown))
                           : oket_dup(name, strlen(name));
    if (r->path == NULL || r->shown == NULL) {
        free(r->path);
        free(r->shown);
        return;
    }
    r->dir = fixed ? 1 : S_ISDIR(st->st_mode) != 0;
    r->depth = depth;
    r->fixed = fixed;
    mode_string(st->st_mode, r->mode);
    when_string(st->st_mtime, r->when, sizeof r->when);
    snprintf(r->size, sizeof r->size, "%lld", (long long)st->st_size);
    rb->n++;
}

typedef struct {
    char       *name;
    struct stat st;
} entry;

/* Directories first, then by name: the shape the eye expects, and the order is the plugin's to
 * pick because a listing is text it produced. */
static int by_kind_then_name(const void *a, const void *b) {
    const entry *x = a, *y = b;
    int xd = S_ISDIR(x->st.st_mode) != 0, yd = S_ISDIR(y->st.st_mode) != 0;

    return xd != yd ? yd - xd : strcmp(x->name, y->name);
}

/* The children of one directory, and the children of any of THOSE whose subtree is open. Depth
 * is the recursion's own counter. */
static void walk(browser *b, rows_build *rb, const char *dir, int depth) {
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

        if (de->d_name[0] == '.' && (!b->hidden || strcmp(de->d_name, ".") == 0
                                     || strcmp(de->d_name, "..") == 0)) {
            continue;
        }
        grown = realloc(entries, (n + 1) * sizeof *entries);
        if (grown == NULL) {
            break;
        }
        entries = grown;
        snprintf(path, sizeof path, "%s/%s", dir, de->d_name);
        memset(&entries[n].st, 0, sizeof entries[n].st);
        (void)stat(path, &entries[n].st); /* a broken link lists as a zero row rather than not */
        entries[n].name = oket_dup(de->d_name, strlen(de->d_name));
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
        snprintf(path, sizeof path, "%s/%s", dir, entries[i].name);
        row_add(rb, path, entries[i].name, &entries[i].st, depth, 0);
        if (S_ISDIR(entries[i].st.st_mode) && expanded(b, path)) {
            walk(b, rb, path, depth + 1);
        }
        free(entries[i].name);
    }
    free(entries);
}

/* The directory, read again from disk, with typed names carried across. `keep` off is the
 * reload: what is on disk wins and half-typed renames go.
 *
 * ROW 0 IS ALWAYS `..`, whatever the directory holds and wherever it is. Which directory you
 * are in is the bar's answer; what a listing has to carry is the way out of it, and a row is how
 * this one carries anything — so it is a link like the rest and `enter` over it needs no case of
 * its own. `walk` leaves the real `..` out, so there is never a second one. */
static void rows_read(browser *b, int keep) {
    rows_build rb;
    struct stat st;
    char up[PATH_CAP];

    memset(&rb, 0, sizeof rb);
    if (keep) {
        rb.old = b->rows;
        rb.nold = b->nrows;
    }
    parent_of(b->root, up, sizeof up);
    memset(&st, 0, sizeof st);
    (void)stat(up, &st);
    row_add(&rb, up, "..", &st, 0, 1);
    walk(b, &rb, b->root, 0);
    rows_free(b);
    b->rows = rb.list;
    b->nrows = rb.n;
}

static size_t row_of(const browser *b, const char *path) {
    size_t i;

    for (i = 0; i < b->nrows; i++) {
        if (strcmp(b->rows[i].path, path) == 0) {
            return i;
        }
    }
    return 0;
}

/* --- the rows, through the list core --- */

static int32_t b_count(void *ctx) {
    browser *b = ctx;

    return (int32_t)b->nrows;
}

/* `..` is always a row: a filtered listing still needs its way out. */
static int b_match(void *ctx, int32_t i, const char *filter, size_t n) {
    browser *b = ctx;

    return b->rows[i].fixed || n == 0 || strstr(b->rows[i].shown, filter) != NULL;
}

/* One row: `ls -la` for the eye, and the fields over it for a bind.
 *
 * `path` spans the NAME and carries the whole path as its value — what §14 asked for and could
 * not have. What a row SHOWS and what it ACTS ON are two questions, and a value is the answer
 * to the second. `file` is absent on a directory, so a row that cannot fill `<file>` says so
 * with data rather than with a refusal (§8). */
static void b_row(void *ctx, oket_build *out, oket_list_row *lr, int32_t idx) {
    browser *b = ctx;
    row *r = &b->rows[idx];
    char text[LINE_CAP];
    size_t n, name_lo, name_hi, len = strlen(r->shown);
    int i;

    n = (size_t)snprintf(text, sizeof text, "%-10s %*s  %-*s  ", r->mode, SIZE_W, r->size,
                         WHEN_W, r->when);
    if (n > PREFIX_W) {
        n = PREFIX_W; /* a size wider than its column: the name column is what stays put */
    }
    for (i = 0; i < r->depth * INDENT && n + 1 < sizeof text; i++) {
        text[n++] = ' '; /* an open subtree indents the NAME, never the whole row */
    }
    name_lo = n;
    if (len > NAME_CAP) {
        len = NAME_CAP;
    }
    if (len > sizeof text - n - 1) {
        len = sizeof text - n - 1; /* a subtree deep enough to reach the buffer end */
    }
    memcpy(text + n, r->shown, len);
    n += len;
    name_hi = n;
    if (r->dir) {
        text[n++] = '/'; /* open or closed is the indent under it, so there is no marker */
    }
    lr->name_off = (int32_t)name_lo;
    lr->name_len = (int32_t)len;
    lr->fixed = (uint8_t)r->fixed;
    lr->tail = r->dir ? 1 : 0;

    oket_build_cell(out, "row", text, n);
    oket_build_span(out, "mode", 0, 10);
    /* Right-aligned in its column, so the digits are its TAIL and the padding is not part of
     * what `<size>` answers. */
    oket_build_span(out, "size", 11 + SIZE_W - strlen(r->size), 11 + SIZE_W);
    oket_build_link(out, "path", name_lo, name_hi, r->path, strlen(r->path));
    oket_build_span(out, "name", name_lo, name_hi);
    if (!r->dir) {
        oket_build_link(out, "file", name_lo, name_hi, r->path, strlen(r->path));
    }
}

/* No head row: the listing IS the document, and the panel diffs on its own (PANELS.md §7).
 * `editable` and `char` selection come from the spec — point is a caret in a name and not a
 * highlighted row — and the ctrl+f filter reports through the echo line instead. */
static const oket_list_spec LSPEC = {
    "files", "fs", OKET_SELECT_CHAR, 1, INDENT,
    b_count, b_match, b_row, NULL, NULL,
};

/* --- reading the document back --- */

/* What the document says now, back into the rows. A rename is TYPED, so between one publish and
 * the next the document is ahead of this plugin, and a rebuild that did not read it back would
 * throw away what was typed (§6: the text is the state).
 *
 * A line count that does not match is a document somebody has split or joined — an edit no row
 * survives — so nothing is harvested and `commit` will refuse for the same reason. */
static void harvest(oket_list *l, const oket_snapshot *s) {
    browser *b = l->ctx;
    size_t j;

    if (s == NULL || s->lines != 1 + l->nrows) {
        return;
    }
    for (j = 0; j < l->nrows; j++) {
        char name[LINE_CAP];
        row *r = &b->rows[l->rows[j].idx];
        size_t lo, hi, n;
        char *shown;

        if (r->fixed) {
            continue;
        }
        oket_line_range(s, 1 + j, &lo, &hi);
        if (hi - lo < (size_t)l->rows[j].name_off) {
            continue; /* the prefix is gone: not a row a name can be read out of */
        }
        n = oket_list_name(s, l, 1 + j, name, sizeof name);
        shown = oket_dup(name, n);
        if (shown != NULL) {
            free(r->shown);
            r->shown = shown;
        }
    }
}

/* Names typed over and not committed. Visiting another directory drops them, and a regeneration
 * takes the undo log with it (§5), so this is said out loud rather than lost quietly (§8). */
static int pending(const browser *b) {
    size_t i;
    int n = 0;

    for (i = 0; i < b->nrows; i++) {
        if (!b->rows[i].fixed && strcmp(base_of(b->rows[i].path), b->rows[i].shown) != 0) {
            n++;
        }
    }
    return n;
}

/* Read the document back, read the directory again, write it out: the three steps every verb
 * below ends with. `keep` off throws typed names away, which is what a reload is. */
static void rebuild(const oket_api *api, oket_self self, oket_list *l, const oket_at *at,
                    int keep) {
    browser *b = l->ctx;

    if (keep) {
        harvest(l, at->snap);
    }
    rows_read(b, keep);
    oket_list_publish(api, self, l);
}

/* The listing, rooted somewhere else, with the caret on `land`'s name once the rows exist.
 * Shared by every verb that MOVES rather than opens: visiting a directory, going back up, and
 * `:fs.root`. The filter is this directory's, so it goes too. */
static void reroot(const oket_api *api, oket_self self, oket_list *l, const oket_at *at,
                   const char *root, const char *land) {
    browser *b = l->ctx;
    char report[128];
    char kept[PATH_CAP];
    size_t idx;
    ptrdiff_t line;
    int dropped;

    harvest(l, at->snap);
    dropped = pending(b);
    snprintf(kept, sizeof kept, "%s", land == NULL ? "" : land);
    free(b->root);
    b->root = oket_dup(root, strlen(root));
    l->file = b->root;
    l->nfilter = 0;
    l->filter[0] = 0;
    l->filtering = 0;
    rows_read(b, 0); /* another directory, so nothing typed in this one carries over */
    oket_list_publish(api, self, l);
    /* The first real entry, not `..`: you arrive somewhere to look at what is in it. */
    idx = kept[0] == '\0' ? (b->nrows > 1 ? 1 : 0) : row_of(b, kept);
    line = oket_list_row_line(l, (int32_t)idx);
    oket_list_point(api, self, l, line >= 0 ? (size_t)line : 0);
    if (dropped > 0) {
        snprintf(report, sizeof report, "%d name(s) typed and not committed were dropped",
                 dropped);
        oket_say(api, self, report);
    }
}

/* --- the six messages --- */

static void *open_browser(const oket_api *api, oket_self self, oket_doc doc,
                          const char *args, size_t args_len) {
    browser *b = calloc(1, sizeof *b);
    oket_list *l;

    if (b == NULL) {
        return NULL;
    }
    /* Where oket was started, ABSOLUTE. `.` names the same directory and costs the two things a
     * root has to answer: what to call the row, and what is above it. */
    if (args_len > 0) {
        b->root = oket_dup(args, args_len);
    } else {
        char cwd[PATH_CAP];

        b->root = getcwd(cwd, sizeof cwd) != NULL ? oket_dup(cwd, strlen(cwd)) : oket_dup(".", 1);
    }
    if (b->root == NULL) {
        free(b);
        return NULL;
    }
    l = oket_list_open(api, self, doc, b);
    if (l == NULL) {
        free(b->root);
        free(b);
        return NULL;
    }
    l->file = b->root;
    b->hidden = 1; /* dotfiles are listed until :fs.hidden hides them */
    rows_read(b, 0);
    oket_list_publish(api, self, l);
    oket_list_point(api, self, l, l->nrows > 1 ? 2 : 1);
    return l;
}

static void close_browser(const oket_api *api, oket_self self, oket_doc doc, void *inst) {
    oket_list *l = inst;
    browser *b;
    size_t i;

    (void)api;
    (void)self;
    (void)doc;
    if (l == NULL) {
        return;
    }
    b = l->ctx;
    for (i = 0; i < b->nopen; i++) {
        free(b->open[i]);
    }
    free(b->open);
    rows_free(b);
    free(b->root);
    free(b);
    oket_list_close(l);
}

/* --- the verbs --- */

static int32_t refuse(const oket_api *api, oket_self self, const char *why) {
    oket_say(api, self, why);
    return 1;
}

/* The browser row behind the line point is on, or NULL over nothing. */
static row *row_at_point(oket_list *l, const oket_at *at, size_t *line) {
    const oket_list_row *lr;
    browser *b = l->ctx;

    *line = oket_list_line(at->snap);
    lr = oket_list_at(l, *line);
    return lr == NULL ? NULL : &b->rows[lr->idx];
}

/* The argument of a `<path>` hole, NUL-terminated into `out`. False for a line whose hole could
 * not be filled, which the kernel already reported. */
static int arg_path(const char *args, size_t args_len, char *out, size_t cap) {
    if (args_len == 0 || args_len >= cap) {
        return 0;
    }
    memcpy(out, args, args_len);
    out[args_len] = '\0';
    return 1;
}

/* `fs.enter <path>` — the first half of the `enter` row.
 *
 * A directory is VISITED: the buffer becomes that directory, the way dired's RET does, and not
 * a subtree opening underneath the row. One document, one place, and the row you were standing
 * on is where `left` brings you back to.
 *
 * The exit code is the whole interface: non-zero over a directory STOPS the `&&` chain, having
 * moved; zero over anything else lets the chain reach `:open <path>`. A plugin cannot open a
 * document of somebody else's kind and does not need to — the command line it was bound in can. */
static int32_t enter_cmd(const oket_api *api, oket_self self, const oket_at *at,
                         const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);
    char path[PATH_CAP];

    if (l == NULL || !arg_path(args, args_len, path, sizeof path)) {
        return 0;
    }
    if (!is_dir(path)) {
        return 0;
    }
    reroot(api, self, l, at, path, NULL);
    return 1;
}

/* `fs.up` — out of whatever you are inside of: an open subtree closes, and otherwise the
 * listing goes up a directory and lands on the row it came from. `ctrl+backspace`, and the
 * same place the `..` row takes you. */
static int32_t up_cmd(const oket_api *api, oket_self self, const oket_at *at,
                      const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);
    browser *b;
    row *r;
    char here[PATH_CAP];
    char up[PATH_CAP];
    size_t line;

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return refuse(api, self, "fs.up: this document is not the files list");
    }
    b = l->ctx;
    r = row_at_point(l, at, &line);
    if (r != NULL && !r->fixed && r->dir && expanded(b, r->path)) {
        toggle_open(b, r->path);
        rebuild(api, self, l, at, 1);
        oket_list_point(api, self, l, line);
        return 0;
    }
    snprintf(here, sizeof here, "%s", b->root);
    parent_of(here, up, sizeof up);
    if (strcmp(up, here) == 0) {
        return 0; /* already as far up as this path can name */
    }
    reroot(api, self, l, at, up, here);
    return 0;
}

/* `fs.into` — the directory under point, visited. The mirror of `fs.up`, and UNBOUND by
 * default: `enter` already visits a directory, so this is one binds.conf line away for anyone
 * who wants the pair on two chords. Over a file it does nothing. */
static int32_t into_cmd(const oket_api *api, oket_self self, const oket_at *at,
                        const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);
    row *r;
    size_t line;

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return refuse(api, self, "fs.into: this document is not the files list");
    }
    r = row_at_point(l, at, &line);
    if (r == NULL || !r->dir) {
        return 0; /* `..` is a directory like any other here, and going into it is going up */
    }
    reroot(api, self, l, at, r->path, NULL);
    return 0;
}

/* `fs.up.row` and `fs.down.row` — one row, and the caret lands at the END OF ITS NAME. That is
 * the whole of what navigation means here: there is no column to keep, because every row is
 * arrived at ready to type into. */
static int32_t step(const oket_api *api, oket_self self, oket_list *l, const oket_at *at,
                    int by) {
    size_t line = oket_list_line(at->snap);

    if (by < 0 && line == 0) {
        return 0;
    }
    oket_list_point(api, self, l, by < 0 ? line - 1 : line + 1);
    return 0;
}

static int32_t up_row_cmd(const oket_api *api, oket_self self, const oket_at *at,
                          const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return refuse(api, self, "fs.up.row: this document is not the files list");
    }
    return step(api, self, l, at, -1);
}

static int32_t down_row_cmd(const oket_api *api, oket_self self, const oket_at *at,
                            const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return refuse(api, self, "fs.down.row: this document is not the files list");
    }
    return step(api, self, l, at, 1);
}

/* `fs.snap` — the caret back onto the end of the name of whatever row it is on. What `click` is
 * bound to: the kernel moves point before it dispatches a button chord (§8), so this lands it
 * where a name is edited from rather than where the pointer happened to be. */
static int32_t snap_cmd(const oket_api *api, oket_self self, const oket_at *at,
                        const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return refuse(api, self, "fs.snap: this document is not the files list");
    }
    oket_list_point(api, self, l, oket_list_line(at->snap));
    return 0;
}

/* `fs.toggle <path>` — the subtree under a row, opened or closed IN PLACE. Unbound by default:
 * `enter` and the arrows are the hierarchy, and this is for the key you want it on. */
static int32_t toggle_cmd(const oket_api *api, oket_self self, const oket_at *at,
                          const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);
    char path[PATH_CAP];
    size_t line;

    if (l == NULL || !arg_path(args, args_len, path, sizeof path)) {
        return 0;
    }
    if (!is_dir(path)) {
        return 0;
    }
    line = oket_list_line(at->snap);
    toggle_open(l->ctx, path);
    rebuild(api, self, l, at, 1);
    oket_list_point(api, self, l, line);
    return 1;
}

/* `:fs.commit` — every name that has been typed over, renamed on disk.
 *
 * The rows say what each line USED to be, so the diff is the whole of what to do: a line whose
 * text still matches its row is not touched, and the ones that do not are renamed in place.
 * Nothing here deletes and nothing here overwrites — a name that would land on something that
 * already exists is reported and skipped, which is the one failure worth being loud about.
 *
 * A document with a different number of lines than rows is one somebody has split or joined,
 * and no row can be trusted to name its own line any more. That refuses whole: `:fs.reload` is
 * one key away and undo is the kernel's. */
static int32_t commit_cmd(const oket_api *api, oket_self self, const oket_at *at,
                          const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);
    const oket_snapshot *s = at->snap;
    browser *b;
    char report[256];
    size_t i, line;
    int done = 0, failed = 0;

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return refuse(api, self, "fs.commit: this document is not the files list");
    }
    b = l->ctx;
    if (s->lines != 1 + l->nrows) {
        return refuse(api, self, "fs.commit: a row was split or joined; f5 re-reads the listing");
    }
    line = oket_list_line(s);
    harvest(l, s);
    for (i = 0; i < b->nrows; i++) {
        char want[PATH_CAP];
        char dir[PATH_CAP];

        if (b->rows[i].fixed || strcmp(base_of(b->rows[i].path), b->rows[i].shown) == 0) {
            continue;
        }
        if (b->rows[i].shown[0] == '\0' || strchr(b->rows[i].shown, '/') != NULL) {
            failed++; /* a name is a name: an empty one, or one with a path in it, is neither */
            continue;
        }
        parent_of(b->rows[i].path, dir, sizeof dir);
        snprintf(want, sizeof want, "%s/%s", dir, b->rows[i].shown);
        if (exists(want) || rename(b->rows[i].path, want) != 0) {
            failed++;
            continue;
        }
        done++;
    }
    /* From disk, and NOT keeping what was typed: what is on the platter is the answer now, and
     * a name that failed has to come back saying so rather than looking committed. */
    rows_read(b, 0);
    oket_list_publish(api, self, l);
    oket_list_point(api, self, l, line);
    snprintf(report, sizeof report, "fs.commit: %d renamed, %d refused", done, failed);
    oket_say(api, self, report);
    return failed == 0 ? 0 : 1;
}

/* `:fs.reload` — the listing as the disk has it, and typed names dropped. The abort half of a
 * rename, and the way back from an edit that broke a row. */
static int32_t reload_cmd(const oket_api *api, oket_self self, const oket_at *at,
                          const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);
    size_t line;

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return refuse(api, self, "fs.reload: this document is not the files list");
    }
    line = oket_list_line(at->snap);
    rebuild(api, self, l, at, 0);
    oket_list_point(api, self, l, line);
    return 0;
}

/* `:fs.hidden` — dotfiles, shown or not. A row rather than a mode: it answers to `describe` and
 * it is one line in binds.conf away from any key. */
static int32_t hidden_cmd(const oket_api *api, oket_self self, const oket_at *at,
                          const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);
    browser *b;

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return refuse(api, self, "fs.hidden: this document is not the files list");
    }
    b = l->ctx;
    b->hidden = !b->hidden;
    rebuild(api, self, l, at, 1);
    oket_list_point(api, self, l, 1);
    return 0;
}

/* `:fs.root <path>` — the listing, somewhere else. The lane already holds this document, so the
 * root moves rather than a second listing opening beside it. */
static int32_t root_cmd(const oket_api *api, oket_self self, const oket_at *at,
                        const char *args, size_t args_len) {
    oket_list *l = oket_list_of(at);
    char root[PATH_CAP];

    if (l == NULL) {
        return refuse(api, self, "fs.root: this document is not the files list");
    }
    if (!arg_path(args, args_len, root, sizeof root) || !is_dir(root)) {
        return refuse(api, self, "fs.root <path>, and it has to be a directory");
    }
    reroot(api, self, l, at, root, NULL);
    return 0;
}

OKET_MAIN {
    /* `files` is the name the kernel already aims at (kinds.odin): `:open` on a directory,
     * `alt+f`'s `:ring files`, and the `[files]` bind section all reach whoever registers it,
     * so this becomes what a directory opens as with no new wiring. */
    static const oket_kind_spec SPEC = {
        LIT("files"),
        LIT("surface"),
        {open_browser, close_browser, oket_list_event},
    };

    FILES = api->register_kind(api, self, &SPEC);
    if (FILES == 0) {
        return 1;
    }
    /* The typing, the erase pair, the filter and esc are the list core's: fs.erase on
     * backspace, fs.erase.fwd for del, fs.filter on ctrl+f, fs.clear on esc. */
    oket_list_register(api, self, &LSPEC, FILES);
    api->register_command(api, self, LIT("fs.enter"),
                          LIT("visit the directory, and stop the chain if it was one"), enter_cmd);
    api->register_command(api, self, LIT("fs.up"),
                          LIT("close this subtree, or visit the directory above"), up_cmd);
    api->register_command(api, self, LIT("fs.into"), LIT("visit the directory under point"),
                          into_cmd);
    api->register_command(api, self, LIT("fs.up.row"),
                          LIT("one row up, caret at the end of its name"), up_row_cmd);
    api->register_command(api, self, LIT("fs.down.row"),
                          LIT("one row down, caret at the end of its name"), down_row_cmd);
    api->register_command(api, self, LIT("fs.snap"),
                          LIT("caret back to the end of this row's name"), snap_cmd);
    api->register_command(api, self, LIT("fs.toggle"),
                          LIT("open or close the subtree under the row, in place"), toggle_cmd);
    api->register_command(api, self, LIT("fs.commit"),
                          LIT("rename every row whose name has been typed over"), commit_cmd);
    api->register_command(api, self, LIT("fs.reload"),
                          LIT("read the directory again, dropping names typed and not committed"),
                          reload_cmd);
    api->register_command(api, self, LIT("fs.hidden"), LIT("show or hide dotfiles"), hidden_cmd);
    api->register_command(api, self, LIT("fs.root"), LIT("move the listing to another directory"),
                          root_cmd);
    /* ASKED FOR, never claimed (§8). Every one shadows something wider — `enter` the
     * surface-tier `:open <path>`, the vertical arrows the kernel's own motion — and the
     * writeback says so above each row, so what the browser took is readable in the file rather
     * than known.
     *
     * TWO ARROWS, not four: up and down land on a name, and LEFT AND RIGHT ARE NOT ASKED FOR,
     * so they stay the kernel's `nav.left`/`nav.right` and move the caret inside the row being
     * renamed. The hierarchy is on `enter` (a directory is visited) and on `ctrl+backspace` (out
     * of one), with the `..` row as the way up that needs no chord at all. */
    api->request_bind(api, self, LIT("files"), LIT("enter"),
                      LIT("exec :fs.enter <path> && :open <path>"));
    /* Out, and it shadows nothing: `edit.delete_word_back` is written for the `text` context and
     * a listing is a surface. Backspace erases inside a name, so the modified one leaving the
     * directory reads the same way round. */
    api->request_bind(api, self, LIT("files"), LIT("ctrl+backspace"), LIT("fs.up"));
    /* DOUBLE click, not single: a single one moves point and `fs.snap` lands it on the name, so
     * clicking into a row to rename it does not also take you somewhere. */
    api->request_bind(api, self, LIT("files"), LIT("double-click"),
                      LIT("exec :fs.enter <path> && :open <path>"));
    api->request_bind(api, self, LIT("files"), LIT("click"), LIT("fs.snap"));
    api->request_bind(api, self, LIT("files"), LIT("up"), LIT("fs.up.row"));
    api->request_bind(api, self, LIT("files"), LIT("down"), LIT("fs.down.row"));
    api->request_bind(api, self, LIT("files"), LIT("del"), LIT("fs.erase.fwd"));
    api->request_bind(api, self, LIT("files"), LIT("ctrl+@AC02"), LIT("exec :fs.commit"));
    api->request_bind(api, self, LIT("files"), LIT("f5"), LIT("exec :fs.reload"));
    api->request_bind(api, self, LIT("files"), LIT("ctrl+@AB05"), LIT("exec :fs.hidden"));
    return 0;
}
