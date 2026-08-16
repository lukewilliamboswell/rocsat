#!/usr/bin/env python3
"""Records reference statuses: runs CaDiCaL over instance sets and writes bench/expected/<set>.tsv.

    bench/expected.py [--jobs N] [--timeout S] [--force] [set ...]

Default sets: every directory under bench/corpus plus `edge`. An existing .tsv is compared, not
overwritten: a disagreement is printed and exits 1 (`--force` rewrites). CaDiCaL rejects two of
the leniencies our parser accepts (`+` prefixes and a `%` trailer), so instances are fed to it
through a light rewrite on stdin.
"""

import argparse
import os
import sys
from concurrent.futures import ThreadPoolExecutor

import common


def status(path, timeout):
    rc, out, err, _ = common.run(["cadical", "-q", "-f", "-t", str(int(timeout))], timeout + 5,
                                 stdin_bytes=common.sanitized(path))
    if rc == 10:
        return "SAT"
    if rc == 20:
        return "UNSAT"
    return f"UNKNOWN(rc={rc}: {err.decode(errors='replace').strip()[:80]})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    sets = args.sets or sorted(os.listdir(common.CORPUS)) + ["edge"]
    os.makedirs(common.EXPECTED, exist_ok=True)
    bad = 0
    for s in sets:
        files = common.resolve_instances([s])
        with ThreadPoolExecutor(args.jobs) as ex:
            results = list(ex.map(lambda f: (os.path.basename(f), status(f, args.timeout)), files))
        got = dict(results)
        unknown = {k: v for k, v in got.items() if v.startswith("UNKNOWN")}
        for k, v in unknown.items():
            print(f"{s}/{k}: {v}", file=sys.stderr)
        known = {k: v for k, v in got.items() if k not in unknown}
        have = common.load_expected(s)
        diffs = {k: (have[k], known[k]) for k in known if k in have and have[k] != known[k]}
        for k, (old, new) in sorted(diffs.items()):
            print(f"DISAGREE {s}/{k}: recorded {old}, cadical says {new}", file=sys.stderr)
        if diffs and not args.force:
            bad += 1
            continue
        merged = dict(have)
        merged.update(known)
        with open(os.path.join(common.EXPECTED, s + ".tsv"), "w") as f:
            for k in sorted(merged):
                f.write(f"{k}\t{merged[k]}\n")
        n_sat = sum(1 for v in merged.values() if v == "SAT")
        print(f"{s}: {len(merged)} instances ({n_sat} SAT, {len(merged) - n_sat} UNSAT)"
              + (f", {len(unknown)} unknown" if unknown else ""))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
