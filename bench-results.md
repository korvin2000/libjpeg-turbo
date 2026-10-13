# libjpeg-turbo 3.2.1 on Windows x64: GCC vs Clang benchmark

Date: 2026-10-13. CI run: <https://github.com/korvin2000/libjpeg-turbo/actions/runs/38403143315>.
Release (all tested builds): <https://github.com/korvin2000/libjpeg-turbo/releases/tag/win64-compilers-20261013-4>.
Workflow: [.github/workflows/windows-x64-compilers.yml](.github/workflows/windows-x64-compilers.yml),
scripts in [.github/compiler-bench/](.github/compiler-bench/).

## Result

**Fastest build: `clang-nightly-avx2-lto-pgo`** (Clang 24.0.0git / llvm-mingw nightly,
`-O3 -march=x86-64-v3 -ffast-math -flto` + PGO). Overall it is **13.4% faster** than the GCC 17 baseline
build. It is 4.5% faster than the best GCC build (`gcc17-avx2-lto-pgo`, +8.5%).
Download: `libjpeg-turbo-3.2.1-win64-clang-nightly-avx2-lto-pgo.zip` from the release. It needs an
AVX2/FMA/BMI2 CPU (Intel Haswell / AMD Zen 1 or newer). For any other x86-64 CPU use a `*-base` zip.

| rank | build | overall | 8-bit SIMD workloads | plain-C workloads |
|---:|---|---:|---:|---:|
| 1 | **clang-nightly-avx2-lto-pgo** | **1.134** | **1.064** | 1.234 |
| 2 | clang-nightly-avx2 | 1.103 | 1.003 | **1.252** |
| 3 | clang23-avx2-lto | 1.100 | 1.014 | 1.227 |
| 4 | clang-nightly-avx2-lto | 1.099 | 1.002 | 1.244 |
| 5 | gcc17-avx2-lto-pgo | 1.085 | 1.033 | 1.160 |
| 6 | gcc17-avx2 | 1.070 | 1.009 | 1.157 |
| 7 | gcc17-avx2-lto | 1.065 | 0.999 | 1.161 |
| 8 | gcc16-avx2-lto | 1.035 | 1.010 | 1.071 |
| 9 | clang-nightly-base | 1.008 | 0.987 | 1.036 |
| 10 | gcc17-base | 1.000 | 1.000 | 1.000 |

Score = geometric mean of compression and decompression speed ratios against `gcc17-base`.
"8-bit SIMD" = the `420`, `444`, `420-prog` and `420-arith` workloads. "Plain C" = `420-12bit`,
`lossless-16bit` and `420-nosimd`.

## Setup

* **Compilers**
  * GCC 17.0.0 snapshot `gcc-17-20261011`: Linux-hosted mingw-w64 cross compiler built in CI
    (binutils 2.47, mingw-w64 master `63ebe6cd`, UCRT, win32 threads).
  * Clang 24.0.0git (llvm-mingw nightly, LLVM `dff64a2b`; UCRT, lld).
  * References: GCC 16.2.0 (same cross recipe) and Clang 23.1.3 (llvm-mingw 20261006).
* **Variants**
  * `base`: the project defaults (Release = `-O3`, generic x86-64).
  * `avx2`: `-O3 -march=x86-64-v3 -ffast-math`. `-ffast-math` includes `-funsafe-math-optimizations`.
  * `avx2-lto`: `avx2` plus `-flto` (Clang) or `-flto=auto -ffat-lto-objects` (GCC).
  * `avx2-lto-pgo`: `avx2-lto` plus PGO. Training ran the instrumented tjbench, cjpeg, djpeg and
    jpegtran under Wine on the repo's `testimages/`, not on the benchmark images.
  * The NASM SIMD extensions (SSE2/AVX2, selected at run time) are in every build. Runtime is
    linked statically, so there are no MinGW DLLs.
* **Machine**: one GitHub `windows-latest` runner, AMD EPYC 9V45 (Zen 5). Every build was
  benchmarked on that same machine.
* **Method**
  * `tjbench` (single-threaded, pinned to CPU 1, high priority), `-benchtime 1.0 -warmup 0.25`.
  * Each workload compresses the image and then decompresses the result.
  * 7 interleaved rounds in rotating order; the reported value is the median.
  * Images: `nightshot_iso_100.ppm` (3136x2352) and `artificial.ppm` (3072x2048) from the
    imagecompression.info 8-bit set. libjpeg-turbo.org uses the same images for its own performance
    pages.
