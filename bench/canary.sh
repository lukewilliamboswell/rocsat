#!/bin/sh
# Timing canary: hyperfine min-of-N on fixed inputs, to catch a nightly or a refactor turning an
# in-place loop into a cloning one. Today it measures parser throughput on a generated
# random 3-SAT file of ~100 MB (the SATLIB files are too small to see past process start-up).
# Usage: bench/canary.sh [binary]   (default src/rocsat); JSON lands in bench/out/canary.json.
# Run plugged in: on battery this machine measures ~35 % slower (349 vs 220 MB/s observed).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-"$here/../src/rocsat"}
out="$here/out"
mkdir -p "$out"
big="$out/canary-3sat-1M.cnf"
if [ ! -f "$big" ]; then
    echo "generating $big"
    uv run python - "$big" <<'EOF'
import random, sys
rng = random.Random(20260816)
n, m = 1_000_000, 4_000_000
with open(sys.argv[1], "w") as f:
    f.write(f"p cnf {n} {m}\n")
    for _ in range(m):
        f.write(" ".join(str(rng.randint(1, n) * rng.choice((1, -1))) for _ in range(3)) + " 0\n")
EOF
fi
size_mb=$(uv run python -c "import os,sys; print(round(os.path.getsize(sys.argv[1])/1e6,1))" "$big")
echo "canary: parse ${size_mb} MB"
hyperfine --warmup 1 --min-runs 5 --export-json "$out/canary.json" "$bin parse $big"
uv run python - "$out/canary.json" "$size_mb" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))["results"][0]
print(f"min {r['min']:.3f}s  ->  {float(sys.argv[2]) / r['min']:.0f} MB/s")
EOF
