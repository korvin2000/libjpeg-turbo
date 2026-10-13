#!/usr/bin/env bash
# Cross-build (Linux host -> Windows x64) libjpeg-turbo with one compiler + one optimization variant.
# Used by .github/workflows/windows-x64-compilers.yml.
#
# Usage: build-variant.sh <gcc|clang> <variant> <out-dir>
#   x86_64-w64-mingw32-{gcc|clang}, -windres, nasm, cmake and ninja must be on PATH; *-pgo also needs wine.
# Variants (the x86 SIMD extensions (NASM, SSE2/AVX2, CPU-dispatched at run time) are in every build):
#   base          project defaults: Release = -O3, generic x86-64
#   avx2          -O3 -march=x86-64-v3 (AVX2/FMA/BMI2: Haswell / Zen 1 or newer) -ffast-math
#                 (-ffast-math includes -funsafe-math-optimizations)
#   avx2-lto      avx2 + link-time optimization
#   avx2-lto-pgo  avx2-lto + profile-guided optimization; training = the instrumented tjbench/cjpeg/djpeg/
#                 jpegtran run under Wine on the repo's testimages/ (not on the benchmark corpus)
# Output dir: install/ (stripped 'cmake --install' tree = release payload), testbin/ (every .exe/.dll of
# the build tree at its relative path, swapped into a native Windows CTest tree by the test job),
# info.txt, build.log, cc-cmd.txt (one real compile command line).
set -euo pipefail

CC_KIND=$1
VARIANT=$2
OUT=$(mkdir -p "$3" && cd "$3" && pwd)
SRC=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(dirname "$OUT")/work-$(basename "$OUT")
B=$WORK/build            # the PGO instrumented and final builds use the same path (profile file names)
PROF=$WORK/pgo-data
T=x86_64-w64-mingw32

case $CC_KIND in
    gcc)   CC=$T-gcc;   AR=$T-gcc-ar; RANLIB=$T-gcc-ranlib
           LTO="-flto=auto -ffat-lto-objects"       # fat: the installed static libs stay usable without LTO
           PGO_GEN="-fprofile-generate=$PROF"
           PGO_USE="-fprofile-use=$PROF -fprofile-partial-training -Wno-missing-profile" ;;
    clang) CC=$T-clang; AR=$T-ar;     RANLIB=$T-ranlib
           LTO=-flto
           PGO_GEN="-fprofile-generate=$PROF"
           PGO_USE="-fprofile-use=$PROF/merged.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date" ;;
    *) echo "unknown compiler kind: $CC_KIND" >&2; exit 2 ;;
esac
AVX2="-O3 -march=x86-64-v3 -ffast-math"
case $VARIANT in
    base)                  PERF="" ;;
    avx2)                  PERF=$AVX2 ;;
    avx2-lto|avx2-lto-pgo) PERF="$AVX2 $LTO" ;;
    *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
esac
# The 12-bit float DCT is plain C: with FMA (x86-64-v3) GCC and Clang >= 14 contract a*b+c, which changes
# its expected test output (see FLOATTEST12 in CMakeLists.txt). The 8-bit one is SIMD (sse) everywhere.
case $VARIANT in base) FT12=no-fp-contract ;; *) FT12=fp-contract ;; esac

configure_and_build() {  # $1 = extra C flags (PGO); verbose log appended to build.log
    rm -rf "$B"
    cmake -S "$SRC" -B "$B" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64 \
        -DCMAKE_C_COMPILER=$CC -DCMAKE_RC_COMPILER=$T-windres \
        -DCMAKE_AR="$(command -v $AR)" -DCMAKE_RANLIB="$(command -v $RANLIB)" \
        -DCMAKE_STRIP="$(command -v $T-strip)" \
        -DCMAKE_ASM_NASM_COMPILER=nasm -DREQUIRE_SIMD=1 \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/libjpeg-turbo \
        -DCMAKE_C_FLAGS="$PERF $1" \
        -DCMAKE_EXE_LINKER_FLAGS=-static -DCMAKE_SHARED_LINKER_FLAGS=-static \
        -DFLOATTEST12=$FT12 >> "$OUT/build.log" 2>&1 || { tail -60 "$OUT/build.log"; exit 1; }
    cmake --build "$B" -j"$(nproc)" -v >> "$OUT/build.log" 2>&1 || { tail -100 "$OUT/build.log"; exit 1; }
}

