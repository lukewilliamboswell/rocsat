#!/bin/sh
# Adapt a local MiniSat binary to rocsat's `solve` command and competition model output.
set -eu
[ "${1:-}" = solve ] || { echo "usage: bench/minisat.sh solve FILE" >&2; exit 2; }
shift
here=$(cd "$(dirname "$0")" && pwd)
bin=${MINISAT_BIN:-$here/tools/minisat/minisat-bin}
[ -x "$bin" ] || { echo "MiniSat not found: set MINISAT_BIN or build $bin" >&2; exit 2; }
model=$(mktemp)
log=$(mktemp)
trap 'rm -f "$model" "$log"' 0 1 2 3 15
set +e
"$bin" "$@" "$model" >"$log" 2>&1
rc=$?
set -e
cat "$log"
case $rc in
    10)
        echo "s SATISFIABLE"
        sed -n '2,$s/^/v /p' "$model"
        ;;
    20) echo "s UNSATISFIABLE" ;;
esac
exit "$rc"
