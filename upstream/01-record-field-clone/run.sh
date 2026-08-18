#!/bin/sh
# Builds the minimal reproducer and measures scaling in list length and write count.
set -eu
roc=${ROC:-roc}
cd "$(dirname "$0")"
"$roc" build --opt=speed --output=app main.roc
uv run python - <<'PY'
import subprocess
import time

points = (
    (1_000_000, 100),
    (1_000_000, 200),
    (1_000_000, 400),
    (250_000, 200),
    (500_000, 200),
)

for length, writes in points:
    samples = []
    for _ in range(3):
        start = time.perf_counter()
        result = subprocess.run(
            ["./app", str(length), str(writes)],
            check=True,
            capture_output=True,
            timeout=30,
        )
        samples.append((time.perf_counter() - start) * 1000)
    print(
        f"len={length:>7} writes={writes:>3} "
        f"{min(samples):>8.1f} ms result={result.stdout.decode().strip()}"
    )
PY
