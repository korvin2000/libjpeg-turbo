"""Benchmark driver for .github/workflows/windows-x64-compilers.yml (runs on the Windows runner).

Every build (<builds-dir>/<compiler>-<variant>/install/bin/tjbench.exe + libturbojpeg.dll, info.txt) is
run on the SAME machine, in interleaved rounds whose order rotates, so runner drift / noisy neighbours
hit all builds alike. tjbench is single-threaded: pinned to CPU 1, high priority. For every corpus
image and workload it compresses the image and decompresses the result; results are Mpixels/s
(medians over rounds).

Workloads (8-bit unless noted; quality 95):
  420, 444        baseline Huffman (SIMD color conversion / DCT / Huffman encode in NASM)
  420-prog        progressive (progressive Huffman decode is plain C)
  420-arith       arithmetic entropy coding (plain C)
  420-12bit       12-bit samples: no SIMD at all, pure compiler output
  lossless-16bit  lossless JPEG (PSV 1), 16-bit samples (plain C)
  420-nosimd      JSIMD_FORCENONE=1: the whole 8-bit pipeline in compiler-generated code
"""
import argparse
import json
import math
import os
import re
import statistics
import subprocess
import sys
import time

HIGH = getattr(subprocess, "HIGH_PRIORITY_CLASS", 0)
PIN1 = 0b10  # CPU 1 (not CPU 0, which takes most interrupts)

WORKLOADS = [  # name, tjbench args after the image, extra environment, group
    ("420", ["95", "-subsamp", "420"], {}, "simd"),
    ("444", ["95", "-subsamp", "444"], {}, "simd"),
    ("420-prog", ["95", "-subsamp", "420", "-progressive"], {}, "simd"),
    ("420-arith", ["95", "-subsamp", "420", "-arithmetic"], {}, "simd"),
    ("420-12bit", ["95", "-subsamp", "420", "-precision", "12"], {}, "c"),
    ("lossless-16bit", ["1", "-lossless", "-precision", "16", "-subsamp", "444"], {}, "c"),
    ("420-nosimd", ["95", "-subsamp", "420"], {"JSIMD_FORCENONE": "1"}, "c"),
]
NUM = re.compile(r"^\s*[0-9]+(\.[0-9]+)?\s*$")


