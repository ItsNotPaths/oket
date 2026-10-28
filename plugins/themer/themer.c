/* The theme picker, as a document (§5, §11): every helix theme, the ones on disk and the ones
 * one curl away, one row each. The list scaffold — the ctrl+f filter, the publish, the shared
 * verbs — is the helper library's list core; what is this file's is the platter scan, the
 * manifest, and the chains. Selecting STAGES a chain in the command line rather than acting:
 *
 *     [themer]
 *     enter = stage $o_act                                    the switch, pulling the file first
 *     del   = stage :th.rm $o_name && :set theme.name gruvbox  a pulled one removed
 *
 * `act` is a VALUE the row never draws, built here where the state is known, so the staged line
 * is the whole policy: you read it, edit it, or hit enter. Provenance is the manifest
 * (`.themer` — names the staged pulls append), never a name-match against the repo, so
 * `th.rm` refuses a hand-made file that shares a repo name.
 *
 * THE REPO LIST IS FETCHED, NOT VENDORED: the grammar registry earns its header by carrying
 * repo, rev and subpath per language; this list is a directory listing, one curl away. It lands
 * in a cache beside the themes (`.list`, the shell does the JSON scraping), fetched when the
 * cache is absent and on `:th.pull`. Offline the cache answers, or the list is what is
 * installed.
 *
 *     :ring themer     the list (alt+t)
 *     ctrl+f           filters; backspace and esc take it back off
 */
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

#define API_URL "https://api.github.com/repos/helix-editor/helix/contents/runtime/themes"
#define RAW_URL "https://raw.githubusercontent.com/helix-editor/helix/master/runtime/themes"
#define THEME_DEFAULT "gruvbox"

#define NAME_CAP 64
#define PATH_CAP 512
#define ACT_CAP 1024
#define LINE_CAP 256
#define NAME_W 34
#define MAX_THEMES 512

static lues_kind THEMER;

/* Where the themes live: `$OKET_DATA/themes`, or wherever `:th.dir` pointed — the same seam
 * `:grammar dir` gives the syntax gate, because a test cannot set this process's environment. */
static char ROOT[PATH_CAP];

/* --- what there is --- */

/* One state, not two flags: PULLED implies a file on disk, so "pulled but not here" cannot be
 * spelled. */
enum { AWAY, HERE, PULLED };

typedef struct {
    char name[NAME_CAP];
    unsigned char state;
} theme_row;

static theme_row THEMES[MAX_THEMES];
static int NTHEMES, NHERE;

static int is_here(const theme_row *r) {
    return r->state != AWAY;
}

/* A name is bytes inside a shell chain and a sed pattern: only these runes get a row at all. */
static int name_ok(const char *name) {
    static const char safe[] = "abcdefghijklmnopqrstuvwxyz"
                               "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-";

    return name[0] != 0 && name[strspn(name, safe)] == 0;
}

static theme_row *row_named(const char *name) {
    int i;

    for (i = 0; i < NTHEMES; i++) {
        if (strcmp(THEMES[i].name, name) == 0) {
            return &THEMES[i];
        }
    }
    return NULL;
}

static void row_add(const char *name, int here) {
    theme_row *r = row_named(name);

    if (r == NULL) {
        if (NTHEMES >= MAX_THEMES || !name_ok(name) || strlen(name) >= NAME_CAP) {
            return;
        }
        r = &THEMES[NTHEMES++];
        memset(r, 0, sizeof *r);
        snprintf(r->name, sizeof r->name, "%s", name);
    }
    if (here && r->state == AWAY) {
        r->state = HERE;
    }
}

