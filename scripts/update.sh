#!/usr/bin/env bash
# Move protonnyuu to the newest DW-Proton release.
#
# Usage: scripts/update.sh [--build] [--install] [--commit] [--push]
#   (no flags)  only report whether a newer release exists
#   --build     build it (scripts/build.sh, which also checks the tag signature)
#   --install   install the build into Steam (implies --build)
#   --commit    commit the new upstream.json, only after a good build
#   --push      push that commit to origin main (implies --commit)
# upstream.json is restored if the build or install fails or the run is
# interrupted. A release that needs a different Proton SDK image is not built:
# it is reported as "needs-review" so its digest can be checked and pinned.
# The last stdout line is a JSON summary:
#   {"status": "up-to-date"|"available"|"needs-review"|"built"|"build-failed"|"error", ...}
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
API=https://dawn.wine/api/v1/repos/dawn-winery/dwproton
MIRROR_API=https://api.github.com/repos/dawn-winery/dwproton-mirror
LOGDIR="$HOME/.cache/protonnyuu"
CURL=(curl -fsS --proto '=https' --connect-timeout 10 --max-time 60 --retry 2)
DO_BUILD='' DO_INSTALL='' DO_COMMIT='' DO_PUSH=''
for a in "$@"; do
  case $a in
    --build) DO_BUILD=1 ;;
    --install) DO_INSTALL=1 DO_BUILD=1 ;;
    --commit) DO_COMMIT=1 ;;
    --push) DO_PUSH=1 DO_COMMIT=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

summary() { python3 -I -c 'import json,sys; print(json.dumps(dict(a.split("=",1) for a in sys.argv[1:])))' "$@"; }
field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
fail() { summary status=error "$@"; exit 1; }

OLD_TAG=$(field "$ROOT/upstream.json" tag)
OLD_SDK=$(field "$ROOT/upstream.json" sdkImage)

# Newest published (non-draft, non-prerelease) release.
NEW_TAG=$("${CURL[@]}" "$API/releases?limit=10" | python3 -I -c '
import json,sys
for r in json.load(sys.stdin):
    if not r["draft"] and not r["prerelease"]:
        print(r["tag_name"]); break') || NEW_TAG=
[[ $NEW_TAG =~ ^dwproton-[0-9]+\.[0-9]+-[0-9]+$ ]] || fail step=release-check "notes=could not read the newest DW-Proton release"

if [[ $NEW_TAG == "$OLD_TAG" ]]; then
  summary status=up-to-date "tag=$OLD_TAG"
  exit 0
fi

# Its commit and tag object on dawn.wine, cross-checked with the GitHub mirror.
read -r NEW_TAG_OBJECT NEW_COMMIT < <("${CURL[@]}" "$API/tags/$NEW_TAG" | python3 -I -c '
import json,sys; d=json.load(sys.stdin); print(d["id"], d["commit"]["sha"])' 2>/dev/null) || true
[[ ${NEW_COMMIT:-} =~ ^[0-9a-f]{40}$ && ${NEW_TAG_OBJECT:-} =~ ^[0-9a-f]{40}$ ]] \
  || fail step=tag-lookup "notes=could not read the commit of $NEW_TAG"
MIRROR_OBJECT=$("${CURL[@]}" "$MIRROR_API/git/ref/tags/$NEW_TAG" | python3 -I -c '
import json,sys; print(json.load(sys.stdin)["object"]["sha"])' 2>/dev/null) || MIRROR_OBJECT=
if [[ $MIRROR_OBJECT != "$NEW_TAG_OBJECT" ]]; then
  summary status=needs-review "previousTag=$OLD_TAG" "tag=$NEW_TAG" \
    "notes=the GitHub mirror does not have the same tag object yet (dawn.wine $NEW_TAG_OBJECT, mirror ${MIRROR_OBJECT:-none}); try again later"
  exit 0
fi

# The Proton SDK image this release wants.
NEW_SDK=$("${CURL[@]}" "$API/raw/Makefile.in?ref=$NEW_TAG" \
  | sed -n 's/^[[:space:]]*STEAMRT_IMAGE ?= \(registry[^[:space:]]*\/x86_64:[^[:space:]]*\)$/\1/p' | head -n1) || NEW_SDK=
[[ -n $NEW_SDK ]] || fail step=sdk-check "tag=$NEW_TAG" "notes=could not read the SDK image of $NEW_TAG"
if [[ $NEW_SDK != "$OLD_SDK" ]]; then
  summary status=needs-review "previousTag=$OLD_TAG" "tag=$NEW_TAG" "sdkImage=$NEW_SDK" \
    "notes=$NEW_TAG needs a new Proton SDK image; check it, then pin sdkImage and sdkDigest in upstream.json"
  exit 0
fi

if [[ -z $DO_BUILD ]]; then
  summary status=available "previousTag=$OLD_TAG" "tag=$NEW_TAG"
  exit 0
fi

# From here on, put upstream.json back unless the run reaches the commit.
cp "$ROOT/upstream.json" "$ROOT/upstream.json.bak"
restore() { [[ -f $ROOT/upstream.json.bak ]] && mv "$ROOT/upstream.json.bak" "$ROOT/upstream.json"; }
trap restore EXIT
python3 -I - "$ROOT/upstream.json" "$NEW_TAG" "$NEW_COMMIT" "$NEW_TAG_OBJECT" <<'EOF'
import json,sys
p,tag,commit,obj=sys.argv[1:]
d=json.load(open(p)); d["tag"]=tag; d["commit"]=commit; d["tagObject"]=obj
open(p,"w").write(json.dumps(d,indent=2)+"\n")
EOF

mkdir -p "$LOGDIR"
BUILDLOG="$LOGDIR/build-$NEW_TAG.log"
if ! "$ROOT/scripts/build.sh" >"$BUILDLOG" 2>&1; then
  summary status=build-failed step=build "previousTag=$OLD_TAG" "tag=$NEW_TAG" "buildLog=$BUILDLOG"
  exit 1
fi
if [[ -n $DO_INSTALL ]] && ! "$ROOT/scripts/install.sh" >>"$BUILDLOG" 2>&1; then
  fail step=install "previousTag=$OLD_TAG" "tag=$NEW_TAG" "buildLog=$BUILDLOG"
fi

# The new pin is built (and installed): keep it, even if commit or push fails.
rm -f "$ROOT/upstream.json.bak"
trap - EXIT

if [[ -n $DO_COMMIT ]]; then
  [[ $(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null) == main ]] \
    || fail step=commit "tag=$NEW_TAG" "notes=the repo is not on branch main"
  git -C "$ROOT" commit -q --only -m "Update to $NEW_TAG" \
    -m "Co-authored-by: OpenBot <335604065+openbotgit[bot]@users.noreply.github.com>" -- upstream.json \
    || fail step=commit "tag=$NEW_TAG" "buildLog=$BUILDLOG"
fi
if [[ -n $DO_PUSH ]]; then
  git -C "$ROOT" push -q origin HEAD:refs/heads/main \
    || fail step=push "tag=$NEW_TAG" "buildLog=$BUILDLOG"
fi
summary status=built "previousTag=$OLD_TAG" "tag=$NEW_TAG" "name=protonnyuu-${NEW_TAG#dwproton-}" "buildLog=$BUILDLOG"
