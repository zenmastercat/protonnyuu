#!/usr/bin/env bash
# Install a built protonnyuu into Steam's compatibilitytools.d.
#
# Usage: scripts/install.sh [build-dir]
#   build-dir is the unpacked build (<build>/protonnyuu-<version>) and
#   defaults to the last successful scripts/build.sh output
#   (~/.cache/protonnyuu/last-build).
# Restart Steam afterwards, then pick it under a game's
# Properties > Compatibility.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TAG=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$ROOT/upstream.json")
[[ $TAG =~ ^dwproton-[0-9]+\.[0-9]+-[0-9]+$ ]] || { echo "error: bad tag in upstream.json: $TAG" >&2; exit 1; }
NAME="protonnyuu-${TAG#dwproton-}"
LAST="$HOME/.cache/protonnyuu/last-build"
if [[ $# -ge 1 ]]; then
  REDIST=$1
elif [[ -f $LAST ]]; then
  REDIST=$(<"$LAST")
else
  echo "error: no build found (run scripts/build.sh first)" >&2
  exit 1
fi
STEAM=${STEAM_DIR:-$HOME/.local/share/Steam}
DEST="$STEAM/compatibilitytools.d/$NAME"

[[ -f $REDIST/proton && -f $REDIST/compatibilitytool.vdf ]] || {
  echo "error: no built Proton in $REDIST (run scripts/build.sh first)" >&2
  exit 1
}
grep -qF "\"$NAME\"" "$REDIST/compatibilitytool.vdf" || {
  echo "error: $REDIST is not a build of $NAME" >&2
  exit 1
}
mkdir -p "$STEAM/compatibilitytools.d"
TMP=$(mktemp -d "$STEAM/compatibilitytools.d/.$NAME.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cp -a "$REDIST/." "$TMP/"
rm -rf "$DEST"
mv "$TMP" "$DEST"
trap - EXIT
echo "installed $NAME to $DEST"
echo "restart Steam, then choose \"$NAME\" in the game's Properties > Compatibility"
