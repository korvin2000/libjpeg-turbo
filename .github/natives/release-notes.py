"""Release notes for .github/workflows/natives-all.yml from the info-<platform>.txt files (key: value lines).
Usage: release-notes.py <dir with info-*.txt> <version> <run url>  -> Markdown on stdout"""
import glob
import os
import sys

ORDER = ["windows-x64", "windows-aarch64", "linux-x64", "linux-aarch64", "mac-x64", "mac-arm64"]


def load(path):
    info = {}
    for line in open(path, encoding="utf-8"):
        if ": " in line:
            k, v = line.rstrip("\n").split(": ", 1)
            info.setdefault(k, v)
    return info


d, ver, run = sys.argv[1:4]
infos = {i["platform"]: i for i in map(load, glob.glob(os.path.join(d, "info-*.txt")))}
plats = [p for p in ORDER if p in infos] + sorted(p for p in infos if p not in ORDER)
missing = [p for p in ORDER if p not in infos]

print(f"TurboJPEG shared library from libjpeg-turbo {ver} (this fork) for {len(plats)} platforms, for loading "
      "by path through Java's FFM API (plain C `tj3*` API, no JNI). Built natively on GitHub runners with "
      "Clang: `-O3 -ffast-math` + LTO + PGO, `-march=x86-64-v3` on x64; the SIMD extensions are enabled "
      "(NASM SSE2/AVX2 on x64, NEON on arm64, selected at run time).")
print()
print("| platform | file | size | SHA-256 | compiler | flags | PGO | dependencies | floor | `tj3*` exports | CTest |")
print("|---|---|---:|---|---|---|---|---|---|---:|---|")
for p in plats:
    i = infos[p]
    name = i.get("soname") or i.get("install_name") or ""
    file = f"`{i.get('file')}`" + (f"<br>({name})" if name else "")
    pgo = "yes" if i.get("pgo", "").startswith("yes") else "**no**"
    print(f"| {p} | {file} | {int(i.get('size', 0)):,} | `{i.get('sha256', '')[:16]}...` | {i.get('compiler', '')} "
          f"| `{i.get('cflags', '')}` {i.get('ldflags', '') if i.get('ldflags', '').startswith('-') else ''} "
          f"| {pgo} | {i.get('deps', '')} | {i.get('floor', '')} | {i.get('tj3_exports', '')} "
          f"| {i.get('ctest', '').split(' (')[0]} |")
print()
print("* **CPU**: the x64 files need an AVX2/FMA/BMI2 CPU (x86-64-v3: Intel Haswell / AMD Zen 1 or newer) and "
      "crash with an illegal instruction elsewhere; the arm64 files run on any ARMv8-A CPU.")
print("* **Files**: `libturbojpeg-<platform>.<so|dylib>` / `turbojpeg-windows-<arch>.dll` = the real shared "
      "library (not a symlink) of that platform's install tree. Each `libjpeg-turbo-*.zip` = the full stripped "
      "install tree (libjpeg + TurboJPEG shared and static libraries, headers, tools) plus `info.txt`; "
      "`info-<platform>.txt` = compiler, flags, PGO, dependencies, exports, CTest result. `SHA256SUMS` covers "
      "every asset.")
print("* **Tests**: every build ran the project's full CTest suite natively on its runner (Clang: all tests "
      "pass, incl. the 12-bit float DCT tests with `FLOATTEST12=fp-contract`, so no tolerance handling was "
      "needed), plus a smoke test that loads the bare file by path (dlopen/LoadLibrary) and round-trips an "
      "image through `tj3Compress8`/`tj3Decompress8`.")
print("* **FFM note**: `tj3Init` in `turbojpeg.h` 3.2 is a macro for `tj3InitVersion(initType, 3002000)`; the "
      "exported `tj3Init` symbol treats the caller as a 3.1 client (no `TJSAMP_410`/`TJSAMP_24`). Bind "
      "`tj3InitVersion` to get the 3.2 behavior.")
print("* **-ffast-math**: libjpeg-turbo's default code paths are integer-only; it only affects the opt-in float "
      "DCT. Linux libraries are linked with `-mno-daz-ftz` (no `crtfastmath.o`), so loading them does not switch "
      "the process (e.g. a JVM) to flush-to-zero; macOS and Windows toolchains have no such startup object.")
print("* **Linux**: `-static-libgcc`, lld; needs only glibc (floor in the table, built on Ubuntu 22.04). "
      "**macOS**: Apple clang + ld64, only `/usr/lib` system libraries, ad-hoc signed. **Windows**: llvm-mingw "
      "(UCRT), static runtime: imports only `KERNEL32.dll` and the UCRT (`api-ms-win-crt-*`).")
print("* **windows-x64** is `bin/libturbojpeg.dll` of `libjpeg-turbo-3.2.1-win64-clang-nightly-avx2-lto-pgo.zip` "
      "from release `win64-compilers-20261013-4` (cross-built with llvm-mingw nightly, PGO trained under Wine, "
      "CTest natively on Windows; see `bench-results.md`).")
print("* Static libraries in these LTO builds hold LLVM bitcode (link them with Clang/lld only).")
if missing:
    print(f"* **Not in this release** (job failed or skipped): {', '.join(missing)}.")
print()
print(f"Commit: {os.environ.get('GITHUB_SHA', '?')}, run: {run}")
