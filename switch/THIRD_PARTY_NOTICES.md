# Third-party notices

This wrapper is built on other people's work. All of it is MIT-licensed unless
noted; the MIT notice in `LICENSE` is kept as required.

- **delsonazevedo** - the original Godot 4 Nintendo Switch Android-library
  wrapper (the `smwr_nx` template, written for Godot 4.4/4.6 games), from
  which the loader, fake JNI layer, libc shim and EGL/GLES import table come.
- **artslay/galaxian_nx** - the Godot 4.7 retarget of that template that this
  project started from (`artslay`, MIT).
- **TheFloW (Andy Nguyen), fgsfdsfgs and Rinnegatamante** - the "SoLoader"
  lineage (`so_util`) that loads an Android `.so` on a console.
- **danfromtico/mesa-switch** and **NaGaa95** - Mesa with a Horizon/libnx
  backend (NVK Vulkan, Nouveau GL/GLES, EGL), linked statically. Mesa is MIT.
- **Godot Engine** - MIT. The wrapper loads the unmodified
  `libgodot_android.so` shipped inside the game's own APK; it is not
  redistributed here.
- **devkitPro / libnx** - toolchain and system library.

No part of SkyNET, Future Shock or any game data is included.
