#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Compare two benchmark JSON files emitted by bench/run.py."""

import argparse
import json
import math
from pathlib import Path
import statistics


def par2(run):
    timeout = run["timeout"]
    return sum(item.get("seconds", 0) if item["status"] == "ok" else 2 * timeout
               for item in run["results"] if item["status"] != "skipped")


def summarize(baseline, candidate, threshold=0.10):
    if baseline["timeout"] != candidate["timeout"]:
        raise ValueError("benchmark timeouts differ")
    left = {item["instance"]: item for item in baseline["results"]}
    right = {item["instance"]: item for item in candidate["results"]}
    if left.keys() != right.keys():
        raise ValueError("benchmark instance sets differ")
    common = [(left[name], right[name]) for name in sorted(left)
              if left[name]["status"] == right[name]["status"] == "ok"]
    ratios = [new["seconds"] / old["seconds"] for old, new in common if old["seconds"] > 0]
    regressions = [
        {"instance": old["instance"], "baseline": old["seconds"], "candidate": new["seconds"],
         "ratio": round(new["seconds"] / old["seconds"], 3)}
        for old, new in common
        if old["seconds"] > 0 and new["seconds"] > old["seconds"] * (1 + threshold)
        and new["seconds"] - old["seconds"] >= 0.01
    ]
    search_pairs = [(old.get("solver_stats", {}), new.get("solver_stats", {})) for old, new in common]
    baseline_rss = [item["peak_rss_kib"] for item in left.values() if item.get("peak_rss_kib")]
    candidate_rss = [item["peak_rss_kib"] for item in right.values() if item.get("peak_rss_kib")]
    return {
        "instances": len(left),
        "baseline_solved": sum(item["status"] == "ok" for item in left.values()),
        "candidate_solved": sum(item["status"] == "ok" for item in right.values()),
        "baseline_failed": sum(item["status"] == "fail" for item in left.values()),
        "candidate_failed": sum(item["status"] == "fail" for item in right.values()),
        "baseline_par2": round(par2(baseline), 4),
        "candidate_par2": round(par2(candidate), 4),
        "common_solved": len(common),
        "median_time_ratio": round(statistics.median(ratios), 4) if ratios else None,
        "geomean_time_ratio": round(math.exp(sum(math.log(x) for x in ratios) / len(ratios)), 4)
                              if ratios else None,
        "identical_search": sum(bool(old) and old == new for old, new in search_pairs),
        "baseline_peak_rss_kib": max(baseline_rss, default=None),
        "candidate_peak_rss_kib": max(candidate_rss, default=None),
        "regression_threshold": threshold,
        "regressions": regressions,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--threshold", type=float, default=0.10)
    parser.add_argument("--json")
    parser.add_argument("--fail-regressions", action="store_true")
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    candidate = json.loads(args.candidate.read_text())
    result = summarize(baseline, candidate, args.threshold)
    print(f"solved {result['baseline_solved']} -> {result['candidate_solved']}; "
          f"PAR-2 {result['baseline_par2']:.2f} -> {result['candidate_par2']:.2f}; "
          f"common {result['common_solved']}; geomean ratio {result['geomean_time_ratio']}; "
          f"regressions {len(result['regressions'])}")
    for item in sorted(result["regressions"], key=lambda item: item["ratio"], reverse=True):
        print(f"  {item['ratio']:.2f}x {item['instance']} "
              f"({item['baseline']:.3f}s -> {item['candidate']:.3f}s)")
    if args.json:
        Path(args.json).write_text(json.dumps(result, indent=1) + "\n")
    if result["baseline_failed"] or result["candidate_failed"]:
        raise SystemExit(1)
    if args.fail_regressions and result["regressions"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
