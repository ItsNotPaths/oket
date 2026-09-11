/* A list of rows (the browser/picker core): the filter, the publish scaffold, and the clamped
 * typing/erase machinery the file browser, the theme picker and the grammar list share.
 *
 * Plugin-level statics: every plugin links its own copy of this file, so this is per-plugin
 * state and one spec is one plugin's list kind. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

static const oket_list_spec *LIST_SPEC;
static oket_kind             LIST_KIND;
static oket_list            *LISTS;

/* The verb names, built once from the prefix and alive for as long as the commands are. */
static char LIST_FILTER_CMD[48], LIST_ERASE_CMD[48], LIST_ERASE_FWD_CMD[56], LIST_CLEAR_CMD[48];

static size_t list_first(void) {
    return 1 + (LIST_SPEC != NULL && LIST_SPEC->head != NULL ? 1 : 0);
}

static size_t list_clamp(size_t v, size_t lo, size_t hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

oket_list *oket_list_open(const oket_api *api, oket_self self, oket_doc doc, void *ctx) {
    oket_list *l;

    (void)api;
    (void)self;
    if (LIST_SPEC == NULL) {
        return NULL;
    }
    l = calloc(1, sizeof *l);
    if (l == NULL) {
        return NULL;
    }
    l->doc = doc;
    l->ctx = ctx;
    l->next = LISTS;
    LISTS = l;
    return l;
}

void oket_list_close(oket_list *l) {
    oket_list **at;

    if (l == NULL) {
        return;
    }
    for (at = &LISTS; *at != NULL; at = &(*at)->next) {
        if (*at == l) {
            *at = l->next;
            break;
        }
    }
    free(l->rows);
    free(l);
}

oket_list *oket_list_of(const oket_at *at) {
    oket_list *l;

    for (l = LISTS; l != NULL; l = l->next) {
        if (l == at->inst) {
            return l;
        }
    }
    return NULL;
}

const oket_list_row *oket_list_at(const oket_list *l, size_t line) {
    size_t first = list_first();

    if (line < first || line - first >= l->nrows) {
        return NULL;
    }
    return &l->rows[line - first];
}

ptrdiff_t oket_list_row_line(const oket_list *l, int32_t idx) {
    size_t i;

    for (i = 0; i < l->nrows; i++) {
        if (l->rows[i].idx == idx) {
            return (ptrdiff_t)(list_first() + i);
        }
    }
    return -1;
}

size_t oket_list_line(const oket_snapshot *s) {
    size_t lo, hi;

    if (s == NULL || s->ncursors == 0) {
        return 0;
    }
    oket_cursor_span(s, s->primary, &lo, &hi);
    return oket_line_at(s, lo);
}

void oket_list_name_span(const oket_snapshot *s, const oket_list *l, size_t line,
                         size_t *lo, size_t *hi) {
    const oket_list_row *r = oket_list_at(l, line);
    size_t start, end;

    oket_line_range(s, line, &start, &end);
    *lo = *hi = end;
    if (r == NULL) {
        return;
    }
    *lo = start + (size_t)r->name_off;
    if (*lo > end) {
        *lo = end; /* the prefix is gone: not a row a name can be read out of */
    }
    *hi = end;
    if (r->tail > 0 && *hi >= *lo + r->tail) {
        *hi -= r->tail; /* a directory's slash is punctuation, not part of its name */
    }
    if (*hi < *lo) {
        *hi = *lo;
    }
}

size_t oket_list_name(const oket_snapshot *s, const oket_list *l, size_t line,
                      char *dst, size_t cap) {
    size_t lo, hi;

    oket_list_name_span(s, l, line, &lo, &hi);
    return oket_copy(s, lo, hi, dst, cap);
}

void oket_list_publish(const oket_api *api, oket_self self, oket_list *l) {
    const oket_list_spec *sp = LIST_SPEC;
    oket_descriptor d;
    oket_build out;
    char head[512];
    int32_t i, n, shown = 0;

    if (sp == NULL) {
        return;
    }
    n = sp->count(l->ctx);
    for (i = 0; i < n; i++) {
        shown += sp->match(l->ctx, i, l->filter, l->nfilter) ? 1 : 0;
    }
    memset(&out, 0, sizeof out);
    {
        char filt[OKET_LIST_FILTER_CAP + 2];
        size_t flen = 0;
        if (l->filtering) {
            filt[0] = '/';
            memcpy(filt + 1, l->filter, l->nfilter);
            flen = 1 + l->nfilter;
        }
        oket_build_cell(&out, "filter", filt, flen);
        oket_build_row(&out);
    }
    if (sp->head != NULL) {
        size_t hn = sp->head(l->ctx, head, sizeof head, l, shown);

        if (hn >= sizeof head) {
            hn = sizeof head - 1;
        }
        oket_build_cell(&out, "head", head, hn);
        oket_build_row(&out);
    }
    l->nrows = 0;
    for (i = 0; i < n; i++) {
        oket_list_row *r;

        if (!sp->match(l->ctx, i, l->filter, l->nfilter)) {
            continue;
        }
        if (l->nrows == l->rows_cap) {
            size_t cap = l->rows_cap ? l->rows_cap * 2 : 64;
            oket_list_row *grown = realloc(l->rows, cap * sizeof *grown);

            if (grown == NULL) {
                break;
            }
            l->rows = grown;
            l->rows_cap = cap;
        }
        r = &l->rows[l->nrows];
        memset(r, 0, sizeof *r);
        r->idx = i;
        sp->row(l->ctx, &out, r, i);
        oket_build_row(&out);
        l->nrows++;
    }

    memset(&d, 0, sizeof d);
    d.kind = LIST_KIND;
    d.render = OKET_RENDER_TEXT;
    d.selection = sp->selection;
    d.input = OKET_INPUT_BOUND;
    d.editable = 1; /* what makes a typed rune reach the plugin at all */
    d.tab_width = sp->tab_width;
    if (l->file != NULL) {
        d.file = l->file;
        d.file_len = strlen(l->file);
    }
    oket_build_desc(&out, &d);
    /* Minus the row terminator the last row wrote: a document does not end in a blank line. */
    oket_regen(api, self, l->doc, out.text, out.len > 0 ? out.len - 1 : 0, &d);
    oket_build_free(&out);
}

void oket_list_repaint(const oket_api *api, oket_self self) {
    oket_list *l;

    for (l = LISTS; l != NULL; l = l->next) {
        oket_list_publish(api, self, l);
    }
}

void oket_list_point(const oket_api *api, oket_self self, oket_list *l, size_t line) {
    size_t first = list_first();
    oket_cursor c;

    memset(&c, 0, sizeof c);
    if (l->nrows == 0) {
        line = 0;
    } else {
        line = list_clamp(line, first, first + l->nrows - 1);
    }
    c.head.line = (ptrdiff_t)line;
    if (LIST_SPEC != NULL && LIST_SPEC->pin && l->nrows > 0) {
        const oket_list_row *r = &l->rows[line - first];

        c.head.col = r->name_off + r->name_len;
    }
    c.anchor = c.head;
    c.goal = -1; /* the kernel computes the cell column */
    api->cursors(api, self, l->doc, &c, 1, 0);
}

void oket_list_refilter(const oket_api *api, oket_self self, oket_list *l) {
    size_t i, line;

    oket_list_publish(api, self, l);
    /* The first row a filter can MEAN: not `..`, whose fixed row matches every filter and
     * whose path would send enter up instead of into the match. A list of only fixed rows
     * (a picker) points at the first as before. */
    line = list_first();
    for (i = 0; i < l->nrows; i++) {
        if (!l->rows[i].fixed) {
            line = list_first() + i;
            break;
        }
    }
    oket_list_point(api, self, l, line);
}

static void list_feedback(const oket_api *api, oket_self self, oket_list *l) {
    (void)api;
    (void)self;
    (void)l;
}

static void list_filter_changed(const oket_api *api, oket_self self, oket_list *l) {
    if (LIST_SPEC->filtered != NULL) {
        LIST_SPEC->filtered(l->ctx);
    }
    oket_list_refilter(api, self, l);
    list_feedback(api, self, l);
}

int32_t oket_list_event(const oket_api *api, oket_self self, const oket_at *at,
                        oket_event ev, const char *text, size_t len) {
    const oket_snapshot *s = at->snap;
    oket_list *l = oket_list_of(at);
    oket_batch batch;
    size_t i;
    int sent;

    if (l == NULL || ev != OKET_EVENT_TEXT || s == NULL || len == 0) {
        return 0;
    }
    if (l->filtering) {
        if (l->nfilter + len >= sizeof l->filter) {
            return 0;
        }
        memcpy(l->filter + l->nfilter, text, len);
        l->nfilter += len;
        l->filter[l->nfilter] = 0;
        list_filter_changed(api, self, l);
        return 1;
    }
    /* Self-insert, CLAMPED INTO THE NAME, so nothing left of it is writable and a fixed row
     * takes nothing at all. No REGEN flag: a typed rune is exactly the case whose caret must
     * follow the splice. */
    memset(&batch, 0, sizeof batch);
    for (i = 0; i < s->ncursors; i++) {
        size_t lo, hi, nlo, nhi, line;
        const oket_list_row *r;

        oket_cursor_span(s, i, &lo, &hi);
        line = oket_line_at(s, lo);
        r = oket_list_at(l, line);
        if (r == NULL || r->fixed) {
            continue;
        }
        oket_list_name_span(s, l, line, &nlo, &nhi);
        lo = list_clamp(lo, nlo, nhi);
        hi = list_clamp(hi, lo, nhi);
        oket_batch_edit(&batch, lo, hi, text, len);
    }
    sent = oket_batch_submit(api, self, s->doc, s->gen, &batch);
    oket_batch_free(&batch);
    return sent;
}

/* Backspace and Delete in a name, clamped like typing: a row cannot be spliced into the one
 * above, and the prefix left of the name cannot be eaten. */
static int32_t list_erase(const oket_api *api, oket_self self, const oket_at *at, int forward) {
    const oket_snapshot *s = at->snap;
    oket_list *l = at->inst;
    oket_batch batch;
    size_t i;
    int sent;

    memset(&batch, 0, sizeof batch);
    for (i = 0; i < s->ncursors; i++) {
        size_t lo, hi, nlo, nhi, line, col, step_len, len;
        char text[1024];
        uint32_t r;
        const oket_list_row *row = NULL;

        oket_cursor_span(s, i, &lo, &hi);
        line = oket_line_at(s, lo);
        row = oket_list_at(l, line);
        if (row == NULL || row->fixed) {
            continue;
        }
        oket_list_name_span(s, l, line, &nlo, &nhi);
        if (lo != hi) { /* a selection: whatever of it lies inside the name */
            lo = list_clamp(lo, nlo, nhi);
            hi = list_clamp(hi, lo, nhi);
            if (lo < hi) {
                oket_batch_edit(&batch, lo, hi, "", 0);
            }
            continue;
        }
        lo = list_clamp(lo, nlo, nhi);
        len = oket_line_copy(s, line, text, sizeof text);
        col = lo - oket_line_start(s, line);
        if (col > len) {
            continue; /* the line outgrew the copy: no rune to measure there */
        }
        if (forward) {
            if (lo >= nhi) {
                continue; /* the name ends here, and the row does not go on being one */
            }
            step_len = oket_utf8_next(text + col, len - col, &r);
            oket_batch_edit(&batch, lo, lo + step_len, "", 0);
        } else {
            if (lo <= nlo) {
                continue;
            }
            step_len = oket_utf8_prev(text, col, &r);
            oket_batch_edit(&batch, lo - step_len, lo, "", 0);
        }
    }
    sent = oket_batch_submit(api, self, s->doc, s->gen, &batch);
    oket_batch_free(&batch);
    return sent ? 0 : 1;
}

static oket_list *list_mine(const oket_api *api, oket_self self, const oket_at *at,
                            const char *verb) {
    oket_list *l = oket_list_of(at);

    if (l == NULL || at->snap == NULL) {
        char msg[96];

        snprintf(msg, sizeof msg, "%s: this document is not the %s list", verb,
                 LIST_SPEC != NULL ? LIST_SPEC->name : "?");
        oket_say(api, self, msg);
        return NULL;
    }
    return l;
}

static int32_t list_filter_cmd(const oket_api *api, oket_self self, const oket_at *at,
                               const char *args, size_t args_len) {
    oket_list *l = list_mine(api, self, at, LIST_FILTER_CMD);

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return 1;
    }
    if (!l->filtering) {
        l->filtering = 1;
        oket_list_publish(api, self, l);
    }
    return 0;
}

