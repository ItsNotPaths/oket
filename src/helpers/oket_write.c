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
    oket_field *f;

    if (!grow(&b->oom, (void **)&b->fields, &b->fields_cap, b->nfields + 1, sizeof *b->fields)) {
        return;
    }
    f = &b->fields[b->nfields++];
    f->name = name;
    f->name_len = strlen(name);
    f->line = b->line;
    /* Cell-relative in, line-relative out, which is what a Field's offsets are. The document
     * offset never appears on either side. */
    f->lo = (int32_t)(b->cell_start + lo);
    f->hi = (int32_t)(b->cell_start + hi);
    f->value = NULL; /* the span's own bytes are the value */
    f->value_len = 0;
    memset(f->_pad, 0, sizeof f->_pad);
}

void oket_build_link(oket_build *b, const char *name, size_t lo, size_t hi,
                     const char *value, size_t value_len) {
    oket_build_span(b, name, lo, hi);
    if (b->nfields > 0 && value != NULL) {
        b->fields[b->nfields - 1].value = value;
        b->fields[b->nfields - 1].value_len = value_len;
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

void oket_build_desc(oket_build *b, oket_descriptor *d) {
    d->columns = b->columns;
    d->ncolumns = b->ncolumns;
    d->fields = b->fields;
    d->nfields = b->nfields;
    d->depth = b->depth;
    d->ndepth = b->ndepth;
}

void oket_build_free(oket_build *b) {
    free(b->text);
    free(b->fields);
    free(b->columns);
    free(b->depth);
    memset(b, 0, sizeof *b);
}

/* --- writing (§6) --- */

void oket_replace(const oket_api *api, oket_self self, oket_doc doc,
                  size_t lo, size_t hi, const char *text, size_t len) {
    const oket_snapshot *s = api->snapshot(api, self, doc);
    oket_edit e;

    if (s == NULL) {
        return;
    }
    memset(&e, 0, sizeof e);
    e.lo = lo;
    e.hi = hi;
    e.text = text;
    e.text_len = len;
    api->submit(api, self, doc, s->gen, &e, 1, NULL, NULL, 0);
    api->release(api, self, s);
}

static void set(const oket_api *api, oket_self self, oket_doc doc,
                const char *text, size_t len, const oket_descriptor *d, uint32_t flags);

void oket_set(const oket_api *api, oket_self self, oket_doc doc,
              const char *text, size_t len, const oket_descriptor *d) {
    set(api, self, doc, text, len, d, 0);
}

void oket_regen(const oket_api *api, oket_self self, oket_doc doc,
                const char *text, size_t len, const oket_descriptor *d) {
    set(api, self, doc, text, len, d, OKET_SUBMIT_REGEN);
}

static void set(const oket_api *api, oket_self self, oket_doc doc,
                const char *text, size_t len, const oket_descriptor *d, uint32_t flags) {
    const oket_snapshot *s = api->snapshot(api, self, doc);
    oket_edit e;

    if (s == NULL) {
        return;
    }
    memset(&e, 0, sizeof e);
    e.lo = 0;
    e.hi = s->size;
    e.text = text;
    e.text_len = len;
    api->submit(api, self, doc, s->gen, &e, 1, d, NULL, flags);
    api->release(api, self, s);
}

/* --- writing several places at once --- */

void oket_batch_edit(oket_batch *b, size_t lo, size_t hi, const char *text, size_t len) {
    oket_batch_edit_for(b, 0, lo, hi, text, len);
}

void oket_batch_edit_for(oket_batch *b, uint32_t cur, size_t lo, size_t hi,
                         const char *text, size_t len) {
    oket_edit *e;
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
    e->lo = lo;
    e->hi = hi;
    e->text = own;
    e->text_len = len;
    e->id = cur;
}

int oket_batch_submit(const oket_api *api, oket_self self, oket_doc doc, uint64_t gen,
                      oket_batch *b) {
    if (b->oom || b->n == 0) {
        return 0;
    }
    api->submit(api, self, doc, gen, b->edits, b->n, NULL, NULL, 0);
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

void oket_spans_add(oket_spans *b, size_t lo, size_t hi, oket_token tok, uint8_t attrs,
                    uint8_t set) {
    oket_span *sp;

    if (hi <= lo || !grow(&b->oom, (void **)&b->spans, &b->cap, b->n + 1, sizeof *b->spans)) {
        return;
    }
    sp = &b->spans[b->n++];
    memset(sp, 0, sizeof *sp);
    sp->lo = lo;
    sp->hi = hi;
    sp->tok = tok;
    sp->attrs = attrs;
    sp->set = set;
}

int oket_spans_publish(const oket_api *api, oket_self self, oket_doc doc, uint64_t gen,
                       size_t lo, size_t hi, oket_spans *b) {
    oket_span_pub pub;

    if (b->oom) {
        return 0;
    }
    memset(&pub, 0, sizeof pub);
    pub.lo = lo;
    pub.hi = hi;
    pub.spans = b->spans;
    pub.nspans = b->n;
    /* An EMPTY list still goes: a range-scoped replace with nothing in it is how a publisher
     * says "no colours here any more", and refusing it would leave the last parse's on screen. */
    api->submit(api, self, doc, gen, NULL, 0, NULL, &pub, 0);
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
