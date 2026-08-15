# Track C — Testing and benchmarking a from-scratch CDCL solver (rocsat)

Researched 2026-08-15 on macOS 24.6 / Apple silicon (arm64). Every tool below was checked
for existence *today* (GitHub API `pushed_at`, PyPI, Homebrew, or HTTP HEAD on the download).
Roc measurements were made with the release nightly `nightly-2026-08-13-2fdd90e`
(the `roc` at `~/programs/roc` is a `debug-*` tracy build; see §8).

Legend for status: **live** = commits/release in the last ~12 months; **stable/frozen** =
no recent commits but builds and is still the reference tool; **abandoned** = no maintained
home, use a successor.

---

## 1. Checking a single answer

### SAT answers
Trivial: parse the model, check every clause has a true literal. Do this **inside the
solver's own driver** on every SAT result (it costs O(|F|), negligible), and also with an
external checker so the check is independent of the solver's own clause database:

- `dimocheck` (Biere) — standalone DIMACS model checker, used by `runcnfuzz`.
  https://github.com/arminbiere/dimocheck — **live** (pushed 2025-02).
  `git clone https://github.com/arminbiere/dimocheck && cd dimocheck && ./configure && make`
- `drat-trim -S` also does a "SAT check mode" (forward checking of a model) —
  https://github.com/marijnheule/drat-trim/blob/master/drat-trim.c (`printHelp`).