def run(cmd, env=None, affinity=PIN1, timeout=600):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
                         encoding="utf-8", errors="replace", creationflags=HIGH)
    if affinity and os.name == "nt":
        import ctypes
        ctypes.windll.kernel32.SetProcessAffinityMask(int(p._handle), affinity)
    out, _ = p.communicate(timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(f"{cmd} failed ({p.returncode}):\n{out[-3000:]}")
    return out


def tjbench(exe, image, wl, benchtime, warmup):
    """-qq prints one number per line: compress Mpix/s, compression ratio, decompress Mpix/s."""
    _, args, extra_env, _ = wl
    env = dict(os.environ, **extra_env)
    out = run([exe, image] + args + ["-qq", "-nowrite", "-benchtime", str(benchtime),
                                     "-warmup", str(warmup)], env=env)
    nums = [float(l) for l in out.splitlines() if NUM.match(l)]
    if len(nums) != 3:
        raise ValueError(f"unexpected tjbench output for {wl[0]}:\n{out[-2000:]}")
    return {"comp": nums[0], "ratio": nums[1], "decomp": nums[2]}


def geomean(xs):
    xs = [x for x in xs if x > 0]
    return math.exp(sum(map(math.log, xs)) / len(xs)) if xs else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--builds-dir", required=True)
    ap.add_argument("--images", nargs="+", required=True)
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--benchtime", type=float, default=1.0)
    ap.add_argument("--warmup", type=float, default=0.25)
    ap.add_argument("--baseline", default="gcc17-base")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    exe_of = lambda b: os.path.join(a.builds_dir, b, "install", "bin", "tjbench.exe")
    builds = sorted(d for d in os.listdir(a.builds_dir) if os.path.isfile(exe_of(d)))
    if not builds:
        sys.exit("no builds found")
    info = {}
    for b in builds:
        p = os.path.join(a.builds_dir, b, "info.txt")
        info[b] = open(p, encoding="utf-8").read().strip() if os.path.exists(p) else ""
    base = a.baseline if a.baseline in builds else builds[0]
    images = {os.path.splitext(os.path.basename(i))[0]: i for i in a.images}

    # probe: every workload must run with every build (warm-up too)
    workloads = []
    for wl in WORKLOADS:
        try:
            for b in builds:
                tjbench(exe_of(b), a.images[0], wl, 0.05, 0)
            workloads.append(wl)
        except Exception as e:  # noqa: BLE001 - report and drop the workload, keep benchmarking the rest
            print(f"::warning::workload {wl[0]} dropped: {e}", flush=True)
    cpu = subprocess.run(["powershell", "-NoProfile", "-Command",
                          "(Get-CimInstance Win32_Processor).Name"],
                         capture_output=True, text=True).stdout.strip() if os.name == "nt" else ""

    keys = [(w[0], img) for w in workloads for img in images]
    raw = {b: {f"{w}|{i}": [] for w, i in keys} for b in builds}
    t0 = time.time()

    def rotation(r):
        order = builds[r % len(builds):] + builds[:r % len(builds)]
        return order[::-1] if r % 2 else order

    for r in range(a.rounds):
        for b in rotation(r):
            for wl in workloads:
                for img, path in images.items():
                    raw[b][f"{wl[0]}|{img}"].append(tjbench(exe_of(b), path, wl, a.benchtime, a.warmup))
            print(f"[{time.time() - t0:6.0f}s] round {r + 1}/{a.rounds} {b}", flush=True)

    med = {b: {k: {m: statistics.median(x[m] for x in v) for m in ("comp", "decomp", "ratio")}
               for k, v in raw[b].items()} for b in builds}

    def score(b, group=None):
        return geomean([med[b][f"{w}|{i}"][m] / med[base][f"{w}|{i}"][m]
                        for w, i in keys for m in ("comp", "decomp")
                        if group is None or dict((x[0], x[3]) for x in workloads)[w] == group])

    scores = {b: {"all": score(b), "simd": score(b, "simd"), "c": score(b, "c")} for b in builds}
    ranking = sorted(builds, key=lambda b: -scores[b]["all"])
    with open(os.path.join(a.out, "results.json"), "w", encoding="utf-8") as f:
        json.dump({"cpu": cpu, "info": info, "baseline": base, "raw": raw, "scores": scores,
                   "ranking": ranking}, f, indent=1)

    # ---------------------------------------------------------------- summary (markdown)
    md = ["## libjpeg-turbo Windows x64 compiler benchmark (tjbench)", "",
          f"CPU: `{cpu}`; {a.rounds} interleaved rounds (rotating order), single thread pinned to CPU 1, "
          f"`-benchtime {a.benchtime} -warmup {a.warmup}`; medians; speed ratios relative to `{base}`.",
          f"Images: {', '.join(f'`{i}`' for i in images)}.", "",
          "### Builds", "", "| build | compiler | flags |", "|---|---|---|"]
    for b in builds:
        kv = dict(l.split(":", 1) for l in info[b].splitlines() if ":" in l)
        md.append(f"| {b} | {kv.get('compiler', '').strip()} | `{kv.get('flags', '').strip()}` |")

    md += ["", "### Overall (geometric mean of compress + decompress speed ratios vs base) - higher is better", "",
           "| rank | build | all | SIMD workloads | plain-C workloads |", "|---:|---|---:|---:|---:|"]
    for n, b in enumerate(ranking, 1):
        s = scores[b]
        md.append(f"| {n} | **{b}** | **{s['all']:.3f}** | {s['simd']:.3f} | {s['c']:.3f} |" if n == 1 else
                  f"| {n} | {b} | {s['all']:.3f} | {s['simd']:.3f} | {s['c']:.3f} |")

    for m, title in (("comp", "Compression"), ("decomp", "Decompression")):
        md += ["", f"### {title}, Mpixels/s (geomean over images) - higher is better", "",
               "| workload | " + " | ".join(builds) + " |", "|---|" + "---:|" * len(builds)]
        for w in workloads:
            vals = {b: geomean([med[b][f"{w[0]}|{i}"][m] for i in images]) for b in builds}
            best = max(vals.values())
            md.append(f"| {w[0]} | " + " | ".join(
                (f"**{vals[b]:.1f}**" if vals[b] == best else f"{vals[b]:.1f}") for b in builds) + " |")

    diff = [(b, w, i, med[b][f"{w}|{i}"]["ratio"], med[base][f"{w}|{i}"]["ratio"])
            for b in builds for w, i in keys
            if abs(med[b][f"{w}|{i}"]["ratio"] - med[base][f"{w}|{i}"]["ratio"]) > 1e-9]
    md += ["", "### Output consistency", ""]
    if diff:
        md += ["Compression ratios that differ from the baseline (= different JPEG output):", "",
               "| build | workload | image | ratio | baseline ratio |", "|---|---|---|---:|---:|"]
        md += [f"| {b} | {w} | {i} | {r} | {r0} |" for b, w, i, r, r0 in diff]
    else:
        md.append("All builds produce JPEG files of identical size for every workload and image.")

    text = "\n".join(md) + "\n"
    with open(os.path.join(a.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(text)
    print(text)


if __name__ == "__main__":
    main()
