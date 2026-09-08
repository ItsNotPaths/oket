/* What every plugin writes first: one-liners over `oket_api`, `oket_at` and malloc that a
 * plugin would otherwise carry a private copy of. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

void oket_say(const oket_api *api, oket_self self, const char *text) {
    api->message(api, self, text, strlen(text));
}

int oket_mine(const oket_at *at) {
    return at->inst != NULL && at->snap != NULL;
}

char *oket_dup(const char *s, size_t len) {
    char *out = malloc(len + 1);

    if (out == NULL) {
        return NULL;
    }
    memcpy(out, s, len);
    out[len] = '\0';
    return out;
}

char *oket_file_read(const char *path, size_t max, size_t *len) {
    FILE *f = fopen(path, "rb");
    char *buf;
    long n;

    *len = 0;
    if (f == NULL) {
        return NULL;
    }
    /* Seek-tell-seek rather than stat: one header fewer, and a file that will not seek is one
     * this cannot read whole anyway. */
    if (fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return NULL;
    }
    if (max != 0 && (size_t)n > max) {
        fclose(f);
        return NULL;
    }
    buf = malloc((size_t)n + 1);
    if (buf != NULL) {
        /* Short reads are not an error here: `len` is what arrived, and a file shrinking under
         * a reader is the same answer as a file that was always that size. */
        *len = fread(buf, 1, (size_t)n, f);
        buf[*len] = '\0';
    }
    fclose(f);
    return buf;
}

/* --- chords --- */

int oket_chord_is(const char *chord, size_t chord_len, const char *name) {
    return strlen(name) == chord_len && memcmp(chord, name, chord_len) == 0;
}
