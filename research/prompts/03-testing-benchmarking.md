# Track C — testing and benchmarking

Run this as a research agent. Independent of Tracks A and B.

---

Research how to establish that a from-scratch SAT solver is correct and how to measure its
performance. The solver is a new MiniSat-class CDCL implementation written in Roc; the author
has no existing test infrastructure and wants to build confidence incrementally from the first
milestone onward.

REPORT ON:

1. Checking a single answer. SAT answers are trivially checkable by evaluating the model;
   UNSAT answers are not. Cover DRAT/LRAT proof logging, drat-trim and any current
   alternatives, what proof checking costs relative to solving, and how to wire it into a
   test loop so that every UNSAT result in the regression suite is machine-verified.

2. Test corpora. Where to get graded CNF instances at every difficulty level, from toy
   problems up: SATLIB (uf/uuf families), SAT Competition benchmark archives, cnfgen and
   other generators. Concrete URLs and sizes. Identify a small set — tens of megabytes at
   most — suitable for a fast regression suite that runs on every change, and separately a
   larger set for nightly runs.

3. Random instances. The 3-SAT phase transition at clause/variable ratio ~4.26 and why
   instances near it are the interesting ones. How to generate them reproducibly with a seed.

4. Fuzzing and shrinking. CNF fuzzers (CNFuzz, FuzzSAT, and anything current) plus
   delta-debuggers that shrink a failing instance to something a human can read. This
   combination is reportedly how most real solver bugs get found — confirm that and describe
   the concrete workflow, including how to detect a wrong answer without a reference solver
   (self-consistency, proof checking) and with one.

5. Differential testing. Which reference solvers to use, how to install them on macOS
   (arm64), and how to compare results — including under assumptions, where the interface
   differs between solvers.

6. Property-based and unit-level testing. What properties are worth asserting about unit
   propagation, conflict analysis, and the watched-literal invariants. How to check structural
   invariants cheaply enough to leave enabled during development.
   Roc-specific: `expect` is Roc's built-in test/assert keyword, it runs under `roc test`, and
   it is documented as being compiled out under `--opt=speed`. Investigate how to build a
   testing strategy around that — it potentially allows expensive invariant checks that cost
   nothing in release builds. Verify the current behavior rather than trusting the docs;
   `roc-docs/NOTES.md` records that the docs say this is not yet implemented.

7. Benchmarking method. What to measure beyond wall-clock: propagations/sec, conflicts/sec,
   decisions, restarts, peak memory. How solver papers report results (cactus plots, PAR-2
   scoring), timeout conventions, and how to avoid fooling yourself benchmarking on a laptop
   (thermal throttling, efficiency vs performance cores on Apple silicon, run-to-run variance,
   why minimum-of-N beats mean).

8. Roc-specific mechanics. How do you time a Roc program — does the current platform expose a
   monotonic clock, or must timing be external? How do you get a release build
   (`roc build --opt=speed`)? How does `roc test` work and can it be driven from CI?
   Note that the `roc` on PATH may be a debug build and unusable for benchmarking; document
   how to check (`roc version` printing `debug-*` or mentioning tracy).

9. A recommended concrete setup: what to build first, what runs on every change, what runs
   nightly, and roughly how long each should take.

RULES: verify tools still exist and build today; give install commands for macOS arm64 where
possible; note anything that appears abandoned. Every claim gets a URL.

Write the document to research/03-testing-benchmarking.md.
