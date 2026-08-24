#!/bin/sh
# Adapt a solver that already emits SAT-competition output (CaDiCaL, Kissat, and most modern
# solvers) to the `solve <file>` shape bench/run.py invokes. Stripping the subcommand is the
# only translation needed; MiniSat, which reports its model separately, has its own adapter.
#
# Any spawn here is charged to the solver's measured time, so this exec's straight into it:
#   SOLVER_BIN=/path/to/kissat uv run --script bench/run.py bench/competition.sh solve <sets>
set -eu
[ "${1:-}" = solve ] || { echo "usage: SOLVER_BIN=... bench/competition.sh solve FILE" >&2; exit 2; }
shift
bin=${SOLVER_BIN:-}
[ -n "$bin" ] || { echo "competition: set SOLVER_BIN to a competition-output solver" >&2; exit 2; }
command -v "$bin" >/dev/null 2>&1 || { echo "competition: not executable: $bin" >&2; exit 2; }
exec "$bin" "$@"
