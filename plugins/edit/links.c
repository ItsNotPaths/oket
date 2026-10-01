/* The links in an editor buffer, published as `link` data spans for `:openlink` to follow. A
 * plugin says WHERE a link is; what it does is the kernel's. Three shapes:
 *
 *   https://example.com     a URI: a scheme, then `://`
 *   src/x.c:12:4            a path that exists, relative to the buffer's directory, with an
 *                           optional :line[:col]
 *   [text](target)          markdown: the span covers `text`, and its value is `target`
 *
 * The whole buffer each time it moves. Spans ride the text between scans, so a stale scan is
 * only late, never wrong about where a link sits. */
#define _POSIX_C_SOURCE 200809L
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "links.h"

#define STATS_MAX 4096 /* paths checked on disk per scan: a huge file costs a bounded amount */

typedef struct {
    const char *dir; /* the buffer's directory, or NULL */
    int         stats;
} scan;

static int space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static int digit(char c) {
    return c >= '0' && c <= '9';
}

static int alpha(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/* `[text](target)` on one line, starting at `at`: `text` ends at *close and `target` is
 * [*t_lo, *t_hi). Answers the end, or 0 for no match. */
static size_t markdown(const char *buf, size_t len, size_t at, size_t *close, size_t *t_lo,
                       size_t *t_hi) {
    size_t i = at + 1;

    while (i < len && buf[i] != ']' && buf[i] != '\n') {
        i++;
    }
    if (i + 1 >= len || buf[i] != ']' || buf[i + 1] != '(' || i == at + 1) {
        return 0;
    }
    *close = i;
    *t_lo = i + 2;
    for (i = *t_lo; i < len && buf[i] != ')' && buf[i] != '\n'; i++) {
    }
    if (i >= len || buf[i] != ')' || i == *t_lo) {
        return 0;
    }
    *t_hi = i;
    return i + 1;
}

/* A scheme, then `://`, then something. */
static int uri(const char *s, size_t n) {
    size_t i = 0;

    if (n == 0 || !alpha(s[0])) {
        return 0;
    }
    while (i < n && (alpha(s[i]) || digit(s[i]) || s[i] == '+' || s[i] == '-' || s[i] == '.')) {
        i++;
    }
    return i + 3 < n && memcmp(s + i, "://", 3) == 0;
}

/* `s` less a trailing `:line` and `:line:col`. */
static size_t path_part(const char *s, size_t n) {
    int parts;

    for (parts = 0; parts < 2; parts++) {
        size_t i = n;

        while (i > 0 && digit(s[i - 1])) {
            i--;
        }
        if (i == n || i == 0 || s[i - 1] != ':') {
            break;
        }
        n = i - 1;
    }
    return n;
}

/* Does [s, s+n) name something on disk, from the buffer's directory or as it stands. */
static int exists(scan *sc, const char *s, size_t n) {
    char full[PATH_MAX];
    const char *home = getenv("HOME");
    struct stat st;
    int w;

    if (n == 0 || n >= sizeof full || sc->stats >= STATS_MAX ||
        (memchr(s, '/', n) == NULL && memchr(s, '.', n) == NULL)) {
        return 0;
    }
    sc->stats++;
    if (s[0] == '/') {
        w = snprintf(full, sizeof full, "%.*s", (int)n, s);
    } else if (n > 1 && s[0] == '~' && s[1] == '/' && home != NULL) {
        w = snprintf(full, sizeof full, "%s%.*s", home, (int)(n - 1), s + 1);
    } else if (sc->dir != NULL) {
        w = snprintf(full, sizeof full, "%s/%.*s", sc->dir, (int)n, s);
    } else {
        w = snprintf(full, sizeof full, "%.*s", (int)n, s);
    }
    return w > 0 && (size_t)w < sizeof full && stat(full, &st) == 0;
}

/* One whitespace-free token, less the punctuation prose wraps around a link. */
static void token(scan *sc, oket_spans *out, lues_token key, const char *buf, size_t lo,
                  size_t hi) {
    static const char LEAD[] = "(<\"'`[";
    static const char TRAIL[] = ")>\"'`],.;:!?";

    while (lo < hi && strchr(LEAD, buf[lo]) != NULL) {
        lo++;
    }
    while (hi > lo && strchr(TRAIL, buf[hi - 1]) != NULL) {
        hi--;
    }
    if (hi <= lo) {
        return;
    }
    if (uri(buf + lo, hi - lo) || exists(sc, buf + lo, path_part(buf + lo, hi - lo))) {
        oket_spans_data(out, lo, hi, key, NULL, 0);
    }
}

void links_scan(const char *buf, size_t len, const char *dir, lues_token key, oket_spans *out) {
    scan sc = {dir, 0};
    size_t i = 0;

    while (i < len) {
        size_t start, close, t_lo, t_hi, end;

        if (space(buf[i])) {
            i++;
            continue;
        }
        if (buf[i] == '[' && (end = markdown(buf, len, i, &close, &t_lo, &t_hi)) != 0) {
            oket_spans_data(out, i + 1, close, key, buf + t_lo, t_hi - t_lo);
            i = end;
            continue;
        }
        start = i;
        while (i < len && !space(buf[i])) {
            i++;
        }
        token(&sc, out, key, buf, start, i);
    }
}
