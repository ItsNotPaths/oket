#ifndef EDIT_LINKS_H
#define EDIT_LINKS_H

#include "oket_helpers.h"

/* Adds a `key` data run to `out` for every link in `buf`. Markdown values point into `buf`, so
 * it must outlive the publish. `dir` resolves relative paths; NULL is the working directory. */
void links_scan(const char *buf, size_t len, const char *dir, lues_token key, oket_spans *out);

#endif
