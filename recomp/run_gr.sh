#!/bin/bash
# run_gr.sh [script] : development run of the recompiled game in test mode (no launch window, muted, background
# window). The script is DS_SCRIPT ("<frame>:shot:<png>;<frame>:key:<vk>;..."). Log: $GR_LOG or /dev/stderr.
HERE="$(cd "$(dirname "$0")" && pwd)"; W="$HERE/work/gr"
GAME="${GR_GAME:-$HOME/Games/GhostReconNative/game-files/GhostRecon}"; DATA="${GR_DATA:-$HOME/Games/GhostReconNative}"
DS_TEST=1 DS_NO_LAUNCHER=1 W32_AUDIO_MUTE=${W32_AUDIO_MUTE-1} DS_SCRIPT="${1:-}" exec "$W/app/GhostRecon" --exe "$W/GhostRecon.exe" --game "$GAME" --data "$DATA"
