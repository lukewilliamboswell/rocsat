#!/bin/sh
# Runs the minimal reproducer 10 times and prints each compiler exit code.
# Expect ten 139 (SIGSEGV) exits; a correct compiler should report the type error with exit 1.
set -u
roc=${ROC:-roc}
cd "$(dirname "$0")"
i=1
while [ "$i" -le 10 ]; do
    "$roc" check --no-cache main.roc >/dev/null 2>&1
    printf '%s ' "$?"
    i=$((i + 1))
done
echo
