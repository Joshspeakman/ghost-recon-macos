# Recompiler: Ghost Recon as native code

Static recompilation of the user's own Steam `GhostRecon.exe` 1.4 into C, compiled for Apple Silicon. The same program
plays Ghost Recon, Desert Siege and Island Thunder (the expansions are mod folders for it). Nothing derived from the
game is committed: `build_gr.sh` regenerates everything locally from the user's files, in `work/` (ignored by git).

Installing and playing: [README](../README.md). What was specific to this game, the runtime changes it needed and how
each part was checked: [docs/GR-PORT.md](../docs/GR-PORT.md).

```sh
recomp/build_gr.sh ~/Games/GhostReconNative/game-files/GhostRecon     # -> recomp/work/gr
recomp/run_gr.sh                                                       # test mode
```

## The build

`build_gr.sh <GhostRecon folder> [outdir]`:

1. Checks `GhostRecon.exe`'s SHA-256 (Steam app 15300, depot 15301, version 1.4 only).
2. Sets up `recomp/.venv` the first time (Capstone, and Unicorn for the tests).
3. Undoes SteamStub 2.0 on a copy in the build folder (`tools/steamstub20.py`). The original stays untouched.
4. **Analysis** (`tools/analyze.py`): finds every function, jump table and SEH scope (40,045 functions).
5. **Lifting** (`tools/lift.py --game gr`): one C function per original function, in `lift_*.c`. Then
   `tools/link_tables.py` builds the address → function table.
6. **Compiling**: the lifted C in parallel (`GR_BUILD_JOBS`, default all cores) through `tools/cc1.sh`.
7. **Runtime and link** (`tools/build_runtime.sh`): the Win32 runtime (`runtime/`), the Metal renderer
   (`../src/renderer`) and the Mac host (`host/main.m`, `host/gr_launcher.m`), into `work/gr/app/GhostRecon`.

`GR_RELINK=1` keeps the lifted objects and redoes only step 7, for runtime, renderer or host changes (a minute
instead of a quarter of an hour). `../install.sh` runs all of this and assembles the app bundle around the result.

## Layout

| | |
|---|---|
| `tools/` | the recompiler (`analyze.py`, `lift.py`, `link_tables.py`), SteamStub (`steamstub20.py`), build and app scripts, `gr_art.py` (launch-window art from the Steam store pages) |
| `runtime/` | the execution core (`rt.c`, `rt.h`: memory, x87, flags, calls) |
| `runtime/win32/` | the Windows the game sees: kernel32 and user32 (files, threads, events, messages), Direct3D 8 (`d3d8.inc`) on the Direct3D 9 layer (`d3d9.c`), DirectSound (`dsound.c`), DirectInput 8 (`dinput8.c`), Winsock (`winsock.c`, `net_ole.c`), SEH (`seh.c`), crash reports (`crash.c`), and `gr_imports.c` for the few calls only Ghost Recon makes |
| `../src/renderer/` | the Metal renderer the Direct3D layer drives (`renderer.m`, `shaders.metal`) |
| `host/` | the Mac app: window, input, sound output, test scripting (`main.m`), and the launch window (`gr_launcher.m`) |
| `tests/` | instruction harnesses and runtime unit tests inherited from the earlier ports |
| `third_party/` | MojoShader, minimp3, Vulkan headers (see [NOTICE.md](../NOTICE.md)) |

## Testing and debugging

`run_gr.sh ["<script>"]` runs the last build in **test mode**: a background window that never takes the mouse, sound
muted, no launch window. It reads `GR_GAME` (game folder) and `GR_DATA` (data folder) and passes on everything else
below.