* **Workloads** (quality 95)
  * `420`, `444`: baseline Huffman.
  * `420-prog`: progressive.
  * `420-arith`: arithmetic coding.
  * `420-12bit`: 12-bit samples, with no SIMD at all.
  * `lossless-16bit`: lossless JPEG with 16-bit samples.
  * `420-nosimd`: `JSIMD_FORCENONE=1`, so the whole 8-bit pipeline runs as compiler-generated code.
* **Noise**: round-to-round spread on the shared runner was 6-12% (max/min). Treat differences
  below about 3% as noise. An earlier 5-round run (without PGO, run 38397238788) agreed on the main
  conclusions: the Clang AVX2 builds were on top and every `avx2` build beat `base`. Builds that
  were within 3% of each other swapped places between the two runs.

## Findings

Speed ratios per optimization step, as overall score and per workload (compression / decompression):

| comparison | all | 420 | 444 | 420-prog | 420-arith | 420-12bit | lossless-16bit | 420-nosimd |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `-march=x86-64-v3 -ffast-math` vs base (Clang) | 1.094 | 1.01/0.99 | 1.01/1.00 | 0.99/1.09 | 1.00/1.04 | 1.17/1.19 | 1.02/1.01 | 2.00/1.07 |
| `-march=x86-64-v3 -ffast-math` vs base (GCC 17) | 1.070 | 1.03/1.00 | 1.01/1.01 | 0.99/1.03 | 1.02/0.98 | 1.08/1.08 | 0.98/1.04 | 1.92/1.04 |
| + LTO (Clang) | 0.997 | 0.99/1.02 | 1.00/1.03 | 1.01/1.00 | 1.00/0.95 | 0.99/1.00 | 0.98/1.01 | 0.98/1.00 |
| + LTO (GCC 17) | 0.996 | 0.99/1.01 | 0.98/1.00 | 1.00/0.97 | 0.98/0.98 | 1.04/1.02 | 0.98/0.99 | 1.00/0.99 |
| + PGO (Clang) | 1.031 | 1.00/1.00 | 1.00/1.02 | 1.16/1.09 | 1.12/1.12 | 0.84/0.98 | 1.02/1.05 | 1.07/1.01 |
| + PGO (GCC 17) | 1.019 | 1.01/1.01 | 1.02/1.03 | 1.13/0.91 | 1.13/1.05 | 0.95/1.00 | 1.00/1.07 | 0.99/0.99 |
| Clang vs GCC 17, `base` | 1.008 | 1.03/1.01 | 1.01/1.00 | 0.98/0.90 | 1.02/0.95 | 1.06/0.96 | 1.04/1.04 | 1.04/1.08 |
| Clang vs GCC 17, `avx2` | 1.031 | 1.02/1.00 | 1.01/0.99 | 0.98/0.95 | 1.00/1.01 | 1.15/1.05 | 1.08/1.02 | 1.09/1.11 |
| Clang vs GCC 17, `avx2-lto-pgo` | 1.045 | 1.01/0.99 | 1.01/1.01 | 1.02/1.17 | 1.00/1.06 | 0.97/1.02 | 1.10/1.01 | 1.14/1.15 |
| Clang 24 nightly vs Clang 23.1.3 (`avx2-lto`) | 0.999 | 1.00/0.98 | 0.99/0.99 | 0.98/1.04 | 0.98/0.95 | 1.16/0.99 | 0.98/1.00 | 0.98/0.99 |
| GCC 17 snapshot vs GCC 16.2 (`avx2-lto`) | 1.029 | 1.00/1.00 | 0.97/1.02 | 1.00/0.99 | 0.97/0.97 | 1.31/1.02 | 1.26/0.98 | 0.99/0.99 |

1. **The 8-bit baseline paths (`420`, `444`) barely depend on the compiler.** Their hot loops (color
   conversion, DCT, chroma resampling, Huffman encoding) are hand-written NASM, picked at run time.
   Every build lands within about ±3% (noise) there, even the generic `base` builds.
2. **`-march=x86-64-v3` is the biggest compiler-side win on the C code paths.** 8-bit encoding without
   the SIMD extensions runs about 2x faster, because the compilers auto-vectorize the C color
   conversion and downsampling. 12-bit gains 8-19%. Overall: +9.4% (Clang), +7.0% (GCC).
3. **LTO alone does nothing measurable** (-0.3% / -0.4%, within noise). Likely reason: libjpeg-turbo
   calls its hot functions through function pointers (the libjpeg module design), which leaves
   cross-module inlining little to work with.
4. **PGO helps the entropy coders**: progressive and arithmetic coding run +12-16% faster with both
   compilers. Clang also decodes progressive JPEGs +9% faster. GCC's progressive decode lost 9%, and
   Clang's 12-bit encode lost 16%; the training set holds only a small 12-bit image, so those paths
   were under-trained. A larger, more representative training set should remove these regressions.
