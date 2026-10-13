#!/usr/bin/env bash
# Build libjpeg-turbo with one compiler + one optimization variant. Used by
# .github/workflows/windows-x64-compilers.yml (Linux -> Windows x64 cross builds) and
# .github/workflows/platforms.yml (native Linux / macOS / Windows ARM64 builds).
#
# Usage: build-variant.sh <gcc|clang> <variant> <out-dir>
# Environment:
#   TARGET   x86_64-w64-mingw32 (default): cross build on Linux with x86_64-w64-mingw32-{gcc|clang}
#                                (+ -windres, nasm); PGO training runs under Wine
#            native: build for the host (Linux, macOS, or Windows via Git Bash + llvm-mingw) with $CC
#                    (default: gcc / clang); PGO training runs the binaries directly
#   CC       native builds: the C compiler (e.g. aarch64-w64-mingw32-clang); clang PGO also needs
#            llvm-profdata on PATH
#   LDFLAGS  extra link flags (e.g. -fuse-ld=lld for Clang LTO on Linux)
#   CMAKE_EXTRA  extra CMake arguments, space-separated (e.g. -DCMAKE_OSX_ARCHITECTURES=x86_64)
# Variants (the SIMD extensions - NASM SSE2/AVX2 on x86-64, NEON on arm64, CPU-dispatched at run time
# on x86-64 - are in every build):
#   base          project defaults: Release = -O3, generic CPU
#   avx2          -O3 -march=x86-64-v3 (AVX2/FMA/BMI2: Haswell / Zen 1 or newer) -ffast-math
#                 (-ffast-math includes -funsafe-math-optimizations)
#   avx2-lto      avx2 + link-time optimization
#   avx2-lto-pgo  avx2-lto + profile-guided optimization
#   lto-pgo       portable (any CPU of the architecture): -O3 -ffast-math + LTO + PGO
# LTO applies to the shared libraries and executables only (project-hooks.cmake): the static libraries
# stay plain machine code that any compiler/linker can use. PGO training = the instrumented tjbench /
# cjpeg / djpeg / jpegtran (shared + static builds) on the repo's testimages/ (not on the benchmark corpus).
# Output dir: install/ (stripped 'cmake --install' tree = release payload), info.txt, build.log,
# cc-cmd.txt (a real compile command line of the shared TurboJPEG library), ref/djpeg-static (-ffast-math
# builds: the same compiler's djpeg without -ffast-math, see run-ctest.sh); Windows targets also get
# testbin/ (every .exe/.dll of the build tree at its relative path, for the native CTest run of
# cross builds). The build tree stays in <out-dir>/../work-<name>/build; native builds test it with
# run-ctest.sh <that build dir> <out-dir> testimages.
set -euo pipefail

CC_KIND=$1
VARIANT=$2
OUT=$(mkdir -p "$3" && cd "$3" && pwd)
SRC=$(cd "$(dirname "$0")/../.." && pwd)
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) HOSTWIN=1                     # native Windows tools get C:/... paths, also
                          OUT=$(cygpath -m "$OUT")      # inside flag strings such as -fprofile-generate=
                          SRC=$(cygpath -m "$SRC") ;;
    *)                    HOSTWIN="" ;;
esac
WORK=$(dirname "$OUT")/work-$(basename "$OUT")
B=$WORK/build            # the PGO instrumented and final builds use the same path (profile file names)
PROF=$WORK/pgo-data
TARGET=${TARGET:-x86_64-w64-mingw32}
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
# (Windows: 'python3' may be the Microsoft Store stub)
if [ -n "$HOSTWIN" ]; then PY=$(command -v python); else PY=$(command -v python3 || command -v python); fi

CMAKE_ARGS=(-DCMAKE_PROJECT_INCLUDE="$SRC/.github/compiler-bench/project-hooks.cmake"
            -DLJT_RELOCATABLE_RPATH=ON -DCMAKE_INSTALL_LIBDIR=lib -DREQUIRE_SIMD=1 -DCMAKE_BUILD_TYPE=Release
            ${CMAKE_EXTRA:-})
LINK=${LDFLAGS:-}
EXE="" RUNNER=""
if [ "$TARGET" = native ]; then
    CC=${CC:-$CC_KIND}
    if [ -n "$HOSTWIN" ]; then
        EXE=.exe; LINK="-static $LINK"     # no libc++/libunwind/libgcc DLLs
        CMAKE_ARGS+=(-DCMAKE_RC_COMPILER="${CC%clang}windres")
    else
        CMAKE_ARGS+=(-DCMAKE_INSTALL_PREFIX=/opt/libjpeg-turbo)
    fi
