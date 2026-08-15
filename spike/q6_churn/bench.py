#!/usr/bin/env python3
"""Time every mode of ./churn. Usage: bench.py L T R [period] [stride] [runs]"""
import re, resource, subprocess, sys, time

L, T, R = sys.argv[1:4] if len(sys.argv) >= 4 else ("200000", "2000000", "2000000")
period = sys.argv[4] if len(sys.argv) >= 5 else "200000"
stride = sys.argv[5] if len(sys.argv) >= 6 else "8"
runs = int(sys.argv[6]) if len(sys.argv) >= 7 else 3
modes = re.findall(r'mode == "([a-z_0-9]+)"', open("churn.roc").read())


def run(mode, rr):
    best, out, rss = None, None, 0
    for _ in range(runs):
        t0 = time.perf_counter()
        r0 = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        try:
            r = subprocess.run(["./churn", mode, L, T, rr, period, stride], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            return None, "TIMEOUT", 0
        dt = time.perf_counter() - t0
        if r.returncode != 0:
            return None, r.stderr.strip() or r.stdout.strip(), 0
        out = r.stdout.strip()
        best = dt if best is None else min(best, dt)
        rss = max(rss, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
    return best, out, rss


print(f"L={L} T={T} R={R} period={period} stride={stride} runs={runs} (min)")
print(f"{'mode':18} {'full':>9} {'R=0':>9} {'loop':>9} {'ns/visit':>9}  relocs compacts pool_words checksum")
visits = None
for mode in modes:
    full, out, rss = run(mode, R)
    if full is None:
        print(f"{mode:18} FAILED: {out}")
        continue
    base, _, _ = run(mode, "0")
    kv = dict(kv.split("=") for kv in out.split() if "=" in kv)
    # entry visits ~= R * T/L (average list length); report per-visit cost
    v = int(R) * int(T) / int(L)
    print(f"{mode:18} {full*1000:8.1f}ms {base*1000:8.1f}ms {(full-base)*1000:8.1f}ms {(full-base)*1e9/v:8.1f}  {kv['relocs']:>7} {kv['compacts']:>6} {kv['words']:>10} {kv['checksum']}")
