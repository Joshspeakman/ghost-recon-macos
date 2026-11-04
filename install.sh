#!/bin/bash
# install.sh --game-dir <GTAIII folder> [--app-dir DIR] [--data-dir DIR] [--branch main|nightly] [--no-downloads] [--in-place]
#
# Builds the natively recompiled Grand Theft Auto III from your own Steam copy and installs it as "Grand Theft Auto
# III.app" ("Grand Theft Auto III Nightly.app" with --branch nightly) in ~/Applications. The game folder is the Mac
# Steam release's (app 12230): Grand Theft Auto 3.app/Contents/Resources/transgaming/c_drive/Program Files/Rockstar
# Games/GTAIII (the Windows gta3.exe inside TransGaming's wrapper), or a copy of it made by an earlier install.
# The game is copied into the data folder (default ~/Games/GTA3Native/game-files/GTAIII; an APFS clone, no extra space)
# with the radio and cutscene audio the wrapper keeps beside it (c_drive/Audio), so the Steam copy can go afterwards;
# --in-place reads the given folder instead. Saves and settings go to the data folder (drive_c/.../GTA3 User Files).
# The app opens with a launch window (display, notch, resolution, VSync, saves, updates); its art comes from the game's
# Steam store page (tools/gta3_art.py, into the data folder's art/; --no-downloads writes the title instead) and its
# icon is the Mac release's own. Needs clang and python3 (the Xcode command line tools); the recompiler installs
# capstone with pip into recomp/.venv.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME=""; APPS=""; DATA=""; NODL=""; U_BRANCH=main; IN_PLACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) GAME="$2"; shift 2;; --app-dir) APPS="$2"; shift 2;; --data-dir) DATA="$2"; shift 2;;
    --branch) U_BRANCH="$2"; shift 2;;
    --no-downloads) NODL=--no-downloads; shift;;
    --in-place) IN_PLACE=1; shift;;
    *) echo "unknown option $1"; exit 1;;
  esac
done
[[ "$U_BRANCH" == main || "$U_BRANCH" == nightly ]] || { echo "--branch must be main or nightly"; exit 1; }
[ -n "$GAME" ] || { echo "usage: install.sh --game-dir <the GTAIII folder>"; exit 1; }
[[ $(uname -s) == Darwin ]] || { echo "the GTA III port is macOS only for now"; exit 1; }
GAME="$(cd "$GAME" && pwd)"
[ -f "$GAME/gta3.exe" ] || { echo "$GAME has no gta3.exe"; exit 1; }
EXE=gta3.exe; BIN=GTA3; NAME="Grand Theft Auto III"; ID=com.joshspeakman.gta3
[[ "$U_BRANCH" == nightly ]] && { NAME="$NAME Nightly"; ID=$ID.nightly; }
DATA="${DATA:-$HOME/Games/GTA3Native}"; mkdir -p "$DATA"
# the Mac release's wrapper: the app bundle around the game folder (its icon) and the radio/cutscene audio (c_drive/Audio)
WRAP_RES="$(cd "$GAME/../../../../.." 2>/dev/null && pwd || true)"; WRAP_AUDIO="$(cd "$GAME/../../../Audio" 2>/dev/null && pwd || true)"
[ -f "$WRAP_RES/grandtheftauto3.icns" ] && { mkdir -p "$DATA/art"; cp "$WRAP_RES/grandtheftauto3.icns" "$DATA/art/icon.icns"; }

