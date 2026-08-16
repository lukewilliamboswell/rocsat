#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Runs a rocsat subcommand over instance sets and checks every answer.

    bench/run.py <binary> <subcommand> <set|list.txt|glob>... [options]

Per instance: exit code must be 10 or 20 and agree with bench/expected/<set>.tsv when recorded;
SAT answers are re-checked with `<binary> check` (and dimocheck when built); UNSAT answers are
checked with drat-trim when `--drat` is given (the proof path is passed as an extra argument).
Prints failures, solved count and PAR-2; exit status 1 on any failure.

Options: --timeout S (default 60), --jobs N, --max-vars N (skip larger instances), --drat,
--rerun (run twice, stdout must be identical), --json FILE.
"""

import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor

import common


def check_model(binary, cnf, stdout, timeout):
    model = common.temp_file(stdout, ".model")
    try:
        rc, _, err, _ = common.run([binary, "check", cnf, model], timeout)
        if rc != 0:
            return f"model rejected: {err.decode(errors='replace').strip()}"
        dimocheck = common.tool("dimocheck")
        if dimocheck:
            strict_cnf = common.temp_file(common.sanitized(cnf), ".cnf")
            try:
                rc, out, err, _ = common.run([dimocheck, strict_cnf, model], timeout)
            finally:
                os.unlink(strict_cnf)
            if rc != 0:
                return f"dimocheck rejected: {(out + err).decode(errors='replace').strip()[-200:]}"
        return None
    finally:
        os.unlink(model)


def check_proof(cnf, proof, timeout):
    drat_trim = common.tool("drat-trim")
    if not drat_trim:
        return "drat-trim not built (bench/tools.sh)"
    if not os.path.isfile(proof):
        return "no proof file written"
    rc, out, _, _ = common.run([drat_trim, cnf, proof], timeout)
    if b"s VERIFIED" not in out:
        return "drat-trim: " + out.decode(errors="replace").strip().splitlines()[-1:][0] if out else "drat-trim: no output"
    return None


def run_one(args, cnf, expected):
    name = os.path.relpath(cnf, common.ROOT)
    result = {"instance": name, "expected": expected}
    if args.max_vars and common.header_vars(cnf) > args.max_vars:
        result["status"] = "skipped"
        return result
    cmd = [args.binary, args.subcommand, cnf]
    proof = None
    if args.drat:
        os.makedirs(common.OUT, exist_ok=True)
        proof = os.path.join(common.OUT, os.path.basename(cnf) + ".drat")
        cmd.append(proof)
    rc, out, err, secs = common.run(cmd, args.timeout)
    result["seconds"] = round(secs, 4)
    result["rc"] = rc
    fail = None
    if rc is None:
        fail = "timeout"
    elif rc not in (10, 20):
        fail = f"exit {rc}: {err.decode(errors='replace').strip()[-200:]}"
    else:
        got = "SAT" if rc == 10 else "UNSAT"
        result["got"] = got
        if common.solution_status(out) != got:
            fail = f"exit {rc} but stdout says {common.solution_status(out)}"
        elif expected and expected != got:
            fail = f"expected {expected}, got {got}"
        elif got == "SAT":
            fail = check_model(args.binary, cnf, out, args.timeout)
        elif args.drat:
            fail = check_proof(cnf, proof, args.timeout)
        if fail is None and args.rerun:
            rc2, out2, _, _ = common.run(cmd, args.timeout)
            if rc2 != rc or out2 != out:
                fail = "nondeterministic: second run differs"
    if proof and os.path.isfile(proof) and fail is None:
        os.unlink(proof)
    result["status"] = "fail" if fail else "ok"
    if fail:
        result["reason"] = fail
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("subcommand")
    ap.add_argument("specs", nargs="+")
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    ap.add_argument("--max-vars", type=int, default=0)
    ap.add_argument("--drat", action="store_true")
    ap.add_argument("--rerun", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args()

    files = common.resolve_instances(args.specs)
    expected_by_set = {}
    jobs = []
    for f in files:
        s = common.set_of(f)
        if s not in expected_by_set:
            expected_by_set[s] = common.load_expected(s)
        jobs.append((f, expected_by_set[s].get(os.path.basename(f))))
    with ThreadPoolExecutor(args.jobs) as ex:
        results = list(ex.map(lambda j: run_one(args, *j), jobs))

    ran = [r for r in results if r["status"] != "skipped"]
    fails = [r for r in ran if r["status"] == "fail"]
    for r in fails:
        print(f"FAIL {r['instance']}: {r['reason']}")
    solved = len(ran) - len(fails)
    par2 = sum(r.get("seconds", 0) if r["status"] == "ok" else 2 * args.timeout for r in ran)
    total = sum(r.get("seconds", 0) for r in ran)
    print(f"{args.subcommand}: {solved}/{len(ran)} ok, {len(fails)} failed, "
          f"{len(results) - len(ran)} skipped; total {total:.2f}s, PAR-2 {par2:.2f}s"
          + (f", slowest {max(r.get('seconds', 0) for r in ran):.3f}s" if ran else ""))
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"binary": args.binary, "subcommand": args.subcommand, "timeout": args.timeout,
                       "results": results}, f, indent=1)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