else
    T=$TARGET; CC=$T-$CC_KIND; EXE=.exe; RUNNER=wine; LINK="-static $LINK"
    CMAKE_ARGS+=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64 -DCMAKE_RC_COMPILER=$T-windres
                 -DCMAKE_AR="$(command -v $T-ar)" -DCMAKE_RANLIB="$(command -v $T-ranlib)"
                 -DCMAKE_STRIP="$(command -v $T-strip)" -DCMAKE_ASM_NASM_COMPILER=nasm
                 -DCMAKE_INSTALL_PREFIX=/opt/libjpeg-turbo)
fi

case $CC_KIND in
    gcc)   LTO=-flto=auto
           PGO_GEN="-fprofile-generate=$PROF"
           PGO_USE="-fprofile-use=$PROF -fprofile-partial-training -Wno-missing-profile" ;;
    clang) LTO=-flto
           PGO_GEN="-fprofile-generate=$PROF"
           PGO_USE="-fprofile-use=$PROF/merged.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date" ;;
    *) echo "unknown compiler kind: $CC_KIND" >&2; exit 2 ;;
esac
AVX2="-O3 -march=x86-64-v3 -ffast-math"
case $VARIANT in
    base)         PERF="";            LTO="" ;;
    avx2)         PERF=$AVX2;         LTO="" ;;
    avx2-lto)     PERF=$AVX2 ;;
    avx2-lto-pgo) PERF=$AVX2 ;;
    lto-pgo)      PERF="-O3 -ffast-math" ;;
    *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
esac
# The 12-bit float DCT is plain C: with FMA (x86-64-v3) GCC and Clang >= 14 contract a*b+c, which changes
# its expected test output (see FLOATTEST12 in CMakeLists.txt). Other builds use the project's default.
case $VARIANT in avx2*) CMAKE_ARGS+=(-DFLOATTEST12=fp-contract) ;; esac

configure_and_build() {  # $1 = extra C flags (PGO); verbose log appended to build.log
    rm -rf "$B"
    cmake -S "$SRC" -B "$B" -G Ninja "${CMAKE_ARGS[@]}" \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$PERF $1" -DLJT_LTO_FLAGS="$LTO" \
        -DCMAKE_EXE_LINKER_FLAGS="$LINK" -DCMAKE_SHARED_LINKER_FLAGS="$LINK" \
        >> "$OUT/build.log" 2>&1 || { tail -60 "$OUT/build.log"; exit 1; }
    cmake --build "$B" -j"$JOBS" -v >> "$OUT/build.log" 2>&1 || { tail -100 "$OUT/build.log"; exit 1; }
}

# PGO training: exercise both shared libraries (TurboJPEG via tjbench, libjpeg via cjpeg/djpeg/jpegtran)
# and the static-library builds (*-static), in all modes the benchmark measures.
x() {  # run a target program (under Wine for cross builds); show its output only if it fails
    local rc=0
    $RUNNER "$@" > "$WORK/run.log" 2>&1 || rc=$?
    if [ $rc != 0 ]; then echo "::error::$RUNNER $* failed (exit $rc)"; cat "$WORK/run.log"; return $rc; fi
}

