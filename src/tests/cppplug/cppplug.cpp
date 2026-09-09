/* A whole plugin in C++, which is the §8 claim: one command and one helper call. The header is
 * C, so the include and the entry point both need `extern "C"`. A fixture, so it sits under
 * src/tests like boom.c and not in plugins/. */
extern "C" {
#include "oket_helpers.h"
}

static const char NAME[] = "cppplug";
static const char DOC[] = "proof the seam is not C-only";

static int32_t said(const oket_api *api, oket_self self, const oket_at *at,
                    const char *args, size_t args_len) {
    (void)at;
    (void)args;
    (void)args_len;
    oket_say(api, self, "hello from c++");
    return 0;
}

extern "C" OKET_EXPORT int32_t oket_main(const oket_api *api, oket_self self) {
    api->register_command(api, self, NAME, sizeof NAME - 1, DOC, sizeof DOC - 1, said);
    return 0;
}
