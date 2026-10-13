#!/usr/bin/env bash
# Run the project's CTest suite on a build tree; used by platforms.yml and windows-x64-compilers.yml.
#
# Usage: run-ctest.sh <build-dir> <build-out-dir> <testimages-dir>
#   <build-out-dir> = the out-dir of build-variant.sh; for -ffast-math builds it holds ref/djpeg-static,
#   the same compiler's build without -ffast-math.
# Environment: CTEST (default: ctest), PYTHON (default: python3, or python on Windows), JOBS.
#
# -ffast-math may round the opt-in 12-bit *float* IDCT differently from every checksum the test suite
# knows (FLOATTEST12 in CMakeLists.txt). If the 12-bit float-IDCT checksum tests are the only failures
# and the build has a reference decoder, they are replaced by a tolerance check instead: the build's
# float-IDCT output must be within 1 LSB of the reference decoder's (ppmdiff.py). Any other failure fails.
set -uo pipefail

B=$(cd "$1" && pwd)
OUT=$(cd "$2" && pwd)
IMG=$(cd "$3" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
CTEST=${CTEST:-ctest}
JOBS=${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}
EXE=""
[ -f "$B/djpeg-static.exe" ] && EXE=.exe
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) PY=${PYTHON:-python} ;; *) PY=${PYTHON:-python3} ;; esac
FLOAT12='^djpeg12-(shared|static)-3x2-float-prog-cmp$'

"$CTEST" --test-dir "$B" -j"$JOBS" --output-on-failure --timeout 900 && { echo "CTest: all tests passed"; exit 0; }

failed=$(sed -n 's/^[0-9]*://p' "$B/Testing/Temporary/LastTestsFailed.log" 2>/dev/null)
echo "failed tests: $(echo $failed)"
if [ -z "$failed" ] || echo "$failed" | grep -vqE "$FLOAT12"; then
    echo "::error::CTest failures"; exit 1
fi
REF=$OUT/ref/djpeg-static$EXE
if [ ! -f "$REF" ]; then
    echo "::error::12-bit float IDCT checksum tests failed and there is no reference decoder"; exit 1
fi
echo "Only the 12-bit float IDCT checksum tests failed (-ffast-math rounding): tolerance check against $REF"
T=$(mktemp -d)
cp "$IMG/monkey16.png" "$T/"
(
    set -e
    cd "$T"
    "$B/cjpeg-static$EXE" -precision 12 -sample 3x2 -dct float -prog -outfile t.jpg monkey16.png
    "$B/djpeg-static$EXE" -dct float -ppm -outfile build.ppm t.jpg
    "$REF" -dct float -ppm -outfile ref.ppm t.jpg
    "$PY" -I "$HERE/ppmdiff.py" build.ppm ref.ppm --max 1
)
rc=$?
rm -rf "$T"
if [ $rc = 0 ]; then
    echo "::notice::12-bit float IDCT within 1 LSB of the reference (exact-checksum tests replaced); all other tests passed"
fi
exit $rc