train() {
    if [ "$RUNNER" = wine ]; then
        export WINEDEBUG=-all,err+all WINEDLLOVERRIDES="mscoree,mshtml=" WINEPREFIX=$WORK/wineprefix
        wine --version
        wineboot --init > "$WORK/wineboot.log" 2>&1 || { echo "wineboot failed:"; cat "$WORK/wineboot.log"; }
    fi
    local t=$WORK/train
    rm -rf "$t" && mkdir -p "$t" && cp "$SRC"/testimages/* "$t/" && cd "$t"
    local s img
    for s in "" -static; do
        tj() { x "$B/tjbench$s$EXE" "$@" -benchtime 0.2 -warmup 0 -qq -nowrite; }
        for img in testorig.ppm vgl_6548_0026a.bmp shira_bird8.bmp; do
            tj $img 95                                   # gray, 4:2:0, 4:2:2, 4:4:4
            tj $img 75 -subsamp 420 -progressive
            tj $img 95 -subsamp 420 -arithmetic
            JSIMD_FORCENONE=1 tj $img 95 -subsamp 420
        done
        tj testorig.ppm 95 -subsamp 420 -precision 12      # (BMP input is 8-bit only)
        tj testorig.ppm 95 -subsamp 444 -precision 12 -progressive
        tj monkey16.pgm 1 -lossless -precision 16
        tj testorig.ppm 1 -lossless -precision 16
        tj testorig.jpg                                  # decompression + lossless transforms
        x "$B/cjpeg$s$EXE" -quality 90 -outfile o1.jpg testorig.ppm
        x "$B/cjpeg$s$EXE" -progressive -outfile o2.jpg vgl_6548_0026a.bmp
        x "$B/djpeg$s$EXE" -outfile o1.ppm o1.jpg
        x "$B/djpeg$s$EXE" -bmp -outfile o2.bmp o2.jpg
        x "$B/djpeg$s$EXE" -outfile o3.ppm testimgari.jpg
        x "$B/jpegtran$s$EXE" -rotate 90 -optimize -outfile o3.jpg testorig.jpg
    done
    cd "$SRC"
}

: > "$OUT/build.log"
if [[ "$VARIANT" == *pgo ]]; then
    echo "::group::PGO instrumented build ($CC_KIND)"
    rm -rf "$PROF" && mkdir -p "$PROF"
    configure_and_build "$PGO_GEN"
    echo "::endgroup::"
    echo "::group::PGO training${RUNNER:+ ($RUNNER)}"
    train
    if [ "$CC_KIND" = clang ]; then
        llvm-profdata merge -o "$PROF/merged.profdata" "$PROF"/*.profraw
    fi
    echo "$(find "$PROF" -type f | wc -l) profile files"   # (no '| head': SIGPIPE + pipefail)
    test -n "$(find "$PROF" -type f -name '*.gcda' -o -type f -name 'merged.profdata')"
    echo "::endgroup::"
    EXTRA=$PGO_USE
else
    EXTRA=""
fi

echo "::group::build ($CC_KIND $VARIANT)"
configure_and_build "$EXTRA"
# last match = the final build (build.log also holds the PGO instrumented build)
grep -E 'CMakeFiles/turbojpeg\.dir/src/jchuff\.c\.o(bj)? ' "$OUT/build.log" | grep -E ' -c ' | tail -1 > "$OUT/cc-cmd.txt" || true
grep -E '^-- (CI hooks|SIMD extensions|FLOATTEST)' "$OUT/build.log" | sort -u || true
echo "::endgroup::"

# verify the variant flags really reached the compiler (the last -O wins)
cat "$OUT/cc-cmd.txt"
for f in $PERF $LTO $EXTRA; do
    case $f in -Wno-*) continue ;; esac
    grep -q -- " $f" "$OUT/cc-cmd.txt" || { echo "::error::flag $f missing from the compile command"; exit 1; }
done
LAST_O=$(grep -oE ' -O[0-3s]' "$OUT/cc-cmd.txt" | tail -1)
[ "$LAST_O" = " -O3" ] || { echo "::error::effective optimization level is '$LAST_O', expected -O3"; exit 1; }

rm -rf "$OUT/install" "$OUT/testbin" "$OUT/ref"
# -ffast-math builds: the same compiler's djpeg without it = the reference of run-ctest.sh's 12-bit float
# IDCT tolerance check
if [[ " $PERF " == *" -ffast-math "* ]]; then
    echo "::group::reference djpeg-static (no -ffast-math)"
    R=$WORK/ref
    rm -rf "$R"
    cmake -S "$SRC" -B "$R" -G Ninja "${CMAKE_ARGS[@]}" -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_EXE_LINKER_FLAGS="$LINK" -DCMAKE_SHARED_LINKER_FLAGS="$LINK" > "$OUT/build-ref.log" 2>&1 \
        && cmake --build "$R" --target djpeg-static -j"$JOBS" >> "$OUT/build-ref.log" 2>&1 \
        || { tail -60 "$OUT/build-ref.log"; exit 1; }
    mkdir -p "$OUT/ref" && cp "$R/djpeg-static$EXE" "$OUT/ref/"
    echo "::endgroup::"
fi
cmake --install "$B" --prefix "$OUT/install" --strip > /dev/null
"$PY" "$SRC/.github/compiler-bench/check-static-libs.py" "$OUT"/install/lib/*.a
if [ -n "$EXE" ]; then
    (cd "$B" && find . -path ./CMakeFiles -prune -o \( -name '*.exe' -o -name '*.dll' \) -print) \
        | while read -r f; do mkdir -p "$OUT/testbin/$(dirname "$f")"; cp "$B/$f" "$OUT/testbin/$f"; done
fi
{
    echo "compiler: $($CC --version | head -1)"
    echo "target: $([ "$TARGET" = native ] && echo "native $(uname -sm)" || echo "$TARGET")"
    echo "variant: $VARIANT"
    echo "flags: ${PERF:-(project defaults: -O3, generic CPU)}${LTO:+ $LTO (shared libs + executables)} ${EXTRA}"
    echo "floattest12: $(sed -n 's/^FLOATTEST12:STRING=//p' "$B/CMakeCache.txt")"
} | tee "$OUT/info.txt"
ls -l "$OUT"/install/bin
