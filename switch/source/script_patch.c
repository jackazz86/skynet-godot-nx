/* script_patch.c -- on-device patches to defaults in the game's compiled GDScript.
 *
 * For SkyNET (Godot 4.7) no script patch is known to be needed yet, so
 * script_patches_apply() is a no-op. This file (and the zstd/asset_pack
 * plumbing it used under galaxian_nx) is kept as a hook point: if a boot log
 * or on-hardware test shows a hardcoded Android-only assumption baked into a
 * compiled .gdc (a FileDialog path, an input-mode default, ...), the same
 * technique galaxian_nx used -- decompress the .gdc with the engine's zstd,
 * rewrite a literal constant in its token buffer, re-encode to the same
 * length, and serve the copy from <save_root>/_ovr via godot_shim.c -- can be
 * re-added here. See galaxian_nx's script_patch.c for the original technique.
 * MIT license; see LICENSE. */

#include "script_patch.h"

void script_patches_apply(void) {
  // No known GDScript default needs patching for SkyNET yet.
}
