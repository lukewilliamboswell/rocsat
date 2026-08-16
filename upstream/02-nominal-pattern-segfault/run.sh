#!/bin/sh
# Runs `roc check main.roc` 10 times, each in a fresh copy, and prints the exit codes.
# Expect: mostly 139 (SIGSEGV), occasionally 1 (the type error reported correctly).
set -u
roc=${ROC:-roc}
here=$(cd "$(dirname "$0")" && pwd)
i=1
while [ "$i" -le 10 ]; do
    d=$(mktemp -d)
    cp "$here/Sol.roc" "$here/main.roc" "$d/"
    (cd "$d" && "$roc" check --no-cache main.roc >/dev/null 2>&1)
    printf '%s ' "$?"
    rm -rf "$d"
    i=$((i + 1))
done
echo