echo "== recompiling $NAME from $GAME (a few minutes)"
"$HERE/recomp/build_gta3.sh" "$GAME" "$HERE/recomp/work/gta3"
OUT="$HERE/recomp/work/gta3"
if [ -z "$IN_PLACE" ]; then case "$GAME/" in "$DATA"/*) ;; *)
  GF="$DATA/game-files/GTAIII"; echo "== copying the game from $GAME into $GF"
  mkdir -p "$DATA/game-files"; rm -rf "$GF.part"
  cp -cRL "$GAME" "$GF.part" 2>/dev/null || { rm -rf "$GF.part"; cp -RL "$GAME" "$GF.part"; }
  rm -rf "$GF"; mv "$GF.part" "$GF"
  echo "== the app reads the game from $GF: $GAME is no longer needed (delete it to free the space)"; GAME="$GF";;
esac; fi
# the radio stations and cutscene audio: the game asks for them on its "CD" (C:\Audio, mapped to the game's audio/)
if [ -n "$WRAP_AUDIO" ] && [ -f "$WRAP_AUDIO/HEAD.WAV" ] && [ ! -f "$GAME/audio/HEAD.WAV" ]; then
  echo "== copying the radio and cutscene audio from $WRAP_AUDIO"
  mkdir -p "$GAME/audio"; for f in "$WRAP_AUDIO"/*; do [ -e "$GAME/audio/$(basename "$f")" ] || cp -cRL "$f" "$GAME/audio/" 2>/dev/null || cp -RL "$f" "$GAME/audio/"; done
fi
[ -f "$GAME/audio/HEAD.WAV" ] || echo "   (no radio audio found: the game will ask for its second disc; copy c_drive/Audio into $GAME/audio)"
Q_GAME=$(printf '%q' "$GAME"); Q_DATA=$(printf '%q' "$DATA")      # shell-quoted: any folder name is only data

APPS="${APPS:-$HOME/Applications}"; A="$APPS/$NAME.app"; echo "== installing $A"
mkdir -p "$APPS"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp "$OUT/app/$BIN" "$OUT/app/shaders.metal" "$OUT/app/dsr_snapshot.bin" "$A/Contents/MacOS/"
cp "$OUT/$EXE" "$A/Contents/Resources/$EXE"                        # the unwrapped executable (your copy, this Mac only)
# updates from the launch window: the commit this app was built from and the checkout it was installed from; its
# updater keeps the chosen branch across rebuilds (game folder, data kept)
U_WORK=stable; [[ "$U_BRANCH" == nightly ]] && U_WORK=nightly
U_REPO="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"; U_REPO="${U_REPO%/.git}"
U_BUILT="$(git -C "$HERE" rev-parse HEAD 2>/dev/null || true)"
if [ -n "$U_REPO" ] && [ -n "$U_BUILT" ] && git -C "$U_REPO" remote get-url origin >/dev/null 2>&1; then
  cat > "$A/Contents/MacOS/update" <<UPDATE
#!/bin/bash
# $NAME updater (generated by install.sh): "update --check" prints the newest commit of $U_BRANCH on GitHub;
# "update" fetches it into a worktree of the checkout this app was installed from and rebuilds the app from it
set -euo pipefail
REPO=$(printf '%q' "$U_REPO"); BRANCH=$U_BRANCH; W="\$REPO/build/$U_WORK"
export GIT_TERMINAL_PROMPT=0 PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"   # never wait for a password prompt
# a private repository: git signs in through gh with the repository owner's account (gh's active one may differ)
OWNER="\$(git -C "\$REPO" remote get-url origin | sed -E 's#.*github.com[:/]([^/]+)/.*#\1#')"
[ -n "\${GH_TOKEN:-}" ] || GH_TOKEN="\$(gh auth token --user "\$OWNER" 2>/dev/null || true)"
[ -z "\$GH_TOKEN" ] || export GH_TOKEN
if [ "\${1:-}" = --check ]; then                          # GitHub's newest, unless this app already has it: a build
  R="\$(git -C "\$REPO" ls-remote origin "refs/heads/\$BRANCH" | cut -f1)"   # from a newer local commit is never offered an older one
  if [ -n "\$R" ] && git -C "\$REPO" merge-base --is-ancestor "\$R" $U_BUILT 2>/dev/null; then echo $U_BUILT; else echo "\$R"; fi
  exit 0
fi
echo "== fetching \$BRANCH from GitHub"
git -C "\$REPO" fetch -q origin "\$BRANCH"
git -C "\$REPO" worktree prune
if [ -e "\$W/.git" ]; then git -C "\$W" checkout -q -f --detach "origin/\$BRANCH"
else mkdir -p "\$REPO/build"; git -C "\$REPO" worktree add -q -f --detach "\$W" "origin/\$BRANCH"; fi
echo "== \$BRANCH: \$(git -C "\$W" log -1 --format='%h %s')"
[ -e "\$W/recomp/.venv" ] || [ ! -e "\$REPO/recomp/.venv" ] || ln -s "\$(readlink "\$REPO/recomp/.venv" 2>/dev/null || echo "\$REPO/recomp/.venv")" "\$W/recomp/.venv"   # share the tools
exec "\$W/install.sh" --game-dir $Q_GAME --data-dir $Q_DATA --app-dir $(printf '%q' "$APPS") --branch $U_BRANCH $NODL
UPDATE
  chmod +x "$A/Contents/MacOS/update"
fi
cat > "$A/Contents/MacOS/launcher" <<LAUNCH
#!/bin/bash
# $NAME launcher (generated by install.sh; for the terminal: the app itself opens $BIN with Resources/launch.plist)
GAME="\${DF_GAME_DIR:-$Q_GAME}"; DATA="\${DF_DATA_DIR:-$Q_DATA}"
mkdir -p "\$DATA"; L="\$DATA/$BIN.log"
[ -f "\$L" ] && [ "\$(stat -f %z "\$L")" -gt 5000000 ] && mv -f "\$L" "\$DATA/$BIN.old.log"
B="\$(cd "\$(dirname "\$0")" && pwd)"; export DS_LOG_FILE="\$L"
[ -x "\$B/update" ] && export DS_UPDATER="\$B/update" DS_UPDATE_BRANCH=$U_BRANCH DS_BUILT_COMMIT=$U_BUILT   # the launch window's Updates tile
exec "\$B/$BIN" --exe "\$B/../Resources/$EXE" --game "\$GAME" --data "\$DATA" 2>>"\$L"
LAUNCH
chmod +x "$A/Contents/MacOS/launcher"
# The app's executable is the game itself (macOS recognises a game, and turns on Game Mode, only for a bundle whose
# executable is the program): it reads these settings when opened from Finder (main.m bundle_launch)
P="$A/Contents/Resources/launch.plist"; plutil -create xml1 "$P"
plutil -insert game -string "$GAME" "$P"; plutil -insert data -string "$DATA" "$P"; plutil -insert log -string "$BIN" "$P"
plutil -insert exe -string "$EXE" "$P"; plutil -insert branch -string "$U_BRANCH" "$P"; plutil -insert built -string "$U_BUILT" "$P"
cat > "$A/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${U_BUILT:0:7}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>
  <key>GCSupportsGameMode</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# the launch window's art (tools/gta3_art.py): in the data folder, and a copy in the app
if python3 "$HERE/recomp/tools/gta3_art.py" "$DATA/art" $NODL >/dev/null 2>&1 && ls "$DATA/art/"*.jpg >/dev/null 2>&1; then
  echo "== the launch window's art: $(cd "$DATA/art" && ls | tr '\n' ' ')"
  mkdir -p "$A/Contents/Resources/art"; cp "$DATA/art/"*.jpg "$DATA/art/"*.png "$A/Contents/Resources/art/" 2>/dev/null || true
else echo "   (no art for the launch window: it writes the title)"; fi
# the icon: the Mac release's own (kept in the data folder's art/), else the Windows executable's
if [ -f "$DATA/art/icon.icns" ]; then cp "$DATA/art/icon.icns" "$A/Contents/Resources/icon.icns"
else
  I="$(mktemp -d)"
  if python3 "$HERE/recomp/tools/extract_icon.py" "$OUT/$EXE" "$I/g.ico" 2>/dev/null && sips -s format png "$I/g.ico" --out "$I/g.png" >/dev/null 2>&1; then
    sips -z 512 512 "$I/g.png" --out "$I/g512.png" >/dev/null && sips -s format icns "$I/g512.png" --out "$A/Contents/Resources/icon.icns" >/dev/null 2>&1 || true
  fi
  rm -rf "$I"
fi
codesign --force --deep --sign - "$A" >/dev/null 2>&1 || true
touch "$A"                                                    # Finder and the Dock pick up the new icon
echo "== done: $A (data in $DATA)"
