#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["python-sat"]
# ///
"""Random-CNF fuzz loop against a PySAT oracle.

    bench/fuzz.py [--seconds 60] [--seed S] [--tiny] [--subcommand solve] [--max-vars 24]
                  [--drat] [--binary src/rocsat] [--dev-binary src/rocsat-dev]
    bench/fuzz.py --check FILE          # predicate mode: exit 42 iff FILE shows a bug

Each round generates a small CNF (own generator, alternating with cnfuzz when built), then:
exit code must be 10/20 and match the oracle (PySAT CaDiCaL), SAT models must pass `<binary>
check`, UNSAT proofs must verify with drat-trim when `--drat` is given (the proof path is passed
as an extra argument), and the dev binary must give the same status without printing `Expect
failed`. On the
first bug the instance is saved under bench/out/fail-<seed>.cnf, shrunk with cnfdd through
bench/predicate.sh when available, and the script exits 1.
"""

import argparse
import os
import random
import sys
import time

import common

BUG_EXIT = 42


def oracle_status(clauses):
    if any(len(c) == 0 for c in clauses):
        return "UNSAT"
    from pysat.solvers import Solver
    with Solver(name="cadical195", bootstrap_with=clauses) as s:
        return "SAT" if s.solve() else "UNSAT"


def generate_own(rng, max_vars):
    """Random CNF near the phase transition, with the odd unit, empty, tautological or
    duplicated clause, and occasional formatting quirks."""
    n = rng.randint(1, max_vars)
    m = rng.randint(0, int(n * rng.uniform(2.0, 5.5)) + 2)
    lines = [f"p cnf {n} {m}"]
    for _ in range(m):
        r = rng.random()
        if r < 0.03:
            k = 0
        elif r < 0.10:
            k = 1
        elif r < 0.30:
            k = 2
        else:
            k = rng.choice([3, 3, 3, 4, 5])
        lits = [rng.randint(1, n) * rng.choice([1, -1]) for _ in range(k)]
        if lits and rng.random() < 0.05:
            lits.append(lits[0])
        if lits and rng.random() < 0.03:
            lits.append(-lits[0])
        line = " ".join(map(str, lits + [0]))
        if rng.random() < 0.05:
            line = "c noise\n" + line
        lines.append(line)
    if lines and rng.random() < 0.05:
        lines.append(lines[-1])
    return ("\n".join(lines) + "\n").encode()


def generate_cnfuzz(seed, tiny, max_vars):
    cnfuzz = common.tool("cnfuzz")
    if not cnfuzz:
        return None
    for attempt in range(50):
        rc, out, _, _ = common.run([cnfuzz] + (["--tiny"] if tiny else []) + [str(seed + attempt * 1_000_003)], 30)
        if rc == 0 and out and common.parse_cnf(out)[0] <= max_vars:
            return out
    return None


def check_instance(path, args):
    """Reason string if the instance reveals a bug, else None."""
    data = open(path, "rb").read()
    _, clauses = common.parse_cnf(data)
    proof = path + ".drat" if args.drat else None
    rc, out, err, _ = common.run([args.binary, args.subcommand, path] + ([proof] if proof else []), args.timeout)
    if rc is None:
        return "timeout"
    if rc not in (10, 20):
        return f"exit {rc}: {err.decode(errors='replace').strip()[-200:]}"
    got = "SAT" if rc == 10 else "UNSAT"
    if common.solution_status(out) != got:
        return f"exit {rc} but stdout says {common.solution_status(out)}"
    expected = oracle_status(clauses)
    if got != expected:
        return f"oracle says {expected}, got {got}"
    if got == "SAT":
        model = common.temp_file(out, ".model")
        try:
            rc2, _, err2, _ = common.run([args.binary, "check", path, model], args.timeout)
        finally:
            os.unlink(model)
        if rc2 != 0:
            return f"model rejected: {err2.decode(errors='replace').strip()}"
    elif proof:
        reason = common.check_proof(path, proof, args.timeout)
        if reason:
            return reason
    if args.dev_binary and os.access(args.dev_binary, os.X_OK):
        rc3, out3, err3, _ = common.run([args.dev_binary, args.subcommand, path], args.timeout * 10)
        if b"Expect failed" in out3 + err3:
            return "dev binary: Expect failed\n" + (out3 + err3).decode(errors="replace")[-500:]
        if rc3 != rc:
            return f"dev binary exit {rc3} differs from release exit {rc}"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=os.path.join(common.ROOT, "src", "rocsat"))
    ap.add_argument("--dev-binary", default=os.path.join(common.ROOT, "src", "rocsat-dev"))
    ap.add_argument("--subcommand", default="solve")
    ap.add_argument("--seconds", type=float, default=60)
    ap.add_argument("--seed", type=int, default=int(time.time()))
    ap.add_argument("--tiny", action="store_true", help="cnfuzz --tiny (also caps own generator lower)")
    ap.add_argument("--max-vars", type=int, default=24)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--drat", action="store_true", help="verify UNSAT proofs with drat-trim")
    ap.add_argument("--check", metavar="FILE", help=f"predicate mode: exit {BUG_EXIT} iff FILE shows a bug")
    args = ap.parse_args()

    if args.check:
        reason = check_instance(args.check, args)
        if reason:
            print(reason)
            sys.exit(BUG_EXIT)
        sys.exit(0)

    os.makedirs(common.OUT, exist_ok=True)
    rng = random.Random(args.seed)
    deadline = time.time() + args.seconds
    rounds = 0
    own_max = min(args.max_vars, 12) if args.tiny else args.max_vars
    while time.time() < deadline:
        rounds += 1
        seed = rng.getrandbits(31)
        data = None
        if rounds % 2 == 0:
            data = generate_cnfuzz(seed, args.tiny, args.max_vars)
        if data is None:
            data = generate_own(random.Random(seed), own_max)
        path = os.path.join(common.OUT, f"fuzz-{seed}.cnf")
        with open(path, "wb") as f:
            f.write(data)
        reason = check_instance(path, args)
        if reason is None:
            os.unlink(path)
            if args.drat and os.path.isfile(path + ".drat"):
                os.unlink(path + ".drat")
            continue
        fail = os.path.join(common.OUT, f"fail-{seed}.cnf")
        os.rename(path, fail)
        print(f"BUG after {rounds} rounds (seed {args.seed}): {reason}\n  saved {os.path.relpath(fail, common.ROOT)}")
        cnfdd = common.tool("cnfdd")
        if cnfdd:
            small = os.path.join(common.OUT, f"fail-{seed}-min.cnf")
            common.run([cnfdd, "-e", str(BUG_EXIT), fail, small, os.path.join(common.BENCH, "predicate.sh")], 600)
            if os.path.isfile(small):
                print(f"  shrunk to {os.path.relpath(small, common.ROOT)} ({len(common.parse_cnf(open(small, 'rb').read())[1])} clauses)")
        sys.exit(1)
    print(f"fuzz: {rounds} instances clean in {args.seconds:g}s (seed {args.seed})")


if __name__ == "__main__":
    main()
