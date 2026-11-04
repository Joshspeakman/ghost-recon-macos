# Grand Theft Auto III, native for Apple Silicon

Rockstar's **Grand Theft Auto III** (2001), statically recompiled from your own Steam copy into native arm64 code: no
Wine, no Rosetta, no emulator. It uses the same recompiler and runtime as the author's Dungeon Siege, Delta Force,
Diablo II, Fallout: New Vegas and Sims ports, with a Direct3D 8 layer on its Metal renderer.

The Mac release on Steam (app 12230) is the Windows game inside TransGaming's Cider wrapper, a 32-bit Intel program
that no longer runs on current macOS. This port takes the `gta3.exe` from inside it.

Nothing from the game is in this repository. `./install.sh` imports your copy into `~/Games/GTA3Native/game-files`
(an APFS clone: no extra space), undoes the Steam wrapper on a copy in the build folder, recompiles that copy and
installs an app.

## State

**In development.** The game starts on Metal; see [docs/GTA3-PORT.md](docs/GTA3-PORT.md) for what works.

| Part | State |
|---|---|
| Recompilation | `gta3.exe` 1.1 (Steam, 2010): 20,593 functions lifted, including RenderWare's `_rwcseg` |
| Graphics | Direct3D 8 on the Direct3D 9 → Metal layer (fixed function) |
| Sound | Miles Sound System on Core Audio (raw PCM effects, 3D samples, radio streams) |
| Input | DirectInput 8 keyboard and mouse |
| Movies | not yet (MPEG-1) |

## Building

```sh
recomp/build_gta3.sh "<GTAIII folder>"     # -> recomp/work/gta3
```

The GTAIII folder is `Grand Theft Auto 3.app/Contents/Resources/transgaming/c_drive/Program Files/Rockstar Games/GTAIII`
inside the Steam app. Needs the Xcode command line tools and Python 3.
