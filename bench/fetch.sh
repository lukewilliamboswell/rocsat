#!/bin/sh
# Downloads the SATLIB corpora into bench/corpus/<set>/*.cnf (gitignored, ~35 MB). Idempotent:
# a set whose directory already contains .cnf files is skipped.
# SATLIB's random 3-SAT files end with a "%\n0" trailer that no current solver (CaDiCaL, Kissat,
# MiniSat) accepts; it is cut off here so the corpus is plain DIMACS for every tool.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
corpus="$here/corpus"
base=https://www.cs.ubc.ca/~hoos/SATLIB/Benchmarks/SAT

fetch() (
    set=$1
    url=$2
    dir="$corpus/$set"
    if ls "$dir"/*.cnf >/dev/null 2>&1; then
        echo "$set: present"
        return
    fi
    echo "$set: fetching"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' 0 1 2 3 15
    curl -fLsS -o "$tmp/a.tar.gz" "$url"
    mkdir -p "$dir"
    tar xzf "$tmp/a.tar.gz" -C "$tmp"
    # some tarballs unpack flat, others into a subdirectory
    find "$tmp" -name '*.cnf' -exec mv {} "$dir/" \;
    for f in "$dir"/*.cnf; do
        clean="$f.clean.$$"
        sed '/^%/,$d' "$f" > "$clean"
        mv "$clean" "$f"
    done
    echo "$set: $(ls "$dir" | wc -l | tr -d ' ') files"
)

fetch uf20-91      $base/RND3SAT/uf20-91.tar.gz
fetch uf50-218     $base/RND3SAT/uf50-218.tar.gz
fetch uuf50-218    $base/RND3SAT/uuf50-218.tar.gz
fetch uf100-430    $base/RND3SAT/uf100-430.tar.gz
fetch uuf100-430   $base/RND3SAT/uuf100-430.tar.gz
fetch uf250-1065   $base/RND3SAT/uf250-1065.tar.gz
fetch uuf250-1065  $base/RND3SAT/uuf250-1065.tar.gz
fetch flat200-479  $base/GCP/flat200-479.tar.gz
fetch hole         $base/DIMACS/PHOLE/pigeon-hole.tar.gz
fetch dubois       $base/DIMACS/DUBOIS/dubois.tar.gz
fetch pret         $base/DIMACS/PRET/pret.tar.gz
fetch aim          $base/DIMACS/AIM/aim.tar.gz
