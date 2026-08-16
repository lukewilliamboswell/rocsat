#!/bin/sh
# cnfdd predicate: exit 42 iff the given CNF still shows the bug (see bench/fuzz.py --check).
exec uv run --script "$(dirname "$0")/fuzz.py" --check "$1"