/* Every line of `<dir>/<file>`, handed to `take`. Lines past the caps are dropped whole. */
static void file_lines(const char *file, void (*take)(const char *)) {
    char path[PATH_CAP + 16], line[NAME_CAP];
    FILE *f;

    snprintf(path, sizeof path, "%s/%s", ROOT, file);
    f = fopen(path, "r");
    if (f == NULL) {
        return;
    }
    while (fgets(line, sizeof line, f)) {
        if (strchr(line, '\n') == NULL && !feof(f)) {
            int c;

            do {
                c = fgetc(f);
            } while (c != EOF && c != '\n');
            continue;
        }
        line[strcspn(line, "\n")] = 0;
        take(line);
    }
    fclose(f);
}

static void take_listed(const char *name) {
    row_add(name, 0);
}

/* A manifest line whose file is gone is stale, and stale marks nothing: PULLED is what makes
 * a row removable, and removable must mean the file is there to remove. */
static void take_pulled(const char *name) {
    theme_row *r = row_named(name);

    if (r != NULL && r->state == HERE) {
        r->state = PULLED;
    }
}

static int by_here_then_name(const void *x, const void *y) {
    const theme_row *a = x, *b = y;

    if (is_here(a) != is_here(b)) {
        return is_here(b) - is_here(a);
    }
    return strcmp(a->name, b->name);
}

static void scan(void) {
    DIR *d;
    struct dirent *e;
    int i;

    NTHEMES = 0;
    if (ROOT[0] == 0) {
        NHERE = 0;
        return;
    }
    d = opendir(ROOT);
    if (d != NULL) {
        while ((e = readdir(d)) != NULL) {
            char name[NAME_CAP];
            size_t n = strlen(e->d_name);

            if (n <= 5 || n - 5 >= sizeof name || strcmp(e->d_name + n - 5, ".toml") != 0) {
                continue;
            }
            memcpy(name, e->d_name, n - 5);
            name[n - 5] = 0;
            row_add(name, 1);
        }
        closedir(d);
    }
    file_lines(".themer", take_pulled);
    file_lines(".list", take_listed);
    qsort(THEMES, (size_t)NTHEMES, sizeof THEMES[0], by_here_then_name);
    NHERE = 0;
    for (i = 0; i < NTHEMES; i++) {
        NHERE += is_here(&THEMES[i]);
    }
}

static int cache_present(void) {
    char path[PATH_CAP + 16];
    FILE *f;

    snprintf(path, sizeof path, "%s/.list", ROOT);
    f = fopen(path, "r");
    if (f != NULL) {
        fclose(f);
        return 1;
    }
    return 0;
}

/* The repo listing into the cache, atomically: the shell scrapes the JSON, so no line of it is
 * ever parsed here, and a curl that fails leaves whatever cache there was. The doc routes the
 * exit back to `event` (§9). */
static void fetch(const lues_api *api, lues_self self, lues_doc doc) {
    static char cmd[PATH_CAP * 3 + 256];
    const char *argv[3] = {"sh", "-c", cmd};

    snprintf(cmd, sizeof cmd,
             "curl -fsSL '" API_URL "'"
             " | sed -n 's/.*\"name\": \"\\(.*\\)\\.toml\".*/\\1/p' > '%s/.list.tmp'"
             " && mv '%s/.list.tmp' '%s/.list'",
             ROOT, ROOT, ROOT);
    api->io_spawn(api, self, doc, argv, 3, NULL, 0);
}

/* --- the rows, through the list core --- */

/* A value is BORROWED until the submit (oket_helpers.h), so a chain cannot live on t_row's
 * stack: it lives in its row's slot. */
static char ACTS[MAX_THEMES][ACT_CAP];

/* One row: `name` for the eye and for `th.rm`, and `act`, the chain `enter` stages: a row that
 * is not here pulls its file, writes the manifest and switches, all in the one line the user is
 * shown. */
