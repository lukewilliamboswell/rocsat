#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["python-sat"]
# ///
"""Differential incremental clause/assumption sequences against fresh PySAT solves."""

import argparse
import random
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from pysat.solvers import Solver


@dataclass
class Query:
    clauses: list[list[int]]
    assumptions: list[int]
    sat: bool


def fresh_solve(clauses: list[list[int]], assumptions: list[int]) -> bool:
    if any(not clause for clause in clauses):
        return False
    with Solver(name="cadical195", bootstrap_with=clauses) as solver:
        return solver.solve(assumptions=assumptions)


def random_clause(rng: random.Random, nvars: int) -> list[int]:
    roll = rng.random()
    if roll < 0.015:
        size = 0
    elif roll < 0.10:
        size = 1
    elif roll < 0.35:
        size = 2
    else:
        size = rng.choice((3, 3, 4))
    clause = [rng.randint(1, nvars) * rng.choice((-1, 1)) for _ in range(size)]
    if clause and rng.random() < 0.08:
        clause.append(clause[0])
    if clause and rng.random() < 0.04:
        clause.append(-clause[0])
    return clause


def random_assumptions(rng: random.Random, nvars: int) -> list[int]:
    size = rng.randint(0, min(nvars, 5))
    assumptions = [rng.randint(1, nvars) * rng.choice((-1, 1)) for _ in range(size)]
    if assumptions and rng.random() < 0.08:
        assumptions.append(assumptions[-1])
    if assumptions and rng.random() < 0.08:
        assumptions.append(-assumptions[0])
    return assumptions


def make_session(rng: random.Random, query_count: int) -> tuple[str, list[Query]]:
    nvars = rng.randint(1, 12)
    clauses: list[list[int]] = []
    queries: list[Query] = []
    lines = ["p rocsat"]
    for _ in range(query_count):
        for _ in range(rng.randint(0, 2)):
            clause = random_clause(rng, nvars)
            clauses.append(clause)
            lines.append("+ " + " ".join(map(str, clause + [0])))
        assumptions = random_assumptions(rng, nvars)
        lines.append("? " + " ".join(map(str, assumptions + [0])))
        queries.append(Query([c.copy() for c in clauses], assumptions, fresh_solve(clauses, assumptions)))
    return "\n".join(lines) + "\n", queries


def parse_answers(stdout: str) -> list[tuple[str, list[int]]]:
    lines = [line.strip() for line in stdout.splitlines() if line.strip()]
    answers: list[tuple[str, list[int]]] = []
    i = 0
    while i < len(lines):
        status = lines[i]
        i += 1
        if status == "s SATISFIABLE":
            model: list[int] = []
            terminated = False
            while i < len(lines) and lines[i].startswith("v"):
                tokens = [int(x) for x in lines[i].split()[1:]]
                i += 1
                if 0 in tokens:
                    model.extend(tokens[: tokens.index(0)])
                    terminated = True
                    break
                model.extend(tokens)
            if not terminated:
                raise ValueError("SAT answer has no terminating model 0")
            answers.append(("SAT", model))
        elif status == "s UNSATISFIABLE":
            if i >= len(lines) or not lines[i].startswith("u"):
                raise ValueError("UNSAT answer has no final-conflict line")
            tokens = [int(x) for x in lines[i].split()[1:]]
            i += 1
            if not tokens or tokens[-1] != 0:
                raise ValueError("final-conflict line has no terminating 0")
            answers.append(("UNSAT", tokens[:-1]))
        else:
            raise ValueError(f"unexpected output line: {status!r}")
    return answers


def check_model(model_lits: list[int], query: Query) -> str | None:
    values: dict[int, bool] = {}
    for lit in model_lits:
        var = abs(lit)
        value = lit > 0
        if var in values and values[var] != value:
            return f"contradictory model value for variable {var}"
        values[var] = value

    def true(lit: int) -> bool:
        return values.get(abs(lit)) == (lit > 0)

    for index, clause in enumerate(query.clauses):
        if not any(true(lit) for lit in clause):
            return f"model falsifies clause {index}: {clause}"
    for lit in query.assumptions:
        if not true(lit):
            return f"model falsifies assumption {lit}"
    return None


def check_answer(answer: tuple[str, list[int]], query: Query) -> str | None:
    status, payload = answer
    expected = "SAT" if query.sat else "UNSAT"
    if status != expected:
        return f"status {status}, expected {expected}"
    if status == "SAT":
        return check_model(payload, query)
    failed = [-lit for lit in payload]
    if any(lit not in query.assumptions for lit in failed):
        return f"failed assumptions {failed} are not a subset of {query.assumptions}"
    if fresh_solve(query.clauses, failed):
        return f"reported failed assumptions are satisfiable: {failed}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="src/rocsat")
    parser.add_argument("--cases", type=int, default=10_000)
    parser.add_argument("--queries-per-session", type=int, default=10)
    parser.add_argument("--seed", type=int, default=1_787_152_004)
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    if args.cases < 1 or args.queries_per_session < 1:
        parser.error("case counts must be positive")

    rng = random.Random(args.seed)
    out = Path("bench/out")
    out.mkdir(parents=True, exist_ok=True)
    checked = 0
    session = 0
    while checked < args.cases:
        count = min(args.queries_per_session, args.cases - checked)
        transcript, queries = make_session(rng, count)
        path = out / "incremental-current.txt"
        path.write_text(transcript)
        proc = subprocess.run(
            [args.binary, "incremental", str(path)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=args.timeout,
        )
        if proc.returncode != 0:
            failure = out / f"incremental-fail-{args.seed}-{session}.txt"
            failure.write_text(transcript)
            print(f"incremental: process failed ({proc.returncode}); saved {failure}\n{proc.stderr}", file=sys.stderr)
            return 1
        try:
            answers = parse_answers(proc.stdout)
        except ValueError as error:
            failure = out / f"incremental-fail-{args.seed}-{session}.txt"
            failure.write_text(transcript)
            print(f"incremental: {error}; saved {failure}\nstdout:\n{proc.stdout}", file=sys.stderr)
            return 1
        if len(answers) != len(queries):
            print(f"incremental: got {len(answers)} answers for {len(queries)} queries", file=sys.stderr)
            return 1
        for offset, (answer, query) in enumerate(zip(answers, queries)):
            error = check_answer(answer, query)
            if error:
                failure = out / f"incremental-fail-{args.seed}-{session}.txt"
                failure.write_text(transcript)
                print(f"incremental: case {checked + offset}: {error}; saved {failure}", file=sys.stderr)
                return 1
        checked += count
        session += 1
    print(f"incremental: {checked}/{checked} queries ok in {session} sessions (seed {args.seed})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
