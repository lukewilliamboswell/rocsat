#!/usr/bin/env python3
"""Time every mode of ./main. Usage: bench.py [m cap n] [runs]"""
import subprocess, sys, time

m, cap, n = (sys.argv[1:4] if len(sys.argv) >= 4 else ("1000", "4000", "3200000"))
runs = int(sys.argv[4]) if len(sys.argv) >= 5 else 5
import re
modes = re.findall(r'mode == "([a-z_0-9]+)"', open("main.roc").read())

def run(mode, nn):
    best = None
    out = None
    for _ in range(runs):
        t = time.perf_counter()
        try:
            r = subprocess.run(["./main", mode, m, cap, nn], capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            return None, "TIMEOUT (clones every iteration)"
        dt = time.perf_counter() - t
        if r.returncode != 0:
            return None, r.stderr.strip() or r.stdout.strip()
        out = r.stdout.strip()
        best = dt if best is None else min(best, dt)
    return best, out

print(f"m={m} cap={cap} n={n} runs={runs} (min)")
print(f"{'mode':10} {'full':>9} {'n=0':>9} {'loop':>9}  checksum")
for mode in modes:
    full, out = run(mode, n)
    if full is None:
        print(f"{mode:10} FAILED: {out}")
        continue
    base, _ = run(mode, "0")
    ck = out.split("checksum=")[-1]
    print(f"{mode:10} {full*1000:8.2f}ms {base*1000:8.2f}ms {(full-base)*1000:8.2f}ms  {ck}")
