#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Compare parse wall time on comment-heavy fixtures and caller-supplied CNFs."""

import argparse
from pathlib import Path
from statistics import median
import subprocess
from tempfile import TemporaryDirectory
from time import perf_counter


def write_comment_fixture(path, line_length):
    line = b"c " + b"x" * (line_length - 3) + b"\n"
    with path.open("wb") as file:
        file.write(line * ((16 * 1024 * 1024) // line_length))
        file.write(b"p cnf 2 2\n1 -2 0\n2 0\n")


def parse(binary, path):
    started = perf_counter()
    completed = subprocess.run([binary, "parse", path], capture_output=True, check=True)
    return completed.stdout, perf_counter() - started


def compare(scalar, simd, path, runs):
    expected, _ = parse(scalar, path)
    output, _ = parse(simd, path)
    if output != expected:
        raise RuntimeError(f"SIMD changed parse output for {path}")

    times = [[], []]
    binaries = (scalar, simd)
    for index in range(runs):
        for side in (index % 2, 1 - index % 2):
            output, elapsed = parse(binaries[side], path)
            if output != expected:
                raise RuntimeError(f"Inconsistent parse output for {path}")
            times[side].append(elapsed)
    baseline, vectorized = map(median, times)
    print(f"{path.name:<36} {baseline * 1000:9.2f} {vectorized * 1000:9.2f} {baseline / vectorized:8.2f}x")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scalar", type=Path)
    parser.add_argument("simd", type=Path)
    parser.add_argument("inputs", type=Path, nargs="*")
    parser.add_argument("--runs", type=int, default=11)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")

    print(f"{'Input':<36} {'Scalar ms':>9} {'SIMD ms':>9} {'Speedup':>9}")
    with TemporaryDirectory(prefix="rocsat-simd-") as folder:
        fixtures = []
        for length in (8, 128, 1024):
            path = Path(folder) / f"comments-{length}-bytes-per-line.cnf"
            write_comment_fixture(path, length)
            fixtures.append(path)
        for path in [*fixtures, *args.inputs]:
            compare(args.scalar.resolve(), args.simd.resolve(), path, args.runs)


if __name__ == "__main__":
    main()
