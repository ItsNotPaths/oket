/* What the two halves of the syntax plugin say to each other. syntax.c reads grammars off a
 * disk; grammars.c knows which ones exist and lists them. Neither is a seam: both compile into
 * the one `.so`, and nothing here crosses the plugin boundary.
 */
#ifndef OKET_GRAMMARS_H
#define OKET_GRAMMARS_H

#include "oket.h"

/* --- syntax.c --- */

/* Where `<name>.so` and `<name>.scm` are looked for, or NULL when nothing can say. */
const char *grammars_dir(void);

int grammar_installed(const char *name);

/* Every loaded library dropped, and every document unbound from one. What a build finishing
 * costs, so a grammar made while oket was running is picked up without a reload. */
void grammar_forget(void);

/* The watcher, told to forget what it has been told: every open document arrives again on the
 * next frame. The one way to be called about something no generation records — a build
 * starting, and a build ending. */
void grammar_relatch(const oket_api *api, oket_self self);

/* --- grammars.c --- */

/* The grammar an extension selects, or NULL when the registry lists nobody using it. */
const char *grammar_for_ext(const char *ext, size_t len);

int grammars_count(void);     /* the registry's size */
int grammars_installed(void); /* how many of it were on the platter, as last counted */

/* The chain's last step, whichever way the build went. `installed` is what the platter says,
 * not what the tool claimed: the row stops on `done` or on `failed` by that alone. */
void grammars_done(const oket_api *api, oket_self self, const char *lang, int installed);

/* One frame of the bar on a building row. Non-zero asks the watcher to latch, which is the only
 * thing that keeps frames coming while a shell step is out. */
int grammars_tick(const oket_api *api, oket_self self, const oket_at *at);

/* The `grammars` kind, its verbs and the rows that reach them. Zero if the kind is refused,
 * which is what fails the load. */
oket_kind grammars_register(const oket_api *api, oket_self self);

/* The platter changed: count again, and rewrite every list that is open. */
void grammars_refresh(const oket_api *api, oket_self self);

#endif
