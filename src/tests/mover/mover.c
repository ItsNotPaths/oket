/* A test fixture for `oket(api)->move`: kernel motion, asked for by a plugin.
 *
 *     :paras   every caret down two paragraphs, as two moves in one call
 */
#include "oket_helpers.h"

static int32_t paras(const lues_api *api, lues_self self, const lues_at *at,
                     const char *args, size_t args_len) {
    (void)args;
    (void)args_len;
    if (at->snap == NULL) {
        return 1;
    }
    oket(api)->move(api, self, at->snap->doc, OKET_MOTION_PARA_DOWN, 0);
    oket(api)->move(api, self, at->snap->doc, OKET_MOTION_PARA_DOWN, 0);
    return 0;
}

LUES_MAIN {
    api->register_command(api, self, "paras", 5, "down two paragraphs", 19, paras);
    return 0;
}
