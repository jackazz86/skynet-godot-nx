/* guardmalloc.c -- diagnostic allocator for the engine's malloc/free.
 *
 * The engine (and libc++) allocate through the import table. With the guard on
 * each block gets a header and a 16-byte red zone on both sides, filled with a
 * pattern; free() checks them, poisons the block, and parks it in a quarantine
 * instead of releasing it. When a block finally leaves the quarantine its
 * poison is checked again, which catches a write AFTER free. Every report names
 * the block's size and the engine address that allocated it, which is what a
 * crash far away from the real bug cannot tell us.
 *
 * Pointers that carry no header (strdup, wrapper-made strings, memory from the
 * graphics driver) are passed to the real free(). MIT license; see LICENSE. */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <malloc.h>
#include <switch.h>

#include "guardmalloc.h"
#include "util.h"

extern void heapcheck_log_addr(const char *tag, uint64_t addr);

#define HDR 80
#define NCALL 4
#define RZ 16
#define MAGIC_LIVE 0x6755A4D0C0FFEE01ull
#define MAGIC_FREED 0x6755A4D0DEADF4EEull
#define PAT_RZ 0xA5
#define PAT_FREE 0xDD

typedef struct {
  size_t size;
  void *base;
  void *caller[NCALL];   // engine return addresses, innermost first
  uint64_t magic;
  uint64_t pad;
  uint8_t rz[RZ];
} hdr_t;

typedef struct { uint8_t *user; } qent_t;

#define Q_MAX 32768
#define Q_BYTES (96u << 20)

static int s_on;
static Mutex s_lock;
static qent_t s_q[Q_MAX];
static unsigned s_qhead, s_qtail; // [tail, head) are queued
static size_t s_qbytes;
static unsigned s_reports, s_foreign;

void guard_enable(int on) { s_on = on; }

static int rz_ok(const uint8_t *p) {
  for (int i = 0; i < RZ; i++)
    if (p[i] != PAT_RZ) return 0;
  return 1;
}

static void report(const char *what, const hdr_t *h, size_t extra) {
  if (s_reports++ >= 40) return;
  debugPrintf("[heapcheck] %s: block of %zu bytes (detail %zu)\n", what, h->size, extra);
  for (int i = 0; i < NCALL; i++)
    if (h->caller[i]) heapcheck_log_addr("allocated from", (uint64_t)(uintptr_t)h->caller[i]);
}

// Verify a queued block's poison and header, then really release it.
static void release_oldest_locked(void) {
  uint8_t *user = s_q[s_qtail % Q_MAX].user;
  s_qtail++;
  hdr_t *h = (hdr_t *)(user - HDR);
  if (h->magic != MAGIC_FREED) {
    report("HEADER OVERWRITTEN after free", h, 0);
  } else {
    for (size_t i = 0; i < h->size; i++) {
      if (user[i] != PAT_FREE) {
        report("WRITE AFTER FREE", h, i);
        break;
      }
    }
    if (!rz_ok(user + h->size)) report("tail red zone overwritten after free", h, 0);
  }
  s_qbytes -= h->size;
  void *base = h->base;
  free(base);
}

__attribute__((noinline, optimize("no-omit-frame-pointer")))
static void *guard_alloc(size_t n, size_t align, void *caller) {
  if (align < 16) align = 16;
  size_t pad = (HDR + align - 1) & ~(align - 1);
  if (n > ((size_t)1 << 40)) return NULL;
  uint8_t *base = memalign(align, pad + n + RZ);
  if (!base) return NULL;
  uint8_t *user = base + pad;
  hdr_t *h = (hdr_t *)(user - HDR);
  h->size = n;
  h->base = base;
  h->caller[0] = caller;
  for (int i = 1; i < NCALL; i++) h->caller[i] = NULL;
  {
    // walk the engine's frame-pointer chain (the engine keeps frame pointers)
    const uintptr_t base0 = (uintptr_t)__builtin_frame_address(0);
    uintptr_t fp = *(uintptr_t *)base0;           // the shim's caller's frame
    for (int i = 1; i < NCALL && fp > base0 && fp - base0 < (8u << 20) && (fp & 7) == 0; i++) {
      uintptr_t next = *(uintptr_t *)fp;
      uintptr_t ra = *(uintptr_t *)(fp + 8);
      if (!ra) break;
      h->caller[i] = (void *)ra;
      if (next <= fp || next - fp > (1u << 20)) break;
      fp = next;
    }
  }
  h->magic = MAGIC_LIVE;
  memset(h->rz, PAT_RZ, RZ);
  memset(user + n, PAT_RZ, RZ);
  return user;
}

