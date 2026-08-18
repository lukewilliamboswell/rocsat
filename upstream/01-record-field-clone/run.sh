#!/bin/sh
# Builds and times every mode, min of 3 runs. ROC=/path/to/roc if roc is not on PATH.
# Expect call_qq to be ~1000x the others and to grow linearly with n.
set -eu
roc=${ROC:-roc}
cd "$(dirname "$0")"
"$roc" build --opt=speed record_field_clone.roc
python3 - <<'PY'
import subprocess, time

def t(args):
    best = None
    for _ in range(3):
        s = time.perf_counter()
        subprocess.run(["./record_field_clone", *args], check=True, capture_output=True, timeout=300)
        d = (time.perf_counter() - s) * 1000
        best = d if best is None else min(best, d)
    return best

for mode in ("literal_qq", "call_qq", "call_q", "lists"):
    for n in (2000, 4000, 8000):
        print(f"{mode:<11} n={n:<6} {t([mode, '1000', '4000', str(n)]):8.1f} ms")
PY
