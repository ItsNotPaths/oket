/* Writing: the descriptor builder, whole-document sets, batches, span publishes and the view
 * stage fill. One growth policy (`grow`) serves all the builders here. */
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

/* --- the descriptor builder --- */

/* One growth policy for all three arrays. `oom` latches: a builder that failed once keeps
 * failing, so a caller checks it at the end rather than after every append. */
static int grow(int *oom, void **arr, size_t *cap, size_t need, size_t item) {
    size_t want = *cap ? *cap : 16;
    void *bigger;

    if (*oom) {
        return 0;
    }
    if (need <= *cap) {
        return 1;
    }
    while (want < need) {
        want *= 2;
    }
    bigger = realloc(*arr, want * item);
    if (bigger == NULL) {
        *oom = 1;
        return 0;
    }
    *arr = bigger;
    *cap = want;
    return 1;
}

static void put(oket_build *b, const char *s, size_t len) {
    if (!grow(&b->oom, (void **)&b->text, &b->cap, b->len + len, 1)) {
        return;
    }
    memcpy(b->text + b->len, s, len);
    b->len += len;
}

void oket_build_column(oket_build *b, const char *name, int32_t width, oket_align align) {
    oket_column *c;

    if (!grow(&b->oom, (void **)&b->columns, &b->columns_cap, b->ncolumns + 1, sizeof *b->columns)) {
        return;
    }
    c = &b->columns[b->ncolumns++];
    c->name = name;
    c->name_len = strlen(name);
    c->width = width;
    c->align = (uint8_t)align;
    memset(c->_pad, 0, sizeof c->_pad);
}

void oket_build_span(oket_build *b, const char *name, size_t lo, size_t hi) {
    lues_span *sp;

    if (!grow(&b->oom, (void **)&b->spans, &b->spans_cap, b->nspans + 1, sizeof *b->spans) ||
        !grow(&b->oom, (void **)&b->names, &b->names_cap, b->nspans + 1, sizeof *b->names)) {
        return;
    }
    b->names[b->nspans] = name;
    sp = &b->spans[b->nspans++];
    memset(sp, 0, sizeof *sp);
    sp->size = sizeof *sp;
    /* Cell-relative in, document-relative out. text NULL: the span's own bytes are its value. */
    sp->lo = b->row_start + b->cell_start + lo;
    sp->hi = b->row_start + b->cell_start + hi;
    sp->open = 1; /* text typed at either end of a name is part of it */
}

void oket_build_link(oket_build *b, const char *name, size_t lo, size_t hi,
                     const char *value, size_t value_len) {
    oket_build_span(b, name, lo, hi);
    if (b->nspans > 0 && value != NULL) {
        b->spans[b->nspans - 1].text = value;
        b->spans[b->nspans - 1].text_len = value_len;
    }
}

void oket_build_cell(oket_build *b, const char *name, const char *text, size_t len) {
    if (b->len > b->row_start) {
        put(b, "\t", 1);
    }
    b->cell_start = b->len - b->row_start;
    put(b, text, len);
    oket_build_span(b, name, 0, len);
}

void oket_build_depth(oket_build *b, int32_t depth) {
    size_t want = (size_t)b->line + 1;

    if (!grow(&b->oom, (void **)&b->depth, &b->depth_cap, want, sizeof *b->depth)) {
        return;
    }
    /* Dense and in line order, so a row that says nothing leaves a zero behind it. */
    while (b->ndepth < want) {
        b->depth[b->ndepth++] = 0;
    }
    b->depth[b->line] = depth;
}

void oket_build_row(oket_build *b) {
    put(b, "\n", 1);
    b->line++;
    b->row_start = b->len;
    b->cell_start = 0;
}

static void set(const lues_api *api, lues_self self, lues_doc doc, const char *text, size_t len,
                const oket_descriptor *d, const lues_span_pub *pub, uint32_t flags);

void oket_build_submit(const lues_api *api, lues_self self, lues_doc doc, oket_build *b,
                       size_t len, oket_descriptor *d, uint32_t flags) {
    lues_span_pub pub;
    size_t i;

    d->columns = b->columns;
    d->ncolumns = b->ncolumns;
    d->depth = b->depth;
    d->ndepth = b->ndepth;
    for (i = 0; i < b->nspans; i++) {
        b->spans[i].key = api->register_token(api, self, b->names[i], strlen(b->names[i]));
    }
    memset(&pub, 0, sizeof pub);
    pub.size = sizeof pub;
    pub.hi = b->oom ? 0 : len;
    pub.spans = b->spans;
    pub.nspans = b->oom ? 0 : b->nspans;
    set(api, self, doc, b->text, b->oom ? 0 : len, d, &pub, flags);
}

void oket_build_free(oket_build *b) {
    free(b->text);
    free(b->spans);
    free(b->names);
    free(b->columns);
    free(b->depth);
    memset(b, 0, sizeof *b);
}

/* --- writing (§6) --- */

void oket_replace(const lues_api *api, lues_self self, lues_doc doc,
                  size_t lo, size_t hi, const char *text, size_t len) {
    const lues_snapshot *s = api->snapshot(api, self, doc);
    lues_edit e;

    if (s == NULL) {
        return;
    }
    memset(&e, 0, sizeof e);
    e.size = sizeof e;
    e.lo = lo;
    e.hi = hi;
    e.text = text;
    e.text_len = len;
    api->submit(api, self, doc, s->gen, &e, 1, NULL, 0);
    api->release(api, self, s);
}

