/* patch.c -- binary patches applied to the loaded libgodot_android.so.
 *
 * Offsets are specific to ONE engine build (here: SkyNET v0.4.0's
 * libgodot_android.so, Godot 4.7.2 arm64-v8a, the one in SkyNET.apk from the
 * GitHub release). Each patch checks the original instruction word first and
 * is skipped with a log line if it does not match, so running the wrapper with
 * a different engine build is safe -- it just will not be fixed.
 *
 * can_capture_pointer: DisplayServerAndroid calls
 * GodotJavaViewWrapper::can_capture_pointer() on a null view because there is
 * no Java view on Switch, which reads *(NULL + 0x28) and faults. The
 * replacement returns 0 for a null view. Another Godot build needs its own
 * VADDR: the first on-hardware Data Abort prints "godot+0xADDR" (FAR=0x28);
 * disassemble there and look for
 *     ldp x8, x9, [x0, #40]; cmp x8, #0; ccmp x9, #0, #4, ne; cset w0, ne; ret
 * (word 0xa942a408 at the function start).
 * Inherited from artslay/galaxian_nx, MIT license; see LICENSE. */

#include <stdint.h>

#include "patch.h"
#include "so_util.h"
#include "util.h"

#define CAN_CAPTURE_POINTER_VADDR 0x13197d0
#define CAN_CAPTURE_POINTER_WORD0 0xa942a408u

static int can_capture_pointer_safe(void *self) {
  if (!self) return 0;
  void *req = *(void **)((char *)self + 0x28);
  void *rel = *(void **)((char *)self + 0x30);
  return (req && rel) ? 1 : 0;
}

void so_patch(so_module *mod) {
  // written into the RW backing (load_base) before so_finalize, which flushes
  // the icache when it maps the segment executable
  uint32_t *insn = (uint32_t *)((uintptr_t)mod->load_base + CAN_CAPTURE_POINTER_VADDR);
  if (*insn != CAN_CAPTURE_POINTER_WORD0) {
    debugPrintf("[patch] can_capture_pointer: unexpected bytes %08x at 0x%lx, skipping\n",
                *insn, (unsigned long)CAN_CAPTURE_POINTER_VADDR);
    return;
  }
  hook_arm64((uintptr_t)insn, (uintptr_t)&can_capture_pointer_safe);
  debugPrintf("[patch] can_capture_pointer hooked at vaddr 0x%lx\n",
              (unsigned long)CAN_CAPTURE_POINTER_VADDR);
}
