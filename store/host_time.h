/*
 * Host calendar time for %C — prototypes only; link against libc.
 * (modc's curated <time.h> omits time/gmtime.)
 */
#pragma once

#include <stdint.h>

int64_t time(int64_t *tloc);
