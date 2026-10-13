#!/usr/bin/env bash
# Native build of libjpeg-turbo for one platform (shared TurboJPEG library + full install tree), run on
# the target platform's own GitHub runner. Used by .github/workflows/natives-all.yml.
#
# Usage: build-native.sh <step> <platform> <dir>
#   platform  linux-x64 | linux-aarch64 | mac-x64 | mac-arm64 | windows-aarch64
#   dir       work + output directory, the same for every step
# Steps (in this order):
#   profile   PGO: instrumented build (-fprofile-generate), native training run, llvm-profdata merge.
#             Training = the set of .github/compiler-bench/build-variant.sh (instrumented tjbench, cjpeg,
#             djpeg, jpegtran and their -static builds on testimages/), run natively instead of under Wine.
#   build     final build: the flags below, + -fprofile-use when PGO=true (env) and 'profile' succeeded
#   test      the project's full CTest suite on the final build tree
#   package   cmake --install --strip, dependency/export checks, smoke test of the bare shipped library
#             (loaded by path, tj3* calls), info file, zip -> <dir>/pkg/
# Flags (all clang; the SIMD extensions are required: NASM SSE2/AVX2 on x64, NEON on arm64):
#   x64       -O3 -march=x86-64-v3 -ffast-math -flto   (needs an AVX2/FMA/BMI2 CPU)
#   arm64     -O3 -ffast-math -flto
#   Linux     lld, -static-libgcc, -mno-daz-ftz (-ffast-math must not link crtfastmath.o: its constructor
#             would switch the loading process, e.g. a JVM, to flush-to-zero)
#   macOS     Apple clang + ld64, deployment target 10.13 (x64) / 11.0 (arm64), ad-hoc codesign
#   Windows   llvm-mingw (UCRT), -static (no libc++/libunwind/libwinpthread DLLs)
# Toolchain env: CC (default per platform), LLVM_SUFFIX (Linux: -NN of the apt.llvm.org packages).
set -euo pipefail

STEP=$1
PLATFORM=$2
mkdir -p "$3"
np() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }   # native path
DIR=$(np "$(cd "$3" && pwd)")
SRC=$(np "$(cd "$(dirname "$0")/../.." && pwd)")
B=$DIR/build             # the PGO instrumented and final builds use the same path
PROF=$DIR/pgo-data
OUT=$DIR/pkg
LOG=$DIR/build.log
STATE=$DIR/state.txt     # key: value lines handed from step to step (and into the info file)
JOBS=$(nproc 2> /dev/null || sysctl -n hw.ncpu)
VER=$(sed -n 's/^set(VERSION \(.*\))/\1/p' "$SRC/CMakeLists.txt")
export MSYS_NO_PATHCONV=1  # Git Bash: pass arguments to native Windows programs unchanged

EXE=""
CMAKE_EXTRA=""
case $PLATFORM in
    linux-x64|linux-aarch64)
        CC=${CC:-clang${LLVM_SUFFIX:-}}
        AR=llvm-ar${LLVM_SUFFIX:-}; RANLIB=llvm-ranlib${LLVM_SUFFIX:-}
        PROFDATA="llvm-profdata${LLVM_SUFFIX:-}"
        LDFLAGS="-fuse-ld=lld -static-libgcc -mno-daz-ftz"
        BARE=libturbojpeg-$PLATFORM.so ;;
    mac-x64|mac-arm64)
        CC=${CC:-clang}; AR=""; RANLIB=""
        PROFDATA="xcrun llvm-profdata"
        LDFLAGS=""
        if [ "$PLATFORM" = mac-x64 ]; then
            CMAKE_EXTRA="-DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=10.13"
        else
            CMAKE_EXTRA="-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0"
        fi
        BARE=libturbojpeg-$PLATFORM.dylib ;;
    windows-aarch64)
        CC=${CC:-aarch64-w64-mingw32-clang}
        AR=llvm-ar; RANLIB=llvm-ranlib
        PROFDATA="llvm-profdata"
        LDFLAGS="-static"
        CMAKE_EXTRA="-DCMAKE_RC_COMPILER=aarch64-w64-mingw32-windres"
        EXE=.exe
        BARE=turbojpeg-$PLATFORM.dll ;;
    *) echo "unknown platform: $PLATFORM" >&2; exit 2 ;;
