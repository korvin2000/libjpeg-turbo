# Build Guide: latest compilers, performance builds, GitHub CI and benchmarking

A reusable, project-agnostic tutorial + FAQ for taking a C/C++ project from GitHub, building it with
the newest (stable or nightly) GCC / Clang toolchains, tuning it for speed (O3, LTO, AVX2, fast-math,
PGO), wiring it into GitHub Actions, and benchmarking compilers against each other fairly.

Facts and versions are as of **2026-10-13** and were checked against the sources linked in each
section. Things move fast: section 1.4 shows how to re-check versions in a minute instead of trusting
this file.

---

## Contents

1. [Where to get compilers](#1-where-to-get-compilers-stable-and-nightly)
2. [Building your own GCC snapshot cross toolchain (mingw-w64)](#2-building-your-own-gcc-snapshot-cross-toolchain-mingw-w64)
3. [Performance flags and how to apply them](#3-performance-flags-and-how-to-apply-them)
4. [Getting flags into the build system](#4-getting-flags-into-the-build-system-and-verifying-them)
5. [Windows specifics (MinGW / UCRT / threads / static runtime / JNI)](#5-windows-specifics)
6. [GitHub Actions patterns](#6-github-actions-patterns)
7. [Benchmarking compilers fairly](#7-benchmarking-compilers-fairly)
8. [Checklist: new project](#8-checklist-new-project)
9. [FAQ / troubleshooting](#9-faq--troubleshooting)
10. [Case study results: GCC 17 snapshot vs Clang nightly](#10-case-study-gcc-17-snapshot-vs-clang-nightly-windows-x64)
11. [Link collection](#11-link-collection)

---

## 1. Where to get compilers (stable and nightly)

### 1.1 Version landscape (2026-10-13)

| Toolchain | Latest stable | Development | Notes |
|---|---|---|---|
| GCC | **16.2.0** (2026-08-07) | **17.0.0** weekly snapshots (`gcc-17-YYYYMMDD`, e.g. `17-20261011`) | GCC 17.1 is expected around Apr/May 2027 |
| LLVM / Clang | **23.1.3** (23.1.0 was released 2026-08-25) | **24.0.0git** (main) | point releases about every 2 weeks |
| binutils | 2.47 | - | |
| mingw-w64 (headers/CRT) | v14.0.0 | git master | GCC 17 trunk needs master (see 2.2) |

GCC numbering: `N.0.0` = trunk (development), `N.1` = first release, `N.2`... = bug-fix releases,
`N.x.1` = the release branch between point releases.

### 1.2 Windows

| Source | What you get | Nightly? | Link |
|---|---|---|---|
| **MSYS2** | GCC + Clang in several environments: `UCRT64` (GCC, UCRT), `CLANG64` (Clang+libc+++lld, UCRT), `MINGW64` (GCC, old msvcrt). Packages update within days of upstream releases (gcc 16.2.0, clang 23.1.3 at the time of writing) | no | <https://packages.msys2.org> (e.g. `/packages/mingw-w64-x86_64-gcc`) |
| **llvm-mingw** (Martin Storsjö) | Clang + lld + libc++ + mingw-w64, UCRT; Windows-hosted (x86_64/i686/arm64) **and Linux/macOS-hosted cross** builds | **yes**: release tag `nightly` (LLVM main, rebuilt daily) | <https://github.com/mstorsjo/llvm-mingw/releases> |
| **WinLibs** (Brecht Sanders) | standalone GCC (+ optional LLVM) for MinGW-w64, UCRT or msvcrt, posix/mcf threads | occasional GCC snapshots (e.g. `16.0.1-snapshot20260222`), **no GCC 17 snapshot yet** | <https://winlibs.com>, <https://github.com/brechtsanders/winlibs_mingw/releases> |
| **gcc-mcf** (lhmouse) | GCC built with the mcf thread model (mcfgthread), UCRT/msvcrt | release-branch builds (16.2.1, ...) | <https://gcc-mcf.lhmouse.com/> |
| **niXman mingw-builds** | classic MinGW-w64 GCC builds (posix/win32/mcf) | no | <https://github.com/niXman/mingw-builds-binaries/releases> |
| **w64devkit** | small portable GCC kit | no | <https://github.com/skeeto/w64devkit> |
| **Official LLVM** | `clang`/`clang-cl` for the **MSVC** ABI (needs MSVC/Windows SDK) | no | <https://github.com/llvm/llvm-project/releases> |
| **MSVC** | Visual Studio / Build Tools (preinstalled on GitHub Windows images) | Preview channel | <https://visualstudio.microsoft.com/downloads/> |

**No ready-made GCC trunk/snapshot for Windows exists**. To use one, build a cross compiler on Linux
(section 2): it takes about 35 min on a GitHub runner and can be cached.

### 1.3 Linux / macOS / anywhere

| Source | What | Nightly? | Link |
|---|---|---|---|
| **apt.llvm.org** | Clang/LLVM `.deb`s for Debian/Ubuntu, stable + **snapshot (main)**; `llvm.sh <ver>` installer | **yes** | <https://apt.llvm.org> |
| **GCC snapshots** | weekly source tarballs per branch: `LATEST-17/`, `LATEST-16/`, ... | **yes** (source) | <https://gcc.gnu.org/pub/gcc/snapshots/> |
| Debian/Ubuntu `gcc-snapshot` | GCC trunk package installed into `/usr/lib/gcc-snapshot/` (lags behind) | semi | `apt install gcc-snapshot` |
| ubuntu-toolchain-r PPA | newer GCC releases for Ubuntu LTS | no | <https://launchpad.net/~ubuntu-toolchain-r/+archive/ubuntu/test> |
| Arch / AUR | `gcc-git`, `llvm-git`, `gcc-snapshot` style packages | yes | <https://aur.archlinux.org> |
| Gentoo | `sys-devel/gcc-17.0.0_pYYYYMMDD` snapshot ebuilds | yes | <https://packages.gentoo.org/packages/sys-devel/gcc> |
| conda-forge | gcc / clang packages, any distro, no root | no | <https://conda-forge.org> |
| Homebrew (macOS/Linux) | `brew install llvm gcc` | `--HEAD` for some | <https://brew.sh> |
| Docker | `gcc:<ver>` official images, `silkeh/clang` | no | <https://hub.docker.com/_/gcc> |
| **Compiler Explorer** | try trunk GCC/Clang instantly, compare asm | yes | <https://godbolt.org> |
| zig cc | Clang-based drop-in cross compiler for many targets | dev builds | <https://ziglang.org/download/> |

### 1.4 Re-check versions in one minute

```bash
# Latest GCC snapshot names (replace 17 with the current trunk major)
curl -s https://gcc.gnu.org/pub/gcc/snapshots/LATEST-17/ | grep -oE 'gcc-17-[0-9]{8}' | sort -u
# GCC releases
curl -s https://gcc.gnu.org/pub/gcc/releases/ | grep -oE 'gcc-[0-9]+\.[0-9]+\.[0-9]+' | sort -uV | tail -3
# binutils releases
curl -s https://sourceware.org/pub/binutils/releases/ | grep -oE 'binutils-2\.[0-9.]+tar' | sort -uV | tail -3
# llvm-mingw: releases (LLVM version is in the release name) + nightly asset dates
curl -s 'https://api.github.com/repos/mstorsjo/llvm-mingw/releases?per_page=3' | grep -E '"(tag_name|name)"'
curl -s https://api.github.com/repos/mstorsjo/llvm-mingw/releases/tags/nightly | grep -E '"(name|updated_at)"'
# mingw-w64 tags, WinLibs releases
curl -s 'https://api.github.com/repos/mingw-w64/mingw-w64/tags?per_page=3' | grep '"name"'
curl -s 'https://api.github.com/repos/brechtsanders/winlibs_mingw/releases?per_page=5' | grep tag_name
# MSYS2 package versions: open https://packages.msys2.org/packages/mingw-w64-x86_64-gcc (or -clang)
```

---

## 2. Building your own GCC snapshot cross toolchain (mingw-w64)

Use this when you need a GCC version no Windows distribution ships, such as trunk. Build a
**Linux-hosted cross compiler targeting `x86_64-w64-mingw32`** and cross-compile the project on Linux.
Then run the tests and benchmarks on a real Windows machine or runner. A Windows-hosted GCC would need
an additional "Canadian cross" stage with tricky sysroot relocation; avoid it unless you must compile
on Windows.

### 2.1 Order (the classic mingw-w64 bootstrap)

```
binutils  ->  mingw-w64 headers  ->  gcc all-gcc (compilers only)  ->  mingw-w64 CRT
          ->  [winpthreads, only for --enable-threads=posix]  ->  gcc (libgcc, libstdc++)
```

### 2.2 Recipe (Ubuntu 24.04, about 35 min on a 4-vCPU GitHub runner)

```bash
sudo apt-get install -y bison flex texinfo libgmp-dev libmpfr-dev libmpc-dev libisl-dev
T=x86_64-w64-mingw32; P=$HOME/tc/mingw-gcc17; J=$(nproc)
# sources: binutils-2.47.tar.xz, gcc-17-YYYYMMDD.tar.xz (snapshots/17-YYYYMMDD/), mingw-w64 MASTER commit
#   https://sourceware.org/pub/binutils/releases/
#   https://gcc.gnu.org/pub/gcc/snapshots/LATEST-17/
#   https://github.com/mingw-w64/mingw-w64/archive/<master-sha>.tar.gz   (v14.0.0 CRT fails with GCC 17)
export PATH=$P/bin:$PATH
(mkdir b-binutils && cd b-binutils && ../binutils/configure --target=$T --prefix=$P --with-sysroot=$P \
   --disable-multilib --disable-nls --disable-werror && make -j$J && make install-strip)
(mkdir b-headers && cd b-headers && ../mingw-w64/mingw-w64-headers/configure --host=$T --prefix=$P/$T \
   --with-default-msvcrt=ucrt && make install)
ln -sfn $T $P/mingw          # GCC's native header dir for mingw is /mingw/include under the sysroot
(mkdir b-gcc && cd b-gcc && ../gcc/configure --target=$T --prefix=$P --with-sysroot=$P \
   --enable-languages=c,c++,lto --enable-lto --disable-multilib --disable-nls --disable-werror \
   --enable-checking=release --enable-threads=win32 --disable-libstdcxx-pch \
   --disable-libgomp --disable-libquadmath --disable-libssp --disable-libsanitizer \
   && make -j$J all-gcc && make install-strip-gcc)
(mkdir b-crt && cd b-crt && ../mingw-w64/mingw-w64-crt/configure --host=$T --prefix=$P/$T \
   --with-sysroot=$P --with-default-msvcrt=ucrt --disable-lib32 --enable-lib64 && make -j$J && make install)
(cd b-gcc && make -j$J && make install-strip)
$T-gcc --version
```

Key decisions and pitfalls:

* **`--enable-checking=release`**: snapshots default to extra internal checking, which slows the
  compiler down (it does not change the generated code).
* **Thread model**: `win32` needs no winpthreads, and since GCC 13 libstdc++ supports
  `std::thread`/`std::mutex` with it. Use `posix` only if the project uses pthreads (then build
  winpthreads after the CRT and before the target libraries). `mcf` needs mcfgthread.
* **UCRT vs msvcrt**: pick one and use it for every compiler you compare (see 5.1).
* **Cache it**: key the cache on the snapshot name + binutils + mingw-w64 version + a hash of the
  recipe script (section 6.4).
* A trunk snapshot can be broken for mingw targets in a given week. Make the snapshot name an input
  so you can fall back to the previous week.
* **Match the mingw-w64 version to the compiler's age.** The mingw-w64 **v14.0.0** CRT does *not*
  build with GCC 17 trunk: `ssp/stack_chk_guard.c: conflicting types for '__stack_chk_guard'; have
  'void *'` (GCC 17 predeclares it as `uintptr_t`). It is fixed on mingw-w64 master (commit
  `5d04f8f791`, 2026-05). Trunk compilers need master-era runtimes, so pin a master commit
  (`https://github.com/mingw-w64/mingw-w64/archive/<sha>.tar.gz`). llvm-mingw nightly does the same.
* **`set -e` does not catch `make && make install`**: a failing command that is not the last one in
  an `&&` list does not abort the script. The failed CRT build was swallowed, a half-built toolchain
  was cached, and the error only surfaced later as `cannot find -lgcc / crtend.o / -lkernel32`. Put
  each command on its own line. End the toolchain script with a **smoke test** (link a static C++
  `.exe` and `.dll`), so a broken toolchain fails the job and never gets cached.

---

## 3. Performance flags and how to apply them

### 3.1 The usual suspects

| Flag | GCC | Clang | Effect / caveat |
|---|---|---|---|
| `-O2` | default for most release builds | same | safe baseline |
| `-O3` | more inlining, vectorization, loop transforms | similar | usually 0-10%; can also regress (code size, icache) |
| `-march=x86-64-v2` | SSE4.2, POPCNT | same | runs on almost every x86-64 CPU since about 2009 |
| `-march=x86-64-v3` | **AVX2, FMA, BMI1/2, LZCNT, MOVBE, F16C** | same | Intel Haswell (2013)+, AMD Zen 1 (2017)+; **illegal-instruction crash on older CPUs** |
| `-march=x86-64-v4` | AVX-512 F/BW/CD/DQ/VL | same | Skylake-SP / Ice Lake / Zen 4+, not on many consumer Intel CPUs |
| `-march=native` | host CPU | same | not portable: never ship it, and avoid it on CI (runner CPUs vary) |
| `-mtune=generic\|znver4\|...` | scheduling only | same | safe; never breaks portability |
| `-ffast-math` | unsafe FP reassociation, assumes no NaN/Inf | same (`-ffp-model=fast`) | only helps float-heavy code; breaks `isnan`/`isinf` checks; see 3.3 |
| `-flto` / `-flto=auto` | whole-program optimization (GCC: `=auto` parallel) | `-flto` (full) / `-flto=thin` | 0-15%; needs LTO-aware `ar`/linker (`gcc-ar`, `llvm-ar`, `lld`); see 3.4 |
| PGO | `-fprofile-generate` / `-fprofile-use` | `-fprofile-instr-generate` + `llvm-profdata merge` + `-fprofile-instr-use` | often the biggest single win (10-30% for branchy code); needs a representative training run |
| BOLT | - | `llvm-bolt` | post-link layout optimization, **ELF (Linux) only** |
| `-fno-plt`, `-fno-semantic-interposition` | | | ELF shared libraries only; meaningless for PE/Windows |
| `-fvisibility=hidden` | | | smaller/faster shared libraries; export explicitly |
| `-funroll-loops`, `-mprefer-vector-width=256/512` | | | workload-dependent; measure |

MSVC equivalents: `/O2`, `/arch:AVX2`, `/GL` + `/LTCG` (LTO), `/fp:fast`, PGO via `/GENPROFILE` and
`/USEPROFILE`.

### 3.2 Portable fast binaries: runtime dispatch instead of `-march`

Projects that already dispatch on CPUID (7-Zip, zstd, simdjson, OpenSSL, ...) get AVX2 code paths in
their hot loops even in a generic `-O2` build. In that case `-march=x86-64-v3` only speeds up the
remaining scalar code. To make your own code portable and fast:

* `__attribute__((target("avx2")))` functions + a CPUID check (`__builtin_cpu_supports("avx2")`);
* `__attribute__((target_clones("default","avx2")))` (GCC and Clang; uses ifunc on ELF, a resolver
  on other targets);
* or ship two binaries (generic + v3) and pick one at load time.

### 3.3 fast-math caveats

* `-ffast-math` implies `-ffinite-math-only`, so the compiler may delete NaN/Inf checks.
* When an **executable** is linked with `-ffast-math`, GCC and Clang on ELF targets add `crtfastmath.o`,
  which turns on FTZ/DAZ for the whole process. Recent GCC/Clang skip this for `-shared`. A shared
  library must never change the host process's FP mode, so check the final link line, and never add
  `-mdaz-ftz` to a library.
* Integer workloads (compression, hashing, crypto, parsing) gain essentially nothing.

### 3.4 LTO caveats

* Pass the same optimization flags when compiling **and** linking. CMake passes
  `CMAKE_<LANG>_FLAGS` to the link line; per-target compile options are not passed.
* GCC: use `gcc-ar`/`gcc-ranlib` for static archives (CMake does this when
  `CMAKE_INTERPROCEDURAL_OPTIMIZATION=ON` and policy CMP0069 is NEW).
* Clang: needs `lld` or the gold plugin. llvm-mingw and MSYS2 CLANG64 default to lld.
* Whole-program devirtualization can create references to vtables of classes whose `.cpp` is not
  linked (headers that declare `final` classes). Symptom: `undefined reference to vtable for X` only
  with LTO or newer GCC. Fix: link the missing object, or use `-fno-devirtualize-speculatively`
  (GCC 16 already needs this without LTO in some codebases).
* `--gc-sections` + LTO can drop symbols that are only reached at run time (for example, registration
  objects). Run the full test suite on every LTO build.

---

## 4. Getting flags into the build system (and verifying them)

**Rule 1: the last `-O` on the command line wins.** Build systems often append their own `-O2` *after*
your flags, so passing `-O3` silently does nothing.

* **CMake**: compile line order is
  `CMAKE_<LANG>_FLAGS` → `CMAKE_<LANG>_FLAGS_<CONFIG>` → `add_definitions()`/`add_compile_options()`
  → target options. So `add_definitions(-O2)` in a project overrides your `CMAKE_CXX_FLAGS=-O3`.
  Fix: make it a cache variable (e.g. `OPTIMIZATION_FLAGS`), or patch it.
  `CMAKE_<LANG>_FLAGS` *are* passed to the link line (needed for LTO); `add_compile_options` are not.
* **Make**: variables given on the command line override assignments in the makefile
  (`make CFLAGS_BASE=... FLAGS_FLTO="-O3 ..."`). Find the variable that comes *after* the hard-coded
  `-O2` in the compile rule, or override the one that contains it.
* **Meson**: `-Dbuildtype=release -Doptimization=3 -Db_lto=true -Dc_args=-march=x86-64-v3`.
* **Autotools**: `CFLAGS=... CXXFLAGS=... ./configure` (it defaults to `-g -O2` only when unset).
* **Warnings as errors**: new compilers add warnings, so drop `-Werror` (keep `-Wall`) when you test
  bleeding-edge compilers on someone else's code.

**Verify, don't assume:**

```bash
ninja -v | make V=1 | cmake --build . -v     # print real compile/link lines
grep -m1 'somefile.c' build.log              # check the final -O / -march / -flto actually present
x86_64-w64-mingw32-objdump -d app.exe | grep -c ymm   # AVX2 (ymm) instructions present?
strings app.exe | grep -E 'GCC: \(|clang version'    # which compiler built it (.ident/.comment)
x86_64-w64-mingw32-objdump -p app.dll | grep 'DLL Name'  # runtime DLL dependencies (PE)
readelf -d libx.so | grep NEEDED                      # (ELF)
```

---

## 5. Windows specifics

### 5.1 CRT: UCRT vs msvcrt

* **UCRT** (`ucrtbase.dll`, ships with Windows 10+): modern C99/C11 behaviour. This is the default in
  MSYS2 UCRT64/CLANG64, llvm-mingw and new mingw-w64 builds.
* **msvcrt** (`msvcrt.dll`): legacy; still used by MSYS2 MINGW64 and many existing release builds.
* Do not mix objects or static libraries built against different CRTs. When benchmarking compilers,
  use the same CRT for all of them. `memcpy`/`memset` come from the CRT and can dominate some
  workloads.

### 5.2 Self-contained DLL/EXE (no MinGW runtime DLLs)

* GCC: `-static-libgcc -static-libstdc++` is not enough with the **posix** thread model, because
  `libwinpthread-1.dll` stays a dependency. Link with `-static` (whole link) or use the win32 thread
  model.
* Clang/llvm-mingw: `-static` links libc++/libunwind/compiler-rt statically.
* Check: `objdump -p x.dll | grep 'DLL Name'` must show only system DLLs (`KERNEL32`, `api-ms-win-crt-*`
  or `msvcrt`, `USER32`, ...), never `libgcc_s_seh-1`, `libstdc++-6`, `libwinpthread-1` or `libc++`.

### 5.3 Clang flavours on Windows

| Flavour | Triple / ABI | C++ lib | Linker |
|---|---|---|---|
| llvm-mingw / MSYS2 CLANG64 | `x86_64-w64-mingw32` (GNU ABI) | libc++ | lld |
| MSYS2 UCRT64/MINGW64 `clang` | `x86_64-w64-windows-gnu` | libstdc++ (GCC's) | GNU ld or `-fuse-ld=lld` |
| official LLVM `clang-cl` | `x86_64-pc-windows-msvc` (MSVC ABI) | MSVC STL | `lld-link`/`link.exe` |

MinGW-ABI and MSVC-ABI C++ objects are **not** link-compatible.

### 5.4 Cross-compiling JNI libraries for Windows on Linux

`jni_md.h` is platform-specific. The Linux one defines `jlong` as `long`, which is **32-bit on
Windows** (LLP64), so it silently breaks the ABI. Use the Windows JDK's `include/win32/jni_md.h`:
`JNIEXPORT __declspec(dllexport)`, `JNICALL __stdcall`, `typedef long jint; typedef __int64 jlong;`.
Either extract it from a Windows JDK zip or write those few lines into an overlay JDK's include
directory.

### 5.5 Old CMake projects vs CMake 4

CMake 4 removed compatibility with `cmake_minimum_required(VERSION <3.5)`. Use
`-DCMAKE_POLICY_VERSION_MINIMUM=3.5`, or pin CMake 3.x in CI (`jwlawson/actions-setup-cmake@v2` with
`cmake-version: '3.28.6'`).

---

## 6. GitHub Actions patterns

### 6.1 Hosted runners (check the docs, they change)

* `ubuntu-24.04` / `ubuntu-latest`, `windows-latest` (Windows Server 2025 image), `windows-11-arm`,
  `ubuntu-24.04-arm`, `macos-14`/`macos-15` (Apple Silicon), `macos-13` (Intel).
* Public repositories get **4 vCPU / 16 GB** Linux and Windows runners for free (private repos get
  smaller ones). The CPU model varies between jobs (AMD EPYC or Intel Xeon). AVX2 is present, AVX-512
  is **not** guaranteed.
* Docs: <https://docs.github.com/actions/using-github-hosted-runners/about-github-hosted-runners>

### 6.2 Toolchain setup actions

| Need | Action |
|---|---|
| MSYS2 (GCC/Clang on Windows) | `msys2/setup-msys2@v2` (`msystem: UCRT64\|CLANG64\|MINGW64`, `install: mingw-w64-ucrt-x86_64-gcc ...`) |
| MSVC environment | `ilammy/msvc-dev-cmd@v1` |
| LLVM release on any OS | `KyleMayes/install-llvm-action@v2` |
| CMake pin | `jwlawson/actions-setup-cmake@v2` |
| Ninja | `seanmiddleditch/gha-setup-ninja@v6` |
| JDK | `actions/setup-java@v4` (`distribution: temurin`, `architecture: x64`) |
| ccache / sccache | `hendrikmuhs/ccache-action@v1`, `mozilla-actions/sccache-action` |
| llvm-mingw / GCC snapshot | download the release asset with `curl`, or build and cache it (section 2) |

### 6.3 Architecture for "build with exotic toolchains, test natively"

```
resolve (ubuntu)           pick versions, emit build matrix as JSON, download moving "nightly"
   |                       assets ONCE and pass them on as an artifact
toolchain (ubuntu)         build or restore expensive toolchains (actions/cache)
   |
build (ubuntu, matrix)     cross-compile every compiler x variant, upload artifacts
   |            \
test (windows, matrix)      bench (windows, ONE job)
native test suite with      every binary on the same machine,
the cross-built binary      interleaved rounds, job summary
```

* **Dynamic matrix**: a job writes `builds=[{"compiler":"gcc17","variant":"avx2"},...]` to
  `$GITHUB_OUTPUT`, and later jobs use `matrix: include: ${{ fromJSON(needs.resolve.outputs.builds) }}`.
* **Moving targets** (a nightly asset replaced daily): download once in the first job and share it as
  an artifact, so every matrix job uses the same compiler build.
* **Test harness reuse**: build the test harness natively with any compiler, then point it at the
  cross-built library under test (swap the path or jar). Make sure the harness's own copy is removed,
  so a wrong swap fails loudly.

### 6.4 Caching an expensive toolchain

```yaml
- id: cache
  uses: actions/cache@v4
  with:
    path: ~/tc/mingw-gcc17
    key: mingw-cross-${{ env.GCC_SNAPSHOT }}-binutils2.47-v14.0.0-${{ hashFiles('scripts/build-gcc-cross.sh') }}
- if: steps.cache.outputs.cache-hit != 'true'
  run: bash scripts/build-gcc-cross.sh ...
# consumer jobs:
- uses: actions/cache/restore@v4
  with: { path: ~/tc/mingw-gcc17, key: <same key>, fail-on-cache-miss: true }
```

* The cache `path` must be **identical** in the saving and restoring jobs. Use a path under `~`
  (`/opt` needs sudo to extract).
* A cache saved by one job is available to later jobs in the **same run**.
* A repository has a 10 GB cache budget; the least recently used entries are evicted.

### 6.5 Triggers, dispatch, concurrency

* A `workflow_dispatch` workflow can be run from the UI/API only once the file exists on the
  **default branch**. To iterate on a new workflow in a feature branch, add
  `push: branches: [my-branch]`.
* `concurrency: { group: wf-${{ github.ref }}, cancel-in-progress: true }` cancels superseded runs.
  Keep master runs alive with
  `cancel-in-progress: ${{ github.ref != 'refs/heads/master' }}`.
* Inputs are empty on non-dispatch events. Use defaults like `${{ inputs.rounds || '7' }}`.
* Reusable workflows: `on: workflow_call` and `uses: ./.github/workflows/x.yml` (an umbrella CI
  that calls per-platform workflows).

### 6.6 Results and artifacts

* `$GITHUB_STEP_SUMMARY`: append Markdown (tables) and it is rendered on the run page.
* `actions/upload-artifact@v4`: names must be unique per run. Download with `pattern: bin-*`, then
  rename the folders. Use `compression-level: 0` for already-compressed files.
* `if: always()` on uploads, so logs and results survive failures.

### 6.7 Driving Actions without `gh`

```bash
API=https://api.github.com/repos/OWNER/REPO
curl -s "$API/actions/runs?branch=my-branch&per_page=5"            # public repos: no token needed
curl -s "$API/actions/runs/RUN_ID/jobs?per_page=100"
curl -sL -H "Authorization: Bearer $TOKEN" "$API/actions/jobs/JOB_ID/logs" | tail -100   # logs need auth
curl -s -X POST -H "Authorization: Bearer $TOKEN" "$API/actions/runs/RUN_ID/rerun-failed-jobs"
curl -s -X POST -H "Authorization: Bearer $TOKEN" "$API/actions/workflows/x.yml/dispatches" \
     -d '{"ref":"master","inputs":{"rounds":"9"}}'
```

**Security**: never embed a personal access token in a git remote URL (`https://user:ghp_...@github.com`).
It is stored in plain text in `.git/config` and leaks into logs and tools. Use a credential helper
(`git credential-manager`, `gh auth`) and fine-grained tokens. Inside workflows, use the automatic
`GITHUB_TOKEN` with `permissions: contents: read` (raise only what a job needs).

---

## 7. Benchmarking compilers fairly

### 7.1 Ground rules

1. **Same machine for all candidates.** Cloud runners differ by CPU model and by noisy neighbours, so
   never compare numbers from different jobs. Build in parallel jobs, then benchmark every binary in
   **one** job.
2. **Interleave**: run rounds in rotating order (ABC, CBA, BCA, ...) so drift (thermal, neighbours,
   turbo) hits every build alike. Report **medians** (or best-of for latency benchmarks).
3. **Pin and prioritise**: run single-thread tests pinned to one core (not core 0) at high priority.
   On Windows use `start "" /b /wait /high /affinity 2 app.exe ...` or `SetProcessAffinityMask` from
   Python/ctypes; on Linux use `taskset -c 2 nice -n -5 ...`.
4. **Warm up** once before measuring (file cache, CPU frequency ramp, JIT for JVM benchmarks).
5. **Correctness first**: run the full test suite on every optimized build (fast-math, LTO and
   `-march` can all break things), and round-trip check the outputs.
6. **Know the noise floor**: on shared cloud VMs, run-to-run scatter is often 2-5%. Calling a
   **2-3% difference real** needs a paired design with about 20-50 rounds, or repeated runs on
   independent machines. Treat differences of 5% or more that are consistent across rounds as
   meaningful.
7. **Compare toolchains, not just compilers**: CRT, C++ library, linker and the project's own
   `#ifdef __clang__` paths all differ. For example, 7-Zip enables `__builtin_expect` branch hints only
   for Clang. Report the result as "toolchain X builds this project faster", not as a universal ranking.
8. Report per-workload results **and** an aggregate (geometric mean of speed ratios against a
   baseline). Different codecs and kernels often favour different compilers.

### 7.2 Tools

* **Built-in benchmarks**: many projects have one, and it is the best first choice.
  7-Zip: `7z b` (LZMA rating), `7z b -mmt1` (single thread), `7z b 1 -mmt1 -mm=*` (every
  codec/hash/crypto method), `-md22` (dictionary sizes up to 2^22), `-mdf=24` (one fixed dictionary).
  zstd: `zstd -b1 -e19`; OpenSSL: `openssl speed`; lz4: `lz4 -b`.
* `hyperfine` for whole-command timing with warm-up and statistics: <https://github.com/sharkdp/hyperfine>
* Google Benchmark for micro-benchmarks: <https://github.com/google/benchmark>
* `perf stat` (Linux) to check that IPC, branch misses and cache misses explain a difference.
* Public corpora: Silesia (<https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia>), Canterbury, enwik8/9.

---

## 8. Checklist: new project

1. Read the project's CI files and build scripts first. They show which compilers work, the required
   flags, and pinned tool versions.
2. Build it once, unmodified, with the distro or MSYS2 compiler, and run its tests. This is your
   baseline.
3. Find where optimization flags are set (`grep -rn -- '-O[0-3s]' CMakeLists.txt cmake/ *.mak`) and
   make them overridable.
4. Add the variant flags (`-O3`, `-march=x86-64-v3`, LTO, ...) through the build system's official
   knobs. Verify them in the verbose build log.
5. Run the full test suite on every variant and every compiler.
6. Benchmark all variants on one machine, interleaved (section 7).
7. Ship the winner. If you use `-march=x86-64-v3`, document the AVX2 requirement or add a CPU check
   and a generic fallback.

---

## 9. FAQ / troubleshooting

**Q: I passed `-O3` but the binary is identical / no faster.**
A: Something later on the command line (`-O2`) wins. Look at the verbose compile line (section 4).

**Q: `undefined reference to vtable for SomeClass` with a new GCC or with LTO.**
A: Speculative devirtualization references the vtable of a `final` class whose definition you do not
link. Add `-fno-devirtualize-speculatively` (or link the object that defines the class).

**Q: Is there a Windows build of GCC trunk?**
A: Not as of 2026-10. MSYS2 and WinLibs ship releases; WinLibs has occasional *release-branch*
snapshots. Build a Linux-hosted mingw-w64 cross GCC from the weekly snapshot (section 2).

**Q: Is there a Windows build of Clang trunk?**
A: Yes: the llvm-mingw `nightly` release (Windows-hosted zips and Linux/macOS-hosted cross tarballs),
rebuilt daily from LLVM main.

**Q: Which is faster, GCC or Clang?**
A: It depends on the codebase, and often on the individual hot loop. Measure it. See
[section 10](#10-case-study-gcc-17-snapshot-vs-clang-nightly-windows-x64) for one data point.

**Q: Does `-ffast-math` speed up compression, hashing or crypto?**
A: Practically never; those workloads are integer code. It only risks breaking NaN/Inf handling.

**Q: The optimized DLL crashes with "illegal instruction" on some machines.**
A: It was built with `-march=x86-64-v3`/`-mavx2` and the CPU (or hypervisor, or emulator) lacks AVX2.
Ship a generic build too, or dispatch at run time (section 3.2).

**Q: My DLL still needs `libwinpthread-1.dll` / `libstdc++-6.dll`.**
A: Link with `-static`, or use the win32 thread model. Verify with `objdump -p`.

**Q: CMake 4 fails with "Compatibility with CMake < 3.5 has been removed".**
A: Use `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`, or pin CMake 3.x.

**Q: My new `workflow_dispatch` workflow does not appear in the Actions tab.**
A: It must exist on the default branch. Until then, trigger it with `push` on your branch.

**Q: The cache restore fails with permission errors.**
A: Use a cache path under `$HOME` instead of `/opt` or `/usr/local`, and the same path string in the
saving and restoring jobs.

**Q: My self-built cross GCC links nothing: `cannot find -lgcc`, `crtend.o`, `-lmingw32`, `-lkernel32`.**
A: An earlier stage (usually the mingw-w64 CRT) failed and the error was hidden, for example by
`make && make install` under `set -e`. Find the first `error:` in the toolchain log. With GCC 17 trunk +
mingw-w64 v14.0.0 it is the `__stack_chk_guard` type conflict; use mingw-w64 master (section 2.2).

**Q: GCC snapshot build fails in libsanitizer / libgomp / ...**
A: Disable what you do not need (`--disable-libsanitizer --disable-libgomp ...`), or take the
previous weekly snapshot.

**Q: How do I know which compiler and flags built a binary?**
A: `strings bin | grep -E 'GCC: \(|clang version'`. 7-Zip prints `Compiler: ...` in `7z b`. Keep an
`info.txt` (compiler `--version` + flags) next to every artifact.

---

## 10. Case study: GCC 17 snapshot vs Clang nightly, Windows x64

Project: a C/C++ JNI library around the 7-Zip codecs (LZMA/LZMA2, Deflate, BZip2, PPMd, AES, CRC,
SHA, ...). The goal was to build an AVX2-optimized Windows x64 DLL with the newest compilers on GitHub
Actions and pick the faster compiler.

Setup:

* **GCC 17** snapshot `gcc-17-20261011`: Linux-hosted mingw-w64 cross toolchain built in CI (section 2;
  binutils 2.47, mingw-w64 master, UCRT, win32 threads), cached.
* **Clang nightly**: llvm-mingw `nightly` (LLVM main), Linux-hosted cross tarball (UCRT, libc++, lld).
* Variants:
  * `base`: the project's own `-O2`, generic x86-64;
  * `avx2`: `-O3 -march=x86-64-v3 -ffast-math`;
  * `avx2-lto`: `avx2` + `-flto=auto` (GCC) / `-flto` (Clang).
* Every build ran the project's full JUnit suite on a Windows x64 JVM. All builds were benchmarked
  on one `windows-latest` runner:
  * `7zz b -mmt1 -md22` (single thread, pinned) and `7zz b -md22` (all threads): 7 interleaved rounds;
  * `7zz b 1 -mmt1 -mm=*` (every method): 2 rounds;
  * a JNI end-to-end compress/extract benchmark.

Results: *(filled in from the CI run, see below)*

<!-- RESULTS -->

---

## 11. Link collection

Compilers and toolchains
* GCC releases / snapshots: <https://gcc.gnu.org/releases.html>, <https://gcc.gnu.org/pub/gcc/snapshots/>
* GCC 16 changes: <https://gcc.gnu.org/gcc-16/changes.html>; GCC 16.2 announcement (Phoronix): <https://phoronix.com/news/GCC-16.2-Released>
* LLVM releases: <https://github.com/llvm/llvm-project/releases>, release notes: <https://llvm.org/docs/ReleaseNotes.html>, announcements: <https://discourse.llvm.org/c/announce/>
* llvm-mingw: <https://github.com/mstorsjo/llvm-mingw> (README covers the runtime/ABI differences)
* MSYS2 packages: <https://packages.msys2.org>, environments: <https://www.msys2.org/docs/environments/>
* WinLibs: <https://winlibs.com>; gcc-mcf: <https://gcc-mcf.lhmouse.com/>
* mingw-w64: <https://github.com/mingw-w64/mingw-w64>, build howto: <https://github.com/mingw-w64/mingw-w64/blob/master/mingw-w64-doc/howto-build/mingw-w64-howto-build.txt>
* binutils: <https://sourceware.org/pub/binutils/releases/>
* apt.llvm.org (Debian/Ubuntu stable + nightly LLVM): <https://apt.llvm.org>

Optimization references
* GCC optimize options: <https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html>
* GCC x86 options (`-march` levels): <https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html>
* x86-64 psABI micro-architecture levels: <https://gitlab.com/x86-psABIs/x86-64-ABI>
* Clang PGO: <https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization>
* GCC configure options: <https://gcc.gnu.org/install/configure.html>
* BOLT: <https://github.com/llvm/llvm-project/tree/main/bolt>

GitHub Actions
* Hosted runners: <https://docs.github.com/actions/using-github-hosted-runners/about-github-hosted-runners>
* Runner images (installed software): <https://github.com/actions/runner-images>
* Workflow syntax: <https://docs.github.com/actions/writing-workflows/workflow-syntax-for-github-actions>
* Caching: <https://github.com/actions/cache>; artifacts: <https://github.com/actions/upload-artifact>
* REST API for Actions: <https://docs.github.com/rest/actions>
* setup-msys2: <https://github.com/msys2/setup-msys2>

Benchmarking
* hyperfine: <https://github.com/sharkdp/hyperfine>; Google Benchmark: <https://github.com/google/benchmark>
* 7-Zip benchmark: `7-zip.chm` (shipped with 7-Zip) → Command Line Version → Commands → `b`; reference results per CPU: <https://www.7-cpu.com/>
* Windows `start` (affinity/priority): <https://learn.microsoft.com/windows-server/administration/windows-commands/start>