static int32_t list_erase_dir(const oket_api *api, oket_self self, const oket_at *at,
                              const char *verb, int forward) {
    oket_list *l = list_mine(api, self, at, verb);
    uint32_t r;

    if (l == NULL) {
        return 1;
    }
    if (l->filtering) {
        l->nfilter -= oket_utf8_prev(l->filter, l->nfilter, &r);
        l->filter[l->nfilter] = 0;
        list_filter_changed(api, self, l);
        return 0;
    }
    return list_erase(api, self, at, forward);
}

static int32_t list_erase_cmd(const oket_api *api, oket_self self, const oket_at *at,
                              const char *args, size_t args_len) {
    (void)args;
    (void)args_len;
    return list_erase_dir(api, self, at, LIST_ERASE_CMD, 0);
}

static int32_t list_erase_fwd_cmd(const oket_api *api, oket_self self, const oket_at *at,
                                  const char *args, size_t args_len) {
    (void)args;
    (void)args_len;
    return list_erase_dir(api, self, at, LIST_ERASE_FWD_CMD, 1);
}

static int32_t list_clear_cmd(const oket_api *api, oket_self self, const oket_at *at,
                              const char *args, size_t args_len) {
    oket_list *l = list_mine(api, self, at, LIST_CLEAR_CMD);

    (void)args;
    (void)args_len;
    if (l == NULL) {
        return 1;
    }
    l->nfilter = 0;
    l->filter[0] = 0;
    l->filtering = 0;
    list_filter_changed(api, self, l);
    return 0;
}

