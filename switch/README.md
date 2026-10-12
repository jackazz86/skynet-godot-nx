# SkyNET on Nintendo Switch (experimental)

Runs the Android build of [skynet-godot](https://github.com/nemo22/skynet-godot)
on a Switch with Atmosphere. Nothing is recompiled: the wrapper loads the
unmodified `libgodot_android.so` from the game's own APK and provides the small
Android environment that library expects (C library, a fake JNI, EGL/GLES3 or
Vulkan through Mesa, audio, input, motion sensors).

It is a retarget of [artslay/galaxian_nx](https://github.com/artslay/galaxian_nx),
which in turn comes from delsonazevedo's Godot 4 Switch wrapper. See
`THIRD_PARTY_NOTICES.md`.

No game files are in this repository, and none are needed in it: you bring your
own copy of SkyNET (and optionally Terminator: Future Shock) and the APK from the
skynet-godot release.

## Status

Tested on a Switch OLED, handheld: the engine boots on Vulkan (NVK), converts the
original data, the menus work with a visible cursor, and the first mission plays
with the controller and the gyro. Frame rate in play is roughly 30-55 fps.

Known problems:

- **Getting into a mission takes about a minute.** Most of it is the Vulkan
  shader compiler (Mesa NAK) running on the CPU. The wrapper raises the CPU boost
  when the game announces a mission load (53 s on MAP.210 against 91-93 s before)
  and drops it a few frames after. The pipeline cache is not saved between runs yet,
  so every mission pays this again. The first start also converts all the original
  data, which takes a long time (about 20 minutes here); starting a game also
  checks every cached file against a manifest, which is slow on the SD card.
- **Fidelity to the DOS version.** The graphics and gameplay fixes found by
  comparing with DOS (sprite size and height, enemy damage, effects) are in the
  game scripts of the `gamepad-support` branch; they are also offered upstream
  as `dos-fidelity-fixes`. The enemies' rate of fire is not matched to DOS yet.
- **Exit.** The game leaves through `svcExitProcess`; the console may show an
  error screen when you quit.
- **Memory.** A use-after-free in how the engine drops condition variables used
  to corrupt the heap and crash the game about a minute into a mission. The
  emulation of mutexes and condvars no longer writes into freed memory, which
  stopped the crashes in our tests, but that is a handful of sessions, not a
  guarantee. `heapcheck 1` in `config.txt` turns on a diagnostic allocator (red
  zones plus a quarantine of freed blocks) that names the allocation site of
  whatever gets overwritten.

## Install

On the SD card, in `/switch/skynet_nx/`:

```
skynet_nx.nro
libgodot_android.so      from SkyNET.apk, lib/arm64-v8a/
libc++_shared.so         from SkyNET.apk, lib/arm64-v8a/
config.txt
assets/                  the whole assets/ folder of SkyNET.apk
GAMEDATA/                your SkyNET data (the folder with MDMDMAP2.BSA)
SHOCK/GAMEDATA/          optional, Future Shock
```

Launch it with full RAM: hold **R** while starting a game (title override), or
use a forwarder. The Album applet does not leave enough memory. The log is
`skynet_debug.log` in the same folder.

The wrapper passes `--gamedata=/switch/skynet_nx/GAMEDATA` to the game, because
its first-run folder picker is a native Android dialog that does not exist here.

### The game's own code (controller and gyro)

The APK's game code has no gamepad support (on Android it only uses the touch
overlay). The `gamepad-support` branch adds it. Because the official Godot
export templates refuse `--main-pack` and Android never looks for `<exe>.pck`,
the one way to get changed game scripts into the unmodified engine is to
replace `assets/assets.sparsepck` with a normal pack:

```
Godot_v4.7.2-stable --headless --path godot_project --export-pack "Android" out.pck
copy out.pck to /switch/skynet_nx/assets/assets.sparsepck
```

Use **Godot 4.7.2 stable (the same build as the APK's engine)** and export from
the **same revision of the game as the converted cache**. The game wipes and
rebuilds its cache (`CACHE_VERSION` in `asset_cache.gd`) when that number
differs: the v0.4.0 APK has 11 and current main has 12.

### config.txt

```
screen_width 1280
screen_height 720
deadzone 18          stick dead zone, percent
assetpack 1
enable_vulkan 1      0 = GL Compatibility instead
gyro 1               0 = motion sensors off
gyro_yaw 100         percent of 1:1, negative flips the direction
gyro_pitch 100
gyro_roll 100        the steering-wheel motion also turns the view
gyro_deadzone 0      thousandths of a rotation per second
gyro_drift 0         0 Loose, 1 Standard, 2 Tight
gyro_debug 0         1 = log the raw gyro axes
heapcheck 0          1 = diagnostic allocator (slower, more memory)
```

In the game: left stick move, right stick look (the gyro adds to it), ZR fire,
ZL throw, R / L next / previous weapon, B jump, Y crouch, A use, X next thrown
item, click L3 to turn running on and off, click R3 to turn the gyro on and off,
- automap, + menu.

## Build

Needs devkitA64, libnx >= 4.10 (new TLS ABI), `switch-zlib`, `switch-libexpat`
and a unified Mesa SDK (EGL, GLES2, Vulkan, `libmesa_util*`, `libxmlconfig`,
`libblake3`, `libcompiler`) unpacked so that
`mesa-sdk/opt/devkitpro/portlibs/switch/{include,lib}` exists next to the
Makefile. Build the SDK from
[danfromtico/mesa-switch](https://github.com/danfromtico/mesa-switch) with
`build-unified.sh` under MSYS2 MINGW64 (see
[StevensND/nfsmw-nx `docs/mesa.md`](https://github.com/StevensND/nfsmw-nx/blob/main/docs/mesa.md)
for the Rust and bindgen setup). Then run `make`.

## Fitting another engine build

`patch.c` fixes a null-pointer crash in `DisplayServerAndroid` at a fixed offset,
checked against the expected instruction before it is applied. It matches the
`libgodot_android.so` of SkyNET v0.4.0 only. For another build the first Data
Abort in the log prints `godot+0xADDR`; see the comment in `patch.c`.

## Credits and licence

MIT, see `LICENSE` and `THIRD_PARTY_NOTICES.md`. The icon is original artwork
made for this project.
