# rocsat

A CDCL SAT solver written in [Roc](https://www.roc-lang.org) with the new Zig-based compiler.
The completed core solver is currently exposed through a command-line app; the library API is a
later milestone. Progress is tracked in `plans/ROADMAP.md`, and its design notes live in
`research/`.

## Toolchain

The compiler is pinned in `roc-version`; `scripts/roc` runs that exact nightly from
`~/.roc/<tag>/roc` (or `$ROC_BIN`) and never a `roc` found on `PATH`. To install it, download the
tarball for your platform from `https://github.com/roc-lang/nightlies/releases/tag/<tag>` and
extract it so that `~/.roc/<tag>/roc` exists.

For the test harness, install `git`, `make`, `gcc`, `curl`, `tar`, and
[`uv`](https://docs.astral.sh/uv/getting-started/installation/). On macOS, the Xcode command-line
tools provide the build tools (`xcode-select --install`); on Debian/Ubuntu, install
`build-essential git curl ca-certificates`. Then the same commands work on macOS and Linux:

    bench/tools.sh     # builds drat-trim, cnfuzz, cnfdd, and dimocheck into bench/tools/
    bench/fetch.sh     # downloads and normalizes SATLIB into bench/corpus/
    make check

PySAT is declared by `bench/fuzz.py` and fetched by `uv`. Install `hyperfine` for the timing
canary (`make canary`). CaDiCaL is only required to regenerate the committed reference statuses
with `bench/expected.py`; Kissat and MiniSat are optional comparison solvers.

## Building and checking

    make build         # --opt=speed  -> src/rocsat
    make build-dev     # --opt=dev    -> src/rocsat-dev (keeps inline `expect`s)
    make test          # roc test over src/
    make check         # test + regression set + 30 s fuzz; what every commit must pass
    make canary        # timing canary: ns per clause on a 2 M implication chain vs bench/canary-ceiling.txt

`src/rocsat <command> ...`: `solve <cnf> [proof.drat]` (CDCL; writes a text DRAT proof when a
path is given), `parse <cnf>`, `brute <cnf>` (enumeration reference, ≤ 24 vars), `check <cnf>
<model>`, `version`, `help`. Solving subcommands print `c` statistics, then SAT-competition
`s`/`v` lines, and exit 10 (SAT) / 20 (UNSAT).

Solver structure (`src/`): `Core` (state record, arena, watch pool, trail primitives), `Propagate`
(2WL unit propagation), `Analyze` (1-UIP), `Drat` (proof lines), `Solver` (clause input, search
loop, model). Hot code takes and returns lists, never the state record — the header of
`src/Core.roc` explains why and what shapes this Roc nightly keeps in place.

## Layout

- `src/` — the Roc app (`main.roc`) and modules (`Dimacs`, `Model`, `Brute`, `Core`, `Propagate`,
  `Analyze`, `Drat`, `Solver`)
- `bench/` — harness: `run.py` (instance sets, model/proof checks, PAR-2), `fuzz.py`,
  `expected.py` (reference statuses in `bench/expected/`), `regression.txt`, `canary.sh`
- `tests/edge/` — hand-written edge-case CNFs
- `research/`, `roc-docs/`, `spike/` — background material, frozen
- `plans/` — local planning documents; only `ROADMAP.md` is committed
