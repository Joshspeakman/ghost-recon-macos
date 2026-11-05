# Ghost Recon, native for Apple Silicon

Red Storm's **Tom Clancy's Ghost Recon** (2001) and its expansions **Desert Siege** and **Island Thunder**,
statically recompiled from your own Steam copies into native arm64 code: no Wine, no Rosetta, no emulator. It uses
the same recompiler and runtime as the author's Rainbow Six, Delta Force, GTA Classics, Dungeon Siege and Fallout:
New Vegas ports, with the Direct3D 8 layer (from GTA Classics) on its Metal renderer.

Ghost Recon on Steam (app 15300) is Windows-only. The expansions (Desert Siege 13620, Island Thunder 13630) are mod
folders (`Mods/Mp1`, `Mods/Mp2`) for the same `GhostRecon.exe` 1.4, so one recompiled program plays all three.

Nothing from the games is in this repository. `./install.sh` imports your copies into
`~/Games/GhostReconNative/game-files` (an APFS clone: no extra space), undoes the Steam wrapper (SteamStub 2.0) on a
copy in the build folder, recompiles that copy and installs one app, **Ghost Recon**, with a card for the base game
and each expansion.

## Getting the game files

Steam on macOS won't install Windows-only games, but its console downloads their depots. Open
`steam://open/console` and run:

```
download_depot 15300 15301
download_depot 13620 13621
download_depot 13630 13631
```

They land in Steam's `steamapps/content/app_<id>/depot_<id>` folders, where `./install.sh` finds them.

## State

**In development.** See [docs/GR-PORT.md](docs/GR-PORT.md) for what works.

| Part | State |
|---|---|
| Steam wrapper | SteamStub 2.0 (`recomp/tools/steamstub20.py`), undone on a local copy at build time |
| Recompilation | `GhostRecon.exe` 1.4 (Steam) |
| Graphics | Direct3D 8 on the Direct3D 9 → Metal layer (fixed function) |
| Sound | DirectSound |
| Input | DirectInput 8 |
| Movies | MS-MPEG-4 v2 / Indeo 3.2 AVIs: not decoded yet (skipped) |

## Building by hand

```sh
recomp/build_gr.sh ~/Games/GhostReconNative/game-files/GhostRecon      # -> recomp/work/gr/app/GhostRecon
```

See [recomp/README.md](recomp/README.md) for the recompiler, the runtime and the test switches.

This repository was forked from gta-classics-macos (which came from delta-force-macos and the Dungeon Siege II port);
the runtime still carries modules of those ports.