| Switch | Effect |
|---|---|
| `DS_TEST=1` | test mode (`run_gr.sh` sets it, with `DS_NO_LAUNCHER=1` and `W32_AUDIO_MUTE=1`) |
| `GR_CAMPAIGN=gr\|ds\|it` | which campaign's mod set (`modsset.txt`) to start with |
| `GTA_MODE=WxH` | the mission resolution, written into `options.xml` (the launch window's Resolution) |
| `DS_SCRIPT="<frame>:<action>;…"` | input at given frames |
| `DS_CMDFILE=<file>` | input appended to a file while the game runs (one action per line) |
| `W32_AUDIO_MUTE=0` | sound on in test mode (for sound bugs) |
| `DS_LOG_FILE=<file>` | the host's log to a file |

Script actions (`host/main.m`): `dimove:x,y` (DirectInput mouse movement in mickeys; 1 mickey = 1 menu pixel),
`click:x,y`, `rclick:x,y`, `dclick:x,y`, `key:vk`, `hold:vk,frames`, `type:text`, `shot:<png>` (the game's own
picture, so screenshots work with the window hidden). The game draws its own cursor from DirectInput, so a reliable
click is `dimove:-3000,-3000` (pin it to the corner), `dimove:x,y`, about a second's wait (buttons need hover), then
`click:x,y`. Menu coordinates are listed in [docs/GR-PORT.md](../docs/GR-PORT.md#testing).

Logs and test switches:

| Switch | Shows or changes |
|---|---|
| `W32_TRACE=<file>` | every Windows call |
| `W32_SEHLOG=1` | exceptions and the SEH chain each one walks |
| `W32_REGLOG=1` | registry keys the game asks for that aren't there |
| `W32_AUDIOLOG=1`, `W32_DSLOG=1` | the sound mix; DirectSound buffers, including each `SetVolume` |
| `W32_DILOG=1` | DirectInput |
| `W32_NETLOG=1` | sockets: create, bind (and the fallback to any address), connect, accept, traffic |
| `W32_NETVIRT=k` | copy *k* of several on one Mac: its own loopback address 127.0.0.*k* and port range, so two copies can host and join each other |
| `DSR_DRAWLOG=1` | each kind of draw once: FVF, texture stages (including the texture-coordinate index), lighting |
| `D3D9_CREATELOG=1` | device creation, with the behaviour flags and the x87 control word afterwards |
| `DSR_ANISO=n` | anisotropic filtering for mipmapped textures (default 16; 1 is off) |
| `DSR_VSYNC=0` | no VSync |
| `W32_NO_FPUSETUP=1` | Direct3D leaves the x87 precision alone (Windows lowers it; this brings back the old mipmap crash) |

Crash and hang reports go to `<data>/CrashReports`. The app shows the newest one the next time it opens.

## Execution model

- **Memory:** one 4 GB host region; guest address = offset. The image sits at its preferred base `0x400000`, so all
  pointers the game stores (vtables, saves, its own structures) keep their 32-bit values.
- **Functions:** one C function per original function. Registers are C locals, written back to a per-thread context
  around calls. The guest stack is real (`call` pushes the original return address; arguments are read where the
  original reads them), so calling conventions, `this` pointers and stack-walking code behave as before.
- **Flags:** lazy. Flag-setting instructions record their operands, and consumers (`jcc`, `setcc`, `adc`, `sahf` …)
  compute only the flags they need.
- **x87:** eight doubles, TOP, and the control and status words.
  - Arithmetic is done in double precision, with float rounding at 32-bit stores, and `fist(p)` honours the rounding
    mode.
  - When the precision control says single (which Direct3D's `CreateDevice` sets, as on Windows), add, subtract,
    multiply, divide and square root results are rounded to 24 bits (`rt_pc` in `rt.h`). Ghost Recon's
    power-of-two test depends on that.
  - x87 register forms are decoded from the opcode bytes (Intel semantics), not from disassembler text.
- **Indirect calls and jumps:** an address → function table. Jump tables become `switch` statements. Imports are
  dispatched through `rt_import` (IAT slots hold thunk addresses, so a call through a register still lands there).
- Junk decodes (data read as code) and padding become `rt_unhandled()` traps.

## Verification and known gaps

The instruction-level harness (`tests/harness.py`, `tests/fuzz_insn.py`, `tests/test_slice.py`) comes from the
Dungeon Siege 1 port, where every instruction form the game used was checked bit for bit against Unicorn.
`tests/replay.py` runs one call through the original x86 and the recompiled code from a snapshot and compares them.
The game itself is checked by playing it: [docs/GR-PORT.md](../docs/GR-PORT.md#state) lists what has been.

- **SEH:** access violations and `RaiseException` go through the game's handlers. C++ catch continuations are not
  implemented, and the game has not needed them so far.
- **Indirect calls** to addresses outside the function table stop the game with the address logged (add it as a
  seed in `work/gr/observed_targets.json` and rebuild).
- **x87 tag word** is not modelled; transcendentals use the host math library.
- **Movies:** the AVIs (MS-MPEG-4 v2, Indeo 3.2) have no decoder yet, so DirectShow reports them finished at once.
