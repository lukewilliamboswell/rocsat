#!/bin/sh
# Builds the repository-local tools used by the harness. OS packages are prerequisites rather
# than something this script installs; see README.md for macOS and Linux setup.
#
# python-sat (the fuzz oracle) is declared by fuzz.py and fetched by uv. CaDiCaL is only needed
# to regenerate expected statuses, and hyperfine is only needed by the timing canary.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tools="$here/tools"

missing=
for t in git make gcc uv; do
    if ! command -v "$t" >/dev/null 2>&1; then
        missing="$missing $t"
    fi
done
if [ -n "$missing" ]; then
    echo "tools: missing prerequisites:$missing (see README.md)" >&2
    exit 1
fi
mkdir -p "$tools"

clone_and_make() {
    repo=$1
    dir="$tools/$(basename "$repo")"
    if [ ! -d "$dir" ]; then
        git clone --depth 1 "https://github.com/$repo" "$dir"
    fi
    (
        cd "$dir"
        if [ -x ./configure ]; then
            ./configure >/dev/null
        fi
        make >/dev/null
    )
}
clone_and_make marijnheule/drat-trim
clone_and_make arminbiere/cnfuzz
clone_and_make arminbiere/cnfdd
clone_and_make arminbiere/dimocheck

echo "tools ready:"
for t in drat-trim/drat-trim cnfuzz/cnfuzz cnfdd/cnfdd dimocheck/dimocheck; do
    printf '  %-10s %s\n' "$(basename "$t")" "$([ -x "$tools/$t" ] && echo "$tools/$t" || echo MISSING)"
done
uv run --script "$here/fuzz.py" --help >/dev/null && echo "  pysat      ok (via uv)"
for t in cadical hyperfine; do
    printf '  %-10s %s\n' "$t (optional)" "$(command -v "$t" || echo MISSING)"
done
