#!/bin/sh
# Adapt a local MiniSat binary to rocsat's `solve` command and competition model output.
# Every spawn here is charged to MiniSat's measured time, so the adapter keeps them to the
# one temporary file MiniSat needs for its model.
set -eu
[ "${1:-}" = solve ] || { echo "usage: bench/minisat.sh solve FILE" >&2; exit 2; }
shift
bin=${MINISAT_BIN:-}
if [ -z "$bin" ]; then
    bin=$(cd "$(dirname "$0")" && pwd)/tools/minisat/minisat-bin
fi
[ -x "$bin" ] || { echo "MiniSat not found: set MINISAT_BIN or build $bin" >&2; exit 2; }
model=$(mktemp)
trap 'rm -f "$model"' 0 1 2 3 15
set +e
"$bin" "$@" "$model" 2>&1
rc=$?
set -e
case $rc in
    10)
        echo "s SATISFIABLE"
        # MiniSat writes a status line, then the model literals; the rest becomes `v` lines.
        while IFS= read -r line; do
            [ -n "${seen:-}" ] && printf 'v %s\n' "$line"
            seen=1
        done < "$model"
        ;;
    20) echo "s UNSATISFIABLE" ;;
esac
exit "$rc"
