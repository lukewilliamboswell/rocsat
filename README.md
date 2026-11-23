# rocsat

A CDCL SAT solver written in [Roc](https://www.roc-lang.org) with the new Zig-based compiler.
The reusable solver is exposed through the signed-literal `Rocsat` module and a thin command-line
app. Progress is tracked in `plans/ROADMAP.md`; durable implementation rationale lives in
`DESIGN.md`, and the underlying design research lives in `research/`. Rocsat is licensed under the
[Apache License 2.0](LICENSE).

## Status

Version 0.1.0 is the first source-release candidate. The Phase 1 solver is complete: it produces
checked SAT models and text DRAT proofs, supports persistent incremental clauses and assumptions,
and keeps its learned database bounded. The remaining solver roadmap is measured post-release
research, not missing release functionality.

Rocsat is an experimental solver and a substantial exercise of Roc's new compiler, not a claim to
replace mature native competition solvers. Search is deterministic, but performance and the source
API may change before 1.0. Builds use the exact compiler release in `roc-version` so that compiler
changes in ownership and code generation can be tested before upgrading.

## Toolchain

The compiler is pinned to Roc `0.1.0_RC1` in `roc-version`. On Linux or macOS,
`scripts/install-roc` downloads the matching release asset, verifies its SHA-256, and
installs it under `~/.roc/0.1.0_RC1/`. Set `ROC_BIN` to use an existing installation.
On Apple Silicon, for example, run `ROC_BIN=~/roc-macos_apple_silicon-0.1.0_RC1/roc make source-check`.
If installing manually, extract the whole release archive so the bundled macOS linker can find
`darwin/usr/lib/libSystem.tbd` beside the executable.
[Roc 0.1.0_RC1 release](https://github.com/roc-lang/roc/releases/tag/0.1.0_RC1)

For the test harness, install `git`, `make`, `gcc`, `curl`, `tar`, and
[`uv`](https://docs.astral.sh/uv/getting-started/installation/). On macOS, the Xcode command-line
tools provide the build tools (`xcode-select --install`); on Debian/Ubuntu, install
`build-essential git curl ca-certificates`. Two one-time steps then prepare it, the same way on
macOS and Linux:

    bench/tools.sh     # builds drat-trim, cnfuzz, cnfdd, and dimocheck into bench/tools/
    bench/fetch.py     # downloads and verifies the corpus manifest into bench/corpus/

PySAT is declared by the fuzz and incremental harnesses and fetched by `uv`. Install `hyperfine`
for the timing canary (`make canary`). CaDiCaL is only required to regenerate the committed reference statuses
with `bench/expected.py`; Kissat and MiniSat are optional comparison solvers.

## Quick start

After installing the pinned compiler:

```sh
make build
printf 'p cnf 2 2\n1 2 0\n-1 0\n' > /tmp/example.cnf
src/rocsat solve /tmp/example.cnf
# `solve` prints a model and exits 10, the SAT Competition success code.
```

For an UNSAT formula and checked text proof:

```sh
printf 'p cnf 1 2\n1 0\n-1 0\n' > /tmp/unsat.cnf
src/rocsat solve /tmp/unsat.cnf /tmp/unsat.drat
# Exit 20 is the standard successful UNSAT result.
```

## Building and checking

    make build         # --opt=speed  -> src/rocsat
    make build-dev     # --opt=dev    -> src/rocsat-dev (keeps inline `expect`s)
    make test          # roc test over src/
    make api-check     # build and run examples/api-consumer.roc as a separate application
    make source-check  # CI gate: source tests, harness tests, API consumer, build, version
    make check         # source/API tests, DRAT and incremental regression, 30 s CLI fuzz
    make fuzz-check    # run the declared roc-fuzz examples and allocation budgets
    make fuzz-run      # explore each roc-fuzz target for FUZZ_SECONDS (default 30)
    make canary        # timing canary: ns/clause on a 2 M contradictory implication chain
    make perf-smoke    # 40 serial representatives, 2 s cap, JSON under bench/out/
    make perf-diverse  # 112 serial representatives, 10 s cap, JSON under bench/out/

`make check` is the commit gate and takes a few minutes; it needs the corpus and proof checker
from the one-time harness steps above, while `make build` needs only the pinned compiler.

`src/rocsat <command> ...`: `solve <cnf> [proof.drat]` (CDCL; writes a text DRAT proof when a
path is given), `incremental <transcript>`, `parse <cnf>`, `brute <cnf>` (enumeration reference,
≤ 24 vars), `check <cnf> <model>`, `version`, `help`. One-shot solving prints `c` statistics, then
SAT-competition `s`/`v` lines, and exits 10 (SAT) / 20 (UNSAT).

## Fuzz suites

`src/fuzz.roc` groups the solver and DIMACS suites with roc-fuzz 0.7.0. The solver suite checks
batch and incremental results against brute force, including models and failed-assumption cores,
and checks allocation growth for repeated `new_var` calls. The DIMACS suite covers round trips,
arbitrary body bytes, and the parser's allocation budget for overstated clause counts.
[roc-fuzz 0.7.0 release](https://github.com/lukewilliamboswell/roc-fuzz/releases/tag/0.7.0)

```sh
make fuzz-build
.roc-cache/rocsat-fuzz --list-targets
.roc-cache/rocsat-fuzz --target=incremental-vs-brute run --runs=200000 --time=60
```

The suites run on Apple Silicon macOS and Linux x86-64. The runner keeps corpora and reports
under `.roc-fuzz/` by default. Use the same target name with `show` and `replay` to inspect or
rerun a saved input. The existing `make fuzz` also checks against PySAT and verifies DRAT proofs.

## Incremental API

Add this dependency to your app header and import `sat.Rocsat`. The package uses Roc
`0.1.0_RC1` and works with the app's choice of platform.

```roc
sat: "https://github.com/lukewilliamboswell/rocsat/releases/download/0.0.1/BMxghpQfH1SCuFgQS2vUDCUhqkMLNniXerXCe4h5nH83.tar.zst",
```

`Rocsat` accepts nonzero signed `I32` DIMACS literals. Variables can be introduced with
`new_var` or by mentioning them in a clause or assumption.

```roc
import sat.Rocsat

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

### Scope and limitations

- The CLI reads DIMACS and incremental transcripts from files; it does not currently read CNF from
  standard input.
- Proof output is text DRAT for one-shot/global UNSAT solving. Incremental assumption conflicts are
  exposed as failed-assumption clauses, not proof streams.
- The engine deliberately has no variable-elimination preprocessor. Such elimination would need
  model reconstruction and revival semantics for later incremental clauses.
- The package exposes the `Rocsat` module as its Roc API. `make api-check` builds and runs a
  separate consumer against the package. `make bundle` writes the distributable archive to
  `.roc-cache/bundles/`.

Solver structure (`src/`): `Rocsat` (public incremental facade), `Core` (state record, arena,
watch pool, trail primitives), `Propagate` (2WL unit propagation), `Analyze` (1-UIP and recursive minimization), `Branch` (deterministic
EVSIDS and phase saving), `Reduce` (LBD tiers, learned-clause deletion, arena GC), `Simplify`
(level-0 clause cleanup), `Drat` (proof lines), and `Solver` (clause input and search loop). Search
uses Luby restarts; proof-safe watch rebuilds and compacting collection keep the learned database
bounded. Hot code takes and returns lists, never the state record — the header of `src/Core.roc`
explains the ownership constraints those shapes address.

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
models still fail. `--rss` samples aggregate process-tree peak RSS on Linux every five milliseconds,
so adapter children are included (very short-lived children can finish between samples). JSON
preserves solver counters. Compare two runs with:

```
uv run --script bench/compare.py baseline.json candidate.json --json comparison.json
```

`bench/minisat.sh` adapts a local MiniSat (`MINISAT_BIN=/path/to/minisat`), whose model is
reported separately, and `bench/competition.sh` runs any solver that already emits competition
output (`SOLVER_BIN=/path/to/kissat`, likewise CaDiCaL). Both wrappers cost a few milliseconds
per instance that rocsat, invoked directly, does not pay, so per-instance time ratios against an
adapted solver are unreliable below roughly 100 ms; solved counts and PAR-2 at second-scale
timeouts are unaffected.
Performance runs deliberately omit proofs because proof size is not bounded by input size; the
normal regression gate continues to check every UNSAT proof.

## Layout

- `src/` — the Roc app (`main.roc`) and solver modules
- `examples/api-consumer.roc` — separately compiled public-module contract example
- `bench/` — harness: `run.py` (instance sets, model/proof checks, PAR-2), `fuzz.py`,
  `incremental.py` (fresh-PySAT sequence differential), `fetch.py`/`corpus.toml` (hash-pinned
  corpus), `profile.py`, `compare.py`, `expected.py` (reference statuses in `bench/expected/`),
  performance manifests, `regression.txt`, and `canary.sh`
- `tests/edge/` — hand-written edge-case CNFs
- `DESIGN.md` — durable implementation choices and measured tuning rationale
- `research/`, `roc-docs/`, `spike/` — background material, frozen
- `upstream/` — verified reproducers for the compiler and toolchain problems this project hit,
  one directory per issue; `upstream/README.md` tracks filed reports and pending drafts
- `scripts/` — pinned compiler installer/launcher and the external API-consumer check
- `.github/workflows/check.yml` — clean Linux source/API validation using the compiler pin
- `plans/` — local planning documents; only `ROADMAP.md` is committed

## License

Licensed under the [Apache License 2.0](LICENSE).
