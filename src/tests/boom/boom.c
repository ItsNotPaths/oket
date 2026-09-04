/* Stage 9's gate (§13): a plugin that dies on purpose, so the kernel can be watched surviving
 * it. It is a TEST FIXTURE and lives under src/tests rather than plugins/, because release.sh
 * ships every directory in there and nobody wants this one.
 *
 *     :boom      dereference a null pointer, in this plugin's own code
 *     :hang      stop returning, for the watchdog
 *     :slice N   a VIEW STAGE that answers "not finished" N more times (VIEWS §5's latch)
 *     :boomview  the same stage, dereferencing null instead
 *     the kind   faults in `open`, which is the call that half makes a document
 */
/* nanosleep is POSIX, and -std=c11 alone does not declare it. */
#define _POSIX_C_SOURCE 199309L

#include <stddef.h>
#include <stdio.h>
#include <time.h>

#include "oket_helpers.h"

/* Volatile, or the optimiser proves the store is undefined and folds it into a trap
 * instruction — a different signal, and not the one a wild pointer actually raises. */
static int *volatile NOWHERE;

static oket_kind BOOM;

/* The view stage's two dials: how many more calls answer "not finished", and whether it dies
 * instead. Both are commands, so a test drives them the way a user would. */
static int SLICES;
static int VIEW_DIES;
static oket_batch EDITS;

/* The kernel has already made the document and its descriptor by the time this runs, so a
 * fault here is the case where a half-made document has to go back. */
static void *open_boom(const oket_api *api, oket_self self, oket_doc doc,
                       const char *args, size_t args_len) {
    (void)api;
    (void)self;
    (void)doc;
    (void)args;
    (void)args_len;
    *NOWHERE = 1;
    return NULL;
}

static int32_t boom(const oket_api *api, oket_self self, const oket_at *at,
                    const char *args, size_t args_len) {
    (void)api;
    (void)self;
    (void)at;
    (void)args;
    (void)args_len;
    *NOWHERE = 1;
    return 0;
}

/* Long enough that the watchdog is what ends the call, and bounded so a test still finishes if
 * the watchdog is the thing that is broken. */
static int32_t hang(const oket_api *api, oket_self self, const oket_at *at,
                    const char *args, size_t args_len) {
    struct timespec t = {5, 0};
    (void)api;
    (void)self;
    (void)at;
    (void)args;
    (void)args_len;
    nanosleep(&t, NULL);
    return 0;
}

/* A stage that spreads its work over frames, which is the whole of what the latch is for: what
 * it emits this time is drawn, and a non-zero return asks for the next frame. */
static int32_t slice_view(const oket_api *api, oket_self self, const oket_at *at,
                          oket_view_out *out) {
    char mark[32];
    int  n;

    (void)api;
    (void)self;
    if (VIEW_DIES) {
        *NOWHERE = 1;
    }
    oket_view_clear(&EDITS, NULL);
    n = snprintf(mark, sizeof mark, " [%d]", SLICES);
    if (n > 0 && at->snap->size > 0) {
        oket_batch_edit(&EDITS, at->snap->size, at->snap->size, mark, (size_t)n);
    }
    oket_view_fill(out, &EDITS, NULL);
    return SLICES-- > 0;
}

static int32_t slice(const oket_api *api, oket_self self, const oket_at *at,
                     const char *args, size_t args_len) {
    (void)api;
    (void)self;
    (void)at;
    SLICES = args_len > 0 ? args[0] - '0' : 0;
    return 0;
}

static int32_t boomview(const oket_api *api, oket_self self, const oket_at *at,
                        const char *args, size_t args_len) {
    (void)api;
    (void)self;
    (void)at;
    (void)args;
    (void)args_len;
    VIEW_DIES = 1;
    return 0;
}

OKET_MAIN {
    static const oket_kind_spec SPEC = {"boom", 4, "surface", 7, {open_boom, NULL, NULL}};
    BOOM = api->register_kind(api, self, &SPEC);
    if (BOOM == 0) {
        return 1;
    }
    api->register_command(api, self, "boom", 4, "dereference a null pointer", 26, boom);
    api->register_command(api, self, "hang", 4, "stop returning", 14, hang);
    api->register_command(api, self, "slice", 5, "latch for N more calls", 22, slice);
    api->register_command(api, self, "boomview", 8, "fault in the view stage", 23, boomview);
    api->register_view(api, self, slice_view);
    return 0;
}
