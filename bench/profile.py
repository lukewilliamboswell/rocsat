#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Stream static DIMACS profiles for corpus instances."""

import argparse
import json
from pathlib import Path
import tomllib

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
    try:
        display_path = str(path.resolve().relative_to(Path(common.ROOT)))
    except ValueError:
        display_path = str(path)
    return {
        "path": display_path,
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


def summarize(paths):
    profiles = profile_paths(paths)
    if not profiles:
        return {"instances": 0, "bytes": 0}
    summed = ("bytes", "clauses", "literals", "empty", "unit", "binary", "ternary", "long")
    return {
        "instances": len(profiles),
        **{key: sum(profile[key] for profile in profiles) for key in summed},
        "variables_min": min(profile["variables"] for profile in profiles),
        "variables_max": max(profile["variables"] for profile in profiles),
        "clauses_min": min(profile["clauses"] for profile in profiles),
        "clauses_max": max(profile["clauses"] for profile in profiles),
        "maximum_clause": max(profile["maximum_clause"] for profile in profiles),
    }


def manifest_report(manifest_path):
    with open(manifest_path, "rb") as source:
        manifest = tomllib.load(source)
    sets = {}
    for entry in manifest.get("archive", []):
        paths = common.resolve_instances([entry["set"]])
        sets[entry["set"]] = {
            "family": entry["family"], "profiles": entry["profiles"], **summarize(paths),
        }
    instances = []
    for entry in manifest.get("instance", []):
        path = Path(common.CORPUS) / entry["set"] / entry["name"]
        instances.append({
            "family": entry["family"], "profiles": entry["profiles"],
            "status": entry["status"], "source": entry["source"], **profile_cnf(path),
        })
    total_bytes = sum(item["bytes"] for item in sets.values()) + sum(item["bytes"] for item in instances)
    return {
        "manifest_version": manifest["version"],
        "budget_bytes": manifest["budget_bytes"],
        "corpus_bytes": total_bytes,
        "archive_sets": sets,
        "instances": instances,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("specs", nargs="*")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--json")
    args = parser.parse_args()
    if args.manifest:
        if args.specs:
            parser.error("specs and --manifest are mutually exclusive")
        profiles = manifest_report(args.manifest)
    else:
        if not args.specs:
            parser.error("provide specs or --manifest")
        profiles = profile_paths(common.resolve_instances(args.specs))
    output = json.dumps(profiles, indent=1)
    if args.json:
        Path(args.json).write_text(output + "\n")
    else:
        print(output)


if __name__ == "__main__":
    main()
