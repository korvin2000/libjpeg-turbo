#!/usr/bin/env bash
# Smoke test of an unpacked release zip: runs its tools (from wherever the zip was unpacked, so it also
# checks that the executables find the shared libraries relative to themselves) and compares the MD5 of
# every output with smoke-expected.txt. All of them come from integer code paths (islow DCT, Huffman /
# arithmetic coding, lossless transform), which libjpeg-turbo keeps bit-exact between its SIMD and C
# code, so every platform, CPU and compiler must produce the same files.
#
# Usage: smoke.sh <unpacked-zip-dir> <testimages-dir>
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
D=$(cd "$1" && pwd)
I=$(cd "$2" && pwd)
EXE=""
[ -f "$D/bin/cjpeg.exe" ] && EXE=.exe
T=$(mktemp -d)
cd "$T"

"$D/bin/tjbench$EXE" "$I/testorig.ppm" 95 -benchtime 0.05 -warmup 0 -qq -nowrite > tjbench.txt
"$D/bin/tjbench$EXE" "$I/testorig.ppm" 95 -subsamp 420 -precision 12 -benchtime 0.05 -warmup 0 -qq -nowrite >> tjbench.txt
"$D/bin/cjpeg$EXE" -quality 95 -outfile a.jpg "$I/testorig.ppm"
"$D/bin/cjpeg$EXE" -quality 90 -progressive -outfile b.jpg "$I/vgl_6548_0026a.bmp"
"$D/bin/cjpeg$EXE" -arithmetic -outfile c.jpg "$I/testorig.ppm"
"$D/bin/cjpeg$EXE" -precision 12 -quality 95 -outfile d.jpg "$I/testorig.ppm"
"$D/bin/djpeg$EXE" -ppm -outfile a.ppm a.jpg
"$D/bin/djpeg$EXE" -ppm -outfile b.ppm b.jpg
"$D/bin/djpeg$EXE" -ppm -outfile e.ppm "$I/testimgari.jpg"
"$D/bin/djpeg$EXE" -ppm -outfile d.ppm d.jpg
"$D/bin/jpegtran$EXE" -rotate 90 -optimize -outfile f.jpg "$I/testorig.jpg"
for f in a.jpg b.jpg c.jpg d.jpg a.ppm b.ppm d.ppm e.ppm f.jpg; do
    if command -v md5sum > /dev/null; then md5sum "$f"; else md5 -r "$f"; fi | awk '{sub(/^\*/, "", $2); print $1, $2}'
done > md5.txt
cat md5.txt
EXPECTED=$HERE/smoke-expected.txt
cd / && if diff "$EXPECTED" "$T/md5.txt"; then echo "smoke test OK"; rc=0; else echo "::error::smoke test: outputs differ from $EXPECTED"; rc=1; fi
rm -rf "$T"
exit $rc
