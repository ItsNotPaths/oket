/* Text with no snapshot in sight: UTF-8, display width, character classes, word boundaries,
 * indentation and bracket pairs. The tables come from tools/gen-unicode.py, the same run that
 * writes the kernel's, so the two agree by construction. */
#include "oket_helpers.h"
#include "oket_unicode.h"

#define BAD 0xFFFD

size_t oket_utf8_next(const char *s, size_t len, uint32_t *out) {
    /* The smallest value each length may encode; anything under it is overlong. */
    static const uint32_t least[5] = {0, 0, 0x80, 0x800, 0x10000};
    const unsigned char *p = (const unsigned char *)s;
    unsigned char b0;
    size_t need, i;
    uint32_t r;

    *out = BAD;
    if (len == 0) {
        return 0;
    }
    b0 = p[0];
    if (b0 < 0x80) {
        *out = b0;
        return 1;
    }
    if ((b0 & 0xE0) == 0xC0) {
        need = 2, r = b0 & 0x1Fu;
    } else if ((b0 & 0xF0) == 0xE0) {
        need = 3, r = b0 & 0x0Fu;
    } else if ((b0 & 0xF8) == 0xF0) {
        need = 4, r = b0 & 0x07u;
    } else {
        return 1; /* a stray continuation or a 5-byte lead: one byte of U+FFFD */
    }
    if (need > len) {
        return 1;
    }
    for (i = 1; i < need; i++) {
        if ((p[i] & 0xC0) != 0x80) {
            return 1; /* truncated: resync on the byte that broke it, never past it */
        }
        r = (r << 6) | (p[i] & 0x3Fu);
    }
    /* Overlong forms and surrogates decode to something; refusing them here is what stops a
     * plugin's own parser and the kernel's disagreeing about how many runes a line holds. */
    if (r < least[need] || r > 0x10FFFF || (r >= 0xD800 && r <= 0xDFFF)) {
        return 1;
    }
    *out = r;
    return need;
}

size_t oket_utf8_prev(const char *s, size_t at, uint32_t *out) {
    const unsigned char *p = (const unsigned char *)s;
    size_t start, back, got;

    *out = BAD;
    if (at == 0) {
        return 0;
    }
    /* At most three continuation bytes precede a lead, so the scan is bounded. */
    start = at - 1;
    for (back = 0; back < 3 && start > 0 && (p[start] & 0xC0) == 0x80; back++) {
        start--;
    }
    got = oket_utf8_next(s + start, at - start, out);
    if (got != at - start) { /* the run did not end where we started: take one byte */
        *out = BAD;
        return 1;
    }
    return got;
}

