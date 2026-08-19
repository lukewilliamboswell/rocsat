#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Stream static DIMACS profiles for corpus instances."""

import argparse
import json
from pathlib import Path

import common


def profile_cnf(path):
    path = Path(path)
    declared_vars = declared_clauses = 0
    variables = clauses = literals = maximum = current = 0
    buckets = {"empty": 0, "unit": 0, "binary": 0, "ternary": 0, "long": 0}
    stopped = False
    with path.open("rb") as source:
        for raw in source:
            line = raw.lstrip()
            if not line or line.startswith(b"c"):
                continue
            if line.startswith(b"%"):
                break
            if line.startswith(b"p"):
                fields = line.split()
                if len(fields) >= 4 and fields[1] == b"cnf":
                    declared_vars, declared_clauses = int(fields[2]), int(fields[3])
                continue
            for token in line.split():
                if token == b"%":
                    stopped = True
                    break
                literal = int(token)
                if literal == 0:
                    clauses += 1
                    maximum = max(maximum, current)
                    key = ("empty" if current == 0 else "unit" if current == 1 else
                           "binary" if current == 2 else "ternary" if current == 3 else "long")
                    buckets[key] += 1
                    current = 0
                else:
                    variables = max(variables, abs(literal))
                    literals += 1
                    current += 1
            if stopped:
                break
    if current:
        raise ValueError(f"unterminated clause in {path}")
    return {
        "path": str(path),
        "bytes": path.stat().st_size,
        "variables": max(declared_vars, variables),
        "clauses": clauses,
        "literals": literals,
        "average_clause": round(literals / clauses, 3) if clauses else 0,
        "maximum_clause": maximum,
        "declared_variables": declared_vars,
        "declared_clauses": declared_clauses,
        **buckets,
    }


def profile_paths(paths):
    return [profile_cnf(path) for path in paths]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("specs", nargs="+")
    parser.add_argument("--json")
    args = parser.parse_args()
    profiles = profile_paths(common.resolve_instances(args.specs))
    output = json.dumps(profiles, indent=1)
    if args.json:
        Path(args.json).write_text(output + "\n")
    else:
        print(output)


if __name__ == "__main__":
    main()
