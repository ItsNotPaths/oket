/* Indent marks and scope guides, as spans over any file it is told about.
 *
 * A tab's indent draws a line, a space's a dot, both dim. A block is decided by INDENT, as
 * plugins/fold decides one: a line opens a scope when the next non-blank line sits deeper,
 * and the first line back at its depth or shallower closes it. The kernel draws the line.
 *
 *     :pluginify plugins/indent
 */
#include <stdio.h>
#include <string.h>

#include "oket_helpers.h"

#define HEAD_MAX 256 /* bytes read off a line's front; deeper indent than this draws plain */
#define DEPTH_MAX 64

static lues_token OPEN, CLOSE;
static oket_spans OUT;

/* One mark run per stretch of tabs or spaces in [lo, lo + n) of `head`. */
static void marks(const char *head, size_t n, size_t lo) {
    size_t i = 0, j;

    while (i < n) {
        for (j = i; j < n && head[j] == head[i]; j++) {
        }
        oket_spans_add(&OUT, lo + i, lo + j, OKET_TOK_DIM,
                       head[i] == '\t' ? OKET_ATTR_RULE : OKET_ATTR_DOT,
                       LUES_CHAN_FG | LUES_CHAN_ATTRS);
        i = j;
    }
}

static void close_at(size_t at, size_t n) {
    char count[24];
    int  len = snprintf(count, sizeof count, "%zu", n);

    oket_spans_data(&OUT, at, at + 1, CLOSE, count, (size_t)len);
}

static void scan(const lues_snapshot *s) {
    char   head[HEAD_MAX];
    size_t stack[DEPTH_MAX], depth = 0, prev_cols = 0, prev_at = 0, line, lo, hi, len, cols, n;
    int    seen = 0;

    oket_view_clear(NULL, &OUT);
    for (line = 0; line < s->lines; line++) {
        oket_line_range(s, line, &lo, &hi);
        len = oket_copy(s, lo, hi < lo + HEAD_MAX ? hi : lo + HEAD_MAX, head, sizeof head);
        cols = oket_indent_cols(head, len);
        marks(head, cols, lo);
        if (cols == len) {
            continue; /* blank, or deeper than HEAD_MAX: guides flow through it */
        }
        for (n = 0; depth > 0 && stack[depth - 1] >= cols; n++) {
            depth--;
        }
        if (n > 0) {
            close_at(lo + cols, n);
        }
        if (seen && cols > prev_cols && depth < DEPTH_MAX) {
            stack[depth++] = prev_cols;
            oket_spans_data(&OUT, prev_at, prev_at + 1, OPEN, NULL, 0);
        }
        prev_cols = cols;
        prev_at = lo + cols;
        seen = 1;
    }
}

static int32_t on_moved(const lues_api *api, lues_self self, const lues_at *at, lues_event ev,
                        const char *text, size_t len) {
    const oket_descriptor *desc;

    (void)text;
    (void)len;
    if (ev != LUES_EVENT_MOVED || !at->snap) {
        return 0;
    }
    desc = oket_side_of(at->snap)->desc;
    if (!desc || desc->file_len == 0 || desc->render != OKET_RENDER_TEXT) {
        return 0; /* a terminal, a listing, the command line */
    }
    scan(at->snap);
    oket_spans_publish(api, self, at->doc, at->snap->gen, 0, (size_t)-1, &OUT);
    return 0;
}

LUES_MAIN {
    OPEN = api->register_token(api, self, LIT(OKET_GUIDE_OPEN));
    CLOSE = api->register_token(api, self, LIT(OKET_GUIDE_CLOSE));
    api->register_watch(api, self, on_moved);
    return 0;
}