esac
case $PLATFORM in
    *-x64) PERF="-O3 -march=x86-64-v3 -ffast-math -flto"; VARIANT=avx2-lto; CPU="x86-64-v3: AVX2/FMA/BMI2 (Intel Haswell / AMD Zen 1 or newer)" ;;
    *)     PERF="-O3 -ffast-math -flto";                   VARIANT=lto;      CPU="any ARMv8-A (NEON)" ;;
esac
if [ -n "$AR" ]; then
    CMAKE_EXTRA="$CMAKE_EXTRA -DCMAKE_AR=$(np "$(command -v "$AR")") -DCMAKE_RANLIB=$(np "$(command -v "$RANLIB")")"
fi
PGO_GEN="-fprofile-generate=$PROF"
PGO_USE="-fprofile-use=$PROF/merged.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date"

state() { sed -n "s/^$1: //p" "$STATE" | tail -1; }
put() { echo "$1: $2" >> "$STATE"; }

configure_and_build() {  # $1 = extra C flags (PGO); the verbose log goes to build.log
    rm -rf "$B"
    # FLOATTEST12: with FMA (x86-64-v3, every arm64) clang contracts a*b+c in the plain-C 12-bit float DCT
    # (see CMakeLists.txt); the 8-bit float DCT is SIMD (sse) on x64 and plain C (fp-contract) on arm64.
    # shellcheck disable=SC2086
    cmake -S "$SRC" -B "$B" -G Ninja -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=Release \
        -DREQUIRE_SIMD=1 -DFLOATTEST12=fp-contract \
        -DCMAKE_C_FLAGS="$PERF $1" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
        $CMAKE_EXTRA >> "$LOG" 2>&1 || { tail -80 "$LOG"; exit 1; }
    grep -E '^-- (The C compiler identification|SIMD extensions|FLOATTEST|Linker supports)' "$LOG" | tail -6 || true
    cmake --build "$B" -j"$JOBS" -v >> "$LOG" 2>&1 || { tail -100 "$LOG"; exit 1; }
}

run() {  # run a native program; show its output only if it fails
    local rc=0
    "$@" > "$DIR/run.log" 2>&1 || rc=$?
    if [ $rc != 0 ]; then echo "::error::$* failed (exit $rc)"; cat "$DIR/run.log"; return $rc; fi
}