Watch for the standard exit codes: **10 = SAT, 20 = UNSAT, 0 = unknown/error**. Adopt them
from day one; every downstream script (`runcnfuzz`, SAT-competition harnesses, pysat) keys
on them (https://github.com/arminbiere/cnfuzz/blob/master/runcnfuzz).

### UNSAT answers: proof logging
An UNSAT answer is only trustworthy with a checkable certificate. Two formats matter:

| Format | What the solver emits | Cost to emit | Checker | Notes |
|---|---|---|---|---|
| **DRAT** | every learned clause (`1 -2 0`) and every deletion (`d 1 -2 0`), in order | ~free: an `fprintf`/write per learned clause; deletions optional but they speed checking a lot | `drat-trim` (does RUP + RAT check, backward, core-first) | The SAT-competition standard since 2013. Binary variant exists (drat-trim autodetects; `-i`/`-I` force). |
| **LRAT** | DRAT + for each addition the *hint list* of clause ids used to derive it, plus explicit ids | needs the solver to track clause ids and antecedents during conflict analysis — more code, small runtime overhead | `lrat-check` (C, in the drat-trim repo), `cake_lpr` (formally verified), ACL2 checker | Linear-time check; needed if you want a *verified* checker. drat-trim can *convert* DRAT to LRAT with `-L out.lrat`. |

**Recommendation for rocsat: emit DRAT first** (it is literally "print the learned clause
before you add it, print `d` before you delete it"), and check with `drat-trim`. LRAT is
an upgrade for later — CaDiCaL shows the way (`--lrat`, `--binary`,
https://github.com/arminbiere/cadical/blob/master/src/options.hpp) and the SAT'23 paper
"Faster LRAT Checking Than Solving with CaDiCaL" argues LRAT checking can be faster than
solving (https://drops.dagstuhl.de/storage/00lipics/lipics-vol271-sat2023/LIPIcs.SAT.2023.21/LIPIcs.SAT.2023.21.pdf).

**Correctness detail that bites new solvers:** every clause you *add* must be RUP/RAT with
respect to the current database, including clauses produced by preprocessing/simplification
and by clause minimisation; and you must not delete a clause you still rely on for later
derivations (drat-trim ignores deletions in `-p` plain mode if you get them wrong, at a
big time cost). Unit clauses/learned units are added like any other. Emit the empty clause
`0` at the end.

### drat-trim today
- https://github.com/marijnheule/drat-trim — **stable/frozen** (last push 2024-11-25,
  212 commits, issues still opened in 2025). Builds with plain `make` (Makefile at
  https://github.com/marijnheule/drat-trim/blob/master/Makefile). No Homebrew formula.
  ```sh
  git clone https://github.com/marijnheule/drat-trim && cd drat-trim && make
  # binaries: drat-trim, lrat-check, compress, decompress
  ./drat-trim formula.cnf proof.drat            # prints "s VERIFIED" / "s NOT VERIFIED"
  ./drat-trim formula.cnf proof.drat -L p.lrat  # emit LRAT for a verified checker
  ./lrat-check formula.cnf p.lrat
  ```
  Options (from `printHelp`): `-f` forward mode, `-u` no core-first, `-t <sec>` time limit
  (default 20000), `-c CORE` unsat core, `-l/-L` lemma output (DRAT/LRAT), `-S` SAT-check.
- `cake_lpr` — formally verified LRAT/LPR checker in CakeML, used to validate SC proofs
  since 2020; supports binary LRAT since 2024. https://github.com/tanyongkiam/cake_lpr —
  **live** (pushed 2026-07). Building needs the CakeML compiler chain; treat it as an
  optional "belt and braces" step, not the daily loop.
- ACL2 LRAT checker (`acl2/acl2` books, https://github.com/acl2/acl2 — **live**) — the
  fastest verified LRAT checker per the cake_lpr paper; heavyweight toolchain.
- CaDiCaL ships an *internal* online LRAT checker (`src/lratchecker.cpp`,
  `--checkproof`) — a useful architectural model: an in-process checker you can turn on in
  debug builds.

### Cost of proof checking
- Backward DRAT checking with core-first propagation is typically of the same order as
  solving, sometimes several times more on hard instances; that is why the competition
  gives the checker a separate, generous budget and why deletion info matters (drat-trim
  README: "The main reason to include clause deletion steps in proofs is to reduce the
  computational costs to validate proofs" —
  https://github.com/marijnheule/drat-trim/blob/master/README.md).
- LRAT checking is linear in proof size and can be **faster than solving**
  (Pollitt/Fleury/Biere SAT'23, link above). Emitting LRAT costs the solver a few percent.
- Proof files can be large (hundreds of MB to GBs on hard instances); use binary DRAT for
  the nightly set, ASCII for the regression set (grep-able).

### Wiring into the test loop
Regression harness (Python or shell) does, per instance:
1. `rocsat inst.cnf --proof out.drat > out.sol; rc=$?`
2. `rc==10` → check model with `dimocheck inst.cnf out.sol` (or in-harness evaluator).
3. `rc==20` → `drat-trim inst.cnf out.drat -t 60`, require the string `s VERIFIED`.
4. Anything else, or a mismatch with the expected status stored next to the instance
   (`inst.cnf.expected`), fails the run.
Every UNSAT in the fast regression suite is small, so drat-trim adds seconds total. Compare
against expected status generated *once* by CaDiCaL/Kissat and committed.

---

## 2. Test corpora

### SATLIB (still online, unchanged since ~2000 — **stable/frozen**)
Index: https://www.cs.ubc.ca/~hoos/SATLIB/benchm.html. Files are tarballs of DIMACS.
Verified by HTTP HEAD 2026-08-15:

| Family | Instances | Vars/clauses | Tarball | Size |
|---|---|---|---|---|
| uf20-91 | 1000 SAT | 20/91 | https://www.cs.ubc.ca/~hoos/SATLIB/Benchmarks/SAT/RND3SAT/uf20-91.tar.gz | 324 KB |
| uf50-218 / uuf50-218 | 1000 SAT / 1000 UNSAT | 50/218 | `.../RND3SAT/uf50-218.tar.gz`, `uuf50-218.tar.gz` | 878 KB each |
| uf100-430 / uuf100-430 | 1000 / 1000 | 100/430 | `.../RND3SAT/uf100-430.tar.gz` | 1.9 MB |
| uf125..uf225 (+uuf) | 100 each | 125–225 vars | same dir | ~0.5 MB each |
| uf250-1065 / uuf250-1065 | 100 / 100 | 250/1065 | `.../RND3SAT/uf250-1065.tar.gz` | 547 KB each |
| flat30-60 … flat200-479 (graph colouring, all SAT) | 100–1000 | | https://www.cs.ubc.ca/~hoos/SATLIB/Benchmarks/SAT/GCP/flat200-479.tar.gz | 518 KB |
| CBS (controlled backbone), planning (blocksworld/logistics), AIS, quasigroup, BMC, DIMACS (aim, dubois, jnh, pret, hole/pigeonhole, par, ssa, bf), Beijing | see index | | https://www.cs.ubc.ca/~hoos/SATLIB/benchm.html | all small |

The whole RND3SAT set is under 15 MB. Note the "u" in `uf` = uniform, `uuf` = uniform
*unsat*; every `uuf` instance is a proof-checking test for free. The DIMACS `hole*.cnf`
(pigeonhole) and `dubois*`, `pret*` families are classic *hard for resolution* — small files
that take a CDCL solver a surprisingly long time; ideal for catching pathological
performance regressions.

### SAT Competition archives (**live**)
- Yearly site: https://satcompetition.github.io/2025/downloads.html — benchmarks are
  distributed as a `.uri` list (`track_main_2025.uri`) to `wget -i`; solver sources as
  `.tar.xz`. Main-track instances are typically 400 files, several GB compressed.
- Complete archive 2002–2024, 7330 normalised instances, **28.7 GB** zip, CC-BY 4.0:
  https://zenodo.org/records/15125952 (Biere, 2025-04). Comes with a GBD-hash mapping.
- Global Benchmark Database (GBD): https://benchmark-database.de/ — query by feature
  (`track=main_2024`, `family=...`, size bounds), download a `.uri` file, then
  `wget --content-disposition -i allinstances.uri`. Python tool: `pip install gbd-tools`
  (5.2.5 on PyPI, https://github.com/Udopia/gbd — **live**, pushed 2026-08-11). GBD is
  the way to select "all main-track instances under 2 MB solved by every solver in <10 s"
  for a mid-size suite.

### Generators
- **cnfgen** — `pip3 install cnfgen` (0.9.6, released 2026-07-23, Python ≥ 3.7;
  https://github.com/MassimoLauria/cnfgen — **live**). Families: `randkcnf k n m [seed]`,
  `php` (pigeonhole), `op` (ordering), `tseitin`, `peb`, `kclique`, `ram`, parity, plus
  transformations (`-T shuffle`, xor-substitution) that harden instances without changing
  satisfiability. Docs: https://massimolauria.net/cnfgen/.
- **cnfuzz** (see §4) is also a fine generator of small structured SAT/UNSAT mixes.
- Your own **encoder scripts** for problems with known answers (n-queens, sudoku,
  Langford, small factoring, graph colouring) — the answer is known independent of any
  solver, which is worth a lot early on.

### Suggested corpora
**Fast regression set (every change; target < 60 s; ≈ 5 MB in the repo):**
- uf20-91 (all 1000 — trivial, exercises the parser and the SAT path), uf50/uuf50 (200 of
  each), uf100/uuf100 (50 of each), uf250/uuf250 (10 of each), a dozen `hole6..hole9`,
  `dubois20-29`, `pret60/150`, `aim-*` (some UNSAT aim instances are tiny and famous for
  breaking buggy solvers), 20 flat graph-colouring, and 30 hand-written pathological CNFs
  (empty clause, duplicate literals, tautologies, unit-only, `p cnf 0 0`, variables never
  mentioned, an UNSAT instance made only of binaries, etc.).
- Every UNSAT run proof-checked (§1). Total ≈ 2 000 tiny instances.

**Nightly set (≈ 30–60 min):**
- All of SATLIB RND3SAT + GCP + CBS (~5 000 instances, < 15 MB compressed).
- 100–200 SAT-competition main-track instances chosen via GBD for "solved by Kissat in
  < 60 s", each with a 300 s timeout, run in parallel on P-cores. Report solved count,
  PAR-2, and per-instance deltas vs the previous night.
- One hour of `runcnfuzz` (§4).

---

## 3. Random instances and the phase transition

For uniform random k-SAT with n variables and m clauses, the fraction of satisfiable
instances drops sharply from ≈1 to ≈0 around a critical ratio α = m/n; for 3-SAT that is
α ≈ 4.26 (empirically; the sharp-threshold conjecture is proved for large k), and the
median hardness for complete solvers peaks at the same ratio — instances well below are
under-constrained (easy SAT), well above are over-constrained (easy UNSAT). Original
observation: Mitchell, Selman, Levesque, "Hard and easy distributions of SAT problems",
AAAI'92 (summarised at
https://www.sciencedirect.com/topics/computer-science/phase-transition-phenomenon and
https://cdn.aaai.org/AAAI/1996/AAAI96-038.pdf). This is exactly why SATLIB's uf families
sit at 91/20, 218/50, 430/100, 1065/250 (all ≈ 4.26–4.3).

Why they matter for rocsat: they are the cheapest source of instances whose difficulty is
tunable by a single knob (n), and around the transition you get a natural ≈50/50 SAT/UNSAT
mix, so both the model checker and the proof checker are exercised. Their weakness: they
have no structure, so they say little about industrial performance (VSIDS/restarts/clause
deletion tuned on random 3-SAT will mislead you). Keep them for correctness and for
"did propagation get slower", not for tuning heuristics.

Reproducible generation:
- `cnfgen randkcnf 3 200 852 --seed 42 > r.cnf` — cnfgen accepts `--seed`, and clause
  sampling is without replacement/without duplicate literals; document the cnfgen version
  alongside the seed because generator internals may change between releases
  (https://massimolauria.net/cnfgen/).
- Or 30 lines of your own: seeded PRNG (xoshiro/PCG), pick 3 distinct variables, random
  signs, reject duplicate clauses; store the seed in a `c seed N` comment like cnfuzz does.
  Write it once in Python for the harness and once in Roc for in-solver property tests, and
  cross-check the two produce identical files for the same seed.
- SATLIB's fixed instances are the fully reproducible baseline; regenerate nothing there.

---

## 4. Fuzzing and shrinking

### The claim
Brummayer, Lonsing, Biere, "Automated Testing and Debugging of SAT and QBF Solvers",
SAT'10 (https://cca.informatik.uni-freiburg.de/papers/BrummayerLonsingBiere-SAT10.pdf)
report finding crashes and wrong answers in many contemporary solvers within an hour of
fuzzing with CNFuzz/FuzzSAT, and Biere's own tooling READMEs say cnfuzz/cnfdd have been in
continuous use "since 2007" and that model-based API testing (`mobical`) is "way superior"
for incremental solvers (https://github.com/arminbiere/cnfuzz,
https://github.com/arminbiere/cnfdd). Soos's writeup of his CryptoMiniSat setup
(https://www.msoos.org/2013/08/my-sat-solver-fuzzing-setup/) is the same story. Nobody
publishes a "fraction of bugs found by fuzzing" number, but among solver authors it is the
accepted default; the confirmable statement is: *every serious solver ships a fuzz/delta
loop and its authors credit it with most bug finds*.

### Tools (all Biere, GPL/MIT, C, build with `make`)
| Tool | Home | Status |
|---|---|---|
| **cnfuzz** (layered CNF fuzzer, `--tiny/--small` sizes, prints `c seed N`) + `runcnfuzz`, `ddcnfuzzed`, `cleancnfuzz` scripts | https://github.com/arminbiere/cnfuzz | **live** (pushed 2026-02) |
| **cnfdd** (delta-debugger; shrinks a CNF while a predicate script keeps failing) | https://github.com/arminbiere/cnfdd | **live** (pushed 2025-05) |
| **dimocheck** (model checker used by runcnfuzz) | https://github.com/arminbiere/dimocheck | live (2025-02) |
| CNFuzzDD 2009/2013 zip (cnfuzz + fuzzsat + cnfdd + multi-threaded mcnfdd, QDIMACS) | https://fmv.jku.at/cnfuzzdd/ (`cnfuzzdd2013.zip`, HTTP 200 today) | **frozen** — the GitHub repos above supersede it; **FuzzSAT (circuit-based fuzzer) only lives in this old zip** |
| **mobical** (model-based tester + delta-debugger for the CaDiCaL C++/C API, incl. assumptions) | https://github.com/arminbiere/cadical `src/mobical.cpp`, `scripts/run-mobical-in-parallel.sh` | live |
| lglmbt (Lingeling model-based tester) | https://github.com/arminbiere/lingeling | frozen (2024-03) |

Install (no Homebrew formulas exist for any of these):
```sh
for r in cnfuzz cnfdd dimocheck; do git clone https://github.com/arminbiere/$r; done
(cd cnfuzz && make) ; (cd cnfdd && make) ; (cd dimocheck && ./configure && make)
# put cnfuzz, cnfdd, dimocheck, runcnfuzz, ddcnfuzzed on PATH
```

### The concrete workflow (`runcnfuzz`, read from the script)
```sh
runcnfuzz [--tiny|--small] [-t sec] ./rocsat-check
```
Loop: generate `cnfuzz > /tmp/x.cnf`, run the solver, then
- exit 10 → run `dimocheck cnf sol`; failure = bug;
- exit 20 → fine (unless you make the wrapper proof-check, below);
- exit 0 or crash → bug (`-I` ignores 0 for solvers that use 0);
- on bug, save `bug-<seed>.cnf/.log/.err` and immediately run `cnfdd bug.cnf red.cnf <predicate>`
  to shrink to `red-<seed>.cnf` — typically tens of clauses, human-readable.
`cnfdd` needs a *predicate script* that exits 0 iff the bug is still present; write it to
be as narrow as possible (same wrong status / same assertion text / same proof-check
failure), otherwise the reduction wanders off to a different bug.

**Detecting a wrong answer without a reference solver** — the wrapper `rocsat-check`:
1. SAT → evaluate model (dimocheck).
2. UNSAT → `drat-trim cnf proof` must say `s VERIFIED`. This is what makes fuzzing
   *complete*: with proof checking a wrong UNSAT is caught, with model checking a wrong SAT
   is caught, so an oracle solver is not needed. (drat-trim on fuzzed instances takes
   milliseconds.)
3. Self-consistency: run the solver twice with different seeds/options (or with a
   simplifier off) and require equal status — cheap "option fuzzing", which the cnfuzz
   README explicitly recommends: externalise every heuristic parameter as an option so
   the fuzzer can randomise it and cnfdd can shrink it.
4. Internal invariants (`expect`s, §6) with the debug build in the fuzz loop.

**With a reference solver:** the wrapper runs `cadical -q cnf` and compares exit codes; on
disagreement it still runs the two checkers above to know *who* is wrong. Reference-solver
comparison mostly adds value under assumptions and for incremental use, where there is no
proof format you can check as easily (CaDiCaL does have `--idrup/--lidrup`).

Practicalities: run several `runcnfuzz` in parallel with different `--tiny/--small` mixes,
give the solver a `-t 10` timeout in the wrapper (fuzz should be fast; time-outs are logged
not treated as bugs), commit every reduced `red-*.cnf` into the regression set with the
expected status.

---

## 5. Differential testing

### Reference solvers on macOS arm64 (all verified in Homebrew core on 2026-08-15)
| Solver | Install | Version today | Proof output | Assumptions |
|---|---|---|---|---|
| **CaDiCaL** | `brew install cadical` (3.0.1) or `git clone https://github.com/arminbiere/cadical && ./configure && make` (rel-3.0.1, 2026-07-20; repo pushed 2026-08-07) | 3.0.1 | `cadical cnf proof.drat` (binary by default; `--no-binary`; `--lrat`, `--frat`, `--idrup`, `--lidrup`, `--veripb`) | via C++/C API (`assume`), and via *icnf* incremental files (`cadical` reads `.icnf` with `a` lines when built/invoked for incremental — check `cadical -h`) |
| **Kissat** | `brew install kissat` (4.0.4; https://github.com/arminbiere/kissat rel-4.0.4 2025-10-16) | 4.0.4 | `kissat cnf proof` (binary DRAT unless `--no-binary`, per `src/application.c`) | none — Kissat is non-incremental |
| **MiniSat 2.2** | `brew install minisat` (2.2.1, formula points at the stp/minisat fork; upstream https://github.com/niklasso/minisat is frozen since 2024-04, last release 2010) | 2.2.1 | none | via C++ API only |
| **CryptoMiniSat** | `brew install cryptominisat` (5.14.7; https://github.com/msoos/cryptominisat live) | 5.14.7 | `--drat` (FRAT variants) | Python bindings `pycryptosat` |
| **PySAT** | `pip3 install python-sat` (1.9.dev14, 2026-08-14; https://github.com/pysathq/pysat, wheels for macOS arm64) | bundles CaDiCaL 1.0.3/1.5.3/1.9.5/3.0.0, Glucose 3/4.1/4.2.1, Kissat 4.0.4, MiniSat 2.2, MapleCM, Lingeling, … | Glucose/CaDiCaL proof tracing exposed for some | **`solve(assumptions=[...])` uniform across all backends** — this is the assumptions oracle |

MiniSat is the *architectural* reference for rocsat, but as a differential oracle prefer
CaDiCaL/Kissat: MiniSat has known bugs on odd inputs and no proof output.

### Comparing results
Plain: run both, compare exit codes (10/20). If your solver disagrees with CaDiCaL,
`drat-trim`/`dimocheck` decides who is wrong (usually you). Automate:
```sh
cadical -q x.cnf; a=$?; ./rocsat x.cnf --proof p.drat >m.sol; b=$?
[ $a = $b ] || echo "DISAGREE $a vs $b"
```
Under **assumptions** the CLIs differ or don't exist, so drive both through PySAT (one
process, same clause list, same assumption vector) and your solver through its own
assumption interface (a `--assume "1 -3 5"` flag or `.icnf`-style `a 1 -3 5 0` lines):
- compare status; on UNSAT compare that your **failed-assumption set (final conflict /
  `core`)** is a *subset* of the assumptions and that the reference finds the formula UNSAT
  under exactly that subset (cores are not unique, so never compare them for equality);
- on SAT check the model satisfies both the clauses and the assumptions;
- for incremental sequences (add clauses, solve, assume, solve …) generate the sequence
  from a seed and replay it into both; this is what mobical does for CaDiCaL and is the
  most productive fuzz mode once you have an incremental API.

---

## 6. Property-based and unit-level testing

### Properties worth asserting (cheap enough to leave on in dev)
Unit propagation / watched literals (the "two-watched-literal invariant", MiniSat
`Solver::propagate`):
1. For every clause C in the database, C is watched by exactly its literals `C[0]` and
   `C[1]` (i.e. C appears in `watches[¬C[0]]` and `watches[¬C[1]]` and nowhere else).
2. After propagation reaches fixpoint with no conflict: for every clause, **either** some
   watched literal is true, **or** both watched literals are unassigned, **or** a watched
   literal is false only if the other watched literal is true and was assigned at a
   level ≤ the level of the false one. (Equivalent formulation: no clause is unit or
   falsified under the current assignment.) This is *the* invariant; almost every
   propagation bug breaks it.
3. Every literal on the trail is either a decision or has a reason clause; in the reason
   clause the propagated literal is `C[0]` and every other literal is false and assigned
   *earlier on the trail* (and at a level ≤ current).
4. `trail_lim` is monotone, `level(trail[i])` is non-decreasing in `i`, `qhead ≤ |trail|`.
5. Var data consistency: `assigns[v]`, `level[v]`, `reason[v]` are undefined together for
   unassigned v; the VSIDS heap contains exactly the unassigned variables (or a superset,
   depending on the lazy scheme) and satisfies the heap property.
Conflict analysis:
6. The learned clause is (a) falsified under the current assignment, (b) has exactly one
   literal at the conflict level (1-UIP) — asserted as `C[0]` — and (c) `C[1]` (if any) is
   the literal with the highest level among the rest, so backjumping to `level(C[1])` makes
   the clause unit. (d) After minimisation the clause is still implied by the original
   clauses — checkable *for real* only via DRAT (§1); an in-process RUP check with a scratch
   propagate is possible on tiny inputs in tests.
7. After backjump: every literal at levels > backjump level is unassigned and re-inserted
   in the heap; the learned clause is unit and gets propagated.
Clause database:
8. No duplicate literals or tautologies in stored clauses; deleted clauses are not in any
   watch list; the count of clauses in watch lists is 2× the number of live clauses.
Whole-solver properties (property-based tests, seeded random small CNFs, n ≤ 30):
9. `solve(F)` = SAT ⇒ model satisfies F. `solve(F)` = UNSAT ⇒ brute force (2^n, n ≤ 16)
   agrees, or the DRAT proof verifies.
10. Adding a clause never turns UNSAT into SAT; adding a satisfied model's negation as a
    blocking clause and re-solving enumerates without repeating models.
11. Idempotence: solving twice with the same seed gives the same statistics (determinism —
    invaluable for debugging; check it in CI).

Cost control: invariants 1–2 and 8 are O(|F|); run them (a) after every propagate in the
debug build on the fuzz/regression sets only when a `--check` option is on, and (b)
unconditionally at *restart* boundaries and at the end of `solve`. Invariants 3–7 are O(1)
or O(|clause|) and can stay on always in dev builds.

### Roc `expect` — measured behaviour today (nightly-2026-08-13-2fdd90e)
Test files: scratchpad `exp/expect_test.roc`, `exp/expect_test2.roc`, `exp/expect_cost.roc`.

| How the code runs | Inline `expect` inside a function that fails |
|---|---|
| `roc run file.roc` / `roc run --opt=dev` / `--opt=interpreter` | prints `Expect failed: expect failed` to stderr, **execution continues**, process exit code **1** |
| `roc run --opt=speed file.roc` | **silently ignored**, exit 0 |
| `roc build --opt=speed` then run the binary | **silently ignored**, exit 0 |
| `roc build` (default dev/LLVM) then run the binary | **also silently ignored**, exit 0 — contrary to the tutorial ("debug build of roc" reports) |
| `roc test file.roc` (top-level `expect`s call the function) | inline failure prints `Expect failed` **but the enclosing top-level test still counts as passed** and exit code is 0 unless a *top-level* expect fails |
| `roc test --opt=speed` | same as above (result was served from cache; unverified whether a cold speed test build differs) |

The 400M-iteration `while` loop with an `expect $acc >= $i - 1` inside cost the same
0.30 s with and without the expect under `--opt=speed` (min of 2 runs each), consistent
with it being dropped, or at least fully hoisted. `roc build --opt=speed` currently emits
`0 errors and 0 warnings` and produces the executable **in the current working directory**
(not next to the source).

Consequences for the strategy:
- Inline `expect` is a **free** invariant hook in release builds today (docs said "not yet
  compiled out"; the measured binary behaviour is that it is dropped in every *built*
  binary). This is what you want for the O(1) invariants 3–7 — sprinkle them freely.
- But inline `expect` **does not fail a test** and does not abort under `roc run`; so for
  the test loop, do not rely on inline `expect` to *detect* bugs. Wrap the expensive
  checkers as pure functions returning `Bool` and call them from **top-level `expect`s**
  (which do fail `roc test`), and in the debug driver make the wrapper `crash` (or return an
  `Err`) when `--check` is on so `runcnfuzz` sees a non-10/20 exit code.
- Since only *built* binaries drop expects and `roc run` (dev) keeps them and keeps going,
  a debug driver run via `roc run` will spam stderr on the first invariant break; grep the
  fuzz log for `Expect failed`.
- Re-verify this table on every nightly bump; the tutorial says the semantics "could be
  implemented at any moment" (roc-docs/mini-tutorial-new-compiler.md §`expect` statements).
- There is no property-testing library for the new compiler that I could find; write a
  small seeded PRNG (`splitmix64` in ~10 lines with `U64` wrapping ops) and drive
  properties 9–11 from top-level `expect`s that loop over 100 seeds. `roc test` runs
  top-level expects of the main module and everything it imports (`roc test --help`).

---

## 7. Benchmarking method

### What to record (per run, printed as `c ` comment lines like MiniSat/CaDiCaL)
- decisions, propagations, conflicts, restarts, learned clauses (+ literals), reductions /
  deleted clauses, learnt-clause average length, backjump depth average;
- **propagations/sec** and conflicts/sec — the two "engine speed" numbers; on MiniSat-class
  solvers expect roughly 10^6–10^7 props/s per core on industrial instances;
- peak RSS (`/usr/bin/time -l` on macOS prints "maximum resident set size" in bytes);
- proof size and time if logging.
Compare `conflicts` and `decisions` *between two builds* on the same instance: if search
statistics are identical, a speed change is purely engineering (propagation, memory), if
they differ the heuristics changed and wall-clock is not comparable one-to-one.

### How papers/competitions report
- **PAR-2**: sum over instances of solve time, with unsolved instances counted as 2×
  timeout; SAT Competition main track uses a 5000 s timeout (PAR-2 = 10 000 for a
  timeout), see the SC 2020 report https://www.sciencedirect.com/science/article/pii/S0004370221001235
  and tracks page https://satcompetition.github.io/2023/tracks.html.
- **Cactus plot**: sort per-instance times, x = number of instances solved, y = time
  needed; a curve further right/lower is better (e.g. SC 2018 report,
  https://www.researchgate.net/publication/338089065_SAT_Competition_2018).
- Scatter plots (log-log, time of A vs B per instance) are the standard way to compare
  *two* solvers/builds; draw the diagonal and 2×/½× lines.
- Timeouts: 5000 s in the competition; for a lab loop use 60–300 s and report "solved
  within T" plus PAR-2 at that T. Memory limit is conventionally 8–128 GB; note it.
- **runlim** (https://github.com/arminbiere/runlim, live 2026-05) is the sampled
  time/memory limiter Biere uses; on macOS it may need patching (it reads `/proc`), so use
  `ulimit -t` / `timeout` (`brew install coreutils` → `gtimeout`) plus `/usr/bin/time -l`.

### Not fooling yourself on a laptop
- Apple silicon has **performance and efficiency cores** (this machine:
  `sysctl hw.perflevel0.logicalcpu` → 6 P, `hw.perflevel1.logicalcpu` → 6 E). macOS
  schedules by QoS; a process launched with `taskpolicy -c background` is confined to
  E-cores (`man taskpolicy`) — never benchmark that way, and never run more parallel
  solver instances than P-cores. There is no user API to *pin* to a P-core; run one job at
  a time for numbers you publish, and use `powermetrics --samplers cpu_power` (root) to see
  which cluster is busy if a result looks odd.
- **Thermal/power**: keep the lid open, plugged in, no low-power mode (`pmset -g` shows
  `lowpowermode`), and interleave A/B runs (ABAB, not AAABBB) so drift hits both equally.
- **Variance**: report **minimum of N** (N ≥ 5) for engine micro-benchmarks — the minimum
  is the best estimate of the intrinsic cost, noise only ever adds. For whole-suite
  numbers use median or PAR-2 and always give N. Use `hyperfine` (`brew install hyperfine`,
  1.20.0, https://github.com/sharkdp/hyperfine) with `--warmup 2 --min-runs 5 --export-json`
  for command-level timing; it reports mean±σ, min, max and flags outliers.
- Warm the file cache (first run of a large CNF pays disk I/O), and separate parse time
  from solve time in your own stats.
- Deterministic solver + identical stats ⇒ any timing difference is real machine noise or
  code-gen; if stats differ, the comparison is about heuristics.
- Fix the compiler version in the report (`roc version`) — nightlies change weekly.

---

## 8. Roc-specific mechanics

- **Which `roc`?** `roc version` on the release nightly prints
  `Roc compiler version nightly-2026-08-13-2fdd90e`; the one at `~/programs/roc` on this
  machine prints `debug-*` and is a tracy-instrumented debug build (spike/RESULTS.md) —
  unusable for timing and much slower to compile. Get releases from
  https://github.com/roc-lang/nightlies/releases (macOS apple-silicon tarball
  `roc_nightly-macos_apple_silicon-<date>-<sha>.tar.gz`; live, pushed 2026-08-14). Pin
  the exact nightly in a `ROC_VERSION` file and have the harness refuse to run if
  `roc version` disagrees or contains `debug`.
- **Release build**: `roc build --opt=speed main.roc` (LLVM); `--opt=size` also LLVM;
  default `--opt=dev` is the fast-compile backend; `--opt=interpreter` exists. Output goes
  to `./<name>` in the cwd. `--target=arm64musl` etc. for cross builds. (`roc help`.)
- **Timing from inside Roc**: the stdlib has no clock — grep of `Builtin.roc` for
  `nano|monotonic|clock|instant` finds nothing, and the new-compiler headerless app
  exposes only `echo!`/args (roc-docs/NOTES.md). A clock therefore has to come from the
  **platform**: either wait for new-compiler basic-cli (roc-lang/basic-cli PR #423, WIP) or
  build the solver on a custom Zig/Rust platform
  (https://github.com/lukewilliamboswell/roc-platform-template-zig) exposing
  `now_nanos! : {} => U64` (`std.time.nanoTimestamp` / `Instant`) — which the solver
  needs anyway for a proof-file writer and a DIMACS reader. **Until then, time externally**:
  the spike's `time.perf_counter()` around `subprocess.run` (startup ≈ 2.3 ms, subtract an
  `n=0` run) or `hyperfine`. Internal counters (propagations, conflicts) do not need a
  clock and should be printed regardless.
- **`roc test`**: `roc test [file] [--opt=..] [--verbose] [--timings] [--no-cache]
  [--watch] [--main <file>]`; runs all top-level `expect`s in the module and its imports;
  exit code 1 on any failed top-level expect, 0 otherwise (measured), prints
  `Ran N tests … passed/failed/compiler errors` — trivially driven from CI (`roc test
  src/main.roc || exit 1`). Results are cached (`(cached)` in output); use `--no-cache` in
  CI or when the toolchain changes.
- CI on GitHub Actions: `macos-14`/`macos-15` runners are arm64; download the pinned
  nightly tarball, `tar xf`, add to PATH; cache `brew install cadical kissat` and the
  drat-trim/cnfuzz builds.

---

## 9. Recommended concrete setup

**Milestone 0 (before propagation works)** — build the harness, not the solver:
1. A `bench/` dir with: `fetch.sh` (SATLIB tarballs + a `.uri` for the
   nightly set), `expected/` (status per instance from `cadical`), `run.py` (runs the
   solver with a timeout, checks exit code, calls `dimocheck`/`drat-trim`, prints a table
   and PAR-2, JSON export). Install: `brew install cadical kissat minisat hyperfine
   coreutils`, `pip3 install python-sat cnfgen gbd-tools`, clone+`make` drat-trim, cnfuzz,
   cnfdd, dimocheck. ~1 hour.
2. 30 hand-written edge-case CNFs with expected status.

**Every change (< 1 min, `make check`)**: `roc test` (unit + property expects, seeded, ~a
few seconds) → build `--opt=speed` → fast regression set (~2 000 tiny instances, every UNSAT
through drat-trim, every SAT through the model check) → 60 s of `runcnfuzz --tiny` with the
proof-checking wrapper. Fail on any mismatch, any exit code ∉ {10,20}, any `Expect failed`
in the debug-driver log, and on determinism (stats identical to the committed golden
`stats.json` for 20 fixed instances — bump the golden file deliberately when heuristics
change).

**Every commit to main / nightly (30–60 min)**: SATLIB complete + 100–200 GBD-selected
competition instances at 300 s, 6 parallel jobs max (P-cores), PAR-2 + solved count +
per-instance scatter vs last night; 30–60 min of `runcnfuzz --small` and option-fuzzing;
`hyperfine --min-runs 5` on 5 fixed medium instances with min-of-N reported; peak RSS.
Store JSON per night; a `compare.py` prints regressions > 10 % on min-of-N.

**Milestone order** that keeps confidence ahead of features: DIMACS parse + trivial
propagate (test on uf20) → DRAT writer *at the same time as* clause learning (it is 5 lines
and it makes every UNSAT self-checking) → conflict analysis + backjump (uuf50, `hole`,
`dubois`) → VSIDS/restarts/reduceDB (uf250, competition instances) → assumptions
(PySAT differential) → LRAT/optional.

---

## Open items / could not verify
- `roc test --opt=speed` was only observed with a cached build; cold behaviour of inline
  `expect` under `roc test --opt=speed` unverified (Track B).
- `roc build` (default dev backend) dropping inline `expect` contradicts the tutorial;
  observed once, worth re-checking on the next nightly.
- No monotonic clock is reachable from Roc without a platform; the exact API of the
  new-compiler basic-cli is still WIP (roc-lang/basic-cli PR #423).
- FuzzSAT (circuit fuzzer) exists only in the 2013 zip at https://fmv.jku.at/cnfuzzdd/;
  it was not built here.
- cake_lpr binaries: no GitHub releases assets; building requires the CakeML toolchain
  (not attempted).
- runlim on macOS: not tested; use `gtimeout` + `/usr/bin/time -l`.
