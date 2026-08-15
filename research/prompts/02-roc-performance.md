# Track B — Roc performance semantics (REVISED after the spike)

**STATUS: COMPLETE — deliverable is `research/02-roc-performance.md` (2026-08-16).**

The original version of this prompt asked eight questions. The spike in `spike/RESULTS.md`
answered five of them empirically, so this is now much narrower. Read `spike/RESULTS.md` and
`roc-docs/NOTES.md` before running this — do not re-litigate settled questions.

Already settled, do not re-measure:
- `var $x = ...; $x = $x.set(i, v)?` on a flat `List` mutates in place. ✅
- Nested `List(List(_))` clones the inner list on every append; ~100x, quadratic. ❌
- A flat block arena in a record is as fast as loose `var`s, and matches `clang -O2` exactly. ✅
- Bounds-checked `.get(i)?` costs the same as sequential iteration; ~3.9 G reads/sec. ✅
- **Q1 below is now ANSWERED** — see `spike/q5_boundary/RESULTS.md`. Module/function
  boundaries are fine; mutating through a record field projection is fragile (28/51 shapes
  clone); separate list values are robust (11/11). Do not re-run Q1. The RECOMMENDED MODULE
  STRUCTURE deliverable should be based on that document.

---

You are answering a small number of specific questions about the performance semantics of Roc
— the NEW (Zig) compiler, nightly builds at https://github.com/roc-lang/nightlies/releases.
A release nightly is already extracted; the `roc` on PATH is a debug+tracy build and must not
be used for measurement. Build with `roc build --opt=speed`.

CRITICAL CONTEXT ON SOURCES. Roc was recently rewritten and the language changed
substantially. Most material you find will be about the OLD compiler and will be actively
misleading: roc-lang.org (including the tutorial and FAQ), blog posts, existing Roc packages,
and anything mentioning `when`, `Result`, `List U8` without parens, or `Bool.true`. Trust, in
order: (1) measurement with the release nightly, (2) `roc-docs/Builtin.roc`, (3)
`roc-docs/langref/` and `roc-docs/mini-tutorial-new-compiler.md`, (4) recent Roc Zulip,
(5) nothing else. Version-stamp every claim.

THE PROJECT: a CDCL SAT solver in pure Roc, built on flat `List(U32)`/`List(U64)` arrays held
in a single state record. See `spike/RESULTS.md` for the design this implies.

ANSWER THESE. Each answer must be backed by a measurement or a primary source, and must state
plainly how confident you are.

Q1. UNIQUENESS ACROSS FUNCTION AND MODULE BOUNDARIES — the highest-priority question.
    The spike ran in a single file, where everything could inline. A real solver has
    `propagate`, `analyze`, `backtrack`, `reduce_db` in separate modules, each taking the
    state record and returning it. Does uniqueness survive:
      (a) a call to a non-inlined function in the same module?
      (b) a call across a module boundary?
      (c) a function that takes the state and returns it inside a `Try`?
      (d) a function that takes the state and returns a tuple/record containing it?
      (e) a recursive function threading the state?
    Build a benchmark shaped like the spike's `q3_flatwatch` `record` mode but with the inner
    update moved behind each of these boundaries, and report the timings against the inlined
    baseline. If any of these breaks in-place mutation, that is the single most important
    finding in this document — say so unambiguously and characterize exactly what triggers it.

Q2. WATCH-LIST CHURN WITH REMOVAL. The spike only measured appends into never-shrinking
    blocks. Real propagation removes as much as it adds, and blocks overflow. Benchmark a
    realistic mixed workload — append, swap-remove-last, and periodic compaction — over a flat
    block arena. What growth/compaction policy performs best? Compare against the intrusive
    linked-list-through-an-index-array alternative if Track A recommends it.

Q3. ESCAPE HATCHES AND FUTURE-PROOFING. `Builtin.roc` declares `list_get_unsafe`,
    `list_set_unsafe`, `list_swap_unsafe`, `list_replace_unsafe` as compiler-internal. Given
    that bounds checks measured as free, this is now a low-stakes question, but: are they
    reachable from application code, is exposing them planned, and is the measured
    "bounds checks are free" result something we can rely on or an accident of this nightly?
    Ask on Zulip if the answer is not documented.

Q4. `expect` UNDER `--opt=speed`. Docs say `expect` is skipped in speed builds but note this
    is not yet implemented. Verify current behavior by measuring a loop with an expensive
    `expect` in it. If it works, the solver can carry O(n) invariant checks at zero release
    cost, which is unusually good for this project and worth designing around.

Q5. ALLOCATION AND STARTUP. `List.repeat` of a large list measured ~1.4ms slower than
    `calloc` for 4M elements, presumably because it writes zeros eagerly. For a solver that
    allocates several variable-indexed arrays at startup and grows the clause arena as it
    parses, what are the allocation costs and how should growth be managed? Does `reserve`
    amortize properly, does capacity survive a `set`, is there a realloc-in-place path?

Q6. THE PRACTICALITIES. Which platform for a CLI tool on a current nightly — the Zig
    template, the Rust template, or the WIP basic-cli (roc-lang/basic-cli PR #423)? Confirm
    it provides file reading, argv, stdout, and a monotonic clock. How do you run tests
    (`roc test`?), and is there any way to inspect generated code or IR to check whether a
    mutation happened in place?

DELIVERABLE: research/02-roc-performance.md. Structure it as the six questions with direct
verdicts up front — each answer's first two sentences must give the conclusion, before the
evidence. Include the benchmark source you ran and its raw numbers. End with:
  - RECOMMENDED MODULE STRUCTURE: given Q1, how should the solver be split into functions and
    modules without losing in-place mutation?
  - UNRESOLVED: what you could not determine, and the exact experiment or Zulip question that
    would settle each one.

Do not invent APIs. Every function you name must be one you found in `Builtin.roc` or
confirmed by running it. A plausible-sounding function that does not exist costs me more than
an admission of uncertainty.
