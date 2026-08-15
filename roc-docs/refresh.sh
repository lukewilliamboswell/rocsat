#!/usr/bin/env bash
# Re-sync the local copies of Roc's docs. Roc moves fast; run this before
# trusting NOTES.md, then re-read the diffs.
set -euo pipefail
cd "$(dirname "$0")"

RAW=https://raw.githubusercontent.com/roc-lang/roc/main

curl -fsSL -o mini-tutorial-new-compiler.md "$RAW/docs/mini-tutorial-new-compiler.md"
curl -fsSL -o all_syntax_test.roc           "$RAW/test/echo/all_syntax_test.roc"
curl -fsSL -o Builtin.roc                   "$RAW/src/build/roc/Builtin.roc"

mkdir -p langref
for f in README comments-and-docs dictionaries-and-sets expressions functions if-else \
         iterators loops modules naming numbers operators packages parsers \
         pattern-matching platforms records statements static-dispatch strings \
         tag-unions tuples types; do
  curl -fsSL -o "langref/$f.md" "$RAW/docs/langref/$f.md"
done

echo "Synced. Latest nightly:"
curl -fsSL https://api.github.com/repos/roc-lang/nightlies/releases/latest \
  | grep -m1 '"tag_name"' || true
