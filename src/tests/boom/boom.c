/* Stage 9's gate (§13): a plugin that dies on purpose, so the kernel can be watched surviving
 * it. It is a TEST FIXTURE and lives under src/tests rather than plugins/, because release.sh
 * ships every directory in there and nobody wants this one.
 *
 *     :boom      dereference a null pointer, in this plugin's own code
 *     :hang      stop returning, for the watchdog
 *     the kind   faults in `open`, which is the call that half makes a document
 */
/* nanosleep is POSIX, and -std=c11 alone does not declare it. */
#define _POSIX_C_SOURCE 199309L

#include <stddef.h>
#include <time.h>

#include "oket_helpers.h"

/* Volatile, or the optimiser proves the store is undefined and folds it into a trap
 * instruction — a different signal, and not the one a wild pointer actually raises. */
static int *volatile NOWHERE;

static oket_kind BOOM;

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

OKET_MAIN {
    static const oket_kind_spec SPEC = {"boom", 4, "surface", 7, {open_boom, NULL, NULL}};
    BOOM = api->register_kind(api, self, &SPEC);
    if (BOOM == 0) {
        return 1;
    }
    api->register_command(api, self, "boom", 4, "dereference a null pointer", 26, boom);
    api->register_command(api, self, "hang", 4, "stop returning", 14, hang);
    return 0;
}