void oket_set(const lues_api *api, lues_self self, lues_doc doc,
              const char *text, size_t len, const oket_descriptor *d) {
    set(api, self, doc, text, len, d, NULL, 0);
}

void oket_regen(const lues_api *api, lues_self self, lues_doc doc,
                const char *text, size_t len, const oket_descriptor *d) {
    set(api, self, doc, text, len, d, NULL, LUES_SUBMIT_FORGET);
}

static void set(const lues_api *api, lues_self self, lues_doc doc, const char *text, size_t len,
                const oket_descriptor *d, const lues_span_pub *pub, uint32_t flags) {
    const lues_snapshot *s = api->snapshot(api, self, doc);
    lues_edit e;

    if (s == NULL) {
        return;
    }
    memset(&e, 0, sizeof e);
    e.size = sizeof e;
    e.lo = 0;
    e.hi = s->size;
    e.text = text;
    e.text_len = len;
    if (d != NULL) {
        oket(api)->describe(api, self, doc, d);
    }
    api->submit(api, self, doc, s->gen, &e, 1, pub, flags);
    api->release(api, self, s);
}

/* --- writing several places at once --- */

void oket_batch_edit(oket_batch *b, size_t lo, size_t hi, const char *text, size_t len) {
    oket_batch_edit_for(b, 0, lo, hi, text, len);
}

void oket_batch_edit_for(oket_batch *b, uint32_t cur, size_t lo, size_t hi,
                         const char *text, size_t len) {
    lues_edit *e;
    char *own = NULL;

    if (!grow(&b->oom, (void **)&b->edits, &b->cap, b->n + 1, sizeof *b->edits)) {
        return;
    }
    /* The edit owns its text until the submit copies it, so two carets may take two different
     * strings — which is what an indent-aware newline needs. */
    if (len > 0) {
        own = malloc(len);
        if (own == NULL) {
            b->oom = 1;
            return;
        }
        memcpy(own, text, len);
    }
    e = &b->edits[b->n++];
    memset(e, 0, sizeof *e);
    e->size = sizeof *e;
    e->lo = lo;
    e->hi = hi;
    e->text = own;
    e->text_len = len;
    e->tag = cur;
}

int oket_batch_submit(const lues_api *api, lues_self self, lues_doc doc, uint64_t gen,
                      oket_batch *b) {
    if (b->oom || b->n == 0) {
        return 0;
    }
    api->submit(api, self, doc, gen, b->edits, b->n, NULL, 0);
    return 1;
}

void oket_batch_free(oket_batch *b) {
    size_t i;

    for (i = 0; i < b->n; i++) {
        free((char *)b->edits[i].text);
    }
    free(b->edits);
    memset(b, 0, sizeof *b);
}

/* --- publishing spans (§9) --- */

/* A zeroed run over [lo, hi), or NULL for an empty range or no memory. */
static lues_span *span_push(oket_spans *b, size_t lo, size_t hi) {
    lues_span *sp;

    if (hi <= lo || !grow(&b->oom, (void **)&b->spans, &b->cap, b->n + 1, sizeof *b->spans)) {
        return NULL;
    }
    sp = &b->spans[b->n++];
    memset(sp, 0, sizeof *sp);
    sp->size = sizeof *sp;
    sp->lo = lo;
    sp->hi = hi;
    return sp;
}

void oket_spans_add(oket_spans *b, size_t lo, size_t hi, lues_token tok, uint8_t attrs,
                    uint8_t set) {
    lues_span *sp = span_push(b, lo, hi);

    if (sp != NULL) {
        sp->tok = tok;
        sp->attrs = attrs;
        sp->set = set;
    }
}

void oket_spans_data(oket_spans *b, size_t lo, size_t hi, lues_token key, const char *text,
                     size_t len) {
    lues_span *sp = span_push(b, lo, hi);

    if (sp != NULL) {
        sp->key = key;
        sp->text = text;
        sp->text_len = len;
    }
}

int oket_spans_publish(const lues_api *api, lues_self self, lues_doc doc, uint64_t gen,
                       size_t lo, size_t hi, oket_spans *b) {
    lues_span_pub pub;

    if (b->oom) {
        return 0;
    }
    memset(&pub, 0, sizeof pub);
    pub.size = sizeof pub;
    pub.lo = lo;
    pub.hi = hi;
    pub.spans = b->spans;
    pub.nspans = b->n;
    /* An EMPTY list still goes: a range-scoped replace with nothing in it is how a publisher
     * says "no colours here any more", and refusing it would leave the last parse's on screen. */
    api->submit(api, self, doc, gen, NULL, 0, &pub, 0);
    return 1;
}

void oket_spans_free(oket_spans *b) {
    free(b->spans);
    memset(b, 0, sizeof *b);
}

/* --- a view stage (VIEWS §5) --- */

void oket_view_fill(oket_view_out *out, const oket_batch *edits, const oket_spans *spans) {
    memset(out, 0, sizeof *out);
    if (edits != NULL && !edits->oom) {
        out->edits = edits->edits;
        out->nedits = edits->n;
    }
    if (spans != NULL && !spans->oom) {
        out->spans = spans->spans;
        out->nspans = spans->n;
    }
}

void oket_view_clear(oket_batch *edits, oket_spans *spans) {
    size_t i;

    if (edits != NULL) {
        for (i = 0; i < edits->n; i++) {
            free((char *)edits->edits[i].text);
        }
        edits->n = 0;
        edits->oom = 0;
    }
    if (spans != NULL) {
        spans->n = 0;
        spans->oom = 0;
    }
}
