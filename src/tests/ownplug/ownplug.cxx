/* A source extension stage.sh does not dispatch on, so the plugin's own build.sh is what
 * builds it (§8). Calls `message` straight off the api rather than through a helper: the
 * claim under test is that stage.sh honours a recipe it did not write, not that C++ links. */
#include "oket.h"

static const char NAME[] = "ownplug";
static const char DOC[] = "built by a recipe stage.sh does not know";

static int32_t said(const lues_api *api, lues_self self, const lues_at *at,
                    const char *args, size_t args_len) {
    (void)at;
    (void)args;
    (void)args_len;
    static const char TEXT[] = "hello from a recipe";
    api->message(api, self, TEXT, sizeof TEXT - 1);
    return 0;
}

extern "C" LUES_EXPORT int32_t lues_main(const lues_api *api, lues_self self) {
    api->register_command(api, self, NAME, sizeof NAME - 1, DOC, sizeof DOC - 1, said);
    return 0;
}