5. **Clang beats GCC on the plain-C paths**: lossless, 12-bit and no-SIMD workloads run up to +15% faster
   with equal flags, which adds up to +3-4.5% overall. GCC 17 PGO comes close on the SIMD workloads
   (1.033 vs 1.064).
6. **Nightly vs stable**: Clang 24 nightly equals Clang 23.1.3 within noise. The GCC 17 snapshot beats
   GCC 16.2 by 2.9%, mainly in 12-bit (+31%) and lossless 16-bit (+26%) encoding, where GCC 16.2 is
   the slowest build.
7. **`-ffast-math` / unsafe math has no performance role here.** libjpeg-turbo's default code is
   integer-only, and only the opt-in float DCT uses floating point. Every build produces JPEG files of
   identical size in every workload. The one observable effect is in GCC's opt-in 12-bit float IDCT:
   12 of 101,469 samples differ by 1 LSB (see Correctness).

## Correctness

* Every build ran the project's full CTest suite **natively on Windows**: 662 tests on the
  cross-built EXEs and DLLs (the swapped-in binaries run against a natively configured CTest tree).
  All Clang builds and both `base` builds pass all 662.
* In the GCC `avx2*` builds, `-ffast-math` plus FMA rounds the opt-in **12-bit float IDCT**
  differently from every reference checksum: at most 1 LSB (of 4095), in 12 of 101,469 samples. For
  those builds, CI replaces the two exact-checksum tests (`djpeg12-*-3x2-float-prog-cmp`) with a
  1-LSB tolerance check against the `gcc17-base` decode
  ([ppmdiff.py](.github/compiler-bench/ppmdiff.py)). The other 660 tests pass.
* All DLLs and EXEs import only `KERNEL32.dll` and the UCRT (`api-ms-win-crt-*`). There are no
  libgcc, libwinpthread or libc++ dependencies.
* The winning zip was also smoke-tested outside CI (tjbench, cjpeg/djpeg round trip) on an AMD Ryzen 5
  5500U (Zen 2).

## Caveats

* All numbers come from a single CPU model (AMD Zen 5) and single-threaded runs. On Intel cores the
  ranking of builds within a few % of each other may change.
* `avx2*` builds crash with "illegal instruction" on CPUs without AVX2/FMA/BMI2.
* Static libraries (`lib/*.a`) in the Clang `-lto` builds contain LLVM bitcode, so only Clang/lld can
  link them. GCC LTO builds use fat objects, which any linker can use.

## Reproduce

Actions → *Windows x64 compilers (GCC snapshot vs Clang nightly) build, test, benchmark + release* →
*Run workflow*. Inputs: `gcc_snapshot` (empty = latest `LATEST-17`), `stable` (also build GCC 16.2 +
Clang 23), `rounds` (benchmark rounds) and `release` (publish a GitHub release ranked by the
benchmark). The workflow also runs on push to `compiler-bench`, and pushing a tag `win64-*` publishes
a release.

## All builds and per-workload results

### Builds