static void t_row(void *ctx, oket_build *out, oket_list_row *lr, int32_t idx) {
    const theme_row *r = &THEMES[idx];
    char text[LINE_CAP], *act = ACTS[idx];
    size_t n, name_lo = 2, name_hi = name_lo + strlen(r->name);

    (void)ctx;
    n = (size_t)snprintf(text, sizeof text, "%s %-*s%s", is_here(r) ? "*" : " ", NAME_W, r->name,
                         r->state == PULLED ? "pulled" : "");
    if (n >= sizeof text) {
        n = sizeof text - 1;
    }
    if (is_here(r)) {
        snprintf(act, ACT_CAP, ":set theme.name %s", r->name);
    } else {
        snprintf(act, ACT_CAP,
                 "curl -fsSL '" RAW_URL "/%s.toml' -o '%s/%s.toml'"
                 " && echo %s >> '%s/.themer'"
                 " && :set theme.name %s && :th.done",
                 r->name, ROOT, r->name, r->name, ROOT, r->name);
    }
    lr->fixed = 1; /* a row you stage, never one you rename */
    oket_build_cell(out, "row", text, n);
    oket_build_span(out, "name", name_lo, name_hi);
    oket_build_value(out, "act", name_lo, name_hi, act, strlen(act));
}

static int32_t t_count(void *ctx) {
    (void)ctx;
    return NTHEMES;
}

static int t_match(void *ctx, int32_t i, const char *filter, size_t n) {
    (void)ctx;
    return n == 0 || strstr(THEMES[i].name, filter) != NULL;
}

static size_t t_head(void *ctx, char *out, size_t cap, const oket_list *l, int32_t shown) {
    int n;

    (void)ctx;
    if (l->filtering || l->nfilter > 0) {
        n = snprintf(out, cap, "themes   %d here of %d   /%.*s   %d shown; esc clears",
                     NHERE, NTHEMES, (int)l->nfilter, l->filter, shown);
    } else {
        n = snprintf(out, cap,
                     "themes   %d here of %d   ctrl+f filters; enter stages the switch;"
                     " del removes a pulled one",
                     NHERE, NTHEMES);
    }
    return n < 0 ? 0 : (size_t)n;
}

static const oket_list_spec LSPEC = {
    "themer", "th", OKET_SELECT_LINE, 0, 4,
    t_count, t_match, t_row, t_head, NULL,
};

static void rescan(const lues_api *api, lues_self self) {
    scan();
    oket_list_repaint(api, self);
}

/* --- the six messages --- */

static void *open_list(const lues_api *api, lues_self self, lues_doc doc, const char *args,
                       size_t args_len) {
    oket_list *l = oket_list_open(api, self, doc, NULL);

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return NULL;
    }
    scan();
    oket_list_publish(api, self, l);
    oket_list_point(api, self, l, 2);
    if (ROOT[0] != 0 && !cache_present()) {
        fetch(api, self, doc);
    }
    return l;
}

static void close_list(const lues_api *api, lues_self self, lues_doc doc, void *inst) {
    (void)api;
    (void)self;
    (void)doc;
    oket_list_close(inst);
}

static int32_t event(const lues_api *api, lues_self self, const lues_at *at, lues_event ev,
                     const char *text, size_t len) {
    /* The fetch coming home: the cache moved, or curl said no and it did not. Either way the
     * platter is the answer, so a rescan is the whole of the handling. */
    if (ev == LUES_EVENT_IO_END) {
        rescan(api, self);
        return 0;
    }
    return oket_list_event(api, self, at, ev, text, len);
}

/* --- the verbs --- */

/* A staged chain's last step: the platter moved under every open list, so they say so. */
static int32_t done_cmd(const lues_api *api, lues_self self, const lues_at *at,
                        const char *args, size_t args_len) {
    (void)at;
    (void)args;
    (void)args_len;
    rescan(api, self);
    return 0;
}

/* The manifest is the PULLED rows, so it is written from them rather than edited. */
static void manifest_write(void) {
    char path[PATH_CAP + 16];
    FILE *f;
    int i;

    snprintf(path, sizeof path, "%s/.themer", ROOT);
    f = fopen(path, "w");
    if (f == NULL) {
        return;
    }
    for (i = 0; i < NTHEMES; i++) {
        if (THEMES[i].state == PULLED) {
            fprintf(f, "%s\n", THEMES[i].name);
        }
    }
    fclose(f);
}

