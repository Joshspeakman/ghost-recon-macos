# Ghost Recon port notes

What was specific to Ghost Recon, what works, and how to test it. The recompiler and runtime are the ones described
in [recomp/README.md](../recomp/README.md) (inherited from gta-classics-macos → delta-force-macos → Dungeon Siege II).

## The executable

- `GhostRecon.exe` 1.4 from Steam (app 15300, depot 15301), sha256 `41ffcc70…` (checked by `recomp/build_gr.sh`).
- Steam wrapper: **SteamStub 2.0**, the oldest variant: the stub copies its header out of `.bind` (`mov esi, <header>`,
  `mov ecx, <dwords>`, `rep movsd`), undoes the header's XOR chain, then the code section's (same chain, key at
  header+0x38). `recomp/tools/steamstub20.py` does that on a copy in `recomp/work/gr`; the original entry point is
  0x6f3d14 (MSVC CRT). `drvmgt.dll`/`secdrv.sys` in the depot are SafeDisc leftovers the Steam exe doesn't use.
- 40,045 functions lifted, no internal errors.
- Imports: Direct3D 8, DirectSound (by ordinal: #1 Create, #2 EnumerateA, #11 Create8), DirectInput 8, WSOCK32,
  DBGHELP (crash handler stack walk), ole32 (DirectShow for the AVI movies).

## The expansions

Desert Siege (13620/13621) and Island Thunder (13630/13631) are mod folders, `Mods/Mp1` and `Mods/Mp2`, for the same
exe. The game reads its active mods from `modsset.txt` (written by Options > Mods):

```
// MODS SETTINGS - LIST OF MODS ACTIVE ON THIS SYSTEM
"\mods\mp1"
```

The launch window's cards set `GR_CAMPAIGN=gr|ds|it`; `host/main.m` (`gr_prepare`) writes `<data>/game/modsset.txt`
with no mods, `\mods\mp1` or `\mods\mp2` before the game starts. Each then opens with its own shell art and campaign
set. Without the file every mod is active (Island Thunder's shell).

## Settings and saves

The game writes into its own folder; the runtime sends those writes to `<data>/game` (game-files stays pristine):
`options.xml`, `modsset.txt`, `Ike.log` (the game's log), `IkeCrash.log`, `unlocked_*.xml`, and saves under
`data/save` and `mods/<mod>/save` (campaigns `*.csf_bin`, checkpoints, replays). `GTA_MODE=WxH` (the launch window's
Resolution) rewrites `options.xml`'s `VideoResolution` (32-bit); the menus always run at 640x480, missions at the
chosen mode.

## Runtime changes for this game

- Direct3D 8 caps: `D3DCAPS2_CANRENDERWINDOWED` (dropped in Direct3D 9; Ghost Recon lists only adapters with it).
- DirectSound: `IDirectSoundNotify` (the music/voice streams wait on notification events, set from the render
  callback as the play cursor passes them).
- Direct3D 8 `CreateDevice` puts the calling thread's x87 in single precision (round to nearest, exceptions masked)
  unless `D3DCREATE_FPU_PRESERVE`, as Windows does (Ghost Recon passes 0x44). The game's power-of-two test is
  `trunc(ln(n) * 1/ln2) == log2(n)`: in double precision 8, 64 and 128 come out a hair under (6.999…), so with
  mipmapping on a 256x128 image (character/allied/head.rsb) was taken for a non-power of two, got no mip images and
  the copy read from address 0. `W32_NO_FPUSETUP=1` skips it (test switch, as for DirectDraw).
- DirectInput 8 is fed by the Mac host (mouse motion, buttons, wheel, keys); it was only fed on Linux before.
- Renderer (from gta-classics f270d68): Direct3D vertex lighting (characters, props: FVF with normals, lighting on)
  and per-stage texture-coordinate sets. Terrain is FVF `0x242` (two sets): stage 0 the map's colour layer on set 0,
  stage 1 the tiling detail on set 1 (`D3DTSS_TEXCOORDINDEX` 1); with only set 0 the detail was smeared over the whole
  map and the ground looked flat brown. `DSR_DRAWLOG=1` lists each kind of draw once.

## Testing

`recomp/run_gr.sh "<script>"` runs in test mode (background window, muted, no launch window); `GR_CAMPAIGN`,
`GTA_MODE`, `GR_DATA`, `GR_GAME` are passed through. Script actions (`host/main.m`): `dimove:x,y` (DirectInput
mickeys; 1 mickey = 1 menu pixel), `click:x,y`, `dclick:x,y`, `key:vk`, `hold:vk,frames`, `type:text`,
`shot:png`. The game draws its own cursor from DirectInput, so a click is: `dimove:-3000,-3000` (pin to the corner),
`dimove:x,y`, wait about a second (buttons need hover), `click:x,y`. Menu coordinates (640x480): Training 130,268;
Campaign 130,291; Quick Mission 130,314; Options 130,383; New Campaign 103,208; Start 333,442; next (>) 537,462;
Auto Assign 122,89. Escape in Training ends it.

## State (2026-11-04)

| | |
|---|---|
| Ghost Recon | menus, Training (obstacle course: walk, look), campaign/quick mission screens |
| Desert Siege | new campaign → D01 Burning Sands in game, firing works |
| Island Thunder | new campaign → C01 intro flyover in game |
| Sound | music, effects and briefing voice play (DirectSound, EAX not offered) |
| Movies | **skipped**: MS-MPEG-4 v2 (MP42) and Indeo 3.2 (IV32) AVIs, no decoder in the runtime yet |
| Multiplayer | not tested |
| Mipmapping option | works (on for new installs); the game's MipMapLODBias is not applied by the renderer yet |

Known cosmetic leftovers: the guest install path is `C:\GOG Games\Dungeon Siege` (shows in `IkeCrash.log`), log
lines say `DungeonSiegeNative:`.
