/* Stage 12's gate (§13), the plugin half: a language server, spoken to and answered, with no
 * thread anywhere in the plugin. It is a TEST FIXTURE and lives under src/tests rather than
 * plugins/, because release.sh ships every directory in there.
 *
 *     :lsp <script>   start `sh <script>` as the server and send an initialize request
 *     :lsp stop       end it
 *
 * The framing is LSP's own — `Content-Length`, a blank line, then the body — which is the part
 * that makes this a real round trip rather than an echo: a reply arrives in as many pieces as
 * the pipe felt like giving, and a frame is only a frame once all of it is here.
 *
 * The thread check is the gate stated in code. Every handler runs on the thread that loaded
 * this plugin, or it says so and the test fails on the message.
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oket_helpers.h"

static pthread_t MAIN_THREAD;
static oket_io SERVER;
static size_t SENT;  /* the body we asked about, in bytes */
static int READY;    /* the round trip completed; the answer and a clean exit can share a frame,
                      * so an exit after it must not overwrite the message the test waits on */

/* Everything the server has said and we have not finished reading. */
static char *BUF;
static size_t BUF_LEN;

/* The one rule this fixture exists to check. */
static int on_main_thread(const oket_api *api, oket_self self) {
    if (pthread_equal(pthread_self(), MAIN_THREAD)) {
        return 1;
    }
    oket_say(api, self, "lsp: OFF THREAD");
    return 0;
}

static void frame(const oket_api *api, oket_self self, const char *body) {
    char out[512];
    int n = snprintf(out, sizeof out, "Content-Length: %zu\r\n\r\n%s", strlen(body), body);
    SENT = strlen(body);
    api->io_write(api, self, SERVER, out, (size_t)n);
}

/* One complete frame, or nothing yet. The header is read, the body is waited for, and what is
 * consumed leaves the buffer. */
static void take_frames(const oket_api *api, oket_self self) {
    for (;;) {
        char *head = BUF ? strstr(BUF, "\r\n\r\n") : NULL;
        if (!head) {
            return;
        }
        size_t want = 0;
        const char *len_at = strstr(BUF, "Content-Length:");
        if (!len_at || len_at > head) {
            oket_say(api, self, "lsp: a frame with no length");
            BUF_LEN = 0;
            free(BUF);
            BUF = NULL;
            return;
        }
        want = (size_t)strtoul(len_at + 15, NULL, 10);
        size_t start = (size_t)(head - BUF) + 4;
        if (BUF_LEN < start + want) {
            return; /* the rest of the body is still on its way */
        }
        char body[1024];
        size_t n = want < sizeof body - 1 ? want : sizeof body - 1;
        memcpy(body, BUF + start, n);
        body[n] = 0;

        /* The server answers with the byte count it read, so a reply proves the request
         * arrived whole rather than proving a pipe is connected. */
        const char *got = strstr(body, "\"got\":");
        char msg[128];
        if (got && (size_t)strtoul(got + 6, NULL, 10) == SENT) {
            snprintf(msg, sizeof msg, "lsp: initialized");
            READY = 1;
        } else {
            snprintf(msg, sizeof msg, "lsp: the server read the wrong request");
        }
        oket_say(api, self, msg);

        size_t used = start + want;
        memmove(BUF, BUF + used, BUF_LEN - used);
        BUF_LEN -= used;
        BUF[BUF_LEN] = 0;
    }
}

/* A watcher, so this plugin is reached with no kind and no document of its own (§9). Its I/O
 * jobs name no document either, which is what routes their answers here. */
static int32_t watch(const oket_api *api, oket_self self, const oket_at *at, oket_event ev,
                     const char *text, size_t len) {
    if (!on_main_thread(api, self)) {
        return 0;
    }
    if (ev != OKET_EVENT_IO && ev != OKET_EVENT_IO_END) {
        return 0; /* a document moved; this fixture draws nothing and does not care */
    }
    if (SERVER == 0 || at->io != SERVER) {
        return 0;
    }
    if (ev == OKET_EVENT_IO) {
        char *grown = realloc(BUF, BUF_LEN + len + 1);
        if (!grown) {
            return 0;
        }
        BUF = grown;
        memcpy(BUF + BUF_LEN, text, len);
        BUF_LEN += len;
        BUF[BUF_LEN] = 0;
        take_frames(api, self);
    } else if (ev == OKET_EVENT_IO_END) {
        char msg[64];
        if (!READY) {
            snprintf(msg, sizeof msg, "lsp: server exited %d", at->code);
            oket_say(api, self, msg);
        }
        SERVER = 0;
    }
    return 0;
}

static int32_t lsp_cmd(const oket_api *api, oket_self self, const oket_at *at,
                       const char *args, size_t args_len) {
    (void)at;
    if (args_len == 4 && memcmp(args, "stop", 4) == 0) {
        api->io_close(api, self, SERVER);
        SERVER = 0;
        oket_say(api, self, "lsp: stopped");
        return 0;
    }
    if (args_len == 0) {
        oket_say(api, self, "usage: :lsp <script> | :lsp stop");
        return 1;
    }
    char *script = oket_dup(args, args_len);
    const char *argv[2] = {"sh", script};
    READY = 0;
    SERVER = api->io_spawn(api, self, 0, argv, 2, NULL, 0);
    free(script);
    if (SERVER == 0) {
        oket_say(api, self, "lsp: the server did not start");
        return 1;
    }
    frame(api, self, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{}}");
    return 0;
}

OKET_MAIN {
    MAIN_THREAD = pthread_self();
    api->register_command(api, self, "lsp", 3, "talk to a language server", 25, lsp_cmd);
    api->register_watch(api, self, watch);
    return 0;
}
