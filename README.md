# rocsat

A CDCL SAT solver written in [Roc](https://www.roc-lang.org) with the new Zig-based compiler.
The reusable solver is exposed through the signed-literal `Rocsat` module and a thin command-line
app. Progress is tracked in `plans/ROADMAP.md`, and its design notes live in `research/`.

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
    bench/fetch.py     # downloads and verifies the corpus manifest into bench/corpus/
    make check

PySAT is declared by the fuzz and incremental harnesses and fetched by `uv`. Install `hyperfine`
for the timing canary (`make canary`). CaDiCaL is only required to regenerate the committed reference statuses
with `bench/expected.py`; Kissat and MiniSat are optional comparison solvers.

## Building and checking

    make build         # --opt=speed  -> src/rocsat
    make build-dev     # --opt=dev    -> src/rocsat-dev (keeps inline `expect`s)
    make test          # roc test over src/
    make check         # test + regression + incremental differential + 30 s fuzz; commit gate
    make canary        # timing canary: ns/clause on a 2 M contradictory implication chain
    make perf-smoke    # 40 serial representatives, 2 s cap, JSON under bench/out/
    make perf-diverse  # 112 serial representatives, 10 s cap, JSON under bench/out/

`src/rocsat <command> ...`: `solve <cnf> [proof.drat]` (CDCL; writes a text DRAT proof when a
path is given), `incremental <transcript>`, `parse <cnf>`, `brute <cnf>` (enumeration reference,
≤ 24 vars), `check <cnf> <model>`, `version`, `help`. One-shot solving prints `c` statistics, then
SAT-competition `s`/`v` lines, and exits 10 (SAT) / 20 (UNSAT).

## Incremental API

`src/Rocsat.roc` accepts nonzero signed `I32` DIMACS literals and owns conversion to the engine's
internal encoding. Variables can be introduced with `new_var` or simply by mentioning them in a
clause or assumption. The main operations are:

```roc
state0 = Rocsat.new({})
state1 = Rocsat.add_clause(state0, [1, -2])?
state2 = Rocsat.add_clause(state1, [2, 3])?
(state3, result) = Rocsat.solve(state2, [1, -3])?
```

The surface provides `new`, `new_var`, `num_vars`, `add_clause`, `set_phase`, `solve`, `value`,
`model`, `failed`, `final_conflict`, and `stats`. A SAT assignment remains inspectable until the
next solve or mutation. UNSAT under assumptions leaves the state reusable; a global refutation is
permanent. `final_conflict` is the implied clause of **negated** failed assumptions, so
`failed(state, a)` is true exactly when `-a` occurs in that clause.

For shell-driven tests, an incremental transcript uses `+` for clauses and `?` for assumption
queries:

```
p rocsat
+ -1 2 0
? 1 -2 0
? -1 0
```

Each query prints `s SATISFIABLE` plus `v` lines, or `s UNSATISFIABLE` plus a `u` line containing
the final-conflict clause. This `+`/`?` protocol supports interleaved additions and is deliberately
not called standard INCCNF. Text DRAT output remains a one-shot/global-UNSAT facility.

Solver structure (`src/`): `Rocsat` (public incremental facade), `Core` (state record, arena,
watch pool, trail primitives), `Propagate` (2WL unit propagation), `Analyze` (1-UIP and recursive minimization), `Branch` (deterministic
EVSIDS and phase saving), `Reduce` (LBD tiers, learned-clause deletion, arena GC), `Simplify`
(level-0 clause cleanup), `Drat` (proof lines), and `Solver` (clause input and search loop). Search
uses Luby restarts; proof-safe watch rebuilds and compacting collection keep the learned database
bounded. Hot code takes and returns lists, never the state record — the header of `src/Core.roc`
explains why and what shapes this Roc nightly keeps in place.

## Benchmark corpus

`bench/corpus.toml` is the reproducible corpus manifest. `bench/fetch.py` verifies every source
archive or normalized CNF by SHA-256, replaces sets atomically, and refuses to cross its 900 MB
budget. Corpus files remain ignored; `bench/corpus-profile.json` commits their static shape
metadata and expected statuses live under `bench/expected/`.

The current fetch contains 5,680 CNFs and 532 MiB of formula data: 24 small SATLIB/classic sets
plus one known-result representative from each of 81 compact SAT Competition 2025 families. It
covers random and crafted formulas, graph/CSP puzzles, planning and scheduling, hardware/BMC,
software analysis, arithmetic and cryptography, parity/XOR, and mixed industrial encodings.
Competition entries are capped at 75 MiB extracted. Their statuses come from GBD; the added
SATLIB sets were independently classified with PySAT's CaDiCaL 1.9.5 backend (parity is SAT by
construction, as its source states).

Performance tiers are separate from `make check` and always run serially:

- `perf-smoke`: 40 load representatives at two seconds, bounded to 80 seconds per build. The
  acceptance runs took 48.7 seconds for rocsat and 44.4 seconds for MiniSat.
- `perf-diverse`: 112 instances at ten seconds, bounded to 18 minutes 40 seconds per build. The
  acceptance run took 12 minutes 51 seconds for rocsat.

Benchmark timeouts mean *unsolved*, not failure; crashes, wrong known statuses, and invalid SAT
models still fail. `--rss` samples direct-process peak RSS on Linux and JSON preserves solver
counters. Compare two runs with:

```
uv run --script bench/compare.py baseline.json candidate.json --json comparison.json
```

`bench/minisat.sh` adapts a local MiniSat (`MINISAT_BIN=/path/to/minisat`) to the same output.
Performance runs deliberately omit proofs because proof size is not bounded by input size; the
normal regression gate continues to check every UNSAT proof.

## Layout

- `src/` — the Roc app (`main.roc`) and solver modules
- `bench/` — harness: `run.py` (instance sets, model/proof checks, PAR-2), `fuzz.py`,
  `incremental.py` (fresh-PySAT sequence differential), `fetch.py`/`corpus.toml` (hash-pinned
  corpus), `profile.py`, `compare.py`, `expected.py` (reference statuses in `bench/expected/`),
  performance manifests, `regression.txt`, and `canary.sh`
- `tests/edge/` — hand-written edge-case CNFs
- `research/`, `roc-docs/`, `spike/` — background material, frozen
- `upstream/` — verified reproducers for the compiler and toolchain problems this project hit,
  one directory per issue; `upstream/README.md` tracks filed reports and pending drafts
- `plans/` — local planning documents; only `ROADMAP.md` is committed
