#!/usr/bin/env python3
"""Usage: bench.py [runs]  — times every mode of ./alloc at several n; prints ms and ns/element."""
import re, resource, subprocess, sys, time

runs = int(sys.argv[1]) if len(sys.argv) >= 2 else 5
modes = re.findall(r'mode == "([a-z_0-9]+)"', open("alloc.roc").read())
sizes = ["1000000", "4000000", "16000000", "64000000"]


def run(mode, n, k):
    best, rss = None, 0
    for _ in range(runs):
        t0 = time.perf_counter()
        try:
            r = subprocess.run(["./alloc", mode, n, k], capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return None, 0
        dt = time.perf_counter() - t0
        if r.returncode != 0:
            return None, 0
        best = dt if best is None else min(best, dt)
        rss = max(rss, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
    return best, rss


base, _ = run("repeat", "1", "1")
print(f"process baseline (repeat n=1): {base*1000:.2f} ms; times below have it subtracted; runs={runs} (min)")
print(f"{'mode':16} " + " ".join(f"{'n=' + s:>22}" for s in sizes))
for mode in modes:
    cells = []
    for n in sizes:
        k = "10" if mode == "startup_k" else "4096"
        if mode == "startup_k" and int(n) > 16000000:
            cells.append(f"{'-':>22}")
            continue
        t, rss = run(mode, n, k)
        if t is None:
            cells.append(f"{'FAIL/TIMEOUT':>22}")
        else:
            elems = int(n) * (10 if mode == "startup_k" else 1)
            cells.append(f"{(t-base)*1000:8.1f}ms {(t-base)*1e9/elems:6.2f}ns/el")
    print(f"{mode:16} " + " ".join(cells))
