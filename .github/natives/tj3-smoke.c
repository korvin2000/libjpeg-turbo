/*
 * Smoke test of a shipped TurboJPEG shared library, loaded the way a Java FFM consumer loads it: by
 * absolute path at run time (dlopen / LoadLibrary), plain C tj3* API, no link-time dependency.
 * Compresses a synthetic RGB image (4:2:0, quality 90), decompresses it and checks the round trip.
 * turbojpeg.h is used for the enum values only.
 *
 * Usage: tj3-smoke <path-to-library>
 * Used by .github/natives/build-native.sh (package step).
 */
#include <stdio.h>
#include <stdlib.h>
#include "turbojpeg.h"
#ifdef _WIN32
#include <windows.h>
#define LOADLIB(p)  ((void *)LoadLibraryA(p))
#define LOADSYM(h, n)  ((void *)GetProcAddress((HMODULE)(h), n))
#else
#include <dlfcn.h>
#define LOADLIB(p)  dlopen(p, RTLD_NOW | RTLD_LOCAL)
#define LOADSYM(h, n)  dlsym(h, n)
#endif

typedef tjhandle (*initv_t)(int, int);
typedef tjhandle (*init_t)(int);
typedef int (*set_t)(tjhandle, int, int);
typedef int (*get_t)(tjhandle, int);
typedef int (*comp8_t)(tjhandle, const unsigned char *, int, int, int, int, unsigned char **,
                       size_t *);
typedef int (*dhdr_t)(tjhandle, const unsigned char *, size_t);
typedef int (*dec8_t)(tjhandle, const unsigned char *, size_t, unsigned char *, int, int);
typedef void (*free_t)(void *);
typedef void (*destroy_t)(tjhandle);
typedef char *(*err_t)(tjhandle);

static void *sym(void *lib, const char *name)
{
  void *f = LOADSYM(lib, name);
  if (!f) {
    fprintf(stderr, "FAIL: symbol %s not found\n", name);
    exit(1);
  }
  return f;
}

int main(int argc, char **argv)
{
  enum { W = 227, H = 149 };
  static unsigned char src[W * H * 3], dst[W * H * 3];
  unsigned char *jpeg = NULL;
  size_t jpegSize = 0;
  int x, y, i, maxErr = 0;
  void *lib;

  if (argc != 2) {
    fprintf(stderr, "usage: %s <library>\n", argv[0]);
    return 2;
  }
  if (!(lib = LOADLIB(argv[1]))) {
#ifdef _WIN32
    fprintf(stderr, "FAIL: LoadLibrary(%s): error %lu\n", argv[1], GetLastError());
#else
    fprintf(stderr, "FAIL: dlopen: %s\n", dlerror());
#endif
    return 1;
  }
  {
    initv_t initVersion = (initv_t)sym(lib, "tj3InitVersion");
    init_t init = (init_t)sym(lib, "tj3Init");
    set_t set = (set_t)sym(lib, "tj3Set");
    get_t get = (get_t)sym(lib, "tj3Get");
    comp8_t compress8 = (comp8_t)sym(lib, "tj3Compress8");
    dhdr_t decompressHeader = (dhdr_t)sym(lib, "tj3DecompressHeader");
    dec8_t decompress8 = (dec8_t)sym(lib, "tj3Decompress8");
    free_t tjfree = (free_t)sym(lib, "tj3Free");
    destroy_t destroy = (destroy_t)sym(lib, "tj3Destroy");
    err_t errStr = (err_t)sym(lib, "tj3GetErrorStr");
    tjhandle c, d, legacy;

    for (y = 0; y < H; y++)
      for (x = 0; x < W; x++) {
        unsigned char *p = &src[(y * W + x) * 3];
        p[0] = (unsigned char)(x * 255 / (W - 1));
        p[1] = (unsigned char)(y * 255 / (H - 1));
        p[2] = (unsigned char)((x + y) * 255 / (W + H - 2));
      }

    if (!(legacy = init(TJINIT_DECOMPRESS))) {
      fprintf(stderr, "FAIL: tj3Init: %s\n", errStr(NULL));
      return 1;
    }
    destroy(legacy);

    if (!(c = initVersion(TJINIT_COMPRESS, TURBOJPEG_VERSION_NUMBER)) ||
        !(d = initVersion(TJINIT_DECOMPRESS, TURBOJPEG_VERSION_NUMBER))) {
      fprintf(stderr, "FAIL: tj3InitVersion: %s\n", errStr(NULL));
      return 1;
    }
    if (set(c, TJPARAM_QUALITY, 90) || set(c, TJPARAM_SUBSAMP, TJSAMP_420) ||
        compress8(c, src, W, 0, H, TJPF_RGB, &jpeg, &jpegSize)) {
      fprintf(stderr, "FAIL: compress: %s\n", errStr(c));
      return 1;
    }
    if (decompressHeader(d, jpeg, jpegSize) || get(d, TJPARAM_JPEGWIDTH) != W ||
        get(d, TJPARAM_JPEGHEIGHT) != H || get(d, TJPARAM_SUBSAMP) != TJSAMP_420 ||
        decompress8(d, jpeg, jpegSize, dst, 0, TJPF_RGB)) {
      fprintf(stderr, "FAIL: decompress: %s\n", errStr(d));
      return 1;
    }
    for (i = 0; i < W * H * 3; i++) {
      int e = abs((int)src[i] - (int)dst[i]);
      if (e > maxErr) maxErr = e;
    }
    printf("tj3 round trip %dx%d RGB q90 4:2:0: %lu-byte JPEG, max abs error %d\n", W, H,
           (unsigned long)jpegSize, maxErr);
    tjfree(jpeg);
    destroy(c);
    destroy(d);
    if (jpegSize < 500 || maxErr > 24) {
      fprintf(stderr, "FAIL: unexpected round trip result\n");
      return 1;
    }
  }
  printf("OK\n");
  return 0;
}