void oket_list_register(const oket_api *api, oket_self self, const oket_list_spec *spec,
                        oket_kind kind) {
    LIST_SPEC = spec;
    LIST_KIND = kind;
    snprintf(LIST_FILTER_CMD, sizeof LIST_FILTER_CMD, "%s.filter", spec->prefix);
    snprintf(LIST_ERASE_CMD, sizeof LIST_ERASE_CMD, "%s.erase", spec->prefix);
    snprintf(LIST_ERASE_FWD_CMD, sizeof LIST_ERASE_FWD_CMD, "%s.erase.fwd", spec->prefix);
    snprintf(LIST_CLEAR_CMD, sizeof LIST_CLEAR_CMD, "%s.clear", spec->prefix);
    api->register_command(api, self, LIST_FILTER_CMD, strlen(LIST_FILTER_CMD),
                          LIT("typed runes go to the filter until esc"), list_filter_cmd);
    api->register_command(api, self, LIST_ERASE_CMD, strlen(LIST_ERASE_CMD),
                          LIT("one rune off the filter, or back in the name"), list_erase_cmd);
    api->register_command(api, self, LIST_ERASE_FWD_CMD, strlen(LIST_ERASE_FWD_CMD),
                          LIT("delete forward, stopping at the end of the name"),
                          list_erase_fwd_cmd);
    api->register_command(api, self, LIST_CLEAR_CMD, strlen(LIST_CLEAR_CMD),
                          LIT("clear the filter and leave it"), list_clear_cmd);
    /* ASKED FOR, never claimed (§8). ctrl+f is `ctrl+@AC04` in the physical spelling, and esc
     * shadows quit for this kind — the writeback says so where it can be taken back. */
    api->request_bind(api, self, spec->name, strlen(spec->name), LIT("ctrl+@AC04"),
                      LIST_FILTER_CMD, strlen(LIST_FILTER_CMD));
    api->request_bind(api, self, spec->name, strlen(spec->name), LIT("backspace"),
                      LIST_ERASE_CMD, strlen(LIST_ERASE_CMD));
    api->request_bind(api, self, spec->name, strlen(spec->name), LIT("esc"),
                      LIST_CLEAR_CMD, strlen(LIST_CLEAR_CMD));
}