| build | compiler | flags |
|---|---|---|
| clang-nightly-avx2 | clang version 24.0.0git (https://github.com/llvm/llvm-project.git dff64a2bf54d0abfc3c2232abb04ec28c40087ed) | `-O3 -march=x86-64-v3 -ffast-math` |
| clang-nightly-avx2-lto | clang version 24.0.0git (https://github.com/llvm/llvm-project.git dff64a2bf54d0abfc3c2232abb04ec28c40087ed) | `-O3 -march=x86-64-v3 -ffast-math -flto` |
| clang-nightly-avx2-lto-pgo | clang version 24.0.0git (https://github.com/llvm/llvm-project.git dff64a2bf54d0abfc3c2232abb04ec28c40087ed) | `-O3 -march=x86-64-v3 -ffast-math -flto -fprofile-use=/home/runner/work/libjpeg-turbo/libjpeg-turbo/dist/work-clang-nightly-avx2-lto-pgo/pgo-data/merged.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date` |
| clang-nightly-base | clang version 24.0.0git (https://github.com/llvm/llvm-project.git dff64a2bf54d0abfc3c2232abb04ec28c40087ed) | `(project defaults: -O3, generic x86-64)` |
| clang23-avx2-lto | clang version 23.1.3 (https://github.com/llvm/llvm-project.git 0d261d1ca552c95a8f007e061c787ac7132fbcbc) | `-O3 -march=x86-64-v3 -ffast-math -flto` |
| gcc16-avx2-lto | x86_64-w64-mingw32-gcc (libjpeg-turbo CI cross, gcc-16.2.0) 16.2.0 | `-O3 -march=x86-64-v3 -ffast-math -flto=auto -ffat-lto-objects` |
| gcc17-avx2 | x86_64-w64-mingw32-gcc (libjpeg-turbo CI cross, gcc-17-20261011) 17.0.0 20261011 (experimental) | `-O3 -march=x86-64-v3 -ffast-math` |
| gcc17-avx2-lto | x86_64-w64-mingw32-gcc (libjpeg-turbo CI cross, gcc-17-20261011) 17.0.0 20261011 (experimental) | `-O3 -march=x86-64-v3 -ffast-math -flto=auto -ffat-lto-objects` |
| gcc17-avx2-lto-pgo | x86_64-w64-mingw32-gcc (libjpeg-turbo CI cross, gcc-17-20261011) 17.0.0 20261011 (experimental) | `-O3 -march=x86-64-v3 -ffast-math -flto=auto -ffat-lto-objects -fprofile-use=/home/runner/work/libjpeg-turbo/libjpeg-turbo/dist/work-gcc17-avx2-lto-pgo/pgo-data -fprofile-partial-training -Wno-missing-profile` |
| gcc17-base | x86_64-w64-mingw32-gcc (libjpeg-turbo CI cross, gcc-17-20261011) 17.0.0 20261011 (experimental) | `(project defaults: -O3, generic x86-64)` |

### Compression, Mpixels/s (geomean over images) - higher is better

| workload | clang-nightly-avx2 | clang-nightly-avx2-lto | clang-nightly-avx2-lto-pgo | clang-nightly-base | clang23-avx2-lto | gcc16-avx2-lto | gcc17-avx2 | gcc17-avx2-lto | gcc17-avx2-lto-pgo | gcc17-base |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 420 | **549.9** | 543.6 | 545.1 | 542.6 | 541.6 | 537.9 | 541.4 | 537.0 | 542.4 | 524.7 |
| 444 | 333.6 | 334.0 | 334.5 | 330.7 | **336.7** | 334.4 | 331.1 | 324.2 | 331.0 | 327.9 |
| 420-prog | 73.6 | 74.6 | **86.7** | 74.3 | 76.0 | 74.7 | 75.1 | 75.1 | 85.1 | 76.0 |
| 420-arith | 61.4 | 61.4 | **68.5** | 61.6 | 62.9 | 62.7 | 61.7 | 60.6 | 68.4 | 60.5 |
| 420-12bit | **80.0** | 79.4 | 66.8 | 68.1 | 68.4 | 55.6 | 69.7 | 72.7 | 68.8 | 64.3 |
| lossless-16bit | 39.9 | 39.3 | 40.0 | 38.9 | **40.2** | 28.6 | 36.9 | 36.1 | 36.2 | 37.5 |
| 420-nosimd | 223.5 | 218.5 | **232.8** | 111.6 | 224.0 | 206.3 | 205.1 | 204.9 | 203.7 | 107.0 |

### Decompression, Mpixels/s (geomean over images) - higher is better

| workload | clang-nightly-avx2 | clang-nightly-avx2-lto | clang-nightly-avx2-lto-pgo | clang-nightly-base | clang23-avx2-lto | gcc16-avx2-lto | gcc17-avx2 | gcc17-avx2-lto | gcc17-avx2-lto-pgo | gcc17-base |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 420 | 492.8 | 500.3 | 502.1 | 497.8 | **511.7** | 499.7 | 494.4 | 500.7 | 507.9 | 492.9 |
| 444 | 339.1 | 347.8 | **354.2** | 339.0 | 351.4 | 337.3 | 342.7 | 343.3 | 352.0 | 339.5 |
| 420-prog | 161.2 | 160.4 | **174.4** | 148.3 | 154.7 | 166.9 | 169.8 | 164.6 | 149.6 | 164.4 |
| 420-arith | 62.3 | 59.4 | **66.6** | 59.7 | 62.7 | 62.0 | 61.4 | 60.2 | 63.1 | 62.5 |
| 420-12bit | 151.8 | 151.6 | 149.2 | 127.9 | **153.2** | 144.0 | 144.2 | 147.3 | 146.8 | 133.5 |
| lossless-16bit | 67.5 | 67.9 | **71.4** | 66.6 | 68.2 | 67.3 | 66.4 | 65.8 | 70.4 | 63.9 |
| 420-nosimd | 243.4 | 244.3 | **246.4** | 227.0 | 245.9 | 219.1 | 218.9 | 216.5 | 214.4 | 209.7 |