train() {
    local t=$DIR/train s img
    rm -rf "$t" && mkdir -p "$t" && cp "$SRC"/testimages/* "$t/" && cd "$t"
    for s in "" -static; do
        tj() { run "$B/tjbench$s$EXE" "$@" -benchtime 0.2 -warmup 0 -qq -nowrite; }
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
        run "$B/cjpeg$s$EXE" -quality 90 -outfile o1.jpg testorig.ppm
        run "$B/cjpeg$s$EXE" -progressive -outfile o2.jpg vgl_6548_0026a.bmp
        run "$B/djpeg$s$EXE" -outfile o1.ppm o1.jpg
        run "$B/djpeg$s$EXE" -bmp -outfile o2.bmp o2.jpg
        run "$B/djpeg$s$EXE" -outfile o3.ppm testimgari.jpg
        run "$B/jpegtran$s$EXE" -rotate 90 -optimize -outfile o3.jpg testorig.jpg
    done
    cd "$SRC"
}

guard_rss() {  # guard_rss <max_kb> <cmd...>: run cmd; SIGKILL bmpsizetest* processes above max_kb RSS
    local max=$1 pid rss n=0     # (or running longer than 300 s)
    shift
    "$@" &
    pid=$!
    while kill -0 "$pid" 2> /dev/null; do
        rss=$(ps -A -o rss=,comm= | awk '/bmpsizetest/ {if ($1 > m) m = $1} END {print m + 0}')
        if [ "$rss" -gt "$max" ] || [ $n -gt 1500 ]; then
            echo "::warning::bmpsizetest killed (RSS $rss KB, limit $max KB; $((n / 5)) s)" >&2
            pkill -9 '^bmpsizetest' || true
        fi
        sleep 0.2
        n=$((n + 1))
    done
    wait "$pid"
}

FLOAT_RE='^djpeg(12)?-(shared|static)-3x2-float-prog-cmp$'
float_tolerance() {  # sets TOLERANCE
    local R=$DIR/ref ref_flags bits jpg d r
    case $PLATFORM in *-x64) ref_flags="-march=x86-64-v3" ;; *) ref_flags="" ;; esac
    echo "::group::reference build without -ffast-math/LTO/PGO ($ref_flags + Release -O3)"
    rm -rf "$R"
    # shellcheck disable=SC2086
    cmake -S "$SRC" -B "$R" -G Ninja -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=Release -DREQUIRE_SIMD=1 \
        -DFLOATTEST12=fp-contract -DCMAKE_C_FLAGS="$ref_flags" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
        $CMAKE_EXTRA > "$DIR/ref.log" 2>&1 || { tail -60 "$DIR/ref.log"; exit 1; }
    cmake --build "$R" -j"$JOBS" >> "$DIR/ref.log" 2>&1 || { tail -60 "$DIR/ref.log"; exit 1; }
    # the reference must reproduce the official checksums of exactly these tests
    ctest --test-dir "$R" -j"$JOBS" --output-on-failure -R '3x2-float-prog' | tail -5
    echo "::endgroup::"
    TOLERANCE=""
    for bits in 8 12; do
        case $bits in 8) jpg=$B/testout_3x2_float_prog.jpg ;; 12) jpg=$B/testout12_3x2_float_prog.jpg ;; esac
        "$R/djpeg$EXE" -dct float -ppm -outfile "$DIR/ref$bits.ppm" "$jpg"
        for d in djpeg djpeg-static; do
            "$B/$d$EXE" -dct float -ppm -outfile "$DIR/$d$bits.ppm" "$jpg"
            r=$("$(command -v python3 || command -v python)" -I "$SRC/.github/compiler-bench/ppmdiff.py" \
                "$DIR/$d$bits.ppm" "$DIR/ref$bits.ppm" --max 1) || { echo "::error::$d $bits-bit: $r"; exit 1; }
            echo "$d $bits-bit float IDCT vs reference: $r"
            TOLERANCE="$TOLERANCE${TOLERANCE:+; }$bits-bit $d: $(echo "$r" | sed 's/^.*: //')"
        done
    done
}

sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

case $STEP in
profile)
    : > "$LOG"; rm -f "$STATE"
    rm -rf "$PROF" && mkdir -p "$PROF"
    echo "::group::PGO instrumented build"
    configure_and_build "$PGO_GEN"
    echo "::endgroup::"
    echo "::group::PGO training (native)"
    train
    ls "$PROF"
    # shellcheck disable=SC2086
    $PROFDATA merge -o "$PROF/merged.profdata" "$PROF"/*.profraw
    test -s "$PROF/merged.profdata"
    echo "$(ls "$PROF"/*.profraw | wc -l) raw profiles -> merged.profdata ($(wc -c < "$PROF/merged.profdata") bytes)"
    echo "::endgroup::"
    ;;

build)
    if [ "${PGO:-false}" = true ] && [ -s "$PROF/merged.profdata" ]; then
        EXTRA=$PGO_USE; VARIANT=$VARIANT-pgo
        PGO_NOTE="yes: instrumented tjbench/cjpeg/djpeg/jpegtran (+ -static builds) trained natively on testimages/"
    else
        EXTRA=""
        PGO_NOTE="no (the PGO profile step failed; see the workflow log)"
        echo "::warning::$PLATFORM: building without PGO (profile step failed)"
    fi
    rm -f "$STATE"
    echo "::group::final build ($PLATFORM $VARIANT)"
    echo "== final build" >> "$LOG"
    configure_and_build "$EXTRA"
    echo "::endgroup::"
    # verify the flags reached the compiler (last compile of jchuff.c = the final build; the last -O wins)
    grep -E ' -c [^ ]*src/jchuff\.c' "$LOG" | tail -1 > "$DIR/cc-cmd.txt" || true
    cat "$DIR/cc-cmd.txt"
    for f in $PERF $EXTRA; do
        case $f in -Wno-*) continue ;; esac
        grep -q -- " $f" "$DIR/cc-cmd.txt" || { echo "::error::flag $f missing from the compile command"; exit 1; }
    done
    LAST_O=$(grep -oE ' -O[0-3s]' "$DIR/cc-cmd.txt" | tail -1)
    [ "$LAST_O" = " -O3" ] || { echo "::error::effective optimization level is '$LAST_O', expected -O3"; exit 1; }
    put variant "$VARIANT"
    put compiler "$("$CC" --version | sed -n 1p)"
    put cflags "$PERF${EXTRA:+ -fprofile-use=<training profile>}"
    put ldflags "${LDFLAGS:-(toolchain defaults)}"
    put pgo "$PGO_NOTE"
    put simd "$(grep -E '^-- SIMD extensions' "$LOG" | tail -1 | sed 's/^-- //')"
    put cpu "$CPU"
    ;;

test)
    # 1. everything but bmpsizetest, in parallel
    rc=0
    ctest --test-dir "$B" -j"$JOBS" --output-on-failure --timeout 900 -E '^bmpsizetest' > "$DIR/ctest.log" 2>&1 || rc=$?
    LOGS="$DIR/ctest.log"
    # 2. bmpsizetest (Unix only: fmemopen) probes the 65500x65500 limits of the image readers/writers with
    #    huge, lazily mapped allocations: run it alone, under an RSS guard so a runaway cannot take the
    #    whole runner down (two parallel copies did on the Linux runners)
    case $PLATFORM in windows-*) ;; *)
        guard_rss 3000000 ctest --test-dir "$B" --output-on-failure --timeout 300 -R '^bmpsizetest' \
            > "$DIR/ctest-bmpsize.log" 2>&1 || rc=$?
        LOGS="$LOGS $DIR/ctest-bmpsize.log" ;;
    esac
    # shellcheck disable=SC2086
    grep -hvE '^ *[0-9]+/[0-9]+ Test +#[0-9]+: .* Passed' $LOGS | tail -60 || true
    # shellcheck disable=SC2086
    TOTAL=$(cat $LOGS | sed -n 's/.*tests passed, [0-9]* tests* failed out of \([0-9]*\).*/\1/p' | awk '{s += $1} END {print s + 0}')
    # shellcheck disable=SC2086
    FAILED=$(cat $LOGS | sed -n 's/^[[:space:]]*[0-9][0-9]* - \([^ ]*\) (.*/\1/p')
    NFAIL=$(echo "$FAILED" | grep -c . || true)
    echo "tests: $TOTAL, failed: $NFAIL ${FAILED:+($(echo $FAILED))}"
    [ "$TOTAL" -gt 0 ] || { echo "::error::no CTest summary"; exit 1; }
    if [ $rc != 0 ] && [ "$NFAIL" = 0 ]; then echo "::error::ctest failed without a failed-test list"; exit 1; fi
    # -ffast-math (-ffp-contract=fast) may round the opt-in float IDCT of the 3x2 progressive tests
    # differently from the reference checksums (Clang's assume -ffp-contract=on): those, and only those,
    # are then replaced by a 1-LSB tolerance check against a non-fast-math reference build's decode
    OTHER=$(echo "$FAILED" | grep -vE "$FLOAT_RE" | grep . || true)
    if [ -n "$OTHER" ]; then echo "::error::failed tests: $(echo $OTHER)"; exit 1; fi
    if [ "$NFAIL" = 0 ]; then
        put ctest "$TOTAL/$TOTAL passed (full CTest suite, natively on the runner, FLOATTEST12=fp-contract)"
    else
        float_tolerance
        put ctest "$((TOTAL - NFAIL))/$TOTAL passed exactly + $NFAIL float-IDCT checksum tests ($(echo $FAILED)) replaced by a 1-LSB tolerance check vs a non-fast-math reference build: $TOLERANCE"
    fi
    echo "ctest: $(state ctest)"
    ;;

diag)
    # which flag makes bmpsizetest-static run away? (diagnostic only; each variant runs under the RSS guard)
    for v in "no-pgo:$PERF" "no-lto:$(echo "$PERF" | sed 's/ -flto//')" \
             "no-fast-math:$(echo "$PERF" | sed 's/ -ffast-math//')" "none:$(echo "$PERF" | sed 's/ -flto//; s/ -ffast-math//')"; do
        name=${v%%:*}; flags=${v#*:}
        R=$DIR/diag-$name
        rm -rf "$R"
        # shellcheck disable=SC2086
        cmake -S "$SRC" -B "$R" -G Ninja -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=Release -DREQUIRE_SIMD=1 \
            -DCMAKE_C_FLAGS="$flags" -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
            $CMAKE_EXTRA > "$R.log" 2>&1 || { tail -30 "$R.log"; continue; }
        cmake --build "$R" -j"$JOBS" --target bmpsizetest-static bmpsizetest >> "$R.log" 2>&1 || { tail -30 "$R.log"; continue; }
        for t in bmpsizetest-static bmpsizetest; do
            r=0; guard_rss 3000000 "$R/$t" > "$R-$t.out" 2>&1 || r=$?
            echo "diag $name ($flags): $t exit $r, $(tr '\n' ' ' < "$R-$t.out" | cut -c1-300)"
        done
    done
    ;;

package)
    [ -n "$(state ctest)" ] || { echo "::error::no successful test step recorded"; exit 1; }
    VARIANT=$(state variant)
    NAME=libjpeg-turbo-$VER-$PLATFORM-clang-$VARIANT
    rm -rf "$OUT" "$DIR/tree" && mkdir -p "$OUT" "$DIR/tree"
    I=$DIR/tree/$NAME
    cmake --install "$B" --prefix "$I" --strip > /dev/null
    case $PLATFORM in
    linux-*)
        LIB=$(ls "$I"/lib*/libturbojpeg.so.0.*.*)
        [ -f "$LIB" ] && [ ! -L "$LIB" ]
        readelf -d "$LIB"
        # crtfastmath.o must not be in it (see -mno-daz-ftz above); checked on the unstripped build tree copy
        nm "$B/$(basename "$LIB")" > "$DIR/nm.txt"
        if grep -q set_fast_math "$DIR/nm.txt"; then
            echo "::error::crtfastmath.o (FTZ/DAZ constructor) was linked into the library"; exit 1; fi
        SONAME=$(readelf -d "$LIB" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
        DEPS=$(readelf -d "$LIB" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')
        for d in $DEPS; do
            case $d in libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|ld-linux-*) ;;
                *) echo "::error::unexpected dependency $d"; exit 1 ;; esac
        done
        FLOOR=$(objdump -T "$LIB" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sort -u -V | tail -1)
        TJ3=$(nm -D --defined-only "$LIB" | awk '{print $3}' | sed 's/@.*//' | grep -E '^tj3' | sort -u | wc -l)
        put soname "$SONAME"
        put floor "glibc: $FLOOR (highest versioned glibc symbol)"
        ;;
    mac-*)
        LIB=$(ls "$I"/lib/libturbojpeg.0.*.*.dylib)
        [ -f "$LIB" ] && [ ! -L "$LIB" ]
        for f in "$I"/lib/*.dylib "$I"/bin/*; do   # strip invalidated the linker's ad-hoc signatures
            if [ ! -L "$f" ] && file "$f" > "$DIR/file.txt" && grep -q Mach-O "$DIR/file.txt"; then
                codesign --force --sign - "$f"
            fi
        done
        codesign --verify --verbose "$LIB"
        otool -L "$LIB"
        ID=$(otool -D "$LIB" | tail -1)
        DEPS=$(otool -L "$LIB" | tail -n +2 | awk '{print $1}' | grep -vxF "$ID" | tr '\n' ' ')
        for d in $DEPS; do
            case $d in /usr/lib/*|/System/*) ;; *) echo "::error::unexpected dependency $d"; exit 1 ;; esac
        done
        MINOS=$(otool -l "$LIB" | awk '/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/ {f=1} f && ($1 == "minos" || $1 == "version") {print $2; exit}')
        echo "minos: $MINOS, archs: $(lipo -archs "$LIB")"
        TJ3=$(nm -gU "$LIB" | awk '{print $3}' | grep -cE '^_tj3')
        put install_name "$ID"
        put floor "macOS minos $MINOS ($(lipo -archs "$LIB")), ad-hoc signed"
        ;;
    windows-*)
        LIB=$I/bin/libturbojpeg.dll
        llvm-readobj --file-headers "$LIB" | grep -E 'Machine: IMAGE_FILE_MACHINE_ARM64'
        DEPS=$(llvm-readobj --coff-imports "$LIB" | sed -n 's/^ *Name: *//p' | tr '\n' ' ')
        for d in $DEPS; do
            case $d in KERNEL32.dll|api-ms-win-crt-*.dll) ;; *) echo "::error::unexpected dependency $d"; exit 1 ;; esac
        done
        TJ3=$(llvm-readobj --coff-exports "$LIB" | sed -n 's/^ *Name: *//p' | grep -cE '^tj3')
        put floor "Windows 10+ on ARM64 (UCRT)"
        ;;
    esac
    echo "dependencies: $DEPS"
    echo "tj3* exports: $TJ3"
    cp "$LIB" "$OUT/$BARE"
    cp "$STATE" "$I/info.txt"

    echo "::group::smoke test of $BARE (loaded by path)"
    SMOKE=$DIR/tj3-smoke$EXE
    case $PLATFORM in linux-*) SMOKE_LIBS=-ldl ;; *) SMOKE_LIBS="" ;; esac
    # shellcheck disable=SC2086
    "$CC" -O1 -I"$SRC/src" -o "$SMOKE" "$SRC/.github/natives/tj3-smoke.c" $SMOKE_LIBS
    case $PLATFORM in windows-*) LIBARG=$(cygpath -w "$OUT/$BARE") ;; *) LIBARG=$OUT/$BARE ;; esac
    SMOKE_OUT=$("$SMOKE" "$LIBARG")
    SMOKE_RESULT=$(echo "$SMOKE_OUT" | sed -n 1p)
    echo "$SMOKE_RESULT"
    echo "::endgroup::"

    {
        echo "platform: $PLATFORM"
        echo "file: $BARE"
        echo "source: $NAME.zip:${LIB#"$DIR"/tree/"$NAME"/}"
        echo "size: $(wc -c < "$OUT/$BARE" | tr -d ' ')"
        echo "sha256: $(sha256 "$OUT/$BARE")"
        grep -vE '^(ctest): ' "$STATE"
        echo "deps: $DEPS"
        echo "tj3_exports: $TJ3"
        echo "ctest: $(state ctest)"
        echo "smoke: $SMOKE_RESULT (bare file loaded by path)"
        echo "zip: $NAME.zip"
        echo "commit: ${GITHUB_SHA:-local}"
    } > "$OUT/info-$PLATFORM.txt"
    cp "$OUT/info-$PLATFORM.txt" "$I/info.txt"
    cat "$OUT/info-$PLATFORM.txt"

    case $PLATFORM in
        windows-*) (cd "$DIR/tree" && /c/Windows/System32/tar.exe -a -cf "$OUT/$NAME.zip" "$NAME") ;;
        *)         (cd "$DIR/tree" && zip -qry9 "$OUT/$NAME.zip" "$NAME") ;;   # -y: keep the .so/.dylib symlinks
    esac
    ls -l "$OUT"
    ;;

*) echo "unknown step: $STEP" >&2; exit 2 ;;
esac
