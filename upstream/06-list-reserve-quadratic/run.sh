#!/bin/sh
# Builds the minimal example and measures how its runtime changes with list length.
set -eu
roc=${ROC:-roc}
cd "$(dirname "$0")"
"$roc" build --opt=speed --output=app main.roc
uv run python - <<'PY'
import subprocess
import time

for n in (10_000, 20_000, 40_000):
    samples = []
    for _ in range(3):
        start = time.perf_counter()
        result = subprocess.run(
            ["./app", str(n)],
            check=True,
            capture_output=True,
            timeout=30,
        )
        samples.append((time.perf_counter() - start) * 1000)
    print(f"n={n:>5} {min(samples):>8.1f} ms result={result.stdout.decode().strip()}")
PY
