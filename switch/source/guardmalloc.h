/* guardmalloc.h -- diagnostic allocator for the engine's malloc/free.
 * MIT license; see LICENSE. */

#ifndef __GUARDMALLOC_H__
#define __GUARDMALLOC_H__

#include <stddef.h>

// 1 = engine allocations get red zones and a quarantine; 0 = plain newlib.
void guard_enable(int on);

void *guard_malloc(size_t n);
void *guard_calloc(size_t count, size_t size);
void *guard_realloc(void *p, size_t n);
void guard_free(void *p);
void guard_describe(const void *addr);
int guard_posix_memalign(void **out, size_t align, size_t n);

#endif
