#ifndef FIND_GREP_H
#define FIND_GREP_H

#include "oket_helpers.h"

/* The `grep` kind and the `:grep` command. Non-zero when the kind could not be registered. */
int grep_register(const lues_api *api, lues_self self);

#endif
