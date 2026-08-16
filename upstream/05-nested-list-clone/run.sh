#!/bin/sh
# Builds and times every mode, min of 3 runs. ROC=/path/to/roc if roc is not on PATH.
# Expect update and getset to roughly quadruple per doubling of n; flat stays linear.
set -eu
roc=${ROC:-roc}
cd "$(dirname "$0")"
"$roc" build --opt=speed nested_list.roc
python3 - <<'PY'
import subprocess, time

def t(args):
    best = None
    for _ in range(3):
        s = time.perf_counter()
        subprocess.run(["./nested_list", *args], capture_output=True, timeout=300)
        d = (time.perf_counter() - s) * 1000
        best = d if best is None else min(best, d)
    return best

for mode in ("update", "getset", "flat"):
    for n in (400000, 800000, 1600000, 3200000):
        print(f"{mode:<7} n={n:<8} {t([mode, '1000', str(n)]):9.1f} ms")
PY