# PGO training: exercise both DLLs (libturbojpeg via tjbench, libjpeg-62 via cjpeg/djpeg/jpegtran) and the
# static-library builds (*-static.exe), in all modes the benchmark measures.
train() {
    export WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" WINEPREFIX=$WORK/wineprefix
    wineboot --init > /dev/null 2>&1 || true
    local t=$WORK/train
    rm -rf "$t" && mkdir -p "$t" && cp "$SRC"/testimages/* "$t/" && cd "$t"
    local s img
    for s in "" -static; do
        tj() { wine "$B/tjbench$s.exe" "$@" -benchtime 0.2 -warmup 0 -qq -nowrite > /dev/null; }
        for img in testorig.ppm vgl_6548_0026a.bmp shira_bird8.bmp; do
            tj $img 95                                   # gray, 4:2:0, 4:2:2, 4:4:4
            tj $img 75 -subsamp 420 -progressive
            tj $img 95 -subsamp 420 -arithmetic
            tj $img 95 -subsamp 420 -precision 12
            JSIMD_FORCENONE=1 tj $img 95 -subsamp 420
        done
        tj monkey16.pgm 1 -lossless -precision 16
        tj testorig.ppm 1 -lossless -precision 16
        tj testorig.jpg                                  # decompression + lossless transforms
        wine "$B/cjpeg$s.exe" -quality 90 -outfile o1.jpg testorig.ppm
        wine "$B/cjpeg$s.exe" -progressive -outfile o2.jpg vgl_6548_0026a.bmp
        wine "$B/djpeg$s.exe" -outfile o1.ppm o1.jpg
        wine "$B/djpeg$s.exe" -bmp -outfile o2.bmp o2.jpg
        wine "$B/djpeg$s.exe" -outfile o3.ppm testimgari.jpg
        wine "$B/jpegtran$s.exe" -rotate 90 -optimize -outfile o3.jpg testorig.jpg
    done
    cd "$SRC"
}

: > "$OUT/build.log"
if [ "$VARIANT" = avx2-lto-pgo ]; then
    echo "::group::PGO instrumented build ($CC_KIND)"
    rm -rf "$PROF" && mkdir -p "$PROF"
    configure_and_build "$PGO_GEN"
    echo "::endgroup::"
    echo "::group::PGO training (Wine)"
    train
    if [ "$CC_KIND" = clang ]; then
        ls "$PROF"/*.profraw
        llvm-profdata merge -o "$PROF/merged.profdata" "$PROF"/*.profraw
    fi
    find "$PROF" -type f | head -5; echo "$(find "$PROF" -type f | wc -l) profile files"
    test -n "$(find "$PROF" -type f -name '*.gcda' -o -type f -name 'merged.profdata')"
    echo "::endgroup::"
    EXTRA=$PGO_USE
else
    EXTRA=""
fi

echo "::group::build ($CC_KIND $VARIANT)"
configure_and_build "$EXTRA"
# last match = the final build (build.log also holds the PGO instrumented build)
grep -E ' -c [^ ]*src/jchuff\.c' "$OUT/build.log" | tail -1 > "$OUT/cc-cmd.txt" || true
grep -E '^-- (SIMD extensions|FLOATTEST)' "$OUT/build.log" | sort -u || true
echo "::endgroup::"

# verify the variant flags really reached the compiler (the last -O wins)
cat "$OUT/cc-cmd.txt"
for f in $PERF $EXTRA; do
    case $f in -Wno-*) continue ;; esac
    grep -q -- " $f" "$OUT/cc-cmd.txt" || { echo "::error::flag $f missing from the compile command"; exit 1; }
done
LAST_O=$(grep -oE ' -O[0-3s]' "$OUT/cc-cmd.txt" | tail -1)
[ "$LAST_O" = " -O3" ] || { echo "::error::effective optimization level is '$LAST_O', expected -O3"; exit 1; }

rm -rf "$OUT/install" "$OUT/testbin"
cmake --install "$B" --prefix "$OUT/install" --strip > /dev/null
(cd "$B" && find . -path ./CMakeFiles -prune -o \( -name '*.exe' -o -name '*.dll' \) -print) \
    | while read -r f; do mkdir -p "$OUT/testbin/$(dirname "$f")"; cp "$B/$f" "$OUT/testbin/$f"; done
{
    echo "compiler: $($CC --version | head -1)"
    echo "variant: $VARIANT"
    echo "flags: ${PERF:-(project defaults: -O3, generic x86-64)} ${EXTRA}"
    echo "floattest12: $FT12"
} | tee "$OUT/info.txt"
ls -l "$OUT"/install/bin
