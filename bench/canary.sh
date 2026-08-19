#!/bin/sh
# Timing canary: hyperfine min-of-N on a fixed generated input, to catch a nightly or a refactor
# turning an in-place loop into a copying one (that failure is quadratic, so it shows up as a
# multiple, not a percentage). The input is an implication chain (¬x_i ∨ x_{i+1}) with
# contradictory units x1 and ¬xN last. Level-0 propagation walks the chain from both ends until
# they meet and report UNSAT, exercising binary attachment and propagation without formatting a
# giant SAT model. Reported: ns per clause = (solve − parse) / N, compared with the hard ceiling
# in bench/canary-ceiling.txt (a regression must be understood, not accepted).
# Usage: bench/canary.sh [binary]   (default src/rocsat); JSON lands in bench/out/canary.json.
# Run plugged in: on battery this machine measures ~35 % slower.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-"$here/../src/rocsat"}
out="$here/out"
mkdir -p "$out"
n=2000000
big="$out/canary-unsat-chain-2M.cnf"
if [ ! -f "$big" ]; then
    echo "generating $big"
    uv run python - "$big" "$n" <<'EOF'
import sys
n = int(sys.argv[2])
with open(sys.argv[1], "w") as f:
    f.write(f"p cnf {n} {n + 1}\n")
    for i in range(1, n):
        f.write(f"-{i} {i + 1} 0\n")
    f.write("1 0\n")
    f.write(f"-{n} 0\n")
EOF
fi
echo "canary: contradictory propagation chain of $n"
hyperfine=${HYPERFINE:-$(command -v hyperfine || true)}
[ -n "$hyperfine" ] || hyperfine="$here/tools/hyperfine/hyperfine"
[ -x "$hyperfine" ] || { echo "hyperfine not found (set HYPERFINE)" >&2; exit 1; }
"$hyperfine" --warmup 1 --min-runs 5 --ignore-failure --export-json "$out/canary.json" "$bin parse $big" "$bin solve $big >/dev/null"
uv run python - "$out/canary.json" "$n" "$here/canary-ceiling.txt" <<'EOF'
import json, sys
parse, solve = [r["min"] for r in json.load(open(sys.argv[1]))["results"]]
ns = (solve - parse) / int(sys.argv[2]) * 1e9
ceiling = float(open(sys.argv[3]).read().split()[0])
print(f"parse min {parse:.3f}s  solve min {solve:.3f}s  ->  {ns:.1f} ns per clause (ceiling {ceiling:.0f})")
sys.exit(0 if ns <= ceiling else 1)
EOF
