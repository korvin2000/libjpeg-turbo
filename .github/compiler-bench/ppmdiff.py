"""Compare two binary PPM files (8- or 16-bit samples): ppmdiff.py a.ppm b.ppm [--max N]
Prints how many samples differ and the largest absolute difference; exits 1 if it exceeds --max."""
import argparse
import sys


def load(path):
    d = open(path, "rb").read()
    fields, i = [], 0
    while len(fields) < 4:          # P6 <w> <h> <maxval>
        while d[i:i + 1].isspace():
            i += 1
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        fields.append(d[i:j])
        i = j
    w, h, maxval = int(fields[1]), int(fields[2]), int(fields[3])
    px, n = d[i + 1:], w * h * 3
    if maxval > 255:
        return (w, h, maxval), [px[2 * k] << 8 | px[2 * k + 1] for k in range(n)]
    return (w, h, maxval), list(px[:n])


ap = argparse.ArgumentParser()
ap.add_argument("a")
ap.add_argument("b")
ap.add_argument("--max", type=int, default=0)
a = ap.parse_args()
(ha, pa), (hb, pb) = load(a.a), load(a.b)
if ha != hb:
    sys.exit(f"header mismatch: {ha} vs {hb}")
diffs = [abs(x - y) for x, y in zip(pa, pb)]
worst = max(diffs)
print(f"{ha[0]}x{ha[1]} maxval {ha[2]}: {sum(1 for x in diffs if x)}/{len(diffs)} samples differ, "
      f"max abs diff {worst} (allowed {a.max})")
sys.exit(1 if worst > a.max else 0)
