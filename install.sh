#!/bin/bash
# install.sh [--game-dir DIR] [--data-dir DIR] [--app-dir DIR] [--branch main|nightly] [--no-downloads] [--in-place]
#            [--depots DIR]
#
# Builds Tom Clancy's Ghost Recon natively for Apple Silicon from your own Steam copy and installs it as one app,
# "Ghost Recon.app" ("Ghost Recon Nightly.app" with --branch nightly), in ~/Applications. Its launch window has a card
# for the base campaign and each expansion (Desert Siege, Island Thunder): one recompiled GhostRecon.exe 1.4 plays all
# three; Play starts the chosen one in the same process (Game Mode stays on).
#
# Ghost Recon is Windows-only on Steam. Download the depots in Steam's console (steam://open/console):
#   download_depot 15300 15301     Ghost Recon
#   download_depot 13620 13621     Desert Siege (its Mods/Mp1)
#   download_depot 13630 13631     Island Thunder (its Mods/Mp2)
# They land under Steam's steamapps/content/app_<id>/depot_<id> (--depots: that content folder), where they are found.
# The game is copied into the data folder (--data-dir, default ~/Games/GhostReconNative: game-files/GhostRecon, an APFS
# clone, no extra space) and each expansion found is merged into it (Mods/Mp1, Mods/Mp2; readmes and manuals in Docs),
# also into an earlier import, so the depots can go afterwards. An import already there is used as it is.
# --game-dir names the GhostRecon folder (the one holding GhostRecon.exe) to import from instead of the depot.
# --in-place reads the game from where it is found and copies nothing: an expansion is then only played if its Mods
# folder is already in that game folder.
# Saves stay in the game's own Mods/Origmiss/Save; the launch window's choices in <data>/launcher.plist. The window's
# art comes from the Steam store pages (recomp/tools/gr_art.py, into <data>/art; --no-downloads draws plain colours);
# the app's icon is the game's own (Ghost.ico). The app's updater (Updates in the launch window) rebuilds it from the
# branch it follows. Needs clang and python3 (the Xcode command line tools); the recompiler installs capstone with pip
# into recomp/.venv.
#   development: --skip-build assembles the app from the last build in recomp/work/gr instead.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPOTS="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content"
GIVEN=""; DATA=""; APPS=""; NODL=""; U_BRANCH=main; IN_PLACE=""; SKIP_BUILD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) GIVEN="$2"; shift 2;;
    --data-dir) DATA="$2"; shift 2;;
    --app-dir) APPS="$2"; shift 2;;
    --branch) U_BRANCH="$2"; shift 2;;
    --depots) DEPOTS="$2"; shift 2;;
    --no-downloads) NODL=--no-downloads; shift;;
    --in-place) IN_PLACE=1; shift;;
    --skip-build) SKIP_BUILD=1; shift;;
    -h|--help) sed -n '2,26p' "$0" | cut -c3-; exit 0;;
    *) echo "unknown option $1 (see install.sh --help)"; exit 1;;
  esac
done
[[ "$U_BRANCH" == main || "$U_BRANCH" == nightly ]] || { echo "--branch must be main or nightly"; exit 1; }
[[ $(uname -s) == Darwin ]] || { echo "the Ghost Recon port is macOS only for now"; exit 1; }
DATA="${DATA:-$HOME/Games/GhostReconNative}"; mkdir -p "$DATA"; DATA="$(cd "$DATA" && pwd)"
IMPORTED="$DATA/game-files/GhostRecon"
BASE_DEPOT="$DEPOTS/app_15300/depot_15301"
copy() { cp -cR "$1" "$2" 2>/dev/null || cp -R "$1" "$2"; }   # an APFS clone where it can be

# ---------------------------------------------------------------- the game: given, imported, or the depot
if [ -n "$GIVEN" ]; then
  [ -f "$GIVEN/GhostRecon.exe" ] || { echo "no GhostRecon.exe in $GIVEN"; exit 1; }
  GAME="$(cd "$GIVEN" && pwd)"
