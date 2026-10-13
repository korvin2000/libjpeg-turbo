#!/usr/bin/env bash
# Package one build as the release zip libjpeg-turbo-<version>-<platform>.zip (used by platforms.yml).
#
# Usage: package.sh <build-out-dir> <platform> <zip-dir>
#   <build-out-dir> = the out-dir of build-variant.sh (install/ + info.txt)
# The zip holds one top-level folder libjpeg-turbo-<version>-<platform>/ with the install tree (bin/,
# lib/, include/, share/) and BUILDINFO.txt (compiler, flags); symlinks (lib*.so / lib*.dylib version
# links) are stored as symlinks.
set -euo pipefail

IN=$(cd "$1" && pwd)
PLATFORM=$2
mkdir -p "$3"
ZIPDIR=$(cd "$3" && pwd)
SRC=$(cd "$(dirname "$0")/../.." && pwd)
VER=$(sed -n 's/^set(VERSION \(.*\))/\1/p' "$SRC/CMakeLists.txt")
test -n "$VER"
NAME=libjpeg-turbo-$VER-$PLATFORM
STAGE=$(mktemp -d)

cp -a "$IN/install" "$STAGE/$NAME"
{
    echo "libjpeg-turbo $VER for $PLATFORM"
    echo "source: ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-} commit ${GITHUB_SHA:-unknown}"
    cat "$IN/info.txt"
} > "$STAGE/$NAME/BUILDINFO.txt"
rm -f "$ZIPDIR/$NAME.zip"
(cd "$STAGE" && zip -qry9 "$ZIPDIR/$NAME.zip" "$NAME")
rm -rf "$STAGE"
echo "$ZIPDIR/$NAME.zip: $(du -k "$ZIPDIR/$NAME.zip" | cut -f1) KiB"