/* `th.rm <name>`: a pulled theme's file and its manifest line. A hand-made file is not this
 * list's to remove. */
static int32_t rm_cmd(const lues_api *api, lues_self self, const lues_at *at,
                      const char *args, size_t args_len) {
    char name[NAME_CAP], path[PATH_CAP + NAME_CAP + 8], msg[NAME_CAP + 48];
    theme_row *r;

    (void)at;
    if (args_len == 0 || args_len >= sizeof name) {
        oket_say(api, self, "usage: :th.rm <name>");
        return 1;
    }
    memcpy(name, args, args_len);
    name[args_len] = 0;
    scan();
    r = row_named(name);
    if (r == NULL || r->state != PULLED) {
        snprintf(msg, sizeof msg, "th.rm: %s was not pulled here", name);
        oket_say(api, self, msg);
        return 1;
    }
    snprintf(path, sizeof path, "%s/%s.toml", ROOT, name);
    if (remove(path) != 0) {
        snprintf(msg, sizeof msg, "th.rm: cannot remove %s.toml", name);
        oket_say(api, self, msg);
        return 1;
    }
    r->state = AWAY;
    manifest_write();
    rescan(api, self);
    return 0;
}

static int32_t pull_cmd(const lues_api *api, lues_self self, const lues_at *at,
                        const char *args, size_t args_len) {
    (void)args;
    (void)args_len;
    if (oket_list_of(at) == NULL) {
        oket_say(api, self, "th.pull: this document is not the theme list");
        return 1;
    }
    if (ROOT[0] == 0) {
        oket_say(api, self, "th.pull: no themes directory; :th.dir <path> names one");
        return 1;
    }
    fetch(api, self, at->doc);
    return 0;
}

static int32_t dir_cmd(const lues_api *api, lues_self self, const lues_at *at,
                       const char *args, size_t args_len) {
    char msg[PATH_CAP + 32];

    (void)at;
    if (args_len == 0) {
        snprintf(msg, sizeof msg, "th.dir: %s", ROOT[0] ? ROOT : "(unset)");
        oket_say(api, self, msg);
        return 0;
    }
    if (args_len >= sizeof ROOT) {
        oket_say(api, self, "th.dir: path too long");
        return 1;
    }
    memcpy(ROOT, args, args_len);
    ROOT[args_len] = 0;
    rescan(api, self);
    return 0;
}

LUES_MAIN {
    static const lues_kind_spec SPEC = {
        sizeof(lues_kind_spec),
        LIT("themer"),
        LIT("surface"),
        {open_list, close_list, event},
    };
    const char *data = getenv("OKET_DATA");

    if (data != NULL && data[0] != 0) {
        snprintf(ROOT, sizeof ROOT, "%s/themes", data);
    }
    THEMER = api->register_kind(api, self, &SPEC);
    if (THEMER == 0) {
        return 1;
    }
    /* th.filter on ctrl+f, th.erase on backspace, th.clear on esc: the list core's rows. */
    oket_list_register(api, self, &LSPEC, THEMER);
    api->register_command(api, self, LIT("th.done"), LIT("re-read the themes directory"),
                          done_cmd);
    api->register_command(api, self, LIT("th.pull"), LIT("refresh the repo list"), pull_cmd);
    api->register_command(api, self, LIT("th.rm"), LIT("remove a pulled theme"), rm_cmd);
    api->register_command(api, self, LIT("th.dir"), LIT("where the themes live; no argument asks"),
                          dir_cmd);
    api->request_bind(api, self, LIT("global"), LIT("alt+@AD05"), LIT(":ring themer"));
    api->request_bind(api, self, LIT("themer"), LIT("enter"), LIT(":stage $o_act"));
    api->request_bind(api, self, LIT("themer"), LIT("del"),
                      LIT(":stage :th.rm $o_name && :set theme.name " THEME_DEFAULT));
    return 0;
}