elif [ -f "$IMPORTED/GhostRecon.exe" ]; then GAME="$IMPORTED"
elif [ -f "$BASE_DEPOT/GhostRecon.exe" ]; then GAME="$BASE_DEPOT"
else
  echo "no Ghost Recon found: not in $IMPORTED nor in $BASE_DEPOT"
  echo "download it in Steam's console (steam://open/console): download_depot 15300 15301 (or use --game-dir)"; exit 1
fi
echo "== Ghost Recon: $GAME"
if [ -z "$IN_PLACE" ] && [ "$GAME" != "$IMPORTED" ]; then
  if [ -f "$IMPORTED/GhostRecon.exe" ]; then
    echo "== $IMPORTED is already there: used as it is (move it away to import $GAME again)"
  else
    echo "== copying Ghost Recon from $GAME into $IMPORTED"
    mkdir -p "$DATA/game-files"; rm -rf "$IMPORTED.part"; copy "$GAME" "$IMPORTED.part"
    mv "$IMPORTED.part" "$IMPORTED"
    echo "== Ghost Recon is read from $IMPORTED: $GAME is no longer needed (delete it to free the space)"
  fi
  GAME="$IMPORTED"
fi
# the expansions: each depot's Mods/<MpN> merged into the game's Mods (they don't overlap), its readme and manual
# into Docs/ (as Steam installs them)
for x in "13620 13621 Mp1 Desert Siege" "13630 13631 Mp2 Island Thunder"; do
  set -- $x; APP=$1; DEP=$2; MOD=$3; shift 3; XNAME="$*"; D="$DEPOTS/app_$APP/depot_$DEP"
  if [ -d "$GAME/Mods/$MOD" ]; then echo "== $XNAME: $GAME/Mods/$MOD"; continue; fi
  if [ ! -d "$D/Mods/$MOD" ]; then echo "== $XNAME: not found (download_depot $APP $DEP in Steam's console): its card stays dimmed"; continue; fi
  if [ -n "$IN_PLACE" ]; then echo "== $XNAME: found in $D, but --in-place copies nothing: merge $D/Mods/$MOD into $GAME/Mods to play it"; continue; fi
  echo "== $XNAME: merging $D/Mods/$MOD into $GAME/Mods"
  rm -rf "$GAME/Mods/$MOD.part"; copy "$D/Mods/$MOD" "$GAME/Mods/$MOD.part"; mv "$GAME/Mods/$MOD.part" "$GAME/Mods/$MOD"
  mkdir -p "$GAME/Docs"
  for f in "$D"/*.txt "$D"/*.pdf; do
    if [ -f "$f" ] && [ ! -e "$GAME/Docs/$(basename "$f")" ]; then copy "$f" "$GAME/Docs/"; fi
  done
done

# ---------------------------------------------------------------- the build
OUT="$HERE/recomp/work/gr"
if [ -z "$SKIP_BUILD" ]; then
  echo "== recompiling Ghost Recon from $GAME (around fifteen minutes)"
  "$HERE/recomp/build_gr.sh" "$GAME" "$OUT"
fi
[ -x "$OUT/app/GhostRecon" ] && [ -f "$OUT/GhostRecon.exe" ] || { echo "== the build made no $OUT/app/GhostRecon"; exit 1; }

# ---------------------------------------------------------------- the app: staged beside, then swapped in
NAME="Ghost Recon"; ID=com.joshspeakman.ghost-recon
[[ "$U_BRANCH" == nightly ]] && { NAME="$NAME Nightly"; ID=$ID-nightly; }
APPS="${APPS:-$HOME/Applications}"; mkdir -p "$APPS"; APPS="$(cd "$APPS" && pwd)"; A="$APPS/$NAME.app"
U_BUILT="$(git -C "$HERE" rev-parse HEAD 2>/dev/null || true)"
echo "== installing $A"
STAGE="$HERE/build/stage/$NAME.app"; rm -rf "$STAGE"; mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
clang -O2 -fobjc-arc -Wall -DGR_LAUNCHER_APP -framework Cocoa -o "$STAGE/Contents/MacOS/GhostReconLauncher" "$HERE/recomp/host/gr_launcher.m"
cp "$OUT/app/GhostRecon" "$STAGE/Contents/MacOS/"
for f in shaders.metal dsr_snapshot.bin; do cp "$OUT/app/$f" "$STAGE/Contents/MacOS/"; done
cp "$OUT/GhostRecon.exe" "$STAGE/Contents/Resources/"          # the unwrapped executable: your copy, this Mac only
# launch.plist: the folders, for the launch window and for the game opened on its own (main.m bundle_launch)
P="$STAGE/Contents/Resources/launch.plist"; plutil -create xml1 "$P"
plutil -insert game -string "$GAME" "$P"; plutil -insert data -string "$DATA" "$P"
plutil -insert exe -string GhostRecon.exe "$P"; plutil -insert bin -string GhostRecon "$P"; plutil -insert log -string GhostRecon "$P"
plutil -insert branch -string "$U_BRANCH" "$P"; plutil -insert built -string "$U_BUILT" "$P"
# the launch window's art (tools/gr_art.py) for all three campaigns, installed or not (a card shows it either way)
for g in gr ds it; do
  if python3 -I "$HERE/recomp/tools/gr_art.py" $g "$DATA/art/$g" $NODL >/dev/null 2>&1 && ls "$DATA/art/$g/"*.jpg >/dev/null 2>&1; then
    mkdir -p "$STAGE/Contents/Resources/art/$g"; cp "$DATA/art/$g/hero.jpg" "$DATA/art/$g/shot1.jpg" "$STAGE/Contents/Resources/art/$g/" 2>/dev/null || true
  else echo "   (no art for the $g card: the launch window draws plain colours)"; fi
done
# the icon: the game's own Ghost.ico, else the executable's
I="$(mktemp -d)"
if { [ -f "$GAME/Ghost.ico" ] && cp "$GAME/Ghost.ico" "$I/g.ico"; } || python3 "$HERE/recomp/tools/extract_icon.py" "$OUT/GhostRecon.exe" "$I/g.ico" 2>/dev/null; then
  if sips -s format png "$I/g.ico" --out "$I/g.png" >/dev/null 2>&1; then
    sips -z 512 512 "$I/g.png" --out "$I/g512.png" >/dev/null 2>&1 && sips -s format icns "$I/g512.png" --out "$STAGE/Contents/Resources/icon.icns" >/dev/null 2>&1 || true
  fi
fi
rm -rf "$I"; [ -f "$STAGE/Contents/Resources/icon.icns" ] || echo "   (no icon could be made from Ghost.ico or the executable)"
# updates from the launch window: the commit this app was built from and the checkout it was installed from; the
# updater rebuilds the app (from the game folder it was installed from) from the branch it follows
U_WORK=stable; [[ "$U_BRANCH" == nightly ]] && U_WORK=nightly
U_REPO="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"; U_REPO="${U_REPO%/.git}"
if [ -n "$U_REPO" ] && [ -n "$U_BUILT" ] && git -C "$U_REPO" remote get-url origin >/dev/null 2>&1; then
  U_ARGS="--game-dir $(printf '%q' "$GAME") --data-dir $(printf '%q' "$DATA") --app-dir $(printf '%q' "$APPS") --branch $U_BRANCH"
  [ -n "$IN_PLACE" ] && U_ARGS="$U_ARGS --in-place"
  [ -n "$NODL" ] && U_ARGS="$U_ARGS $NODL"
  cat > "$STAGE/Contents/MacOS/update" <<UPDATE
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
exec "\$W/install.sh" $U_ARGS
UPDATE
  chmod +x "$STAGE/Contents/MacOS/update"
fi
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>GhostReconLauncher</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${U_BUILT:0:7}</string>
  <key>CFBundleVersion</key><string>${U_BUILT:0:7}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>
  <key>GCSupportsGameMode</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>GRBranch</key><string>$U_BRANCH</string>
  <key>GRBuilt</key><string>$U_BUILT</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$STAGE" >/dev/null 2>&1 || true
rm -rf "$A"; mv "$STAGE" "$A"
touch "$A"                                                    # Finder and the Dock pick up the new icon
C=""; for m in Mp1:"Desert Siege" Mp2:"Island Thunder"; do if [ -d "$GAME/Mods/${m%%:*}" ]; then C="$C, ${m#*:}"; fi; done
echo "== done: $A (Ghost Recon$C; game $GAME, data $DATA)"
