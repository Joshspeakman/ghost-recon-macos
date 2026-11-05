# Notices and credits

**Tom Clancy's Ghost Recon**, **Desert Siege** and **Island Thunder** © Red Storm Entertainment / Ubisoft. Tom
Clancy's is a trademark of Ubisoft. This project is not affiliated with or endorsed by either company, and it contains
no part of the games. The build recompiles the executable of a copy the user owns (bought on Steam), after verifying
its checksum. It undoes the Steam wrapper on a copy in the local build folder so the code can be read, and the app
reads the game's data from the user's copy. The recompiled program is for that user only.

The screenshots in `docs/screenshots` show the game running in this port, for illustration.

The launch window's art is downloaded at install time from the games' Steam store pages into the user's data folder
(`recomp/tools/gr_art.py`; `--no-downloads` leaves it out). None of it is in this repository.

This repository started from gta-classics-macos, which came from delta-force-macos and the Dungeon Siege II /
Fallout: New Vegas / The Sims recompiler. The Direct3D 8 layer and the renderer's fixed-function lighting come from
the GTA Classics port. No part of those games is included either.

Included:
- **Vulkan-Headers** (Apache-2.0 / MIT, The Khronos Group): `recomp/third_party/vulkan`, inherited from the Sims port.
- **MojoShader** (zlib), **minimp3** (CC0): `recomp/third_party`, inherited from the Fallout: New Vegas port.

Used at build time (installed into `recomp/.venv` with pip, not redistributed here):
- **Capstone** (BSD): disassembly for the recompiler. https://www.capstone-engine.org/
- **Unicorn** (GPL-2.0): x86 emulation, used only by the tests to compare the recompiled code with the original.
  https://www.unicorn-engine.org/

Prior work this project learned from:
- **Steamless** by atom0s (https://github.com/atom0s/Steamless) documents the SteamStub formats.
  `recomp/tools/steamstub20.py` (and `steamstub21.py`, from the Delta Force port) are independent implementations from
  those descriptions, not copies of its code.
- `src/dsr/dsr_snapshot.bin` records device capabilities reported by Wine's DirectDraw implementation (Wine, LGPL).
