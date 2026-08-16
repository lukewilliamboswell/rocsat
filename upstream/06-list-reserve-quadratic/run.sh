#!/bin/sh
# Builds and times every mode, min of 3 runs. ROC=/path/to/roc if roc is not on PATH.
# Expect reserve to roughly quadruple per doubling of n; append and manual stay linear.
set -eu
roc=${ROC:-roc}
cd "$(dirname "$0")"
"$roc" build --opt=speed reserve.roc
python3 - <<'PY'
import subprocess, time

def t(args):
    best = None
    for _ in range(3):
        s = time.perf_counter()
        subprocess.run(["./reserve", *args], capture_output=True, timeout=300)
        d = (time.perf_counter() - s) * 1000
        best = d if best is None else min(best, d)
    return best

for mode in ("reserve", "append", "manual"):
    for n in (1000000, 2000000, 4000000):
        print(f"{mode:<8} n={n:<8} {t([mode, str(n), '4096']):9.1f} ms")
PY