void *guard_malloc(size_t n) {
  if (!s_on) return malloc(n);
  return guard_alloc(n, 16, __builtin_return_address(0));
}

void *guard_calloc(size_t count, size_t size) {
  if (!s_on) return calloc(count, size);
  size_t n;
  if (__builtin_mul_overflow(count, size, &n)) return NULL;
  void *p = guard_alloc(n, 16, __builtin_return_address(0));
  if (p) memset(p, 0, n);
  return p;
}

int guard_posix_memalign(void **out, size_t align, size_t n) {
  if (!s_on) {
    void *p = memalign(align, n);
    if (!p) return 12; // ENOMEM
    *out = p;
    return 0;
  }
  void *p = guard_alloc(n, align, __builtin_return_address(0));
  if (!p) return 12;
  *out = p;
  return 0;
}

void guard_free(void *p) {
  if (!p) return;
  if (!s_on) { free(p); return; }
  hdr_t *h = (hdr_t *)((uint8_t *)p - HDR);
  if (h->magic == MAGIC_FREED) {
    report("DOUBLE FREE", h, 0);
    return;
  }
  if (h->magic != MAGIC_LIVE) {
    // not ours: strdup, wrapper-made or driver memory
    if (s_foreign++ < 5)
      debugPrintf("[heapcheck] free of a block without header: %p (passed to the real free)\n", p);
    free(p);
    return;
  }
  if (!rz_ok(h->rz)) report("UNDERFLOW (head red zone)", h, 0);
  if (!rz_ok((uint8_t *)p + h->size)) report("OVERFLOW (tail red zone)", h, 0);
  h->magic = MAGIC_FREED;
  memset(p, PAT_FREE, h->size);

  mutexLock(&s_lock);
  s_q[s_qhead % Q_MAX].user = p;
  s_qhead++;
  s_qbytes += h->size;
  while ((s_qhead - s_qtail) >= Q_MAX || s_qbytes > Q_BYTES)
    release_oldest_locked();
  mutexUnlock(&s_lock);
}

void *guard_realloc(void *p, size_t n) {
  if (!s_on) return realloc(p, n);
  if (!p) return guard_alloc(n, 16, __builtin_return_address(0));
  if (n == 0) { guard_free(p); return NULL; }
  hdr_t *h = (hdr_t *)((uint8_t *)p - HDR);
  if (h->magic != MAGIC_LIVE) return realloc(p, n); // foreign block
  void *np = guard_alloc(n, 16, __builtin_return_address(0));
  if (!np) return NULL;
  memcpy(np, p, h->size < n ? h->size : n);
  guard_free(p);
  return np;
}

// Where does an address that holds poison belong? Search the quarantine.
void guard_describe(const void *addr) {
  const uint8_t *a = (const uint8_t *)addr;
  mutexLock(&s_lock);
  for (unsigned i = s_qtail; i != s_qhead; i++) {
    const uint8_t *user = s_q[i % Q_MAX].user;
    const hdr_t *h = (const hdr_t *)(user - HDR);
    if (a >= user && a < user + h->size) {
      debugPrintf("[heapcheck] that address is inside a FREED block of %zu bytes, offset %zu\n",
                  h->size, (size_t)(a - user));
      for (int k = 0; k < NCALL; k++)
        if (h->caller[k]) heapcheck_log_addr("block allocated from", (uint64_t)(uintptr_t)h->caller[k]);
      mutexUnlock(&s_lock);
      return;
    }
  }
  mutexUnlock(&s_lock);
  debugPrintf("[heapcheck] that address is not inside any quarantined block\n");
}
