#!/bin/sh
# Builds and times every mode, min of 3 runs. ROC=/path/to/roc if roc is not on PATH.
# Loop time = the n=3.2M run minus an n=0 run of the same binary.
# Expect the two call_* modes to be ~4x the two inline_* modes.
set -eu
roc=${ROC:-roc}
cd "$(dirname "$0")"
"$roc" build --opt=speed inline_vs_call.roc
python3 - <<'PY'
import subprocess, time

def t(args):
    best = None
    for _ in range(3):
        s = time.perf_counter()
        subprocess.run(["./inline_vs_call", *args], check=True, capture_output=True, timeout=300)
        d = (time.perf_counter() - s) * 1000
        best = d if best is None else min(best, d)
    return best

for mode in ("inline_loop", "inline_rec", "call_loop", "call_rec"):
    loop = t([mode, "1000", "4000", "3200000"]) - t([mode, "1000", "4000", "0"])
    print(f"{mode:<13} {loop:8.1f} ms loop")
PY
