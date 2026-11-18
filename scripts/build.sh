#!/usr/bin/env bash
# Build protonnyuu: DW-Proton at the tag pinned in upstream.json,
# compiled for this PC's CPU (hardware/profile.json).
#
# Before compiling it checks that:
#   - the tag is signed by the pinned key (keys/, upstream.json signingKey),
#   - the tag object and commit match upstream.json,
#   - the source asks for the pinned Proton SDK image, which then runs by digest.
#
# Usage: scripts/build.sh
# Env:   PROTONNYUU_SRC    source checkout   (default ~/Projects/dwproton-src)
#        PROTONNYUU_BUILD  build directory   (default ~/.cache/protonnyuu/build-<tag>-<flags hash>)
#        PROTONNYUU_JOBS   parallel jobs     (default: nproc)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CACHE="$HOME/.cache/protonnyuu"
json() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
log() { printf '[build] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

U="$ROOT/upstream.json"
REPO=$(json "$U" repo)
TAG=$(json "$U" tag)
COMMIT=$(json "$U" commit)
TAG_OBJECT=$(json "$U" tagObject)
SIGNING_KEY=$(json "$U" signingKey)
SDK_IMAGE=$(json "$U" sdkImage)
SDK_DIGEST=$(json "$U" sdkDigest)
MARCH=$(json "$ROOT/hardware/profile.json" march)
RUST_CPU=$(json "$ROOT/hardware/profile.json" rustTargetCpu)

[[ $TAG =~ ^dwproton-[0-9]+\.[0-9]+-[0-9]+$ ]] || die "bad tag in upstream.json: $TAG"
[[ $COMMIT =~ ^[0-9a-f]{40}$ && $TAG_OBJECT =~ ^[0-9a-f]{40}$ ]] || die "bad commit or tagObject in upstream.json"
[[ $SIGNING_KEY =~ ^[0-9A-F]{40}$ ]] || die "bad signingKey in upstream.json"
[[ $SDK_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || die "bad sdkDigest in upstream.json"
[[ $MARCH =~ ^[a-z0-9-]+$ && $RUST_CPU =~ ^[a-z0-9-]+$ ]] || die "bad CPU name in hardware/profile.json"

VERSION=${TAG#dwproton-}
NAME="protonnyuu-$VERSION"
CFLAGS_OPT="-O2 -march=$MARCH -mtune=$MARCH"
RUSTFLAGS_OPT="-Copt-level=3 -Ctarget-cpu=$RUST_CPU"
FLAGS_HASH=$(printf '%s|%s|%s' "$CFLAGS_OPT" "$RUSTFLAGS_OPT" "$SDK_DIGEST" | sha256sum | cut -c1-12)

SRC=${PROTONNYUU_SRC:-$HOME/Projects/dwproton-src}
BUILD=${PROTONNYUU_BUILD:-$CACHE/build-$TAG-$FLAGS_HASH}
JOBS=${PROTONNYUU_JOBS:-$(nproc)}

# 1. Source at the pinned tag (shallow, with submodules). Refuse to overwrite edits.
if [[ ! -d $SRC/.git ]]; then
  log "cloning $REPO at $TAG"
  git clone --branch "$TAG" --depth 1 --recurse-submodules --shallow-submodules -j8 "$REPO" "$SRC"
else
  dirty=$(git -C "$SRC" status --porcelain --untracked-files=no --ignore-submodules=none)
  [[ -z $dirty ]] || die "$SRC has local changes; commit or stash them first:
$dirty"
  log "updating $SRC to $TAG"
  git -C "$SRC" fetch --depth 1 origin "+refs/tags/$TAG:refs/tags/$TAG"
  git -C "$SRC" checkout -q "$TAG"
  git -C "$SRC" submodule sync -q --recursive
  git -C "$SRC" submodule update --init --recursive --depth 1 -j8
fi

# 2. Trust checks: tag object, commit, and a signature by the pinned key.
[[ $(git -C "$SRC" rev-parse "refs/tags/$TAG") == "$TAG_OBJECT" ]] || die "tag object differs from upstream.json"
[[ $(git -C "$SRC" rev-parse HEAD) == "$COMMIT" ]] || die "HEAD differs from the pinned commit $COMMIT"
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg -q --batch --import "$ROOT"/keys/*.asc 2>/dev/null
sig=$(git -C "$SRC" verify-tag --raw "$TAG" 2>&1 || true)
grep -q "^\[GNUPG:\] VALIDSIG $SIGNING_KEY " <<<"$sig" || die "tag $TAG is not validly signed by $SIGNING_KEY"
log "tag $TAG: good signature from $SIGNING_KEY"

# 3. The source must ask for the pinned SDK image; it then runs by digest.
want=$(make --silent "SRCDIR=$SRC" --file "$SRC/Makefile.in" TARGET_ARCH=x86_64 get-steamrt-image)
[[ $want == "$SDK_IMAGE" ]] || die "this release wants SDK image $want, but upstream.json pins $SDK_IMAGE; review it and pin its digest first"
SDK_REF="${SDK_IMAGE%:*}@$SDK_DIGEST"

# 4. Configure with this CPU's flags.
#    Proton still adds -mno-avx/-mno-avx2/-mno-avx512f after these flags for
#    GCC builds (MinGW cannot keep the 32-byte stack alignment AVX needs), so
#    -march only adds the non-AVX instructions (SSE4.2, BMI, POPCNT...) and
#    -mtune schedules code for this CPU. That limit is kept on purpose.
#    The build directory name includes a hash of the flags and SDK, so a
#    flag change never reuses old objects.
mkdir -p "$BUILD"
cd "$BUILD"
log "configuring $NAME in $BUILD (CFLAGS=$CFLAGS_OPT, RUSTFLAGS=$RUSTFLAGS_OPT)"
CFLAGS="$CFLAGS_OPT" RUSTFLAGS="$RUSTFLAGS_OPT" \
  "$SRC/configure.sh" --build-name="$NAME" --container-engine=docker \
  --proton-sdk-image="$SDK_REF" --enable-ccache --without-tts

# 5. Build the Steam compatibility tool.
#    DW-Proton's `make redist` fills ./redist, renames it to ./$NAME and packs
#    $NAME.tar.xz. Clear the previous output first: if ./$NAME already exists,
#    `mv redist $NAME` would put the new build inside the old one.
OUT="$BUILD/$NAME"
rm -rf "$BUILD/redist" "$OUT" "$OUT.tar.xz" "$OUT.sha512sum"
log "building with $JOBS jobs"
make -j"$JOBS" redist

[[ -f $OUT/proton && -f $OUT/compatibilitytool.vdf ]] || die "$OUT is incomplete"
grep -qF "\"$NAME\"" "$OUT/compatibilitytool.vdf" || die "compatibilitytool.vdf does not name $NAME"
printf '%s\n' "$OUT" > "$CACHE/last-build"
log "done: $OUT (archive: $OUT.tar.xz)"
printf '%s\n' "$OUT"
