# rocsat

A CDCL SAT solver written in [Roc](https://www.roc-lang.org) (the new Zig-based compiler): a
library with a thin command-line front end. Progress is tracked in `plans/ROADMAP.md`; the design
notes behind it live in `research/`.

## Toolchain

The compiler is pinned in `roc-version`; `scripts/roc` runs that exact nightly from
`~/.roc/<tag>/roc` (or `$ROC_BIN`) and never a `roc` found on `PATH`. To install it, download the
tarball for your platform from `https://github.com/roc-lang/nightlies/releases/tag/<tag>` and
extract it so that `~/.roc/<tag>/roc` exists.

External tools for the test harness (CaDiCaL as status oracle, drat-trim, cnfuzz, cnfdd,
dimocheck, hyperfine, `uv` for the Python scripts — PySAT is a script dependency `uv` fetches)
and the SATLIB corpora are installed once:

    bench/tools.sh     # brew + builds into bench/tools/
    bench/fetch.sh     # SATLIB into bench/corpus/

## Building and checking

    make build         # --opt=speed  -> src/rocsat
    make build-dev     # --opt=dev    -> src/rocsat-dev (keeps inline `expect`s)
    make test          # roc test over src/
    make check         # test + regression set + 30 s fuzz; what every commit must pass
    make canary        # hyperfine timing canary (bench/canary.sh)

`src/rocsat <command> <file.cnf>`: `parse`, `brute` (enumeration reference, ≤ 24 vars),
`check <cnf> <model>`, `version`, `help`. Solving subcommands print SAT-competition output and
exit 10 (SAT) / 20 (UNSAT).

## Layout

- `src/` — the Roc app (`main.roc`) and modules (`Dimacs`, `Model`, `Brute`, …)
- `bench/` — harness: `run.py` (instance sets, model/proof checks, PAR-2), `fuzz.py`,
  `expected.py` (reference statuses in `bench/expected/`), `regression.txt`, `canary.sh`
- `tests/edge/` — hand-written edge-case CNFs
- `research/`, `roc-docs/`, `spike/` — background material, frozen
- `plans/` — local planning documents; only `ROADMAP.md` is committed
