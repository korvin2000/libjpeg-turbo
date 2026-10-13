"""Fail if a static library holds link-time-optimization IR instead of machine code.

check-static-libs.py lib/*.a ...   (GNU and BSD/macOS 'ar' formats)
LLVM bitcode (raw 'BC\\xC0\\xDE' or the Darwin wrapper 0x0B17C0DE) and GCC LTO objects ('.gnu.lto_'
sections) only link with the compiler that produced them; the release ships plain object code."""
import sys

BITCODE = (b"BC\xc0\xde", b"\xde\xc0\x17\x0b")


def members(path):
    d = open(path, "rb").read()
    if not d.startswith(b"!<arch>\n"):
        raise ValueError(f"{path}: not an ar archive")
    i = 8
    while i + 60 <= len(d):
        name, size = d[i:i + 16].decode("latin-1").strip(), int(d[i + 48:i + 58])
        body = d[i + 60:i + 60 + size]
        if name.startswith("#1/"):                  # BSD: the name precedes the data
            n = int(name[3:])
            name, body = body[:n].rstrip(b"\0").decode("latin-1"), body[n:]
        if name not in ("/", "//", "/SYM64/") and not name.startswith("__.SYMDEF"):  # symbol/name tables
            yield name, body
        i += 60 + size + (size & 1)


bad = 0
for lib in sys.argv[1:]:
    objs = list(members(lib))
    ir = [n for n, b in objs if b.startswith(BITCODE) or b".gnu.lto_" in b]
    print(f"{lib}: {len(objs)} objects, {len(ir)} with LTO IR")
    if ir or not objs:
        print(f"::error::{lib} contains LTO IR objects ({', '.join(ir[:5])}) or no objects")
        bad = 1
sys.exit(bad)