size_t oket_utf8_encode(uint32_t r, char *out) {
    if (r < 0x80) {
        out[0] = (char)r;
        return 1;
    }
    if (r < 0x800) {
        out[0] = (char)(0xC0 | (r >> 6));
        out[1] = (char)(0x80 | (r & 0x3F));
        return 2;
    }
    if (r < 0x10000) {
        out[0] = (char)(0xE0 | (r >> 12));
        out[1] = (char)(0x80 | ((r >> 6) & 0x3F));
        out[2] = (char)(0x80 | (r & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (r >> 18));
    out[1] = (char)(0x80 | ((r >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((r >> 6) & 0x3F));
    out[3] = (char)(0x80 | (r & 0x3F));
    return 4;
}

static int in_ranges(const oket_crange *rs, size_t n, uint32_t r) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (r < rs[mid].lo) {
            hi = mid;
        } else if (r > rs[mid].hi) {
            lo = mid + 1;
        } else {
            return 1;
        }
    }
    return 0;
}

int oket_width(uint32_t r) {
    /* Below U+0300 everything is one column, so nearly all text skips both searches. */
    if (r < 0x0300) {
        return r == 0 ? 0 : 1;
    }
    if (in_ranges(OKET_WIDTH_ZERO, sizeof OKET_WIDTH_ZERO / sizeof *OKET_WIDTH_ZERO, r)) {
        return 0;
    }
    if (in_ranges(OKET_WIDTH_WIDE, sizeof OKET_WIDTH_WIDE / sizeof *OKET_WIDTH_WIDE, r)) {
        return 2;
    }
    return 1;
}

size_t oket_width_str(const char *s, size_t len) {
    size_t i = 0, w = 0;
    while (i < len) {
        uint32_t r;
        size_t n = oket_utf8_next(s + i, len - i, &r);
        if (n == 0) {
            break;
        }
        i += n;
        w += (size_t)oket_width(r);
    }
    return w;
}

/* --- character classes --- */

oket_class oket_class_of(uint32_t r) {
    if (in_ranges(OKET_SPACE_RANGES, sizeof OKET_SPACE_RANGES / sizeof *OKET_SPACE_RANGES,
                  r)) {
        return OKET_CLASS_SPACE;
    }
    if (in_ranges(OKET_WORD_RANGES, sizeof OKET_WORD_RANGES / sizeof *OKET_WORD_RANGES,
                  r)) {
        return OKET_CLASS_WORD;
    }
    return OKET_CLASS_PUNCT;
}

/* --- word boundaries --- */

static size_t clamp_to(size_t v, size_t len) {
    return v > len ? len : v;
}

size_t oket_word_right(const char *s, size_t len, size_t from) {
    size_t i = clamp_to(from, len);
    uint32_t r;
    oket_class c;

    while (i < len) {
        size_t n = oket_utf8_next(s + i, len - i, &r);
        if (oket_class_of(r) != OKET_CLASS_SPACE) {
            break;
        }
        i += n;
    }
    if (i >= len) {
        return i;
    }
    oket_utf8_next(s + i, len - i, &r);
    c = oket_class_of(r);
    while (i < len) {
        size_t n = oket_utf8_next(s + i, len - i, &r);
        if (oket_class_of(r) != c) {
            break;
        }
        i += n;
    }
    return i;
}

size_t oket_word_left(const char *s, size_t len, size_t from) {
    size_t i = clamp_to(from, len);
    uint32_t r;
    oket_class c;

    while (i > 0) {
        size_t n = oket_utf8_prev(s, i, &r);
        if (oket_class_of(r) != OKET_CLASS_SPACE) {
            break;
        }
        i -= n;
    }
    if (i == 0) {
        return 0;
    }
    oket_utf8_prev(s, i, &r);
    c = oket_class_of(r);
    while (i > 0) {
        size_t n = oket_utf8_prev(s, i, &r);
        if (oket_class_of(r) != c) {
            break;
        }
        i -= n;
    }
    return i;
}

void oket_word_span(const char *s, size_t len, size_t col, size_t *lo, size_t *hi) {
    size_t i = clamp_to(col, len);
    uint32_t r;
    oket_class c;
    size_t size;

    *lo = *hi = 0;
    if (len == 0) {
        return;
    }
    if (i == len) {
        i -= oket_utf8_prev(s, i, &r); /* past the end: the run that ends here */
    }
    size = oket_utf8_next(s + i, len - i, &r);
    c = oket_class_of(r);
    *lo = i;
    *hi = i + size;
    while (*lo > 0) {
        size_t n = oket_utf8_prev(s, *lo, &r);
        if (oket_class_of(r) != c) {
            break;
        }
        *lo -= n;
    }
    while (*hi < len) {
        size_t n = oket_utf8_next(s + *hi, len - *hi, &r);
        if (oket_class_of(r) != c) {
            break;
        }
        *hi += n;
    }
}

/* --- lines --- */

size_t oket_indent_cols(const char *s, size_t len) {
    size_t n = 0;
    while (n < len && (s[n] == ' ' || s[n] == '\t')) {
        n++;
    }
    return n;
}

int oket_line_blank(const char *s, size_t len) {
    return oket_indent_cols(s, len) == len;
}

/* --- brackets --- */

uint32_t oket_pair_close(uint32_t open) {
    switch (open) {
    case '(': return ')';
    case '[': return ']';
    case '{': return '}';
    case '"': return '"';
    case '\'': return '\'';
    case '`': return '`';
    }
    return 0;
}
