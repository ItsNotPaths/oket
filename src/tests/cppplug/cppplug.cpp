/* A whole plugin in C++, which is the §8 claim: one command and one helper call. The header is
 * C, so the include and the entry point both need `extern "C"`. A fixture, so it sits under
 * src/tests like boom.c and not in plugins/. */
extern "C" {
#include <string.h>

#include "oket_helpers.h"
}

static const char NAME[] = "cppplug";
static const char DOC[] = "proof the seam is not C-only";
static const char BOLD_NAME[] = "cppbold";
static const char BOLD_DOC[] = "publish one bold run over the focused document";

static int32_t said(const oket_api *api, oket_self self, const oket_at *at,
                    const char *args, size_t args_len) {
    (void)at;
    (void)args;
    (void)args_len;
    oket_say(api, self, "hello from c++");
    return 0;
}

/* The only thing that crosses the seam as a RAW BYTE. `attrs` is a uint8_t here and a
 * `shape.Attrs` on the kernel side, so this is what proves OKET_ATTR_BOLD arrives as the bit
 * the renderer reads. A C claim, not a C++ one — the fixture just happens to be the one with
 * the helpers already linked. */
static int32_t bold(const oket_api *api, oket_self self, const oket_at *at,
                    const char *args, size_t args_len) {
    oket_spans b;
    int ok;

    (void)args;
    (void)args_len;
    if (at->snap == NULL) {
        return 1;
    }
    memset(&b, 0, sizeof b);
    oket_spans_add(&b, 0, 3, OKET_TOK_FG, OKET_ATTR_BOLD, OKET_SET_ATTRS);
    ok = oket_spans_publish(api, self, at->doc, at->snap->gen, 0, 3, &b);
    oket_spans_free(&b);
    return ok ? 0 : 1;
}

extern "C" OKET_EXPORT int32_t oket_main(const oket_api *api, oket_self self) {
    api->register_command(api, self, NAME, sizeof NAME - 1, DOC, sizeof DOC - 1, said);
    api->register_command(api, self, BOLD_NAME, sizeof BOLD_NAME - 1,
                          BOLD_DOC, sizeof BOLD_DOC - 1, bold);
    return 0;
}
