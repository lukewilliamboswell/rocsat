#!/bin/sh
# Installs the external tools the harness uses. Idempotent; re-run any time.
#   brew:  cadical (status oracle), kissat, minisat, hyperfine (canary), coreutils (gtimeout)
#   pip:   python-sat (differential oracle, assumptions), cnfgen (generators)
#   git:   drat-trim (proof checker), cnfuzz + cnfdd (fuzz + shrink), dimocheck (model check)
#          built into bench/tools/ (gitignored)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tools="$here/tools"
mkdir -p "$tools"

brew install cadical kissat minisat hyperfine coreutils
python3 -m pip install --user --quiet --break-system-packages python-sat cnfgen

clone_and_make() {
    repo=$1
    dir="$tools/$(basename "$repo")"
    if [ ! -d "$dir" ]; then
        git clone --depth 1 "https://github.com/$repo" "$dir"
    fi
    (cd "$dir" && { [ -x ./configure ] && ./configure >/dev/null; } ; make >/dev/null)
}
clone_and_make marijnheule/drat-trim
clone_and_make arminbiere/cnfuzz
clone_and_make arminbiere/cnfdd
clone_and_make arminbiere/dimocheck

echo "tools ready:"
for t in cadical kissat minisat hyperfine gtimeout; do printf '  %-10s %s\n' "$t" "$(command -v $t || echo MISSING)"; done
for t in drat-trim/drat-trim cnfuzz/cnfuzz cnfdd/cnfdd dimocheck/dimocheck; do
    printf '  %-10s %s\n' "$(basename $t)" "$([ -x "$tools/$t" ] && echo "$tools/$t" || echo MISSING)"
done
python3 -c 'import pysat; print("  pysat     ", pysat.__version__)'
