#!/bin/bash
# build_gr.sh <GhostRecon folder> [outdir]
# Recompile the user's own Steam copy of Tom Clancy's Ghost Recon (Steam app 15300, depot 15301: GhostRecon.exe 1.4,
# which also runs Desert Siege and Island Thunder, apps 13620/13630, installed as Mods/Mp1 and Mods/Mp2) into C and
# link it with the native runtime (tools/build_runtime.sh). The Steam wrapper (SteamStub 2.0) is undone on a copy in
# the build folder (tools/steamstub20.py); everything generated stays local (work/ is ignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME="$(cd "${1:?usage: build_gr.sh <GhostRecon folder> [outdir]}" && pwd)"
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
EXE_NAME=GhostRecon.exe; SHA=41ffcc70a97a3146386c71e5d1145dd5c939a1a974a247ce47ba3ffb88e16c15   # Steam 15300 depot 15301, 1.4
[ -f "$GAME/$EXE_NAME" ] || { echo "no GhostRecon.exe in $GAME"; exit 1; }
[ "$(sha "$GAME/$EXE_NAME")" = "$SHA" ] || { echo "not the supported Steam GhostRecon.exe (1.4, Steam 15300)"; exit 1; }
OUT="${2:-$HERE/work/gr}"
PY="$HERE/.venv/bin/python"
[ -x "$PY" ] || { python3 -m venv "$HERE/.venv" && "$HERE/.venv/bin/pip" install -q capstone==5.0.7 unicorn==2.1.4; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
python3 "$HERE/tools/compiler_compat.py" "${CC:-clang}" "$OUT/compiler-flags.txt"
"$PY" "$HERE/tools/steamstub20.py" "$GAME/$EXE_NAME" "$OUT/$EXE_NAME"; EXE="$OUT/$EXE_NAME"
if [[ -n "${GR_RELINK:-}" && -d "$OUT/obj" ]]; then              # runtime changes only: keep the lifted objects
  echo "== runtime and link (GR_RELINK)"; exec "$HERE/tools/build_runtime.sh" "$OUT"
fi
echo "== analysis"
"$PY" "$HERE/tools/analyze.py" "$EXE" "$OUT/analysis.json" > "$OUT/analysis.log"
sed -n '/^functions /p; /^decode failures:/p; /^jump tables /p; /^SEH:/p' "$OUT/analysis.log"
echo "== lifting"
"$PY" "$HERE/tools/lift.py" "$EXE" "$OUT/analysis.json" "$OUT" --game gr | grep -Ev '^unsupported: \{\}$'
"$PY" "$HERE/tools/link_tables.py" "$OUT" "="
echo "== compiling"
rm -rf "$OUT/obj"; mkdir -p "$OUT/obj"
JOBS="${GR_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
printf '%s\n' "$OUT"/lift_*.c "$OUT/fntab.c" | xargs -n 1 -P "$JOBS" "$HERE/tools/cc1.sh" "$OUT"
echo "== $(ls "$OUT/obj" | wc -l | tr -d ' ') object files; runtime and link"
"$HERE/tools/build_runtime.sh" "$OUT"
